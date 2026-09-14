# 02c: the database clock, and every comparison against a persisted timestamp

The owner's decision on 2026-09-14, after step 0 refuted both proposed
wall-clock bases (`02c-clock-choice.md`): **stamp and compare with the same
clock, and for anything persisted that clock is the database's.**

`AuroraMeter.Clock` gained a fourth reading, `db_now/0`
(`SELECT clock_timestamp() AT TIME ZONE 'UTC'` through `Config.repo()`). This
file is the inventory the acceptance criteria ask for: every decision in either
package that compares against a persisted timestamp, with the clock on each side
named, before and after. It is also where build unit **04b** should start, since
it inherits two of these call sites.

## The rule as implemented

Two halves, and a partial fix is worse than none because the mismatch then gets
harder to see.

1. **Comparison.** A decision that compares "now" against a timestamp read out of
   a row takes `Clock.db_now/0`.
2. **Stamping.** That row's timestamp is written **by the database**, with a
   `fragment("date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC')")` in
   the insert or update. Not read into Elixir with `db_now/0` and written back:
   that is one more round trip and, worse, it leaves the guarantee resting on
   every future caller remembering the right function.

`date_trunc('second', ...)` because the columns are `:utc_datetime`, which is
what the `DateTime.truncate(:second)` it replaced produced. `AT TIME ZONE 'UTC'`
because they are `timestamp without time zone` columns, so the conversion must
not depend on the session's `TimeZone` setting.

`clock_timestamp()` and not `now()`: `now()` is the transaction's start time and
returns the same instant for every call inside one transaction, which is exactly
wrong for "has enough time passed". `AuroraMeter.ClockTest` asserts the
difference against a real connection.

## The inventory

### Comparisons that now take `db_now/0`

| Decision | Compared against | Was | Now | Stamped by |
|---|---|---|---|---|
| `in_cooldown?/1`, `pro/credits/auto_top_up_worker.ex` | `credit_accounts.last_attempt_at` | `DateTime.utc_now/0` | `Clock.db_now/0` | the database (`mark_attempt/2`, `touch_attempt/1`) |
| `resume/1`'s 23 hour uncertainty horizon, same file | `credit_accounts.pending_started_at` | `DateTime.utc_now/0` | `Clock.db_now/0` | the database (`mark_attempt/2`) |
| `deliver/1`'s 23 hour horizon, `pro/usage_reporter.ex` | `usage_reports.pending_since` | `DateTime.utc_now/0` | `Clock.db_now/0` | the database (`report_one/5`) |
| `AuroraMeter.Credits.expire_due/0`'s default `now` | `credit_transactions.expires_at` | `DateTime.utc_now/0` | `Clock.db_now/0` | the **host**, deliberately: `expires_at` is a future instant the caller chose at grant time, not a stamp of when something happened. There is nothing to fix on the stamping side; what matters is that every node running expiry agrees on "now". |

The first three are the ones B01 named. They are now the same shape: one clock
on both sides, and the stamp written where a caller cannot get it wrong.

### Comparisons that deliberately do **not** take `db_now/0`

Recorded with the reason, so a later reader can disagree with the reason rather
than guess at the omission.

| Site | Compared against | Clock | Why not `db_now/0` |
|---|---|---|---|
| `pro/credits.ex` `recent?/1` (the grant race window) | Stripe's `created`, a **provider** timestamp | `Clock.now/0` as unix seconds | There is no way to make Stripe stamp with our database. Both sides cannot be one clock here, and the database's clock is no closer to Stripe's than the node's. Provider clock skew is 04b's to reason about. |
| `pro/credits.ex` `newer_card_event?/3` | `credit_accounts.payment_method_saved_at` vs Stripe's `created` | `Clock.now/0` at the settings-edit write | Same reason, and the webhook path already stamps that column from Stripe's own `created` (`payment_created_at/1`). Making it database-stamped would put *two* clocks on that comparison rather than one. Flagged for 06e. |
| `pro/webhook.ex` signature tolerance | Stripe's signature timestamp | `Clock.now/0` as unix seconds | Provider timestamp again, and the tolerance is minutes wide. |
| `pro/usage_reporter.ex` 70 day lookback (two sites) | `counters.period_start`, `subscriptions.current_period_end` | `Clock.now/0` | A selection window, not a decision about a row: it chooses which periods to look at, and a second of clock error changes nothing. Both sides are node-stamped or period boundaries. |
| `pro/rollup.ex` `since`, `pro/reconcile.ex` `since`, `pro/audit_log.ex` prune cutoff | `inserted_at` columns | `Clock.now/0` / `Clock.today/0` | Same: windowing for reporting and retention. `architecture-map.md` section 3 assigns `inserted_at` to `now/0`, so using `db_now/0` for the cutoff would introduce the two-clock comparison rather than remove one. |
| `AuroraMeter.Credits.pending_holds/1`'s `older_than` (a host argument) | `credit_transactions.inserted_at` | the host's choice; the `@doc` example uses `Clock.now/0` | Both sides node-stamped today. Build unit **05b** owns hold reconciliation and should decide whether hold rows become database-stamped; until then, matching the stamp is the consistent answer. |
| `Period.current!/2`'s containment check | the period the source computed, in memory | `Clock.now/0` | Nothing persisted is involved: it compares a computed boundary with the instant it was asked about. |

## Why the comparison side is `db_now/0` and not a SQL predicate

The stronger pattern in general is to push the comparison into the query that is
already happening (`WHERE last_attempt_at <= clock_timestamp() - interval '...'`),
so stamp and compare share a clock by construction with no round trip added. It
was considered and it does not fit these call sites.

`in_cooldown?/1` and the 23 hour check both operate on a `%CreditAccount{}`
already loaded in memory, inside a `cond` whose branches the caller
distinguishes (`{:skip, :cooldown}` against
`{:error, :payment_reconciliation_required}`). Turning that into a query means
restructuring the worker's control flow and reconstructing those branches from
what the query returned, which is a larger and riskier change than the one it
replaces. It belongs to **04b**, which is rewriting that state machine anyway.
The round trip is also nearly free in context: the worker is already doing a
database update and a Stripe call.

**04b: this is why, so you need not relitigate it.** If the `cond` becomes a
state machine driven by a query, the SQL predicate is the better answer and
`db_now/0` can go away at those two sites.

## Cost

`db_now/0` is a round trip. Measured on the same host and toolchain as the other
clock readings (`02c-validation-cost.md` has the machine and the method), with a
warm connection from the pool:

| Reading | Median, per call |
|---|---|
| `Clock.now/0` | **237.62 ns** |
| `Clock.System.db_now/0` (warm pool, local Postgres) | **371.68 us** |

Five runs of 1,000 `db_now/0` calls: 389,637, 427,063, 346,241, 371,683 and
349,065 us. `tmp/v1/02c/logs/validation-cost.txt`, 2026-09-14T12:52:52Z, exit 0.
The connection pool was warmed first, so this is the steady-state cost of a round
trip to a Postgres on the same machine; a network hop makes it worse, not better.

`db_now/0` is therefore about **1,560 times** the cost of `now/0`, which is
exactly why **P08** exists: it appears nowhere on the
`track/4`, `check/2`, `reserve/2,3` or `with_quota/3,4` path, and both packages'
suites assert that as a source-level audit rather than by inspection
(`AuroraMeter.ClockTest` "P08 db_now/0 appears in no module on the hot path" and
`AuroraMeter.Pro.ClockAuditTest` "P08 db_now/0 is absent from Pro's metering
path"). The two callers are an Oban worker holding an advisory lock and about to
call Stripe, and the usage reporter after its flush.

## B01: the workaround removed, and what replaced it

01d could not fix B01 (it modified no `lib/` file), so it worked around it in the
test suite: every test that wanted "no cooldown" asked for `-86_400` seconds
rather than `0`, because at `0` the predicate reduced to "is `last_attempt_at` in
the future", which is what a backward step of the node clock leaves behind. 01d
said in three places that this was a workaround and not a fix.

All three are gone:

| Place | Was | Now |
|---|---|---|
| `pro/credits/pending_payment_test.exs`, the `@no_cooldown` constant | `-86_400` with a paragraph explaining the workaround | `0`, with a paragraph explaining the fix |
| `pro/credits/auto_top_up_worker_test.exs`, the same constant | `-86_400` | `0` |
| `docs/correctness.md`'s B01 entry | "every timing guard ... compares two wall clock instants", owner 02c | the fix, both halves, with the tests that keep it |

`test I15 a zero cooldown is defeated by a backward clock step (B01, fixed in
02c)` documented the defect by setting `last_attempt_at` two seconds into the
future and asserting the worker refused. It is replaced by two tests that prove
the fix instead:

- **`test I15 the cooldown boundary is decided by the database clock (B01)`**
  drives the boundary in both directions with the clock frozen: at
  `last_attempt_at + 599` with a 600 second cooldown the attempt is refused
  (`{:cancel, :cooldown}`, nothing charged, no call to the Stripe fake); at
  `last_attempt_at + 600` it goes through and the balance moves by 25 dollars.
  `Clock.Fixed` answers `db_now/0` from the frozen instant, which is what makes a
  database-clock decision testable at all, and is why `db_now/0` is a callback on
  the behaviour rather than a bare query helper.
- **`test I15 last_attempt_at is stamped by the database, not by the node clock`**
  freezes the node clock at `2001-01-01T00:00:00Z`, runs a successful attempt,
  and asserts the stamp the worker wrote is bracketed by two real
  `Clock.System.db_now/0` readings taken outside the frozen block. A node-clock
  stamp would have written 2001. This is the half a convention cannot guarantee.

One further test closes the gap the fake opens: because `Clock.Fixed` answers
`db_now/0` from the frozen instant, every frozen test stops exercising the query.
`AuroraMeter.ClockTest`'s "db_now/0 against the real database" block calls
`AuroraMeter.Clock.System.db_now/0` directly and checks that it returns UTC with
microsecond precision, agrees with the node clock to within seconds, advances
inside one transaction, and raises an `ArgumentError` naming the `repo` key when
no repo is configured.

## What this does not claim

`db_now/0` does not make the database's clock perfect: that host's clock can be
corrected too, and a 1.3 second backward step there is as possible as it is on an
application node. What it removes is the *skew between two clocks*, which is the
class of defect B01 and L20 both were, and it leaves one operationally managed
clock in its place. `docs/periods.md` says this rather than overclaiming.

Ordering still never takes a clock at all. It takes `seq`
(`architecture-map.md` 7.1), which is L20's resolution and is not reopened here.
