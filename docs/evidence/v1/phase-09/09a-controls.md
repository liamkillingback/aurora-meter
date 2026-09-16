# 09a: the negative controls

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.
Harness: `tmp/v1/09a/controls.py`. Raw logs: `logs/09a-controls.log` (the run in
which eleven of the twelve discriminated), `logs/09a-controls-c5.log` (`c5` on
its own, with the third and working patch) and `logs/09a-controls-first.log` (the
first run, kept because two of its verdicts are the interesting ones and
deleting a log that shows a detector failing is how the lesson gets lost).

Twelve controls. Each restores a defect this unit's tests are supposed to catch,
runs the tests, and requires the **named** test to fail. A test that passes with
the defect in place is a test that proves nothing.

## How the harness is built, and why each rule is there

  * **X326, never `git checkout`.** The harness runs no git at all. Before the
    first patch it asserts the **baseline** (every anchor occurs exactly once in
    its target) and refuses to start otherwise, copies every target aside and
    records its sha256, restores from that copy and verifies the digest after
    every control, registers the restore on an `atexit` hook so an exception or
    an interrupt still restores, and sweeps all targets at the end. The three
    baseline digests and the final "all 3 targets back at their baseline digest"
    line are both in the log.
  * **X325 and X350, the verdict is positive and anchored on shape.** ExUnit
    prints an `X/Y` ratio in its `Result:` line only when a run is **not** clean,
    so a run is CLEAN only when a `Result:` line exists and contains no `/`. A
    missing line is `NO_RESULT` and is a failure, never a pass. Nothing is
    decided by a substring of a count.
  * **X300, a control that does not compile has tested nothing.** A run with no
    `Result:` line is reported as HARNESS ERROR with the last 25 lines of output
    printed, never as "the control discriminated". Three controls hit this and
    all three are written up below.
  * **X125 and X287, a control that PASSES is a question.** One did, and it
    found a real defect in a test.

## Results

| Control | The defect it restores | Tests that must fail | Verdict |
|---|---|---|---|
| `c1-plug-reserves` | the plug calls `reserve/2` instead of `check/2`: the reserving pre-request plug 09.02 forbids | "usage is unchanged after a passing request", "twelve passing requests at the cap boundary" | **discriminated**, both |
| `c2-missing-tenant-defaults` | a `nil` tenant falls through to `""` instead of 401 | "halts with 401 and :missing_tenant", "never resolves the default tenant" | **discriminated**, both |
| `c3-usage-payload-loses-tenant-key` | `tenant_key` removed from the `:usage` broadcast | "the usage broadcast carries the tenant_key" | **discriminated** |
| `c4-on-mount-subscribes-on-static` | `on_mount` subscribes on the static mount too | "subscribes only when connected" | **discriminated**, and it also caught "switch_tenant on a disconnected socket only re-assigns" |
| `c5-switch-tenant-leaks-old-topics` | `switch_tenant/2` unsubscribes the new key instead of the old one | "unsubscribes the old topics and subscribes the new ones" | **discriminated** (third patch; see below) |
| `c6-handle-usage-does-not-filter` | the `tenant_key` comparison in `handle_usage/2` is a tautology | "drops a message whose tenant_key is not the socket's", "a socket switched to a second tenant keeps only the second tenant's value" | **discriminated**, after the second test was fixed (see below) |
| `c7-bare-on-mount-falls-back` | the bare `:subscribe` form resolves from an assign instead of raising | "bare :subscribe without live_view_tenant raises ArgumentError naming the config key" | **discriminated**, and it also caught the positive control beside it |
| `c8-denial-callback-need-not-halt` | the halted-conn assertion is skipped | both `RuntimeError` tests | **discriminated**, both |
| `c9-subscribe-leaves-partial` | `subscribe/2` does not roll back what it subscribed | "unsubscribes what it had subscribed when a later topic fails" | **discriminated** |
| `c10-entitled-mode-reads-usage` | `mode: :entitled?` routed through `check/2` | "passes at the hard cap because it never reads usage", "reads no counter, and the same arming makes :check answer 503" | **discriminated**, both |
| `c11-config-errors-become-503` | `UndeclaredFeatureError` and `InvalidPeriodError` classified as outages | both propagation tests | **discriminated**, both |
| `c12-live-view-accepts-nil-tenant` | `resolve_key!/2`'s `nil` clause never matches | "subscribe refuses a nil tenant", "switch_tenant raises on a nil tenant" | **discriminated**, both |

Baseline before any patch: `Result: 67 passed (1 doctest, 66 tests)`, CLEAN.

## The control that passed, and the defect it found

`c6-handle-usage-does-not-filter` removes the tenant filter from
`handle_usage/2`. It correctly failed "drops a message whose tenant_key is not
the socket's" and it **passed** "a socket switched to a second tenant keeps only
the second tenant's value", which is acceptance criterion 7.

The test read:

```elixir
socket = handle_usage(usage_message(first,  :requests, 111, nil), socket)
socket = handle_usage(usage_message(second, :requests, 222, nil), socket)
assert socket.assigns.aurora_meter_usage == %{requests: %{value: 222, ...}}
```

With the filter removed both messages are applied, the second overwrites the
first, and the expected value comes out anyway. **The test could not fail.** Worse,
the ordering it used is the wrong one: the hazard is a message broadcast
**before** the switch and delivered **after** it, so the stale message arrives
last.

Fixed by delivering `second` and then `first`. With the filter it is 222; without
it, 111. The control now fails it.

This is the entire reason the controls are run, and it is X287 for the third time
in this programme: a control that passes is a question, not a result.

## The three harness errors, and what each cost

None of them was reported as a pass, which is the point of the X300 rule.

1. **`c11`, first attempt.** The patch was
   `error in [UndeclaredFeatureError] when false ->`, which is not a legal
   `rescue` clause. `error in [...] when guard` is a syntax error in Elixir, so
   the module did not compile. Rewritten to keep the clause and change its
   **body** to `{:unavailable, error, __STACKTRACE__}`, which is exactly the
   defect and compiles.
2. **`c5`, two attempts.** Deleting the `unsubscribe_key/2` call left the
   function unused; passing it `nil` made its second clause unreachable.
   `elixirc_options: [warnings_as_errors: true]` refuses both. Rewritten to pass
   the **new** key instead of the old one: the old topics leak, both clauses stay
   reachable.
3. **`c5` and `c6` together, on the second full run.** `c5` failed to compile,
   and `c6` then reported *`c5`'s* compile error as its own with no `Compiling`
   line of its own. Mix decides staleness from mtime at one-second granularity,
   and a patch and its restore inside the same second are invisible to it, so
   `c6` ran against a build that still held `c5`'s failure. Every write in the
   harness now takes a strictly increasing mtime in the future, so no pair can
   collide.

   The first version of the harness printed the output tail only when a regex
   recognised a compile error, so these came back as bare `NO_RESULT` with no way
   to tell why. It now prints the tail for **every** run with no `Result:` line,
   whatever the cause.

## The harness leaked a patched tree to another agent

Recorded here as well as in `09a-flake.md` section 2, because it is a defect in
this harness rather than in the unit's code.

The harness patched a file, then called `tmp/v1/mixlane.sh`, which takes the lane
lock, runs `mix`, and **releases the lock when it exits**. The restore ran after
that. Between the release and the restore, a patched `lib/` file sat on disk with
the lane free, and that window is the worst one available: it is exactly when an
agent blocked on the lock is woken.

It reached someone. Repair unit R2 reported core failing at
`test/aurora_meter/live_view_test.exs:263`, and control
`c5-switch-tenant-leaks-old-topics` reproduces that failure at that exact line
with `left: 1 right: 0` (`logs/09a-sighting1.log`). R2 was compiling this
harness's patched tree.

The harness now takes the lane lock **in-process** and holds it across baseline,
patch, test and restore, calling `mix` directly instead of through `mixlane.sh`.
The restore hook is registered after the lock-release hook so `atexit` runs it
first, which puts the tree back while the lane is still held.

This is X326 with its missing half. X326 said a harness must take its own
baseline and assert its own restore, and this one did both. What it never asked
was **who else can see the tree while it is modified**. A harness that mutates
shared state must hold the same lock its readers take, for the whole time it is
mutating; asserting the restore afterwards does nothing for the run that read the
tree in between.

## The final sweep, and a fourth detector that was wrong

The harness restores from its snapshots and verifies the digests, and its last
line is `[restore] all 3 targets back at their baseline digest`. That is the
harness marking its own homework, so the tree was checked again afterwards, and
the check found a mismatch: `lib/aurora_meter/plug/ensure_entitled.ex` no longer
hashed to the baseline the harness recorded.

It was `mix format`, run on this unit's own changed files after the controls, and
it wrapped one `@spec`. But "the harness said it restored" is not an answer to a
digest that has moved, so the question was asked directly instead
(`tmp/v1/09a/verify_clean.py`, log `logs/09a-restore-sweep.log`): every control's
**anchor**, which is the correct code, must be present exactly once. If a patch
had survived, its anchor would have been replaced and its count would be zero.
All twelve are present exactly once.

The first version of that check also counted the **replacement** text and called
a non-zero count "DEFECT STILL PRESENT". Three controls are deletions, so their
replacement is a substring of their anchor and is present in perfectly clean
code, and the check reported three surviving defects that had never existed. The
verdict is now the anchor count alone, the replacement count is printed and
decides nothing, and the script carries a probe that plants `c1`'s defect **in
memory** and asserts the anchor count goes to zero, so the sweep is watched
seeing a survivor before it is trusted saying there is none (X350's third
clause).

Four detectors in this unit produced a wrong answer before they produced a right
one: the leg's dependency probe, the controls' `NO_RESULT` reporting, the mtime
collision, and this sweep. Every one of them was wrong in the direction of
reporting success.

## What the controls do not cover

The optional-dependency guards (`Code.ensure_loaded?(Plug.Conn)`,
`Code.ensure_loaded?(Phoenix.LiveView)`) are not controlled here. Restoring a
defect in a guard changes what compiles rather than what a test asserts, and the
honest proof is the legs themselves: `09a-optional-deps.md` shows the module
present on one leg and absent on another, with the resolved dependency list for
each, and every assertion written as an equality against its own dependency so
that it is a positive control on the leg where the dependency is present.
