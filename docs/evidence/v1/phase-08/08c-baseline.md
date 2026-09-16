# 08c: the pre-V1 baseline

Build unit **08c**, V1 task **08.08** ("establish same-machine baseline before
feature edits where possible").

## 1. Tasks, repository and revision

- Task: 08.08, the baseline half.
- Repository: core `aurora_meter`, working tree at `34c188d`, **dirty** with
  08c's own changes. The baseline itself is taken from a clone at the `v0.4.0`
  tag and touches the working tree not at all.
- Runner: `scripts/v1/bench.sh baseline --tag v0.4.0 --out tmp/v1/bench/baseline-0.4.0 --runs 5`

## 2. Environment

| | |
|---|---|
| Machine | WSL Ubuntu 24.04.4, AMD Ryzen 9 7900X, 24 logical CPUs, 19.5 GiB |
| Kernel | `unix/linux 6.6.87` |
| Runtime | Elixir 1.20.1, OTP 29, ERTS 17.0.1, 24 schedulers online |
| Database | none: `spread` is a micro mode and opens no connection |
| Package under test | `aurora_meter` at tag `v0.4.0`, in a clone |

## 3. Commands and logs

```
bash scripts/v1/bench.sh baseline --tag v0.4.0 --out tmp/v1/bench/baseline-0.4.0 --runs 5
exit=0
```

Raw records and the applied patch: `runs/baseline-0.4.0/`.

The procedure, exactly:

1. `git clone --no-hardlinks <core> <out>/clone`, then `git checkout v0.4.0` in
   the clone. The working repository is never mutated: no worktree is created in
   it, no branch is touched, and nothing is checked out inside it.
2. **One** change is applied to the clone, and it is stored as
   `runs/baseline-0.4.0/c7.patch`:

   ```diff
   -        do: :ets.insert(Store.counters_table(), {{tenant(i), @feature, @period}, 0, 0, 0})
   +        do: :ets.insert(Store.counters_table(), {{tenant(i), @feature, @period}, 0, 0, 0, 0, 0})
   ```

   Without it there is no v0.4.0 figure at all. The 0.4.0 task seeds a four
   element counter row and `Counter.read/1` matches a six element one, so the
   task performs every increment and then raises `MatchError` printing the
   result (`open-findings.md` C7). The anchor is asserted to occur **exactly
   once** before anything is written, and the patch is asserted to have applied
   after, so a silently-failed patch cannot become a silently-different
   baseline (`open-findings.md` X326, X300).
3. `mix deps.get` in the clone, then five runs of `mix aurora_meter.bench 8 500000`.
4. `git status --porcelain | wc -l` in the working repository before and after.
   Both read **25**. The runner fails the baseline if they differ.

The 0.4.0 task prints a paragraph and writes no JSON, so each run's figure is
parsed out of its own output and re-recorded in this suite's record shape, with
the raw log kept beside it. Every field 0.4.0 did not measure is `null`, not
zero: it measured no latency at all, only an aggregate elapsed time and a
derived rate.

## 4. Results

| | |
|---|---|
| Mode | `spread` (micro) |
| Workload | 8 processes x 500,000 increments = 4,000,000 |
| Runs | 5 |
| **Median throughput** | **4,782,812 increments/s** |
| Range across the five runs | 4,400,334 to 5,088,379 |
| Run-to-run spread | 13.52% |
| `correct` | true on all five |

### The modes with no pre-V1 baseline, and why

**`spread` is the only one.** The build document says "`spread` and `hot` ... are
the only two modes that exist at 0.4.0", and reading
`git show v0.4.0:lib/mix/tasks/aurora_meter.bench.ex` shows that is not so: the
0.4.0 task has **one** shape, a distinct key per worker, and no hot-key mode at
all. The historical hot-key figure in `docs/evidence/phase-03/bench.md` has no
run block beside it, which is consistent with its never having been produced by
a task. Recorded as finding **X339**.

Every other mode measures something that does not exist at 0.4.0 (`reserve` and
`with_quota` exist as APIs but not as bench modes; the durable, ledger, flush,
fault and cluster modes measure code that landed in phases 03 to 07), so its
reference is **its own first V1 measurement**, recorded in `08c-results.md`. That
is stated here rather than papered over: a budget against a reference that was
taken by the same code it is meant to police can only catch a **later** change.

### The run-to-run spread EXCEEDS the budget, and that matters more

The baseline's five runs span **13.52%** and the candidate's span **12.19%**,
against a hot-path budget of 10%. On this machine, in the state it was in for
this run, two runs of the same code can differ by more than the threshold. The
same baseline measured earlier the same afternoon spanned 7.68% and its median
was 4,933,320 rather than 4,782,812: a 3% difference between two measurements of
**identical code at the same tag**, an hour apart.

So the budget is applied to the **median of five**, every comparison carries both
spreads beside both medians, and a breach whose size is inside the noise is a
reason to re-measure rather than to act. The breach recorded in
`08c-regressions.md` survives that test on two counts: it is **28.53%**, more
than twice the spread, and its cause is measured to the nanosecond rather than
inferred. A 12% fall on this machine would not have been believable, and saying
so is part of the result.

## 5. Changes

None to any package. The baseline reads; it does not write.

## 6. Open defects

- **X339**: the build document's claim that `hot` has a 0.4.0 baseline. The
  0.4.0 task has no hot-key mode. Corrected here; `hot`'s reference is its own
  first V1 measurement.

## 7. Handoff

To re-take the baseline, run the one command at the top of section 3. It is
repeatable: the clone is rebuilt from scratch each time and the patch is
re-asserted against its anchor. To compare a later candidate against it:

```
bash scripts/v1/bench.sh compare \
  --baseline tmp/v1/bench/baseline-0.4.0 --candidate <dir>
```
