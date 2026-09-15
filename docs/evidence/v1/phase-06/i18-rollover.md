# I18: capped rollover over six periods

Build unit 06d, V1 task 06.05. Raw output: `logs/06d-evidence.txt`, section
"i18-rollover"; produced by `tmp/v1/06d_evidence.exs` through
`tmp/v1/06d-evidence.sh` on 2026-09-15, core `011ac34` plus 06d's working tree,
Postgres 16.13, Elixir 1.20.1 / OTP 29.

One tenant on plan `:allowance`: `recurring_credits :monthly, amount: 5_000_000,
rollover: 1_000_000, expires: :period_end`. One run per month at the 15th, with
the spend shown taken immediately after the run. All amounts are micro-dollars.

## The six periods

| period | granted | carried in | spendable after the run | spent | unused at the end | carried out | destroyed |
|---|---|---|---|---|---|---|---|
| 2026-05 | 5,000,000 | 0 (no period before it) | 5,000,000 | 0 | 5,000,000 | 1,000,000 | 4,000,000 |
| 2026-06 | 5,000,000 | 1,000,000 | 6,000,000 | 5,000,000 | 1,000,000 | 1,000,000 | 0 |
| 2026-07 | 5,000,000 | 1,000,000 | 6,000,000 | 4,000,000 | 2,000,000 | 1,000,000 | 1,000,000 |
| 2026-08 | 5,000,000 | 1,000,000 | 6,000,000 | 0 | 6,000,000 | 1,000,000 | 5,000,000 |
| 2026-09 | 5,000,000 | 1,000,000 | 6,000,000 | 0 | 6,000,000 | 1,000,000 | 5,000,000 |
| 2026-10 | 5,000,000 | 1,000,000 | 6,000,000 | 0 | 6,000,000 | (still live) | (still live) |

"carried in" is the run's own `counts["rollover"]`; "carried out" is the next
row's "carried in". The five cases the unit document asks for are all here:
a period with nothing before it (May), a fully spent period (June), a partly
spent period whose remainder is **below** the cap (July), a period where the cap
binds (August), and **two consecutive idle periods** (August and September),
which carry 1,000,000 each and never 2,000,000.

## Every lot the tenant ended with

Read from `aurora_meter_credit_lots` in `seq` order. The tenant prefix is
stripped from the reference for width; it is
`recurring:<tenant_key>:monthly:allowance:1:<period start>`.

| seq | reference | amount | available | consumed | expired | expires_at | state |
|---|---|---|---|---|---|---|---|
| 34205 | `...:2026-05-01T00:00:00Z` | 5,000,000 | 0 | 0 | 5,000,000 | 2026-06-01 | expired |
| 34206 | `...:2026-06-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 | 0 | 2026-07-01 | exhausted |
| 34207 | `...:2026-06-01T00:00:00Z:rollover` | 1,000,000 | 0 | 0 | 1,000,000 | 2026-07-01 | expired |
| 34208 | `...:2026-07-01T00:00:00Z` | 5,000,000 | 0 | 4,000,000 | 1,000,000 | 2026-08-01 | expired |
| 34209 | `...:2026-07-01T00:00:00Z:rollover` | 1,000,000 | 0 | 0 | 1,000,000 | 2026-08-01 | expired |
| 34210 | `...:2026-08-01T00:00:00Z` | 5,000,000 | 0 | 0 | 5,000,000 | 2026-09-01 | expired |
| 34211 | `...:2026-08-01T00:00:00Z:rollover` | 1,000,000 | 0 | 0 | 1,000,000 | 2026-09-01 | expired |
| 34212 | `...:2026-09-01T00:00:00Z` | 5,000,000 | 0 | 0 | 5,000,000 | 2026-10-01 | expired |
| 34213 | `...:2026-09-01T00:00:00Z:rollover` | 1,000,000 | 0 | 0 | 1,000,000 | 2026-10-01 | expired |
| 34214 | `...:2026-10-01T00:00:00Z` | 5,000,000 | 5,000,000 | 0 | 0 | 2026-11-01 | open |
| 34215 | `...:2026-10-01T00:00:00Z:rollover` | 1,000,000 | 1,000,000 | 0 | 0 | 2026-11-01 | open |

Final balance row: `available 6,000,000`, `expired 20,000,000`, `debt 0`,
`promotional_spendable 6,000,000`. Six recurrence rows, five of them naming a
`rollover_from_id`, the first (May) naming none.

## What each number proves

**The cap binds, and the cap is the thing that stops compounding.** June holds
6,000,000 (its allowance plus May's carry) and passes on 1,000,000. August and
September each hold 6,000,000 unused and each pass on 1,000,000. If the cap were
applied per lot rather than to the previous period as a whole, an idle period
would pass on 1,000,000 from its allowance **and** 1,000,000 from its carried
lot, and October would hold 7,000,000. It holds 6,000,000.

**A rollover is a grant, not a transfer.** Every carried lot has its own row,
its own reference (`...:rollover`), its own `granted_at` and its own allocation
trail; the previous period's lot expires in full. June's 5,000,000 allowance
was spent, so it is `exhausted` with `expired 0`; its carried lot was untouched
and is `expired 1,000,000`. That split is what makes the carry 1,000,000 and not
0: the unused figure is `available + expired` over **both** of the period's
lots, so a period that spent its allowance and left its carry alone still has
something to pass on.

**Criterion 4, both halves, from the rows above.** July spent 4,000,000 of an
allowance of 5,000,000: its allowance lot ends `consumed 4,000,000,
available 0, expired 1,000,000`, the carry is 1,000,000, and nothing is
destroyed beyond it (`expired - carried = 0`). August spent nothing: its
allowance lot ends `expired 5,000,000`, the carry is 1,000,000, and 4,000,000 is
destroyed net of the carry. The criterion's "4,000,000 expired" is that second
number; the lot's own `expired` bucket reads 5,000,000, because the carry is a
new lot rather than a piece of the old one left behind.

## The negative control

`logs/06d-controls.log`, control A. The cap is read from the **compiled plan**
instead of the previous period's stored policy snapshot, and nothing else
changes. One test fails and it is the right one:

```
1) test I18 a plan edited between two periods grants the new amount and keeps the old cap
   assert summary.counts["rollover"] == @cap
   left:  3000000
   right: 1000000
```

29 of 30 pass with the control in place, 30 of 30 after the file is restored
(sha256 `2802dd90f3cfdd570b6f2604eb132338864a3e39b1ebb85d490a68c9d8fdba5c` either
side). So the snapshot is load-bearing: it is what makes a plan whose cap rose
from 1,000,000 to 3,000,000 between two periods carry the **old** cap out of the
period that was issued under it.

Worth stating plainly, because it is the part that surprised this unit: the
**amount** snapshot is not load-bearing in the same way. The recurrence row and
its grant commit in one transaction, so a retry can never re-grant at any
amount; the snapshot of the amount is defence in depth and an audit record. The
cap is the field a later period actually reads, and it is the one the control
had to move.
