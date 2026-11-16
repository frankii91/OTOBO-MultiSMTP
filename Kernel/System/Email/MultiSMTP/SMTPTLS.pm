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

package Kernel::System::Email::MultiSMTP::SMTPTLS;

use strict;
use warnings;

use parent 'Kernel::System::Email::MultiSMTP::SMTP';
use IO::Socket::SSL ();

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Log',
);

sub _Connect {
    my ( $Self, %Param ) = @_;

    $Param{SMTPPort} ||= 587;
    my $SMTP = $Self->SUPER::_Connect(%Param);
    return if !$SMTP;

    my $SSLVerifyMode = $Kernel::OM->Get('Kernel::Config')->Get('SendmailModule::SSLVerifyMode')
        // IO::Socket::SSL::SSL_VERIFY_NONE();

    # A failed STARTTLS must never continue with authentication or message data in cleartext.
    if ( !$SMTP->starttls( SSL_verify_mode => $SSLVerifyMode ) ) {
        $SMTP->quit();
        return;
    }

    return $SMTP;
}

1;
