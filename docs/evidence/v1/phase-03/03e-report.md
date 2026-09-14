# 03e: immutable corrections (`correct/4` and `replace/4`)

The seven items of `v1-release.md` 1.2.

## 1. Tasks, repository and source

| | |
|---|---|
| V1 task | **03.08**, build unit **03e** |
| Invariant owned | **I09** (contributors: I06, I07) |
| Gates | G03 bullets 1, 2, 3 and 6 as they apply to corrections; G04's late-correction bullet through 04d |
| Core repository | `product-workspaces/aurora_meter`, HEAD `b032aae672ce8b3e19ff4067e647e0b0e9364982` (`feat(v1): reporting source isolation, and the I08 proof`) |
| Core state | **dirty**, uncommitted. Tracked modifications sha256 `d7aadb3b5a578fdc86b673b665cb1db9d67d478ca09ad9a084ee1e866be03275`; the three new test files concatenated sha256 `59674c3adf82b9b47d234741eaeeaef0252fee61e6b8ac9b7541885c42718f00`; the eight new evidence files concatenated sha256 `dabd793e02652a5781ad5c89b324abb3e4f5e78de9045fb0c7f1550ea482abcf` |
| Pro repository | `product-workspaces/aurora_meter_pro`, HEAD `c8f10d0175ae89b9cc54aa55653c207b23ebf620` |
| Pro state | **dirty**, one test-support file. Patch sha256 `c43600f2d6c4149119266d7dcaa2a99c9005077d379e733c3180b395ee4e22af` |
| Storefront | branch `aurorameter-v1`, **dirty** in `docs/v1/build-plans/` only (`README.md` status and four `open-findings.md` rows). Patch sha256 `0c224d750334f74130f90871a97baa12c27060f2006e4d91dc3c62ca6509e240`. No storefront code change |

The checksums above are of the working tree at the moment this report was
written, reproducible with `bash tmp/v1/03e/checksums.sh`. **Nothing is
committed.** The owner reviews and commits.

## 2. Versions, toolchain and environment

| | |
|---|---|
| Core package | 0.5.0 |
| Pro package | 0.3.0 |
| Core schema version | 8 (unchanged; this unit adds **no** DDL) |
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts-17.0.1) |
| Operating system | Ubuntu 24.04.4 LTS on WSL2, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Database | PostgreSQL 16.13 (Debian 16.13-1.pgdg13+1), port 5490, `aurora_meter_test` |
| `mix.lock` sha256, core | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` |
| `mix.lock` sha256, Pro | `bd66012e64e0ce2cb97e5a9fdbee15c248277484a18f7176731e10649c6df424` |

## 3. Commands, exit codes, seeds, timestamps and logs

Every command, with its exit code, UTC timestamps and log path, is in
`03e-commands.txt`. The headline runs:

| Command | Exit | Result | Log |
|---|---|---|---|
| `mix test` (core, baseline before the unit) | 0 | 1011 passed, 3 excluded | `tmp/v1/03e/logs/baseline-core-test.log` |
| `mix check` (core, after) | 0 | **1084 passed** (42 doctests, 12 properties, 1030 tests), 3 excluded; Dialyzer 0 errors; Credo clean; docs `--warnings-as-errors` clean | `tmp/v1/03e/logs/03e-core-check.log` |
| `mix check` (Pro, PLT deleted first) | 0 | 420 passed (28 doctests, 392 tests); Dialyzer 0 new errors (1 pre-existing skip) | `tmp/v1/03e/logs/03e-pro-check.log` |
| `mix test test/aurora_meter/correct_concurrency_test.exs --seed N`, N in 0..9 | all 0 | 6 passed each | `tmp/v1/03e/logs/seeds/seed-N.log`, index `tmp/v1/03e/logs/seeds.csv` |
| the six mutation controls | see `03e-step-order.md` | each fails exactly the test that exists to catch it; the positive control passes | `tmp/v1/03e/logs/negative/` |

**Core test count: 1011 before, 1084 after (+73).**

## 4. Expected and actual results

### The cumulative bound, under contention

Ten seeds of `correct_concurrency_test.exs`, twelve independent non-sandbox
connections, per-task outcomes in `03e-bound.json` (20 lines, two tests times
ten seeds). Every line identical:

| Case | Expected | Actual |
|---|---|---|
| 12 correctors of a 10-unit original, 1 unit each | 10 inserted, 2 `exceeds_original`, 10 correction rows, totals `quantity: 0, events: 11`, 10 outbox items | exactly that, all ten seeds |
| 12 submissions of one correction identity, 10 units | 1 inserted, 11 duplicate, 1 correction row, totals `quantity: 0, events: 2`, 1 outbox item | exactly that, all ten seeds |

### Reconciliation

`AuroraMeter.CorrectTest` / `test replay arithmetic I09 recomputing every total
from the event rows reproduces the projection exactly` records 100 events and 40
corrections across three periods, recomputes each key's total from the rows with
L-03e-3's rule (`usage - corrections`, count of rows of both kinds) and asserts
it equals what the live path projected, for all three keys, and that
`Events.total/3` agrees. This is the comparison 03d's replay will make; the
replay itself is 03d's.

### Acceptance criteria

| Criterion | Met | Evidence |
|---|---|---|
| Twelve concurrent corrections of one 10-unit original on twelve independent connections produce exactly ten correction rows, ten outbox items, a totals quantity of 0, an event count of 11 and exactly two `exceeds_original` | yes | `03e-bound.json`, ten seeds, every line identical |
| A full reversal followed by any further correction is rejected, and the same call repeated with the same id returns `:duplicate` rather than an error | yes | `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a full reversal then a further correction is rejected` and `... even when the original is already fully corrected` |
| Twelve concurrent submissions of one correction identity produce one row, one totals delta and one outbox item | yes | `03e-bound.json`; 1 inserted, 11 duplicate, every seed |
| A correction inherits the original's feature, period start, period source, plan id and plan version, verified for an original in a previous period | yes | `AuroraMeter.CorrectTest` / `test what a correction inherits L-03e-2 ...`, which also asserts the previous period's totals row moved and the current one does not exist |
| A correction to a correction is rejected | yes | `AuroraMeter.CorrectTest` / `test identity I09 a correction to a correction is rejected` |
| A correction refused for exceeding the bound leaves a wrapping host transaction able to commit | yes | `AuroraMeter.CorrectTest` / `test inside a host transaction I09 a refusal does not roll back the host's transaction` |
| A correction of a buffered feature's event and a correction of an unattributed original are both stored and both produce an outbox item carrying an explicit reason; neither is dropped and neither is marked accepted | yes | `03e-eligibility.md` and the two named tests |
| `replace/4` writes exactly two events and two ordered outbox items in one transaction, is idempotent under one caller id, and rolls both back when the replacement fails | yes | `03e-replace.md`; `AuroraMeter.ReplaceTest`, 18 tests |
| A replay of a history containing corrections reproduces byte-identical totals and event counts | **partially**, see below | `AuroraMeter.CorrectTest` / `test replay arithmetic I09 recomputing every total from the event rows reproduces the projection exactly` |
| The ETS projection never shows a negative value for a corrected key | yes | two tests under `test the in-memory projection`, with the `no_floor` negative control |
| `AuroraMeter.StorageCase` passes the correction section for `Storage.Ecto` and returns `{:error, {:unsupported, :corrections}}` for a capability-less fake | yes | `AuroraMeter.StorageCaseEctoTest` (six new correction assertions) and `AuroraMeter.StorageCaseIncapableTest`, both inside the 1084 |
| `mix check` passes with no new Dialyzer or Credo finding | yes | core exit 0, Dialyzer `Total errors: 0`; Pro exit 0 with its PLT deleted first |

**On the replay criterion.** `AuroraMeter.Events.Replay` does not exist yet: it
is 03d's, and `execution-waves.md` orders 03e before it. What this unit can
prove, and does, is the **arithmetic** a replay has to reproduce: 100 events and
40 corrections across three keys, each key's total recomputed from the rows with
L-03e-3's rule and asserted equal to what the live path projected, and equal to
`Events.total/3`. Running an actual replay over that history is named in the
handoff as 03d's, which its own document already requires ("It must pass in both
units' suites").

### Known limitations

In `i09.md` under "Known limits", and repeated in `docs/correctness.md`. The
short list: the provider window is Pro's (04d); corrections of corrections are
not supported in 1.0; the in-memory view is advisory; the legacy negative
`track/4` is still unbounded for buffered features (10c).

## 5. Changes to public APIs, configuration, migrations, telemetry, docs

**Public API, additive.**

| Change | Class |
|---|---|
| `AuroraMeter.correct/4` | additive |
| `AuroraMeter.replace/4` | additive |
| `AuroraMeter.Storage.record_correction/2` callback and dispatcher | **breaking for custom adapters**, with the other six from 03b; `capabilities/0` must declare `:corrections` |
| `AuroraMeter.StorageCase.correction/4` | additive |
| `t:AuroraMeter.Storage.correction_entry/0` | additive |
| New `{:invalid, _}` reasons: `original: :is_correction`, `original: :missing \| :not_a_binary \| :empty \| :too_long`, `quantity: :exceeds_original`, `quantity: :already_fully_corrected`, `dimensions: :not_supported_on_correction`, `occurred_at: :not_supported_on_correction`, `feature: :differs_from_original`, `id: :too_long_for_replacement` | additive |
| New error `{:error, {:not_found, :original}}` | additive |
| New outbox ineligibility `:original_ineligible` | additive |
| `AuroraMeter.Events.Canonical.validate_correction/1` and `correction_hash/3` | internal module |
| `AuroraMeter.Counter.apply_projection/2` accepts a negative delta | internal module |

**Configuration.** None. No new key.

**Migrations.** **None.** This unit writes no DDL; it uses 03a's `kind`,
`original_event_id`, pairing check constraint and corrections partial index.

**Telemetry.** No new event. `[:aurora_meter, :record]` carries
`kind: :correction`, so 08a's preset covers corrections automatically. A
`replace/4` is one span with `batch_size: 2`.

**PubSub.** The same `{:aurora_meter, :event, ...}` message with
`kind: :correction` and the **positive** magnitude.

**Docs.** `docs/api.md` (three rows plus the types paragraph),
`docs/metering.md` (a correction section), `docs/examples/events-source.md` (the
recipe, compiled by `examples_test.exs`), `docs/telemetry.md`,
`docs/storage-adapters.md` (the `record_correction/2` contract) and
`docs/correctness.md` (I09 rewritten, I06 and I07 extended).

**Operational procedures.** None changed. An operator correcting one large
original in many small steps serialises on that one row, which is correct and is
documented in `docs/metering.md`.

## 6. Open defects and findings

None in the shipped code. Four findings for `open-findings.md`, each with
evidence:

1. **The build document's step order is incomplete under concurrency.** It puts
   the duplicate check before the lock and none after it, which tells a
   concurrent retry of one correction identity `exceeds_original` for a
   correction that is its own. A step 3b was added. Evidence:
   `03e-step-order.md` "Wrong ordering 1b", negative control `no_recheck`.
   Severity: high, financial, **fixed in this unit**.
2. **A CHECK constraint applies to the tuple an `ON CONFLICT DO UPDATE`
   proposes.** The build document assumed it applied to the resulting row, and
   the correction's totals delta cannot use the upsert `record_events/2` uses.
   Measured on PostgreSQL 16.13. Evidence: `03e-totals-check.md`. Severity:
   high, **fixed in this unit**.
3. **A concurrency test was satisfied by a serialisation point it did not mean
   to test.** With the `FOR UPDATE` removed, 03a's totals check constraint
   enforced I09 instead, producing the same counts and the same error tuple, so
   the bound test passed on code with no lock. Evidence: `03e-step-order.md`
   "The half of this that is worth reading twice". Severity: medium, **fixed in
   this unit** by a log assertion naming the constraint plus a paired
   widened-window control.
4. **X109 reproduced, in this unit's own suite.** The correction concurrency
   file failed once at seed 7 with a totals row holding `quantity: 13,
   events: 6` where it expected `6` and `2`. That is exactly a previous run's
   rows plus this run's, because `System.unique_integer/1` restarts from small
   values in every BEAM and an interruption test cannot guarantee its own
   teardown. A prefix sweep now runs at suite start. Severity: medium, **fixed
   in this unit**; the sweep covers the nine non-sandbox prefixes in the suite,
   not only this unit's.

No test is skipped, excluded or tagged out by this unit. The three excluded
tests in every run are the pre-existing `:headless` ones.

**One verification command in the build document does not exist.** It asks for

```
scripts/v1/faults.sh --repo core --seed 3 --point before_commit \
  --point after_commit_before_ack --suite corrections
```

That runner has no `--suite` flag (it takes `--point`, `--seed`, `--repo`,
`--only` and `--repeat`), and it selects by a `fault:<point>` tag that **no test
in either repository carries**, which the script itself anticipates: "if this
fails with no report, no suite is tagged fault:$point yet (build unit 01b)". The
same was true when 03b wrote its kill tests. What actually runs the two kill
cases is the `:fault` moduletag and the `mix v1.faults` alias, which CI runs as
its own job:

```
2026-09-14T20:09Z  exit=0  mix v1.faults (core)
  Running ExUnit with seed: 0, max_cases: 48
  Including tags: [:fault]
  Result: 82 passed, 1004 excluded
  log: tmp/v1/03e/logs/03e-faults.log
```

Retagging every fault suite with a point is a change to 01b's harness and to
every module that uses it, so it is recorded here rather than done inside a
financial unit. Severity: low, **not fixed**, affects the conservation runner's
coverage rather than any invariant.

## 7. Handoff

**What a fresh agent needs to know.**

- The unit's contract lives in three places, in this order: the module docs on
  `AuroraMeter.correct/4` and `replace/4`, the seven-step comment above
  `correction_transaction/1` in `lib/aurora_meter/storage/ecto.ex`, and
  `docs/storage-adapters.md`'s `record_correction/2` section. The comment is the
  authoritative one for the order.
- **Do not "simplify" the two duplicate checks into one.** `03e-step-order.md`
  names each wrong ordering, the observed failure and the test that catches it,
  and the mutation harness that produced them is `tmp/v1/03e/mutate.py` plus
  `tmp/v1/03e/negative-controls.sh`, runnable as-is.
- The correction path is deliberately separate from the record path inside the
  adapter: `apply_correction_totals/2` and `enqueue_corrections/2` duplicate a
  little of `apply_totals/4` and `enqueue/4` so that every function
  `record_events/2` reaches is byte-identical to HEAD. That is proven, not
  claimed: `tmp/v1/03e/hotpath.py`, output
  `tmp/v1/03e/logs/03e-hotpath.json`, and the tool itself is proven by
  `hotpath.py --selftest`.
- **03d** consumes this unit's arithmetic. Two things are waiting for it: the
  building-generation note on `apply_correction_totals/2` (a correction's
  negative delta landing on a zero row the scan has not yet filled), and the
  reconciliation test named above, which is the small deterministic version of
  its own large one.
- **04d** owns the provider half of I09. `03e-eligibility.md` states the
  contract core meets, and `docs/correctness.md`'s I09 section carries a prose
  handoff paragraph instead of a planned bullet, because a bullet naming a Pro
  module could never be promoted in core (`open-findings.md` X120).
- **10c** rewrites the storefront guides that currently teach corrections as a
  negative `track/4`.

**Reproducing the evidence.**

```bash
bash tmp/v1/03e/seeds.sh              # the ten concurrency seeds and 03e-bound.json
bash tmp/v1/03e/negative-controls.sh  # the six mutation controls
python3 tmp/v1/03e/hotpath.py         # the unchanged-symbol comparison
python3 tmp/v1/03e/hotpath.py --selftest
bash tmp/v1/03e/check.sh              # core mix check
bash tmp/v1/03e/pro.sh                # Pro mix check, PLT deleted first
```
