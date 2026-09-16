# 08c: budget breaches

Every breach of the budgets in `08c-budgets.md`, with its cause, its
measurement, its resolution or the reason the tradeoff is accepted, and the
claim it retires. V1 task **08.08**.

One breach so far.

---

## 2026-09-16: `spread` is 28.53 percent slower than v0.4.0 (finding X342)

| | |
|---|---|
| Family | hot path |
| Metric | median throughput across five runs |
| Reference | v0.4.0, **4,782,812** increments/s (`08c-baseline.md`) |
| Candidate | V1 at `34c188d`, **3,418,407** increments/s |
| Change | **-28.53 percent** |
| Threshold | a fall of more than 10 percent |
| Baseline spread | 13.52 percent |
| Candidate spread | 12.19 percent |
| Verdict | **breach**, and believed on two grounds rather than on the threshold: the fall is more than twice the candidate's own run-to-run spread, and its cause is measured rather than inferred. Both spreads exceed the 10 percent threshold on this run, so the threshold alone would not have been enough |

### The cause, measured

`AuroraMeter.Counter.incr/4` is otherwise identical between the two revisions:
one `:ets.update_counter/3` over three positions, then `mark_dirty/1`. The one
difference is its fourth argument.

```elixir
# v0.4.0
def incr(tenant_key, feature, qty, period_start) do
  new = bump({tenant_key, feature, period_start}, qty)
  bump_history(tenant_key, feature, qty, Date.utc_today())
  new
end

# V1 (the clock seam, build unit 02c)
def incr(tenant_key, feature, qty, period_start) do
  new = bump({tenant_key, feature, period_start}, qty)
  bump_history(tenant_key, feature, qty, Clock.today())
  new
end
```

Elixir evaluates that argument **before** the call, so it is paid on every
increment whether or not `:history` is on, and the bench runs micro modes with
history off. `Clock.today/0` is `AuroraMeter.Config.clock().today()`: an
`Application.get_env` lookup, a module dispatch,
`System.system_time(:microsecond)`, a `DateTime` struct built from it, and
`DateTime.to_date/1` on the result.

`tmp/v1/08c-clockprobe.exs`, 4,000,000 calls of each with a 100,000 call warm-up
discarded, on the same machine and toolchain:

```
Date.utc_today/0            (v0.4.0)        146.9 ns/call  total 587.4 ms
AuroraMeter.Clock.today/0    (V1)           261.0 ns/call  total 1044.0 ms
AuroraMeter.Config.clock/0  (the lookup)     69.7 ns/call  total 278.7 ms
Clock.System.today/0        (no lookup)     163.8 ns/call  total 655.3 ms
System.system_time(:microsecond)             28.1 ns/call  total 112.5 ms

difference per call: 114.1 ns
difference over 4000000 increments: 456.6 ms
```

The measured run durations: 4,000,000 / 4,782,812 = **836.3 ms** at v0.4.0 and
4,000,000 / 3,418,407 = **1,170.1 ms** at V1, a difference of **333.8 ms** of
wall time across eight concurrent workers on 24 schedulers. The clock read's
difference is 456.6 ms of CPU, which across eight workers on a machine with
spare schedulers is the same order and the right direction. The regression's
magnitude is accounted for by this one change; no other difference in `incr/4`'s
path was found.

**What this does not prove.** The attribution is an inference from two
measurements plus a microbenchmark of the two functions, not an A/B of the two
clocks inside `incr/4`: that would need a patched `Counter.incr/4`, and 08c must
not change the function it measures. The experiment that would settle it is a
one-line variant of the current code measured against the current code on the
same run, and it belongs to whoever takes the finding.

The single largest component is the **configuration lookup**: 69.7 ns per call,
27 percent of `Clock.today/0`'s cost, spent asking the application environment
which clock module to use, on every increment, for a result that changes only
when a test installs a fixed clock.

### Resolution: accepted as a deliberate tradeoff, not fixed here

The clock seam is build unit 02c's, and it exists for a reason this programme
has measured rather than assumed: the shared clock steps backwards by up to 439
ms on a 32.5 second cadence (`open-findings.md` X100), and the seam is what lets
every duration in the library be read from one place and be pinned in a test.
Removing it to recover 114 ns per increment would give back a correctness
property to buy a number.

08c must not change `Counter.incr/4` either way: it is what the bench measures,
and a unit that changed the thing it was measuring would have no measurement.

**So the tradeoff stands and the measured result is published.** `README.md`
now says 3,418,407 increments/s, with the toolchain and the date beside it, and
neither the figure it used to carry nor the v0.4.0 baseline.

### The claim this retires

The spread-key figure from `docs/evidence/phase-03/bench.md`, which was
published on `README.md` (which ships on Hex with every release) and in
`docs/launch/gtm.md`, and which is about 40 percent above what this machine
measures today. It is named by reference rather than reproduced, for the reason
`08c-results.md` gives. It was measured against the 0.3 four-column counter row
that 0.4.0 replaced, by a task that has crashed at its own summary line ever
since (`open-findings.md` C7). It is now gone from every document that makes a
claim, and `AuroraMeter.Bench.ClaimsTest` fails if it comes back.

### What would close it, for whoever wants the throughput back

The cheap half is the lookup, not the clock. `AuroraMeter.Config.clock/0` could
resolve through `:persistent_term` with the same semantics, which would return
about 70 ns of the 114 ns for no change to the seam's contract, and the read
itself is what X100 says the library must keep. The expensive half after that is
`Clock.System.today/0` building a `DateTime` to throw away everything but its
date; a direct `:calendar` conversion from the same `System.system_time/1`
reading would be cheaper again and would keep `now/0` and `today/0` derived from
one instant, which is the property the module's own documentation says it has.

Neither is 08c's to make. Both are measurable with `mix aurora_meter.bench
spread` against this page's number, which is the point of having it.
