# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2011 - 2021 Perl-Services.de
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

package Kernel::Modules::AdminMultiSMTP;

use strict;
use warnings;

use Kernel::Language qw(Translatable);

our @ObjectDependencies = qw(
    Kernel::System::MultiSMTP
    Kernel::System::Valid
    Kernel::System::Web::Request
    Kernel::Output::HTML::Layout
    Kernel::System::OpenIDConnect::FunctionalAccounts
    Kernel::Config
    Kernel::System::Log
);

sub new {
    my ( $Type, %Param ) = @_;

    my $Self = {%Param};
    bless( $Self, $Type );

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $SMTPObject   = $Kernel::OM->Get('Kernel::System::MultiSMTP');

    my %GetParam;
    for my $Name (qw(ID Host User PasswordDecrypted Type ValidID Port Comments Anonymous AuthMethod OAuth2FunctionalAccount)) {
        my $Value = $ParamObject->GetParam( Param => $Name );
        $GetParam{$Name} = defined $Value ? $Value : '';
    }
    $GetParam{Emails} = [ $ParamObject->GetArray( Param => 'Emails' ) ];

    if ( $Self->{Subaction} eq 'Add' ) {
        return $Self->_FormScreen(
            Mode      => 'Add',
            Subaction => 'Save',
        );
    }
    elsif ( $Self->{Subaction} eq 'Edit' ) {
        return $LayoutObject->ErrorScreen() if !$GetParam{ID};
        return $Self->_FormScreen(
            ID        => $GetParam{ID},
            Mode      => 'Edit',
            LoadData  => 1,
            Subaction => 'Update',
        );
    }
    elsif ( $Self->{Subaction} eq 'Save' ) {
        $LayoutObject->ChallengeTokenCheck();

        delete $GetParam{ID};
        $GetParam{AuthMethod} ||= 'Basic';
        if ( $GetParam{Anonymous} ) {
            $GetParam{User}              = '';
            $GetParam{PasswordDecrypted} = '';
        }

        my $Errors = $SMTPObject->SMTPValidate(
            %GetParam,
            Password => $GetParam{PasswordDecrypted},
            UserID   => $Self->{UserID},
        );
        return $Self->_FormScreen(
            %GetParam,
            Mode       => 'Add',
            Subaction  => 'Save',
            Errors     => $Errors,
            NotifyError => 1,
        ) if %$Errors;

        my $Success = $SMTPObject->SMTPAdd(
            %GetParam,
            Password => $GetParam{PasswordDecrypted},
            UserID   => $Self->{UserID},
        );
        return $LayoutObject->Redirect( OP => 'Action=AdminMultiSMTP' ) if $Success;

        return $Self->_FormScreen(
            %GetParam,
            Mode        => 'Add',
            Subaction   => 'Save',
            Errors      => { Account => 1 },
            NotifyError => 1,
        );
    }
    elsif ( $Self->{Subaction} eq 'Update' ) {
        $LayoutObject->ChallengeTokenCheck();

        my %Current = $SMTPObject->SMTPGet( ID => $GetParam{ID} );
        return $LayoutObject->ErrorScreen() if !%Current;

        $GetParam{AuthMethod} ||= 'Basic';
        if ( $GetParam{Anonymous} ) {
            $GetParam{User}              = '';
            $GetParam{PasswordDecrypted} = '';
        }

        my $PasswordRequired = 1;
        if (
            $GetParam{AuthMethod} eq 'Basic'
            && !$GetParam{Anonymous}
            && ( $Current{AuthMethod} || 'Basic' ) eq 'Basic'
            && defined $Current{User}
            && $Current{User} =~ /\S/
            && defined $Current{PasswordDecrypted}
            && $Current{PasswordDecrypted} ne ''
            && $GetParam{PasswordDecrypted} eq ''
            )
        {
            $PasswordRequired = 0;
        }

        my $Errors = $SMTPObject->SMTPValidate(
            %GetParam,
            Password         => $GetParam{PasswordDecrypted},
            PasswordRequired => $PasswordRequired,
            UserID           => $Self->{UserID},
        );
        if ( %$Errors ) {
            return $Self->_FormScreen(
                %GetParam,
                Mode                => 'Edit',
                Subaction           => 'Update',
                Errors              => $Errors,
                NotifyError         => 1,
                OriginalAuthMethod  => $Current{AuthMethod} || 'Basic',
                PasswordPresent     => $Current{PasswordDecrypted} ? 1 : 0,
            );
        }

        my $Update = $SMTPObject->SMTPUpdate(
            %GetParam,
            Password => $GetParam{PasswordDecrypted},
            UserID   => $Self->{UserID},
        );
        return $LayoutObject->Redirect( OP => 'Action=AdminMultiSMTP' ) if $Update;

        return $Self->_FormScreen(
            %GetParam,
            Mode                => 'Edit',
            Subaction           => 'Update',
            Errors              => { Account => 1 },
            NotifyError         => 1,
            OriginalAuthMethod  => $Current{AuthMethod} || 'Basic',
            PasswordPresent     => $Current{PasswordDecrypted} ? 1 : 0,
        );
    }
    elsif ( $Self->{Subaction} eq 'Delete' ) {
        return $LayoutObject->ErrorScreen() if $ParamObject->RequestMethod() ne 'POST';

        $LayoutObject->ChallengeTokenCheck();
        return $LayoutObject->ErrorScreen() if !$SMTPObject->SMTPDelete( ID => $GetParam{ID} );

        return $LayoutObject->Redirect( OP => 'Action=AdminMultiSMTP' );
    }

    return $Self->_FormScreen( Mode => 'List' );
}

sub _FormScreen {
    my ( $Self, %Param ) = @_;

    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $NotifyError  = delete $Param{NotifyError};

    my $Output = $LayoutObject->Header();
    $Output .= $LayoutObject->NavigationBar();
    $Output .= $LayoutObject->Notify( Priority => 'Error' ) if $NotifyError;
    $Output .= $Self->_MaskSMTPForm(%Param);
    $Output .= $LayoutObject->Footer();

    return $Output;
}

sub _MaskSMTPForm {
    my ( $Self, %Param ) = @_;

    my $SMTPObject   = $Kernel::OM->Get('Kernel::System::MultiSMTP');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');
    my $ValidObject  = $Kernel::OM->Get('Kernel::System::Valid');

    for my $Field ( keys %{ $Param{Errors} || {} } ) {
        $Param{ $Field . 'Invalid' } = 'ServerError';
    }

    my %SMTP;
    if ( $Param{Mode} eq 'Edit' && $Param{LoadData} ) {
        %SMTP = $SMTPObject->SMTPGet( ID => $Param{ID} );
        return $LayoutObject->ErrorScreen() if !%SMTP;
        $Param{$_} = $SMTP{$_} for grep { !exists $Param{$_} } keys %SMTP;
        $Param{OriginalAuthMethod} = $SMTP{AuthMethod} || 'Basic';
        $Param{PasswordPresent} = $SMTP{PasswordDecrypted} ? 1 : 0;
        if ( $Param{AuthMethod} eq 'Basic' && !$Param{User} && !$Param{PasswordPresent} ) {
            $Param{Anonymous} = 1;
        }
    }

    $Param{AuthMethod} ||= 'Basic';
    $Param{Port} = 25 if !defined $Param{Port} || $Param{Port} eq '';
    $Param{Emails} = $SMTP{Emails} || [] if ref $Param{Emails} ne 'ARRAY' || !@{ $Param{Emails} };

    my %SelectedAddresses = map { $_ => 1 } @{ $Param{Emails} || [] };
    my %SystemAddresses = $SMTPObject->SystemAddressList(%SelectedAddresses);

    for my $ConfigKey ( qw/AdminEmail NotificationSenderEmail PostMaster::PreFilterModule::NewTicketReject::Sender/ ) {
        my $Mail = $ConfigObject->Get($ConfigKey);
        next if !$Mail || $SystemAddresses{$Mail};
        $SystemAddresses{$Mail} = $Mail . ' (' . $ConfigKey . ')';
    }

    $Param{EmailsSelect} = $LayoutObject->BuildSelection(
        Data       => \%SystemAddresses,
        Name       => 'Emails',
        Size       => 5,
        Class      => 'Modernize Validate_Required ' . ( $Param{Errors}->{Emails} ? 'ServerError' : '' ),
        Multiple   => 1,
        SelectedID => $Param{Emails} || [],
        HTMLQuote  => 1,
    );

    $Param{TypeSelect} = $LayoutObject->BuildSelection(
        Data => {
            SMTP    => 'SMTP',
            SMTPS   => 'SMTP/S',
            SMTPTLS => 'SMTPTLS',
        },
        Name       => 'Type',
        Size       => 1,
        SelectedID => $Param{Type},
        HTMLQuote  => 1,
        Class      => 'Modernize ' . ( $Param{Errors}->{Type} ? 'ServerError' : '' ),
    );

    $Param{AuthMethodSelect} = $LayoutObject->BuildSelection(
        Data => {
            Basic       => 'Basic',
            XOAUTH2     => 'XOAUTH2',
            OAUTHBEARER => 'OAUTHBEARER',
        },
        Name       => 'AuthMethod',
        ID         => 'AuthMethod',
        SelectedID => $Param{AuthMethod},
        HTMLQuote  => 1,
        Class      => 'Modernize ' . ( $Param{Errors}->{AuthMethod} ? 'ServerError' : '' ),
    );

    my $OAuthAccounts = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->GetAccounts();
    my %OAuthAccountNames = ( '' => Translatable('Select an account'), map { $_->{Name} => $_->{Name} } @$OAuthAccounts );
    $Param{OAuth2FunctionalAccountSelect} = $LayoutObject->BuildSelection(
        Data       => \%OAuthAccountNames,
        Name       => 'OAuth2FunctionalAccount',
        ID         => 'OAuth2FunctionalAccount',
        SelectedID => $Param{OAuth2FunctionalAccount},
        HTMLQuote  => 1,
        Class      => 'Modernize ' . ( $Param{Errors}->{OAuth2FunctionalAccount} ? 'ServerError' : '' ),
    );

    my $ValidID = $ValidObject->ValidLookup( Valid => 'valid' );
    $Param{ValidSelect} = $LayoutObject->BuildSelection(
        Data       => { $ValidObject->ValidList() },
        Name       => 'ValidID',
        Size       => 1,
        SelectedID => $Param{ValidID} || $ValidID || 1,
        HTMLQuote  => 1,
        Class      => 'Modernize ' . ( $Param{Errors}->{ValidID} ? 'ServerError' : '' ),
    );

    $Param{AnonymousChecked} = $Param{Anonymous} ? 'checked="checked"' : '';
    $Param{PasswordRequired} = 1
        if $Param{AuthMethod} eq 'Basic'
        && !$Param{Anonymous}
        && ( !$Param{PasswordPresent} || ( $Param{OriginalAuthMethod} || 'Basic' ) ne 'Basic' );
    $Param{PasswordRequired} ||= 0;
    $Param{PasswordPlaceholder} = $Param{PasswordPresent}
        ? Translatable('Leave blank to keep the current password.')
        : '';

    # Passwords are accepted on POST but never sent back to the browser.
    delete @Param{qw(Password PasswordDecrypted Encrypted)};
    delete $Param{LoadData};

    if ( $Param{Mode} eq 'List' ) {
        my %SMTPList = $SMTPObject->SMTPList();

        if ( !%SMTPList ) {
            $LayoutObject->Block( Name => 'NoSMTPFound' );
        }

        for my $ID ( sort { $a <=> $b } keys %SMTPList ) {
            my %Data = $SMTPObject->SMTPGet( ID => $ID );
            $Data{EmailString} = join ', ', @{ $Data{Emails} || [] };
            $Data{AuthString} = $Data{AuthMethod} || 'Basic';
            $Data{AuthString} .= ' (' . $Data{OAuth2FunctionalAccount} . ')' if $Data{OAuth2FunctionalAccount};
            $Data{Valid} = $ValidObject->ValidLookup( ValidID => $Data{ValidID} );
            $Data{Creator} = $Kernel::OM->Get('Kernel::System::User')->UserLookup( UserID => $Data{CreateBy} );
            delete @Data{qw(Password PasswordDecrypted Encrypted)};

            $LayoutObject->Block(
                Name => 'SMTPRow',
                Data => \%Data,
            );
        }
    }

    $Param{Subaction} ||= $Param{Mode} eq 'Add' ? 'Save' : 'Update';
    my $TemplateFile = $Param{Mode} eq 'List' ? 'AdminMultiSMTPList' : 'AdminMultiSMTPForm';

    return $LayoutObject->Output(
        TemplateFile => $TemplateFile,
        Data         => { %Param },
    );
}

1;
