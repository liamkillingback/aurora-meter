# 08c: the measured results

**This is the only artifact any claim about Aurora Meter's performance may
cite.** `README.md` links it, `docs/launch/gtm.md` links it, and
`AuroraMeter.Bench.ClaimsTest` fails if a document quotes a throughput figure
without it.

Build unit **08c**, V1 tasks **08.06**, **08.07** and **08.08**.

## 1. Tasks, repository and revision

- Tasks: 08.06 (the modes), 08.07 (the measurement record), 08.08 (the budgets).
- Repository: core `aurora_meter`, working tree at `34c188d`, **dirty** with
  08c's own changes. Every record carries `package.git_sha`
  (`34c188dbaa896562416aef21a4840872ba857e60`) and `package.git_dirty: true`.
- Storefront: `scripts/v1/bench.sh`, `scripts/v1/lib/bench.js`,
  `scripts/v1/budgets.json`, at `58a707b`.
- **Every figure on this page was produced by the code as it stands at
  hand-back.** The suite was measured once, then changed (the clock seam, the
  git reader, the peer supervisor), and then measured again from scratch. The
  second measurement is what is published; the first is not in this file.

## 2. Environment

Measured on **2026-09-16**. Not generalised to any other machine or toolchain
pair (decision D12).

| | |
|---|---|
| Machine | WSL Ubuntu 24.04.4 LTS, AMD Ryzen 9 7900X 12-Core, 24 logical CPUs, 19.5 GiB |
| Kernel | `unix/linux 6.6.87` |
| Runtime | Elixir 1.20.1, OTP 29, ERTS 17.0.1, 24 schedulers online |
| Database | PostgreSQL 16.13 (Debian), container `aurora-meter-pro-testdb`, `localhost:5490`, database `aurora_meter_bench`, pool 30 |
| Package | `aurora_meter` 0.5.0, core schema 10 |

**A WSL laptop is not a controlled environment, and on this run it was a busy
one**: the measurement ran after several hours of test suites and earlier bench
runs on the same machine. The run-to-run spread column is as much a part of each
result as the median, and on this run it is larger than on the first: `spread`
moved from 6.67 percent to 12.19 percent between two measurements of the same
code. Where the spread approaches or exceeds a budget threshold the budget is
not meaningful at that mode on this hardware, and `08c-budgets.md` says which
modes those are.

## 3. Commands and logs

```
bash scripts/v1/bench.sh baseline --tag v0.4.0 --out tmp/v1/bench/baseline-0.4.0 --runs 5
exit=0

bash scripts/v1/bench.sh run --modes all --runs 5 --out tmp/v1/bench/v1-rc1
exit=1   (ten of the ninety runs failed: flush_10k and flush_100k, five each, finding X338)

bash scripts/v1/bench.sh run --modes cluster_2,cluster_4 --runs 5 \
  --out tmp/v1/bench/cluster-gossip --extra "--broadcast-interval 25"
exit=1   (one of ten: cluster_2 run 4 exceeded its computed bound, finding X346)

bash scripts/v1/bench.sh run --modes db_recovery --runs 3 --out tmp/v1/bench/outage \
  --outage-seconds 20 --seconds-before-outage 15 --extra "--duration 60000 ..."
exit=0

bash scripts/v1/bench.sh compare --baseline tmp/v1/bench/baseline-0.4.0 \
  --candidate tmp/v1/bench/v1-rc1
exit=1   (one breach: spread, recorded in 08c-regressions.md)
```

Five runs per mode, **each in a fresh `mix` invocation**, so ETS and the
scheduler start cold every time. Warm-up runs the same workload and is discarded
from the clock but not from the state, and its own duration is recorded
separately.

Every raw record is under `runs/`:

| Directory | What |
|---|---|
| `runs/v1-rc1/` | five runs of every mode, `summary.json` and `run.meta` |
| `runs/baseline-0.4.0/` | the v0.4.0 baseline, its metadata and the C7 patch that made it possible |
| `runs/cluster-gossip/` | the same cluster modes at a 25 ms `broadcast_interval` |
| `runs/outage/` | the three real-outage runs and their container timelines |
| `runs/outage-control/` | the control that never drained (X338) |
| `runs/smoke/` | one tiny run of every mode, read by `AuroraMeter.Bench.ReportTest` |

## 4. Results

**Read the `Kind` column before the number.** *micro* isolates an in-memory path
with no database anywhere in it; *end-to-end* reaches Postgres through the real
adapter on every write. On this machine they differ by three orders of
magnitude.

| Mode | Kind | What it measures | Workload | Median throughput (ops/s) | Median p50 (us) | Median p95 (us) | Spread across 5 runs | correct |
|---|---|---|---|---|---|---|---|---|
| `spread` | micro | `Counter.incr/4`, one distinct key per worker | 8 x 500,000 = 4,000,000 ops | 3,418,407.02 | 1.93 | 3.38 | 12.19% | true |
| `hot` | micro | `Counter.incr/4`, every worker on one shared key | 8 x 500,000 = 4,000,000 ops | 70,513.24 | 119.86 | 198.72 | 10.01% | true |
| `reserve` | micro | `AuroraMeter.reserve/3`, two passes: admitted and denied | 8 x 50,000 = 400,000 ops | 266,216.16 | 26.19 | 43.84 | 13.1% | true |
| `with_quota` | micro | `AuroraMeter.with_quota/4` with a no-op callback | 8 x 50,000 = 400,000 ops | 423,658.21 | 16.36 | 27.14 | 4.63% | true |
| `cluster_2_sim` | micro | gossip apply cost in one VM (**not** a cluster result) | 8 x 500,000 = 4,000,000 ops | 480,621.02 | 15.15 | 28.91 | 6.85% | true |
| `record` | end-to-end | `AuroraMeter.record/4`, one durable event per call | 8 x 2,000 = 16,000 ops | 1,804.25 | 4,230.09 | 6,035.22 | 5.24% | true |
| `record_batch` | end-to-end | `AuroraMeter.record_batch/2` at 1, 10, 100 and 500 | 8 x 200 = 1,600 ops | 201.96 | 16,059.64 | 126,655.28 | 61.1% | true |
| `correct` | end-to-end | `AuroraMeter.correct/4` against pre-recorded originals | 8 x 1,000 = 8,000 ops | 1,217.64 | 6,534.75 | 7,603.65 | 30.64% | true |
| `replay` | end-to-end | `Events.Replay.run/1` over the seeded population | 8 x 500 = 20,000 ops | 51,223.83 | 77,618.5 | 82,741.25 | 15.11% | true |
| `credits_debit` | end-to-end | `Credits.debit/4` across distinct wallets (lots enabled) | 8 x 2,000 = 16,000 ops | 1,091.03 | 6,814.68 | 9,241.27 | 48.01% | true |
| `credits_hot_wallet` | end-to-end | the same debit against one shared wallet | 8 x 2,000 = 16,000 ops | 186.81 | 42,541.99 | 46,661.68 | 19.36% | true |
| `flush_1k` | end-to-end | one `Flusher.flush/0` with 1,000 dirty keys | 1,000 dirty keys x 5 rounds | 21,658.59 | 42,515.36 | 58,413.57 | 4.55% | true |
| `flush_10k` | end-to-end | one `Flusher.flush/0` with 10,000 dirty keys | 10,000 dirty keys x 5 rounds | 0 | 290,959.48 | 290,959.48 | n/a | **false** |
| `flush_100k` | end-to-end | one `Flusher.flush/0` with 100,000 dirty keys | 100,000 dirty keys x 5 rounds | 0 | 2,565,796.71 | 2,565,796.71 | n/a | **false** |
| `db_delay` | end-to-end | sustained load with a delay in front of every storage call | 8 procs x 20,000 ms over 2,000 keys, 50,000 us per storage call | 1,544,940.46 | null | null | 5.1% | true |
| `db_recovery` | end-to-end | sustained load, then the drain | 8 procs x 20,000 ms over 2,000 keys | 1,517,524.56 | null | null | 9.47% | true |
| `cluster_2` | end-to-end | two real nodes reserving against one hard limit | 2 nodes x 20,000 reservations, limit 10,000 | 196,500.18 | null | null | 41.32% | true |
| `cluster_4` | end-to-end | four real nodes reserving against one hard limit | 4 nodes x 20,000 reservations, limit 10,000 | 337,656.46 | null | null | 24% | true |

`null` in a latency column is not a missing number. Those four modes take no
per-operation timing sample, because their unit of work is not an operation in a
loop: a percentile over operations would have no referent. Every record says so
in its own `notes`, which is what criterion 6 asks of every `null` field.

### Against the pre-V1 baseline

| Comparison | v0.4.0 (baseline) | V1 (candidate) | Change |
|---|---|---|---|
| `spread` median throughput | 4,782,812 ops/s | 3,418,407 ops/s | **-28.53%** |
| `spread` range across 5 runs | 4,400,334 to 5,088,379 | 3,264,693 to 3,717,718 | |
| `spread` run-to-run spread | 13.52% | 12.19% | |

`spread` is the only mode with a pre-V1 reference: the 0.4.0 task has one shape.
See `08c-baseline.md`. The fall is a budget breach with a measured cause, in
`08c-regressions.md`. **Both spreads exceed the 10 percent threshold on this
run**, so the breach is believed on the size of the gap (more than twice the
noise) and on the cause being measured, not on the threshold alone.

### What this replaces, and in which direction

The two figures `README.md` carried until today are the ones in
`docs/evidence/phase-03/bench.md`, which is where they stay: they were measured
against the 0.3 four-column counter row that 0.4.0 replaced, by a task that has
crashed at its own summary line in every release since (`open-findings.md` C7).
They are named here by reference and not reproduced, because criterion 13 is
that those strings appear nowhere outside that file and an evidence page
explaining why a claim was retired is not an exception to it.

| Claim | Measured now | Against what the page used to carry |
|---|---|---|
| Spread keys | **3,418,407** increments/s | **38 percent lower** |
| One hot key | **70,513** increments/s | 33 percent higher |

The headline figure is published lower. That is the point of the exercise: a
figure that is lower and true is worth more than one that is higher and
unverifiable.

### Reading notes, per mode

- **`hot`** is contention, not aggregate throughput: eight workers on one ETS
  row, which `:ets.update_counter/3` serialises. It is a worst case and must
  never be quoted as a rate.
- **`reserve`** runs two passes per operation, one admitting and one crossing
  the hard limit halfway through each worker's run, so the denial branch is
  measured and not assumed. `limit_exceeded` is counted in `errors.by_tag`
  because it is the expected outcome of those calls, and the record's `notes`
  say so.
- **Five modes have a run-to-run spread above their own budget threshold**, and
  they are listed in `08c-budgets.md`. `record_batch` at 61.1 percent is the
  worst: it cycles batch sizes 1, 10, 100 and 500, so one run's mix of cheap and
  expensive calls differs from the next's by more than any threshold could
  distinguish. `credits_debit` at 48 percent, `cluster_2` at 41.3 percent and
  `correct` at 30.6 percent follow. These are recorded rather than smoothed
  away, and 11d's soak is where longer runs can make them mean something.
- **`db_delay` at 1,544,940/s against `db_recovery` at 1,517,525/s** is the
  correct result and is worth stating plainly: putting 50 ms in front of every
  storage callback changes the increment rate by nothing outside the noise,
  because the hot path never touches storage. What a slow database costs is
  flush latency and backlog, not throughput.
- **`credits_debit`** runs against a wallet with lots enabled, so it is the V1
  allocator and not the legacy wallet arithmetic. `workload.lots` is 1: the
  allocator reads and locks the whole book per write and its cost is bounded by
  that count (`open-findings.md` X248), so a figure taken on a one-lot wallet
  does not describe a wallet with a thousand. X248's shape is confirmed and its
  absolute figures are superseded: it measured 6,069 us p50 at one lot with
  Ecto's debug logging on, and this harness measures **6,814.68 us p50 /
  9,241.27 us p95** with logging off at eight concurrent workers.
- **`flush_10k` and `flush_100k` did not measure anything.** A flush of more than
  9,362 dirty counter keys cannot be sent to Postgres at all. See
  `08c-flush-limit.md` (finding X338). Criterion 4 ("every mode runs with tiny
  parameters and reports `correct: true`") is met by **sixteen of eighteen**
  modes, and the two exceptions are that defect rather than a gap in the suite.

## 5. Changes

- Core: `mix aurora_meter.bench <mode> [options]` replaces the positional task;
  the positional form still runs, as `spread`, with a deprecation notice, and is
  removed in 2.0. `AuroraMeter.Counter.warm/2` and
  `AuroraMeter.Clock.monotonic_native/0` are new and both `@doc false`.
  `AuroraMeter.Bench.*` (fifteen modules) and `priv/bench/report.schema.json`
  are new; the fifteen are in `docs/api.md`'s internal list, `mix.exs`'s Internal
  group and `api_inventory_test.exs`'s `@internal_modules`, which that test keeps
  equal. `mix bench.setup` and the `AURORA_BENCH=1` repo switch are new.
- Core documents: `README.md`'s throughput table and `docs/launch/gtm.md`'s two
  figures are replaced by V1 measurements linking this file;
  `docs/evidence/phase-03/bench.md` carries a header note marking it historical
  and its body is untouched.
- Storefront: `scripts/v1/bench.sh`, `scripts/v1/lib/bench.js`,
  `scripts/v1/budgets.json`, `scripts/v1/test/19-bench-budgets.sh`.
- No library function changed shape. No configuration key, behaviour, telemetry
  event, PubSub message, schema or migration was touched. `priv/bench/` is not
  in `package.files`: the schema is a test fixture and the tarball grows only by
  the bench modules.

## 6. Open defects

| Finding | What |
|---|---|
| **X338** | a flush of more than 9,362 dirty counter keys cannot be sent, and is retried for ever. `08c-flush-limit.md` |
| **X339** | the build document's claim that `hot` has a 0.4.0 baseline; the 0.4.0 task has no hot-key mode. `08c-baseline.md` |
| **X340** | this unit's own convergence reading was wrong and reported a correct cluster as unconverged. `08c-cluster.md` |
| **X341** | this unit's own overshoot bound was too tight and could not fail at the default interval. `08c-cluster.md` |
| **X342** | the hot-path regression: 28.53% against v0.4.0, cause measured. `08c-regressions.md` |
| **X343** | `AuroraMeter.Bench.*` is excluded from the coverage floor, and why |
| **X344** | a nested `mix` inside `mix test` destroyed 604 tests elsewhere in the suite |
| **X345** | the evidence-writes detector flagged a file that writes only to the temp directory |
| **X346** | the documented overshoot bound is tight, and one run in ten crossed it at a 25 ms interval. `08c-cluster.md` |

## 7. Handoff

Everything on this page is reproducible from the commands in section 3.

- To re-measure: `bash scripts/v1/bench.sh run --modes all --runs 5 --out <dir>`.
- To compare against a reference: `bash scripts/v1/bench.sh compare --baseline
  <dir> --candidate <dir>`, which exits non-zero on a breach.
- The budget rule in words: `08c-budgets.md`. Breaches: `08c-regressions.md`.

**Every mode except `spread` has as its reference its own first V1 measurement,
which is this page.** That is a real limitation and it is stated rather than
implied: a budget whose reference was taken by the same code it is policing can
only catch a later change. 11d's soak is the first run that compares against it,
and its first job should be to re-measure on a quiet machine: five of the
eighteen modes on this run are too noisy for their own thresholds, and it is not
yet known how much of that is the workload and how much is this laptop.
