# 06a: credit lot and allocation schema, and the single allocation engine

Build unit **06a**, V1 tasks **06.01** (model and schema) and **06.04**
(allocation engine). Core only. Author agent; the reviewer ticks the acceptance
criteria (programme rule 4), so every checkbox in the build document is left
unticked here.

## 1. Identity and dirty state

| | |
|---|---|
| Repositories | `aurora_meter` (core) and `aurora_meter_pro` (Pro), branch `aurorameter-v1` in both |
| Base SHA | `57996c569228ff76f47f5395ed87379880caf1a5` (`57996c5`) |
| Working tree | **dirty**: this unit is uncommitted. The owner reviews and commits. |
| Pro base SHA | `7fc19ff`, **and this unit does touch Pro**: see section 3.6 |
| Storefront | untouched by this unit |

Files changed and added are listed in section 5.

## 2. Versions, toolchain and environment

| | |
|---|---|
| Core schema version | **8 to 9** (`AuroraMeter.Migration.latest_version() == 9`) |
| Pro schema version | 9, unchanged |
| Core / Pro pair under test | core 9 / Pro 9 |
| Elixir | 1.20.1 |
| Erlang/OTP | 29, erts 17.0.1, jit, smp 24:24 |
| Operating system | Linux 6.6.87.2-microsoft-standard-WSL2 (WSL2 on Windows 11) |
| Database | PostgreSQL 16.13 (Debian 16.13-1.pgdg13+1), port 5490 |
| `mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| Test pool size | raised from 30 to 60, for the fifty-connection hot-wallet test |

## 3. What was built

### 3.1 Schema version 9 (`schema-migration-map.md` S4)

`AuroraMeter.Migration.V9`, in its own file under `lib/aurora_meter/migration/`
like V6 to V8. Additive, transactional, and it **writes no data**.

New tables: `aurora_meter_credit_lots`, `aurora_meter_credit_allocations`,
`aurora_meter_credit_recurrences` (created here so phase 06 has one DDL version;
populated by 06d). Altered: `aurora_meter_credit_balances` gains `debt`,
`expired`, `lots_enabled_at`, `projection_checked_at`, `low_balance_crossing_id`
and four `>= 0` CHECK constraints; `aurora_meter_credit_transactions` gains
`seq`, `updated_at` and `hold_transaction_id`.

**Constraint validity, stated because it is easy to get wrong in both
directions.** The four checks on `aurora_meter_credit_balances` go on a table
that already has rows, so they are added `NOT VALID` and then validated in a
separate statement: the fast `ALTER` does not scan, and the scan takes
`SHARE UPDATE EXCLUSIVE` rather than blocking writes. The checks on the three
**new** tables are added valid outright, because a `NOT VALID` check on a table
created empty a few statements earlier is not a fast path, it is a permanently
unproven constraint that the planner cannot use and that the migration rehearsal
then has to explain. `06a-ddl.sql` shows `valid=true` on every constraint of all
five tables.

The exact catalogue is `06a-ddl.sql`.

### 3.2 `seq`, and every ordering that moved to it

`aurora_meter_credit_transactions.seq bigint GENERATED ALWAYS AS IDENTITY`, with
an index on `(tenant_key, seq)` and a unique index on `(seq)`. The lot and
allocation tables carry their own on the same terms.

**Moved to `seq`:**

| Where | Was | Is | Why it mattered |
|---|---|---|---|
| `Ledger.remaining_on_grant/3` | `ORDER BY inserted_at, id` | `ORDER BY seq` | The causal fold behind expiry. This is X213 and L20. |
| `Credits.history/2` | `ORDER BY inserted_at DESC` | `ORDER BY seq DESC` | The ledger's own account of its order. `:before` stays an `inserted_at` filter, which is the documented option; 06c owns the keyset form (L8). |
| the lot spend order | n/a (new) | `{category, expiry, granted_at, seq}` | `seq` and not `id`: a uuid is random, so `id` would make two lots granted in one tick spend in an order unrelated to which came first. |
| the allocation trail | n/a (new) | `(lot_id, seq)`, `(tenant_key, seq)` | |
| the lot expiry sweep's candidate scan | n/a (new) | `ORDER BY expires_at, seq` | |

**Did not move, and this is a recorded conflict with `architecture-map.md` 7.1,
which lists it.** `Ledger.pending_holds/1` still orders by `(inserted_at, id)`.
Its `:after` cursor is the **same key** as its `ORDER BY`, so the scan cannot
skip or repeat a hold whatever the clock does; and `Credits.pending_holds/1`
documents `:after` as `{inserted_at, id}`, so moving the order without moving
the cursor would be unsound and moving both is a public option-shape change that
06c owns (finding L8). Recorded as **X245** and handed to 06c.

Version 9 gained two columns **after** it had first been applied here:
`aurora_meter_credit_allocations.from_bucket` and `to_bucket`, both `NOT NULL`
with a membership check each and a `from_bucket <> to_bucket` check. Version 9
is unreleased, so extending it rather than adding a version 10 is the same move
`schema-migration-map.md` records Pro's V10 taking twice; the test database was
dropped and rebuilt so the edited version ran from scratch. The reason is
finding **X249** and it is worth reading: `kind` alone does not say which bucket
the value came out of, so the allocation trail was not reconstructible and
LI-06a-3 was not met by the shape the maps specified.

### 3.3 The allocator

`AuroraMeter.Credits.Allocator` (`@moduledoc false`, internal, added to
`api-change-map.md`'s internal set, `docs/api.md` and `mix.exs`'s Internal
group). Two layers in one module:

* **Planner**, `plan/2`, pure. Takes a book of lot maps already read and locked
  plus an instant, returns movements. No repo, no clock, no configuration. This
  is the function the model drives and the function 06b's migration will replay
  with, so the runtime and the migration cannot disagree about what a history
  means.
* **Applier**, `apply_plan/6`, repo bound. Writes allocations, updates lots,
  moves the balance row **by the plan's deltas**, runs the conservation check.
  Decides nothing.

Seven operations: `grant`, `debit`, `hold`, `settle`, `release`, `expire`,
`reverse` and `restore`. The last two are implemented here and wired by 06e.

### 3.4 Dispatch and lock order

`Ledger` reads `lots_enabled_at` from the balance row it has just locked
`FOR UPDATE` and dispatches. That is what makes it impossible for the legacy
writer and the allocator to run on one wallet at once: a cutover has to take the
same lock to set the flag.

`settle/3`, `release/1` and the legacy `expire_grant/2` moved from
transaction-row-first to **balance-row-first**, which is the one order
`architecture-map.md` 7.3 permits. Measured, not argued: `06a-locks.md`.

### 3.6 Pro

**Core only was the wrong frame and this unit corrects it.** A change to core's
*schema* is a change to Pro whether or not a Pro file is edited: Pro depends on
core by path, so core's `CreditBalance` declaring `debt` and four more columns
made every Ecto query Pro builds from that schema select them against a database
still at core 8. Pro's `mix check` exited 2 with **151 failures**, all
`ERROR 42703 column a0.debt does not exist` (finding **X252**).

Three Pro changes, no `lib/` file among them and no Pro schema version:

* `pro:priv/test_repo/migrations/20260915130000_upgrade_core_v9.exs`, following
  the v7 shape rather than v8's, because core 9 is transactional and core 8 is
  the only version that builds an index `CONCURRENTLY`. Pro's database was
  probed first for a row the new `held >= 0` or `promotional >= 0` checks would
  refuse, since `VALIDATE CONSTRAINT` behaves there exactly as it does in core:
  **zero balance rows and zero violations**, so the scan was trivial.
* `AuroraMeter.Pro.Test.Connections.tables/0` gains the two new core schemas
  **child first**, because version 9 put the first `ON DELETE RESTRICT` foreign
  keys in the ledger and deleting the transactions first now fails. Pro's own
  `Y4` guard is what caught it.
* Pro's `FaultRepo` gains `insert!/1`, which its surface guard scans core's
  `lib/` for.

### 3.5 The one behaviour change

`Credits.sufficient?/2`, and therefore the refusal condition of `hold/4` and
`debit/4`. On a legacy wallet: `balance - held`, unchanged. On a cut-over
wallet: the sum of the **eligible** lots' `available` less `debt`, where
eligible excludes a lot past its `expires_at`. Two consequences, both
deliberate and both in `docs/credits.md`:

* credit whose expiry has passed is not spendable before the sweep reaches it
  (in 0.4.0 it was, which made expiry a race);
* a wallet with outstanding `debt` cannot spend until a grant repays it.

## 4. Commands, exit codes and seeds

All times UTC. Every command was run through `tmp/v1/mixlane.sh core`, which
holds the core lane lock, with `DB_PORT=5490` and `MIX_ENV=test`.

| # | Command | Seed | Exit | When |
|---|---|---|---|---|
| 1 | `mix test.setup` (applies V9 to the test database) | n/a | 0 | 2026-09-15T12:12:26Z |
| 2 | `mix test test/aurora_meter/credits_test.exs test/aurora_meter/credits_concurrency_test.exs` | 0 | 0 | 2026-09-15T12:12:42Z |
| 3 | `mix test test/aurora_meter/credits/allocator_test.exs` | 0 | 0 | 2026-09-15T12:25:38Z |
| 4 | `mix test test/aurora_meter/credits_lots_test.exs` | 0 | 0 | 2026-09-15T13:02:05Z |
| 5 | `mix test test/aurora_meter/credits_lots_concurrency_test.exs` | 0 | 0 | 2026-09-15T12:29:41Z |
| 6 | `mix test test/aurora_meter/migration_v9_test.exs` | 0 | 0 | 2026-09-15T12:30:21Z |
| 7 | `mix test test/aurora_meter/credits_model_test.exs test/aurora_meter/oban_job_controls_test.exs ...` | 0 | 0 | 2026-09-15T12:24:37Z |
| 8 | `mix ecto.drop && mix test.setup` (version 9 gained two columns after the property found X249, and it is unreleased so it may still be extended) | n/a | 0 | 2026-09-15T13:10:54Z |
| 9 | `mix test test/aurora_meter/credits_lots_test.exs` under seven fixed seeds | 0, 1, 7, 42, 101, 1009, 20260915 | 0 on all seven | 2026-09-15T13:11:08Z to 13:11:22Z |
| 10 | **`mix check`** (compile --warnings-as-errors, format --check-formatted, credo --strict, `mix test`, dialyzer, docs) | 0 | **0** | 2026-09-15T13:23:50Z |
| 11 | headless leg: `AURORA_HEADLESS=1`, `mix compile --warnings-as-errors --force`, a planner and ledger probe, `mix test --include headless` | 0 | 0 | 2026-09-15T13:27:39Z |
| 12 | two-node concurrent spend, `tmp/v1/06a-multinode/run.sh final` | n/a | 0 | 2026-09-15T13:23:5xZ |
| 13 | first ledger bench, `tmp/v1/06a-bench/run.sh` | n/a | 0 | 2026-09-15T13:01:27Z |
| 14 | DDL and lock capture, `tmp/v1/06a-ddl/run.sh` | n/a | 0 | 2026-09-15T13:19:5xZ |
| 15 | the allocation-trail negative control, `tmp/v1/06a-control.py break` then the file then `restore` | 0 | **2** broken (3 of 19 failed), **0** restored, file sha256 identical | 2026-09-15T13:06:01Z |

Logs: `logs/` in this directory.

### Suite numbers

All four from one tree, after the review round.

| Run | Result |
|---|---|
| Core, before this unit (`57996c5`) | **1411 passed** (57 doctests, 12 properties, 1342 tests), 4 excluded |
| **Core `mix check`** | **1467 passed** (57 doctests, 15 properties, 1395 tests), 4 excluded, exit **0** |
| **Core headless leg** (`AURORA_HEADLESS=1`) | **1379 passed** (53 doctests, 15 properties, 1311 tests), exit **0** |
| **Pro `mix check`**, PLT and core's beams deleted first (X114) | **959 passed** (65 doctests, 894 tests), exit **0**; Dialyzer `Total errors: 1, Skipped: 1`, the pre-existing `CheckoutSession.create/1` entry, ignore file unchanged |
| Pro `mix check` **before** the core v9 migration was added | 807 of 959, **151 failures**, exit 2, every one `ERROR 42703 column a0.debt does not exist` (finding X252) |

The 56 new tests are: 11 in `AuroraMeter.Credits.AllocatorTest` (pure planner,
one of them a property), 20 in `AuroraMeter.CreditsLotsTest` (19 tests and one
property), 5 in `AuroraMeter.CreditsLotsConcurrencyTest`, 6 in
`AuroraMeter.MigrationV9Test`, 11 in `AuroraMeter.CreditsLotsFaultsTest` (the
kill and fault matrix, X243), 2 in `AuroraMeter.CreditsModelTest` (the
cross-oracle property and its own negative control) and 1 in
`AuroraMeter.DocExamplesTest` (the guard on the guard added for X246). Two
existing tests changed because the defects they asserted are fixed; see
section 7.

## 5. Public API, configuration, migration, telemetry and docs

### New public modules

| Item | Kind |
|---|---|
| `AuroraMeter.Schema.CreditLot` | documented struct, `categories/0`, `states/0`, `quantities/0`, `state_for/1`, `changeset/2` |
| `AuroraMeter.Schema.CreditAllocation` | documented struct, `kinds/0`, `changeset/2` |
| `AuroraMeter.Credits.ConservationError` | exception; its `@moduledoc` says catching it and continuing is never correct |

### Changed public API

| Item | Change |
|---|---|
| `AuroraMeter.Credits.sufficient?/2` | spendable arithmetic (section 3.5). Compat change, documented. |
| `AuroraMeter.Credits.hold/4`, `debit/4` | refusal condition follows `sufficient?/2` |
| `AuroraMeter.Credits.grant/3` | new optional `:source` (a map, stored on the lot's `source` jsonb) for 06e's `payment_intent_id` |
| `AuroraMeter.Schema.CreditTransaction` | `@kinds` gains `:reverse`; new fields `seq`, `updated_at`, `hold_transaction_id`. `categories/0` unchanged. |
| `AuroraMeter.Schema.CreditBalance` | new fields `debt`, `expired`, `lots_enabled_at`, `projection_checked_at`, `low_balance_crossing_id`; four `>= 0` validations |

### Telemetry

`[:aurora_meter, :credits, :conservation_error]`, measurements
`balance_delta`, `held_delta`, `promotional_delta`, `expired_delta`, metadata
`tenant_key`, `operation`, `reference`. Added to `docs/api.md` section 6.

**Not added, against the build document:** the build document also promised
`overrun_amount` and `debt_after` on the `[:aurora_meter, :credits, :settle]`
metadata. The settle row already carries the debt in `balance_after` and the
overrun in `settled_amount` against `held_delta`, and adding metadata to an
event 08a is about to inventory is better done there. Recorded as **X247**.

### Migration

Core schema **9**. `@data_loss_versions` gains 9, so `down(version: 9)` without
`confirm_data_loss: true` raises. `AuroraMeter.Migration.up(from: 9, version: 9)`
is transactional and needs no special host-migration attributes.

### Documentation

`docs/credits.md` (lot lifecycle, spend order, debt, expiry semantics, the
compatibility change), `docs/api.md`, `docs/correctness.md` (I10, I11, I12, I19
test lists, and I12's limits section now says which writer owns the wallet).

### Configuration

None added. The conservation check is always on and there is no option to
disable it.

## 6. Expected versus actual

| Claim | Expected | Actual |
|---|---|---|
| promotional A=3, B=5, paid P=10; debit 6 | A=0, B=2, P=10, independent of query order | met, for **all six** permutations in the planner and at the database |
| 50 independent connections, 10 USD funded, 1 USD holds | 10 `{:ok, _}`, 40 `:insufficient_credits`, 10 reserve allocations totalling 10 USD, `held = 10 USD` | met |
| two real BEAM nodes, 25 attempts each | 10 admitted in total, conservation intact | met in both release orders; **18 concurrent lock waiters** measured in every round. Winner split across three runs: `[{a, 10, 0}, {b, 9, 1}]`, `[{a, 10, 0}, {b, 8, 2}]` and `[{a, 10, 0}, {b, 6, 4}]`. Node A wins when it is released first every time, which is X209's distribution asymmetry and is why the release order is reversed |
| hold 2 USD on a lot that expires, then release | `expired = 2 USD`, `available = 0`, `sufficient?(tenant, 1) == false` | met |
| settle 7 USD against a 5 USD hold with no other funds | `debt = 2 USD`, `balance = -2 USD`, next hold refused; a 3 USD grant leaves `debt = 0`, `available = 1 USD`, a 2 USD `consume` on the new lot | met |
| every lot-path write ends conserving, `projection_checked_at` moved | | met |
| hand-edited lot row | refused by `aurora_meter_credit_lots_conservation_check` | met |
| hand-edited balance row | `ConservationError`, nothing written | met |
| sweep run twice | one `expire` allocation, one `expire` row, reference `expire:<lot_id>:0` | met, and the second pass does not examine the lot at all |
| lock order | balance before transaction before lots | met; `06a-locks.md` |
| legacy wallet | 0.4.0 behaviour, no lot written | met; `credits_test.exs` and `credits_concurrency_test.exs` pass unchanged |
| replay reconstructs balance, debt, held and every lot's allocations over arbitrary valid sequences | | met for the lot half by a generated-history property, with a negative control that discriminates; **01e's model test was not extended**, see section 7 item 6 |
| a lot's quantities are reproducible by folding its allocations | | **met only after the schema changed.** The specified allocation shape (`kind` and `amount`) is ambiguous and a fold has to guess the source bucket. The generated-history property found it on its twelfth sample; version 9 gained `from_bucket` and `to_bucket`. Finding **X249** |
| `mix check` | green, no new Dialyzer suppression, no new Credo exception | met |
| process kill at each fault point | zero lots, zero allocations, unchanged balance | **not proved.** See section 7. |

## 7. Open defects, gaps and what is not proved

Findings appended to `open-findings.md` as **X243 to X247**; **X213 is marked
RESOLVED** and **X183** is answered for the balance row.

Not proved by this unit, and each is named rather than left to be discovered:

1. ~~The kill and fault-injection matrix is not run.~~ **Done at the review**:
   `AuroraMeter.CreditsLotsFaultsTest`, eleven tests. Four kills at the four
   stage boundaries of a lot-path transaction, four injected raises at the same
   points plus the new lot's insert, one kill after commit and before the reply
   with the retry refused by its reference, and two negative controls running
   the same harness with nothing armed. Each test asserts the **wallet** and the
   conservation property re-read from the database, not the absence of an
   error. `{:killed, _pid}` and `assert_raise` are what prove each fault
   actually fired. X243 is resolved.
2. **The `CreditExpiry` Oban worker's checkpoint does not page the lot phase.**
   `expire_due/2` runs the lot sweep once per scan, bounded by the page's
   remaining limit and with no cursor; it is idempotent across runs, so nothing
   is lost, but a wallet with more due lots than one page can hold needs several
   runs. Wiring a second cursor into 05c's checkpoint shape is a cutover
   concern: **X244**, owed to 06b.
3. **Pre-version-9 rows get their `seq` from the table rewrite's physical
   order,** which for a row that has been updated in place (a closed hold, a
   stamped grant) is not insertion order. `Promotions.consume/3` is now total
   rather than raising, with the fallback tested; 06b must not assume otherwise.
   Part of **X244**.
4. **The allocator's per-write cost grows with the wallet's lot count**: p50
   6.0 ms at one lot, 13.2 ms at a thousand, against a flat 4.0 to 4.4 ms for
   the legacy writer. `06a-bench.json`. Informational; 08c owns the budget and
   06b's report owns the observed lot-count distribution.
5. `Credits.balance/1` does not expose `debt` or `expired`. That is 06c's
   (display fields), stated so a reader does not read the omission as a gap.
6. ~~01e's model test was not extended with a lot book.~~ **Done at the
   review, and it found three money defects.** See section 7b. The original
   text of this item is kept below because its assessment of what the two
   oracles catch turned out to be exactly right.

   **01e's `AuroraMeter.CreditsModelTest` was not extended with a lot book.**
   The build document asks for it and G06 bullet 4 is proved "jointly with 01e's
   extended model test". What stands in its place is
   `AuroraMeter.CreditsLotsTest`'s generated-history property, which replays
   arbitrary valid sequences through the real ledger and reconstructs the rows
   three independent ways, with a negative control that discriminates
   (`i10-conservation.md`). It is a weaker claim than 01e's in one specific
   respect: 01e compares against a **second implementation** of the arithmetic,
   and this compares the database against itself from three directions. The
   difference matters for a systematic error that all three share. Owed, and
   the natural owner is 06b, which has to write a replay anyway.

## 7b. The second oracle, and the three defects it found

`LedgerModel.lot_view/1` was written by build unit **01e** from
`architecture-map.md` section 7, before 06a existed, and 01e could only assert
its internal conservation because there were no lot tables to compare it with.
There are now. Driving both from one generated history is a comparison against
**a second implementation of the same design, by a different unit, from the
specification rather than from the code**, which is what G06 bullet 4 is asking
for and what 06a's own generated-history property is not.

It found three defects in 06a's allocator, recorded as **X251** and all fixed:

1. **A settlement handed back its hold's original per-lot reservation** instead
   of what was left after the settlement consumed part of it. Invisible while
   that hold is the only reservation on the lot, because the lot's own
   `reserved` caps the excess away; the moment a second hold reserves on the
   same lot it takes that hold's reservation into `available`. Measured as a lot
   the model said held `reserved: 23,030,658` reading `1,874,663`.
2. **`debit` did not refuse while `debt > 0`**, though `hold` did and
   `architecture-map.md` 7.2 requires both.
3. **A release did not repay outstanding debt** out of what it handed back, so
   LI-06a-5 was false.

**What did not catch (1) is the point of the whole exercise.** Conservation held
throughout: `reserved` to `available` keeps the five buckets summing to the
amount, `held` still equalled `sum(reserved)`, the CHECK constraints and the
in-transaction projection check were both satisfied, and 06a's own
generated-history property, which reconstructs the rows three ways **from the
same database**, was green. A systematic error shared by all three of those
directions is exactly what a second implementation catches.

### What is compared, and what is excluded

Every exclusion is measured rather than assumed, and each names who closes it.

| Excluded | Why | Closed by |
|---|---|---|
| `:reverse` | `Credits.reverse/4` still takes the plain debit path, so it disagrees with 01e's view of a lot reversal on the first command that reaches it. With it in, **every** history diverged on three of seven fixed seeds and the run compared nothing at all, which the property's own teardown correctly turned into a failure | 06e (finding X250) |
| expiring grants (`expiry: false`) | 06a's compatibility change makes a lot past its `expires_at` unspendable before the sweep; 01e's `live_lot?/1` has no expiry test. That shows as a **refusal** only when nothing else can pay: the ordinary case is that both accept the debit and take it from **different lots**, which no result-level classifier can see. Comparing across it would mean encoding 06a's own spend decision into the oracle | nobody; it is a deliberate divergence |
| histories where debt was reachable | 06a repays debt out of what a release hands back and 01e's view does not, so the buckets part company without the results ever disagreeing. Decided from the model's own `overrun?` record rather than from the generator | `architecture-map.md` 7.2 should say "every incoming value" |

### Counts, asserted rather than printed

The property records how many histories it fully compared and how many
diverged, and the module's teardown **raises** if a run compared none of them,
because a property that diverged on everything is green and proves nothing
(X182, X214). Over seven fixed seeds, twelve histories each:

| Seed | 0 | 1 | 7 | 42 | 101 | 1009 | 20260915 |
|---|---|---|---|---|---|---|---|
| compared | 12 | 10 | 9 | 8 | 12 | 9 | 7 |
| diverged | 0 | 2 | 3 | 4 | 0 | 3 | 5 |

### The negative control

`test I10 the cross-oracle comparison can fail: a lot bucket moved by hand is
caught` moves one micro-dollar between two buckets of a committed lot, which the
lot's CHECK permits because the sum is unchanged, and asserts the comparison
notices. Separately, reintroducing defect (1) (`tmp/v1` break and restore, file
sha256 `bf48707a...` before and after) fails **both** the property and the
deterministic regression, and nothing else in the suite.

## 7a. G06, bullet by bullet

Checked against `v1-release.md`'s "Verification checklist / G06" rather than
against this unit's own acceptance criteria, because a unit reports against the
list it read and a bullet it did not read is invisible to it (finding X212).
06a does not own G06; three of its seven bullets belong to other units and are
marked as such.

| G06 bullet | 06a's coverage |
|---|---|
| 1. promotional A=3, B=5 and paid P=10; a 6 USD debit consumes A=3 and B=3, independent of insertion query order | **Covered.** `AllocatorTest` asserts it for **all six** permutations of the input list, and `CreditsLotsTest` asserts the same at the database with one `consume` allocation per lot touched and the paid lot untouched. |
| 2. concurrent holds cannot allocate the same micro-USD twice; many tenants and one hot wallet, independent connections | **Covered.** 50 connections on one wallet (10 admitted, 40 refused, 10 reserve allocations totalling the funded amount), 20 wallets in parallel, and two real BEAM nodes with 18 concurrent lock waiters measured. `i11-hot-wallet.md`. |
| 3. expiry racing settlement or release preserves conservation; released expired reserved value never returns to spendable balance | **Covered.** A forced rendezvous fires in 6 of 6 rounds (asserted, not printed), and the deterministic release-on-expired and settle-on-expired cases assert `expired`, `available: 0` and `sufficient?/2 == false`. `i12-expiry.md`. |
| 4. replay reconstructs balance, debt, held and every lot's allocations after arbitrary valid operation sequences | **Covered, by two oracles.** 06a's own generated-history property reconstructs the rows three ways from the database, and 01e's independent lot model is now compared against it lot for lot over the subset section 7b defines. The second oracle found three defects the first could not (X251). |
| 5. a refund of a spent paid lot does not erase later promotional credit or exceed the payment's net reversible grant | **Partly, and the rest is 06e's.** The planner implements `reverse` and `restore` with the bucket order available, consumed, reserved, refuses to touch a promotional lot from a paid reversal, caps per lot, and raises debt only for what was already consumed; `AllocatorTest` asserts all four. Nothing wires them to a public function or to Stripe: that is 06e, and it is wiring only. |
| 6. recurring job retry, plan change mid-retry, clock boundary and two-node execution issue one grant and one rollover per period | **Not 06a's.** 06d owns it; `aurora_meter_credit_recurrences` exists and is empty. |
| 7. upgrade populated core-6 / Pro-9 histories with pending holds, promotions, debt and refunds without monetary drift; no blanket destructive down migration for financial allocations | **Partly.** The second half is met: version 9 is on `data_loss_versions`, `down` without `confirm_data_loss: true` raises, and the ledger survives the rollback so an application rollback before the wallet cutover is supported. `MigrationV9Test` also upgrades a database that already holds credit rows and asserts they are unchanged, that `seq` is assigned and that no lot is invented. The populated-fixture upgrade is 11a's and the wallet replay is 06b's. |

## 8. Handoff

A fresh agent continuing from here needs:

* **06b** (wallet migration): the tables, `Allocator.plan/2` to replay with,
  `lots_enabled_at`, and `Ledger.enable_lots!/1` as the shape of the flag write.
  `enable_lots!/1` deliberately **refuses** a wallet that has any ledger row, so
  06b must replace it with the real cutover rather than call it. It also owes
  X244's two items.
* **06c**: `debt`, `expired`, `low_balance_crossing_id` and the lot rows are in
  place; `Credits.Lots` and the display fields are its own. It owns L8 (the
  keyset form of `pending_holds/1` and `history/2`) and X245.
* **06d**: `aurora_meter_credit_recurrences` exists and is empty.
* **06e**: `Allocator.plan/2` implements `{:reverse, payment_intent_id, amount,
  now}` and `{:restore, ...}` with the bucket order available, consumed,
  reserved; the lot's `source` jsonb carries `payment_intent_id` and is indexed.
  Wiring `reverse_lot/4` and `restore_lot/4` is all that is left.
* **08c**: `06a-bench.json` is the first measurement and `tmp/v1/06a-bench/`
  the script.
* **11a**: schema version 9 is on `data_loss_versions`; `MigrationV9Test` covers
  the fresh-versus-incremental catalogue, idempotency, an already-populated
  database and the refusal path.

Nothing in this unit requires an owner action, a credential or a network call.
No commit, tag, push, publish or deploy was made.
