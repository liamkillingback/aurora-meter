# 01c: core regressions (phase report)

Build unit 01c, `docs/v1/build-plans/phase-01/01c-core-regressions.md`,
wave 1b. Recorded 2026-09-14.

Per-invariant evidence is in `i01.md`, `i02.md`, `i03.md`, `i04.md`, `i05.md`,
`i11.md` and `i12.md` beside this file. This is the phase report required by
`v1-release.md` section 1.2: the seven sections below are its contents.

## 1. Tasks, repository and revision

- V1 task: **01.04** (core regressions). Gate **G01** bullets 1, 2 and 6.
- Repository: core `product-workspaces/aurora_meter` only. Pro untouched.
- Revision: `26e18b6`, **dirty**. The tree carries wave 1a (01a, 01b, 01f) and,
  while this unit ran, wave 1b's 01e as well, so a patch checksum over the whole
  diff is not a checksum of 01c: it moved every time 01e saved a file. The
  checksum at the moment this report was finished is
  `587e31d9b41fb38294fde0b25587586a6d293e144f5323d35f57d1fc3e202bd5`
  (`git diff | sha256sum`), and the file list below is what 01c is accountable
  for.
- **No file under `lib/` is modified by this unit**, and `git status --porcelain
  -- lib/` in the core repository is empty for the whole wave. `git diff --stat`
  outside `test/` lists `.github/workflows/ci.yml`, `README.md`,
  `docs/testing.md` and `mix.exs`, and all but `docs/testing.md` belong to
  earlier units.
- **Pro is untouched by this unit.** `product-workspaces/aurora_meter_pro` is at
  `8d76f52` and its working-tree changes are 01b's harness mirror and 01d's
  regressions; 01c wrote nothing under that directory.
- No secret value appears in this report, in any evidence file, or in any log.
  Tenant keys are the synthetic `<prefix>_<integer>` values from
  `AuroraMeter.Test.unique_tenant/1`.
- No checkbox is ticked, in `v1-release.md`, `plan.md` or any build document.

Files this unit created or edited:

| File | Change |
|---|---|
| `test/aurora_meter/statements_test.exs` | new, 4 tests (I02) |
| `test/aurora_meter/kill_test.exs` | new, 5 tests (I01, I03, I04) |
| `test/aurora_meter/cluster_convergence_test.exs` | new, 4 tests (I05) |
| `test/support/aurora_meter/test/kill.ex` | `await_restart!/2` added to 01b's module |
| `test/aurora_meter/test/harness_test.exs` | 2 self-tests for `await_restart!/2` |
| `test/aurora_meter/flush_batch_concurrency_test.exs` | 2 renames, 1 new test, setup |
| `test/aurora_meter/flusher_test.exs` | 3 renames, `@moduletag :fault` |
| `test/aurora_meter/entitlements_test.exs` | 4 renames, 5 new tests, 1 rename and extension (I20) |
| `test/aurora_meter/metering_test.exs` | 1 rename |
| `test/aurora_meter/cluster_test.exs` | 2 renames |
| `test/aurora_meter/credits_concurrency_test.exs` | 3 renames, 2 new tests |
| `test/aurora_meter/credits_test.exs` | 3 renames, 1 new test |
| `docs/correctness.md` | every rename and addition, and three known-limit paragraphs |
| `docs/testing.md` | two conventions this unit established |
| `docs/evidence/v1/phase-01/` | this file, seven invariant files, logs |

24 tests added. Baseline was 309 core tests; 01c takes that to 333, and the
counts in the logs are higher again because 01e's tests are in the same tree.

## 2. Environment

| Item | Value |
|---|---|
| Elixir | 1.20.1 |
| OTP | 29 |
| PostgreSQL | 16.13 (Debian), container `aurora-meter-pro-testdb`, port 5490 |
| Database | `aurora_meter_test` |
| Schema version | 6 (`AuroraMeter.Migration.latest_version/0`) |
| `sha256sum mix.lock` | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` |
| `repo().config()[:pool_size]` | 30 |
| `Connections.max_tasks()` | 26 |

Every Mix command ran through `tmp/v1/mixlane.sh core`, which sets
`DB_PORT=5490` and takes a `flock` per repository so 01e and 01d cannot corrupt
the same `_build`.

## 3. Commands and logs

All logs are in `docs/evidence/v1/phase-01/logs/`.

| Command | Log | Result |
|---|---|---|
| `mix test statements_test kill_test cluster_convergence_test harness_test --seed 0` with `AURORA_FAULT_REPORT` | `01c-faults.txt`, `01c-faults.jsonl` | **pass**, 59 tests |
| `mix test --seed 1` | `01c-seed-1.txt` | 362/364; 2 failures, both 01e's |
| `mix test --seed 7` | `01c-seed-7.txt` | 362/364; 2 failures, both 01e's |
| `mix test --seed 13` | `01c-seed-13.txt` | 361/364; 3 failures, all 01e's |
| `mix test --seed 101` | `01c-seed-101.txt` | 362/363; 1 failure, 01e's |
| `mix test --seed 4242` | `01c-seed-4242.txt` | **363 passed, 0 failures** |
| `mix test --seed 0` (final, after 01e landed its index bullets) | `01c-seed-0.txt` | **363 passed, 0 failures** |
| `mix test <01c's files only> --seed 1` | `01c-scoped-seed-1.txt` | **321 passed** |
| `mix test <01c's files only> --seed 7` | `01c-scoped-seed-7.txt` | **321 passed** |
| `mix test <01c's files only> --seed 13` | `01c-scoped-seed-13.txt` | **321 passed** |
| `mix test <01c's files only> --seed 101` | `01c-scoped-seed-101.txt` | **321 passed** |
| `mix test <01c's files only> --seed 4242` | `01c-scoped-seed-4242.txt` | **321 passed** |
| `mix format --check-formatted` (whole project) | `01c-format.txt` | **pass** |
| `mix check` | `01c-check.txt` | format, compile, credo (`found no issues`) and docs pass; **dialyzer fails with 2 errors, both 01e's** |
| `mix coverage` | `01c-coverage.txt` | **pass**, total **93.43%** against a floor of 90 |

The three new suites were also run at seeds 0, 1, 7, 13, 101 and 4242 on their
own, after the two defects in section 6 were fixed: **59 passed at every one of
the six seeds**, which is how both of those defects were found in the first
place.

## 4. Results

### What was proved

Each per-invariant file carries the detail; the measured numbers this unit was
asked to produce are:

| Measurement | Value | Where |
|---|---|---|
| leaked reservation after a killed `with_quota` caller | exactly the quantity reserved (3 of 3, and 48 of 48 at the cap) | `i03.md`, `i04.md` |
| `remaining/2` after that kill | 50 to 47, and 50 to 2 | `i04.md` |
| `pending_flush` on a leaked reservation | 0, now and after every later flush | `i03.md` |
| database effect of a killed caller | none, `load_counter` stays `nil` | `i03.md` |
| cluster overshoot, limit 50 | **20**, equal to what the peer admitted in that window; durable total 70 | `i05.md` |
| C6 exception | `ArgumentError`, `"errors were found at the given arguments:\n\n  * 2nd argument: not a key that exists in the table"`, naming neither tenant nor feature | `i03.md` |
| fifty-connection hot wallet | 25 admitted, 25 refused, `held_after` 100 000 to 2 500 000 in 25 steps | `i11.md` |
| conservation records | 12, **every delta zero** | `i02.md`, `01c-faults.jsonl` |

The two historical numeric assertions `v1-release.md` 01.04 requires preserved
are unchanged: `flusher_test.exs` still asserts `8` after the retry and `10`
after the later `+2`, and `flush_batch_concurrency_test.exs` still asserts `5`
across twelve deliveries.

### The failures in the five unscoped seed runs

Every failure in every one of the five runs belongs to **01e**, which is
editing `test/aurora_meter/credits_model_test.exs`,
`test/aurora_meter/credits_regressions_test.exs` and `test/regressions/seeds/`
in the same working tree while these ran. None is in a file 01c owns.

| Failure | Cause |
|---|---|
| `CorrectnessIndexTest / every test whose description starts with an invariant id is named in the index` | 01e's `CreditsModelTest` carries 24 `I10 `-prefixed tests that are not yet bullets in `docs/correctness.md`. The index parses every file under `test/` whether or not it is in the run set. 01e promotes them. |
| `CreditsRegressionsTest / replays i10-20260914T095318-20260914.exs` | a seed 01e captured at 09:53:18 and later deleted; it replays green, then `enoent` |
| `CreditsRegressionsTest / every saved seed file parses and names an invariant` | the same file, mid-deletion |

The index test's first two checks both pass throughout, which is the part that
concerns 01c: every bullet 01c wrote resolves to exactly one test, and no
`PLANNED` bullet resolves to a real one.

01e landed its bullets while the fifth seed was running, so seed 4242 and the
final seed-0 run are both fully green at **363 passed, 0 failures**, and that is
the current state of the core suite.

The scoped runs (`01c-scoped-seed-*.txt`) are the same five seeds with those
three files out of the run set, and are the record of 01c's own work: **321
passed at every seed**.

### `mix check` and `mix coverage`

`mix coverage` passes at **93.43%** against the measured floor of 90. The
baseline in `coverage.md` was 92.55%, so this unit's 24 tests moved it up by
0.88 of a point, well inside the two points that would oblige 01a to revisit the
floor.

`mix check` runs `format --check-formatted`, `compile --warnings-as-errors
--force`, `credo --strict`, `dialyzer`, `test` and `docs`. Format, compile,
credo (`971 mods/funs, found no issues`) and docs all pass. **Dialyzer fails
with exactly two errors, both in 01e's file** and neither in anything 01c
touched:

```
test/support/aurora_meter/test/ledger_commands.ex:103:41:unknown_type  Unknown type: StreamData.t/0.
test/support/aurora_meter/test/ledger_commands.ex:126:58:unknown_type  Unknown type: StreamData.t/0.
```

`stream_data` is `only: :test`, so its types are not in the PLT that `mix check`
builds. 01e owns the fix, which is either a PLT addition in `mix.exs`
`dialyzer.plt_add_apps` or dropping the `StreamData.t()` annotations. One earlier
credo finding did belong to 01c, two `Credo.Check.Design.AliasUsage` suggestions
on `AuroraMeter.Billing.Noop` and `AuroraMeter.Billing.Provider` in
`entitlements_test.exs`; both are fixed and credo is clean.

### Known limits of what was proved

- The cluster tests simulate peers on one VM through `Cluster.apply/3`. They do
  not exercise `Phoenix.PubSub`, a netsplit or a real rejoin; 11d owns that.
- I03's period-crossing case is partial until 02c, because `lib/` has no clock
  seam and this unit changes no `lib/` file.
- I02 is proved for the Ecto adapter on PostgreSQL, per batch, not per
  `track/4`.

## 5. Changes

No public API, configuration key, migration, telemetry event or PubSub message
changes. The only new module-level addition is
`AuroraMeter.Test.Kill.await_restart!/2` under `test/support/`, which `mix.exs`
`package.files` excludes from the Hex archive.

Documentation: `docs/correctness.md` gains every rename and addition plus three
known-limit paragraphs (C6 under I03, L18 under I10, L1 under I12) naming the
units that fix them. `docs/testing.md` gains two sections, "Killing a supervised
process" and "A non-sandbox module discards, it does not drain".

## 6. Open defects

### Proved here, fixed elsewhere

| Id | Defect | Reproduction | Severity | Invariant | Fixed by |
|---|---|---|---|---|---|
| **C6** | `Counter.commit_work/5` and `release_work/4` skip `ensure_seeded/1`, so both raise `ArgumentError` after a Store restart while a deferred `Counter.reserve/6` on the same cold key does not | `AuroraMeter.KillTest` / `I03 Counter.commit_work after a Store restart raises (C6, fixed in 03b)` | high: a `with_quota` whose callback outlives a Store crash fails at commit, after the work succeeded, with a message naming neither tenant nor feature | I03 | **03b** |
| **L1** | value a hold reserved on an already expired grant becomes ordinary spendable credit when released, and stays spendable until the next `expire_due/1` pass | `AuroraMeter.CreditsTest` / `I12 a release after the grant expired returns spendable credit (L1, fixed in 06a)` | medium: promotional credit outlives its expiry | I12 | **06a** |
| **L18** | `Credits.Ledger.transact_outcome/1` emits telemetry, PubSub and the low-balance handler when the inner transaction returns, which inside a host transaction is a savepoint release and not a commit | `AuroraMeter.CreditsConcurrencyTest` / `I10 a host transaction that rolls back undoes the ledger row although the side effects already fired (L18, fixed in 06c)` | medium: a handler can act on a balance that no reader will ever find | I10 | **06c** |

Each is a **passing** test that asserts current behaviour, carries the defect id
and the fixing unit in its description, and is listed under that invariant's
"Known limits" in `docs/correctness.md`. `v1-release.md` 1.1 requires the suite
to stay green and 1.2 requirement 6 forbids hiding a skipped test, so a failing
test was not an option.

**C8** (`Counter.restore_pending/2` is unreachable from `lib/`) is recorded and
not tested, as the build document directs; 02a marks it internal and 03b removes
it.

No test is skipped, excluded or tagged out by this unit.

### Two defects this unit introduced and fixed before recording anything

Both were found by running more than once, which is why they are written down
rather than quietly patched.

1. **`await_restart!/2` returned on registration, not readiness.**
   `:gen_server` registers a name before it calls `init/1`, and
   `AuroraMeter.Store` creates its five ETS tables inside `init/1`. The first
   version of `await_restart!/2` returned as soon as a different pid was
   registered, so `AuroraMeter.KillTest` failed intermittently with
   `:ets.lookup(:aurora_meter_flush_batches, :pending)` raising "the table
   identifier does not refer to an existing ETS table". It now blocks on a
   synchronous system call, which a `GenServer` does not answer until `init/1`
   has returned, and `AuroraMeter.Test.HarnessTest` has a self-test whose
   `Restartable` child creates a table in `init/1` for exactly this.

2. **A drain flush in a non-sandbox module poisoned the test database across
   runs.** `statements_test.exs`, `kill_test.exs` and
   `flush_batch_concurrency_test.exs` opened with `Flusher.flush/0` to clear
   earlier modules' pending deltas. On a real connection that **commits** them,
   under the `org_<n>` tenant keys a sandbox module owns and never cleans up.
   `System.unique_integer/1` starts again at the same values in the next
   `mix test`, so those rows seeded a later run's counters: seed 13 read
   `usage/2` as 38 where 10 had been tracked, and as 83 where 11 had been
   tracked. All three now call `AuroraMeter.Test.reset!/0`, which discards the
   buffer and touches no row. The already-committed rows were cleared by
   truncating every package table in `aurora_meter_test` inside the mixlane
   lock, so no other unit's run was executing at the time. The rule is now in
   `docs/testing.md`.

### New findings for `open-findings.md` (not edited by this unit)

| Proposed id | Finding | Owner |
|---|---|---|
| X36 | A non-sandbox test module that calls `Flusher.flush/0` commits whatever pending deltas a sandbox module left behind, permanently, under tenant keys nothing cleans up; `System.unique_integer/1` reuses those integers in the next `mix test`, so the rows poison a later run and it fails in a file that has nothing to do with them. Recorded in `docs/testing.md`. | 01c (resolved in 01c) |
| X37 | `tmp/v1/mixlane.sh` serialises Mix invocations against one `_build`, but it does not stop another unit editing the same repository's `test/support` mid-run. Six of this unit's recorded runs failed to compile on 01e's half-written `ledger_commands.ex`, and three of the five seed runs had to be retried. Concurrent units in one repository need either a lock that spans the edit or a worktree each. | wave coordination |
| X38 | Killing a `mix test` run that has non-sandbox modules in flight skips their `on_exit`, leaving committed rows for `concurrent_<n>`, `killt_<n>` and `stmt_<n>` tenants. Combined with X36's integer reuse, that is a second route to a poisoned database. A pre-run sweep, or a teardown that runs from a process outside the test, would close it. | 01f or a 00d follow-up |
| X39 | `AuroraMeter.Supervisor` is `one_for_one` with OTP's defaults, so the whole suite has a budget of three automatic restarts in five seconds. `AuroraMeter.KillTest` spends all three, and a fourth kill anywhere near it takes the supervisor down along with every test that follows. 03b and 05c both plan kill tests. | 03b, 05c |
| X40 | `docs/correctness.md` carried `PLANNED (01c): AuroraMeter.EntitlementsTest / test I20 every Noop billing provider callback returns :not_configured`, which is an I20 test and appears nowhere in 01c's build document. 01c wrote it, because the file it belongs in is 01c's, but the assignment should be reconciled between `01a` and `01c`'s documents. | 01a, 08b |
| X41 | 01c's build document asks for `docs/evidence/v1/phase-01/{i11,i12}.md` while `invariant-map.md` gives I11 one home at `phase-05/i11.md` and I12 one at `phase-06/i12.md`, and the index test enforces one path per invariant. Both phase-01 files exist as this unit's contribution and say so; 05b and 06a must link to them from the invariant's home file. | 05b, 06a |
| X42 | `mix check`'s dialyzer step cannot see `StreamData.t/0`, because `stream_data` is `only: :test` and is not in `dialyzer.plt_add_apps` (`mix.exs:225`, which lists `:ex_unit` and `:mix` only). Any test-support module that annotates a generator fails the gate. | 01e, then 01f if the PLT list is the fix |
| X43 | 01c's build document asks every test in `cluster_convergence_test.exs` to emit an `AuroraMeter.Test.Connections.report!/1` conservation record. That module is a `DataCase` and the sandbox rolls its rows back, so a before-and-after row count is zero by construction and the record would assert nothing while looking like rigour. The records come from `statements_test.exs` and `kill_test.exs`, which really commit; the deviation is deliberate. | 01c (recorded, not acted on) |

## 7. Handoff

**Where the work stopped.** Everything in 01c's build document is implemented
and green. The unscoped suite is red only on 01e's three in-flight files; that
clears when 01e promotes its `I10 ` bullets into `docs/correctness.md` and
settles `test/regressions/seeds/`.

**What to read.** This file, then the seven `i<nn>.md` files beside it, then
`docs/correctness.md` (the index is the contract, this is the measurement).
`docs/testing.md` carries the two conventions a later kill test needs.

**What must not change.**

- The numeric assertions in `AuroraMeter.FlusherTest` (`8`, then `10`) and in
  `AuroraMeter.FlushBatchConcurrencyTest` (`5`). They are the phase-17
  historical cases `v1-release.md` 01.04 requires preserved.
- `AuroraMeter.KillTest` stays `async: false`, and it stays at three kills.
- The three defect-documenting tests are inverted by 03b, 06a and 06c
  respectively, and by nobody else.

**Next verification target for the units that follow.** 03b flips
`I03 Counter.commit_work after a Store restart raises (C6, fixed in 03b)`: the
exact message it must stop producing is in `i03.md` section 4. 06a flips
`I12 a release after the grant expired returns spendable credit`. 06c flips
`I10 a host transaction that rolls back undoes the ledger row although the side
effects already fired`.
