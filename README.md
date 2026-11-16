# OTOBO-MultiSMTP

Sender-specific SMTP accounts for **OTOBO 11.1.x**. This fork continues
[Perl Services MultiSMTP](https://github.com/reneeb/opm-MultiSMTP/tree/otobo).
It does not claim compatibility with OTRS, Znuny, or older OTOBO versions.

Each profile has its own server, port, credentials, transport (SMTP, SMTPS,
or STARTTLS), and assigned sender addresses. Queues using different system
addresses can therefore use different SMTP accounts. Queues sharing an
address also share its SMTP profile. Incoming mail accounts remain separate.

## Configuration

1. Install the built `MultiSMTP-11.1.0.opm` through OTOBO Package Manager.
2. Open **Administration > SMTP settings** and assign the required system
   addresses to their SMTP accounts.
3. Set `SendmailModule` to `Kernel::System::Email::MultiSMTP` in System
   Configuration. Deploy the configuration and reload existing web/daemon
   processes when replacing an older version of the addon.

Basic authentication, anonymous relays, XOAUTH2, and OAUTHBEARER are supported.
OAuth profiles reference an existing OTOBO OAuth functional account; tokens
are obtained through the native OTOBO token provider. This addon does not
create or change provider-side OAuth clients.

`MultiSMTP::UseFallback` controls whether an address without a matching active
profile uses `MultiSMTP::Fallback` and the global SMTP settings. A matching
profile's authentication or delivery failure never triggers a second send
through another account. Disabling fallback makes unmapped senders fail.

By default the envelope sender selects the profile. Set
`MultiSMTP::UseSenderFromMail` to select by the message's From header instead.
This does not rewrite an explicit envelope sender. Null envelopes used for
bounces are preserved; their account is selected by the From header.

Encrypted transports honor OTOBO's `SendmailModule::SSLVerifyMode` setting.
STARTTLS failure stops the connection before authentication. Existing optional
password encryption remains compatible with the original addon; configure its
key and salt before storing encrypted credentials. Protocol debug output may
contain sensitive data and should not remain enabled during normal operation.

## Build and tests

Run inside an isolated OTOBO 11.1 installation with its normal Perl dependencies:

```sh
bin/otobo.Console.pl Dev::Package::Build --module-directory /path/to/OTOBO-MultiSMTP /path/to/OTOBO-MultiSMTP/MultiSMTP.sopm /tmp
bin/otobo.Console.pl Admin::Package::Install /tmp/MultiSMTP-11.1.0.opm
prove -I /path/to/OTOBO-MultiSMTP -I . -I Kernel/cpan-lib /path/to/OTOBO-MultiSMTP/scripts/test/MultiSMTP/*.t
```

Database integration tests require the package schema and use the OTOBO test
helper to roll back test data. The administration test also requires OTOBO's
Selenium configuration and removes its own fixtures. SMTP network operations
are mocked; these tests do not send external email. Test real SMTP delivery
separately with an explicitly chosen recipient.

## Upstream issue review

The review includes all 15 issues and 5 pull requests in
[`reneeb/opm-MultiSMTP`](https://github.com/reneeb/opm-MultiSMTP), as of 2026-11-16.

| References | Disposition in this OTOBO fork |
| --- | --- |
| Issues #4, #5, #7, #11 | Sender parsing uses the current address parser; header selection and null envelopes have regression coverage. Historical configuration-specific reports are not treated as reproduced defects. |
| Issues #14, #15 | Existing single-send behavior is preserved and tested. The historical duplicate report was resolved after a daemon restart. |
| Issues #16, #17; PR #19 | Native OAuth authentication per account and a fresh transport per message prevent stale credentials or token selection. |
| Issues #1, #3, #8, #9, #12 | Historical dependency, environment, or insufficiently specified errors. This version uses OTOBO 11.1's SMTP implementation and dependencies; those old environments are not supported or claimed repaired. |
| Issue #6 | Installation and backend activation are documented above. |
| PRs #2, #10, #13 | Previously merged translations and OTOBO-branch changes are retained. |
| Issue #20; PR #18 | Znuny-specific compatibility requests; outside the OTOBO 11.1 target. |

Additional corrections cover the removed OTOBO email-parser API, disabled
fallback, structured error results, TLS verification, and protected account
administration. No upstream issue is closed or declared fixed on behalf of
its reporter.
