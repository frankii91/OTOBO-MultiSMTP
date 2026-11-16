use v5.24;
use strict;
use warnings;
use utf8;

use Test2::V0;
use Net::SMTP ();
use Kernel::System::UnitTest::RegisterOM;

$Kernel::OM->ObjectParamAdd(
    'Kernel::System::UnitTest::Helper' => {
        RestoreDatabase => 1,
    },
);

my $Helper = $Kernel::OM->Get('Kernel::System::UnitTest::Helper');
for my $Setting (
    [ CheckEmailAddresses => 0 ],
    [ SendmailModule => 'Kernel::System::Email::MultiSMTP' ],
    [ 'SendmailNotificationEnvelopeFrom' => '' ],
    [ 'SendmailNotificationEnvelopeFrom::FallbackToEmailFrom' => 0 ],
    [ 'MultiSMTP::UseFallback' => 0 ],
    [ 'MultiSMTP::UseSenderFromMail' => 0 ],
    [ 'MultiSMTP::Debug' => 0 ],
) {
    $Helper->ConfigSettingChange(
        Key   => $Setting->[0],
        Value => $Setting->[1],
    );
}

my $SMTPObject     = $Kernel::OM->Get('Kernel::System::MultiSMTP');
my $EmailObject    = $Kernel::OM->Get('Kernel::System::Email');
my $MailQueueObject = $Kernel::OM->Get('Kernel::System::MailQueue');
my $ValidID = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup( Valid => 'valid' );
my ( undef, $UserID ) = $Helper->TestUserCreate(
    Groups => [ 'admin', 'users' ],
);

my $AddAccount = sub {
    my (%Param) = @_;

    return $SMTPObject->SMTPAdd(
        Host                     => $Param{Host},
        User                     => $Param{User} // '',
        Password                 => $Param{Password} // '',
        Port                     => $Param{Port} || 587,
        Type                     => $Param{Type} || 'SMTPTLS',
        Emails                   => [ $Param{Email} ],
        ValidID                  => $ValidID,
        UserID                   => $UserID,
        AuthMethod               => $Param{AuthMethod} || 'Basic',
        OAuth2FunctionalAccount  => $Param{OAuth2FunctionalAccount} // '',
        Anonymous                => $Param{Anonymous} || 0,
    );
};

my $RunID = $Helper->GetRandomNumber();
my $OIDCProfileName = "__MultiSMTP_MailQueue_Profile_$RunID";
my $ProfileRepository = $Kernel::OM->Get('Kernel::System::OpenIDConnect::ProfileRepository');
ok(
    $ProfileRepository->AddProfile(
        Name => $OIDCProfileName,
        ClientSettings => {
            ClientID     => 'multismtp-mailqueue-client',
            ClientSecret => 'multismtp-mailqueue-secret',
            RedirectURI  => '',
        },
        ProviderSettings => {
            OpenIDConfiguration => 'https://oidc.example.test/.well-known/openid-configuration',
            TTL                 => 1800,
            SSLOptions          => {},
        },
        Valid  => 1,
        UserID => $UserID,
    ),
    'temporary OIDC profile created for authentication API coverage',
);
my $OIDCProfile = $ProfileRepository->GetProfile( Name => $OIDCProfileName );
my $FunctionalAccounts = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts');
for my $AuthMethod (qw(XOAUTH2 OAUTHBEARER)) {
    my $Name = "MultiSMTP test $AuthMethod";
    ok(
        $FunctionalAccounts->SaveAccount(
            Name          => $Name,
            OIDCProfileID => $OIDCProfile->{ProfileID},
            GrantType     => 'client_credentials',
            Scope         => 'openid email',
            Token         => 'access_token',
            Valid         => 1,
            UserID        => $UserID,
        ),
        "$AuthMethod functional account created without a token request",
    );
}

my @Profiles = (
    {
        Address  => "multismtp-one-$RunID\@example.test",
        Host     => 'multismtp-one.example.test',
        Port     => 1587,
        Password => 'profile-one-password',
    },
    {
        Address  => "multismtp-two-$RunID\@example.test",
        Host     => 'multismtp-two.example.test',
        Port     => 2587,
        Password => 'profile-two-password',
    },
);

my %ProfileIDs;
for my $Profile (@Profiles) {
    $ProfileIDs{ $Profile->{Address} } = $AddAccount->(
        Email    => $Profile->{Address},
        Host     => $Profile->{Host},
        Port     => $Profile->{Port},
        User     => 'shared-user',
        Password => $Profile->{Password},
    );
    ok( $ProfileIDs{ $Profile->{Address} }, "database profile created for $Profile->{Address}" );

    my %Stored = $SMTPObject->SMTPGetForAddress(
        Address => $Profile->{Address},
        Valid   => 1,
    );
    is( $Stored{Host}, $Profile->{Host}, 'profile host is loaded from the database' );
    is( $Stored{User}, 'shared-user', 'profile username is loaded from the database' );
    is( $Stored{PasswordDecrypted}, $Profile->{Password}, 'profile password is loaded from the database' );
    is( $Stored{AuthMethod}, 'Basic', 'profile authentication method is loaded from the database' );
}

for my $AuthMethod (qw(XOAUTH2 OAUTHBEARER)) {
    my $Address = "multismtp-$AuthMethod-$RunID\@example.test";
    my $OAuthAccount = "MultiSMTP test $AuthMethod";
    my $ID = $AddAccount->(
        Email                    => $Address,
        Host                     => 'multismtp-oauth.example.test',
        Port                     => 1587,
        Type                     => 'SMTP',
        User                     => 'oauth-user',
        AuthMethod               => $AuthMethod,
        OAuth2FunctionalAccount  => $OAuthAccount,
    );
    ok( $ID, "$AuthMethod profile created through SMTPAdd" );

    my %Stored = $SMTPObject->SMTPGetForAddress(
        Address => $Address,
        Valid   => 1,
    );
    is( $Stored{AuthMethod}, $AuthMethod, "$AuthMethod method is persisted" );
    is( $Stored{OAuth2FunctionalAccount}, $OAuthAccount, "$AuthMethod account name is persisted" );
}

my $AnonymousAddress = "multismtp-anonymous-$RunID\@example.test";
my $AnonymousID = $AddAccount->(
    Email     => $AnonymousAddress,
    Host      => 'multismtp-anonymous.example.test',
    Port      => 25,
    Type      => 'SMTP',
    Anonymous => 1,
);
ok( $AnonymousID, 'anonymous profile can be created with empty credentials' );
my %AnonymousProfile = $SMTPObject->SMTPGetForAddress(
    Address => $AnonymousAddress,
    Valid   => 1,
);
is( $AnonymousProfile{User}, '', 'anonymous profile has no username' );
is( $AnonymousProfile{PasswordDecrypted}, '', 'anonymous profile has no password' );

my @SMTPConnections;
our %SMTPBehavior;
my $SMTPMock = mock 'Net::SMTP' => (
    override => [ new => sub {
        my ( $Class, $Host, %Options ) = @_;
        die "Refusing non-test SMTP target: $Host" if $Host !~ /\.example\.test\z/;

        my $Connection = bless {
            Host     => $Host,
            Options  => \%Options,
            Behavior => { %SMTPBehavior },
            Data     => '',
        }, 'MultiSMTPMailQueueTestConnection';
        push @SMTPConnections, $Connection;
        return $Connection;
    } ],
);

for my $Index ( 0 .. $#Profiles ) {
    my $Profile   = $Profiles[$Index];
    my $Recipient = "multismtp-fixture-$RunID-$Index\@example.test";
    is( $MailQueueObject->List( Recipient => $Recipient ), [], 'unique local recipient fixture starts unused' );

    my $BuildResult = $EmailObject->Send(
        From     => "Zgłoszenia Łukasz <$Profile->{Address}>",
        To       => $Recipient,
        Subject  => "MultiSMTP integration profile $Index",
        Body     => "mailqueue-body-$RunID-$Index",
        MimeType => 'text/plain',
        Charset  => 'utf-8',
        Loop     => 1,
    );
    ok( $BuildResult->{Success}, 'native Email->Send builds and queues the message' );
    like( $BuildResult->{Data}->{Header}, qr/^From:.*=\?utf-8\?[BQ]\?/mi, 'native MIME header encodes the UTF-8 display name' );
    like( $BuildResult->{Data}->{Header}, qr/^Content-Type:\s*text\/plain.*charset\s*=\s*"?utf-8/i, 'native MIME header records the body charset' );
    like( $BuildResult->{Data}->{Body}, qr/mailqueue-body-\Q$RunID\E-\Q$Index\E/, 'native MIME body is retained' );

    my $Items = $MailQueueObject->List( Recipient => $Recipient );
    is( scalar @{$Items}, 1, 'Email->Send created only the matching queue item' );
    my $Item = $Items->[0];
    is( $Item->{Recipient}, [$Recipient], 'queue item has the local fixture recipient' );
    ok( !defined $Item->{Sender} || $Item->{Sender} eq '', 'Loop notification is queued with a null envelope sender' );
    like( $Item->{Message}->{Header}, qr/^From:.*\Q$Profile->{Address}\E/ims, 'queued MIME retains the sender used for profile mapping' );

    my $ConnectionCount = scalar @SMTPConnections;
    my $SendResult      = $MailQueueObject->Send( %{$Item} );
    is( $SendResult->{Status}, 'Success', 'MailQueue->Send delivers the queued message' );
    is( scalar @SMTPConnections - $ConnectionCount, 1, 'one SMTP connection handles this queue item' );

    my $Connection = $SMTPConnections[-1];
    is( $Connection->{Host}, $Profile->{Host}, 'database mapping selects the expected SMTP host' );
    is( $Connection->{Options}->{Port}, $Profile->{Port}, 'database mapping selects the expected SMTP port' );
    is( $Connection->{Auth}, ['shared-user', $Profile->{Password}], 'same username uses this profile password' );
    is( $Connection->{Envelope}, '', 'SMTP receives the null envelope sender' );
    is( $Connection->{To}, [$Recipient], 'SMTP receives only the local fixture recipient' );
    is( $Connection->{DataEnds}, 1, 'one queued message is transmitted exactly once' );
    like( $Connection->{Data}, qr/^From:.*\Q$Profile->{Address}\E/ims, 'SMTP payload contains the mapped From header' );
    like( $Connection->{Data}, qr/mailqueue-body-\Q$RunID\E-\Q$Index\E/, 'SMTP payload contains the native MIME body' );
    is( $MailQueueObject->List( ID => $Item->{ID} ), [], 'success removes only the processed queue item' );
}

my $MissingAddress   = "multismtp-unmapped-$RunID\@example.test";
my $MissingRecipient = "multismtp-fixture-unmapped-$RunID\@example.test";
my $MissingBuild = $EmailObject->Send(
    From     => $MissingAddress,
    To       => $MissingRecipient,
    Subject  => 'MultiSMTP unmapped sender',
    Body     => "unmapped-body-$RunID",
    MimeType => 'text/plain',
    Charset  => 'utf-8',
);
ok( $MissingBuild->{Success}, 'native Email->Send queues an unmapped sender for queue-time handling' );
my $MissingItems = $MailQueueObject->List( Recipient => $MissingRecipient );
is( scalar @{$MissingItems}, 1, 'unmapped message has one scoped queue item' );
my $MissingItem     = $MissingItems->[0];
my $ConnectionCount = scalar @SMTPConnections;
my $MissingSend     = $MailQueueObject->Send( %{$MissingItem} );
is( $MissingSend->{Status}, 'Failed', 'disabled fallback fails an unmapped sender' );
is( scalar @SMTPConnections, $ConnectionCount, 'unmapped sender does not open an SMTP connection' );
my $RetriedItems = $MailQueueObject->List( ID => $MissingItem->{ID} );
is( scalar @{$RetriedItems}, 1, 'unmapped sender remains queued for retry' );
is( $RetriedItems->[0]->{Attempts}, 1, 'unmapped failure increments attempts once' );

my $RejectedRecipient = "multismtp-fixture-550-$RunID\@example.test";
my $RejectedBuild = $EmailObject->Send(
    From     => $Profiles[0]->{Address},
    To       => $RejectedRecipient,
    Subject  => 'MultiSMTP transport rejection',
    Body     => "rejected-body-$RunID",
    MimeType => 'text/plain',
    Charset  => 'utf-8',
);
ok( $RejectedBuild->{Success}, 'native Email->Send queues a message for transport rejection handling' );
my $RejectedItems = $MailQueueObject->List( Recipient => $RejectedRecipient );
is( scalar @{$RejectedItems}, 1, '550 test has one scoped queue item' );
my $RejectedItem = $RejectedItems->[0];
{
    local %SMTPBehavior = (
        RejectMail => 1,
        Code       => 550,
        Message    => 'fixture sender rejected',
    );
    my $RejectedSend = $MailQueueObject->Send( %{$RejectedItem} );
    is( $RejectedSend->{Status}, 'Failed', 'SMTP 550 is reported as a failed queue send' );
}
my $RejectedConnection = $SMTPConnections[-1];
is( $RejectedConnection->{Envelope}, $Profiles[0]->{Address}, '550 is returned for the mapped envelope sender' );
is( $RejectedConnection->{DataEnds} || 0, 0, 'SMTP 550 stops before sending message data' );
is( $MailQueueObject->List( ID => $RejectedItem->{ID} ), [], 'permanent SMTP 550 removes only the rejected queue item' );

done_testing();

package MultiSMTPMailQueueTestConnection;
sub starttls { my ( $Self, %Options ) = @_; $Self->{TLS} = \%Options; return 1 }
sub auth { my ( $Self, @Arguments ) = @_; $Self->{Auth} = \@Arguments; return 1 }
sub mail { my ( $Self, $From ) = @_; $Self->{Envelope} = $From; return !$Self->{Behavior}->{RejectMail} }
sub to { my ( $Self, $Address ) = @_; push @{ $Self->{To} }, $Address; return 1 }
sub data { return 1 }
sub datasend { my ( $Self, $Data ) = @_; $Self->{Data} .= $Data; return 1 }
sub dataend { $_[0]->{DataEnds}++; return 1 }
sub quit { $_[0]->{Quits}++; return 1 }
sub code { return $_[0]->{Behavior}->{Code} // 250 }
sub message { return $_[0]->{Behavior}->{Message} // 'fixture accepted' }

