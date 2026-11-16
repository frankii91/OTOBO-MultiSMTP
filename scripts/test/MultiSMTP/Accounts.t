# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2019-2026 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

use v5.24;
use strict;
use warnings;
use utf8;

use Kernel::System::UnitTest::RegisterDriver;

our $Self;

$Kernel::OM->ObjectParamAdd(
    'Kernel::System::UnitTest::Helper' => {
        RestoreDatabase => 1,
    },
);
my $Helper      = $Kernel::OM->Get('Kernel::System::UnitTest::Helper');
my $SMTPObject  = $Kernel::OM->Get('Kernel::System::MultiSMTP');
my $DBObject    = $Kernel::OM->Get('Kernel::System::DB');
my $UserID      = 1;
my $ValidID     = $Kernel::OM->Get('Kernel::System::Valid')->ValidLookup( Valid => 'valid' );
my $TestID      = $Helper->GetRandomID();
my $EmailBasic  = "${TestID}-basic\@example.com";
my $EmailOAuth  = "${TestID}-oauth\@example.com";
my $EmailBearer = "${TestID}-bearer\@example.com";
my $EmailAnon   = "${TestID}-anon\@example.com";

my %Base = (
    Host    => 'smtp.example.com',
    User    => 'smtp-user',
    Type    => 'SMTP',
    Port    => 587,
    ValidID => $ValidID,
    UserID  => $UserID,
);

for my $Test (
    { Type => 'UNKNOWN', Expected => 'Type' },
    { AuthMethod => 'PLAIN', Expected => 'AuthMethod' },
    { Port => 0, Expected => 'Port' },
    { Port => 65536, Expected => 'Port' },
    { Port => '587smtp', Expected => 'Port' },
    { Emails => [], Expected => 'Emails' },
    { Emails => [''], Expected => 'Emails' },
    { User => '', Password => '', Expected => 'User' },
)
{
    my %TestData = %$Test;
    my $Expected = delete $TestData{Expected};
    my %Data = ( %Base, Password => 'secret', Emails => [$EmailBasic], AuthMethod => 'Basic', %TestData );
    my $Errors = $SMTPObject->SMTPValidate(%Data);

    $Self->True(
        $Errors->{$Expected},
        "SMTPValidate rejects invalid $Expected",
    );
}

my $BasicID = $SMTPObject->SMTPAdd(
    %Base,
    Password => 'basic-secret',
    Emails   => [$EmailBasic],
);
$Self->True( $BasicID, 'SMTPAdd creates a Basic account with the default auth method' );

my %Basic = $SMTPObject->SMTPGet( ID => $BasicID );
$Self->Is( $Basic{AuthMethod}, 'Basic', 'SMTPGet returns Basic auth method' );
$Self->Is( $Basic{PasswordDecrypted}, 'basic-secret', 'SMTPGet decrypts the legacy Basic password' );
$Self->IsDeeply( $Basic{Emails}, [$EmailBasic], 'SMTPGet returns associated email addresses' );

my $DuplicateAdd = $SMTPObject->SMTPAdd(
    %Base,
    ID       => $BasicID,
    Password => 'another-secret',
    Emails   => [$EmailBasic],
);
$Self->False( $DuplicateAdd, 'SMTPAdd ignores caller supplied IDs when checking duplicate address mappings' );

my %BasicForAddress = $SMTPObject->SMTPGetForAddress( Address => $EmailBasic, Valid => 1 );
$Self->Is( $BasicForAddress{ID}, $BasicID, 'SMTPGetForAddress returns the matching account' );
$Self->Is( $BasicForAddress{AuthMethod}, 'Basic', 'SMTPGetForAddress returns the authentication method' );
$Self->Is( $BasicForAddress{PasswordDecrypted}, 'basic-secret', 'SMTPGetForAddress returns the decrypted password' );

my $BasicUpdate = $SMTPObject->SMTPUpdate(
    ID       => $BasicID,
    %Base,
    Host     => 'smtp-updated.example.com',
    Password => '',
    Emails   => [$EmailBasic],
    AuthMethod => 'Basic',
);
$Self->True( $BasicUpdate, 'SMTPUpdate accepts a blank password when preserving an existing Basic credential' );

%Basic = $SMTPObject->SMTPGet( ID => $BasicID );
$Self->Is( $Basic{Host}, 'smtp-updated.example.com', 'SMTPUpdate saves account fields' );
$Self->Is( $Basic{PasswordDecrypted}, 'basic-secret', 'SMTPUpdate preserves the existing password' );

my $ProfileName = $Helper->GetRandomID();
my $FunctionalAccountName = $Helper->GetRandomID();
my $ProfileRepository = $Kernel::OM->Get('Kernel::System::OpenIDConnect::ProfileRepository');
my $ProfileAdded = $ProfileRepository->AddProfile(
    Name             => $ProfileName,
    ClientSettings   => {
        ClientSecret => 'unit-test-secret',
        ClientID     => 'unit-test-client',
        RedirectURI  => 'https://example.com/callback',
    },
    ProviderSettings => {
        OpenIDConfiguration => 'https://example.com/.well-known/openid-configuration',
        TTL                 => 60,
        SSLOptions          => { SSLVerifyHostname => 0, SSLVerifyMode => 0 },
    },
    UserID => $UserID,
    Valid  => 1,
);
$Self->True( $ProfileAdded, 'Create a local OIDC profile for OAuth account tests' );

my $Profile = $ProfileRepository->GetProfile( Name => $ProfileName );
my $FunctionalAccountAdded = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->SaveAccount(
    Name          => $FunctionalAccountName,
    OIDCProfileID => $Profile->{ProfileID},
    GrantType     => 'client_credentials',
    Scope         => 'openid email',
    Token         => 'unit-test-token',
    Valid         => 1,
    UserID        => $UserID,
);
$Self->True( $FunctionalAccountAdded, 'Create a local OIDC functional account' );

my $OAuthID = $SMTPObject->SMTPAdd(
    %Base,
    User                     => 'oauth-user',
    AuthMethod               => 'XOAUTH2',
    OAuth2FunctionalAccount  => $FunctionalAccountName,
    Password                 => '',
    Emails                   => [$EmailOAuth],
);
$Self->True( $OAuthID, 'SMTPAdd creates a passwordless XOAUTH2 account' );

my %OAuth = $SMTPObject->SMTPGet( ID => $OAuthID );
$Self->Is( $OAuth{AuthMethod}, 'XOAUTH2', 'SMTPGet returns XOAUTH2 auth method' );
$Self->Is( $OAuth{OAuth2FunctionalAccount}, $FunctionalAccountName, 'SMTPGet returns the OIDC functional account name' );
$Self->Is( $OAuth{PasswordDecrypted}, '', 'SMTPGet returns no password for OAuth accounts' );

my $BearerID = $SMTPObject->SMTPAdd(
    %Base,
    User                     => 'bearer-user',
    AuthMethod               => 'OAUTHBEARER',
    OAuth2FunctionalAccount  => $FunctionalAccountName,
    Password                 => '',
    Emails                   => [$EmailBearer],
);
$Self->True( $BearerID, 'SMTPAdd creates a passwordless OAUTHBEARER account' );

my %BearerForAddress = $SMTPObject->SMTPGetForAddress( Address => $EmailBearer, Valid => 1 );
$Self->Is( $BearerForAddress{AuthMethod}, 'OAUTHBEARER', 'SMTPGetForAddress returns OAUTHBEARER auth method' );
$Self->Is( $BearerForAddress{OAuth2FunctionalAccount}, $FunctionalAccountName, 'SMTPGetForAddress returns the OIDC functional account name' );

my $OAuthErrors = $SMTPObject->SMTPValidate(
    %Base,
    AuthMethod => 'XOAUTH2',
    User       => 'oauth-user',
    Emails     => [$EmailBearer],
    Password   => '',
);
$Self->True( $OAuthErrors->{OAuth2FunctionalAccount}, 'OAuth validation requires a configured functional account' );

my $AnonymousID = $SMTPObject->SMTPAdd(
    %Base,
    User      => '',
    Password  => '',
    Anonymous => 1,
    Emails    => [$EmailAnon],
);
$Self->True( $AnonymousID, 'SMTPAdd preserves anonymous SMTP accounts' );
my %Anonymous = $SMTPObject->SMTPGet( ID => $AnonymousID );
$Self->Is( $Anonymous{AuthMethod}, 'Basic', 'Anonymous SMTP defaults to Basic auth' );
$Self->Is( $Anonymous{User}, '', 'Anonymous SMTP has no user' );
$Self->Is( $Anonymous{PasswordDecrypted}, '', 'Anonymous SMTP has no password' );

my $AnonymousUpgradeWithoutPassword = $SMTPObject->SMTPUpdate(
    ID       => $AnonymousID,
    %Base,
    User     => 'authenticated-user',
    Password => '',
    Emails   => [$EmailAnon],
    AuthMethod => 'Basic',
);
$Self->False( $AnonymousUpgradeWithoutPassword, 'Cannot turn anonymous SMTP into authenticated SMTP without a password' );

my $AnonymousUpgrade = $SMTPObject->SMTPUpdate(
    ID       => $AnonymousID,
    %Base,
    User     => 'authenticated-user',
    Password => 'authenticated-secret',
    Emails   => [$EmailAnon],
    AuthMethod => 'Basic',
);
$Self->True( $AnonymousUpgrade, 'Anonymous SMTP can be converted when a password is provided' );
%Anonymous = $SMTPObject->SMTPGet( ID => $AnonymousID );
$Self->Is( $Anonymous{PasswordDecrypted}, 'authenticated-secret', 'The provided password is stored during conversion' );

my $DuplicateMappingAdded = $DBObject->Do(
    SQL  => 'INSERT INTO ps_multi_smtp_address (smtp_id, address) VALUES (?, ?)',
    Bind => [ \$OAuthID, \$EmailBasic ],
);
$Self->True( $DuplicateMappingAdded, 'Insert a legacy duplicate mapping for deterministic lookup coverage' );
my %DuplicateLookup = $SMTPObject->SMTPGetForAddress( Address => $EmailBasic, Valid => 1 );
$Self->Is( $DuplicateLookup{ID}, $BasicID, 'Duplicate address mappings resolve to the lowest SMTP ID' );

my $DuplicateErrors = $SMTPObject->SMTPValidate(
    %Base,
    Password => 'secret',
    Emails   => [$EmailBasic],
);
$Self->True( $DuplicateErrors->{Emails}, 'Validation rejects an address already mapped to another account' );

my $EmailReplacement = "${TestID}-replacement\@example.com";
my %BeforeRollback = $SMTPObject->SMTPGet( ID => $BasicID );
my $OriginalDo = \&Kernel::System::DB::Do;
my $FailedUpdate;
{
    no warnings 'redefine';
    local *Kernel::System::DB::Do = sub {
        my ( $Object, %Param ) = @_;
        return if $Param{SQL} =~ /^DELETE FROM ps_multi_smtp_address WHERE smtp_id = \? AND LOWER\(address\) NOT IN/;
        return $OriginalDo->( $Object, %Param );
    };

    $FailedUpdate = $SMTPObject->SMTPUpdate(
        ID         => $BasicID,
        %Base,
        Host       => 'smtp-failed-update.example.com',
        Password   => 'replacement-secret',
        Emails     => [$EmailReplacement],
        AuthMethod => 'Basic',
    );
}
$Self->False( $FailedUpdate, 'SMTPUpdate reports failure when address removal fails' );

%Basic = $SMTPObject->SMTPGet( ID => $BasicID );
$Self->Is( $Basic{Host}, $BeforeRollback{Host}, 'Failed SMTPUpdate rolls back account fields' );
$Self->Is( $Basic{PasswordDecrypted}, $BeforeRollback{PasswordDecrypted}, 'Failed SMTPUpdate rolls back credentials' );
$Self->IsDeeply( $Basic{Emails}, $BeforeRollback{Emails}, 'Failed SMTPUpdate rolls back address mappings' );

$Self->DoneTesting();
