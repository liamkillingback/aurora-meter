# 06d: recurring grants, capped rollover and downtime catch-up

Build unit 06d, V1 task **06.05**, gate G06 bullet 6. Written to the seven-item
format of `v1-release.md` 1.2.

## 1. Tasks, repository and exact source

| | |
|---|---|
| V1 task | **06.05** (recurring engine), taken from the 06d row of `docs/v1/build-plans/README.md` |
| Repository | core `aurora_meter` only |
| Branch | `aurorameter-v1` |
| Base SHA | `011ac346e7cbdc23c5ef8870b17b2e002ccbb56a` |
| State at hand-back | **dirty, uncommitted by instruction** |
| Patch sha256 (tracked files, `git diff \| sha256sum`) | `fee0bf6dc72240b3873cadb57b7504182f13f9acaf86ef8878ceb38d31b37507` |

Modified, tracked: `.formatter.exs`, `CHANGELOG.md`, `docs/api.md`,
`docs/correctness.md`, `docs/credits.md`, `docs/operations/scheduler.md`,
`docs/plans.md`, `lib/aurora_meter/credits.ex`,
`lib/aurora_meter/credits/ledger.ex`, `lib/aurora_meter/oban.ex`,
`lib/aurora_meter/oban/recurring_grants.ex`, `lib/aurora_meter/plan.ex`,
`lib/aurora_meter/plans.ex`, `test/aurora_meter/api_inventory_test.exs`,
`test/aurora_meter/oban/workers_test.exs`, `test/aurora_meter/oban_test.exs`,
`test/aurora_meter/plans_test.exs`,
`test/support/aurora_meter/test/connections.ex`,
`test/support/aurora_meter/test/storage_fakes.ex`,
`test/support/period_sources.ex`, `test/support/test_plans.ex`,
`test/test_helper.exs`.

New, untracked: `lib/aurora_meter/credits/recurrences.ex`,
`lib/aurora_meter/schema/credit_recurrence.ex`,
`test/aurora_meter/credits/recurrences_periods_test.exs`,
`test/aurora_meter/credits_recurrences_test.exs`,
`test/aurora_meter/credits_recurrences_concurrency_test.exs`, and this evidence
directory.

**Pro**, at `20f29a63e3255141360c550d55ee96855c0a63e0` on `aurorameter-v1`: one
test-support file changed, `test/support/aurora_meter/pro/test/connections.ex`
(patch sha256 `ce0f873be837976114f21d33a45cdd7c4b34836da6b8c6f17654392e3515f58b`).
No Pro `lib/` file, no Pro migration, no Pro version change. See item 6.

Storefront at `9f310334d54cf413e18bb75e524f2ce3f4cf1ce6`, unchanged by this unit
apart from `docs/v1/build-plans/open-findings.md`, the README row and the release
manifest.

## 2. Schema, toolchain and environment

| | |
|---|---|
| Core schema version | **9, unchanged.** No DDL. `aurora_meter_credit_recurrences` was created by 06a's V9 and this unit is its first writer |
| Core package version | 0.5.0, unchanged |
| Pro schema version | 9, unchanged |
| Elixir / OTP | 1.20.1 / Erlang 29 (erts 17.0.1) |
| Operating system | Ubuntu 24.04.4 LTS on WSL2 (kernel 6.6.87.2) |
| Database | PostgreSQL 16.13 (Debian), port 5490, database `aurora_meter_test` |
| Core `mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| Pro `mix.lock` sha256 | `a2140b7e65132ec337fb7e6ac70fbd750b4ade13f1f6b1fb1762d1426bfbac8e` |

## 3. Commands, exit codes and artefacts

Every Mix command went through `tmp/v1/mixlane.sh`, which serialises against one
package `_build`. All runs 2026-09-15 (UTC), seed 0 where a seed applies.

| command | exit | result |
|---|---|---|
| `mix check` (core) | **0** | 1642 passed (73 doctests, 17 properties, 1552 tests), 4 excluded. Baseline at `011ac34` was 1583 |
| `mix check` (Pro) | **0** | 966 passed (66 doctests, 900 tests). Baseline 966 |
| `tmp/v1/06d-core-headless.sh` | **0** | `AURORA_HEADLESS=1`, `mix compile --warnings-as-errors --force` exit 0, the probe printed `headless ok`, `mix test --include headless --seed 0` gave **1553 passed**. Baseline 1495 |
| `mix test test/aurora_meter/plans_test.exs --seed 0` | 0 | 23 passed (3 doctests) |
| `mix test test/aurora_meter/credits/recurrences_periods_test.exs --seed 0 --trace` | 0 | 13 passed (4 doctests) |
| `mix test test/aurora_meter/credits_recurrences_test.exs --seed 0` | 0 | 30 passed (1 doctest) |
| `mix test test/aurora_meter/credits_recurrences_concurrency_test.exs --seed 0 --trace` | 0 | 5 passed |
| `tmp/v1/06d-controls.sh` | see item 4 | the two patch-and-measure negative controls |
| `tmp/v1/06d-evidence.sh` | 0 | the tables in `i18-*.md`, `06d-dsl.md` and `06d-boundary.md` |

Logs: `logs/06d-evidence.txt`, `logs/06d-controls.log`,
`logs/06d-core-headless.log` (dependency resolution lines stripped; nothing else
removed). No credential, key or customer identity appears in any of them; every
tenant key is a synthetic `ev6d_*`, `recur*` or `headless_06d_*` value.

## 4. Expected and actual results

### The acceptance criteria, and where each is proved

| # | criterion | where |
|---|---|---|
| 1 | one lot of 5,000,000 expiring at the period end, one recurrence row with the policy snapshot, one grant row with the period's reference | `test I18 one run grants one lot per entitled tenant for the current period` |
| 2 | two schedulers, fifty tenants, fifty recurrence rows, fifty grants, zero duplicate lots | `i18-once-per-period.md`; 50 granted, 50 duplicate of which **35 conflicts**, 50 rows, 50 + 50 lots, every tenant at 6,000,000 |
| 3 | five runs in one period: one grant, four duplicates | `test I18 running the job five times in one period produces one grant and four duplicates`: `granted [1,0,0,0,0]`, `duplicate [0,1,1,1,1]` |
| 4 | the two rollover cases and their expiry | `i18-rollover.md`, July and August rows |
| 5 | two idle periods carry the cap, never twice the cap | `i18-rollover.md`, August and September: the third period holds 6,000,000, not 7,000,000 |
| 6 | three historical periods issued and expired in one transaction each, zero availability, plus one live period with the capped carry | `i18-catchup.md`: 7 historical lots, 23,000,000 granted, **0 available**, live period 6,000,000 |
| 7 | a plan edit changes the new period and not a retry of the old one | `test I18 a plan edited between two periods grants the new amount and keeps the old cap`, and control A below |
| 8 | `Credits.grant(tenant, 1, reference: "recurring:anything")` raises | `test I18 the recurrence reference namespace is rejected for a manual grant`, over all five facade functions |
| 9 | pausing makes a run return `%{paused: true}` and write nothing | `test I16 a paused run writes nothing and says it is paused`. **The name is `"credits_recurrences:global"`, not `"credits_recurrences"`** (finding X272) |
| 10 | a run killed mid-tenant resumes and reaches the same state | `test I16 a run killed mid-tenant resumes and reaches the same state as an uninterrupted one` |
| 11 | a tenant whose period source raises is skipped and the run continues | `test I18 a tenant whose period source raises is skipped and the run continues` |
| 12 | `mix check` passes in core | exit 0, item 3 |

### Reconciliation totals

`i18-rollover.md`: six periods, 30,000,000 granted as allowances plus 5,000,000
carried, against 20,000,000 expired, 9,000,000 consumed and 6,000,000 still
available. `35,000,000 = 20,000,000 + 9,000,000 + 6,000,000`. The balance row
agrees with the lots on every write, because `Allocator.check!/4` re-reads the
lot sums from the database and raises `ConservationError` if they disagree; it
runs as the last statement of every one of this unit's writes.

`i18-catchup.md`: 23,000,000 granted across the historical periods, 23,000,000
expired, 0 available; 6,000,000 granted live and 6,000,000 available.

### Negative controls, and whether they discriminated

**Control A: the rollover cap read from the compiled plan instead of the stored
snapshot.** Ran. **It discriminated**, and by exactly the intended number: one
test of thirty failed, `rollover` 3,000,000 against the expected 1,000,000.
`recurrences.ex` restored sha256-identical
(`2802dd90f3cfdd570b6f2604eb132338864a3e39b1ebb85d490a68c9d8fdba5c` either side),
30 of 30 after the restore.

The control had to be written twice, and the first attempt is worth recording:
removing the call to `stored_rollover/1` left it unused, and this project
compiles its own sources with `warnings_as_errors: true`, so the control did not
compile and the run reported exit 1 rather than a test failure. A control that
does not compile proves nothing; the second version keeps the call and discards
the value.

**Control B: a reference that is not stable for the period, under the forced
rendezvous.** Ran. **It discriminated**: two `:new` grants and two lots per
round, 10,000,000 where 5,000,000 was owed, with `contended == 4 of 4`.

**Control C: the recurrence row's guard removed, the ledger's index left.** Ran.
**It discriminated in the direction that matters**: one `:new` and one
`:duplicate` per round, one lot. It proves the two guards are independently
sufficient rather than one of them being decorative.

**Control D: the reference the build document specifies.** Ran. **It
discriminated**: five of thirty tests failed, including `granted == 1` where two
tenants each expected one grant. Recorded as finding X273.

**Control E: the `max_periods` bound.** Inline, in
`test I18 the walk stops at max_periods and reports the remainder`: the same call
with the budget removed returns 8 periods where the bounded one returns 3.

## 5. Changes to public API, configuration, migrations, telemetry and docs

**Added.** `AuroraMeter.Plans.recurring_credits/2` (DSL macro);
`%AuroraMeter.Plan{recurring_credits: [...]}` and
`t:AuroraMeter.Plan.recurring_credit/0`; `AuroraMeter.Credits.Recurrences` with
`run/1`, `status/1`, `periods/4`, `namespace/0` and `operation/0`;
`AuroraMeter.Schema.CreditRecurrence` with `changeset/2` and `states/0`;
telemetry `[:aurora_meter, :credits, :recurrence]`; the operation and checkpoint
name `"credits_recurrences:global"`.

**Changed (compatibility).** References beginning `recurring:` are reserved:
`Credits.grant/3`, `grant_with_status/3`, `hold/4`, `debit/4` and `reverse/4`
raise `ArgumentError` for a caller-supplied reference with that prefix. Named in
the changelog's Changed section as a release note. Nothing else is reserved.

`AuroraMeter.Oban.RecurringGrants` now appears in
`AuroraMeter.Oban.cron_entries/0` at `"7 * * * *"` and runs its operation instead
of cancelling with `{:cancel, :not_implemented}`. **The worker's own source
changed only in its moduledoc and its argument mapping**: the availability check
is evaluated at call time, so the operation arriving is what moved it. That is
05a's design working, and `docs/operations/scheduler.md` now says so.

**Migrations:** none. No DDL of any kind; core schema stays at 9.

**Configuration:** none added. The policy lives in the plan and the bounds are
call options.

**Docs:** `docs/plans.md` gains "Recurring credit allowances";
`docs/credits.md` gains "Recurring allowances"; `docs/api.md` gains section 1.18,
the DSL macro row, two schema rows, the telemetry literal and a rewritten Oban
worker row; `docs/operations/scheduler.md` gains the schedule and the argument
recipe; `docs/correctness.md` I18 is rewritten from "not guaranteed by the
shipped code" to the guarantee, with 47 tests indexed; `CHANGELOG.md` gains
Added and Changed entries.

**Operational procedures:** an operator pauses the sweep with
`AuroraMeter.Operations.pause("credits_recurrences:global")` and reads
`AuroraMeter.Credits.Recurrences.status/1`. Both are documented in
`docs/credits.md`.

## 6. Open defects, limits and next tasks

**X273 (new, this unit).** The build document's recurrence key doubles as the
grant reference, and `aurora_meter_credit_transactions` is `UNIQUE (kind,
reference)` **across every tenant**, so two tenants on one plan reaching one
period collide. Measured: control D, five failing tests. Resolved in the
implementation by putting the tenant key in the reference and leaving the
per-tenant `key` column exactly as `architecture-map.md` 7.1 specifies it.

**X274 (new, this unit).** The engine requires the wallet to be on the lot
engine, and no wallet is, because 06b's cutover is fenced behind X250 until 06e
wires `Credits.reverse_lot/4`. So recurring grants are implemented, tested and
documented, and are **not reachable on an existing production wallet today**.
This is a sequencing consequence rather than a defect, and it is stated in
`docs/credits.md` and in `AuroraMeter.Credits.Recurrences`'s moduledoc where a
host will meet it.

**X275 (new, this unit).** Adding one core schema module changed what **Pro's**
test harness must clean up, and only running Pro's suite said so. This is X252's
shape again in a place X252 did not predict.

**X272 (resolved here).** Criterion 9's `"credits_recurrences"` raises;
the shipped name is `"credits_recurrences:global"`.

**Known limits, all deliberate and all documented.** No back-pay before a
tenant's first recurrence row; no pro-ration for a mid-period adoption; every key
carries plan version `"1"` until 07a; a plan transition landing inside a period
is 07b's to order, and this engine refuses a tenant whose plan changed rather
than granting the old plan's allowance; a historical grant repays outstanding
debt out of a lot that is then expired, which is arguably generous to a tenant
who was never able to spend it and is the simplest defensible rule.

**No test is skipped.** The only excluded tag in core is `:headless`, and the
headless leg runs it (1553 passed).

### Is a recurrence row shape safe for 06b's migration fold?

**Yes, and for a stronger reason than it handling them: it never sees them.**
06d writes no new row shape at all. Its allowances go through 06a's
`grant_with_lots/4` and its expiries through 06a's `expire_lot_locked/4`, so the
`kind` values it produces are `:grant` (category `:promotional`) and `:expire`,
both of which `LotMigration.step/2` has had a clause for since 06b. Checked
rather than assumed, because X266 is what happens when it is assumed.

The reason it never sees them is the stronger one: the fold replays a wallet's
legacy ledger into lots, and it runs only on a wallet whose `lots_enabled_at` is
null. 06d refuses exactly those wallets. A wallet the fold will ever read
therefore cannot contain a recurrence row.

One thing worth handing on, and it is **06a's** rather than 06d's:
`LotMigration.expire_target/2` resolves an expire row through
`row.metadata["grant_id"]`, and `Ledger.lot_expire_metadata/3` writes `"lot_id"`,
`"grant_reference"`, `"lot_amount"` and `"expired_amount"` instead. So **any**
lot-path expire row would flag `:expire_unattributed` if it ever reached the
fold. It cannot today, for the reason above. It is recorded here because 06e
opens the cutover gate, and anything that later replays a cut-over wallet's rows
has to know it.

### Weak spots, named

**The contended-branch count is machine-dependent.** 35 of 50 duplicates were
conflicts on this machine; the test asserts `conflict > 0` and reports the
number, because the machine decides how many of the fifty pairs really overlap.
The forced-rendezvous test is what makes the count deterministic (6 of 6), and it
runs six rounds rather than fifty.

**The fifty-tenant test's `duplicate == 50` assumes each tenant is visited by
exactly two runs**, which the harness guarantees by construction
(`div(i - 1, 2)`). If that ever changed the assertion would move with it, and it
would still be a real assertion: what it rules out is a tenant granted twice.

**A historical grant repays outstanding debt out of a lot that is then
expired.** `Allocator.plan/2`'s `:grant` clause repays debt from the new lot
before anything else, and it does not ask whether the lot is already past its
expiry. So a wallet in debt that is caught up three periods has its debt reduced
by allowances it was never able to spend. That is arguably the tenant-friendly
reading and it conserves exactly; it is not a reading this unit chose
deliberately, and a later unit that disagrees should change the allocator rather
than the engine.

**The catch-up rollover chain runs through periods that were never spendable.**
July carries out of June even though June's allowance was issued and expired in
the same transaction. That reproduces the chain a timely run would have
produced, which is the build document's rule, and it means a tenant caught up
after three months of downtime reaches its live period with the full capped
carry. The alternative (carry nothing through history) would punish a tenant for
the host's outage, and neither reading is forced by `v1-release.md` 10.1.

**`run(tenant: ...)` writes no checkpoint.** The explicit-tenant path skips
`Operations.run_batches/3` entirely, so it has no cursor and no batch boundary;
it still reads the pause. That is right for an operator running one tenant by
hand, and it means every test that drives one tenant proves nothing about the
cursor. The cursor is proved by the two scan tests instead, which delete the
subscriptions table inside the sandbox so the scan is deterministic.

**The summary counts rather than names.** The build document says a run that hit
`:max_periods` "reports the tenant and the periods remaining". It reports
`counts["catching_up"]`, a number, because `Operations.run_batches/3` merges two
batches' counts by adding numbers and **replacing** anything else, so a list
accumulated across batches would silently become the last batch's list. The
tenant is in the telemetry event and in its own recurrence rows, and
`status(tenant: ...)` reads them back. The alternative was widening 05c's shared
merge, which is a change to every worker in both packages for one unit's
convenience.

**The 06b generated-history property was not re-run.** X263 measured the
migration reaching about two thirds of generated wallets, and this unit could
not have changed that number (it writes nothing a legacy wallet can contain),
but that is an argument rather than a measurement. `mix check` runs
`credits_lot_migration_property_test.exs` and it is green, which is the weaker
statement that the fixed seeds are unchanged.

**Next tasks.** 06e (Pro lot integration) opens the cutover gate that X274
depends on. 07c makes recurring grants use the effective plan version for the
period, which is the one place the literal `"1"` in the key has to change.

## 7. Handoff

A fresh agent needs `docs/v1/build-plans/phase-06/06d-recurring-grants-and-rollover.md`
for the contract, this directory for what was measured, and three files for the
code: `lib/aurora_meter/credits/recurrences.ex` (the engine: options, the scan,
the period walk, the counters and the telemetry),
`lib/aurora_meter/credits/ledger.ex` from `recurrence/2` to
`rollover_from/2` (one period's whole transaction, under the wallet's balance row
lock), and `lib/aurora_meter/plans.ex` from `recurring_credits/2` to
`recurring_error/3` (the DSL and every compile-time refusal).

The three seams to know:

* **The engine decides which periods and what policy; the ledger decides nothing
  except how to write it.** Everything a period does is a ledger write, and the
  lock order (`architecture-map.md` 7.3) is the ledger's to keep, so
  `Ledger.recurrence/2` is one transaction that takes the balance row first and
  then does the whole period. The engine passes a request map including a `gate`
  closure, which is how the entitlement re-check happens under the lock without
  the ledger learning about subscriptions.
* **Two clocks.** `Clock.now/0` chooses the period (a wall-clock question);
  `Clock.db_now/0`, through `Ledger.lot_instant/0`, decides everything inside the
  transaction (compared against columns this database stamped). Ordering takes
  `period_start` and `seq`, never a clock.
* **`duplicate` and `conflict` are counted separately** because only the second
  is the branch two schedulers racing take, and a test that could not tell them
  apart would report a race it never had.

To re-run everything: `bash tmp/v1/06d-check.sh` (core `mix check`),
`bash tmp/v1/06d-pro.sh` (Pro `mix check`),
`bash tmp/v1/06d-core-headless.sh` (the headless leg; it removes
`_build/test/lib/{aurora_meter,oban}`, so run `bash tmp/v1/06d-restore2.sh`
afterwards or the next `mix test` compiles without Oban),
`bash tmp/v1/06d-controls.sh` (the two patch-and-measure controls) and
`bash tmp/v1/06d-evidence.sh` (the tables).
