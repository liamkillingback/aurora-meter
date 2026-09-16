# 08c: why the suite fell over once, and what the fourth restart was

Finding **X347**. The orchestrator's verification run of `mix check` failed
**exit 2, 1313 of 2007 passed**: 694 tests down, 577 `ArgumentError`, 59
`RuntimeError`, 22 `DBConnection.ConnectionError`, the first failure in
`AuroraMeter.KillTest` with `AuroraMeter.Supervisor` reported `:noproc`. The same
seed passed on a re-run, and so did `mix check`.

This page is the mechanism, forced deterministically with its controls, and the
before and after measured. It is not "it passed on a re-run": that answer has
been wrong five times in this programme (X241, X260, X264, X284, X238).

**There were two suppliers of the fourth restart, not one.** The first was found
and fixed, and a run count afterwards still produced a dead tree. The second is
in the test suite and is the one that reproduces on demand. Both are recorded
below in the order they were found, because the first fix being necessary and
not sufficient is the most useful thing on this page.

## 1. Tasks, repository and revision

- Build unit 08c, closing the orchestrator's verification failure.
- Core working tree at `34c188d`, dirty with 08c's changes.
- Probes: `tmp/v1/08c-supervisor-probe.exs`, `tmp/v1/08c-timer-probe.exs`,
  `tmp/v1/08c-fourth-kill-both.sh` (with `08c-fourth-kill.sh` and
  `08c-revert-gauge.py`), `tmp/v1/08c-guard-proof.sh`.
- Counters: `tmp/v1/08c-runcount-after.sh`, `tmp/v1/08c-recount-before.sh`,
  `tmp/v1/08c-final-gates.sh`. All of them keep every line of every run.

## 2. Environment

| | |
|---|---|
| Machine | WSL Ubuntu 24.04.4, AMD Ryzen 9 7900X, 24 logical CPUs |
| Runtime | Elixir 1.20.1, OTP 29, ERTS 17.0.1 |
| Suite duration | about 260 seconds |
| Intervals before | `flush_interval` 3,600,000, **`broadcast_interval` 60,000**, `metrics_interval` 0 |

## 3. The invariant that was being broken

`AuroraMeter.Supervisor` is `one_for_one` with OTP's defaults: **three automatic
restarts in five seconds, and the fourth takes the supervisor down**, and with it
every ETS table its children own and therefore every test that runs afterwards.
That is the 577 `ArgumentError`s: they are all "the table identifier does not
refer to an existing ETS table".

`AuroraMeter.KillTest` spends all three, by design, and says so:

> This module consumes the whole of `AuroraMeter.Supervisor`'s restart budget.
> The supervisor is `one_for_one` with OTP's defaults, three restarts in five
> seconds, and the three tests below kill a supervised child once each. A fourth
> automatic restart inside the same five seconds would take the supervisor down
> and every later test with it.

So the suite runs the budget at **zero margin**. The question was never whether a
fourth restart is fatal; the module states that it is. The question is what
supplies one, and the answer turned out to be two different things.

## 4. Supplier one (X347): the periodic broadcast tick

**`AuroraMeter.Broadcaster`'s periodic tick has no rescue.**
`handle_info(:broadcast, state)` calls `do_broadcast/0`, whose first expression
is `AuroraMeter.Counter.touched_keys/0`, which is `:ets.tab2list/1` on a table
`AuroraMeter.Store` owns. When the Store is dead the table is gone and the call
raises `:badarg`. `AuroraMeter.Flusher.do_flush/1` has both a `rescue` and a
`catch` for exactly this; the Broadcaster has neither.

**`broadcast_interval` was 60,000 ms in the test environment**, against a 260
second suite: four ticks per run, at arbitrary points. A tick that lands between
a Store kill and its restart is a fourth restart.

### Forced deterministically, with the controls

```
AURORA_BENCH=1 MIX_ENV=test DB_PORT=5490 \
  elixir -S mix run --no-start tmp/v1/08c-supervisor-probe.exs
exit=0   failures: 0        duration 10 s
```

The supervisor is **suspended** for the length of each window, so the tick lands
with the tables genuinely absent rather than by winning a race.

```
== Part A: a broadcast tick with the Store dead is an unhandled raise
  PASS  the counters table is gone with the Store
  broadcaster exit reason               :badarg
  PASS  a tick with no tables kills the Broadcaster on the ETS read
  PASS  and the first frame is AuroraMeter.Counter.touched_keys/0

== Part B: the fourth restart inside five seconds takes the tree down
  three kills                           [:ok, :ok, :ok]
  PASS  the tree survives three restarts in five seconds
  fourth kill                           :not_restarted
  PASS  the FOURTH restart inside the same five seconds kills AuroraMeter.Supervisor

== Part B control: the same four kills, spaced past the window
  PASS  four kills spaced 2.1 s apart leave the tree standing

== Part C: three kills plus ONE broadcast tick in the window is fatal
  PASS  the tree is still up after KillTest's three kills
  PASS  three deliberate kills plus one badly timed tick kills AuroraMeter.Supervisor
```

**Part B's control is what makes Part B mean anything.** Without it the evidence
would read as "four kills are fatal", which is neither what OTP does nor what the
suite meets: four kills spaced past the five second window leave the tree
standing, so it is four **restarts inside the window** and nothing else.

### The fix, and the before and after measured

`config/config.exs`, test environment only: **`broadcast_interval` 60,000 to
3,600,000**, the value and the reasoning `flush_interval` already carries. The
same reasoning had been applied to `flush_interval` (X241, X264) and to
`metrics_interval` (X320, set to 0), and this key was left behind.

Tests that need a broadcast drive one: `AuroraMeter.Test.broadcast!/0`,
`AuroraMeter.Broadcaster.broadcast_now/0`, or
`AuroraMeter.Test.Config.with_config/2` for a deliberately short interval inside
one test (`cluster_lag_test.exs` does exactly that at 1,000 ms). **No test
depends on the periodic tick**, which is why it could be removed rather than
lengthened a little.

Measured at the real intervals, with the detector proved on a positive control
first so that a zero is a zero and not a broken handler:

```
AURORA_BENCH=1 MIX_ENV=test DB_PORT=5490 \
  elixir -S mix run --no-start tmp/v1/08c-timer-probe.exs
exit=0   failures: 0        duration 135 s

1. Positive control: the detector can see a tick
  ticks at 200 ms in 2 s                      9
  PASS  the detector sees ticks when there are ticks

2. The value this suite ran until today: 60,000 ms, watched 65 s
  ticks at 60,000 ms in 65 s                  1
  PASS  a 60 second timer fires during a run
  ticks that would fire in a 260 s suite      4

3. The configured value, watched for the same 65 s
  ticks at 3600000 ms in 65 s                 0
  PASS  no tick fires
  PASS  and none can: the interval exceeds any run this suite has taken
```

**Four ticks per run before, none after, and none possible after.** That is why
this is a removal rather than a reduction: a 3,600,000 ms timer scheduled once at
boot cannot fire inside a 260 second run, so the rate is not lowered, the event
is gone.

`AuroraMeter.ConfigTest` gains
`test "no periodic timer in the test environment can fire during a run"`, which
asserts every periodic interval is either 0 or at least 1,800,000 ms and names
X241, X264, X320 and X347 in its failure message. Four findings were the same
sentence with a different key in it; this is the sentence.

## 5. Supplier two (X349), and why supplier one was not the whole answer

**A run count after the broadcast fix still produced a dead tree.** Five full
runs: three clean, one failing an unrelated random-seed property, and one, at
seed 505085, that died after 10 seconds with no `Result:` line at all. This time
the whole log was kept, and it ends:

```
[error] GenServer AuroraMeter.Flusher terminating
** (ArgumentError) errors were found at the given arguments:
  * 1st argument: the table identifier does not refer to an existing ETS table
    (stdlib 8.0) :ets.lookup(:aurora_meter_flush_batches, :pending)
    (aurora_meter 0.5.0) lib/aurora_meter/flusher.ex:158: AuroraMeter.Flusher.failed/2
    (aurora_meter 0.5.0) lib/aurora_meter/flusher.ex:72: AuroraMeter.Flusher.terminate/2
Last message: {:EXIT, #PID<0.440.0>, :shutdown}
** (EXIT from #PID<0.95.0>) shutdown
```

`{:EXIT, _, :shutdown}` reaching the Flusher is `AuroraMeter.Supervisor` shutting
its children down, and the second `EXIT` is that shutdown reaching the VM's main
process. So the tree died again, with no timer left that could fire.

`grep` for every call site that waits on an **automatic** restart of a child of
`AuroraMeter.Supervisor` found four, not three:

```
test/aurora_meter/kill_test.exs:160        Kill.await_restart!(Flusher, from: pid)
test/aurora_meter/kill_test.exs:187        Kill.await_restart!(Store,   from: pid)
test/aurora_meter/kill_test.exs:217        Kill.await_restart!(Store,   from: pid)
test/aurora_meter/store_gauge_test.exs:214 Kill.await_restart!(Store,   from: pid)
```

`AuroraMeter.StoreGaugeTest` kills the Store so that `init/1` runs again and arms
the gauge timer, which is the right thing to test. It is the **fourth** automatic
restart in the suite. Both modules are `async: false`, ExUnit shuffles the order
of synchronous modules by seed, and when the seed puts these two next to each
other the four restarts land inside the same five seconds.

The test's own comment already named the hazard and stopped one step short of it:

> the supervisor allows three restarts in five seconds and a test that spends two
> of them is a test that can take the tree down when it runs beside
> `AuroraMeter.KillTest`

It was right that two would be fatal. One is fatal too, because `KillTest`
already spends the whole budget.

### Forced deterministically

Run the two modules, and only those two, in one invocation. There is no seed at
which they are not adjacent, so the collision is guaranteed rather than sampled.

```
bash tmp/v1/08c-fourth-kill-both.sh
```

That script reverts `store_gauge_test.exs` to its pre-fix kill, runs the
forcing, restores the file and runs it again. The revert is a **checksum
snapshot and restore, never `git checkout`** (X326), the restore is on the
script's `EXIT` trap so an interrupted run still puts the file back, and the
script prints both digests at the end: the file is byte identical afterwards
(`21a4f5f128328650f7070a2bf976215f397949027ebd5917aea0f7717c3ed03d`).

**Before, five runs at five seeds, every one fatal:**

| run | seed | exit | duration | result |
|---|---|---|---|---|
| 1 | 122581 | 1 | died | NO RESULT LINE, `** (EXIT from #PID<0.95.0>) shutdown` |
| 2 | 875806 | 1 | died | NO RESULT LINE, `** (EXIT from #PID<0.95.0>) shutdown` |
| 3 | 705038 | 1 | died | NO RESULT LINE, `** (EXIT from #PID<0.95.0>) shutdown` |
| 4 | 479353 | 1 | died | NO RESULT LINE, `** (EXIT from #PID<0.95.0>) shutdown` |
| 5 | 306199 | 1 | died | NO RESULT LINE, `** (EXIT from #PID<0.95.0>) shutdown` |

**0 of 5 clean.** The logs carry the orchestrator's exact failure: the
`ArgumentError` from `:ets.lookup(:aurora_meter_flush_batches, :pending)` inside
`AuroraMeter.Flusher.terminate/2`, then the VM's main process taking the
supervisor's `:shutdown`. `broadcast_interval` is 3,600,000 for these runs, so
**no timer is involved in any of them**.

Three of the five also carry the guard from the next section firing on the real
thing rather than on a planted probe, naming the file and the line before the
tree went down:

```
1) test this module is the only one that spends AuroraMeter.Supervisor's restart budget
   a supervised child of AuroraMeter.Supervisor is killed and left to restart
   automatically outside test/aurora_meter/kill_test.exs:
   [{"test/aurora_meter/store_gauge_test.exs", 231, "Kill.await_restart!(Store, from: ...
```

In the other two the tree died before that test was reached, which is the
ordering the seed chose and is exactly why the guard exists: a source scan
reports the offence whether or not the run gets far enough to suffer it.

### The fix

`test/aurora_meter/store_gauge_test.exs`: the kill becomes a **manual** restart.

```elixir
:ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Store)
{:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)
```

This is not "make it rarer". `Supervisor.restart_child/2` is **not counted
against restart intensity at all**, so the collision cannot happen at any seed,
at any spacing, under any load. And it is not a weaker test: what the test needs
is `AuroraMeter.Store.init/1` running again with `metrics_interval: 50` in the
environment, and `terminate_child` plus `restart_child` runs exactly that
function on exactly that path. The tables die with their owner and `init/1`
creates them again and arms the timer, which is the assertion. `KillTest`'s own
moduledoc had already written down that this is the way out:

> `Supervisor.restart_child/2`, which `AuroraMeter.FlusherTest` uses, is a manual
> restart and does not count.

`AuroraMeter.FlusherTest` and `AuroraMeter.LiveDashboard.SectionsTest` already
restart children this way, so the idiom is the suite's own.

**After, the same forcing minutes later on the same machine:**

| run | seed | exit | duration | result |
|---|---|---|---|---|
| 1 | 188393 | 0 | 1.8 s | `Result: 15 passed` |
| 2 | 71424 | 0 | 1.8 s | `Result: 15 passed` |
| 3 | 923030 | 0 | 1.8 s | `Result: 15 passed` |
| 4 | 782554 | 0 | 1.8 s | `Result: 15 passed` |
| 5 | 649345 | 0 | 1.8 s | `Result: 15 passed` |

**5 of 5 clean**, ten distinct seeds in that pair of batches. An earlier pair,
run before the guard existed, gave the same answer at ten further seeds:
0 of 5 before (121473, 855473, 630947, 372578, 128359) and 5 of 5 after (574897,
408869, 276249, 106834, 965348). **Twenty seeds, one command, and the outcome
tracks the fix rather than the seed.**

### The standing guard, and it was watched failing

The moduledoc said "this module consumes the whole restart budget" before today
as well, and a second module spent a fourth anyway. A rule nothing enforces is
one already being broken (X153). So `AuroraMeter.KillTest` gains
`test "this module is the only one that spends AuroraMeter.Supervisor's restart
budget"`, which reads the supervised children **from the running tree** (so a
child added by a later unit is covered without anyone remembering to), scans
`test/**/*.exs` for a call that waits on one of their automatic restarts, and
asserts the set of files is exactly `kill_test.exs` and the count is exactly
three.

A guard nobody has watched fail is a guard nobody has tested, so it was watched:

```
bash tmp/v1/08c-guard-proof.sh

guard at test/aurora_meter/kill_test.exs:86
== 1. control: the tree as it stands
   rc=0  Result: 1 passed, 5 excluded
== 2. a fourth automatic restart, introduced in an untracked scan-only file
   rc=2  Result: 0/1 passed, 5 excluded
     1) test this module is the only one that spends AuroraMeter.Supervisor's restart budget
        a supervised child of AuroraMeter.Supervisor is killed and left to restart
        automatically outside test/aurora_meter/kill_test.exs: [...]
== 3. control again, after the violation is removed
   rc=0  Result: 1 passed, 5 excluded
== the probe file is gone
```

The violation is written into a file named without the `_test` suffix, so the
scan sees it and `mix test` never loads it, and no tracked file is touched. The
script owns its cleanup (X329) and the last line proves the cleanup ran. The
guard also refuses to pass when `Supervisor.which_children/1` returns nothing,
because a detector that can quietly match nothing is exactly the failure this
unit made three times in its own scripts.

## 6. This unit's own contribution, and what was done about it

08c did not create either hazard and it did perturb the first one. `mix test`
runs async modules concurrently, and `test/mix/tasks/aurora_meter_bench_test.exs`
spawns twelve external `elixir` processes during that phase. Each one, started
with no flags, takes **one scheduler per logical CPU**: on this host that is
twelve VMs of 24 scheduler threads each competing with the suite's own 24. That
does not create a fourth restart, but it changes both the suite's duration and
its scheduling, and therefore where the 60 second tick fell relative to
`KillTest`'s three kills, and how far apart the two `async: false` modules ran.
A latent one-in-N becomes an observed failure. That is X264's signature exactly:
the failing seed moved between runs, and the movement was the evidence.

Two changes, neither of which is "make it rarer":

1. **`--erl "+S 2:2 +A 2"`** on every spawn. The task's workload in these tests
   is `--procs 2`; it has no use for 24 schedulers. The file also got faster,
   6.7 s to 4.5 s.
2. **Every spawn asserts that `AuroraMeter.Supervisor` is still alive when the
   external process exits.** If an external process ever does perturb the VM
   under the suite, the failure names itself in this file instead of surfacing as
   six hundred unrelated ETS failures.

## 7. Full suite runs

The forcing in section 5 is the proof; this is the rate it was showing up at in
ordinary runs, before and after, on the whole suite.

```
bash tmp/v1/08c-recount-before.sh    # re-judges every retained pre-fix log
bash tmp/v1/08c-runcount-after.sh 6  # six full runs after both fixes
```

Each run takes its own random seed, which is the point: a fault that moves with
module placement rather than with a seed is not answered by pinning one. **Every
pre-fix batch is re-judged from its logs** rather than from the summary its
counter printed, because that counter was wrong (X350).

## 8. Results

### Before, meaning after supplier one was fixed and before supplier two was

Ten retained full-suite logs, re-judged from the logs:

| log | seed | duration | result |
|---|---|---|---|
| `08c-runcount/run-1.log` | 487501 | 255.9 s | **2007/2008**, property `I10` in `AuroraMeter.CreditsLotsTest` (X351) |
| `08c-runcount/run-2.log` | 505085 | died at about 10 s | **NO `Result:` LINE**, supervisor down, section 5's stack |
| `08c-runcount/run-3.log` | 438993 | 251.8 s | 2008 passed |
| `08c-runcount/run-4.log` | 344548 | 251.9 s | 2008 passed |
| `08c-runcount/run-5.log` | 310533 | 267.5 s | 2008 passed |
| `08c-run1/full-1.log` | 779176 | 251.6 s | 2008 passed |
| `08c-run1/full-2.log` | 505772 | 253.2 s | 2008 passed |
| `08c-run1/full-3.log` | 841496 | 275.1 s | 2008 passed |
| `08c-run1/after-probe-1.log` | 13413 | 252.7 s | 2008 passed |
| `08c-run1/after-probe-2.log` | 791160 | 250.3 s | 2008 passed |

**8 of 10 clean. One dead supervisor, one unrelated property.** And before those
ten there was a batch of six whose logs a bad counter discarded, one of which
also printed no `Result:` line, so the honest statement of the rate is **one or
two dead trees in sixteen full runs**, and the uncertainty is mine.

### After both fixes

| run | seed | duration | result |
|---|---|---|---|
| 1 | 625165 | 251.1 s | 2009 passed |
| 2 | 876951 | 259.3 s | 2009 passed |
| 3 | 306715 | 251.2 s | 2009 passed |
| 4 | 637338 | 251.7 s | 2009 passed |
| 5 | 450570 | 271.9 s | 2009 passed |
| 6 | 428452 | 251.3 s | 2009 passed |

**6 of 6 clean**, six distinct seeds, 25.5 minutes of wall clock, every log kept.
2009 rather than 2008 is the two standing guards.

And the gates themselves, run last with every file at its final bytes
(`tmp/v1/08c-final-gates.sh`):

| gate | exit | result | test phase | whole gate |
|---|---|---|---|---|
| core `mix check` | **0** | 2009 passed (80 doctests, 20 properties, 1909 tests), 6 excluded | 251.8 s | 264 s |
| Pro `mix check` | **0** | 1135 passed (72 doctests, 1063 tests) | 17.0 s | 27 s |

`git status --short --untracked-files=all` was captured for the storefront, core
and Pro before and after that script and is **byte identical in all three**
(criterion 8), and Pro's is empty: no Pro file changed.

**Six clean runs is not on its own a proof and is not offered as one.** At the
observed pre-fix rate, one or two dead trees in sixteen runs, six consecutive
clean runs happen by luck **between about 45 and 70 percent of the time**
(`(14/16)^6 = 0.45`, `(15/16)^6 = 0.68`). A batch that likely is a coin toss
proves nothing on its own, and saying so is the point: what proves this is
section 5, the collision forced at every seed, 0 of 5 before and 5 of 5 after. The run count is here because the orchestrator
asked for the rate before and after, and because a fix that made the suite worse
in some other way would show up in it.

### The run I destroyed the evidence for, and the run I miscounted (X325, X350)

Two of this unit's own mistakes, both of them X325, both worth writing down.

**The destroyed one.** The first batch of six was counted by a script that kept
two line patterns from each run and threw the rest away. Run 1 of that batch took
36 seconds, printed the ExUnit banner and **printed no `Result:` line**, and
there is nothing left to read. An absent result is a failure and not a pass, so
it is counted as one. Two hypotheses for it were tested and both are refuted:

- **An OOM kill.** `dmesg` has no `Killed process` or `Out of memory` line, and
  the host had 8.5 GiB free of 19 GiB.
- **A forced recompile.** Run 1 was the first `mix test` after an
  `AURORA_BENCH=1 mix run` probe, and `AURORA_BENCH` changes what
  `config/config.exs` evaluates to, so Mix might have recompiled inside those 36
  seconds. `tmp/v1/08c-run1-hypothesis.sh` reproduces that exact sequence twice:
  `recompiled=0` both times and both runs clean at 2008.

The most likely explanation, given section 5, is the collision in section 5,
which was present in every run of this unit until today. It cannot be asserted,
because the log is gone.

**The miscounted one.** The replacement script kept every line and then compared
the result with `grep -q "2008 passed"`, which **matches inside
`Result: 2007/2008 passed`**. ExUnit prints that ratio only when a run has
failed, so a failing run was reported CLEAN by a counter written specifically to
stop that happening. It is now anchored on the shape rather than on a count: a
clean run is a `Result:` line with no `/` in it, and a ratio present or the line
absent are both failures.

The rule that survives all three instances is not "check for a failure line". It
is **"keep everything, and treat anything you cannot read as a failure, and watch
your detector fail before you trust it passing"**.

## 9. Observed and not this unit's: a random-seed property failure (X351)

One run of the five-run batch failed property
`I10 a generated history on a lot wallet reconstructs the balance row` in
`AuroraMeter.CreditsLotsTest`, at a random seed, after 27 clean runs of the same
suite. This is X276's family: the fixed-seed sweep (0, 1, 7, 42, 1337) is clean,
and the failure moves with the generator rather than with anything 08c changed.
It is recorded here and filed rather than fixed, because 08c must not change what
it measures.

## 10. Open defects (X348)

**X348, and it is not a test problem.** The asymmetry found in section 4 is in
the library: `AuroraMeter.Flusher.do_flush/1` rescues and catches, and
`AuroraMeter.Broadcaster.handle_info(:broadcast, _)` does neither, so a tick that
meets a restarting Store takes the Broadcaster down. The shipped default
`broadcast_interval` is **1 second**, not the hour this suite now uses, so a host
whose Store crashes repeatedly can lose `AuroraMeter.Supervisor` to restart
intensity and stop metering until its own supervisor restarts the tree. The
buffered deltas in ETS go with it, which is the documented loss but arriving by a
path nobody wrote down.

08c does not change `Broadcaster`: it is measured by this unit's bench modes and
the unit must not change what it measures. Recorded for an owner.

## 11. Handoff

All four probes are runnable: 10 s, 135 s, about 20 s and about 25 s.

What is still true and should be said plainly: **`AuroraMeter.KillTest` runs
`AuroraMeter.Supervisor`'s restart budget at zero margin.** Neither change widens
that margin. They remove the two things that were spending a fourth restart, and
the next unit to add one will spend it again. The difference is that it will now
fail in `AuroraMeter.KillTest` with a message naming the file and the line,
rather than as six hundred `ArgumentError`s in whatever ran next.

The alternative, raising `max_restarts` for the test environment, would be
changing the library's supervision policy to suit a test and was not done.
