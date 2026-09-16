# Support policy

What Aurora Meter promises about compatibility, and what it does not. It
restates commitments the package already keeps; it adds no commercial term, and
it is not a service level agreement.

The surface it applies to is [the API inventory](api.md). If an entry is not on
that page, nothing here covers it.

## 1. What SemVer covers

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Inside 1.x, these things do not break:

- Every entry in the API inventory classed `stable` or `optional-dep`: its
  name, its arity, the shape of its arguments and the shape of what it returns.
- The documented ledger semantics: micro-dollar integers, the allocation order
  (promotional credit before paid credit, soonest expiry first within
  promotional), conservation of the balance across grant, hold, settle,
  release, debit, reverse and expire, and the rule that a refusal writes
  nothing and never rolls back the caller's transaction.
- Configuration key names, their types, and their defaults.
- Telemetry event names, measurement keys and metadata keys.
- PubSub message tags and the topic functions that build the topic strings.
- Migration entry points and the schema-version contract in section 3.

Additive change is allowed in a minor release: a new function, a new optional
argument with a default, a new key in a payload map, a new metadata key on an
existing telemetry event, a new configuration key with a default that preserves
today's behaviour. Match on the keys you need rather than on a whole map, and
additive change stays invisible to you.

## 2. What SemVer does not cover

- Anything classed `internal` in the inventory, whether or not it is public in
  the compiled code. Section 11 of that page names every internal module.
  Internal entries may change in any release, including a patch, with no
  deprecation and no warning.
- Any function carrying `@doc false`.
- The wording of log messages.
- The SQL Aurora Meter generates and the query plans Postgres chooses for it.
- The ETS table layout, the counter row tuple, and the contents of the tables
  `AuroraMeter.Store` owns.
- The contents of a `metadata` map: Aurora Meter stores what a host writes and
  hands it back, and puts nothing of its own in it.
- Benchmark numbers, including everything `mix aurora_meter.bench` prints.
- The exact text of an error message. The **tuples** are covered
  (`{:error, :insufficient_credits}` will not become `{:error, :no_credit}`);
  the strings inside an exception's `:message` are not.

## 3. Schema

A host owns its own database and runs its own migrations. Aurora Meter provides
the migration bodies through `AuroraMeter.Migration.up/1` and `down/1`.

- **1.x migrations are additive only.** A new version adds tables, columns and
  indexes. It does not drop a column, narrow a type or delete a row. A version
  that would destroy data is refused unless the caller passes
  `confirm_data_loss: true`, and no such version is planned for 1.x.
- **Every version is idempotent**, so re-running one is safe.
- **Every supported 0.x history upgrades to 1.0.** In practice the histories
  that exist are installs currently at schema version 1, 2 or 6; each has a
  path to the 1.0 schema through `AuroraMeter.Migration.up(from: n)`, and each
  is exercised by the migration matrix in this repository's CI on every push.
- `AuroraMeter.Migration.latest_version/0` reports the version the installed
  package expects. It is the number to compare against in a health check.

## 4. Deprecations

A deprecated API keeps working. It warns, at most once per node per distinct
key, so a hot path cannot flood a log. It is **not removed before 2.0**.

Deprecated today:

| Entry | Replacement | Removed in |
|---|---|---|
| `:durable_features` configuration key | per-feature reporting sources | 2.0 |

Two behaviours change their **default** rather than disappearing, and each gets
a transition release that warns before the default moves:
`:undeclared_feature_policy` (`:warn` in 0.5.x, `:deny` from 1.0) and unknown
configuration keys (a warning in 0.5.x, a refusal to boot in 1.0). Setting the
key explicitly pins the behaviour across the change in both cases.

## 5. Runtime support

The supported pairs are the ones CI exercises on every push, at the exact patch
versions listed in the README's "Supported versions" table. Nothing is claimed
for a pair that is not tested.

- Floor: Elixir 1.15.8 on Erlang/OTP 25.3.2.21.
- Postgres 13 is the floor and 16.13 is the tested version, with a second lane
  on 15.6.
- A lane builds and tests with none of the optional dependencies present, so
  "optional" means optional.
- Optional `phoenix_live_view` is `~> 1.0`, and `~> 1.0` only.

### Phoenix LiveView 1.0, when LiveView is present at all

Aurora Meter 1.0 requires `phoenix_live_view ~> 1.0` **when the optional
dependency is present**. A host with no LiveView is unaffected: nothing outside
`AuroraMeter.Components` and the LiveDashboard page needs it, and
`AuroraMeter.LiveView.subscribe/1` deliberately sits outside the guard so a
headless host keeps the subscription.

0.4.0 declared `~> 0.20 or ~> 1.0`, and the 0.20 half of that was never true.
Every component and dashboard template is written in LiveView 1.0's curly body
interpolation, and in 0.20 a `{...}` in an element body is not an interpolation:
it is literal text. A 0.20 host compiled this package without an error and
rendered `{@label}` to its own customers. Narrowing the requirement replaces a
claim that never worked with one that does, which is why it is a breaking change
in a major release rather than a bug fix.

If you are on LiveView 0.20, there are two routes and the second costs almost
nothing:

1. **Upgrade LiveView to 1.0.** Phoenix's own migration guide covers it. Aurora
   Meter needs nothing from you in the process.
2. **Drop the optional dependency.** Remove `phoenix_live_view` from your
   `mix.exs` if Aurora Meter is the only thing that wanted it. You lose
   `AuroraMeter.Components` and the LiveDashboard page, and keep the facade, the
   credit ledger, the plans DSL, the migrations, telemetry, the Oban workers and
   the PubSub subscription.

Hex applies an optional requirement when the dependency **is** present, so a
0.20 host that keeps LiveView gets a resolution conflict before anything is
installed rather than a page full of braces afterwards.

`mix aurora_meter.install --check-support` prints the floor for every
dependency, and exits non-zero when something present is below one.

Dropping a supported pair is a compatibility decision and needs release notes
that say so before the release that drops it. Raising the floor inside 1.x
happens only for a pair that is no longer available or no longer builds.

The floor is a compatibility guarantee, not a recommendation. Elixir 1.15.8 is
the last release of its line and Erlang/OTP 25 is no longer maintained
upstream, so neither will receive further security patches.

## 6. Security

Report a suspected vulnerability privately through
<https://aurorameter.com/contact>, not through a public issue. A `SECURITY.md`
with the disclosure process, the supported-version window and the response
expectation is being added; this page will link to it rather than duplicate it,
so that there is one description of the process and not two.

## 7. Support

**There is no response-time commitment.** Support is best effort. Aurora Meter
(the core) is MIT licensed and is provided as the licence says, without
warranty. Aurora Meter Pro is a separate commercial package; buying it buys the
software and its updates, and its licence is unchanged by this page. Neither
package comes with a service level agreement, and this policy does not create
one.

Bug reports and questions are welcome at
<https://github.com/liamkillingback/aurora-meter/issues>. The most useful report
names the package version, the Elixir and Erlang/OTP versions, and the smallest
configuration that reproduces the behaviour.

## 8. Releases and transition releases

Releases are published by the maintainer. There is no automatic publish from
CI, and no agent publishes a package.

A change that moves a default, or that starts refusing something previously
accepted, ships in two steps. First a **transition release** that keeps today's
behaviour, warns about what is going to change, and lets a host opt in to the
new behaviour early by setting the key explicitly. Then the release that moves
the default, whose notes list every default that moved and the key that pins the
old one. A host that reads the warnings and sets the keys has nothing to do on
the second release.

Every release carries a `CHANGELOG.md` entry. An entry that changes behaviour
names what a caller has to do, or says plainly that there is nothing to do.

## Test helpers

`AuroraMeter.Test` and `AuroraMeter.Clock.Fixed` ship in the package and are
listed in the inventory as `stable`, because a host test suite that uses them
should not break on a minor upgrade. They are governed here rather than by
SemVer on every helper name: a helper may gain an option or a clearer failure
message in a minor release, and a helper that becomes wrong (because the
behaviour it simulates changed) is fixed rather than kept bug-compatible.

Nothing in production should call them. They start agents, clear ETS tables and
freeze the clock, and none of that is safe in a running system.
