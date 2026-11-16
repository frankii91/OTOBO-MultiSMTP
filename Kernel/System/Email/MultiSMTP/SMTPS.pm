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

package Kernel::System::Email::MultiSMTP::SMTPS;

use strict;
use warnings;

use parent 'Kernel::System::Email::MultiSMTP::SMTP';
use Kernel::System::Email::SMTPS ();

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::Log',
);

sub _Connect {
    my ( $Self, %Param ) = @_;

    return Kernel::System::Email::SMTPS::_Connect( $Self, %Param );
}

1;
