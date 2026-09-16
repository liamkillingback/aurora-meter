# 07a: plan versions, snapshot registry and legacy assignment

**Tasks:** 07.01 (code-first schema with an immutable version id, effective time
and a deterministic fingerprint), 07.02 (registry: code stays authoritative,
snapshots persisted only to interpret existing subscriptions and history),
07.03 (existing customers get an explicit legacy version; changing the latest
version affects new subscriptions only; referenced old definitions stay
loadable). Taken from the README row for 07a, not guessed (`open-findings.md`
X265).

**Invariants:** I17 (owner), I19 (contributor, through core schema version 10).

**Gate:** G07 bullets 1 (core half), 2 and 6.

## Provenance

| | |
|---|---|
| Date | 2026-09-16 |
| Core repository | `product-workspaces/aurora_meter`, HEAD `0b3c206d60fa86019b17392914c4d6621777ac3b`, **dirty: 71 files** (43 of code, tests and documentation, plus 28 evidence files and logs under `docs/evidence/v1/phase-07/`). Uncommitted, per programme rule 4 |
| Core `mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| Core package version | 0.5.0 (so `Config.Schema.mode/0` is `:transition` and `plan_version_conflict` defaults to `:warn`) |
| Pro repository | `product-workspaces/aurora_meter_pro`, HEAD `f1e450781201ad0beebfa94b99fcd276db48d76e`, dirty: 5 files |
| Pro `mix.lock` sha256 | `a2140b7e65132ec337fb7e6ac70fbd750b4ade13f1f6b1fb1762d1426bfbac8e` |
| Core schema version | **6 or 9 before, 10 after** |
| Pro schema version | 10, unchanged |
| Elixir | 1.20.1 |
| Erlang/OTP | 29, erts 17.0.1 |
| Postgres | 16 (Docker `aurora-meter-pro-testdb`, port 5490) |
| OS | WSL2 Ubuntu 24.04, kernel 6.6.87.2, on Windows 11 |

## What changed

### Core, `lib/`

| File | Change |
|---|---|
| `aurora_meter/plans/snapshot.ex` | **new**, `@moduledoc false`. Canonical form, `fingerprint/1`, `encode/1`, `decode/5`, separators, `fingerprint_version/0`. |
| `aurora_meter/plan_version_conflict_error.ex` | **new**. `AuroraMeter.PlanVersionConflictError`, with `conflicts` and `format/1`. |
| `aurora_meter/schema/plan_version.ex` | **new**. `aurora_meter_plan_versions`. |
| `aurora_meter/schema/plan_transition.ex` | **new**. `aurora_meter_plan_transitions`, written by nobody in this release. |
| `aurora_meter/migration/v10.ex` | **new**. Core schema version 10, plus X220. |
| `aurora_meter/plan.ex` | `version`, `effective_at`, `fingerprint` on the struct and the type; `base_version/0`. |
| `aurora_meter/plans.ex` | `plan/3`; compile-time validation of version, effective instant and options; the cross-block rules; `__aurora_plan_index__/0`; `get/2`, `base/1`, `versions/1`, `plan_ids/0`, `register!/0`, the snapshot cache, `registry_state/0`, `reset_registry/0`. |
| `aurora_meter/entitlements.ex` | `plan/1` resolves the pinned version with a snapshot fallback and a base-version default for an unnamed row; `subscribe/3` takes `version:`; `known_plan?/1` reads `plan_ids/0`. |
| `aurora_meter.ex` | `subscribe/3`; `start_link/1` runs `Plans.register!/0` after the supervisor starts, and only when it actually started. |
| `aurora_meter/schema/subscription.ex` | ten new fields, `@castable`, `syncable/0`, two `validate_inclusion` calls. |
| `aurora_meter/storage.ex` | `:plan_versions` capability; `put_plan_version/1`, `list_plan_versions/1`, `assign_legacy_plan_versions/1` as callbacks and dispatchers. |
| `aurora_meter/storage/ecto.ex` | the three implementations, the S4 fix in `put_subscription/1`, X220 in `flush_batch/3`, the assignment statement. |
| `aurora_meter/migration.ex` | `@latest 10`, `@data_loss_versions [7, 9, 10]`, the version list. |
| `aurora_meter/config.ex` | `plan_version_conflict` key and accessor; `check_plans!/2` reads the `{id, version}` key. |
| `aurora_meter/config/schema.ex` | `default_plan_version_conflict/0`. |
| `aurora_meter/retention.ex` | both new tables added to `@protected`. |
| `aurora_meter/storage_case.ex` | `:plan_versions` in the capability vocabulary. |
| `mix/tasks/aurora_meter.features.ex` | reports per plan version; gaps stay per plan id. |

### Core, `test/` and `docs/`

New: `plans_snapshot_test.exs` (15), `plan_versions_test.exs` (31),
`plan_versions_property_test.exs` (3 properties),
`plan_registry_concurrency_test.exs` (7), `migration_v10_test.exs` (9),
and two X220 tests in `storage_test.exs`: 67 in all, which is exactly the
difference between the 1657 baseline and this unit's 1724.
`priv/test_repo/migrations/20260916090000_upgrade_aurora_meter_v10.exs`.

Extended: `storage_test.exs` (two X220 tests), `test_plans.ex` (a two-version
`:versioned` plan plus four swap-in modules), `connections.ex`
(`reset_plan_versions!/0`, `PlanTransition` in `@tables`, `PlanVersion` in
`@tenantless`), `fault_storage.ex` and `fault_repo.ex` (the three callbacks and
`query/2`), `storage_fakes.ex`, `test_helper.exs` (the registry reset runs
before the runtime starts), `api_inventory_test.exs`, `plans_test.exs`,
`examples_test.exs`, `config_strictness_test.exs`,
`release_metadata_test.exs` (`@schema_version 10`).

Docs: `docs/plans.md` (a "Versions" section), `docs/configuration.md`
(`:plan_version_conflict`), `docs/api.md`, `docs/correctness.md` (I17 rewritten,
56 I17 bullets and 8 I19 bullets added), `docs/adr/0012-immutable-plan-versions.md`
(implementation notes), `CHANGELOG.md`.

**No new ADR.** The build document asks for `docs/adr/0009-plan-versions.md`;
0009 is `durable-event-semantics` and the plan-versions ADR already exists as
**0012**. Its "Implementation notes (build unit 07a)" section records the five
places the implementation settled differently from, or more precisely than, the
decision.

### Pro

Core-only work, and it touched Pro anyway (`open-findings.md` X252 and X275, and
this is the third unit in a row).

| File | Change | Why |
|---|---|---|
| `priv/test_repo/migrations/20260916090000_upgrade_core_v10.exs` | **new** | core 10's columns are declared by core's `Subscription` schema, so every Pro query selects them; and Pro's flushes need the receipt default |
| `test/support/.../connections.ex` | `PlanTransition` in `@tables`, `PlanVersion` in `@tenantless`, `reset_plan_versions!/0` | Pro's harness guard enumerates **schema modules** (X275) |
| `test/support/.../fault_storage.ex` | the three new callbacks, instrumented | the shim's parity guard requires every `Storage` callback |
| `test/support/.../fault_repo.ex` | `query/2` | the surface guard scans core's `lib/` and the assignment uses the non-bang form |
| `test/test_helper.exs` | the registry reset runs before the runtime starts | registration compares against a previous run's snapshots |

Pro's suite found two of those itself: `Y4 cleanup! covers every schema the
package owns` (`PlanTransition`) and `FaultRepo exports every repo function
lib/ calls` (`query/2`). Core's `mix check` was green when both were broken.

## Commands

Every command ran through `tmp/v1/mixlane.sh`, so core and Pro never ran
concurrently. Seeds are stated where a run takes one.

| Command | Exit | Result |
|---|---|---|
| `mix test.setup` (core) | 0 | version 10 applied to `aurora_meter_test` |
| `mix test.setup` (pro) | 0 | version 10 applied to Pro's test database |
| `mix check` (core, beams deleted first) | **0** | **1724 passed** (73 doctests, 20 properties, 1631 tests), 4 excluded. Baseline was 1657, so +67. Dialyzer over a PLT rebuilt from scratch, credo --strict clean, `mix docs --warnings-as-errors` clean |
| `mix check` (pro, PLT deleted first) | **0** | **987 passed** (66 doctests, 921 tests), unchanged from the baseline |
| headless leg (`AURORA_HEADLESS=1`, `compile --warnings-as-errors --force`, `mix test --include headless --seed 0`) | 0 | **1635 passed** (69 doctests, 20 properties, 1546 tests) |
| property sweep, seeds 0, 1, 7, 42, 1337 | 0 at every seed | see below |
| 100,000-row measurement | 0 | see `07a-migration.md` |
| 11 negative controls | see below | 11 of 11 discriminated |

Logs: `07a-logs/core-check.log`, `07a-logs/pro-check.log`,
`07a-logs/core-headless.log`, `07a-logs/property-seeds.log`,
`07a-logs/measure.log`, `07a-logs/control-*.log`.

### The property sweep, per seed

`open-findings.md` X276: `mix check` draws a random seed, so a property that
fails at one fixed seed is invisible to the gate. Every `*property*.exs` file in
core, at the five fixed seeds. Both files ran at every seed.

| Seed | Exit | 07a determinism | 07a injectivity | 07a round trip | 06b compared / refused |
|---|---|---|---|---|---|
| 0 | 0 | 100 | distinct=100 equal=0 | 100 | 14 / 7 |
| 1 | 0 | 100 | distinct=100 equal=0 | 100 | 19 / 2 |
| 7 | 0 | 100 | distinct=100 equal=0 | 100 | 16 / 5 |
| 42 | 0 | 100 | distinct=100 equal=0 | 100 | 11 / 10 |
| 1337 | 0 | 100 | distinct=100 equal=0 | 100 | 16 / 5 |

Every count is non-zero, so no property was green for having compared nothing.

### The negative controls

`open-findings.md` X125 and X242. Each control breaks exactly one thing, runs the
tests meant to notice, and restores the file. A break that leaves a function
unused fails the `--warnings-as-errors` compile and is reported as an **invalid
control** rather than as a pass.

| Control | Break | Result |
|---|---|---|
| `a1-subscribe-ignores-version` | `resolve_version/2` uses `Plans.get(id)` | 4 tests |
| `a2-plan-ignores-pin` | `pinned_plan/2` uses `Plans.get(id)` (**criterion 4**) | 4 tests, including criterion 4's |
| `a3-...-version-assert-relaxed` | same break, criterion 4's version assertion removed | still 4 tests: the effect assertions discriminate on their own |
| `b-no-snapshot-fallback` | `list_plan_versions/1` returns `[]` for both clauses (**criterion 9**) | 3 tests, including criterion 9's |
| `c-replace-all-except` | the old `{:replace_all_except, ...}` upsert (**S4**) | 2 tests |
| `d-node-stamped-receipt` | `inserted_at: Clock.now()` back in the receipt (**X220**) | 1 test |
| `e-no-skip-locked` | `FOR UPDATE` without `SKIP LOCKED` | 1 test |
| `f-no-resume-predicate` | the assignment drops `WHERE plan_version IS NULL` | 8 tests |
| `g-literal-version-one` | the assignment joins `version = '1'` instead of the base version | 1 test (**and zero before that test existed: finding X287**) |
| `h-no-separators` | canonical fields joined with `""` | 2 tests |
| `i-unsorted-features` | the feature sort removed | 1 test (**and zero before that test was rewritten: finding X291**) |
| `j-unsorted-credits` | the recurring credit sort removed | 1 test, 1 property |
| `k-no-conflict-check` | every fingerprint comparison forced equal | 2 tests |

Two of them did not discriminate on their first run, and both produced a finding
and a new test: `g` (X287) and `i` (X291). A third, the first attempt at the
criterion-4 control, anchored on the wrong occurrence of `Plans.get(id, version)`
and proved something else; it is kept as `a1` under an honest name.

## Public API, configuration, migration and documentation changes

### Additive

`AuroraMeter.subscribe/3`, `AuroraMeter.Plans.{get/2, base/1, versions/1,
plan_ids/0, register!/0}`, `AuroraMeter.Plans.plan/3` (DSL macro),
`AuroraMeter.PlanVersionConflictError`, `AuroraMeter.Schema.PlanVersion`,
`AuroraMeter.Schema.PlanTransition`, `AuroraMeter.Config.plan_version_conflict/0`,
`%AuroraMeter.Plan{}`'s `version`, `effective_at` and `fingerprint`.

### Breaking for a custom storage adapter

`AuroraMeter.Storage` gains three required callbacks:
`put_plan_version/1`, `list_plan_versions/1`, `assign_legacy_plan_versions/1`,
all behind the new `:plan_versions` capability. No custom adapter is known to
exist, and the capability mechanism degrades rather than crashes.

### Behaviour changes

- `AuroraMeter.Storage.put_subscription/1` no longer writes NULL into a column
  the caller omitted. Documented in the changelog; the only in-tree caller that
  omitted columns was `Entitlements.subscribe/2`.
- `AuroraMeter.Plans.all/0` keeps its shape and its content becomes time
  dependent.
- The generated `__aurora_plans__/0` is keyed by `{plan_id, version}`. `@doc
  false` and generated, but a host that called it directly breaks.
- `AuroraMeter.start_link/1` does database work. A host that starts Aurora Meter
  above its Repo gets one warning and deferred registration rather than a failed
  boot, which is the point of the deferral.

### Configuration

`plan_version_conflict: :raise | :warn`, default `:warn` in 0.5.x and `:raise`
from 1.0, following `undeclared_feature_policy`'s pattern exactly.

### Migration

Core schema version 10 (`schema-migration-map.md` S6). See `07a-migration.md`.

## G07, bullet by bullet

`open-findings.md` X212: a gate bullet with no test is invisible to a unit that
checks only its own criteria, so every bullet is answered here, including the
ones that are not this unit's.

| Bullet | This unit |
|---|---|
| 1. Deploying Pro plan v2 leaves a tenant on v1 with unchanged limits, period, credit recurrence and Stripe price | **Core half proved.** `test I17 a tenant subscribed before version 2 exists keeps version 1 after version 2 is effective` covers limits, feature values, price and recurring credit amount and rollover cap. **Period is not asserted** and is 07b's, because nothing in this unit changes a period. **The Stripe price half is 07c's.** |
| 2. New subscriptions select the intended effective version; future-dated versions are not active early | **Proved.** `test I17 subscribe/2 selects the version effective now and stamps its fingerprint` (before and after the boundary, under `Clock.Fixed`), `test I17 a future-dated version is not effective before its instant and is after it`, and `test I17 subscribe/3 with an explicit version pins it, including one not yet effective`, which is the deliberate exception: an opt-in by name is not a version becoming active early. |
| 3. Duplicate schedules, worker retry and two nodes apply one transition; crash between provider update and local commit converges | **Not this unit.** 07b. The transitions table ships here unwritten. |
| 4. Stale webhooks do not resurrect cancelled plans or override a newer transition; zero-price transitions and cancellation at period end | **Not this unit.** 07b and 07c. |
| 5. Mid-period historical usage stays on its original plan/price mapping; late export does not inherit current pricing | **Not this unit.** 07c (event attribution). This unit supplies the identity it attributes to. |
| 6. Generated migration upgrades old subscriptions without silently migrating their commercial contract | **Proved.** `test I19 a populated version 9 database upgrades with no subscription changed` (the DDL touches nothing and leaves every plan column NULL), `test I17 register! names the contract of a subscription that has none, and leaves a named one alone` (L17.4), and the 100,000-row measurement: zero rows with `plan_version IS NULL` and zero rows whose `plan_id` changed. The generator half (`mix aurora_meter.gen.migration` emitting a bounded version 10 file) is 11a's; the host migration is written by hand in the meantime, as `docs/plans.md` and the migration moduledoc show. |

## Acceptance criteria: what was run

Not ticked here (programme rule 4). Stated so the reviewer can tick or refuse.

1. Two versions compile and `versions/1` returns them ordered, `test I17 two
   versions of one plan id both compile and versions/1 lists them oldest first`.
2. The clock boundary, `test I17 a future-dated version is not effective before
   its instant and is after it`. "No subscription row changed in between" is
   covered by criterion 4's test, which asserts the row still reads
   `plan_version: "1"` after the swap.
3. The conflict and its message, `test I17 register! raises
   PlanVersionConflictError naming the plan, version and both fingerprints` and
   `test I17 plan_version_conflict warn logs the same message once and does not
   raise`. The message is quoted in full in `i17.md`.
4. Compatibility, `test I17 a tenant subscribed before version 2 exists keeps
   version 1 after version 2 is effective`, with two negative controls.
5. **Qualified.** The `core6_pro9` fixture does not exist (X258, still 11a's).
   Proved against a 100,000-row synthetic core-9 database: zero
   `plan_version IS NULL`, zero `plan_id` changed. Finding **X293** says exactly
   what was used and what remains 11a's.
6. Kill and rerun, `test I17 register! killed between assignment batches
   resumes and completes on the next run`, over 5,100 rows so that there is more
   than one productive batch. Exact counts in `i17.md`.
7. Twelve independent connections, `test I17 twelve concurrent register! calls
   insert one row per plan id and version` and `test I17 twelve concurrent
   register! calls reach the same conflict decision` (twelve of twelve).
8. Partial `put_subscription/1`: `test I17 put_subscription with a partial
   attribute map leaves every column it did not send`, plus `test I17
   put_subscription never writes a transition column, even when asked to`.
9. Deleting version 1's block, `test I17 a tenant keeps version 1's limits when
   version 1's block is deleted from the module`, which also asserts the log has
   no `[error]` line.
10. `mix check` and the evidence files, see Commands above and this directory.

## Open defects and weak spots

See `open-findings.md` **X285** to **X294**. The ones a reviewer should weigh:

- **X288**: `plan_effective_at` on a fresh `subscribe/3` is node-stamped. Nothing
  compares it in this release; 07b will, and must move it to a database stamp
  first.
- **X292**: a 1.0.0-rc.1 node cannot flush against a core-9 database. Loud, not
  silent, and it is S6's documented quiescence requirement, but the direction is
  new.
- **X293**: criterion 5's fixture half is 11a's.
- **X287** and **X291**: two negative controls that did not discriminate, each of
  which produced a test that now does.

Three more, smaller, that are not findings:

- **The `:plan_version_conflict` row in `docs/configuration.md` uses an em dash**
  as its "no default" placeholder, because all 25 rows above it do and a single
  row with a different placeholder would read as a broken table. It is the one
  em dash this unit wrote and left in place; every other one was replaced.
- **The criterion-4 and criterion-9 tests swap the plans module with
  `with_config/2`**, which is how a deploy is simulated in a single BEAM. A real
  deploy also recompiles, and no test here can reach that. What the swap does
  reproduce exactly is the thing the criteria are about: the compiled
  definitions change under a subscription that did not.
- **`AuroraMeter.Exporter.JournalTest` failed once, in one full `mix check`
  run, on a `GenServer.stop/3` in its own `on_exit`** (`no process`). It passed
  in isolation immediately afterwards and in both later full runs. It is
  `open-findings.md` X284's shape, in a file this unit does not touch, and it is
  recorded here rather than left as an unexplained green.

## Handoff

### To 07b (scheduled transitions)

- `aurora_meter_plan_transitions` exists, with every column, index and check
  `schema-migration-map.md` S6 lists, and **nothing writes it**.
  `AuroraMeter.Schema.PlanTransition` has a changeset that validates `state`,
  `confirm` and `ref` length, and a unique constraint on `(tenant_key, ref)`.
- `aurora_meter_subscriptions` carries the mirror columns:
  `scheduled_plan_id`, `scheduled_plan_version`, `scheduled_effective_at`,
  `transition_ref`, `transition_state`, `transition_confirm`,
  `transition_applied_at`. All nullable, all NULL today.
- **`transition_confirm`** is `"local"` or `"provider"`: whether the transition
  may be applied locally or must wait for the billing provider to confirm the
  price change. It mirrors `aurora_meter_plan_transitions.confirm` so Pro finds
  due provider work with one indexed keyset query over the subscriptions table
  rather than a jsonb predicate over the transitions table. The partial index
  `(scheduled_effective_at, tenant_key) WHERE transition_state = 'pending'` is
  the one that query uses.
- **None of the transition columns is in `Subscription.syncable/0`**, so
  `Storage.put_subscription/1` cannot write them however it is called. 07b writes
  them through its own path, and `test I17 put_subscription never writes a
  transition column, even when asked to` is the guard.
- `AuroraMeter.Plans.get/2`, `base/1` and `versions/1` are the resolution API.
  `Plans.register!/0` is idempotent and safe to call again.
- **X288 is yours**: stamp `plan_effective_at` from the database before you
  compare it.
- 07b's refusal to apply transitions while any row has `plan_version IS NULL`
  (the build document's "stale workers" row) is still 07b's to implement.

### To 07c (provider mapping and attribution)

- `%AuroraMeter.Plan{}.version` and `Plans.get/2` are what a price map keys on.
  `Plans.versions/1` includes versions that exist only as snapshots.
- `plan_version` is on `aurora_meter_subscriptions` and is safe from
  `Pro.Subscriptions.sync/1` (the S4 fix): it is in `syncable/0`, so a sync that
  **sends** it writes it and a sync that omits it leaves it alone.
- Pro's S8 (Pro schema 11, `usage_reports.plan_id` and `plan_version`) is
  untouched here.

### To 11a

- Core schema version 10 and the assignment are in place; **X293** and **X258**
  are the fixture debt.
- **X292** belongs in the migration matrix: the pairing "core 9 database,
  1.0.0-rc.1 node" now fails on the flush path.
- Both packages' `test_helper.exs` now reset `aurora_meter_plan_versions` before
  the runtime starts. A fixture-based run has to do the same, or registration
  compares a fixture's plans module against the last run's snapshots.
