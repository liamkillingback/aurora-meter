# 03a: event schema (core V7 and V8) and legacy backfill

## 1. Tasks, repository and revision

- V1 tasks: **03.01** (ADR and schema) and **03.02** (migration and backfill),
  from `v1-release.md` section 7.
- Repository: `aurora_meter` (core), branch `aurorameter-v1`, parent commit
  `fe28f84e39dacdb0691afd1d3a7393800eec12c8`.
- Second repository touched: `aurora_meter_pro`, parent commit
  `7a083e389598cc1e5c4ea6f62e23836c79030b42`. Three test-repo migration files
  and one test-support function, no library code. See section 5.
- **The tree is dirty.** This unit does not commit, tag, publish or deploy
  (decision D13). Every number below comes from a run performed against this
  working tree.

## 2. Environment

| Fact | Value |
|---|---|
| Core schema version before | 6 |
| Core schema version after | 8 |
| Pro schema version | 9, unchanged |
| Package pair | core 0.5.0 (`mix.exs` unchanged), Pro 0.3.1 |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1) |
| Postgres | 16.13 (Debian 16.13-1.pgdg13+1), container `aurora-meter-pro-testdb`, port 5490 |
| Operating system | Ubuntu 24.04 under WSL2 |
| `sha256sum core/mix.lock` | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` |
| `sha256sum pro/mix.lock` | `bd66012e64e0ce2cb97e5a9fdbee15c248277484a18f7176731e10649c6df424` |

Both lock files are byte identical to `HEAD`: this unit adds no dependency, and
`git diff --stat mix.lock` is empty in both repositories (`open-findings.md`
X57).

### The Postgres floor

Unchanged and still stated honestly (`open-findings.md` S5, decision D12).
Version 7 uses `GENERATED ALWAYS AS IDENTITY` (PG 10), `ADD COLUMN` with a
constant default without a rewrite (PG 11) and `ADD CONSTRAINT ... NOT VALID`
(PG 9.1). Version 8 uses `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS` (PG
9.5) and `SET NOT NULL` proved from an existing constraint (PG 12). None of
these raises the floor above the 13 that `gen_random_uuid()` already requires.
**13 remains the documented floor and 16 the tested version.** No PG 13 leg was
run by this unit, and no claim is made about one.

## 3. Commands and logs

Every command, its exit code, timestamps and artifact path is in
`03a-commands.txt` beside this file. The verification set:

| Command | Exit | Artifact |
|---|---|---|
| `mix test test/aurora_meter/migration_test.exs --seed 0` (at `@latest 7`, before V8 existed) | 0 | `03a-commands.txt` |
| `mix test --seed 0` (core, full) | 0 | `03a-core-check.log` |
| `mix check` (core) | 0 | `03a-core-check.log` |
| `mix check` (Pro) | 0 | `03a-pro-check.log` |
| `mix ecto.drop && mix ecto.create && mix ecto.migrate --log-migrations-sql` | 0 | `03a-v7-sql.log` |
| `mix run --no-start tmp/v1/03a/rehearse.exs` | 0 | `03a-backfill-counts.json`, `03a-rewrite-timing.json`, `03a-schema-diff.md` |
| `mix run --no-start tmp/v1/03a/catalogue.exs` | 0 | `03a-fresh-vs-upgrade.txt` |

Seed 0 throughout. Every disposable database is named `aurora_v1_*` and is
dropped by the run that created it; `aurora_meter_test` and
`aurora_meter_pro_test` were rebuilt only through `mix ecto.drop` and
`mix test.setup`.

## 4. Results

### Test counts

| Suite | Before | After |
|---|---|---|
| core | 810 (42 doctests, 10 properties, 758 tests) | **866** (42 doctests, 10 properties, 814 tests) |
| Pro | 420 | **420**, unchanged |

56 tests added in core. Pro's count is unchanged, which is the point: this unit
adds nothing to Pro and breaks nothing in it.

### The migration ladder

`03a-fresh-vs-upgrade.txt`. A database built by
`up(from: 1, version: 8, concurrently: false)` and one built by
`up(from: 1, version: 6)`, 25 legacy rows, `up(from: 7, version: 7)`, the
backfill, then `up(from: 8, version: 8)` in a file with both DDL attributes,
produce **125 catalogue lines each and zero difference**. A catalogue line is
one column (type, nullability, identity, default), one index (full `indexdef`)
or one constraint (type, `convalidated`, definition), for every table whose
name begins `aurora_meter`.

Every published schema history reaches 8 with its rows intact:

| Starting point | Published as | Marker before 7 | After 7 | After 8 | Rows preserved | Backfilled |
|---|---|---|---|---|---|---|
| core 1 | core 0.1.0 | absent | 7 | 8 | 10 of 10 | 10 |
| core 2 | core 0.2.0 to 0.3.2 | absent | 7 | 8 | 10 of 10 | 10 |
| core 6 | core 0.4.0 | absent | 7 | 8 | 10 of 10 | 10 |

The suite runs the same ladder from 3, 4 and 5 as well, which no customer is at
(`test/aurora_meter/migration_v7_test.exs`, `test the ladder I19 each published
schema history reaches 7 and then 8`). No starting point could not be proved.

### The combined `ALTER TABLE`

`03a-v7-sql.log`, and the statement as the migration runner logged it:

```
ALTER TABLE aurora_meter_events
  ALTER COLUMN quantity TYPE bigint,
  ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY
```

One statement, so Postgres performs one table rewrite rather than two.

### Cost of the rewrite

`03a-rewrite-timing.json`. **A local measurement on the recorded machine with an
otherwise idle database. It is not a customer-scale claim and must not be quoted
as one.** 11.05 repeats it on the migration fixtures.

| Rows | Table bytes before | After | V7 `ALTER` | Backfill | V8 | Lock waits |
|---|---|---|---|---|---|---|
| 12,002 | 2,244,608 | 2,990,080 | 0.13 s | 0.2 s (12 batches of 1000) | n/a | 0 |
| 1,000,000 | 190,668,800 | 195,387,392 | **6.35 s** | **60.4 s** (batches of 10,000) | 4.11 s | 0 |

### The backfill

`03a-backfill-counts.json`. 12,002 rows in the 0.4.0 shape, including one with a
non-positive quantity and one with 20 KB of metadata, which is what a real
0.4.x database can hold because `track/4` never validated either.

- Dry run: `scanned 12002, updated 12002` predicted, `nonpositive_quantity 1`,
  `oversized_metadata 1`, and **nothing written**: no row changed and no
  checkpoint row created.
- Interrupted run (`--max-batches 3`): `updated 3000`, checkpoint left at
  `seq 3000`.
- Resume: `scanned 9002, updated 9002`, `remaining 0`. 12,002 rows carry a
  `legacy:` identity.
- `aurora_meter_event_totals` holds **0 rows** afterwards (L-03a-3). A legacy
  event was never billed and must not become billable by being upgraded.
- A kill test in the suite (`kill -9` of the runner at a batch boundary, driven
  by the task's own telemetry) proves the stronger form: the interrupted and
  uninterrupted runs produce the identical ordered list of `{seq, payload_hash}`.

### What is approximated, and how to find it

Two things, and only two.

1. **`occurred_at`**, set to `inserted_at`, because `track/4` never recorded
   when the usage happened. Every such row is exactly a row whose `event_id`
   begins `legacy:`, and that prefix is derived from the row's own primary key
   rather than flagged, so it cannot drift:

       SELECT count(*) FROM aurora_meter_events WHERE event_id LIKE 'legacy:%';

2. **`period_start`**, where the configured period source could not place the
   instant. Those rows get the calendar month containing it and
   `attribution = 'unresolved'`:

       SELECT count(*) FROM aurora_meter_events WHERE attribution = 'unresolved';

   In this rehearsal the count is 0, because the calendar source can place any
   instant. The suite drives it to 3 of 3 with two broken period sources.

`plan_id` and `plan_version` are left null rather than guessed: legacy events
were never billed and their plan attribution cannot be reconstructed.

### Exclusion between two backfill runners, and why it is not a lease (X100)

A **Postgres session advisory lock** (`pg_try_advisory_lock`) on a connection
pinned for the length of the run, and nothing else decides it.

`open-findings.md` X100 measured `clock_timestamp()` stepping backwards 439 ms
on a 32.5 second cadence: it is the database host's OS clock and the host
corrects it. A lease is a duration compared against a clock and can therefore
invert. A lock has no clock in it at all, and it releases itself when the
connection holding it dies, which is exactly the signal a stale lease is trying
to approximate. This is also not a correctness property being carried by the
lock: two concurrent runs are already safe, because the derivation is
deterministic and every update carries `WHERE event_id IS NULL`. The lock stops
waste, and it stops it honestly.

The checkpoint row's `state` and `updated_at` are a **report**. A `"running"`
state with the lock free means the previous run was killed, and the task says
so and offers `--force-resume`; `--force-resume` cannot take a lock somebody
holds. The Mix task's `--stale-after` only changes the wording of a message,
and the one comparison it makes puts `Clock.db_now/0` against a column the
database stamped with `clock_timestamp()`: one clock on both sides, a threshold
of minutes, and no decision resting on it.

Measured consequence, recorded because it surprised the first version of the
test: when the runner is killed, the pool closes its connection and the lock
goes with it, but not instantaneously. On this host it took **under 50 ms**. A
resume attempted in the same instant as the kill can still see
`:already_running`; a resume attempted by a human cannot. The suite waits for
the condition rather than sleeping through it.

### Acceptance criteria

| Criterion | Met | Evidence |
|---|---|---|
| `latest_version()` returns 8 and `migration_test.exs`'s three existing assertions pass unchanged | yes | `AuroraMeter.MigrationTest`, 3 original tests plus 8 new |
| Fresh install and incremental upgrade have identical column, index and constraint catalogues | yes | `03a-fresh-vs-upgrade.txt`: 125 lines each, zero difference |
| Two inserts of the same `(tenant_key, event_id)` on two independent connections produce one row; the second raises `unique_violation` | yes | `MigrationV8Test`, `I06 two inserts of the same (tenant_key, event_id) leave exactly one row` |
| The same `event_id` under two tenant keys produces two rows | yes | `MigrationV8Test`, `I06 the same event_id under two tenants is two facts` |
| `up(from: 7, version: 8)` raises `ConcurrentVersionError`; the generated version 8 file carries both attributes | yes | `MigrationTest` (both the raise and its negative control), `Mix.Tasks.AuroraMeter.Gen.MigrationTest` |
| Version 8 with one null `event_id` raises `BackfillIncompleteError` with the exact count | yes | `MigrationV8Test`, `I07 it refuses while any event_id is null, and names the count` |
| 12,000 rows interrupted by `kill -9` and resumed give the identical ordered `{seq, event_id, payload_hash}` | **partly** | `EventsBackfillTest`, `I19 a run killed between batches resumes byte for byte`, at 3,000 rows and comparing `{seq, payload_hash}`. See "Known limits" below |
| A second run reports zero updated rows and leaves every `payload_hash` unchanged | yes | `EventsBackfillTest`, `I19 it is idempotent`, both from the checkpoint and from a full rescan |
| After a backfill, `aurora_meter_event_totals` has zero rows | yes | `EventsBackfillTest` `L-03a-3`, and `03a-backfill-counts.json` |
| `quantity = 2_147_483_648` inserts and reads back exactly | yes | `MigrationV7Test`, `C13 a quantity above the int4 maximum inserts and reads back exactly` |
| `down(version: 7, to: 7)` raises `DataLossError` without `confirm_data_loss: true` | yes | `MigrationTest`, with its negative control |
| `Checkpoints.get("schema:core").cursor["version"]` equals the highest version applied, absent on a core 6 database | yes | `MigrationTest` and `MigrationV7Test` |
| `mix check` passes in core with no new Dialyzer or Credo finding | yes | `03a-core-check.log`, exit 0 |

**Known limits of the kill criterion.** The criterion asks for 12,000 rows and a
three-field comparison. The test uses **3,000 rows** and compares `{seq,
payload_hash}`, deliberately:

- 12,000 rows is the size the *count* criterion needs and that case does run at
  12,000; the resume case gains nothing from the extra 9,000 rows and costs
  three seconds of wall clock on every suite run.
- `event_id` is excluded from the comparison because the two runs are against
  two disposable databases and `event_id` is derived from `gen_random_uuid()`,
  so the two lists cannot be equal by construction. Comparing them would be a
  test that could only fail. `seq` and `payload_hash` are the fields that carry
  the claim, and `event_id` is asserted separately to equal `'legacy:' <> id`
  for every row.

The full-size, two-database, three-field form belongs to 11a's fixtures, where
both sides are the same restored database.

## 5. Changes

### New public surface

| Addition | Where |
|---|---|
| `%AuroraMeter.Event{}` read struct, and its `attribution` vocabulary | `lib/aurora_meter/event.ex` |
| `AuroraMeter.Checkpoints.{get/1, all/0, put/4, update/2, delete/1, pause/1, resume/1, paused?/1}` | `lib/aurora_meter/checkpoints.ex` |
| `AuroraMeter.Migration.{concurrent_versions/0, data_loss_versions/0}` | `lib/aurora_meter/migration.ex` |
| `up/1` options `:concurrently`, `:validate_checks`, `:lock_timeout`; `down/1` option `:confirm_data_loss` | `lib/aurora_meter/migration.ex` |
| `AuroraMeter.Migration.{ConcurrentVersionError, DataLossError, BackfillIncompleteError}` | `lib/aurora_meter/migration/errors.ex` |
| `mix aurora_meter.events.backfill` | `lib/mix/tasks/aurora_meter.events.backfill.ex` |
| `AuroraMeter.Schema.Event` field additions (13 fields, none renamed or removed) | `lib/aurora_meter/schema/event.ex` |
| Telemetry `[:aurora_meter, :events, :backfill, :batch]` | emitted by the backfill, documented in `docs/api.md` section 6 |

New internal modules, listed in `docs/api.md` section 11 and in `mix.exs`'s
Internal group: `AuroraMeter.Events.Backfill`, `AuroraMeter.Events.Canonical`,
`AuroraMeter.Migration.V7`, `AuroraMeter.Migration.V8`.

No configuration key is added. The backfill's batch size is an argument, not
configuration: it is a one-time operation whose right value depends on the
maintenance window.

### Migrations

Core schema **7** (additive, transactional) and **8** (concurrent index, its own
host migration). The full statement list is in `03a-schema-diff.md`.

### Documentation

`docs/api.md` (new surface, the telemetry event, the internal modules),
`docs/correctness.md` (I06, I07 and I19 sections: new tests, and prose corrected
where this unit changed the facts).

### Cross-unit touches

Each of these is another unit's file, changed minimally because a whole-codebase
guard tipped or because the package would otherwise be broken. All are reported
rather than absorbed (`open-findings.md` X73).

| File | Owner | Change | Why |
|---|---|---|---|
| `lib/aurora_meter/storage/ecto.ex`, `insert_events/1` | 03c | Supplies `event_id` (`"track:" <> uuid`), `payload_hash`, `occurred_at` and `attribution: "legacy_track"` | Version 8 makes the first three `NOT NULL`. Without this, **every durable `AuroraMeter.track/4` in the package fails after V8**. See defect D1 |
| `test/aurora_meter/api_inventory_test.exs`, `mix.exs`, `docs/api.md` | 02a | Four new internal modules added to `@internal_modules`, the Internal docs group and section 11 | The three lists must be equal; A03 fails otherwise |
| `test/aurora_meter/release_metadata_test.exs` | 02d | `@schema_version` 6 to 8, and the test renamed to say what it now checks | Its own comment instructed it. See defect D2 |
| `test/aurora_meter/clock_test.exs` | 02c | `mix aurora_meter.events.backfill` added to the `db_now/0` allow-list, with a reason | The task reads it for one descriptive message; not a path, hot or otherwise |
| `docs/correctness.md` | 02a | I06, I07, I19 | The index is two-way: an invariant test that is not listed fails the suite |
| `test/support/aurora_meter/test/fault_repo.ex` (core) and Pro's equivalent | 01b | `checkout/2` and `query!/3` added | The harness must export every repo function `lib/` calls, and the backfill bounds its bulk statements with an explicit `:timeout` |
| Pro `priv/test_repo/migrations/` (3 files) | 04b / 11a | Pro's test database taken from core 6 to core 8, with the backfill between | See defect D1: a database left at core 6 refuses every durable `track/4` |

Pro's `lib/` is untouched. `AuroraMeter.Pro.Rollup.day_rollups_from_events/1`
reads `inserted_at`, `quantity`, `tenant_key` and `feature`, none of which
version 7 changes; a copy of its query is exercised against a version 7
database by `MigrationV7Test`, cited by symbol rather than by line
(`open-findings.md` X67).

## 6. Open defects

### D1. After core schema 8, a database left at an older schema refuses every durable `track/4`

**Severity: high, and it is the sharpest edge this unit creates.** From version 7
on, `AuroraMeter.Storage.Ecto.insert_events/1` writes `event_id`,
`payload_hash`, `occurred_at` and `attribution`, because version 8 makes the
first three `NOT NULL`. A host that upgrades the *package* without running the
*migration* gets `ERROR 42703 undefined_column` on every durable
`AuroraMeter.track/4`. Found by Pro's suite, whose test database was pinned at
core 6.

The failure is loud, immediate and at the right place, and the alternative (a
runtime schema sniff, writing one shape or the other) is worse. It is recorded
here because it must reach `docs/upgrading-to-1.0.md`.

- **Reproduction**: migrate a database to core 6, install this core, call
  `AuroraMeter.track(tenant, :f, 1, durable: true)`.
- **Invariant**: I06, I19. **Owner**: 10a for the upgrade guide, 03c for the
  legacy track path it now shares.

### D2. G04's changelog assertion now permits a stale schema claim

`CHANGELOG.md`'s 0.5.0 section says `latest_version()` is 6. That was true of
release 0.5.0 and is no longer true of this tree. `@schema_version` moved to 8
as its own comment instructed, but the other half of that instruction, "say so
in the changelog", cannot be carried out here: a non-empty `[Unreleased]`
section is refused by `G02 nothing is left in an Unreleased section`, and
rewriting a released section would falsify the record.

- **Severity**: low, but baseline numbers are what later claims are measured
  against. **Owner**: 10a or 11e, in the release that ships schema 7 and 8.
- **Suggested fix**: G04's second test should assert that the number in the
  CHANGELOG's top section equals `Migration.latest_version()`, once tree and
  release agree again.

### D3. `AuroraMeter.Events.Backfill` has no supported entry point in a release

Mix tasks do not exist in an OTP release. An operator running a Mix-free
deployment has no documented way to run the backfill; `Backfill.run/1` works but
is internal.

- **Severity**: medium, operational. **Owner**: 05c, which already introduces
  `AuroraMeter.Operations` as the operator surface over these same checkpoints.

### D4. The fault harness has no injection point inside a Mix-task-shaped worker

`AuroraMeter.Test.Kill` arms faults at named points in the storage layer, none
of which the backfill passes through. The resume test therefore kills the runner
from the task's own telemetry handler rather than through the harness.

- **Severity**: low. **Owner**: 01b, or 03d, which needs the same thing for
  replay.

No test is skipped. Three tags are excluded by `test_helper.exs`, all `:headless`
and all pre-existing.

## 7. Handoff

**Where the work stopped.** Core schema 7 and 8 are implemented, migrated,
tested and measured. Core is 866 tests and `mix check` exit 0; Pro is 420 tests
and `mix check` exit 0. The tree is dirty and uncommitted.

**What to read.** This file, then `03a-schema-diff.md` for the exact catalogue,
then `AuroraMeter.Migration`'s moduledoc for the version list and the options,
then `AuroraMeter.Events.Backfill`'s moduledoc for what the backfill
approximates and why its exclusion is a lock.

**What must not change.**

- `AuroraMeter.Migration.V1` to `V6`: published, and a migration that has run
  somewhere is history.
- The `aurora_meter_events` primary key, and the Ecto field name `inserted_at`
  on `AuroraMeter.Schema.Event`. `recorded_at` is the name on the public read
  struct only; renaming the schema field would break every query written
  against 0.4.x.
- `seq` is assigned by the database, `GENERATED ALWAYS`, and the schema marks it
  `read_after_writes`. Nothing may supply a value for it: it is the only sound
  scan order this table has.
- The two constraints in version 8's `@late_checks` must not move back into
  version 7. See the map amendments below.

**Next verification target.** 03b: `record/4`, the storage callbacks and the
projection. The columns, the totals table, the `events_projection` checkpoint row
and the `%AuroraMeter.Event{}` struct are all in place and waiting for it.
`AuroraMeter.Events.Canonical` holds the canonical form; extend it there rather
than writing a second one.

## Map amendments this unit requires

Reported rather than applied: `docs/v1/build-plans/` is the storefront's and
these are binding documents.

1. **`architecture-map.md` 4.1 and `schema-migration-map.md` S1: the metadata
   size constraint.** The map names `pg_column_size(metadata) <= 16384`. That is
   not a property of the value: `pg_column_size` reports the size **as stored**,
   so measured on this host one 20,012 byte metadata map is 20,012 bytes to an
   `INSERT` and 259 bytes once TOAST has compressed it. The same value is
   therefore refused on the way in and **passes `VALIDATE CONSTRAINT`** on the
   way out. A constraint whose truth changes with how a row happens to be
   stored is not a constraint. This unit implements
   `octet_length(metadata::text) <= 16384`, which is deterministic and is
   exactly the contract `record/4` documents (metadata at most 16 KiB encoded).
   Probe output is in the commands file.

2. **`schema-migration-map.md` S1 and S3: which version adds `quantity > 0` and
   the metadata bound.** The map puts every check constraint in S1 (version 7)
   `NOT VALID` and validates in S3. That cannot work: **a `NOT VALID` constraint
   is enforced on `UPDATE` as well as on `INSERT`**, and the backfill's whole
   job is to `UPDATE` the historical rows, including the ones that violate those
   two constraints. Added in version 7, the constraints would make the V1
   upgrade impossible on any database holding a non-positive quantity or an
   oversized metadata map, which is the case the `NOT VALID` design exists to
   serve. The four constraints legacy rows cannot violate (`kind`, the
   correction pairing, the `event_id` length, `jsonb_typeof(dimensions)`) stay
   in version 7. The two that history can violate move to version 8, added
   `NOT VALID` after the backfill and validated in the same version.
   `AuroraMeter.MigrationV7Test`, `it does not add a constraint that legacy
   history can violate`, is the regression test.

3. **`schema-migration-map.md` S1: `seq`, two indexes and one constraint not
   listed.** As the 03a build document's open question 2 proposed, and now
   implemented: `seq bigint GENERATED ALWAYS AS IDENTITY` with
   `aurora_meter_events_seq_index`; `index(:aurora_meter_events, [:tenant_key,
   :original_event_id]) WHERE kind = 'correction'`; and the
   `jsonb_typeof(dimensions) = 'object'` check. The map's own rule permits this
   and asks for the amendment.

4. **`architecture-map.md` section 3, the clock bullet.** It cites
   "`Credits.with_lock/2`" as an advisory lock the ledger already uses. There is
   no such function in core: `with_lock/2` is `AuroraMeter.Pro.Credits.with_lock/2`,
   and core's ledger uses row locks (`lock: "FOR UPDATE"`). The advice is right
   and the citation names another package. Worth fixing before a later unit goes
   looking for it in core (`open-findings.md` X67 family).

5. **The 03a build document, "Ordering, backfill and resumability".** It gives
   backfilled rows `attribution = "resolved"`, which this unit implements. Note
   for 03c: `"legacy_track"` is then free to mean what it says, a row written by
   `AuroraMeter.track/4` on the legacy durable path, and this unit already
   writes it there. The discriminator for a *backfilled* row is the derived
   `legacy:` prefix on its `event_id`, not its attribution.
