# 09a: three intermittent failures, three different mechanisms

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.

Two independent repair units saw an intermittent failure in this unit's work.
They are **not the same cause**, and assuming they were is how the second would
have been missed. One is a defect in a test this unit wrote; the other is a
defect in the control harness this unit ran, which left a patched library file on
disk where another agent compiled it.

| | Sighting one | Sighting two | Sighting three |
|---|---|---|---|
| Seen by | R2, once, in a full suite (2113/2114) | R3, about 1 run in 3; reproduced 2 of 6 with R3's own changes reverted | nobody: found by verifying the other two |
| Where | `live_view_test.exs:263` | `doc_examples_test.exs:192` | `plug/ensure_entitled_test.exs:82` |
| Cause | this unit's **control harness** released the lane lock before restoring a patched `lib/aurora_meter/live_view.ex` | `function_exported?/3` asked about a module that had not been loaded | absolute absence asserted in a **node-wide** ETS table other modules legitimately populate |
| Reproduced | deterministically, by applying the control | deterministically, 5 of 5 and 10 of 10 | deterministically, at the seed that produced it |
| Fixed by | holding the lane lock across patch, test and restore | `Code.ensure_loaded?/1` first, through a helper, plus a guard that enforces the idiom | a before/after delta instead of an absolute absence |
| After | not reproducible by construction: the defect can no longer reach another agent's build | 30 of 30 clean where the force failed 10 of 10 | clean at the failing seed, and the control that should catch it still does |

## 1. Sighting two: the mechanism, shown

R3's reading was that `function_exported?/3` answers `false` for a module that has
not been loaded. That is plausible and it is not a proof, so it was forced and
then shown.

**Forced.** `test/aurora_meter/doc_examples_test.exs:169` is the test containing
line 192. Run on its own, in a fresh VM, nothing else in the run can have loaded
`AuroraMeter.LiveView`:

```
mix test test/aurora_meter/doc_examples_test.exs:169 --seed <n>
seed 1  FAILED  Result: 0/1 passed, 12 excluded
seed 2  FAILED  seed 3  FAILED  seed 4  FAILED  seed 5  FAILED
     code: assert function_exported?(AuroraMeter.LiveView, :switch_tenant, 2)
     Expected truthy, got false
```

**5 of 5.** Log: `logs/09a-force-before.log`.

**Shown.** `logs/09a-mechanism-lazy-load.log`, from a VM that has done nothing
else and never names the module in a remote call (a remote call is resolved at
compile time and would load it):

```
BEFORE anything loads it:
  :code.is_loaded/1        => false
  function_exported?/3     => false
the beam is on disk the whole time, so the function does exist:
  :code.which/1            => ".../Elixir.AuroraMeter.LiveView.beam"
AFTER Code.ensure_loaded?/1 => true:
  :code.is_loaded/1        => {:file, ...}
  function_exported?/3     => true
```

`false` for a function that exists, `true` one `Code.ensure_loaded?/1` later,
with nothing else changed. In a test run, whether the module happens to be
loaded at that point depends on whether an earlier test called into it, which
depends on the seed and the run set. That is the flake.

**The probe was wrong twice before it was right**, and both are worth recording
because both failed towards "success". Its first version named the module in a
remote call (`AuroraMeter.LiveView.__info__/1`), so the compiler loaded the
module before the body ran and it reported the module already loaded. And its
verdict checked only that the answer was `true` AFTER the load, which is true
whatever happens before it, so it printed "MECHANISM SHOWN" on a run that showed
nothing. It now refuses to conclude anything if the module was already loaded
when it started, and requires `false` before and `true` after.

### Why this unit introduced it

`AuroraMeter.LiveView` is the first module in the package that is **always
compiled** and puts only some of its functions behind an optional-dependency
guard. Every earlier optional integration is a whole module, where
`Code.ensure_loaded?/1` is the natural question and `function_exported?/3` never
comes up. Asking about a guarded *function* is new, and the obvious call is the
wrong one.

The package already knew. `lib/aurora_meter/oban.ex:289`,
`lib/aurora_meter/exporter_case.ex:730`, `lib/aurora_meter/period.ex:178`,
`lib/aurora_meter/plans.ex:688` and
`lib/aurora_meter/subscriptions/preview.ex:203` all use
`Code.ensure_loaded?(m) and function_exported?(m, f, a)`, and
`optional_deps_test.exs` has carried a comment explaining exactly this since
build unit 03b, with its own measurement. **A rule that lives only in a comment
is a rule already being broken** (X153), and this unit broke it four times.

### The fix, and why it cannot race

Four call sites, all this unit's, now go through a local helper:

```elixir
defp exported?(module, fun, arity) do
  Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
end
```

| File | Line | Was | Note |
|---|---|---|---|
| `doc_examples_test.exs` | 192 | `assert function_exported?(AuroraMeter.LiveView, :switch_tenant, 2)` | the reported failure |
| `optional_deps_test.exs` | 75, 76 | `assert function_exported?(AuroraMeter.Plug.EnsureEntitled, :init, 1)` and `:call, 2` | safe only because the line above happens to load it |
| `optional_deps_test.exs` | 113-115 | `refute function_exported?(AuroraMeter.LiveView, :on_mount, 4)` and two more | the `plug_only` leg |
| `optional_deps_test.exs` | 382-384 | the same three | the `headless` leg |

**The `refute` sites are the worse half.** An unloaded module answers `false`, so
those refutations passed whether or not the functions were compiled: they could
not have failed, and the absence the leg exists to prove was never tested. They
are safe today only because earlier lines in the same tests call into the module
first, which is exactly the accident this whole finding is about.

### The guard

`test/aurora_meter/exported_idiom_test.exs` (`AuroraMeter.ExportedIdiomTest`),
three tests. It parses the **AST**, not the text, because half the call sites in
this package sit beside a comment naming `function_exported?/3` and a comment is
not a call. It reports every `function_exported?/3` and `macro_exported?/3` on a
literal module alias that is not the right-hand side of an `and` whose left-hand
side is `Code.ensure_loaded?/1` of the same module.

It is **watched failing before it is trusted passing** (X350's third clause): the
third test feeds it a bare call, a wrapped call, the same call inside a comment,
and a call on a module held in a variable, and requires it to find exactly the
first. It also has a staleness test, so an allow-list entry cannot outlive the
call site it excuses.

**Its scope is deliberately narrow**: the files 09a owns or edited. See section 5.

### Before and after

Measured on **one tree**, with the defect restored for the "before" half rather
than remembered from an earlier run: `tmp/v1/09a/force_ba.py` snapshots the file
by sha256, puts the bare call back, measures, puts the fix back, measures again,
and restores on an exit hook with the digest verified. It holds the lane lock
throughout, for section 2's reason. Log: `logs/09a-force-before-after.log`.

| | Before | After |
|---|---|---|
| the owning test alone, 10 seeds (the deterministic force) | **0 passed, 10 failed** | **10 passed, 0 failed** |
| the whole file, 10 seeds | 6 passed, **4 failed** | **10 passed, 0 failed** |

**4 of 10 independently reproduces R3's "about 1 run in 3"**, which is what ties
this measurement to the failure R3 actually saw rather than to a defect that
merely looks like it.

Extended after the fix (`logs/09a-after-full.log`): see section 4.

## 2. Sighting one: a different mechanism, and it is the harness

`live_view_test.exs:263` is
`assert registrations(usage_topic(first)) == 0`, the assertion that
`switch_tenant/2` unsubscribed the tenant it left. It contains no
`function_exported?/3` and nothing lazily loaded, so it is not sighting two.

**It did not reproduce.** 40 runs of the file alone and 25 runs of it alongside
every module in the suite that subscribes to a tenant topic or swaps
`:aurora_meter, :pubsub`: **65 runs, 0 failures**. Every one of those modules is
`async: false`, so ExUnit cannot interleave them with `live_view_test.exs` at
all, which rules out cross-module interference structurally rather than only
empirically.

**What does reproduce it, exactly**, is this unit's own control harness. Control
`c5-switch-tenant-leaks-old-topics` patches `lib/aurora_meter/live_view.ex` so
`switch_tenant/2` unsubscribes nothing. With that patch on disk
(`logs/09a-sighting1.log`):

```
  1) test switch_tenant/2 I20 switch_tenant unsubscribes the old topics and subscribes the new ones
     test/aurora_meter/live_view_test.exs:252
     Assertion with == failed
     code:  assert registrations(usage_topic(first)) == 0
     left:  1
     right: 0
       test/aurora_meter/live_view_test.exs:263: (test)
```

`live_view_test.exs:263`, the line R2 named, with `left: 1`.

**How another agent's run could compile it.** The harness patched a file, then
called `tmp/v1/mixlane.sh`, which takes the lane lock, runs `mix`, and
**releases the lock when it exits**. The restore ran after that. So between the
release and the restore there was a window with a patched `lib/` file on disk and
the lane free, and that window is not an arbitrary moment: it is exactly when an
agent blocked on the lock is woken. R2 ran while this unit's controls were
running, saw it once, and it did not recur.

**The fix.** The harness now takes the lane lock itself, in-process, and holds it
across baseline, patch, test and restore, calling `mix` directly rather than
through `mixlane.sh`. The restore hook is registered after the lock-release hook
so that `atexit` runs it first: the tree is put back while the lane is still
held. No other agent can hold the lane while a control patch is on disk.

This is X326's family with the missing half filled in. X326 said a harness must
take its own baseline and assert its own restore, and this one did both. What it
did not do was ask **who else can see the tree while it is modified**. A harness
that mutates shared state has to hold the same lock the readers take, for the
whole time it is mutating, and asserting the restore afterwards does not help the
run that read the tree in between.

## 3. Sighting three, which nobody reported, found by verifying the other two

The 5-seed full-suite run that was supposed to confirm the fixes failed once, at
seed 638544:

```
  1) test a missing tenant I20 a resolver returning nil never resolves the default tenant
     test/aurora_meter/plug/ensure_entitled_test.exs:65
     Expected false or nil, got true
     code: refute :ets.member(:aurora_meter_subscription_cache, "")
```

A third mechanism, and a third one this unit shipped.

`:aurora_meter_counters` and `:aurora_meter_subscription_cache` are **node-wide**
tables shared by the entire run. The test asserted the **absolute absence** of a
row for `""`. But `""` is what `AuroraMeter.Tenant.Default` returns for anything
it cannot resolve, and several other modules exercise exactly that (it is the
0.5.x transition behaviour C12 is about). Whether a `""` row exists when this
test starts is therefore a question about the seed, not about the plug.

What the test is entitled to claim is that **this request** wrote nothing for
`""`, and a before/after comparison says exactly that. It is deterministic
because the module is `async: false`, so nothing else runs between the two reads.
The database assertions beside it need no such care: they are inside the sandbox.

**Forced, on the seed that produced it** (`logs/09a-sighting3.log`). Same tree,
same seed, same module order, one line different:

```
  absolute absence       FAILED   Result: 2132/2133 passed
      failing assertion: refute :ets.member(:aurora_meter_subscription_cache, "")
  before/after delta     clean    Result: 2133 passed
```

**The first attempt at this measurement proved nothing and said so.** It guessed
at which modules warm that key, ran twelve seeds against them, and the old form
passed 12 of 12. A "before" that never fails cannot demonstrate a fix, so the
script exited non-zero with `NOT PROVED` rather than reporting a green pair. The
seed from the failing run is not a guess and it forces the ordering directly.

The weaker claim is deliberate and is worth naming: the delta says "this request
wrote nothing", not "nothing exists". That is what acceptance criterion 1 means
and it is the strongest claim this test can make without deleting rows from a
table the rest of the run shares. Control `c2-missing-tenant-defaults`, which
makes the plug resolve `nil` to `""` and act on it, still fails this test, so the
weaker form has lost none of its power to catch the defect it exists for.

## 4. One cause or three?

Three, and nothing is shared between them.

| | Lives in | Reproducible on a quiet tree | Fixed in |
|---|---|---|---|
| one | a throwaway harness, never in the source | no | the harness's locking |
| two | the committed source | yes, deterministically | the test, through a helper, with a guard |
| three | the committed source | yes, at a known seed | the test's assertion shape |

No fix affects another's symptom: `exported?/3` does nothing for
`registrations/1`, the lane lock does nothing for lazy loading, and the delta
does nothing for either. Assuming any two were one cause is how the third would
have stayed hidden, and the third was only found because the verification of the
first two was run wide enough to trip it.

## 5. Verification after all three fixes

See `logs/09a-after-full.log`, `logs/09a-controls-relocked.log`,
`logs/09a-force-before-after.log`, `logs/09a-sighting1.log`,
`logs/09a-sighting3.log` and `logs/09a-final-full.log`.

| Run | Result |
|---|---|
| `doc_examples_test.exs`, 30 seeds | 30 clean |
| the deterministic force alone, 30 seeds | 30 clean (was 0 of 10) |
| `live_view_test.exs` alone, 40 seeds | 40 clean |
| eight pubsub-touching modules, 25 seeds | 25 clean |
| the twelve controls, one run | 12 of 12 discriminated, tree restored before the lane is released |
| full suite | see `logs/09a-final-full.log` |
| Pro | `Result: 1158 passed (74 doctests, 1084 tests)`, exit 0 |

## 5. Bare call sites this unit did not write, and did not touch

The guard's scope stops at 09a's files. These predate this unit, have the same
latent defect, and are left alone because a guard that failed their build would
be this unit changing another unit's work by proxy:

| File | Line | Call |
|---|---|---|
| `test/aurora_meter/oban/workers_test.exs` | 227 | `function_exported?(AuroraMeter.Subscriptions, :apply_due_transitions, 1)` |
| `test/aurora_meter/entitlements_test.exs` | 461 | `refute function_exported?(Noop, fun, arity)` |
| `test/aurora_meter/credits_lot_migration_test.exs` | 565 | `function_exported?(Credits, :reverse_lot, 4)` |
| `test/aurora_meter/optional_deps_test.exs` | 179, 458, 459 | `Mix.Tasks.AuroraMeter.Install` (03b's, allow-listed with its reason) |
| `test/aurora_meter/optional_deps_test.exs` | 271-273 | `AuroraMeter.OpenTelemetry` (08b's, allow-listed) |
| `test/aurora_meter/optional_deps_test.exs` | 422, 423 | `Credits` (05a's, allow-listed) |

Every one of them is safe **by adjacency**: a line above happens to load the
module. That is the same accident that made this unit's four look fine until a
seed put them first. Whoever owns those files should consider the same helper;
the three `refute` shaped ones matter most, because a refutation that cannot tell
"absent" from "not yet loaded" asserts nothing.
