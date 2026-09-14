# 02d: core 0.5.0, the transition release

Build unit 02d, 2026-09-15. Task 02.07. **Prepared, not published.** Decision
D13: the owner publishes, agents prepare and verify. No `mix hex.publish` was
run, no git tag was created or moved, nothing was pushed to any remote, and no
published version was edited.

Branch: `release/0.5.0`, cut from `aurorameter-v1` (the phase 02 merge point) at
`477a7a6e6fb03bfbf67153243687cb316bf676b3`, then kept level with
`aurorameter-v1` so that it carries this evidence too and the owner publishes
from one branch rather than from one that is a commit behind. `docs/` is not in
`package.files`, so the archive is unchanged, and that was **verified rather
than assumed**: rebuilding after the evidence commit produces the same tarball
sha256, the same inner `contents.tar` digest and the same Hex `CHECKSUM` as the
build at `477a7a6`. The exact head is recorded in the storefront's
`docs/evidence/v1/release-manifest.md` section 10.1. Local only; no tag, no
push.

## 1. Why this release exists

Decision D04. An existing customer must get a release that **warns** about
everything 1.0 will refuse before 1.0 refuses it. Without it, the 1.0 upgrade is
a silent behaviour flip: unknown configuration keys start failing the boot,
undeclared features start being denied, an unknown plan id starts raising. With
it, a host upgrades to 0.5.0, reads its logs for a week, fixes what is named,
and 1.0 is a version bump.

That is why the single most important check in this unit is the one in section 5.

## 2. Contents, item by item

`api-change-map.md` section 3 lists the release. Delivery status is stated
honestly, including the one item that is not there.

| Item | Status in 0.5.0 | Where |
|---|---|---|
| `undeclared_feature_policy`, default `:warn` | delivered | 02b |
| Unknown configuration keys warn | delivered | 02b |
| `durable_features` deprecation warning | **delivered by this unit** | `Config.check_deprecations!/1`, one line per node at boot through 02b's warn-once registry |
| `clock` seam (additive) | delivered | 02c |
| `Period.current!/2` validation | delivered | 02c |
| `subscribe/2` plan validation warning | delivered | 02b |
| Release notes describing the 1.0 defaults | **delivered by this unit** | `CHANGELOG.md` and `docs/upgrading-to-1.0.md` |
| No schema change | delivered | `AuroraMeter.Migration.latest_version() == 6`, asserted by `release_metadata_test.exs` |
| `plan_version_conflict` | **deliberately absent** | see below |

Beyond that list, the branch carries everything phase 02 produced, all additive:
`mix aurora_meter.features`, `AuroraMeter.Credits.assert_currency!/0` and the
boot checks, `AuroraMeter.Clock` with `AuroraMeter.Clock.Fixed` and the test
helpers, `AuroraMeter.Period.containing/2`, `AuroraMeter.UndeclaredFeatureError`
and the other new exceptions, `docs/api.md`, `docs/support-policy.md`,
`docs/correctness.md`, `docs/periods.md`, `docs/testing.md`,
`docs/guarantees.md`, `docs/upgrading-to-1.0.md`, and the transition-mode
warnings for binary feature names, empty tenant keys and an unknown
`default_plan`. The `CHANGELOG.md` entry enumerates all of it. A release note
that lists less than the diff is worse than no release note.

### `plan_version_conflict` is not in this release

The build document says to ship the key as accepted and inert.
**`api-change-map.md` section 3 says the opposite**, in terms: it is
"deliberately **not** in 0.5.0 ... shipping it inert would teach operators to
trust a check that is not running. It arrives with 07a, defaulting to `:raise`
in 1.0."

The binding map wins, so the key is absent. The build document's two acceptance
criteria about it are therefore not met, and are not met on purpose. This is
recorded rather than reconciled quietly, because the two documents disagree and
whoever writes `07a` needs to know which way it was decided. `docs/upgrading-to-1.0.md`
has a short section saying the key is not in this release and why.

## 3. The version, and what the bump touched

| Place | Value |
|---|---|
| `mix.exs` `@version` | `0.5.0` |
| `CHANGELOG.md` top heading | `## [0.5.0] - 2026-09-15` |
| `README.md` install snippet | `{:aurora_meter, "~> 0.5"}` |
| `docs/getting-started.md` | `{:aurora_meter, "~> 0.5"}` |
| `docs/RELEASE.md` | `git tag v0.5.0` |
| `AuroraMeter.Migration.latest_version()` | `6`, unchanged from 0.4.0 |

`test/aurora_meter/release_metadata_test.exs` asserts all six, plus that no
`[Unreleased]` section is left above the release heading, that the requirement
admits 0.5.1 and refuses 1.0.0, and that `docs/RELEASE.md` names no other tag.
Nothing noticed when `git tag v0.4.0` was left behind by a previous bump; that
is the defect this file exists for.

0.5.0 rather than 0.4.1 because the release adds public API: a behaviour
(`AuroraMeter.Clock`), four modules, two configuration keys, three exceptions
and several functions. `api-change-map.md` fixes the number.

## 4. Which decision records reach hexdocs

`open-findings.md` X85: seven core ADRs were absent from `docs()` extras and
never reached hexdocs. Two of them describe behaviour that **ships in this
release** and are published with it:

- `docs/adr/0010-undeclared-features-and-config-strictness.md` (02b)
- `docs/adr/0015-period-contract-and-clock-seam.md` (02c)

The other five describe V1 design that has **not** shipped and stay unpublished:
0009 (durable event semantics), 0011 (credit lots), 0012 (immutable plan
versions), 0013 (the sample app), 0014 (optional integrations). Publishing them
would put a plan on the public documentation site as though it were a feature.

`release_metadata_test.exs` enforces both halves, and a third assertion catches
an ADR that is in neither list, so a new decision record cannot be added without
someone deciding which it is. The negative control added 0009 to extras; the
test failed with "would present a plan as a feature".

One cross-unit touch: ADR 0010 referred to `Config.validate!/0` unqualified,
which ExDoc cannot resolve from an extra, so publishing it failed
`mix docs --warnings-as-errors`. It now says `AuroraMeter.Config.validate!/0`.
That is a one-word change to another unit's file, made because publishing the
file is this unit's job.

## 5. `Schema.mode/0` after the version bump

**This is the check the release turns on.** 02b's `AuroraMeter.Config.Schema`
derives release strictness from the package version string, so bumping the
version is exactly the kind of change that could flip it by accident. A 0.5.0
that resolved to `:strict` would start **denying** undeclared features, which is
the precise outcome D04 exists to prevent: the warning release would be the
breaking release.

Verified explicitly, in `:dev`, on the release branch
(`tmp/v1/02d/schema-mode.txt`):

```
mix.exs version            : 0.5.0
Schema.version/0           : 0.5.0
Schema.mode/0              : :transition
Schema.mode/1 on 0.4.0     : :transition
Schema.mode/1 on 0.5.0     : :transition
Schema.mode/1 on 0.5.99    : :transition
Schema.mode/1 on 1.0.0-rc.0: :strict
Schema.mode/1 on 1.0.0     : :strict
default policy             : :warn
Config.defaults policy     : :warn

OK: 0.5.0 resolves to :transition and the default policy is :warn
```

The threshold is `@strict_from "1.0.0-rc.0"`, so every 0.x version is
`:transition` and the first release candidate is the flip. The mode is derived
at compile time from `Mix.Project.config()[:version]`, not written as a literal,
and `mode/0` routes through `mode/1` rather than comparing inline: Elixir 1.20
refuses a comparison against a compile-time-literal constant under
`warnings_as_errors` (`open-findings.md` X74), and a literal would also let the
compiler prove the transition branches dead and warn on them.

`test/aurora_meter/config_strictness_test.exs` now asserts `Schema.mode("0.5.0")
== :transition` by name, next to the existing `0.4.0`, `0.5.3`, `1.0.0-rc.0`,
`1.0.0-rc.1` and `1.0.0` cases, so the next version bump inherits the check.

## 6. The `durable_features` deprecation notice

Delivered by this unit rather than by `03c`, which owns the key, because it is a
pure warning with no behaviour or schema implication.
`api-change-map.md` section 3 says so explicitly, and adds that **`03c` must not
add a second warning for the same key.**

- Fires once per node, through 02b's `warn_once/3` persistent-term registry, so
  a host that revalidates its configuration gets one line rather than a stream.
- Fires in **both** modes and never raises. The key is kept until 2.0
  (`api-change-map.md` section 5), so refusing to boot on it would be a breaking
  change wearing a warning's clothes.
- Names the 1.0 replacement (`feature_sources`, and `AuroraMeter.record/4` for
  usage that must not be lost) and points at `docs/upgrading-to-1.0.md`.
- An empty list, which is the default, warns about nothing.

Four tests in `config_strictness_test.exs` cover it: one line for a non-empty
list, none for an empty list, none for an absent key, and a warning rather than
a raise in strict mode. The negative control made the notice fire for an empty
list; the "an empty durable_features list emits no warning" test failed.

`AuroraMeter.record/4` does not exist yet, which is the point of naming it, so
`mix.exs` adds it to `skip_code_autolink_to` with a comment saying to remove the
line when 03b adds the function.

## 7. The verification run

All on `release/0.5.0` at `477a7a6`, through `tmp/v1/mixlane.sh` so no two Mix
workloads shared a `_build`.

| Command | Exit | Result |
|---|---|---|
| `mix deps.unlock --check-unused` | 0 | |
| `mix deps.audit` | 0 | No vulnerabilities found |
| `mix hex.audit` | 0 | No retired or security advisory packages found |
| `mix check` | 0 | format, compile, credo --strict, dialyzer, 810 passed (42 doctests, 10 properties, 758 tests), 3 excluded, `docs --warnings-as-errors` clean |
| `mix hex.build` | 0 | tarball written outside the repository |

Test counts: **781 before this unit, 810 after**, no failures at any point.

`mix.lock` sha256 `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3`
before and after the whole run, and the working tree is clean.

## 8. The tarball

Built with `mix hex.build --output`, which contacts Hex not at all.

| Property | Value |
|---|---|
| File | `aurora_meter-0.5.0.tar` |
| Bytes | 115,200 |
| sha256 | `b63d928d68ea45440e3918ad669fe12ed9b7d269eff6148a589271d93ffad7d7` |
| Hex package checksum (the `CHECKSUM` member) | `097CB498517DCFAC7114871C88E426DF087D30F87A48A189C7205AA3FCBFCEA6` |
| Inner `contents.tar` sha256 | `6661e22c1e3ce980eebee03710eca017226ce91870b20176513f3617e329da5d` |
| Files inside | 51 (0.4.0 shipped 46) |

**Compare the inner content digest, never the tarball hash**, when checking what
the owner publishes against this. Blocker B19 in
`docs/evidence/v1/phase-00/blockers.md`: a Hex archive is not byte reproducible
across toolchains, because the gzip stream differs even when every inner file is
identical.

Outer members: `VERSION`, `CHECKSUM`, `metadata.config`, `contents.tar.gz`.
Inner listing, sorted:

```
.formatter.exs
CHANGELOG.md
LICENSE
NOTICE.md
README.md
lib/aurora_meter.ex
lib/aurora_meter/billing.ex
lib/aurora_meter/billing/noop.ex
lib/aurora_meter/billing/provider.ex
lib/aurora_meter/boot_checks.ex
lib/aurora_meter/broadcaster.ex
lib/aurora_meter/clock.ex
lib/aurora_meter/cluster.ex
lib/aurora_meter/components.ex
lib/aurora_meter/config.ex
lib/aurora_meter/config/schema.ex
lib/aurora_meter/counter.ex
lib/aurora_meter/credits.ex
lib/aurora_meter/credits/ledger.ex
lib/aurora_meter/credits/money.ex
lib/aurora_meter/credits/promotions.ex
lib/aurora_meter/credits/series.ex
lib/aurora_meter/entitlements.ex
lib/aurora_meter/errors.ex
lib/aurora_meter/flusher.ex
lib/aurora_meter/install/templates.ex
lib/aurora_meter/live_view.ex
lib/aurora_meter/migration.ex
lib/aurora_meter/migration/v6.ex
lib/aurora_meter/period.ex
lib/aurora_meter/plan.ex
lib/aurora_meter/plans.ex
lib/aurora_meter/schema/counter.ex
lib/aurora_meter/schema/credit_balance.ex
lib/aurora_meter/schema/credit_transaction.ex
lib/aurora_meter/schema/event.ex
lib/aurora_meter/schema/flush_receipt.ex
lib/aurora_meter/schema/history.ex
lib/aurora_meter/schema/subscription.ex
lib/aurora_meter/storage.ex
lib/aurora_meter/storage/ecto.ex
lib/aurora_meter/store.ex
lib/aurora_meter/subscriptions.ex
lib/aurora_meter/supervisor.ex
lib/aurora_meter/tenant.ex
lib/aurora_meter/test.ex
lib/mix/tasks/aurora_meter.bench.ex
lib/mix/tasks/aurora_meter.features.ex
lib/mix/tasks/aurora_meter.gen.migration.ex
lib/mix/tasks/aurora_meter.install.ex
mix.exs
```

`docs/` is not in `package.files`, so none of the guides above reach a customer
through the archive. They reach hexdocs and the storefront (`open-findings.md`
T12), which is why anything an installed package must be able to read lives in
`lib/`.

## 9. Diff against the published `v0.4.0`

Package contents only (`lib`, `mix.exs`, `README.md`, `CHANGELOG.md`, `LICENSE`,
`NOTICE.md`): **29 files changed, 2,767 insertions, 250 deletions.** The whole
tree, including documentation, evidence and tests: 191 files changed, 27,717
insertions, 667 deletions.

No file was deleted from the package. Four new modules and one new Mix task are
added; every other change is additive or is a warning where there was silence.

## 10. What the owner runs

Nothing here has been run. See the handoff in the storefront's
`docs/evidence/v1/release-manifest.md`, section 11, which carries both packages'
commands in the order they must happen.

The one ordering constraint: **core 0.5.0 is published before Pro 0.3.1.** Pro's
README and `docs/usage-reporting.md` link to
`https://hexdocs.pm/aurora_meter/guarantees.html`, which exists only once core's
docs are up.

## 11. The risk in one sentence

If this release is never published, the D04 warning path never reaches a
customer and 1.0 becomes, for every existing host, exactly the silent behaviour
flip this release was built to prevent.
