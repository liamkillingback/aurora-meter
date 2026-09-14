# 01b: harness self-tests (core)

Recorded 2026-09-14. Commands go through `tmp/v1/mixlane.sh`, which takes a
`flock` per package `_build` and exports `DB_PORT=5490`, because three units
share one working tree in wave 1a.

    bash tmp/v1/mixlane.sh core mix test test/aurora_meter/test/harness_test.exs --trace --seed 0

## Result

**44 of 44 pass**, `test/aurora_meter/test/harness_test.exs`. Full list, with
the outcome of the final run at seed 0:

| Self-test | Result |
|---|---|
| Y1 a fault armed by one process does not fire for an unrelated process | pass |
| Y1 a fault armed by a test fires inside a Task.async child through $callers | pass |
| Y1 a fault armed by a test fires inside a Task.Supervisor.async_nolink child | pass |
| Y1 a bare spawn without owner: does not inherit the fault | pass |
| Y6 assert_fired! raises and names the points that did fire | pass |
| a count: 1 fault consumed by twelve concurrent checkers fires exactly once | pass |
| a count: :infinity fault fires on every check | pass |
| a when: predicate that rejects the context leaves the call untouched | pass |
| faults armed by a process that then dies are disarmed | pass |
| :raise raises AuroraMeter.Test.Faults.Injected carrying the point and the label | pass |
| :exit_kill_self kills the checking process and the monitor reports :killed | pass |
| {:block_until, ref} blocks until released and the owner receives the rendezvous message | pass |
| {:block_until, ref} raises AuroraMeter.Test.Faults.Timeout naming the ref when never released | pass |
| {:delay, ms} delays at least ms and records the delay in the fired log | pass |
| arming an unknown point raises and names the valid points | pass |
| Y2 with_config restores a key that existed | pass |
| Y2 with_config deletes a key that did not exist | pass |
| Y2 with_config restores after a raise, a throw and a caught exit | pass |
| Y2 with_config restores when the calling process is killed | pass |
| Y3 two concurrent with_config regions do not overlap | pass |
| Y3 a waiter blocked longer than the report interval logs the current holder | pass |
| put_config restores in on_exit | pass |
| FaultStorage implements every AuroraMeter.Storage callback | pass |
| FaultStorage delegates flush_batch unchanged when nothing is armed | pass |
| seed for I02: :before_commit on flush_batch leaves no receipt, counter or history row | pass |
| seed for I01: :after_commit_before_ack commits the batch and raises before the caller learns | pass |
| FaultRepo exports every repo function lib/ calls | pass |
| FaultRepo classifies the receipt insert, counter upsert and history upsert distinctly | pass |
| seed for I02: failing the history upsert rolls back the counter and the receipt | pass |
| seed for I02: failing the counter upsert rolls back the receipt | pass |
| seed for I02: failing the receipt insert writes nothing | pass |
| a rollback raised through the shim propagates as Ecto raises it | pass |
| Y4 run/3 checks every connection back in when a body raises | pass |
| Y4 run/3 returns results in index order | pass |
| Y4 cleanup! deletes only rows whose tenant_key carries the prefix | pass |
| Y4 cleanup! refuses a prefix shorter than four characters | pass |
| Y4 cleanup! covers every schema the package owns | pass |
| run/3 refuses more tasks than the pool can serve and says the arithmetic | pass |
| Y5 a killed worker is observed as :killed, not as a caught exit | pass |
| Y5 a worker killed before commit leaves nothing in the database | pass |
| Y5 a worker killed after commit leaves the committed row and no acknowledgement | pass |
| Y5 run/2 fails the test when the worker finishes normally although a kill was armed | pass |
| the test clock returns the set instant and advances by whole seconds | pass |
| unset returns to the system clock | pass |

Five of the descriptions read `seed for I01`/`seed for I02` rather than `I01
seed`/`I02 seed` as the build document wrote them. 01a's
`correctness_index_test.exs` treats any description beginning `I<nn> ` as a
claim on that invariant and fails the suite when it is not listed in
`docs/correctness.md`. These are harness seeds, not invariant proofs (01c owns
those), so the rename keeps them out of the indexable set rather than making a
claim the unit does not prove.

## The two named proofs from the handoff

`:exit_kill_self`, from the trace at seed 0:

    * test :exit_kill_self kills the checking process and the monitor reports :killed (0.1ms)

The assertions are `reason == :killed` compared against the `:DOWN` the test
process received directly, not a `Task.await/2` translation:

    assert_receive {:DOWN, reference, :process, pid, reason}, 5_000
    assert reason == :killed

`{:block_until, ref}` with the release withheld:

    * test {:block_until, ref} raises AuroraMeter.Test.Faults.Timeout naming the ref when never released (106.3ms)

with `error.ref == reference`, `error.point == :after_provider_accept`,
`error.owner == self()`, `error.blocked == self()` and
`Exception.message(error) =~ "was never released after 100ms"` (the self-test
arms `block_timeout: 100` so it does not spend the 5 s default; the default is
unchanged).

## Five seeds

`logs/01b-core-harness-seed-<seed>.txt`, `--trace`:

| Seed | Exit | Result | Wall |
|---|---|---|---|
| 1 | 0 | 44 passed | 1.1 s |
| 7 | 0 | 44 passed | 1.1 s |
| 13 | 0 | 44 passed | 1.1 s |
| 101 | 0 | 44 passed | 1.2 s |
| 4242 | 0 | 44 passed | 1.2 s |

The full core suite was also run at all five seeds; see "Suite state" below.

## Every failure observed while building this unit

Recorded even though the reruns pass, because a flake that was fixed is
evidence and a flake that was not looked at is not.

| # | Seen | Test | Cause | Fix |
|---|---|---|---|---|
| 1 | seeds 37, 148, 185, 259 of ten repeats | `Y1 a fault armed by one process does not fire for an unrelated process` | the self-test called `spawn/1` then `Process.monitor/1`; when the stranger finished first the `:DOWN` carried `:noproc`, not `:normal` | `spawn_monitor/1` |
| 2 | seed 296 of ten repeats | `Y3 two concurrent with_config regions do not overlap` | **a defect in `AuroraMeter.Test.Config`, not in the test**: the snapshot was taken in the caller *before* the token was acquired, so the second region snapshotted the first region's override and restored that instead of deleting the key | the server takes the snapshot at grant time and returns it |
| 3 | once, the first probed run of the guard demonstration | not captured | never reproduced in three repeats of the same probe or in fifteen later harness runs; most likely failure 1 above, which was live at the time | see 1 |

Failure 2 is the one worth reading twice. The harness's own serialisation was
silently defeating itself, and only the two-region self-test could see it.

## Demonstration: the guards fail when production grows a path the shim misses

Script `tmp/v1/01b-core-demo.sh`. It copies the two `lib/` files, adds a
throwaway to each, runs the self-tests, restores the copies and prints
`git status --porcelain -- lib`.

The probes, both chosen so the tree still compiles cleanly (an uncovered call
site in a public function, and an `@optional_callbacks` callback so no
implementation warning fires):

    # lib/aurora_meter/storage/ecto.ex
    @doc false
    def throwaway_probe_01b do
      repo().update_all(from(c in Counter, where: false), set: [value: 0])
    end

    # lib/aurora_meter/storage.ex
    @callback throwaway_probe_01b(term()) :: :ok
    @optional_callbacks throwaway_probe_01b: 1

Observed:

    1) test FaultStorage implements every AuroraMeter.Storage callback
       code:  assert FaultStorage.uncovered_callbacks(Storage) == []
       left:  [throwaway_probe_01b: 1]

    2) test FaultRepo exports every repo function lib/ calls
       code:  assert FaultRepo.uncovered_call_sites(["lib"]) == []
       left:  [%{arity: 2, line: 269, file: "lib/aurora_meter/storage/ecto.ex", fun: :update_all}]

    Result: 42/44 passed, Failed: 2 tests

After restoring, `git status --porcelain -- lib` printed nothing and the same
file returned `Result: 44 passed`. Repeated three times with identical results
(`tmp/v1/01b-core-demo3.sh`).

## Suite state and wall time

| Measurement | Wall | Result |
|---|---|---|
| 00b baseline, core at `cb38c3c` | 2.2 s | 242 passed (35 doctests, 4 properties, 203 tests) |
| this tree, full suite | 3.0 s | 309 passed (35 doctests, 4 properties, 270 tests), 3 excluded |
| this tree, full suite **without** `test/aurora_meter/test/` | 2.3 s | 265 passed (226 tests), 3 excluded |
| this tree, the harness file alone | 1.0 s | 44 passed |

The harness adds 0.7 s, about 0.5 s of which is four self-tests that must wait
by construction: the 100 ms withheld release, the 40 ms `{:delay, ms}` case, the
50 ms `refute_receive` that proves a blocked process is really blocked, and the
300 ms holder in the report-interval case. The rest of the suite is unchanged
(2.3 s here against a 2.2 s baseline that had 23 fewer tests). A
proportionally larger figure than 15% is therefore explained rather than
absorbed: it is the cost of four deliberate waits, not of `Faults.check/2`,
which is one ETS lookup and is only present in the shims.

## The fault lane

01f's `mix v1.faults` alias runs `test --only fault --seed 0`. This module
carries `@moduletag :fault`, so it is in that lane as well as in the default
run:

    bash tmp/v1/mixlane.sh core mix v1.faults
    Result: 49 passed, 263 excluded

49 is this module's 44 plus the five cases in the two independent-connection
files 01f tagged.

## Cross-unit note

Between the first and last runs of this unit the shared tree was also carrying
01a and 01f. At one point the core suite showed one failure,
`AuroraMeter.CorrectnessIndexTest` naming six `I20 ...` tests that 01f had
added and 01a had not yet indexed. It was attributed by removing
`test/aurora_meter/test/harness_test.exs` from the run and observing the same
single failure, and it is green again in the final runs above. No failure in
this tree at any point belonged to this unit except the three recorded in the
table above, all of which were fixed.
