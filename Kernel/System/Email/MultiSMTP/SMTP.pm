# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Changes Copyright (C) 2011 - 2022 Perl-Services.de, http://perl-services.de
# Changes Copyright (C) 2017 WestDevTeam, http://westdev.by
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

package Kernel::System::Email::MultiSMTP::SMTP;

use strict;
use warnings;

use parent 'Kernel::System::Email::SMTP';

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Log',
    'Kernel::System::OpenIDConnect::TokenProvider',
);

sub Check {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # Core SMTP reads SysConfig at connection time. Scope the selected account to this call,
    # including exception paths, so other sends retain their own configuration.
    local $ConfigObject->{'SendmailModule::Host'} = $Self->{Host};
    local $ConfigObject->{'SendmailModule::Port'} = $Self->{Port};
    local $ConfigObject->{'SendmailModule::AuthUser'} = $Self->{User};
    local $ConfigObject->{'SendmailModule::AuthPassword'} = $Self->{Password};
    local $ConfigObject->{'SendmailModule::OAuth2Method'} = $Self->{AuthMethod} || 'Basic';
    local $ConfigObject->{'SendmailModule::OAuth2FunctionalAccount'} = $Self->{OAuth2FunctionalAccount} // '';

    return $Self->SUPER::Check(%Param);
}

sub _GetSMTPSafeWrapper {
    my ( $Self, %Param ) = @_;

    my $Wrapper = $Self->SUPER::_GetSMTPSafeWrapper(%Param);
    return sub {
        my ( $Operation, @Arguments ) = @_;
        return $Wrapper->( $Operation, @Arguments )
            if $Operation ne 'auth' && $Operation ne 'Otobo_OAuth2';

        # The core exception logger includes arguments; authentication arguments contain secrets.
        my $Result;
        eval { $Result = $Param{SMTP}->$Operation(@Arguments); 1 } or do {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "SMTP $Operation failed unexpectedly (authentication details hidden).",
            );
        };
        return $Result;
    };
}

1;
