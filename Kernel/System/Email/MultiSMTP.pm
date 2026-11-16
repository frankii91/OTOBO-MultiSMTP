# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2013 - 2022 Perl-Services.de, http://perl-services.de
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

package Kernel::System::Email::MultiSMTP;

use strict;
use warnings;

use Email::Address::XS ();
our @ObjectDependencies = qw(
    Kernel::Config
    Kernel::System::Log
    Kernel::System::MultiSMTP
    Kernel::System::Email::SMTP
    Kernel::System::Email::SMTPS
    Kernel::System::Email::SMTPTLS
    Kernel::System::Email::MultiSMTP::SMTP
    Kernel::System::Email::MultiSMTP::SMTPS
    Kernel::System::Email::MultiSMTP::SMTPTLS
);

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    $Self->{Debug}   = $ConfigObject->Get( 'MultiSMTP::Debug' );

    return $Self;
}

sub Check {
    # The sending address, and therefore the SMTP account, is only known at Send().
    return ( Success => 1 );
}

sub Send {
    my ( $Self, %Param ) = @_;

    my $LogObject    = $Kernel::OM->Get('Kernel::System::Log');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $MSMTPObject  = $Kernel::OM->Get('Kernel::System::MultiSMTP');

    # check needed stuff
    for my $Needed (qw(Header Body)) {
        if ( !$Param{$Needed} ) {
            $LogObject->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return { Success => 0, ErrorMessage => "Need $Needed!" };
        }
    }

    if ( $Self->{Debug} ) {
        $LogObject->Log(
            Priority => 'debug',
            Message  => 'Header: ' . ${ $Param{Header} },
        );
    }

    my $UseSenderFromMail = $ConfigObject->Get('MultiSMTP::UseSenderFromMail');

    my $Sender = $Param{From};

    # Select the account independently of the SMTP envelope (which may be empty for bounces).
    if ( !$Param{From} || $UseSenderFromMail ) {
        my @FromHeaders = ${ $Param{Header} } =~ m{^From:[\t ]*([^\r\n]*(?:\r?\n[\t ]+[^\r\n]*)*)}gmi;
        return { Success => 0, ErrorMessage => 'Expected exactly one From header.' }
            if @FromHeaders != 1;
        $Sender = $FromHeaders[0];
        $Sender =~ s/\r?\n[\t ]+/ /g;
    }

    if ( $Self->{Debug} ) {
        $LogObject->Log(
            Priority => 'debug',
            Message  => 'From: ' . $Param{From},
        );
    }

    my $ErrorMessage = 'Error preparing to send message';
    if ( $Sender ) {
        my @Addresses = Email::Address::XS->parse($Sender);
        return { Success => 0, ErrorMessage => 'Expected one valid sender address.' }
            if @Addresses != 1 || !$Addresses[0]->is_valid;
        my $PlainFrom = $Addresses[0]->address;

        if ( defined $Param{From} && length $Param{From} ) {
            my @Envelope = Email::Address::XS->parse( $Param{From} );
            return { Success => 0, ErrorMessage => 'Invalid envelope sender.' }
                if @Envelope != 1 || !$Envelope[0]->is_valid;
            $Param{From} = $Envelope[0]->address;
        }

        my %SMTP = $MSMTPObject->SMTPGetForAddress(
            Address => $PlainFrom,
            Valid   => 1,
        );

        if ( $Self->{Debug} ) {
            $LogObject->Log(
                Priority => 'debug',
                Message  => 'From: ' . ( $PlainFrom // '' ) . ' // SMTP: ' . ( $SMTP{ID} // '' ),
            );
        }

        if ( %SMTP ) {
            $SMTP{Password} = $SMTP{PasswordDecrypted};
            return { Success => 0, ErrorMessage => 'Invalid SMTP transport.' }
                if ( $SMTP{Type} // '' ) !~ /\A(?:SMTP|SMTPS|SMTPTLS)\z/;

            if ( $Self->{Debug} && $Self->{Debug} == 2 ) {
                $LogObject->Log(
                    Priority => 'debug',
                    Message  => 'SMTP debugging enabled',
                );

                $SMTP{Debug} = 3;
            }

            my $Module = 'Kernel::System::Email::MultiSMTP::' . $SMTP{Type};
            # Never reuse a transport holding another account's credentials or OAuth token.
            my $SMTPObject = $Kernel::OM->Create( $Module, ObjectParams => \%SMTP );

            if ( $Self->{Debug} ) {
                $LogObject->Log(
                    Priority => 'debug',
                    Message  => "Use MultiSMTP $Module",
                );

                $LogObject->Log(
                    Priority => 'debug',
                    Message  => sprintf "Use SMTP %s/%s (%s)", $SMTP{Host}, $SMTP{User}, $SMTP{ID},
                );
            }

            return { Success => 0, ErrorMessage => 'Could not create SMTP transport.' }
                if !$SMTPObject;

            my $Success = $SMTPObject->Send( %Param );

            return $Success;
        }
        else{
            $ErrorMessage .= ": not found smtp for adress $PlainFrom";
        }
    }
    else{
        $ErrorMessage .= ': param From empty';
    }

    my $UseFallback = $ConfigObject->Get('MultiSMTP::UseFallback') // 1;

    if($UseFallback){
        # use standard SMTP module as fallback
        my $Module  = $ConfigObject->Get('MultiSMTP::Fallback');
        return { Success => 0, ErrorMessage => 'Invalid fallback SMTP transport.' }
            if ( $Module // '' ) !~ /\AKernel::System::Email::(?:SMTP|SMTPS|SMTPTLS)\z/;
        my ($Type) = $Module =~ /::(SMTP|SMTPS|SMTPTLS)\z/;
        my $Fallback = $Kernel::OM->Create(
            'Kernel::System::Email::MultiSMTP::' . $Type,
            ObjectParams => {
                Host                    => $ConfigObject->Get('SendmailModule::Host'),
                Port                    => $ConfigObject->Get('SendmailModule::Port'),
                User                    => $ConfigObject->Get('SendmailModule::AuthUser'),
                Password                => $ConfigObject->Get('SendmailModule::AuthPassword'),
                AuthMethod              => $ConfigObject->Get('SendmailModule::OAuth2Method'),
                OAuth2FunctionalAccount => $ConfigObject->Get('SendmailModule::OAuth2FunctionalAccount'),
            },
        );
        return $Fallback->Send(%Param);
    }
    else
    {
        return { Success => 0, ErrorMessage => $ErrorMessage };
    }

}

1;
