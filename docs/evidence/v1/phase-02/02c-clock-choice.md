# 02c step 0: which clock `Clock.System.now/0` reads

**Status: measured, refuted, decided, implemented.**

Step 0 was run before anything was built on its result, as build unit 02c's
implementation sequence requires. The result **contradicted** the hypothesis the
plan was built on, the unit stopped and reported rather than improvising a
replacement, and the owner then decided. The decision is at the bottom of this
file; the rule it establishes is written up in `02c-db-clock.md`.

**The decision, 2026-09-14.** There is no monotone wall clock, so stop looking
for one. `now/0` stays `System.system_time/1` for **cost** and its contract says
plainly that it promises nothing about monotonicity. Anything comparing against
a persisted timestamp takes a fourth reading, `db_now/0`, which is the database's
clock, and the timestamp it compares against is stamped by the database too.

The plan's hypothesis (`02c-period-contract-and-clock.md` section 1, and the
resolution recorded in `open-findings.md` X58) was:

> `now/0` derives from Erlang system time, `System.system_time(:microsecond)`.
> With time correction enabled the VM slews that offset instead of stepping it,
> so Erlang system time is non-decreasing within a node's lifetime while still
> tracking real wall-clock time.

It is not non-decreasing on this host. It steps backwards further than
`DateTime.utc_now/0` does, and it does so on a regular 60 second cadence.

## Machine and toolchain

| | |
|---|---|
| Host | `DESKTOP-8R659B3`, WSL2 (`Linux 6.6.87.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Thu Jun 5 18:30:46 UTC 2025 x86_64`) |
| Elixir | 1.20.1 |
| OTP | 29 (erts 17.0.1) |
| Schedulers online | 24 (logical processors 24) |
| `time_correction` | `true` |
| `time_warp_mode` | `:multi_time_warp` |
| `os_monotonic_time_source` | `clock_gettime`, `CLOCK_MONOTONIC`, parallel |
| `os_system_time_source` | `clock_gettime`, `CLOCK_REALTIME`, parallel |

`:multi_time_warp` is **not** something this repository sets. A bare
`erl -noshell -eval 'io:format("~p", [erlang:system_info(time_warp_mode)])'`
on this OTP reports `multi_time_warp`, with `ELIXIR_ERL_OPTIONS` and `ERL_FLAGS`
both unset. It is OTP 29's default. In that mode the runtime is explicitly
permitted to change its time offset at any time, and `System.system_time/1` is
Erlang monotonic time **plus that offset**, so it can and does move backwards.

Command and log:

```
PROBE_SECONDS=420 elixir tmp/v1/02c/step0-clock.exs
```

`tmp/v1/02c/logs/step0-clock.log`, exit 0, 2026-09-14T11:43:16Z to
2026-09-14T11:50:00Z.

## Step 0: 420 seconds, 24 loaders, 337,900,054 samples of each reading

| Reading | Backwards steps | Largest backwards step |
|---|---|---|
| `DateTime.utc_now/0` | 13 | 1.330921 s |
| `System.os_time/1` | 13 | 1.330923 s |
| **`System.system_time/1`** | **6** | **2.647191 s** |
| `System.monotonic_time/1` | 0 | 0 s |

Every backwards step, as `(elapsed_ms_into_the_run, magnitude_s)`:

- `DateTime.utc_now/0`: (5952, 1.31296), (38466, 1.330921), (70956, 1.248959),
  (103465, 1.309962), (135960, 1.283077), (168431, 1.283102), (201014, 1.112165),
  (233467, 1.210053), (265951, 1.299381), (298464, 1.283066), (330951, 1.247408),
  (363454, 1.260122), (395947, 1.260406)
- `System.os_time/1`: identical instants and magnitudes to within a microsecond,
  which is the direct confirmation that `DateTime.utc_now/0` reads it.
- **`System.system_time/1`**: (61095, 2.647191), (121095, 2.557812),
  (181098, 2.56618), (241099, 2.334122), (301100, 2.582452), (361101, 1.247408)
- `System.monotonic_time/1`: none.

### What the numbers say

1. The OS wall clock on this host is dragged backwards about 1.3 s every 32.5
   seconds under load. That is the WSL2 pathology 01d found and B01's root cause.
2. `System.system_time/1` goes backwards on an exact **60.000 second** cadence
   (61095, 121095, 181098, 241099, 301100, 361101 ms), by roughly the drift
   accumulated since the previous resync. That is a periodic time-offset warp,
   which is exactly what `:multi_time_warp` licenses.
3. The 60 second cadence is why the pre-launch 45 second probe reported zero. A
   45 second window that starts at VM boot cannot contain a 60 second boundary.
   The probe was not wrong; it was too short, which is precisely why the build
   document said "run minutes, not seconds".

**The hypothesis is refuted.** Building `Clock.System.now/0` on
`System.system_time/1` would put B01 and L20 behind an abstraction and call it
closed, which is the failure X58 exists to prevent, only with a different
primitive.

## The refutation, reproduced through the library's own seam

Before the decision, the unit left a soak test asserting that `Clock.now/0` is
monotone. It **failed**, which is the strongest form this evidence takes: not a
standalone script measuring primitives, but the library's own `AuroraMeter.Clock`
going backwards under its own test. `tmp/v1/02c/logs/p06-150s.txt`,
2026-09-14T12:06:07Z to 2026-09-14T12:08:34Z, exit 2:

```
[P06] 150s, 24 loaders, 82903129 samples: Clock.now/0 backwards=2 worst=2.065293s;
                                          control DateTime.utc_now/0 backwards=4 worst=1.293658s

  1) Clock.now/0 stepped backwards 2 times, largest 2.065293s.
     The seam is built on a clock that goes backwards.
```

The negative control fired in the same run (4 backwards steps of up to 1.293658
s), so the harness is known to be capable of detecting a step.

At `AURORA_CLOCK_SOAK_SECONDS=20` the same test passed and the control did not
fire, which is exactly how a 45 second probe concluded the opposite. **A short
soak proves nothing here**, and that is now finding X60: any clock measurement in
this programme runs minutes, not seconds, and states its duration next to its
result.

That test survives, repurposed. It no longer asserts anything about `now/0`,
because `now/0` no longer claims to be monotone; it records how far the host
clock went backwards during the run, so the *reason* for the database clock stays
visible in the suite rather than only in this document. It asserts only that its
own sampler sampled, since a harness that never ran would report zero backwards
steps and look like good news.

## Candidates measured, for the decision that is not this unit's to take

Measured in one loop so every candidate saw the same 200 seconds of the same
host under the same load. Command and log:

```
PROBE_SECONDS=200 elixir tmp/v1/02c/step0-candidates.exs
```

`tmp/v1/02c/logs/step0-candidates.log`.

200 seconds, 24 loaders, 81,972,279 samples of each reading,
2026-09-14T11:50:49Z to 2026-09-14T11:54:02Z.

| Reading | Backwards steps | Largest backwards step | Max drift vs `System.os_time/1` | Cost per call |
|---|---|---|---|---|
| `DateTime.utc_now/0` | 6 | 1.248315 s | (reference) | 323.4 ns |
| `System.os_time/1` | 6 | 1.248311 s | (reference) | 28.0 ns |
| `System.system_time/1` | 3 | 2.306986 s | 2.311672 s | 31.3 ns |
| `System.monotonic_time/1` | 0 | 0 s | n/a | 29.3 ns |
| **R5** frozen offset + monotonic | **0** | **0 s** | **7.057859 s** | 30.9 ns |
| **R6** clamped system time (`max(system_time, last)`) | **0** | **0 s** | **2.312056 s** | 50.5 ns |

R5 is `base_system_time + (monotonic_now - base_monotonic)` with the offset
captured once at boot. R6 is `System.system_time/1` passed through an
`:atomics` cell that never lets the returned value decrease. Costs were measured
with the loaders killed, 1,000,000 calls each, `:timer.tc/1`. The per-call cost
of a full `DateTime` (323 ns for `DateTime.utc_now/0`) dwarfs the difference
between the integer readings, so the conversion, not the reading, is what
`track/4` pays for.

### The mechanism, isolated

The same script run with the VM's time warp mode changed, same host, same load,
200 seconds each:

| `+C` mode | `System.system_time/1` backwards steps | `System.os_time/1` backwards steps | Log |
|---|---|---|---|
| `multi_time_warp` (OTP 29 default, nothing set) | 6 in 420 s / 3 in 200 s | 13 in 420 s / 6 in 200 s | `step0-clock.log`, `step0-candidates.log` |
| `no_time_warp` | **0** | 6 | `tmp/v1/02c/logs/step0-no-time-warp.log` |
| `single_time_warp` | **0** | 6 | `tmp/v1/02c/logs/step0-single-time-warp.log` |

That is conclusive. The OS clock on this host misbehaves in all three modes
(6 backwards steps of roughly 1.0 to 1.25 s per 200 seconds under load, the WSL2
pathology 01d found). Erlang system time follows it backwards **only** in
`multi_time_warp`, where the runtime resyncs its time offset every 60 seconds.
In `no_time_warp` and `single_time_warp` the offset is fixed after start-up, so
Erlang system time is monotonic time plus a constant and cannot decrease. The
plan's premise was true for the mode OTP used to default to and is false for the
mode OTP 29 defaults to.

Note the equivalence: `no_time_warp` is R5 enforced by the VM. Both buy
"never backwards" with unbounded drift away from the OS wall clock on a host
whose clock is *stepped*, and both cost nothing at all on a host whose clock is
*slewed* by NTP, where `os_time` never moves backwards in the first place.

### The options, with what each costs

| | Guarantee | Drift from real time | Hot-path cost | Objection |
|---|---|---|---|---|
| Keep `DateTime.utc_now/0` | none | none | 323 ns | This is C11/B01/L20 unfixed. |
| `System.system_time/1` (the plan) | none on OTP 29 defaults | bounded | 31 ns + conversion | Refuted above. |
| Require `+C no_time_warp` in the host's `vm.args` | non-decreasing, VM enforced | unbounded on a stepped clock | 31 ns + conversion | A new runtime requirement a library cannot enforce, against D12. Also silently absent on any host that forgets. |
| R5: freeze the offset at boot, add monotonic | non-decreasing by construction | unbounded (7.06 s per 200 s here) | 31 ns + conversion | A long-lived node never re-syncs; timestamps written to the database would drift from every other system's idea of the time. |
| R6: clamp `System.system_time/1` so it never decreases | non-decreasing by construction | bounded by one backwards correction (2.31 s here) | 51 ns + conversion | Per node only; a spurious *forward* jump is adopted permanently and pins the clock until real time catches up; needs a correct CAS retry under concurrency (the probe's version is single process). |
| Do not claim a non-decreasing wall clock at all | none | none | 323 ns | Ordering moves to the database (`seq`, which is already L20's binding resolution in 06a) and every in-memory elapsed span moves to `monotonic_ms/0`, which this unit already provides. `now/0` stays honestly wall-clock shaped. B01's `in_cooldown?/1` then needs its own answer (clamp a negative diff at zero, or compare against the database's `now()`). |

The last row deserves weight rather than dismissal: a per-node monotone wall
clock does nothing about two nodes disagreeing, and L20's resolution has already
moved ledger ordering onto a database sequence. What a monotone `now/0` actually
buys is the single-node "has enough time elapsed since this persisted instant"
question, which is B01.

## The decision, and why the two candidates were not taken

Taken by the owner on **2026-09-14**, after the unit stopped and reported.
`architecture-map.md` section 3 and this unit's section 1 were amended to match.

**Neither R5 nor R6 was chosen.** Both make a *node's* clock non-decreasing, and
that was the wrong shape of answer:

- A per-node monotone clock does nothing about **two nodes disagreeing**, which
  is the deployment that matters. Both defects it was meant to close (B01's
  cooldown, L20's ledger ordering) are about two clocks disagreeing, not about
  one clock moving.
- L20's resolution had already moved ordering onto `seq`
  (`architecture-map.md` 7.1), so "ordering needs a monotone clock" was not a
  live requirement any more. **Ordering never takes a clock at all.**
- R5 buys monotonicity with unbounded drift (7.06 s per 200 s on this host), and
  a long-lived node would never re-sync. R6 is cheap and bounded but is still
  per-node, and a spurious *forward* jump is adopted permanently, pinning the
  clock until real time catches up.

**`+C no_time_warp` was not chosen either**, and the reason generalises: **a VM
flag cannot be a library's remedy.** The host owns `+C`. Aurora Meter is a
dependency in someone else's release; it cannot set the flag, cannot check it at
compile time in any useful way, and a host that forgets it gets the defect back
silently. It is worse than that: `multi_time_warp` is the **OTP 29 default**, so
the flag would have to be actively added by every user of the library, forever,
against the grain of the platform. A correctness property that depends on a
deployment flag nobody sets is not a correctness property. The `no_time_warp`
and `single_time_warp` runs above are a **diagnosis**, which is what isolated the
mechanism; they are not a fix.

**What was chosen instead: the database clock for money.** `AuroraMeter.Clock`
gains a fourth reading, `db_now/0`, and the rule becomes *stamp and compare with
the same clock, and for anything persisted that clock is the database's.*
`now/0` stays `System.system_time/1`, chosen for **cost alone** (237.62 ns
against 323 ns for `DateTime.utc_now/0`, and `track/4` reads it on every
increment) with its contract stating that it promises nothing about
monotonicity, which is the honest thing to say about any wall clock. The full
inventory of comparisons, both halves of the rule, the cost of the round trip and
the B01 fix are in `02c-db-clock.md`.

The measurement that forced this is the one at the top of this file. Its lesson
is not "System.system_time is bad": it is that **a seam is only worth as much as
the primitive under it, and the primitive has to be measured, for minutes, before
anything is built on it.**
