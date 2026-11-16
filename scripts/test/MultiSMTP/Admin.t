use v5.24;
use strict;
use warnings;
use utf8;

use Kernel::System::UnitTest::RegisterDriver;
use Kernel::System::UnitTest::Selenium;

our $Self;

my $Selenium = Kernel::System::UnitTest::Selenium->new( LogExecuteCommandActive => 1 );
my $Helper   = $Kernel::OM->Get('Kernel::System::UnitTest::Helper');
my $RunID    = $Helper->GetRandomNumber();
my @SMTPIDs;
my @SystemAddressIDs;
my $FunctionalAccountName;
my $OIDCProfileName;
my $UserID = 1;
my $CleanupDone;

my $Cleanup = sub {
    return if $CleanupDone++;

    my $SMTPObject = $Kernel::OM->Get('Kernel::System::MultiSMTP');
    $SMTPObject->SMTPDelete( ID => $_ ) for @SMTPIDs;

    if ($FunctionalAccountName) {
        $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->DeleteAccount(
            Name   => $FunctionalAccountName,
            UserID => $UserID,
        );
    }
    if ($OIDCProfileName) {
        $Kernel::OM->Get('Kernel::System::OpenIDConnect::ProfileRepository')->DeleteProfile(
            Name => $OIDCProfileName,
        );
    }

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');
    for my $ID (@SystemAddressIDs) {
        $DBObject->Do(
            SQL  => 'DELETE FROM system_address WHERE id = ?',
            Bind => [ \$ID ],
        );
    }
    $Kernel::OM->Get('Kernel::System::Cache')->CleanUp( Type => 'SystemAddress' );
};

END {
    eval { $Cleanup->() } if $Cleanup;
}

$Selenium->RunTest(
    sub {
        my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
        my $SMTPObject   = $Kernel::OM->Get('Kernel::System::MultiSMTP');
        my $ValidID      = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup( Valid => 'valid' );
        my $SystemAddressObject = $Kernel::OM->Get('Kernel::System::SystemAddress');

        my $TestUserLogin = $Helper->TestUserCreate(
            Groups => ['admin'],
        ) || die 'Could not create test administrator';
        $UserID = $Kernel::OM->Get('Kernel::System::User')->UserLookup(
            UserLogin => $TestUserLogin,
        );

        $OIDCProfileName = "__MultiSMTP_Selenium_Profile_$RunID";
        my $ProfileRepository = $Kernel::OM->Get('Kernel::System::OpenIDConnect::ProfileRepository');
        my $ProfileCreated = $ProfileRepository->AddProfile(
            Name => $OIDCProfileName,
            ClientSettings => {
                ClientID     => 'multismtp-selenium-client',
                ClientSecret => 'multismtp-selenium-secret',
                RedirectURI  => '',
            },
            ProviderSettings => {
                OpenIDConfiguration => 'https://oidc.example.test/.well-known/openid-configuration',
                TTL                 => 1800,
                SSLOptions          => {},
            },
            Valid  => 1,
            UserID => $UserID,
        );
        $Self->True( $ProfileCreated, 'temporary OIDC profile created for the OAuth selector' );
        my $Profile = $ProfileRepository->GetProfile( Name => $OIDCProfileName );

        $FunctionalAccountName = "__MultiSMTP_Selenium_Account_$RunID";
        my $FunctionalAccountCreated = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->SaveAccount(
            Name          => $FunctionalAccountName,
            OIDCProfileID => $Profile->{ProfileID},
            GrantType     => 'client_credentials',
            Scope         => 'openid email',
            Token         => 'access_token',
            Valid         => 1,
            UserID        => $UserID,
        );
        $Self->True( $FunctionalAccountCreated, 'temporary OAuth functional account created' );

        my $QueueID = $Kernel::OM->Get('Kernel::System::Queue')->QueueLookup( Queue => 'Raw' );
        $Self->True( $QueueID, 'Raw queue exists for temporary system addresses' );
        my %SystemAddresses;
        for my $Name (qw(Basic OAuth Anonymous)) {
            my $Address = "multismtp-admin-$RunID-" . lc($Name) . '@example.test';
            my $ID = $SystemAddressObject->SystemAddressAdd(
                Name     => $Address,
                Realname => "MultiSMTP $Name test",
                ValidID  => $ValidID,
                QueueID  => $QueueID,
                UserID   => $UserID,
            );
            push @SystemAddressIDs, $ID if $ID;
            $Self->True( $ID, "temporary system address created for $Name" );
            $SystemAddresses{$Name} = $Address;
        }

        my $ScriptAlias = $ConfigObject->Get('ScriptAlias');
        $Selenium->Login(
            Type     => 'Agent',
            User     => $TestUserLogin,
            Password => $TestUserLogin,
        );
        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP");
        $Selenium->find_element( '#SMTP', 'css' );
        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP;Subaction=Add");

        for my $ID (qw(Host Port Type AuthMethod User OAuth2FunctionalAccount Anonymous PasswordDecrypted Emails ValidID Comments)) {
            $Selenium->find_element( "#$ID", 'css' );
        }
        my $AuthMethods = $Selenium->execute_script(
            "return Array.from(document.querySelectorAll('#AuthMethod option')).map(Option => Option.value);"
        );
        for my $AuthMethod (qw(Basic XOAUTH2 OAUTHBEARER)) {
            $Self->True( ( grep { $_ eq $AuthMethod } @{$AuthMethods} ) ? 1 : 0, "$AuthMethod is available in the admin form" );
        }

        my $FillForm = sub {
            my (%Param) = @_;
            $Selenium->find_element( '#Host', 'css' )->send_keys( $Param{Host} );
            $Selenium->find_element( '#Port', 'css' )->clear();
            $Selenium->find_element( '#Port', 'css' )->send_keys( $Param{Port} || '587' );
            $Selenium->InputFieldValueSet( Element => '#Type', Value => $Param{Type} || 'SMTP' );
            $Selenium->InputFieldValueSet( Element => '#AuthMethod', Value => $Param{AuthMethod} || 'Basic' );
            $Selenium->find_element( '#User', 'css' )->send_keys( $Param{User} ) if $Param{User};
            $Selenium->find_element( '#PasswordDecrypted', 'css' )->send_keys( $Param{Password} ) if $Param{Password};
            $Selenium->InputFieldValueSet( Element => '#OAuth2FunctionalAccount', Value => $Param{OAuth2FunctionalAccount} )
                if $Param{OAuth2FunctionalAccount};
            $Selenium->execute_script(
                "\$('#Anonymous').prop('checked', true).trigger('change');"
            ) if $Param{Anonymous};
            $Selenium->InputFieldValueSet(
                Element => '#Emails',
                Value   => qq{["$Param{Email}"]},
            );
            $Selenium->InputFieldValueSet( Element => '#ValidID', Value => $ValidID );
        };

        my $AddProfile = sub {
            my (%Param) = @_;
            $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP;Subaction=Add");
            $FillForm->(%Param);
            my $EmailOptionCount = $Selenium->execute_script(
                "return \$('#Emails option[value=\"$Param{Email}\"]').length;"
            );
            $Self->Is( $EmailOptionCount, 1, 'test system address is available in the email selector' );
            $Selenium->find_element( 'form.Validate button[type=submit]', 'css' )->VerifiedClick();
        };

        my $BasicEmail    = $SystemAddresses{Basic};
        my $BasicPassword = "multismtp-password-$RunID";
        my $BasicHost     = "multismtp-basic-$RunID.example.test";
        $AddProfile->(
            Host     => $BasicHost,
            User     => "multismtp-user-$RunID",
            Password => $BasicPassword,
            Email    => $BasicEmail,
        );
        my %BasicProfile = $SMTPObject->SMTPGetForAddress( Address => $BasicEmail, Valid => 1 );
        $Self->True( $BasicProfile{ID}, 'Save creates a database-backed SMTP account' );
        push @SMTPIDs, $BasicProfile{ID};
        $Self->Is( $BasicProfile{AuthMethod}, 'Basic', 'new account stores Basic authentication' );

        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP;Subaction=Edit;ID=$BasicProfile{ID}");
        $Self->Is( $Selenium->find_element( '#PasswordDecrypted', 'css' )->get_value(), '', 'edit never reveals the stored password' );
        $Selenium->find_element( 'form.Validate button[type=submit]', 'css' )->VerifiedClick();
        %BasicProfile = $SMTPObject->SMTPGet( ID => $BasicProfile{ID} );
        $Self->Is( $BasicProfile{PasswordDecrypted}, $BasicPassword, 'blank password on edit preserves the stored password' );

        my $CSRFProtection = $ConfigObject->Get('SessionCSRFProtection');
        $Self->True( $CSRFProtection, 'CSRF protection is enabled in the test application' );
        my $ForgedResponse = $Selenium->execute_async_script(
            q{
                const Done = arguments[arguments.length - 1];
                const Body = new URLSearchParams();
                Body.append('Action', 'AdminMultiSMTP');
                Body.append('Subaction', 'Delete');
                Body.append('ID', arguments[0]);
                fetch(window.location.pathname, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
                    body: Body.toString()
                }).then(Response => Response.text()).then(Done).catch(Error => Done('REQUEST_ERROR: ' + String(Error)));
            },
            $BasicProfile{ID},
        );
        $Self->True( index( $ForgedResponse, 'Invalid Challenge Token!' ) > -1, 'delete POST without the browser challenge token is rejected' );
        my %AfterForgedDelete = $SMTPObject->SMTPGet( ID => $BasicProfile{ID} );
        $Self->True( $AfterForgedDelete{ID}, 'rejected delete leaves the SMTP account intact' );

        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP");
        $Selenium->find_element(
            "//form[contains(concat(' ', normalize-space(\@class), ' '), ' DeleteSMTP ')][.//input[\@name='ID' and \@value='$BasicProfile{ID}']]//button"
        )->VerifiedClick();
        my %AfterValidDelete = $SMTPObject->SMTPGet( ID => $BasicProfile{ID} );
        $Self->False( $AfterValidDelete{ID}, 'delete form submits with its challenge token and removes the selected account' );

        my $OAuthEmail = $SystemAddresses{OAuth};
        $AddProfile->(
            Host                    => "multismtp-oauth-$RunID.example.test",
            User                    => "multismtp-oauth-user-$RunID",
            AuthMethod              => 'XOAUTH2',
            OAuth2FunctionalAccount => $FunctionalAccountName,
            Email                   => $OAuthEmail,
        );
        my %OAuthProfile = $SMTPObject->SMTPGetForAddress( Address => $OAuthEmail, Valid => 1 );
        $Self->True( $OAuthProfile{ID}, 'OAuth account is added through the admin page' );
        push @SMTPIDs, $OAuthProfile{ID};
        $Self->Is( $OAuthProfile{AuthMethod}, 'XOAUTH2', 'admin save stores the selected OAuth method' );
        $Self->Is( $OAuthProfile{OAuth2FunctionalAccount}, $FunctionalAccountName, 'admin save stores the OAuth functional account' );

        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP;Subaction=Edit;ID=$OAuthProfile{ID}");
        $Self->Is( $Selenium->find_element( '#AuthMethod', 'css' )->get_value(), 'XOAUTH2', 'edit restores the stored OAuth method' );
        $Self->Is(
            $Selenium->find_element( '#OAuth2FunctionalAccount', 'css' )->get_value(),
            $FunctionalAccountName,
            'edit restores the OAuth functional account',
        );
        $Selenium->InputFieldValueSet( Element => '#AuthMethod', Value => 'OAUTHBEARER' );
        $Selenium->find_element( 'form.Validate button[type=submit]', 'css' )->VerifiedClick();
        %OAuthProfile = $SMTPObject->SMTPGet( ID => $OAuthProfile{ID} );
        $Self->Is( $OAuthProfile{AuthMethod}, 'OAUTHBEARER', 'admin edit saves OAUTHBEARER' );
        $Self->Is( $OAuthProfile{OAuth2FunctionalAccount}, $FunctionalAccountName, 'admin edit retains the selected OAuth account' );

        my $AnonymousEmail = $SystemAddresses{Anonymous};
        $AddProfile->(
            Host      => "multismtp-anonymous-$RunID.example.test",
            Anonymous => 1,
            Email     => $AnonymousEmail,
        );
        my %AnonymousProfile = $SMTPObject->SMTPGetForAddress( Address => $AnonymousEmail, Valid => 1 );
        $Self->True( $AnonymousProfile{ID}, 'Anonymous profile is added without user or password' );
        push @SMTPIDs, $AnonymousProfile{ID};
        $Self->Is( $AnonymousProfile{User}, '', 'Anonymous profile stores an empty username' );
        $Self->Is( $AnonymousProfile{PasswordDecrypted}, '', 'Anonymous profile stores an empty password' );
        $Selenium->VerifiedGet("${ScriptAlias}index.pl?Action=AdminMultiSMTP;Subaction=Edit;ID=$AnonymousProfile{ID}");
        $Self->True( $Selenium->find_element( '#Anonymous', 'css' )->is_selected(), 'edit restores Anonymous mode' );
    }
);

$Cleanup->();
$Self->DoneTesting();

