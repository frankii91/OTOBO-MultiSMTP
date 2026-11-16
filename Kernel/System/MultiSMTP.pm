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

package Kernel::System::MultiSMTP;

use strict;
use warnings;

our $VERSION = 0.3;

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DB',
    'Kernel::System::Encode',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::OpenIDConnect::FunctionalAccounts',
    'Kernel::System::Time',
    'Kernel::System::User',
    'Kernel::System::Valid',
);

=head1 NAME

Kernel::System::MultiSMTP - backend for product news

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create an object

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    my $HasCBC = 1;
    eval{ require Crypt::CBC; 1; } or $HasCBC = 0;

    my $HasDES = 1;
    eval{ require Crypt::DES; 1; } or $HasDES = 0;

    $Self->{UseEncryption} = 0;
    if ( $HasCBC && $HasDES ) {
        $Self->{UseEncryption} = 1;
    }

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    $Self->{EncryptionKey}    = $ConfigObject->Get( 'MultiSMTP::EncryptionKey' ) || 'Key';
    $Self->{EncryptionSalt}   = $ConfigObject->Get( 'MultiSMTP::Salt' )          || 'Salt';
    $Self->{EncryptionModule} = 'Crypt::DES';
    
    return $Self;
}

=item SMTPValidate()

validates data before creating or changing an SMTP account

=cut

sub SMTPValidate {
    my ( $Self, %Param ) = @_;

    my %Errors;
    my %AllowedType = map { $_ => 1 } qw(SMTP SMTPS SMTPTLS);
    my %AllowedAuth = map { $_ => 1 } qw(Basic XOAUTH2 OAUTHBEARER);

    $Param{AuthMethod} ||= 'Basic';
    my $PasswordRequired = defined $Param{PasswordRequired} ? $Param{PasswordRequired} : 1;

    $Errors{Host} = 1 if !defined $Param{Host} || $Param{Host} !~ /\S/;
    $Errors{Type} = 1 if !$AllowedType{ $Param{Type} // '' };
    $Errors{AuthMethod} = 1 if !$AllowedAuth{ $Param{AuthMethod} };
    $Errors{Port} = 1 if !defined $Param{Port} || $Param{Port} !~ /\A\d+\z/ || $Param{Port} < 1 || $Param{Port} > 65535;
    $Errors{ValidID} = 1 if !$Param{ValidID} || !$Kernel::OM->Get('Kernel::System::Valid')->ValidLookup(
        ValidID => $Param{ValidID},
    );
    $Errors{UserID} = 1 if !defined $Param{UserID} || $Param{UserID} !~ /\A\d+\z/ || !$Param{UserID};
    $Errors{ID} = 1 if defined $Param{ID} && $Param{ID} ne '' && ( $Param{ID} !~ /\A\d+\z/ || !$Param{ID} );

    if ( $AllowedAuth{ $Param{AuthMethod} } ) {
        if ( $Param{AuthMethod} eq 'Basic' ) {
            if ( !$Param{Anonymous} ) {
                $Errors{User} = 1 if !defined $Param{User} || $Param{User} !~ /\S/;
                $Errors{Password} = 1
                    if $PasswordRequired && ( !defined $Param{Password} || $Param{Password} eq '' );
            }
        }
        else {
            $Errors{Anonymous} = 1 if $Param{Anonymous};
            $Errors{User} = 1 if !defined $Param{User} || $Param{User} !~ /\S/;
            if ( !defined $Param{OAuth2FunctionalAccount} || $Param{OAuth2FunctionalAccount} !~ /\S/ ) {
                $Errors{OAuth2FunctionalAccount} = 1;
            }
            elsif ( !$Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->GetAccount(
                Name => $Param{OAuth2FunctionalAccount},
            ) ) {
                $Errors{OAuth2FunctionalAccount} = 1;
            }
        }
    }

    my $Emails = ref $Param{Emails} eq 'ARRAY' ? $Param{Emails} : [ defined $Param{Emails} ? $Param{Emails} : () ];
    my %Seen;
    if ( !@$Emails ) {
        $Errors{Emails} = 1;
    }
    else {
        for my $Address (@$Emails) {
            if ( !defined $Address || $Address !~ /\S/ || $Seen{ lc $Address }++ ) {
                $Errors{Emails} = 1;
                last;
            }
        }
        $Errors{Emails} = 1 if !$Errors{Emails} && !$Self->_SMTPAddressMappingsUnique(
            Emails => $Emails,
            ID     => $Param{ID},
        );
    }

    return \%Errors;
}

sub _SMTPAddressMappingsUnique {
    my ( $Self, %Param ) = @_;

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    for my $Address ( @{ $Param{Emails} } ) {
        my $SQL = 'SELECT smtp_id FROM ps_multi_smtp_address WHERE LOWER(address) = LOWER(?)';
        my @Bind = ( \$Address );
        if ( $Param{ID} ) {
            $SQL .= ' AND smtp_id <> ?';
            push @Bind, \$Param{ID};
        }

        return if !$DBObject->Prepare(
            SQL   => $SQL,
            Bind  => \@Bind,
            Limit => 1,
        );

        return if $DBObject->FetchrowArray();
    }

    return 1;
}

sub _SMTPInsertID {
    my ( $Self ) = @_;

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');
    my %SQL = (
        mysql      => 'SELECT LAST_INSERT_ID()',
        postgresql => "SELECT currval(pg_get_serial_sequence('ps_multi_smtp', 'id'))",
        oracle     => 'SELECT SE_PS_MULTI_SMTP.currval FROM dual',
        mssql      => 'SELECT SCOPE_IDENTITY()',
        db2        => 'VALUES IDENTITY_VAL_LOCAL()',
    );
    my $SQL = $SQL{ $DBObject->GetDatabaseFunction('Type') // '' };

    return if !$SQL || !$DBObject->Prepare( SQL => $SQL );

    my ($ID) = $DBObject->FetchrowArray();
    return $ID;
}

=item SMTPAdd()

to add a news 

    my $ID = $SMTPObject->SMTPAdd(
        Host     => 'your.smtp.tld',
        User     => 'SMTPUser',
        Password => 'secret',
        Type     => 'SMTP', # or SMTP/S
        Comments => 'A comment about this entry',
        Port     => 25,
        Emails   => [ 'test@test.tld', 'otobo@test.tld' ],
        ValidID  => 1,
        UserID   => 123,
    );

=cut

sub SMTPAdd {
    my ( $Self, %Param ) = @_;

    my $LogObject = $Kernel::OM->Get('Kernel::System::Log');
    my $DBObject  = $Kernel::OM->Get('Kernel::System::DB');

    delete $Param{ID};
    if ( $Param{Anonymous} ) {
        $Param{User}     = '';
        $Param{Password} = '';
    }

    $Param{AuthMethod} ||= 'Basic';
    $Param{Emails} = ref $Param{Emails} eq 'ARRAY' ? $Param{Emails} : [ defined $Param{Emails} ? $Param{Emails} : () ];
    my $Errors = $Self->SMTPValidate(%Param);
    if ( %$Errors ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'Invalid SMTP account data: ' . join( ', ', sort keys %$Errors ),
        );
        return;
    }

    my $OAuth2FunctionalAccountID;
    my $Encrypted = 0;
    if ( $Param{AuthMethod} ne 'Basic' ) {
        my $OAuth2FunctionalAccount = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->GetAccount(
            Name => $Param{OAuth2FunctionalAccount},
        );
        $OAuth2FunctionalAccountID = $OAuth2FunctionalAccount->{AccountID};
        $Param{Password}          = '';
    }
    elsif ( $Self->{UseEncryption} ) {
        $Encrypted = 1;
        my $Cipher = Crypt::CBC->new(
            -key    => $Self->{EncryptionKey},
            -cipher => $Self->{EncryptionModule},
            -salt   => $Self->{EncryptionSalt},
        );

        $Param{Password} = $Cipher->encrypt_hex( $Param{Password} );
    }

    # insert new smtp
    return if !$DBObject->Do(
        SQL => 'INSERT INTO ps_multi_smtp '
            . '(host, smtp_user, smtp_password, encrypted, type, create_time, create_by, '
            . ' valid_id, change_time, change_by, port, comments, auth_method, oauth2_functional_account_id) '
            . 'VALUES (?, ?, ?, ?, ?, current_timestamp, ?, ?, current_timestamp, ?, ?, ?, ?, ?)',
        Bind => [
            \$Param{Host},
            \$Param{User},
            \$Param{Password},
            \$Encrypted,
            \$Param{Type},
            \$Param{UserID},
            \$Param{ValidID},
            \$Param{UserID},
            \$Param{Port},
            \$Param{Comments},
            \$Param{AuthMethod},
            \$OAuth2FunctionalAccountID,
        ],
    );

    my $ID = $Self->_SMTPInsertID();
    return if !$ID;

    # log notice
    $LogObject->Log(
        Priority => 'notice',
        Message  => "SMTP '$ID' created successfully ($Param{UserID})!",
    );

    # add mail addresses
    my $SQLMails = 'INSERT INTO ps_multi_smtp_address (smtp_id, address) VALUES (?, ?)';
    for my $Address ( @{ $Param{Emails} } ) {
        if ( !$DBObject->Do(
            SQL => $SQLMails,
            Bind => [ \$ID, \$Address ],
        ) ) {
            $Self->SMTPDelete( ID => $ID );
            return;
        }
    }

    return $ID;
}


=item SMTPUpdate()

to update news 

    my $Success = $SMTPObject->SMTPUpdate(
        ID       => 3,
        Host     => 'your.smtp.tld',
        User     => 'SMTPUser',
        Password => 'secret',
        Type     => 'SMTP', # or SMTP/S
        Port     => 25,
        Comments => 'A comment',
        Emails   => [ 'test@test.tld', 'otobo@test.tld' ],
        ValidID  => 1,
        UserID   => 123,
    );

=cut

sub SMTPUpdate {
    my ( $Self, %Param ) = @_;

    my $LogObject = $Kernel::OM->Get('Kernel::System::Log');
    my $DBObject  = $Kernel::OM->Get('Kernel::System::DB');

    return if !$Param{ID};
    my %Existing = $Self->SMTPGet( ID => $Param{ID} );
    return if !%Existing;
    $Existing{AuthMethod} ||= 'Basic';

    $Param{AuthMethod} ||= $Existing{AuthMethod};
    $Param{Emails} = ref $Param{Emails} eq 'ARRAY' ? $Param{Emails} : [ defined $Param{Emails} ? $Param{Emails} : () ];
    if ( $Param{Anonymous} ) {
        $Param{User}     = '';
        $Param{Password} = '';
    }

    $Param{PasswordRequired} = 1;
    if (
        $Param{AuthMethod} eq 'Basic'
        && !$Param{Anonymous}
        && $Existing{AuthMethod} eq 'Basic'
        && defined $Existing{User}
        && $Existing{User} =~ /\S/
        && defined $Existing{PasswordDecrypted}
        && $Existing{PasswordDecrypted} ne ''
        && ( !defined $Param{Password} || $Param{Password} eq '' )
        )
    {
        $Param{PasswordRequired} = 0;
    }

    my $Errors = $Self->SMTPValidate(%Param);
    if ( %$Errors ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'Invalid SMTP account data: ' . join( ', ', sort keys %$Errors ),
        );
        return;
    }

    my $OAuth2FunctionalAccountID;
    my $Encrypted = 0;
    if ( $Param{AuthMethod} ne 'Basic' ) {
        my $OAuth2FunctionalAccount = $Kernel::OM->Get('Kernel::System::OpenIDConnect::FunctionalAccounts')->GetAccount(
            Name => $Param{OAuth2FunctionalAccount},
        );
        $OAuth2FunctionalAccountID = $OAuth2FunctionalAccount->{AccountID};
        $Param{Password}           = '';
    }
    elsif ( !$Param{Anonymous} && ( !defined $Param{Password} || $Param{Password} eq '' ) ) {
        $Param{Password} = $Existing{Password};
        $Encrypted       = $Existing{Encrypted};
    }
    elsif ( $Self->{UseEncryption} ) {
        $Encrypted = 1;
        my $Cipher = Crypt::CBC->new(
            -key    => $Self->{EncryptionKey},
            -cipher => $Self->{EncryptionModule},
            -salt   => $Self->{EncryptionSalt},
        );

        $Param{Password} = $Cipher->encrypt_hex( $Param{Password} );
    }

    my %ExistingAddresses;
    return if !$DBObject->Prepare(
        SQL  => 'SELECT address FROM ps_multi_smtp_address WHERE smtp_id = ?',
        Bind => [ \$Param{ID} ],
    );
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ExistingAddresses{ lc $Row[0] } = $Row[0];
    }

    my $DBHandle        = $DBObject->{dbh};
    my $OwnTransaction  = $DBHandle->{AutoCommit};
    my $DBType          = $DBObject->GetDatabaseFunction('Type') // '';
    my %SavepointSQL = (
        mysql      => [ 'SAVEPOINT MultiSMTPUpdate', 'ROLLBACK TO SAVEPOINT MultiSMTPUpdate', 'RELEASE SAVEPOINT MultiSMTPUpdate' ],
        postgresql => [ 'SAVEPOINT MultiSMTPUpdate', 'ROLLBACK TO SAVEPOINT MultiSMTPUpdate', 'RELEASE SAVEPOINT MultiSMTPUpdate' ],
        oracle     => [ 'SAVEPOINT MultiSMTPUpdate', 'ROLLBACK TO MultiSMTPUpdate', undef ],
        mssql      => [ 'SAVE TRANSACTION MultiSMTPUpdate', 'ROLLBACK TRANSACTION MultiSMTPUpdate', undef ],
        db2        => [ 'SAVEPOINT MultiSMTPUpdate ON ROLLBACK RETAIN CURSORS', 'ROLLBACK TO SAVEPOINT MultiSMTPUpdate', 'RELEASE SAVEPOINT MultiSMTPUpdate' ],
    );
    my $Savepoint = $SavepointSQL{$DBType};

    if ($OwnTransaction) {
        return if !$DBObject->BeginWork();
    }
    else {
        return if !$Savepoint || !$DBObject->Do( SQL => $Savepoint->[0] );
    }

    my $Rollback = sub {
        my $Success = $OwnTransaction
            ? $DBObject->Rollback()
            : $DBObject->Do( SQL => $Savepoint->[1] );

        if ( !$Success ) {
            $LogObject->Log(
                Priority => 'error',
                Message  => 'Unable to roll back SMTP account update.',
            );
        }
        if ( !$OwnTransaction && $Savepoint->[2] ) {
            $DBObject->Do( SQL => $Savepoint->[2] );
        }
    };

    for my $Address ( @{ $Param{Emails} } ) {
        next if $ExistingAddresses{ lc $Address };

        if ( !$DBObject->Do(
            SQL  => 'INSERT INTO ps_multi_smtp_address (smtp_id, address) VALUES (?, ?)',
            Bind => [ \$Param{ID}, \$Address ],
        ) ) {
            $Rollback->();
            return;
        }
    }

    if ( !$DBObject->Do(
        SQL => 'UPDATE ps_multi_smtp SET host = ?, smtp_user = ?, smtp_password = ?, type = ?, port = ?, '
            . 'encrypted = ?, valid_id = ?, change_time = current_timestamp, change_by = ?, '
            . 'comments = ?, auth_method = ?, oauth2_functional_account_id = ? '
            . 'WHERE id = ?',
        Bind => [
            \$Param{Host},
            \$Param{User},
            \$Param{Password},
            \$Param{Type},
            \$Param{Port},
            \$Encrypted,
            \$Param{ValidID},
            \$Param{UserID},
            \$Param{Comments},
            \$Param{AuthMethod},
            \$OAuth2FunctionalAccountID,
            \$Param{ID},
        ],
    ) ) {
        $Rollback->();
        return;
    }

    my $EmailPlaceholders = join ', ', map { 'LOWER(?)' } @{ $Param{Emails} };
    my @DeleteBind        = ( \$Param{ID}, map { \$_ } @{ $Param{Emails} } );
    if ( !$DBObject->Do(
        SQL  => 'DELETE FROM ps_multi_smtp_address WHERE smtp_id = ? AND LOWER(address) NOT IN (' . $EmailPlaceholders . ')',
        Bind => \@DeleteBind,
    ) ) {
        $Rollback->();
        return;
    }

    my $CommitSuccess = $OwnTransaction
        ? $DBHandle->commit()
        : ( !$Savepoint->[2] || $DBObject->Do( SQL => $Savepoint->[2] ) );
    if ( !$CommitSuccess ) {
        $Rollback->();
        return;
    }

    return 1;
}

=item SMTPGet()

returns a hash with news data

    my %SMTPData = $SMTPObject->SMTPGet( ID => 2 );

This returns something like:

    %SMTPData = (
        ID         => 3,
        Host       => 'your.smtp.tld',
        User       => 'SMTPUser',
        Password   => 'encrypted',
        PasswordDecrypted   => 'secret',
        Comments   => 'A comment',
        Type       => 'SMTP', # or SMTP/S
        Emails     => [ 'test@test.tld', 'otobo@test.tld' ],
        CreateTime => '2010-04-07 15:41:15',
        ChangeTime => '2010-04-07 15:41:15',
        CreateBy   => 123,
        ChangeBy   => 123,
    );

=cut

sub SMTPGet {
    my ( $Self, %Param ) = @_;

    my $LogObject = $Kernel::OM->Get('Kernel::System::Log');
    my $DBObject  = $Kernel::OM->Get('Kernel::System::DB');

    # check needed stuff
    if ( !$Param{ID} ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'Need ID!',
        );
        return;
    }

    # sql
    return if !$DBObject->Prepare(
        SQL => 'SELECT smtp.id, smtp.host, smtp.smtp_user, smtp.smtp_password, smtp.type, smtp_address.address, smtp.encrypted, '
            . 'smtp.change_time, smtp.change_by, smtp.create_time, smtp.create_by, smtp.valid_id, smtp.port, smtp.comments, '
            . 'smtp.auth_method, functional_account.name '
            . 'FROM ps_multi_smtp smtp '
            . 'LEFT JOIN ps_multi_smtp_address smtp_address ON smtp.id = smtp_address.smtp_id '
            . 'LEFT JOIN oidc_functional_accounts functional_account ON smtp.oauth2_functional_account_id = functional_account.id '
            . 'WHERE smtp.id = ? ORDER BY smtp_address.id',
        Bind  => [ \$Param{ID} ],
    );

    my %SMTP;
    while ( my @Data = $DBObject->FetchrowArray() ) {
        $SMTP{ID}         = $Data[0];
        $SMTP{Host}       = $Data[1];
        $SMTP{User}       = $Data[2];
        $SMTP{Password}   = $Data[3];
        $SMTP{Type}       = $Data[4];
        $SMTP{Encrypted}  = $Data[6];
        $SMTP{ChangeTime} = $Data[7];
        $SMTP{ChangeBy}   = $Data[8];
        $SMTP{CreateTime} = $Data[9];
        $SMTP{CreateBy}   = $Data[10];
        $SMTP{ValidID}    = $Data[11];
        $SMTP{Port}       = $Data[12];
        $SMTP{Comments}   = $Data[13];
        $SMTP{AuthMethod} = $Data[14] || 'Basic';
        $SMTP{OAuth2FunctionalAccount} = $Data[15];

        push @{ $SMTP{Emails} }, $Data[5] if defined $Data[5];
    }

    my $UserObject  = $Kernel::OM->Get('Kernel::System::User');
    my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');

    if ( %SMTP ) {
        $SMTP{Emails} ||= [];
        $SMTP{Valid}   = $ValidObject->ValidLookup( ValidID => $SMTP{ValidID} );
        $SMTP{Creator} = $UserObject->UserLookup( UserID => $SMTP{CreateBy} );
        $SMTP{Changer} = $UserObject->UserLookup( UserID => $SMTP{ChangeBy} );

        if ( $SMTP{Encrypted} ) {
            my $Cipher = Crypt::CBC->new(
                -key    => $Self->{EncryptionKey},
                -cipher => $Self->{EncryptionModule},
                -salt   => $Self->{EncryptionSalt},
            );

            $SMTP{PasswordDecrypted} = $Cipher->decrypt_hex( $SMTP{Password} );
        }
        else {
            $SMTP{PasswordDecrypted} = $SMTP{Password};
        }
    }

    return %SMTP;
}

=item SMTPDelete()

deletes a news entry. Returns 1 if it was successful, undef otherwise.

    my $Success = $SMTPObject->SMTPDelete(
        ID => 123,
    );

=cut

sub SMTPDelete {
    my ( $Self, %Param ) = @_;

    my $LogObject = $Kernel::OM->Get('Kernel::System::Log');
    my $DBObject  = $Kernel::OM->Get('Kernel::System::DB');

    # check needed stuff
    if ( !$Param{ID} ) {
        $LogObject->Log(
            Priority => 'error',
            Message  => 'Need ID!',
        );

        return;
    }

    $DBObject->Do(
        SQL  => 'DELETE FROM ps_multi_smtp_address WHERE smtp_id = ?',
        Bind => [ \$Param{ID} ],
    );

    return $DBObject->Do(
        SQL  => 'DELETE FROM ps_multi_smtp WHERE id = ?',
        Bind => [ \$Param{ID} ],
    );
}


=item SMTPList()

returns a hash of all news

    my %SMTPs = $SMTPObject->SMTPList();

the result looks like

    %SMTPs = (
        '1' => 'SMTP 1',
        '2' => 'Test SMTP',
    );

=cut

sub SMTPList {
    my ( $Self, %Param ) = @_;

    my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');
    my $DBObject    = $Kernel::OM->Get('Kernel::System::DB');

    my $Where = '';
    my @Bind;

    if ( $Param{Valid} ) {
        my $ValidID = $ValidObject->ValidLookup( Valid => 'valid' );
        $Where = 'WHERE valid_id = ?';
        @Bind  = ( \$ValidID );
    }

    # sql
    return if !$DBObject->Prepare(
        SQL  => "SELECT id, host FROM ps_multi_smtp $Where",
        Bind => \@Bind,
    );

    my %SMTP;
    while ( my @Data = $DBObject->FetchrowArray() ) {
        $SMTP{ $Data[0] } = $Data[1];
    }

    return %SMTP;
}

=item SMTPGetForAddress()

    my %SMTP = $Object->SMTPGetForAddress(
        Address => 'test@test.tld',
    );

=cut

sub SMTPGetForAddress {
    my ( $Self, %Param ) = @_;

    my $ValidObject = $Kernel::OM->Get('Kernel::System::Valid');
    my $LogObject   = $Kernel::OM->Get('Kernel::System::Log');
    my $DBObject    = $Kernel::OM->Get('Kernel::System::DB');
    my $UserObject  = $Kernel::OM->Get('Kernel::System::User');

    for my $Needed (qw(Address)) {
        if ( !$Param{$Needed} ) {
            $LogObject->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    my $ValidWhere = '';
    my @ValidBind;
    if ( $Param{Valid} ) {
        $ValidWhere = ' AND smtp.valid_id = ?';
        push @ValidBind, \"1";
    }

    return if !$DBObject->Prepare(
        SQL => 'SELECT smtp.id, smtp.host, smtp.smtp_user, smtp.smtp_password, smtp.type, smtp_address.address, smtp.encrypted, '
            . 'smtp.change_time, smtp.change_by, smtp.create_time, smtp.create_by, smtp.valid_id, smtp.port, smtp.comments, '
            . 'smtp.auth_method, functional_account.name '
            . 'FROM ps_multi_smtp smtp '
            . 'INNER JOIN ps_multi_smtp_address smtp_address ON smtp.id = smtp_address.smtp_id '
            . 'LEFT JOIN oidc_functional_accounts functional_account ON smtp.oauth2_functional_account_id = functional_account.id '
            . 'WHERE LOWER(smtp_address.address) = LOWER(?)' . $ValidWhere
            . ' ORDER BY smtp.id ASC, smtp_address.id ASC',
        Bind  => [ \$Param{Address}, @ValidBind ],
        Limit => 1,
    );

    my %SMTP;
    while ( my @Data = $DBObject->FetchrowArray() ) {
        %SMTP = (
            ID                       => $Data[0],
            Host                     => $Data[1],
            User                     => $Data[2],
            Password                 => $Data[3],
            Type                     => $Data[4],
            Email                    => $Data[5],
            Encrypted                => $Data[6],
            ChangeTime               => $Data[7],
            ChangeBy                 => $Data[8],
            CreateTime               => $Data[9],
            CreateBy                 => $Data[10],
            ValidID                  => $Data[11],
            Port                     => $Data[12],
            Comments                 => $Data[13],
            AuthMethod               => $Data[14] || 'Basic',
            OAuth2FunctionalAccount => $Data[15],
        );
        last;
    }

    if ( %SMTP ) {
        $SMTP{Valid}   = $ValidObject->ValidLookup( ValidID => $SMTP{ValidID} );
        $SMTP{Creator} = $UserObject->UserLookup( UserID => $SMTP{CreateBy} );
        $SMTP{Changer} = $UserObject->UserLookup( UserID => $SMTP{ChangeBy} );

        if ( $SMTP{Encrypted} ) {
            my $Cipher = Crypt::CBC->new(
                -key    => $Self->{EncryptionKey},
                -cipher => $Self->{EncryptionModule},
                -salt   => $Self->{EncryptionSalt},
            );

            $SMTP{PasswordDecrypted} = $Cipher->decrypt_hex( $SMTP{Password} );
        }
        else {
            $SMTP{PasswordDecrypted} = $SMTP{Password};
        }
    }

    return %SMTP;
}

=item SystemAddressList()

    my %List = $Object->SystemAddressList();

returns a list of all system addresses that are not already mapped to a SMTP.

=cut

sub SystemAddressList {
    my ( $Self, %Param ) = @_;

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    my $SQL = 'SELECT value0, value1 FROM system_address';

    return if !$DBObject->Prepare(
        SQL => $SQL,
    );

    my @Addresses;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        push @Addresses, { address => $Row[0], name => $Row[1] };
    }

    my %List;
    for my $Address ( @Addresses ) {
        my $Email = $Address->{address};
        next if !$Param{$Email} && $Self->SMTPGetForAddress( Address => $Email );
        $List{$Email} = sprintf "%s (%s)", $Email, $Address->{name};
    }

    return %List;
}

1;

=back

=head1 TERMS AND CONDITIONS

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut

