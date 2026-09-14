# 03b: `record` facade, storage callbacks, projection and backpressure

The seven items of `v1-release.md` 1.2.

Every command, exit code, seed, timestamp and log path is in
`03b-commands.txt`. Toolchain: Elixir 1.20.1, OTP 29, ecto_sql 3.14.0,
PostgreSQL 16.13 on port 5490. Core at `286f3d6` (03a) when the unit started.

## 1. What was built

### Core, `lib/`

| File | What it does now |
|---|---|
| `events/canonical.ex` | **Extended**, not replaced. 03a's `canonical_json/1`, `encode/1` and `legacy_payload_hash/1` are untouched; added `validate/1`, `validate_batch/1`, `payload_hash/1`, `tuple/1`, `string_keys?/1`, `safe_canonical_json/1` and the limit accessors. Every failure it finds is accumulated, not short-circuited. |
| `storage.ex` | Seven new callbacks plus `capabilities/0`, their types, and dispatchers that check the capability before the adapter is reached. |
| `storage/ecto.ex` | `record_events/2` (the six-step transaction), `load_event/2`, `load_event_total/3`, `stream_events/2`, `write_projection_totals/2`, `activate_projection/1`, `capabilities/0`, `host_transaction?/0`, and `guarded/1`, which turns every way Postgres can refuse into the one error shape the contract names. |
| `events.ex` | **New.** `get/2`, `total/3`, `count/3`, `stream/1`, `after_commit/1` public; the `record/4` and `record_batch/2` orchestration, the gate, the period attribution, the post-commit effects and the telemetry span internal. |
| `events/gate.ex` | **New.** The admission counter, as a GenServer that monitors its callers. |
| `events/outbox.ex` | **New.** The behaviour and `Outbox.Noop`. |
| `schema/event_total.ex` | **New.** The Ecto schema over `aurora_meter_event_totals`. |
| `storage_case.ex` | **New.** The adapter conformance suite, shipped in `lib/` so an adapter author can use it. |
| `counter.ex` | `apply_projection/2`; the seeding indirection through `Config.feature_source/1`; the C6 fix (`ensure_seeded/1` in `commit_work/5` and `release_work/4`); `restore_pending/2` removed (C8). |
| `aurora_meter.ex` | `record/4`, `record_batch/2`, and the moduledoc paragraph on counting versus recording. |
| `config.ex` | `feature_sources`, `events_outbox`, `events_future_tolerance`, `record_timeout`, `record_max_concurrency`, their accessors, `feature_source/1`, and a conditional boot check for the outbox module. |
| `entitlements.ex` | `feature_policy/3`, the one seam `record/4` applies the undeclared-feature policy through, so two paths cannot disagree about what "undeclared" means. |
| `supervisor.ex` | `Events.Gate`, immediately after `Store`. |

### Core, tests and docs

New: `record_test.exs` (33), `record_batch_test.exs` (11),
`record_concurrency_test.exs` (9), `record_projection_test.exs` (13),
`events_gate_test.exs` (8), `storage_case_test.exs` (28),
`test/support/.../recording_outbox.ex`, `test/support/.../storage_fakes.ex`,
`docs/storage-adapters.md`.

Modified: `docs/api.md` (a new section 1.2 for `AuroraMeter.Events`, the
storage dispatchers, the configuration keys, the telemetry span, the PubSub
message, the behaviour rows, `StorageCase`), `docs/telemetry.md`,
`docs/correctness.md` (I06, I07 and I08 promoted or extended),
`mix.exs` (docs groups and extras; `AuroraMeter.record/4` removed from
`skip_code_autolink_to`, which its own comment asked 03b to do),
`api_inventory_test.exs` (`Events.Gate` internal; `telemetry_sites/0` now counts
spans), `kill_test.exs` (the C6 assertion flipped), `cluster_test.exs` and the
01b harness (`FaultStorage`, `FaultRepo`, `Connections`, `harness_test.exs`).

### Pro, tests only

`FaultStorage` gained the seven callbacks and the `@uninstrumentable` list,
`FaultRepo` gained `all/2`, `Connections` gained `AuroraMeter.Schema.EventTotal`,
and `harness_test.exs` asserts the excused list is real. No `lib/` change, as
the build document requires.

## 2. Acceptance criteria

| # | Criterion | Met | Evidence |
|---|---|---|---|
| 1 | Twelve concurrent submissions of one identity produce one row, one totals delta and one outbox item; every task returns `:inserted`, `:duplicate` or a `conflict_unresolved` that becomes definite on retry | **yes** | `03b-concurrency.json`: 1 inserted, 11 duplicate, 0 unresolved, 1 row, quantity 5 / events 1, 1 outbox item |
| 2 | A submission of an existing identity with any changed field returns `{:error, {:conflict, existing}}` and writes nothing | **yes** | `RecordTest` / `identity I07 a changed quantity, occurred_at, feature, dimension or metadata value each conflict` (five cases) |
| 3 | The same id under two tenant keys produces two events; the same id for two features in one tenant conflicts | **yes** | `RecordTest` / `I06 the same id in two tenants creates two events`, `I07 the same id for two features in one tenant conflicts` |
| 4 | A batch containing one conflicting element leaves zero new rows, zero totals deltas and zero outbox items | **yes** | `RecordBatchTest` / `I07 a conflicting element rolls back every new row in the batch` (10 elements, element 7 conflicts) |
| 5 | Repeated ids with equal payloads produce one row and results in input order; with different payloads they are rejected before any database call | **yes** | `RecordBatchTest`, two tests; the second asserts `RecordingOutbox.calls() == 0` |
| 6 | Killing the caller before commit leaves nothing; after commit leaves exactly one of each, and a same-id retry returns `:duplicate` and adds nothing | **yes** | `03b-kill-matrix.md`; `RecordConcurrencyTest`, two tests |
| 7 | A host transaction that rolls back after `record/4` leaves no row, no delta, no outbox item and no ETS delta | **yes** | `RecordProjectionTest` / `I06 an outer host transaction rollback leaves ...` |
| 8 | After 1000 records of an events-source feature, the next flush batch contains no entry for it and `load_counter/3` is still nil | **yes** | `RecordProjectionTest` / `I08 a projected event never appears in a flush batch`: 1000 events in two batches of 500, flush batch empty for that tenant, `load_counter/3` nil, `Events.total/3` 1000 |
| 9 | `usage/2` for an events-source feature after `AuroraMeter.Test.reset!/0` equals `Events.total/3` | **yes** | `RecordProjectionTest` / `usage/2 for an events-source feature after reset!/0 equals Events.total/3` |
| 10 | With the gate saturated, `record/4` returns `{:error, {:unavailable, :overloaded}}` and the ETS counter is unchanged | **yes** | `EventsGateTest`; negative control C4 breaks it and the test notices |
| 11 | An admitted caller killed with `:kill` releases its permit | **yes** | `EventsGateTest` / `admission a killed admitted caller releases its permit` |
| 12 | A database that never answers produces `{:error, {:unavailable, :timeout}}` within `record_timeout` plus the pool checkout, never an exit | **yes** | `EventsGateTest`: `ACCESS EXCLUSIVE` lock from another connection, `record_timeout: 400`, measured **412 ms**, result `{:error, {:unavailable, :timeout}}` |
| 13 | `AuroraMeter.StorageCase` passes for `Storage.Ecto` and for a capability-less fake | **yes** | `StorageCaseEctoTest` and `StorageCaseIncapableTest`, 28 tests |
| 14 | The core suite passes with LiveView, Phoenix.HTML, Igniter and Oban absent | **yes**, after a fix | `03b-headless.txt`: cold build, 957 passed. The first attempt failed one test; see finding F4 |
| 15 | `mix check` passes with no new Dialyzer or Credo finding | **yes** | `tmp/v1/03b/logs/check.txt`: credo 1776 mods/funs no issues, dialyzer 0 errors, docs with `--warnings-as-errors` |

Two criteria needed a decision rather than only a test, and both are recorded in
full in their own notes: `03b-conflict-wait.md` (criterion 1's
`conflict_unresolved` clause) and `03b-in-transaction.md` (criterion 7's
detection).

## 3. Test counts and gates

| | Before | After |
|---|---|---|
| Core `mix test` | 866 passed (42 doctests, 10 properties, 814 tests), 3 excluded | **967 passed** (42 doctests, 12 properties, 913 tests), 3 excluded |
| Core `mix check` | (not run at baseline) | **exit 0** |
| Core headless (`AURORA_HEADLESS=1 mix test --include headless`) | 856 passed at HEAD | **957 passed** |
| Core `mix v1.faults` | | **76 passed**, 894 excluded |
| Pro `mix test` | 420 passed before the change (recompiled against old core) | **420 passed** |
| Pro `mix check` | | **exit 0**, after a stale PLT was cleared (finding F5) |

Net: **+101 tests, +2 properties**, no test deleted and none weakened. The one
existing assertion that changed is the C6 regression test, which asserted the
defect this unit fixes and whose own comment said "03b seeds the row first and
flips these two assertions".

## 4. Proof the buffered hot path is unchanged

Established, not assumed, four ways.

**(a) By diff.** `Counter.bump/2`, `Counter.reserve/6`, `Store.snapshot/0`,
`Store.snapshot_flush_batch/0`, `Flusher.persist/1`,
`Broadcaster.do_broadcast/0` and `Storage.Ecto.flush_batch/3` are
byte-identical to `286f3d6`; nothing under `lib/aurora_meter/credits/` was
touched at all. `counter.ex` has exactly three changes: two `ensure_seeded/1`
calls (the C6 fix the brief permits), the removal of dead `restore_pending/2`,
and the addition of `apply_projection/2`, which is a new function no existing
path calls. `commit_work/5`'s arithmetic is unchanged: the three
`:ets.update_counter/3` operands are the same three, in the same order.

**(b) By the seeding indirection's shape.** `stored_value/1` now asks
`Config.feature_source/1` first. For a feature with no `feature_sources` entry,
which is every feature in 0.4.x and the default in 1.0, the answer is
`:buffered` and the call is the same `Storage.load_counter/3` it always was.
`RecordProjectionTest` / `a buffered feature still seeds from the counter table, not from event totals`
asserts exactly that, with a durable event of quantity 100 recorded against the
same key and the cold read still returning the flushed 4.

**(c) By the existing suite.** The 814 tests that existed before this unit all
still pass, including `metering_test`, `entitlements_test`, `store_test`,
`flusher_test`, `flush_batch_concurrency_test`, `statements_test`,
`cluster_test`, `cluster_convergence_test` and `kill_test`. Those are the
buffered path's own tests and none of them was modified except the one C6
assertion.

**(d) By a negative control.** C1 makes `apply_projection/2` write
`pending_flush` and mark the key dirty, which is precisely "the projection
entered the flush path", and `I08 a projected event never appears in a flush batch`
fails. The control proves the assertion is load-bearing rather than vacuous.

**What is not claimed:** a benchmark. 08c owns the `track/4` timing comparison,
and this unit adds no database I/O, no lock and no extra ETS operation to
`track`, `check`, `reserve` or `with_quota`. The one structural addition on any
existing path is the `Config.feature_source/1` map lookup on a **cold key seed**,
which is already a database round trip.

## 5. Backpressure and concurrency limits, per X100

**No mechanism in this unit compares two wall-clock instants.**

| Bound | Mechanism | Why not a clock |
|---|---|---|
| Concurrent durable writers | `Events.Gate`: a GenServer holding a count and a monitor per admitted caller | A permit comes back when the caller dies, however it dies. A `:counters` reference would leak on a `:kill`, and a lease with an expiry would be a second-scale duration decided against a clock that steps backwards 439 ms (X100). The gate expires nothing. |
| One durable write | `record_timeout` passed to `repo.transaction/2` **and to every statement inside it**, and forwarded to the outbox in its context | DBConnection's own monotonic timer on a statement, not a comparison of two stamped instants. Measured: 412 ms against a 400 ms bound, answer `{:error, {:unavailable, :timeout}}`, no exit. |
| Request size | `byte_size/1` of the canonical JSON the caller sent, before any I/O | X104: `pg_column_size()` measures the stored size after compression, so a compressible payload of any size passes. Control C5 raises the limit and the named test notices. |
| Record against generation activation | `SELECT ... FOR SHARE` on the `events_projection` checkpoint row, against activation's `FOR UPDATE` | A lock, not a timeout. Two records do not block each other; both block activation; activation waits for every in-flight record. Asserted in `RecordConcurrencyTest` / `generations I06 a record transaction in flight blocks generation activation ...`, which measures that activation does **not** return within 1500 ms while a record is in flight. |
| Deadlock between concurrent batches | A total order on both multi-row statements: `{tenant_key, event_id}` for the insert, `{tenant_key, feature, period_start, generation}` for the totals | Ordering, not retry-with-backoff. Ten passes of two connections submitting the same two keys in opposite order, all 20 batches committed. |

The only time value anywhere on the path is `occurred_at` against
`Clock.now()`, and that is a comparison against a **caller-supplied** instant,
so the node clock is the right clock (architecture map section 3), with a 300
second default tolerance that a bounded sub-second step cannot invert.

`lib/` contains no `DateTime.utc_now`, `Date.utc_today`, `System.os_time`,
`System.system_time`, `System.monotonic_time` or `:timer.tc` outside
`AuroraMeter.Clock`; `AuroraMeter.ClockTest`'s P07 audit is green and the two
hits this unit introduced (a doc example and a `StorageCase` fixture) were both
removed rather than excused.

## 6. The two measurement notes

**`03b-conflict-wait.md`.** PostgreSQL 16.13, READ COMMITTED.
`INSERT ... ON CONFLICT DO NOTHING` **waits** for a concurrent transaction
holding the conflicting row: 1505 ms against a holder released at 1500 ms, in
both directions. After the holder commits, the second inserter inserts 0 rows
and the committed row is visible to the read-back. After it rolls back, the
second inserter inserts 1. Under REPEATABLE READ the insert raises
`40001 serialization_failure` instead of skipping. The `conflict_unresolved`
branch is therefore not reachable by the ordinary race, but **is** reachable
when the conflicting row is deleted between the insert and the read-back
(`{:ok, {0, 0, []}}` measured), which a retention prune racing a retry produces.

**`03b-in-transaction.md`.** ecto_sql 3.14.0: `repo.in_transaction?/0` is
**`false`** on a sandbox checkout with no host transaction, and `true` inside
one, on sandbox and non-sandbox connections alike. The build document's warning
does not hold on this version, so `host_transaction?/0` is
`repo().in_transaction?()` with no carve-out, and a regression test asserts
every cell of the matrix.

Two more numbers worth having here: `record_timeout: 400` produced
`{:unavailable, :timeout}` in **412 ms**; twelve connections on one identity
produced **1 inserted, 11 duplicate, 0 unresolved**.

## 7. Findings for `open-findings.md`

**F1. The build document's `encode_tuple/1` would have invalidated every hash
03a has already written.** 03b specifies "the concatenation of length-prefixed
canonical JSON strings for each element". 03a shipped, and the V7 backfill
migration has already used, a canonical JSON **array**. Changing the encoding
would change every `payload_hash` in every database that has run the backfill,
and the stated reason for the change ("no field value can impersonate a
delimiter") is already satisfied: JSON is self-delimiting, every element is
quoted and escaped. 03a's form was kept, a property test asserts injectivity
over generated payloads, and a unit test asserts that a value containing the
separator characters hashes differently from the split it imitates. **Severity:
high if implemented as written.**

**F2. `api-change-map.md` 1.6 and the 03b build document disagree on the
telemetry shape, and the map wins.** The document specifies
`:telemetry.execute([:aurora_meter, :record], ...)`; the map specifies a
`:telemetry.span/3` triple and gives the reason (an OpenTelemetry bridge must
open the span before the database work starts so Ecto's spans nest inside it).
The span is implemented. Consequence for the guard: 02a's
`telemetry_sites/0` scanned only `:telemetry.execute(`, so the new span was
invisible to the A05 check that is supposed to prove a documented event is
emitted. It now matches `execute` and `span` both. **A guard that cannot see a
whole category of emit site is not a guard.**

**F3. `commit_work/5` on a cold key leaves `reserved` negative, and
`Counter.rebase/3` folds `reserved` into the value.** A Store restart between a
deferred reservation and its commit destroys the reservation row; the C6 fix
seeds a fresh row and then applies `{:reserved, -qty}`, so `reserved` is
negative and this node's view sits one lost reservation below the database
until the next cold seed. Measured: after a restart, `commit_work` of 2 and a
flush, the database reads 2 and `usage/2` reads 2 rather than 4 after a further
deferred reserve of 2. The arithmetic of `commit_work/5` is deliberately
unchanged (03b's brief), so this is recorded rather than fixed, and the kill
test asserts the measured number with the explanation beside it. **Severity:
low, buffered path, self-correcting; but it should be decided deliberately by
whichever unit next owns `counter.ex`.**

**F4. `function_exported?/3` in 01f's headless test is order-dependent and
fails on a cold build.** `I20 the installer prints steps instead of raising
without Igniter` asserts
`function_exported?(Mix.Tasks.AuroraMeter.Install, :run, 1)` without loading the
module first. Nothing in `lib/` references a Mix task, so whether it happens to
be loaded depends on the order of the run and on whether the build was cold.
Measured: the **first** `mix test --include headless` on a fresh headless build
failed there; the second, identical, passed, and `Code.ensure_loaded?/1`
reported the module perfectly loadable. The control at HEAD (whole suite,
headless, 856 passed) is what made this worth chasing rather than retrying.
Fixed here with an `assert Code.ensure_loaded?/1` before the two
`function_exported?/3` assertions. **The general shape: a test that asserts a
module's shape must load the module, or it is asserting the run order.**

**F5. A path dependency's beams changing does not invalidate the consumer's
Dialyzer PLT.** After core grew seven `Storage` callbacks, Pro's `mix check`
reported seven `call_to_missing` warnings for `AuroraMeter.Storage.Ecto`
functions that exist, while Pro's `mix test` passed. Deleting Pro's gitignored
`priv/plts/*.plt` and letting it rebuild fixed it. **Constrains every later unit
that changes core's surface**: Pro's `mix check` result is not trustworthy
across a core change until its PLT is rebuilt, and the failure looks like a real
missing function rather than a stale cache.

**F6. `docs/correctness.md`'s PLANNED bullets for 03b named tests in a module
this unit does not create,** `AuroraMeter.EventsTest`, and one of them
(`I06 restart and replay reproduce the same totals`) is replay, which is 03d's.
The bullets were promoted to the tests that were actually written, and the
replay bullet was re-tagged `PLANNED (03d)` rather than left as a 03b promise
the unit did not keep. **The index test cannot catch this: a PLANNED bullet is
required not to resolve, which a bullet naming a module nobody will ever create
satisfies for ever.**

**F7. Making the `Storage` callbacks mandatory breaks Pro's test harness, and
the build document says Pro needs no file changes.** The scope line is right
about `lib/` and wrong about `test/support`: `AuroraMeter.Pro.Test.FaultStorage`
declares `@behaviour AuroraMeter.Storage`, Pro compiles with
`warnings_as_errors`, and Pro's suite would not compile. Four Pro test-support
files were changed. **Any later unit that adds a `Storage` callback pays the
same cost in both repositories, plus F5.**

**F8. `capabilities/0` must not be fault-instrumented.** Every durable
dispatcher asks the adapter's `capabilities/0` before doing the work, so a
`:before_commit` fault armed for `record_events` fires on the capability check
instead and the test proves nothing about the transaction it named. Both
`FaultStorage` shims now implement it plainly and name it in an
`@uninstrumentable` list with a reason, which the harness self-test checks is a
real callback. **The parity guard's "`[]` is the only acceptable value" needed
an exception, and an exception with a machine-checked reason is better than a
guard quietly weakened.**

## 8. Deliberately not done

- **`correct/4`, `replace/4`, `record_correction/2`** (03e), **`feature_sources`
  semantics beyond the accessor** (03c: the `track/4` guard, the
  `durable_features` interaction, the boot error, the cutover), **replay,
  generations and pruning beyond honouring the active generation** (03d),
  **plan attribution** (07c: `plan_id` and `plan_version` are written as `nil`).
- **A `CHANGELOG.md` entry.** `release_metadata_test.exs` G02 refuses a
  non-empty `[Unreleased]` section, which is why 03a wrote none either. The
  `restore_pending/2` removal and the new public surface are recorded in
  `03b-api.md` for whichever unit cuts the release.
- **A benchmark of the buffered path.** 08c owns it; section 4 says what was
  established instead.
- **A fault point inside `Storage.Ecto.record_events/2`.** It would have let the
  `conflict_unresolved` branch be driven end to end, and it would have put test
  scaffolding inside the one transaction this programme most needs to be able to
  read. The state is proven producible and the caller-visible answer is asserted
  instead; `03b-conflict-wait.md` says exactly what that does and does not
  prove.
- **A sandbox carve-out in `host_transaction?/0`.** Measured unnecessary; see
  `03b-in-transaction.md` for why adding it would have been worse than useless.
- **Ticking any checkbox** in the build document or the programme README.
