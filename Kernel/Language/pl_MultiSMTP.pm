package Kernel::Language::pl_MultiSMTP;

use strict;
use warnings;
use utf8;

sub Data {
    my $Self = shift;
    my $Lang = $Self->{Translation};

    $Lang->{'SMTP settings'} = 'Konta SMTP';
    $Lang->{'Manage SMTP settings.'} = 'Zarządzanie kontami SMTP.';
    $Lang->{'SMTP Management'} = 'Konta SMTP';
    $Lang->{'Add SMTP'} = 'Dodaj konto SMTP';
    $Lang->{'Add/Change SMTP'} = 'Dodaj lub edytuj konto SMTP';
    $Lang->{'Anonymous SMTP'} = 'SMTP bez uwierzytelniania';
    $Lang->{'Emails'} = 'Adresy nadawców';
    $Lang->{'Creator'} = 'Utworzył';
    $Lang->{'OAuth functional account'} = 'Konto funkcyjne OAuth';
    $Lang->{'Leave blank to keep the current password.'} = 'Pozostaw puste, aby zachować obecne hasło.';
    $Lang->{'A password is required for this account.'} = 'To konto wymaga hasła.';
    $Lang->{'Please enter a valid port.'} = 'Podaj prawidłowy numer portu.';
    $Lang->{'Please select a valid transport.'} = 'Wybierz prawidłowy sposób połączenia.';
    $Lang->{'Please select a valid authentication method.'} = 'Wybierz prawidłowy sposób uwierzytelniania.';
    $Lang->{'Please select a valid OAuth functional account.'} = 'Wybierz prawidłowe konto funkcyjne OAuth.';
    $Lang->{'Select at least one email address.'} = 'Wybierz co najmniej jeden adres nadawcy.';
    $Lang->{'Do you really want to delete this SMTP account?'} = 'Czy na pewno chcesz usunąć to konto SMTP?';
}

1;
