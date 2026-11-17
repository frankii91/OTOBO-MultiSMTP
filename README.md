# OTOBO-MultiSMTP

Sender-specific SMTP accounts for **OTOBO 11.1.x**. This fork continues
[Perl Services MultiSMTP](https://github.com/reneeb/opm-MultiSMTP/tree/otobo).
It does not claim compatibility with OTRS, Znuny, or older OTOBO versions.

## Why use it?

OTOBO normally sends outgoing mail through one globally configured SMTP account.
When a mail server only allows that account's own sender address, messages from
other queues can be rejected. MultiSMTP selects the outgoing account by sender
address, so each queue can use the credentials its mail server expects.

Each profile has its own server, port, credentials, transport, and assigned
sender addresses. Queues sharing a sender address also share its SMTP profile.
Incoming IMAP/POP3 accounts remain separate; this addon manages outgoing mail.

## Download

Install [MultiSMTP 11.1.2](https://github.com/frankii91/OTOBO-MultiSMTP/releases/tag/v11.1.2)
from the release's `.opm` asset. The release includes a SHA-256 checksum.

The package targets **OTOBO 11.1.x** and uses its package manager, SMTP transports,
OAuth accounts, and administration controls. It does not replace core files.

## Features

- Separate SMTP accounts selected by sender address.
- SMTP, SMTPS, and STARTTLS with native certificate verification.
- Basic authentication, anonymous relays, XOAUTH2, and OAUTHBEARER.
- Optional fallback for sender addresses without a matching active profile.
- Administrator-only account management, including Polish interface labels.
- Password fields remain blank when editing; leaving them blank keeps the stored password.

## Configuration

1. Install the built `MultiSMTP-11.1.2.opm` through OTOBO Package Manager.
2. Open **Administration > SMTP settings** and assign the required system
   addresses to their SMTP accounts. In Polish, the entry and page are named
   **Konta SMTP**. Access requires read/write permission in the `admin` group.
3. Set `SendmailModule` to `Kernel::System::Email::MultiSMTP` in System
   Configuration and deploy the configuration. Select a fallback transport if
   unmapped senders should keep using the global SMTP account.
4. Send a test message from each relevant queue to a controlled recipient.

After an upgrade, clear the OTOBO cache. If long-running processes still hold
the old package code, reload them according to the installation's deployment procedure.

| Setting | Default | Purpose |
| --- | --- | --- |
| `MultiSMTP::UseFallback` | `1` | Allow unmapped senders to use the fallback transport. |
| `MultiSMTP::Fallback` | `Kernel::System::Email::SMTP` | Transport using the global SMTP configuration; choose SMTPS or SMTPTLS when needed. |
| `MultiSMTP::UseSenderFromMail` | `0` | Select by envelope sender; enable to select by the `From` header. |

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

To stop using MultiSMTP, restore the previous `SendmailModule` and deploy that
configuration. **Uninstalling the package deletes its SMTP account profiles.**

## Build and tests

Run inside an isolated OTOBO 11.1 installation with its normal Perl dependencies:

```sh
bin/otobo.Console.pl Dev::Package::Build --module-directory /path/to/OTOBO-MultiSMTP /path/to/OTOBO-MultiSMTP/MultiSMTP.sopm /tmp
bin/otobo.Console.pl Admin::Package::Install /tmp/MultiSMTP-11.1.2.opm
prove -I /path/to/OTOBO-MultiSMTP -I . -I Kernel/cpan-lib /path/to/OTOBO-MultiSMTP/scripts/test/MultiSMTP/*.t
```

Database integration tests require the package schema and use the OTOBO test
helper to roll back test data. The administration test also requires OTOBO's
Selenium configuration and removes its own fixtures. SMTP network operations
are mocked; these tests do not send external email. Test real SMTP delivery
separately with an explicitly chosen recipient.

Delivery has also been verified with three independent SMTP accounts through
the normal OTOBO mail queue, with receipt confirmed by the recipient. This does
not replace testing credentials, sender permissions, and TLS on your own server.

## Upstream issue review

The review includes all 15 issues and 5 pull requests in
[`reneeb/opm-MultiSMTP`](https://github.com/reneeb/opm-MultiSMTP), as of 2026-11-16.

<details>
<summary>Reviewed issues and pull requests</summary>

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

</details>

## Support

Report reproducible problems in
[this fork's issue tracker](https://github.com/frankii91/OTOBO-MultiSMTP/issues).
Include the OTOBO and package versions, selected transport, and a redacted error
message. Do not attach passwords, OAuth tokens, or private message content.

Original authorship and license notices are retained in the source and package.
