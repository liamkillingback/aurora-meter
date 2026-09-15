# 06d: the clock boundary

Build unit 06d, V1 task 06.05, gate G06 bullet 6 ("clock boundary"). Raw output:
`logs/06d-evidence.txt`, section "06d-boundary", and
`test/aurora_meter/credits_recurrences_test.exs` / `test I18 a run one
microsecond before the boundary grants the old period, and at it the new`.

Both runs use `AuroraMeter.Clock.Fixed` through `AuroraMeter.Test.with_clock/2`,
which answers all four clock readings from one frozen instant, `db_now/0`
included. One tenant on plan `:allowance`.

## The two runs

| frozen instant | period the source resolved | granted | rollover |
|---|---|---|---|
| `2026-09-30T23:59:59.999999Z` | `[2026-09-01T00:00:00Z, 2026-10-01T00:00:00Z)` | 1 | 0 |
| `2026-10-01T00:00:00.000000Z` | `[2026-10-01T00:00:00Z, 2026-11-01T00:00:00Z)` | 1 | 1,000,000 |

Recurrence rows afterwards: `2026-09-01`, `2026-10-01`. Two rows, one per period,
neither granted twice and neither skipped.

Lots afterwards:

| reference | amount | available | expired |
|---|---|---|---|
| `recurring:...:2026-09-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 |
| `recurring:...:2026-10-01T00:00:00Z` | 5,000,000 | 5,000,000 | 0 |
| `recurring:...:2026-10-01T00:00:00Z:rollover` | 1,000,000 | 1,000,000 | 0 |

One microsecond of wall clock separates the two runs and they land on opposite
sides of the boundary: the first grants September and carries nothing (nothing
precedes it), the second grants October, expires September in full and carries
the capped 1,000,000 across.

## Which clock decided what

This is the part the boundary case is really about, and the two readings are
deliberately different (`architecture-map.md` section 3).

**The period came from `Clock.now/0`.** "What period is it now" is a wall-clock
question: the answer is compared against nothing that this database stamped, and
`Period.current!/2` validates that the interval contains the instant it was
asked about. `Recurrences.run/1` reads it once per run and hands the same
instant to every tenant in the run, so two tenants in one run cannot land on
opposite sides of a boundary.

**Every decision inside a transaction came from `Clock.db_now/0`.** The lot's
`granted_at`, the eligibility test that keeps a historical lot out of
`spendable`, and the recurrence row's `inserted_at` are all read from
`Ledger.lot_instant/0`, which is `Clock.db_now/0`. Each is compared against a
column this database wrote, so both sides of every comparison come from the same
clock.

**Ordering took no clock at all.** Periods are ordered by `period_start`, which
is a boundary the period source computed from an instant rather than a reading of
one, and the query that finds a tenant's newest period orders by that column.
The ledger rows are ordered by `seq`. Neither can be inverted by the 439 ms
backwards step X100 measured in `clock_timestamp()`, and neither would be
affected by a larger one.

**The duration this unit relies on is a period, not a lease.** The only
comparison of two instants is "has this lot's `expires_at` passed", at a scale
of weeks. A backwards step of a second at a month boundary changes nothing; and
where the unit needs mutual exclusion it takes the balance row's `FOR UPDATE`
and a unique index, neither of which has a clock in it.

## What a test would have proved without the fixed clock

Nothing. `mix test` ran on 2026-09-15, inside the September period: a boundary
test using the real clock could not have stood on the October side of it at all,
and would have asserted the same thing twice. That is why 02c's clock seam is a
hard dependency of this unit rather than a convenience.
