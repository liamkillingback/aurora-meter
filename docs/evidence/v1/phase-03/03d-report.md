# 03d: projection replay into an isolated generation

The seven items of `v1-release.md` 1.2.

## 1. Tasks, repository and source

| | |
|---|---|
| V1 task | **03.07**, build unit **03d** |
| Invariants | contributor to **I06**, **I08** and **I09**; introduces L-03d-1 (completeness), L-03d-2 (isolation), L-03d-3 (atomicity of activation) and L-03d-4 (retention) |
| Gates | **G03** bullet 4 (100,000 facts and corrections replay to exact totals after interruption and restart) and bullet 3 (crash and restart safety) |
| Core repository | `product-workspaces/aurora_meter`, HEAD `ddb8ecb9bcd3b92e75268d248c41a6431054fdba` (`feat(v1): immutable corrections, and a negative control that had been lying`) |
| Core state | **dirty**, uncommitted. Tracked modifications sha256 `025ea5ce7d1e1ea92dae6d9a2029a26d280e8c22d74ce3a6a7ad9e267e982a88` |
| Pro repository | `product-workspaces/aurora_meter_pro`, HEAD `112c984a0f970aae3f6671ccff03eafc57dd709b` |
| Pro state | **dirty**, one test-support file. Tracked modifications sha256 `96e276c506ad7f03119062656c389a9dfda7a04a0c2bc60d99f6c174f0c859e5` |
| Storefront | branch `aurorameter-v1` at `4758c55`; changed only under `docs/v1/build-plans/` (this unit's status line and `open-findings.md` rows). No storefront code change |

New core source and documentation files, sha256 of the working tree when this
report was written. The nine new files under `docs/evidence/v1/phase-03/` are
this report and its exhibits; `bash tmp/v1/03d/checksums.sh` lists every new
file including them.

| sha256 | file |
|---|---|
| `9a37f450b036e23859c9befd1da0e4ad91f37bfa9d501e0957d73b647a6e8280` | `lib/aurora_meter/events/replay.ex` |
| `8dfbdb6840c10dd405b305861fee07ce8e0d61e46a08ab9a2a9fb75089213118` | `test/aurora_meter/events_replay_test.exs` |
| `5c9b9bbe58920f6542ccae0b4863e49874ffa2282f1d82dce253dc04a41dc009` | `test/aurora_meter/events_replay_large_test.exs` |
| `dc80a2736153cc737f62b77b9167bb63090c7e64a097ae4c24fb19a99a10d110` | `docs/operations/replay.md` |

Reproduce with `bash tmp/v1/03d/checksums.sh`. **Nothing is committed.** The
owner reviews and commits.

## 2. Versions, toolchain and environment

| | |
|---|---|
| Core package | 0.5.0 |
| Pro package | 0.3.0 |
| Core schema version | 8 (unchanged; this unit adds **no** DDL) |
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts-17.0.1) |
| Operating system | Ubuntu 24.04 on WSL2, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Database | PostgreSQL 16.13, port 5490, `aurora_meter_test` |
| `mix.lock` sha256, core | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` |
| `mix.lock` sha256, Pro | `bd66012e64e0ce2cb97e5a9fdbee15c248277484a18f7176731e10649c6df424` |

## 3. Commands, exit codes, seeds, timestamps and logs

Every command with its exit code, UTC timestamps and log path is in
`03d-commands.txt`. The headline runs:

| Command | Exit | Result | Log |
|---|---|---|---|
| `mix test --seed 0` (core, baseline **before** the unit) | 0 | **1084 passed** (42 doctests, 12 properties, 1030 tests), 3 excluded | `tmp/v1/03d/logs/baseline-core-test.log` |
| `mix check` (core, after) | 0 | **1120 passed** (46 doctests, 12 properties, 1062 tests), 3 excluded; Dialyzer clean; Credo clean; `mix docs --warnings-as-errors` clean; format clean | `tmp/v1/03d/logs/core-check-final2.log` |
| `mix check` (Pro, PLT deleted first) | 0 | 420 passed (28 doctests, 392 tests) | `tmp/v1/03d/logs/pro-check-1.log` |
| `mix test events_replay_test.exs events_replay_large_test.exs --seed 0` | 0 | 30 passed, run **after** every negative control was restored | `tmp/v1/03d/logs/replay-after-controls.log` |
| the seven negative controls | each 2 | each fails exactly the tests its layer holds up | `tmp/v1/03d/logs/control-*.log`, summary `03d-negative-controls.txt` |
| the symbol comparison and its own proof | 0 and 1 | 148 symbols byte-identical to HEAD; the tool reports a planted change | `03d-unchanged-symbols.txt`, `03d-symbol-tool-proof.txt` |

**Core test count: 1084 before, 1120 after (+36: 23 replay tests, 3 large tests, 3 conformance tests in each of the two StorageCase suites, and 4 doctests.)**

X114 was observed and honoured: Pro's `priv/plts/*.plt` was deleted before Pro's
`mix check`, because core grew five `Storage` callbacks and a path dependency's
beams changing does not invalidate the consumer's PLT. The deletion is in the
log (`tmp/v1/03d/logs/pro-check-1.log`, preceded by `tmp/v1/03d/pro.sh`'s
listing of the files before and after).

## 4. Expected and actual results

### The gate bullet: 100,000 facts and corrections, killed and restarted

`03d-replay-100k.json`, from
`AuroraMeter.EventsReplayLargeTest / test I06 100,000 facts and corrections
replay to exact totals after a kill and a restart` at seed 7:

| | |
|---|---|
| events | 100,000 (90,000 usage, 10,000 corrections) |
| keys | 750 (50 tenants x 5 features x 3 periods) |
| batch size | 1,000 |
| kill batch | 8, derived from the ExUnit seed |
| run 1 scanned | 8,000 |
| run 2 scanned | 92,000 |
| total scanned | 100,000 (no batch re-read: the killed batch had not committed) |
| differences | 0 |
| duration | 6,393 ms |
| **digest before** | `58fe07f8a62e7b74fdb469a2836fd675c95bf7dc4ee9f163c86567521734b56a` |
| **digest after** | `58fe07f8a62e7b74fdb469a2836fd675c95bf7dc4ee9f163c86567521734b56a` |
| equal | **yes** |

The digests are sha256 over `:erlang.term_to_binary/1` of the **sorted** list of
`{tenant_key, feature, period_start_iso8601, quantity, events}` for this run's
750 keys: taken from the active generation before the replay, and from the
activated generation after it. The same list is also compared with a `GROUP BY`
straight over `aurora_meter_events`, so a shared bug in the live projection and
the rebuild could not make both digests agree.

The kill is a real untrappable `Process.exit(pid, :kill)` through
`AuroraMeter.Test.Kill`, armed at `:before_commit` inside
`write_projection_totals/2` on `AuroraMeter.Test.FaultStorage`. After it, the
checkpoint cursor is asserted to name **exactly** the `seq` the last committed
batch left and the building generation's rows to be **exactly** what that batch
left, which is the acceptance criterion "no batch is ever partially applied".

### Interleaved with twelve recorders

`03d-interleaved.json`: a replay over 10,000 seeded events with twelve
independent, non-sandbox connections recording throughout (1,800 records
committed inside the replay's window). The activated generation and an
independently computed `GROUP BY` over every committed event, taken after every
recorder stopped, have the same 762 keys and the same digest
`6676e68d95b84aa4d947d0315b1d2cfef23a989107ad2b7e355a3c673766cb38`.

### The activation is atomic for readers

`03d-activation-atomicity.txt`: a reader loop on an independent connection
calling `AuroraMeter.Events.total/3` across one activation made 49 reads and
observed exactly two distinct values, `1005` (the old generation: 5 recorded
plus 1,000 planted) and `5` (the rebuild). The assertion refuses any third
value, which is what a partial sum would be.

### A correction while a generation is building

This is the case the build document does not have and the seed exists for.
`03e`'s `apply_correction_totals/2` carries a "NOTE FOR 03d" saying so. A
correction applies a **negative** delta to both generations; a correction whose
original committed below the watermark but whose key the scan has not reached
would take the building generation's row below zero, and 03a's
`aurora_meter_event_totals_quantity_check` would refuse it. The correction would
be reported to the caller as `{:error, {:invalid, [quantity: :exceeds_original]}}`
(`record_correction/2` translates the constraint into the bound's own tuple),
which is a **legal correction refused with a wrong reason**, caused by an
operator's replay.

The announcement therefore copies the active generation into the building
generation and into a frozen seed generation `-building`, inside the same
transaction that takes the exclusive lock. That makes one thing true for the
whole build:

    building(key) == active(key) + (whatever the scan has added so far)

Both terms are non-negative, so the building generation is refused exactly when
the active one would have been and never on its own account.
`drain_projection_seed/2` takes the copy back out, one bounded slice at a time,
after the scan completes and before the comparison. Asserted by
`AuroraMeter.EventsReplayTest / test a correction while a generation is building
I09 a correction for an unscanned original commits and lands in both
generations`, and the control `n2-seed` is the proof it is load-bearing.

### Every acceptance criterion

| Criterion | Met | Evidence |
|---|---|---|
| A replay of at least 100,000 facts and corrections, killed at a batch boundary and restarted, produces per-key totals byte-identical to the pre-replay live totals, and the two sha256 digests are equal | **yes** | `03d-replay-100k.json`, both digests `58fe07f8...` |
| A replay run concurrently with 12 independent recorders produces an activated generation equal to an independently computed aggregate | **yes** | `03d-interleaved.json`, both digests `6676e68d...` |
| No batch is ever partially applied: the cursor after a kill names a `seq` whose batch is fully present | **yes** | `EventsReplayLargeTest` and `EventsReplayTest` both assert the cursor **and** the totals after the kill; control `n5-cursor-runs-ahead` fails when the two stop being one transaction |
| A replay writes zero outbox items, publishes zero PubSub messages, grants zero credits, marks zero counter keys dirty and produces zero flush batches | **yes** | `03d-side-effects.md`, eight asserted channels |
| With `compare: :require_match`, a planted difference prevents activation and `active_generation` is unchanged | **yes** | `test the comparison I06 require_match refuses to activate when a difference exists` |
| A reader calling `Events.total/3` across an activation observes exactly two distinct values and never a partial sum | **yes** | `03d-activation-atomicity.txt`, 49 reads, `[1005, 5]` |
| The previous generation's rows still exist after activation and can be reactivated without rebuilding | **yes** | `test activation L-03d-4 the previous generation survives activation and can be reactivated` |
| `prune/1` refuses the active generation and deletes a retired generation in bounded batches | **yes** | `test prune/1 prune/1 refuses the active generation and deletes a retired one`; the delete is `id IN (SELECT id ... LIMIT 5000)` in a loop |
| A paused replay stops within one batch and resumes at its cursor | **yes** | `test pause and resume a paused replay stops within one batch and resumes at its cursor`, which also asserts the cursor is unchanged by the pause |
| `AuroraMeter.StorageCase` passes for the generation callbacks, and an adapter without the capability returns `{:error, {:unsupported, :projection_generations}}` | **yes** | four `StorageCase` tests; `AuroraMeter.StorageCaseIncapableTest` runs the same suite against `AuroraMeter.Test.IncapableStorage` |
| `mix check` passes with no new Dialyzer or Credo finding | **yes** | `tmp/v1/03d/logs/core-check-final2.log`, exit 0 |

Two criteria from the build document's own **Tests** section are met differently
from the way it words them, and both are recorded in section 6.

## 5. What was measured rather than assumed

* **The watermark waits.** `test the announcement I06 the announcement waits for
  an in-flight record transaction` parks a real `AuroraMeter.record/4` inside its
  transaction (in the outbox seam, which is step 5, after the `FOR SHARE` of
  step 1 and the insert of step 2), then asserts the announcement does **not**
  return for 300 ms, releases the record, and asserts the released event's `seq`
  is at or below the watermark. Control `n4-for-update` turns the announcement's
  lock into `FOR SHARE` and that one test, and only that test, fails.
* **The claim has no clock in it.** Exclusion is
  `AuroraMeter.Checkpoints.claim/3`, a Postgres **session** advisory lock on a
  pinned connection. Section 6 of this report states why, and what was measured
  about the release after a kill.
* **The totals write cannot use one upsert.** Control `n6-single-upsert` restores
  the `INSERT ... ON CONFLICT DO UPDATE` form and all three large tests fail on
  `aurora_meter_event_totals_quantity_check`, because a batch that holds only
  corrections for a key proposes a negative tuple and PostgreSQL judges the
  proposed tuple rather than the row the update would leave (X124). Found by the
  100,000-event test, not by reading.
* **Legacy rows are not in the live projection and must not be in a rebuild.**
  Rows from `AuroraMeter.track/4` on a legacy durable feature
  (`attribution = "legacy_track"`, `event_id` `"track:<uuid>"`) and the same rows
  after `mix aurora_meter.events.backfill` (`event_id` `"legacy:<id>"`) are in
  `aurora_meter_events` and in no total. Summing them would make every rebuilt
  total larger than the live one for a key with history. Control
  `n7-legacy-filter` removes the predicate and the test fails.

## 6. Negative controls

`03d-negative-controls.txt` has the full summary. Seven controls, each disabling
**exactly one** layer, restoring from a saved copy and asserting the restore
(X97):

| Control | Layer disabled | Exit | Tests that failed | Named the constraint |
|---|---|---|---|---|
| `n1-watermark` | the `seq <= watermark` bound | 2 | 8, including `the scan is bounded by the watermark` | no |
| `n2-seed` | the announcement's copy of the active generation | 2 | 2, including the correction-while-building test | **yes** |
| `n3-drain` | taking the seed back out | 2 | 8, including every `require_match` assertion | no |
| `n4-for-update` | the exclusive lock in the announcement | 2 | **1**: `the announcement waits for an in-flight record transaction` | no |
| `n5-cursor-runs-ahead` | committing the totals and the cursor in one transaction | 2 | **1**: `restart and replay reproduce the same totals` | no |
| `n6-single-upsert` | insert-at-zero then update, instead of one upsert | 2 | 3, all of the large file | **yes** |
| `n7-legacy-filter` | excluding legacy track rows | 2 | **1**: `a legacy track row is in the events table and in no rebuilt total` | no |

**No control passed when it should have failed.** That is the answer X125 asks
for, and it is only true because one test was changed after the control caught
it lying.

### The X125 result, in full

`n2-seed` was run first against the test as originally written, which was

```elixir
log = capture_log(fn -> assert {:ok, _c, :inserted} = AuroraMeter.correct(...) end)
refute log =~ "aurora_meter_event_totals_quantity_check"
```

The control failed, so the *outcome* was right. But it failed on the `assert`
inside `capture_log/1`, with
`{:error, {:invalid, [quantity: :exceeds_original]}}` on the right-hand side and
the log discarded, and that tuple is **the same one the cumulative bound
produces**: `record_correction/2` translates a violation of the totals
constraint into it deliberately (03e). A reader of that failure cannot tell "the
seed is missing" from "the correction really did exceed its original", which is
exactly the shape X125 describes. The `constraint_named` column above read
`False`.

The test was changed to take the log and the result together, to assert the
**log** first, and to say in the failure message which layer answered:

```elixir
{result, log} = with_log(fn -> AuroraMeter.correct(...) end)

refute log =~ "aurora_meter_event_totals_quantity_check",
       "the totals check constraint refused this correction, which means the building " <>
         "generation's row for the key went below zero. ..." <> log

assert {:ok, _correction, :inserted} = result
```

Re-running `n2-seed` then reported `constraint_named=True`. The same shape
applies to `n6-single-upsert`, which also names the constraint.

## 7. The record path and the hot path are unchanged

Established, not assumed. `tmp/v1/03d/symbols.py` extracts `def`/`defp` clauses
**by symbol** (never by line number: X67, X90, X93, X108), from
`git show HEAD:<file>` and from the working tree, joins every clause of a name
and compares sha256. `03d-unchanged-symbols.txt` is the output:

| File | Symbols compared | Result |
|---|---|---|
| `lib/aurora_meter/storage/ecto.ex` | 57 named, covering `record_events/2`, `record_correction/2` and every private function of both transactions plus the pre-existing counter and history callbacks | all **SAME** |
| `lib/aurora_meter/counter.ex` | 16 named, covering `apply_projection/2`, `add_projection/2`, `subtract_projection/2`, `reseat/1`, `incr/4`, `reserve/6`, `rebase/3` | all **SAME** |
| `lib/aurora_meter/store.ex` | every symbol in the file, including `snapshot/0` and `snapshot_flush_batch/0` | all **SAME** |
| `lib/aurora_meter/flusher.ex` | every symbol in the file, including `persist/1` | all **SAME** |
| `lib/aurora_meter/credits/` | five whole files, byte for byte | all **SAME** |
| `lib/aurora_meter/events.ex` | every symbol in the file | all **SAME** |

**148 symbols, no `CHANGED`, no `REMOVED`.**

The tool itself is proved in `03d-symbol-tool-proof.txt`: `lock_generations/2`
is mutated (`FOR SHARE` to `FOR UPDATE`), the same comparison reports `CHANGED`
for it and `SAME` for its two neighbours, the file is restored and the restore is
asserted by sha256.

**The first version of that proof script restored wrongly**, and the assertion is
what caught it: the restore replaced the first `FOR UPDATE` in the file, which is
in `lock_projection_row/0`, so the record path was left share-locking where it
should lock exclusively and the announcement the other way round. That is the
whole of X97 happening to the person applying it. The file was repaired by hand,
verified back to sha256 `5312b2ba5d8dc18bac8130abd1a5114abb954eee4097911d72ce7623cfd36fb8`,
and the script now restores from a saved copy with the assertion kept.

The two functions in `storage/ecto.ex` that **did** change,
`write_projection_totals/2` and `activate_projection/1`, are the two 03b declared
and 03d was asked to fix the semantics of. Three are new
(`begin_projection_generation/0`, `projection_state/0`,
`drain_projection_seed/2`). None is on the record path.

## 8. Deviations from the build document

| Document says | What was done | Why |
|---|---|---|
| The building generation starts empty and the scan adds into it | The announcement seeds it (and a frozen `-building` snapshot) from the active generation, and a drain phase takes the seed back out before the comparison | Without it a live correction for an unscanned key is refused by 03a's `quantity >= 0` check with a misleading reason. 03e handed this to 03d explicitly. Section 4 has the argument; control `n2-seed` has the proof |
| Four `Storage` generation functions | Five: `drain_projection_seed/2` is the fifth | The drain is an operation on the adapter's own tables, like the other four, and `StorageCase` verifies it |
| Duplicate execution is prevented "when the heartbeat is stale" | Exclusion is `Checkpoints.claim/3`, a session advisory lock; the heartbeat decides nothing | X100. `clock_timestamp()` steps backwards 439 ms on a 32.5 s cadence, so no N makes "older than N seconds" sound. 03a's backfill set the precedent and this unit copies it. **No duration comparison survives anywhere in this unit** |
| `prune/1` deletes with `id IN (SELECT id ... LIMIT 5000)` | Kept exactly | The column exists after all: `aurora_meter_event_totals` has a `binary_id` primary key |
| The large test is tagged `:slow` and **excluded from the default run** | Tagged `:slow`, **not excluded** | `test/test_helper.exs` excludes exactly one tag and `AuroraMeter.CiContractTest / test :headless is excluded, and it is the only exclusion` asserts it. A gate bullet that runs only when someone remembers a flag is what that guard exists to prevent. The three large tests cost 10.6 s |
| The interruption test is "armed at the `:during_recovery` fault point" | Armed at `:before_commit` on `activate_projection` | Nothing in this unit calls `Faults.check(:during_recovery, ...)`; there is no such site to arm. `:before_commit` on the activation is the same boundary the sentence describes |
| Phases emit `[:aurora_meter, :replay, :phase]` for `:announce`, `:compare`, `:activate` | Also `:drain` | The drain is a phase, and an operator watching a rebuild needs to see it |

## 9. What this unit deliberately did not do

* **No DDL.** The natural fix for the correction hazard is a constraint that does
  not apply to a non-active generation, and that is a core schema version 9 with
  a migration, a generator change and a `schema-migration-map.md` amendment. Out
  of scope, and the seed makes it unnecessary.
* **No Oban worker.** `AuroraMeter.Oban.EventsReplay` is 05a's, and
  `cron_entries/1` deliberately omits it.
* **No `Operations.pause/1` and `resume/1`.** 05c wraps the same checkpoint
  `state` column this unit writes.
* **No retention job.** 05d schedules `prune/1`.
* **No change to Pro beyond its test harness.** Pro's `FaultStorage` gained the
  three new callbacks because it declares `@behaviour AuroraMeter.Storage` and
  compiles with `warnings_as_errors` (X115, for the third time).
