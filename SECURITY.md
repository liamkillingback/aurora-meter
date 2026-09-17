# Security

## Reporting a vulnerability

Report privately, not in a public issue:

- GitHub private vulnerability reporting on
  [liamkillingback/aurora-meter](https://github.com/liamkillingback/aurora-meter/security/advisories/new),
  which is the preferred route because it keeps the report, the fix and the
  advisory in one place; or
- <https://aurorameter.com/contact> or <hello@aurorameter.com>, if you would
  rather not use GitHub. Both reach the maintainer directly.

Please include the package version, the Elixir and Erlang/OTP versions, and the
smallest configuration that reproduces the behaviour.

**There is no response-time commitment, and this file does not create one.** The
maintainer aims to acknowledge a report within a few working days and will say
what is happening rather than go quiet. Aurora Meter is MIT licensed and is
provided as the licence says, without warranty. Aurora Meter Pro is a separate
commercial package; its licence is unchanged by this file, and neither package
comes with a service level agreement. See
[the support policy](docs/support-policy.md) section 7.

## Which versions get a fix

The current minor release and the one before it. Older minors are not patched;
the upgrade path is in [Upgrading to 1.0](docs/upgrading-to-1.0.md).

## What this package stores

Everything it stores comes from you:

- **tenant keys**, exactly as `AuroraMeter.Tenant.to_key/1` resolved them. If
  your tenant key is an email address, that is what is in the rows;
- **feature names**, as atoms you declared in your plans module;
- **integer quantities**, and for the credit ledger integer micro-USD amounts;
- **your metadata**, on events and credit transactions, byte for byte as you
  passed it, handed back unchanged. Aurora Meter puts nothing of its own in it
  and never inspects it;
- **timestamps and period boundaries** derived from the configured clock and
  period source.

It never stores a card number, a Stripe secret, a Hex key or any credential. It
holds no encryption keys and implements no cryptography beyond a SHA-256 hash of
an event's canonical payload, which exists to detect a conflicting reuse of an
event id and is not a security control.

## What this package sends

Nothing. **The free core makes no outbound network request of its own.** It
talks to the Postgres repo you configure and to the `Phoenix.PubSub` server you
configure, and to nothing else. There is no telemetry reporting back to us, no
version check, no usage ping, and no way to turn one on, because there is
nothing to turn on.

`aurora_meter_pro` does call Stripe, which is the whole point of it, and its own
`SECURITY.md` says what that involves.

## What the host is responsible for

These are the places where a mistake in your application, not in this library,
exposes data.

**Authorising the dashboard page.** `AuroraMeter.LiveDashboard.Page` mounts
inside your LiveDashboard and shows tenant-level usage. It refuses to mount
without an authorisation check, and that check is yours to write. Read
[Operations](docs/operations.md) before you add the page.

**Authorising anything that takes a tenant.** A LiveView, a controller or a plug
that resolves a tenant from user input and hands it to Aurora Meter will happily
report another customer's usage. Resolve the tenant from the session or the
authenticated assigns, never from a parameter. The `EnsureEntitled` plug and the
LiveView helpers are documented in [Phoenix](docs/phoenix.md).

**Keeping personal data out of metadata.** Metadata is stored as you give it and
returned as you gave it. It is not encrypted, it is visible to anything that can
read your database, and it is included in a `pg_dump`. Put an identifier in it,
not a person.

**Keeping secrets out of everything.** Metadata, feature names, tenant keys and
event ids all end up in database rows, and several of them end up in telemetry
metadata and log lines. None of them is a place for a secret.

**Your own migrations.** Aurora Meter supplies migration bodies; you run them,
against your database, with your credentials. See
[the support policy](docs/support-policy.md) section 3.

## Dependencies

The free core's runtime dependencies are `ecto_sql`, `postgrex`,
`phoenix_pubsub`, `telemetry`, `nimble_options` and `jason`. Everything else is
optional and a CI lane builds and tests the library with the optional set
removed, so "optional" is a measured claim rather than an intention. The exact
supported versions are in [the support policy](docs/support-policy.md)
section 5.
