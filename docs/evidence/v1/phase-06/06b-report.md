# 06b: wallet migration into lots, and the per-wallet cutover

The seven sections `v1-release.md` section 1.2 requires.

## 1. Tasks, repository and revision

| | |
|---|---|
| Build unit | 06b |
| V1 tasks | **06.02** (migrate old wallets), **06.08** (migration safety) |
| Repository | `aurora_meter` (core) only. No Pro file and no storefront file was changed |
| Branch | `aurorameter-v1` |
| Base SHA | `6af77f98c4d37caac89421269fb111c4889d9eee` |
| Tree state | **dirty at hand back, uncommitted.** The author does not commit (programme rule 4) |

New files:

- `lib/aurora_meter/credits/lot_migration.ex`
- `lib/mix/tasks/aurora_meter.credits.migrate_lots.ex`
- `test/support/aurora_meter/test/ledger_fixtures.ex`
- `test/aurora_meter/credits/lot_migration_replay_test.exs`
- `test/aurora_meter/credits_lot_migration_test.exs`
- `test/aurora_meter/credits_lot_migration_resume_test.exs`
- `test/aurora_meter/credits_lot_migration_property_test.exs`
- `docs/upgrading-to-lots.md`
- this directory's `06b-*.md`, `06b-*.json` and `i19-*.md`

Modified files: `docs/api.md`, `docs/correctness.md`, `docs/credits.md`,
`mix.exs` (the new guide in `extras`), `test/test_helper.exs` (the `lotmig` and
`lotprop` sweep prefixes), `test/aurora_meter/clock_test.exs` (the `db_now/0`
allow list), and three files for one suite-wide flake this unit chased down:
`config/config.exs` (`flush_interval` 60 seconds to one hour),
`test/aurora_meter/config_test.exs` and
`test/aurora_meter/config_strictness_test.exs` (the two assertions on that
number). See `open-findings.md` X264.

No DDL. This is schema-migration step S5, a data step against the tables core
schema version 9 already created, and the core schema version is unchanged at
**9**. Package version unchanged at 0.5.0.

## 2. Environment

| | |
|---|---|
| Core schema version | 9 (`AuroraMeter.Migration.latest_version/0`) |
| Pro schema version | 9, unchanged |
| Core package | 0.5.0 at `6af77f9` |
| Pro package | 0.3.0 at `a32112cb6a5dac018bbc395fbe5946ba7cf6ea0c` |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1) |
| Operating system | Linux 6.6.87.2-microsoft-standard-WSL2 (Ubuntu 24.04 under WSL2) |
| Postgres | 16 (`postgres:16` in Docker, port 5490) |
| `sha256sum mix.lock` core | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| `sha256sum mix.lock` pro | `a2140b7e65132ec337fb7e6ac70fbd750b4ade13f1f6b1fb1762d1426bfbac8e` |

## 3. Commands and logs

Every Mix command went through `tmp/v1/mixlane.sh`, which serialises the two
packages against one `_build` each.

| Command | Exit | Result | Log |
|---|---|---|---|
| `mix test` (core, baseline before any change) | 0 | 1467 passed | recorded at the start of the session |
| `mix test test/aurora_meter/credits/lot_migration_replay_test.exs --seed 0` | 0 | 28 passed | `logs/06b-controls-c0.log` |
| `mix test <the three 06b files> --seed 0` | 0 | **58 passed** at the time the controls were run | `logs/06b-controls-c0.log` |
| `mix test --seed 0` (core, final) | 0 | **1530 passed** | `logs/06b-seeds.log` |
| `mix test --seed 1` (core, final) | 0 | **1530 passed** | `logs/06b-seeds.log` |
| `mix test --seed 7` (core, final) | 0 | **1530 passed** | `logs/06b-seeds.log` |
| `mix test --seed 42` (core, final) | 0 | **1530 passed** | `logs/06b-seeds.log` |
| the same four seeds, before the generator and the X264 fix | 0, 0, **2**, 0 | 1526 each except seed 7, which failed the fault harness's own self-test once and passed on rerun (section 6) | earlier run of the same script |
| headless leg: `AURORA_HEADLESS=1`, `compile --warnings-as-errors --force`, `mix run` assertions, `mix test --include headless --seed 0` | 0 | **1442 passed**, "headless ok" | `logs/06b-headless.log` |
| `mix check` (core, final) | 0 | **1530 passed** (57 doctests, 16 properties, 1457 tests), 4 excluded; credo 0 errors; dialyzer clean; docs clean | `logs/06b-check.log` |
| `mix check` (Pro) | 0 | **959 passed** (65 doctests, 894 tests), unchanged from the baseline at `a32112c` | `logs/06b-pro-check.log` |
| `MIX_ENV=test mix run tmp/v1/06b-evidence.exs` | 0 | 14 migrated, 2 blocked | `06b-shadow.json`, `06b-migrate.json` |
| `mix aurora_meter.credits.migrate_lots -r AuroraMeter.TestRepo --tenant <one wallet>` | **0** | shadow: 1 wallet, 3 lots and 2 allocations planned, lock 8 ms, nothing written | `logs/06b-mix-task.log` |
| the same with `--no-shadow` | **1** | the X250 refusal printed in full, nothing read and nothing written, verified afterwards as `lots_enabled_at=nil lots=0 debt=0` | `logs/06b-mix-task.log` |
| `tmp/v1/06b-property-seeds.sh` (the generated-history replay property, seven fixed seeds, 40 histories each) | 0 each | **198 compared, 89 refused, 0 reordered, 0 skipped** | `logs/06b-property-seeds.log` |
| `tmp/v1/06b-control6.sh` (the X262 measurement: the allocator patched to repay debt on a reversal, three seeds, both files restored sha256-identical) | 0 | `hold_unbacked` 1 to 0 and 1 to 0; nothing else moved | `logs/06b-control6.log` |
| the X264 reproduction: `flush_interval: 120` with two non-sandbox modules before `entitlements_test.exs`, seeds 0 to 4 | **2 at one seed of the five** | `I03 ... is not billed`, `left: nil, right: 4`; which seed moves between runs | `logs/06b-flake.log` |
| the same after the fix | 0 at every seed | 38 passed each | `logs/06b-flake.log` |
| `scripts/v1/migrations.sh --fixture core6_pro9` | refusal | fixture not installed (see section 6) | `logs/06b-core6-pro9-refusal.log` |

The `mix check` run and each seed run are the whole core suite; `mix check` also
runs `format --check-formatted`, `compile --warnings-as-errors --force`,
`credo --strict`, `dialyzer` and `docs --warnings-as-errors`.

Test seeds are given above. The three 06b files are run at seed 0 for the
controls so the comparison between control runs is exact.

## 4. Results

### The reconciliation, which is the whole point

Fourteen populated wallet shapes, every one built by calling the shipped
`AuroraMeter.Credits` API against a wallet on the legacy writer, so the figures
the migration is checked against were produced by the shipped legacy arithmetic
and not by the test. Details in `i19-fixture-wallets.md`.

Shadow run, 16 wallets:

| | |
|---|---|
| `shadow_ok` | 14 |
| `blocked` | 2 |
| rows written to `aurora_meter_credit_lots` | **0** |
| rows written to `aurora_meter_credit_allocations` | **0** |
| balance rows changed | **0** (asserted field by field, not by absence of error) |
| run state | `complete_with_blocked` |

Real run, the same 16 wallets:

| | |
|---|---|
| `migrated` | 14 |
| `blocked` | 2, both with the verdict the shadow run had already reached |
| `balance`, `held`, `promotional` unchanged | **all 16** |
| lot identities agreeing with the pre-migration row | **all 14 migrated wallets** |
| informational flags raised | `promotional_clamped`, `reserved_on_expiring_lot` |
| balance-row lock | 14 samples, min 4 ms, median 5 ms, max **9 ms** |

The identity check is read back out of the lots with SQL
(`sum(available) + sum(reserved) - debt`, `sum(reserved)`,
`sum(available + reserved) FILTER (WHERE category = 'promotional')`) and
compared with the wallet's figures **before** the migration. That is the
assertion that fails if the fold reconciled the wallet totals while putting the
value in the wrong lots, which every conservation identity in the package would
otherwise have been satisfied by.

### The oracle, and what happened when it was corrupted

The fold is checked against numbers the legacy ledger wrote: every row's
`balance_after` and `held_after` form an exact chain in commit order, because
each was computed as `row.balance + amount` under the balance row's lock. The
fold's running projection is compared against them **row by row**, and against
the balance row once before the cutover commits (`open-findings.md` X254).

Five negative controls, each breaking exactly one thing and each still
compiling, because the project builds with warnings as errors and a control that
does not compile proves nothing. All 58 tests of the three 06b files, seed 0.
The module's sha256 was identical before and after every control
(`b305e775732c90fef39c9d64d0ff2187980c18220b72d85c6c17b167de5bee46`).

| Control | What was broken | Failed |
|---|---|---|
| C0 | nothing | **0 of 58** |
| C1 | the replay instant: the fixed expiry eligibility applied to history | **18 of 58** |
| C2 | the per-row chain: each comparison made against itself | **6 of 58** |
| C3 | the final comparison against the locked balance row | **1 of 58** |
| C4 | the lot rows written back: every lot claimed fully available | **17 of 58** |
| C5 | the `hold_transaction_id` backfill made a no-op | **1 of 58** |

C2 and C3 together are the X242 question answered: the two oracles are **not**
redundant, and the per-row one is much the stronger. Disabling the per-row chain
does not merely lose six assertions, it stops **two blocking flags firing at
all** (`history_out_of_order` and `promotional_divergence`), so a wallet whose
history cannot be ordered would have been migrated. Disabling the final
comparison costs one test, and that one is the case the chain cannot see: a
balance row that had already drifted from its own log.

C1 is the design decision of this unit made falsifiable. C4 shows the
conservation check and the table's CHECK constraints are carrying real weight
and not decoration. C5 shows the L9 backfill has exactly one test and that test
discriminates.

### The generated histories, which are where the real findings came from

`06b-generated-histories.md` in full. Seven fixed seeds, forty legacy histories
each, executed through the shipped `AuroraMeter.Credits` API against a legacy
wallet and then replayed and cut over: **198 compared, 89 refused, 0 reordered,
0 skipped**, and the module raises in its own teardown if it ever compares
nothing.

It found three things the fourteen hand-chosen wallets did not, and the first
appeared in the first ten histories:

1. **X261**, an expiry that destroyed the grant a hold had reserved. The legacy
   sweep clamps by `max(balance - held, 0)` for the whole wallet, so another
   grant covering the held amount lets it reach this one. Off by exactly one
   micro-dollar on a 522,138 grant.
2. **X262**, `Allocator.plan/2`'s `{:reverse, ...}` creating debt without
   repaying it, which leaves the book in a state 06a's own LI-06a-5 forbids.
   Measured rather than argued (control C6): fixing it closes `hold_unbacked`
   entirely and **buys nothing else**, against a prediction, written down
   first, that it would also close the promotional divergences.
3. **X263**, and this is the one that matters most. The hand-built
   `promotional_divergence` fixture is a refund clamp, and **the refund clamp
   appeared zero times in 280 generated histories**. Fifty four divergences
   appeared, every one from a `debit`, a `settle`, a `grant` or a `release`,
   because `promotional_delta/2` subtracts a whole spend from `promotional`
   even when a hold has reserved part of it. Sixty seven of the eighty nine
   refusals come from that missing idea and from X261's version of it.

So this unit had named the wrong mechanism as the common one, and the generator
corrected it.

### The refusals

Fourteen blocking flags, each with a wallet built to trigger it, each asserting
four facts: the wallet is `blocked`, `lots_enabled_at` stays null, zero lot rows
and zero allocation rows exist, and the checkpoint row carries the reason. The
catalogue with the arithmetic is `06b-blocked-catalogue.md`.

Ten of the fourteen are produced through the shipped API. Four are histories
the API refuses to produce (an orphan settle, an orphan release, a row of a kind
nothing writes, an expiry larger than its grant) and are written directly, which
is the point of them. The fourteenth, `expire_reserved_grant`, exists because
the generated-history property found the shape and the shape needed a flag of
its own.

One of the thirteen, `promotional_divergence`, is earned by a **healthy** 0.4.0
wallet: the legacy clamp destroys promotional attribution the lot model
preserves, so a refund that drove the balance into debt past live promotional
credit leaves the two accounts genuinely disagreeing. Recorded as
`open-findings.md` X257, and it is a limit on how much of the installed base
this migration can reach.

### Interrupt, resume and contention

`i19-interrupt.md`. A kill inside a wallet's transaction leaves the wallet
entirely untouched and the rerun migrates it exactly once; a kill between two
wallets leaves exactly one committed and the rerun takes the other two, once
each; two runs racing one wallet, held at a rendezvous until Postgres reports
**two** backends waiting on the balance row, produce `[:migrated, :skipped]` and
one lot per grant row.

The waiter count is asserted on an ordinary run rather than printed behind an
environment variable (X214), and the query is `pg_stat_activity` rather than
`pg_locks` filtered by database, which would have returned nothing (X186).

### A defect found in this unit's own evidence run

The first draft skipped a wallet a previous run had blocked without reporting
it. The evidence run made it visible: the shadow run reported two blocked
wallets and exited non-zero, and the real run that followed reported
`blocked 0` and would have exited **zero** with both wallets still on the legacy
writer. A later run now reports such a wallet as `blocked` with the reason
`blocked_before`, without repeating the replay and without overwriting the
reasons the first run wrote, and
`test I19 a wallet a previous run blocked is still counted as blocked by the next one`
is what stops it returning.

### Pro

Pro's suite was run although no Pro file was touched (`open-findings.md` X252: a
unit that changes core's surface changes Pro whether or not a Pro file is
edited). Result in section 3. This unit adds no column, no constraint and no
schema module, so the mechanism X252 describes cannot be triggered by it; the
run is the check that says so rather than the argument.

## 5. Changes

**Public API.** One new module, `AuroraMeter.Credits.LotMigration`, with
`run/1`, `status/1`, `replay/2`, `checkpoint_name/1` and `cutover_blocked/0`;
one new Mix task, `mix aurora_meter.credits.migrate_lots`, whose `report/1` is
public so the maintainer suite can assert the exit decision itself. All listed
in `docs/api.md` section 1.16 and section 8.

**Telemetry.** One new event,
`[:aurora_meter, :credits, :lot_migration]`, measurements
`wallets`, `migrated`, `blocked`, `deferred`, `rows`, `duration_ms`, metadata
`shadow`, `state`. Emitted once per run.

**Configuration.** None added. Every bound is a call option.

**Migrations.** None. S5 is a data step.

**Existing behaviour.** Unchanged. No existing function's body, return shape,
telemetry or PubSub message was touched. `lib/aurora_meter/credits/ledger.ex`,
`promotions.ex` and `allocator.ex` are byte identical to `6af77f9`.

**Documentation.** New operator guide `docs/upgrading-to-lots.md`, added to
`mix.exs`'s `extras`. `docs/credits.md` gains "which wallets are on it" and
"moving a wallet onto lots". `docs/correctness.md` gains 42 test bullets under
I19, I12 and I10.

**Operational procedure.** A new one, and it is the reason the guide exists: run
shadow, read the blocked list, deal with it, run for real, read the report. The
real run is currently refused (section 6).

## 6. Open defects

Twelve findings were raised, `open-findings.md` **X253** to **X264**. In order
of how much they matter to the release:

- **X263** and **X261** together are the largest. Two thirds of every refusal
  the generated histories produced comes from the legacy ledger keeping one
  `promotional` and one `held` figure per wallet with no record of which grant
  a hold reserved. Both figures can therefore be wrong in ways the lots make
  visible and cannot reproduce, so **a wallet that has ever combined
  promotional credit with a hold is likely to be unmigratable.** Nothing is
  fixable in the frozen 0.4.0 ledger; what is owed is that somebody sizes the
  population against production data before the lot migration is planned as a
  fleet-wide move.
- **X262.** `{:reverse, ...}` creates debt without repaying it, breaking 06a's
  own LI-06a-5. Owed to 06e, which is the unit that can add the debt to the
  request tuple.
- **X264.** The suite's "large" flush interval was 60 seconds against a 220
  second suite. Reproduced deterministically and fixed in the test
  configuration.

- **X250 (not new, and it governs this unit).** `Credits.reverse/4` does not
  take the lot path, so a cut-over wallet would let a paid refund consume
  promotional lots. **No wallet is cut over by this unit outside the maintainer
  suite.** `run/1` refuses `shadow: false` with
  `{:error, {:cutover_blocked, %{finding: "X250"}}}`, the Mix task prints the
  refusal and stops, and the gate is behavioural rather than a version number:
  it asks whether `AuroraMeter.Credits.reverse_lot/4` exists, so 06e opens it
  and nothing else can.
- **X257.** A wallet that took a refund into debt while holding live
  promotional credit cannot be migrated automatically, for ever. Somebody should
  count how much of the installed base is in that state.
- **X255.** The build document's "a wallet created after the deploy is born with
  `lots_enabled_at` set" is unimplementable while X250 stands, and 06a was right
  not to implement it. Not implemented and not tested here; owed to 06e.
- **X253.** The build document's fold table applies the fixed I12 release
  semantics during the replay, which double counts. Corrected here; the document
  and `architecture-map.md` 7.4 should be corrected too.
- **X254.** The per-row `balance_after` chain is an oracle nobody had noticed,
  and it is stronger than the final comparison. `architecture-map.md` 7.4's
  `(inserted_at, id)` should say so.
- **X256.** `debit_unbacked` is specified as a block and should not be one.
- **X258.** The two disposable-database evidence runs the document names could
  not be taken: `scripts/v1/migrations.sh --fixture core6_pro9` refuses until
  11a supplies the fixture dumps, which is correct behaviour. The runs were
  taken against the package's own test database instead and the JSON says so in
  `meta.note`.
- **X259.** The allocator has no "expire exactly this much from this lot"
  operation, so the fold builds that one movement itself. Named because "every
  row goes through the planner" is a claim this unit cannot honestly make
  without the exception.

- **X260.** `AuroraMeter.Test.Kill.run/2` monitors the worker after starting it,
  so under the load of a full suite the worker can die before the monitor and
  the harness reports `:noproc` instead of `:killed`. It failed the harness's
  **own** self-test at seed 7 and passed on rerun at the same seed. Shared test
  infrastructure that 01b owns and that every kill test in both packages goes
  through, so it is named rather than patched inside a unit about money.

Two flakes were seen. **One was chased to ground and fixed**; the other is
named mechanically and belongs to shared test infrastructure.

1. `AuroraMeter.EntitlementsTest` / `I03 a callback that flushed and then exits
   is not billed`, seen once at an unrecorded random seed with
   `Storage.load_counter/3` returning `nil` where it expected 4. The hypothesis
   was X241's mechanism, and it held: with `flush_interval` lowered to 120 ms
   and two non-sandbox modules running before `entitlements_test.exs`, one
   seed in a sweep of five fails with the same `left: nil, right: 4`. **Which
   seed moves between runs** (4 on the first sweep, 3 on the recorded one),
   which is what says it is a race against a timer rather than a
   seed-dependent fact, and is why rerunning the original seed proved
   nothing. The Flusher's
   periodic timer fires while no sandbox owner is in shared mode, the flush
   raises for want of a connection, the batch is correctly kept pending, and
   the next test's explicit flush persists that stale batch instead of its own
   counters. **The suite's interval was 60 seconds against a 220 second suite**,
   so it fired three or four times per run at arbitrary points, under a comment
   claiming it never fired at all. Fixed in the test configuration by raising
   it to one hour, which is longer than any run, so the timer cannot fire
   during one rather than firing less often. The reproduction passes at every
   seed after the change (X264).
2. The X260 `:noproc` above, seen once at seed 7 in the four-seed sweep and not
   reproduced: the same seed passed on rerun with 1526 passing, and
   `harness_test.exs` passed three times in a row on its own. The mechanism is
   written out in the finding, the fix is one barrier in `kill.ex`, and it is
   shared infrastructure that 01b owns and that 11b is about to reuse, so it is
   named rather than patched from inside a unit about money.

## 7. What is proven, and what is not

### Proven

- Fourteen populated legacy wallet shapes replay into lots with `balance`,
  `held` and `promotional` byte identical before and after, verified twice: once
  through the public API and once by reading the lots back with SQL.
- Every allocation names the ledger row that caused it and the lot it moved, and
  one lot exists per grant row, counted by `COUNT(*)` against
  `COUNT(DISTINCT grant_transaction_id)`.
- Thirteen distinct reasons a wallet is refused, each with a wallet that
  triggers it and each leaving that wallet with zero lots, zero allocations, a
  null `lots_enabled_at` and a working legacy writer.
- Shadow mode writes no lot, no allocation and no balance change, and reaches
  the same verdict as the real run that follows it.
- One wallet is one transaction: killed inside it, the wallet is untouched;
  killed between wallets, the rest are taken by the rerun, once each.
- Two concurrent runs serialise on the balance row with the contention forced
  and the waiter count asserted, and migrate the wallet exactly once.
- A write committed during the snapshot is folded in from the tail, proved by
  `--max-tail 0` deferring the wallet rather than by hoping the window was hit.
- `hold_transaction_id` is backfilled on every settle and release row, and the
  precondition (that they were null) is asserted first.
- A tenant key that is not a legal `AuroraMeter.Operations` name still gets a
  checkpoint, still pauses and still resumes.
- The whole of it works with no optional dependency in the build.

### Not proven

- **No real wallet has been cut over, and none may be until 06e lands.** Every
  migrated wallet in this evidence is a synthetic fixture and the cutover ran
  behind a maintainer-only door.
- **Not against a populated `core6_pro9` database.** X258. These wallets were
  built by today's code on today's schema and then aged; a real 0.4.0 database
  has rows written by code that no longer exists. 11a owns that.
- **Not against a wallet of realistic size.** The largest fixture has six ledger
  rows and three lots. The lock durations are a floor, not a bound, and the lot
  count distribution of a real installed base is unknown (X248).
- **The generated histories are not adversarial about ordering.** The property
  reported `reordered by seq: 0` across 280 histories: no wall-clock backwards
  step occurred on this host during those runs, so the `seq` retry path was
  never exercised by the generator and rests on named tests alone. A generator
  that could **inject** a backwards stamp mid-history would be stronger, and
  01e's executor abandons such a history as inconclusive rather than producing
  one deliberately.
- **The compatibility criterion is only partly met.** The build document asks
  that the whole of `credits_test.exs` pass against migrated wallets. It is not
  re-run with a migrating setup: every test in it creates its own tenant and
  exercises the legacy path deliberately, and migrating inside its setup would
  change what those tests are about. What is proved instead is that a migrated
  wallet keeps answering `grant`, `hold`, `settle`, `debit`, `balance` and
  `history` with the same shapes
  (`I19 a migrated wallet keeps answering the public credit API`), and that 06a's
  `credits_lots_test.exs` exercises the same public surface on the lot path.

- **The migration's reach is much smaller than this unit assumed, and nobody
  has measured it on real data.** 89 of 287 generated histories could not be
  migrated, and two thirds of those refusals come from the legacy figures not
  knowing which grant a hold reserved (X261, X263). Whether real wallets look
  like generated ones is exactly the thing this evidence cannot say.

### G06, bullet by bullet

| Bullet | This unit's contribution |
|---|---|
| 1. A=3, B=5, P=10, a 6 USD debit takes 3 and 3 | contributed. 06a proves it in the engine; this unit proves the same shape **replayed out of a legacy history**, in the fold and again at the database |
| 2. Concurrent holds cannot allocate the same micro-USD twice | nothing. 06a owns it; this unit's concurrency is between two migration runs, not two holds |
| 3. Expiry racing settlement and release preserves conservation | contributed, from the other side: the replay reproduces the **pre-cutover** behaviour exactly (`I12 a hold spanning a partial expiry replays without moving the money`) and names every wallet where the fixed rule will change something, flag `reserved_on_expiring_lot` |
| 4. A replayed ledger reconstructs balance, debt, held and every lot's allocations after arbitrary valid sequences | **met for the legacy replay.** Fourteen hand-chosen shapes plus 198 generated legacy histories compared at seven fixed seeds, each checked row by row against the log, at the end against the balance row, and lot by lot against a fold of that lot's own allocations. 06a owns the same bullet for the runtime |
| 5. A refund of a spent paid lot does not erase later promotional credit or exceed the payment's net reversible grant | contributed: `reversal_exceeds_lots` blocks a reversal larger than its payment ever granted, and the refund fixture lands on that payment's own lot. The **runtime** half is 06e's, and X250 is exactly that gap |
| 6. Recurring grants, retries, clock boundary, two nodes | nothing. 06d owns it |
| 7. **Upgrade populated core-6 / Pro-9 histories with pending holds, promotions, debt and refunds without monetary drift; no blanket destructive down migration** | **owned here, and half met.** The drift half is proved on fourteen populated wallets that between them carry pending holds, promotions with and without expiry, partial expiry, debt from a settlement overrun, refunds, disputes, reconciliations and reinstatements. The `core-6 / Pro-9` half needs 11a's fixture (X258). The down-migration half is `9 in AuroraMeter.Migration.data_loss_versions()`, proved by 06a in `migration_v9_test.exs` |
