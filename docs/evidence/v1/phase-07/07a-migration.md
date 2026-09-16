# 07a: core schema version 10

Build unit 07a, `schema-migration-map.md` step **S6**. Core `aurora_meter`,
2026-09-16.

## What it does

Additive and transactional. Two new tables, ten columns on
`aurora_meter_subscriptions`, and one line of DDL that belongs to a different
finding entirely (X220, below). It writes **no data**: the legacy assignment is
`AuroraMeter.Plans.register!/0`'s, because `plan_fingerprint` is a sha256 of the
compiled definition and there is no compiled definition inside a SQL statement.

`AuroraMeter.Migration.latest_version/0` is **10**. Version 10 is on
`data_loss_versions/0`, so `down/1` needs `confirm_data_loss: true`: its `down`
drops `aurora_meter_plan_versions`, which is the only record of what a retired
version sold, and `plan_version`, which is the only record of which contract a
tenant is on.

## The DDL as executed, against a database seeded with 100,000 subscriptions

Disposable database, core 9 first, 100,000 subscription rows (one in seven with
`plan_id = 'unknown'`, the value `AuroraMeter.Pro.Subscriptions` writes when no
price mapped), then version 10. Raw log: `07a-logs/measure.log`.

```
seeded rows: 100000
seed wall ms: 525
v10 DDL wall ms: 85
locks observed on aurora_meter tables during v10:
  aurora_meter_subscriptions relation AccessExclusiveLock granted=true
  aurora_meter_subscriptions relation ShareLock granted=true
  aurora_meter_subscriptions relation ShareUpdateExclusiveLock granted=true
rows with no plan_version after the DDL: 100000
```

The locks were sampled every 5 ms from a **second connection**, querying
`pg_locks` **without** a `database` filter, because a row-lock waiter is
invisible to a filtered query (`open-findings.md` X182). Three locks, and each
has a cause worth naming:

- `AccessExclusiveLock` on `aurora_meter_subscriptions`: the `ALTER TABLE ... ADD
  COLUMN` block. Ten nullable columns with no default, so PG 11 and later record
  each as a catalogue entry and no row is rewritten. It is held for the
  catalogue update only.
- `ShareLock`: the **non-concurrent** partial index build. This is the one that
  blocks writes for the duration, and on 100,000 rows the whole version took 85
  ms. On a table two orders of magnitude larger the index build is the part that
  grows. `schema-migration-map.md` S6 asks for this index and does not ask for
  it concurrently; a host with a very large subscriptions table should expect
  this version to hold a write lock for the length of that build.
- `ShareUpdateExclusiveLock`: the two `VALIDATE CONSTRAINT` scans, which is the
  point of adding them `NOT VALID` first: reads and writes continue while the
  scan runs.

An earlier run of the same script also observed `AccessExclusiveLock` on
`aurora_meter_flush_receipts` (the X220 `SET DEFAULT`, a catalogue-only change)
and `RowExclusiveLock` on `aurora_meter_checkpoints` (the schema marker). Both
are in `07a-logs/measure.log`'s first run; the 5 ms sampling interval does not
always catch a statement that takes under a millisecond.

## The catalogue after version 10

### `aurora_meter_plan_versions`

```
  id uuid null=NO default=gen_random_uuid()
  plan_id text null=NO
  version text null=NO
  fingerprint bytea null=NO
  definition jsonb null=NO default='{}'::jsonb
  effective_at timestamp without time zone null=YES
  first_seen_at timestamp without time zone null=NO
      default=(clock_timestamp() AT TIME ZONE 'UTC'::text)
  INDEX aurora_meter_plan_versions_pkey UNIQUE (id)
  INDEX aurora_meter_plan_versions_plan_effective_index (plan_id, effective_at)
  INDEX aurora_meter_plan_versions_plan_id_version_index UNIQUE (plan_id, version)
  CONSTRAINT aurora_meter_plan_versions_fingerprint_check
      CHECK (octet_length(fingerprint) = 32) validated=true
  CONSTRAINT aurora_meter_plan_versions_plan_id_check
      CHECK (octet_length(plan_id) >= 1 AND octet_length(plan_id) <= 128) validated=true
  CONSTRAINT aurora_meter_plan_versions_version_check
      CHECK (octet_length(version) >= 1 AND octet_length(version) <= 32) validated=true
```

No `updated_at`: the row is immutable after insert, and
`aurora_meter_flush_receipts` is the existing precedent for an insert-only core
table. `first_seen_at` is **database-stamped** and
`AuroraMeter.Storage.Ecto.put_plan_version/1` omits it from the insert, so the
row records when the database saw it and not when whichever node booted first
thought it did.

### `aurora_meter_plan_transitions`

```
  id uuid null=NO default=gen_random_uuid()
  tenant_key text null=NO
  ref text null=NO
  from_plan_id text null=YES
  from_version text null=YES
  to_plan_id text null=NO
  to_version text null=NO
  effective_at timestamp without time zone null=NO
  state text null=NO default='pending'::text
  confirm text null=NO default='local'::text
  provider_ref text null=YES
  applied_at timestamp without time zone null=YES
  detail jsonb null=NO default='{}'::jsonb
  inserted_at, updated_at timestamp without time zone null=NO
  INDEX aurora_meter_plan_transitions_due_index (state, effective_at)
  INDEX aurora_meter_plan_transitions_tenant_ref_index UNIQUE (tenant_key, ref)
  CONSTRAINT ..._state_check CHECK (state in ('pending','applied','cancelled','failed'))
  CONSTRAINT ..._confirm_check CHECK (confirm in ('local','provider'))
  CONSTRAINT ..._ref_check CHECK (octet_length(ref) between 1 and 128)
```

Created here and **written by nobody in this release**. 07b adds the behaviour;
shipping the DDL now means phase 07 is one core migration for a host rather than
two.

### `aurora_meter_subscriptions`, the ten new columns

```
  plan_version text null=YES
  plan_fingerprint bytea null=YES
  plan_effective_at timestamp without time zone null=YES
  scheduled_plan_id text null=YES
  scheduled_plan_version text null=YES
  scheduled_effective_at timestamp without time zone null=YES
  transition_ref text null=YES
  transition_state text null=YES
  transition_confirm text null=YES
  transition_applied_at timestamp without time zone null=YES
  INDEX aurora_meter_subscriptions_pending_transition_index
      (scheduled_effective_at, tenant_key) WHERE (transition_state = 'pending'::text)
  CONSTRAINT ..._transition_state_check
      CHECK (transition_state IS NULL OR transition_state = ANY (...)) validated=true
  CONSTRAINT ..._transition_confirm_check
      CHECK (transition_confirm IS NULL OR transition_confirm = ANY (...)) validated=true
```

The index is **partial**, as `schema-migration-map.md` S6 requires. The 07a build
document quotes the earlier unpredicated form of that row; the map was corrected
after the document was written and the map is binding (finding X285).

Both checks were added `NOT VALID` and validated in a separate statement, with
`validate_checks: false` as the named escape hatch and
`AuroraMeter.Migration.V10.find_violating_subscriptions/0` quoted in the error.
They can only be violated by something other than Aurora Meter writing to two
columns this version itself creates as NULL, so the scan is expected to be
trivial; the hatch and the finder query exist because a migration against a
customer database must never fail without saying what to look at.

## The legacy assignment, measured

Driven through the same statement `AuroraMeter.Storage.Ecto` issues, over the
same 100,000 rows.

```
assignment batches: 20
assignment rows: 100000
assignment orphan_plans: 14285
assignment wall ms: 1046
assignment slowest batch ms: 81
assignment batch ms: [81, 62, 61, 59, 59, 59, 58, 53, 56, 54, 54, 47, 45, 43,
                      41, 40, 39, 39, 41, 37]
rows with no plan_version after the assignment: 0
rows whose plan_id changed: 0
```

Twenty batches of 5,000, about a second in total, no batch above 81 ms. The
14,285 orphans are the `plan_id = 'unknown'` rows: they get a version and a NULL
fingerprint and are counted, never refused, because retiring a plan id from code
is ordinary and refusing the upgrade over one would make the upgrade unrunnable
for exactly the oldest installs (S6's own text).

### Interrupted and resumed

```
interrupted: unnamed before: 100000
interrupted: unnamed after two batches: 90000
resumed batches: 18
resumed rows: 90000
resumed: unnamed after: 0
total rows: 100000
```

Two batches, then stop as a kill would, then a fresh loop finishes the other 18.
There is no checkpoint row: the predicate `plan_version IS NULL` is its own
checkpoint. The row count is unchanged throughout.

The process-kill version of the same claim is in
`AuroraMeter.PlanRegistryConcurrencyTest`, which kills the worker for real with
`Process.exit(pid, :kill)` at a fault point inside the batch loop. See
`i17.md`.

## X220, verified separately

The last statement version 10 runs, and the only one that has nothing to do with
plans:

```sql
ALTER TABLE aurora_meter_flush_receipts
  ALTER COLUMN inserted_at SET DEFAULT (clock_timestamp() AT TIME ZONE 'UTC')
```

after which `AuroraMeter.Storage.Ecto.flush_batch/3` omits the column from its
`insert_all` and Postgres stamps it. `AuroraMeter.Retention` compares that
column against a cutoff the **database** computes; it was written from the
**node's** wall clock, which is two clocks on one comparison, and a receipt
pruned early reopens the double-count window I01 exists to close.

Three separate proofs, none of which touches plan versions:

1. `AuroraMeter.MigrationV10Test` / `test X220 version 10 gives the flush receipt
   a clock_timestamp default`: the column default is absent at version 9 and
   present at version 10, a row inserted without the column is stamped, and
   `down` removes the default again.
2. `AuroraMeter.StorageTest` / `test X220 a flush receipt's inserted_at comes
   from the database, not from the node clock`: `flush_batch/3` is called with
   the node clock frozen at 2020-01-01 and the stored `inserted_at` is after
   2024-01-01.
3. `AuroraMeter.StorageTest` / `test X220 the receipt still deduplicates a
   retried batch and does not move its timestamp`: the `on_conflict: :nothing`
   decision that I01 rests on is unchanged: a second `flush_batch/3` with the
   same id adds nothing to the counter and the receipt keeps its first instant.

Negative control `d-node-stamped-receipt` restores `inserted_at: Clock.now()`:
proof 2 fails, proof 3 still passes. That is the honest discrimination boundary
and it is the right one, because proof 3 is about idempotency and the control
does not break idempotency.

**Operational consequence, stated plainly.** A 1.0.0-rc.1 node against a version
9 database **cannot flush**: the insert omits a `NOT NULL` column that has no
default until this version lands, so every flush fails a not-null constraint
immediately and loudly. That is the quiescence requirement
`schema-migration-map.md` section 4 already records for S6 (the migration and
the release ship together), and it is recorded again as finding **X292** because
the failure mode is new.

## Idempotency, ordering and rollback

- `test I19 version 10 run twice is a no-op`: the catalogue is identical after
  one run and two.
- `test I19 a fresh install and an incremental upgrade to 10 produce the same
  catalogue`: `up(from: 1, version: 10)` and the version-by-version ladder
  agree.
- `test I19 down of version 10 removes both tables and every column it added`:
  the catalogue returns to exactly version 9's.
- `test I19 version 10 is on the data-loss list, so its down needs
  confirm_data_loss`.

Application rollback to the previous image is supported after S6 until a
transition is scheduled, with one exception this unit introduces and X292
records: the previous image's `flush_batch/3` stamps `inserted_at` itself, which
still works against the new default, so a rollback of the **code** is safe; a
rollback of the **schema** while the new code runs is not.

## Toolchain

Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), Postgres 16 (Docker
`aurora-meter-pro-testdb`, port 5490), WSL2 Ubuntu 24.04 on Windows 11.
