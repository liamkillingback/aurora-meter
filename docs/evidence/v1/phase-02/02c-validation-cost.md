# 02c: what validating the period on every call costs

**No budget is asserted here.** Build unit `08c` owns budgets and benchmarking.
This file records two numbers and the conditions they were measured under, which
is what the plan asked for: the cost is measured rather than assumed, so that if
`08c` later finds the check dominating `track/4` there is a number to compare
against and a named remedy to reach for.

## Conditions

| | |
|---|---|
| Machine | `DESKTOP-8R659B3`, WSL2, 24 logical processors, otherwise idle |
| Toolchain | Elixir 1.20.1, OTP 29 (erts 17.0.1), `MIX_ENV=test` |
| `period_source` | `AuroraMeter.Period.Calendar` (the default) |
| `clock` | `AuroraMeter.Clock.System` |
| Method | `:timer.tc/1` around `Enum.each(1..100_000, ...)`, 5 runs, median reported, every path warmed first (1,000 calls, and 100 for the round trip) |
| Command | `mix run` on a throwaway script, deleted afterwards |
| Log | `tmp/v1/02c/logs/validation-cost.txt`, 2026-09-14T12:52:52Z, exit 0 |

## The numbers

| Run | `Period.current/2` 100k | `Period.current!/2` 100k | `Clock.now/0` 100k | `Clock.System.db_now/0` 1k |
|---|---|---|---|---|
| 1 | 69,667 us | 115,292 us | 25,832 us | 389,637 us |
| 2 | 70,894 us | 138,255 us | 26,484 us | 427,063 us |
| 3 | 72,845 us | 116,909 us | 23,762 us | 346,241 us |
| 4 | 68,869 us | 112,911 us | 23,259 us | 371,683 us |
| 5 | 68,380 us | 113,675 us | 23,187 us | 349,065 us |

Medians, per call:

| | per call |
|---|---|
| `Period.current/2` (unvalidated) | **696.67 ns** |
| `Period.current!/2` (validated) | **1152.92 ns** |
| `AuroraMeter.Clock.now/0` alone | 237.62 ns |
| `AuroraMeter.Clock.System.db_now/0` (a round trip) | **371.68 us** |
| **validation only** | **456.25 ns**, i.e. **+65%** on the period read |

`db_now/0` is about **1,560 times** `now/0`. That is the number behind invariant
P08 ("`db_now/0` appears nowhere on the hot path"), and it is why the decision
that money decisions take the database's clock did **not** also move `now/0`
onto it. `02c-db-clock.md` carries the full reasoning and the audits that
enforce it.

## What that says

The plan's section 3 predicted "six comparisons with no allocation". The
comparisons are not free: `DateTime.compare/2` converts both operands before
comparing, so three of them cost roughly 456 ns between them, which is more than
half of what resolving the calendar period costs in the first place and about
1.9 times what reading the clock costs.

Perspective, all per call on the `track/4` path: clock read 238 ns, calendar
period resolution about 459 ns on top of that, validation 456 ns on top of that.
`track/4` then does its ETS work on top of all three. This is not a pathology,
but it is not free either, and "six comparisons" understated it.

The named remedy, if `08c` needs one, is unchanged and has no API impact: memoise
per `{source, tenant_key}` keyed on the period's `end` and revalidate only when
`now >= end`. It is deliberately not implemented now, because caching a
validation result is only worth its complexity against a measured number, and
this is the measured number.

A cheaper option that did not exist when the plan was written also falls out of
these figures: both operands are known to be `Etc/UTC` by the time rules 3 and 4
run, so the three `DateTime.compare/2` calls could compare a cheaper
representation instead. That is an optimisation, it is `08c`'s to take or leave,
and it was not done here.

## Why `now/0` is `System.system_time/1` and not `DateTime.utc_now/0`

Cost, and only cost. The integer readings measured in `02c-clock-choice.md` are
28.0 ns for `System.os_time/1`, 31.3 ns for `System.system_time/1` and 323.4 ns
for `DateTime.utc_now/0`, which builds a full `DateTime` on every call. Wrapping
the integer in a `DateTime` brings `Clock.now/0` to the 237.62 ns above, still
appreciably under `DateTime.utc_now/0`, on a function `track/4` calls on every
increment.

Neither is monotone, so nothing about correctness rides on the choice: that is
what `db_now/0` is for. The contract says so in those words rather than leaving
a reader to assume the cheaper one is also the safer one.
