use v5.24;
use strict;
use warnings;
use utf8;

use Test2::V0;
use Kernel::System::UnitTest::RegisterOM;
use Kernel::System::MultiSMTP;
use Kernel::System::Email::MultiSMTP;
use Kernel::System::Email::MultiSMTP::SMTP;
use Kernel::System::Email::MultiSMTP::SMTPS;
use Kernel::System::Email::MultiSMTP::SMTPTLS;
use Kernel::System::OpenIDConnect::TokenProvider;

my $Config = $Kernel::OM->Get('Kernel::Config');
my %Global = (
    'SendmailModule::Host' => 'fallback.example.test',
    'SendmailModule::Port' => 2525,
    'SendmailModule::AuthUser' => 'fallback-user',
    'SendmailModule::AuthPassword' => 'fallback-password',
    'SendmailModule::OAuth2Method' => 'Basic',
    'SendmailModule::OAuth2FunctionalAccount' => 'global-oauth',
    'SendmailModule::SSLVerifyMode' => 1,
    'MultiSMTP::UseFallback' => 0,
    'MultiSMTP::UseSenderFromMail' => 0,
    'MultiSMTP::Fallback' => 'Kernel::System::Email::SMTP',
    'MultiSMTP::Debug' => 0,
);
$Config->Set( Key => $_, Value => $Global{$_} ) for keys %Global;

my %Accounts = (
    'one@example.test' => {
        ID => 1, Host => 'first.example.test', Port => 587, User => 'same-user',
        PasswordDecrypted => 'first-password', Type => 'SMTPTLS', AuthMethod => 'Basic',
    },
    'two@example.test' => {
        ID => 2, Host => 'second.example.test', Port => 2587, User => 'same-user',
        PasswordDecrypted => 'second-password', Type => 'SMTPTLS', AuthMethod => 'Basic',
    },
    'oauth@example.test' => {
        ID => 3, Host => 'oauth.example.test', Port => 465, User => 'oauth-user',
        PasswordDecrypted => '', Type => 'SMTPS', AuthMethod => 'XOAUTH2',
        OAuth2FunctionalAccount => 'first-oauth',
    },
    'anonymous@example.test' => {
        ID => 4, Host => 'relay.example.test', Port => 25, User => '',
        PasswordDecrypted => '', Type => 'SMTP', AuthMethod => 'Basic',
    },
);

my @Connections;
my @TokenAccounts;
my @Errors;
my %Failure;
my $AccountsMock = mock 'Kernel::System::MultiSMTP' => (
    override => [ SMTPGetForAddress => sub {
        my ( $Self, %Param ) = @_;
        return %{ $Accounts{ $Param{Address} } // {} };
    } ],
);
my $SMTPMock = mock 'Net::SMTP' => (
    override => [ new => sub {
        my ( $Type, $Host, %Options ) = @_;
        my $Connection = bless { Host => $Host, Options => \%Options, Failure => { %Failure } }, 'MultiSMTPTestConnection';
        push @Connections, $Connection;
        return $Connection;
    } ],
);
my $TokenMock = mock 'Kernel::System::OpenIDConnect::TokenProvider' => (
    override => [ Fetch => sub {
        my ( $Self, %Param ) = @_;
        push @TokenAccounts, $Param{AccountName};
        return { Success => 1, Token => 'token-' . $Param{AccountName} };
    } ],
);
my $LogMock = mock $Kernel::OM->Get('Kernel::System::Log') => (
    override => [ Log => sub { my ( $Self, %Param ) = @_; push @Errors, $Param{Message}; return 1 } ],
);
my $Backend = $Kernel::OM->Get('Kernel::System::Email::MultiSMTP');
my $Log = bless {}, 'MultiSMTPTestLog';

sub SendMessage {
    my (%Param) = @_;
    my $Header = delete $Param{Header} // "From: $Param{From}\r\nTo: recipient\@example.test\r\nSubject: test\r\n";
    my $Body = 'test body';
    return $Backend->Send(
        Header => \$Header, Body => \$Body, ToArray => ['recipient@example.test'],
        CommunicationLogObject => $Log, %Param,
    );
}

is( { $Backend->Check() }, { Success => 1 }, 'backend Check follows the core contract' );
for my $Address (qw(one@example.test two@example.test one@example.test)) {
    ok( SendMessage( From => $Address )->{Success}, "send from $Address" );
}
is( [ map { $_->{Host} } @Connections ],
    [qw(first.example.test second.example.test first.example.test)], 'each message selects its own host' );
is( [ map { $_->{Options}->{Port} } @Connections ], [587,2587,587], 'same username does not retain an old port' );
is( [ map { $_->{Auth} } @Connections ],
    [ ['same-user','first-password'], ['same-user','second-password'], ['same-user','first-password'] ],
    'same username does not retain an old password' );
is( [ map { $_->{DataEnds} } @Connections ], [1,1,1], 'exactly one delivery per message (#14/#15)' );
is( [ map { $_->{TLS}->{SSL_verify_mode} } @Connections ], [1,1,1], 'STARTTLS retains certificate verification' );
is( [ map { $Config->Get($_) } sort keys %Global ], [ map { $Global{$_} } sort keys %Global ], 'global settings restored' );

ok( SendMessage( From => 'oauth@example.test' )->{Success}, 'XOAUTH2 send' );
is( $Connections[-1]->{OAuth}, ['XOAUTH2','oauth-user','token-first-oauth','oauth.example.test',465], 'native OAuth receives account token' );
is( $Connections[-1]->{Options}->{SSL_verify_mode}, 1, 'SMTPS retains certificate verification' );
$Accounts{'oauth@example.test'}->{OAuth2FunctionalAccount} = 'second-oauth';
$Accounts{'oauth@example.test'}->{AuthMethod} = 'OAUTHBEARER';
ok( SendMessage( From => 'oauth@example.test' )->{Success}, 'OAUTHBEARER send after changing account' );
is( \@TokenAccounts, ['first-oauth','second-oauth'], 'token provider uses current functional account (#17/#19)' );
is( $Connections[-1]->{OAuth}->[0], 'OAUTHBEARER', 'authentication method changes too' );
ok( SendMessage( From => 'anonymous@example.test' )->{Success}, 'anonymous relay works' );
ok( !$Connections[-1]->{Auth} && !$Connections[-1]->{OAuth}, 'anonymous relay does not inherit credentials' );

ok( SendMessage( From => '=?UTF-8?Q?Zg=C5=82oszenia?= <one@example.test>' )->{Success}, 'encoded display name (#4/#7)' );
is( $Connections[-1]->{Envelope}, 'one@example.test', 'SMTP receives a plain envelope address' );
$Config->Set( Key => 'MultiSMTP::UseSenderFromMail', Value => 1 );
ok( SendMessage( From => 'bounce@example.test', Header => "fRoM: Name\r\n <two\@example.test>\r\n" )->{Success}, 'folded header selects account (#11)' );
is( $Connections[-1]->{Host}, 'second.example.test', 'header selects second account' );
is( $Connections[-1]->{Envelope}, 'bounce@example.test', 'routing does not rewrite an explicit envelope' );
ok( SendMessage( From => '', Header => "From: One <one\@example.test>\r\n" )->{Success}, 'empty bounce envelope can select by header' );
is( $Connections[-1]->{Envelope}, '', 'null bounce envelope is preserved' );
my $BeforeInvalid = scalar @Connections;
ok( !SendMessage( From => '', Header => "From: one\@example.test\r\nFrom: two\@example.test\r\n" )->{Success}, 'duplicate From rejected' );
ok( !SendMessage( From => '', Header => "From: one\@example.test, two\@example.test\r\n" )->{Success}, 'ambiguous From rejected' );
is( scalar @Connections, $BeforeInvalid, 'invalid senders never connect' );
$Config->Set( Key => 'MultiSMTP::UseSenderFromMail', Value => 0 );

my $Missing = SendMessage( From => 'unknown@example.test' );
ok( !$Missing->{Success} && $Missing->{ErrorMessage}, 'disabled fallback returns structured failure' );
is( scalar @Connections, $BeforeInvalid, 'disabled fallback does not send' );
$Config->Set( Key => 'MultiSMTP::UseFallback', Value => 1 );
ok( SendMessage( From => 'unknown@example.test' )->{Success}, 'enabled fallback works' );
is( $Connections[-1]->{Host}, 'fallback.example.test', 'fallback retains global host' );
is( $Connections[-1]->{Auth}, ['fallback-user','fallback-password'], 'fallback retains global credentials' );
is( $Connections[-1]->{DataEnds}, 1, 'fallback sends once' );
$Config->Set( Key => 'MultiSMTP::Fallback', Value => 'Kernel::System::Email::MultiSMTP' );
ok( !SendMessage( From => 'unknown@example.test' )->{Success}, 'recursive fallback rejected' );
$Config->Set( Key => 'MultiSMTP::Fallback', Value => $Global{'MultiSMTP::Fallback'} );

%Failure = ( TLS => 1 );
my $BeforeTLS = scalar @Connections;
ok( !SendMessage( From => 'one@example.test' )->{Success}, 'failed STARTTLS fails send' );
ok( !(grep { $_->{Auth} || $_->{DataEnds} } @Connections[$BeforeTLS..$#Connections]), 'no authentication/data after failed TLS' );
$Config->Set( Key => 'MultiSMTP::Fallback', Value => 'Kernel::System::Email::SMTPTLS' );
my $BeforeFallbackTLS = scalar @Connections;
ok( !SendMessage( From => 'unknown@example.test' )->{Success}, 'fallback also rejects failed STARTTLS' );
ok( !(grep { $_->{Auth} || $_->{DataEnds} } @Connections[$BeforeFallbackTLS..$#Connections]), 'fallback never authenticates after failed TLS' );
$Config->Set( Key => 'MultiSMTP::Fallback', Value => $Global{'MultiSMTP::Fallback'} );
%Failure = ( Auth => 1 );
ok( !SendMessage( From => 'one@example.test' )->{Success}, 'rejected credentials fail send without fallback' );
ok( !$Connections[-1]->{DataEnds}, 'rejected credentials never send DATA' );
%Failure = ( Mail => 1 );
ok( !SendMessage( From => 'one@example.test' )->{Success}, '550 sender rejection propagates' );
ok( !$Connections[-1]->{DataEnds}, '550 never sends DATA or retries with fallback' );
%Failure = ( AuthDie => 1 );
ok( !SendMessage( From => 'one@example.test' )->{Success}, 'authentication exception is a structured failure' );
unlike( join('\n', @Errors), qr/first-password|second-password|secret-exception/, 'authentication exception never logs secrets' );
is( $Config->Get('SendmailModule::AuthPassword'), 'fallback-password', 'config restored after exception' );
%Failure = ();

done_testing();

package MultiSMTPTestLog;
sub ObjectLogStart { return 1 }
sub ObjectLogStop { return 1 }
sub ObjectLog { return 1 }

package MultiSMTPTestConnection;
sub starttls { my ( $Self, %Options ) = @_; $Self->{TLS}=\%Options; return !$Self->{Failure}->{TLS} }
sub auth {
    my ( $Self, @Arguments ) = @_;
    die 'secret-exception ' . $Arguments[1] if $Self->{Failure}->{AuthDie};
    $Self->{Auth}=\@Arguments;
    return !$Self->{Failure}->{Auth};
}
sub Otobo_OAuth2 { my ( $Self, @Arguments ) = @_; $Self->{OAuth}=\@Arguments; return 1 }
sub mail { my ( $Self, $From ) = @_; $Self->{Envelope}=$From; return !$Self->{Failure}->{Mail} }
sub to { return 1 }
sub data { return 1 }
sub datasend { return 1 }
sub dataend { $_[0]->{DataEnds}++; return 1 }
sub quit { $_[0]->{Quits}++; return 1 }
sub code { return 550 }
sub message { return 'Test failure' }
