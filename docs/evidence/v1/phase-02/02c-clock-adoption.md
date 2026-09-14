# 02c: every clock read in core `lib/`, before and after

Both packages. Pro's half is at the bottom; its own evidence file is
`aurora_meter_pro/docs/evidence/v1/phase-02/02c-pro-period.md`.

## Before

Found with:

```
grep -rnE "DateTime\.utc_now\(\)|Date\.utc_today\(\)|System\.os_time|System\.system_time|System\.monotonic_time|:timer\.tc" aurora_meter/lib
```

| Core site (at `6ea3a6e`) | Reading | What it timestamps | Now |
|---|---|---|---|
| `aurora_meter.ex:122` | `Date.utc_today()` | default `:to` date for `history/3` | `Clock.today()` |
| `counter.ex:63` | `Date.utc_today()` | day bucket for `incr/4` | `Clock.today()` |
| `counter.ex:83` | `Date.utc_today()` | day bucket for a non-deferred `reserve/6` | `Clock.today()` |
| `counter.ex:131` | `Date.utc_today()` | day bucket for `release/5` when no date is given | `Clock.today()` |
| `credits.ex:353` | `DateTime.utc_now()` | **a `@doc` example**, not code (the plan's table called it the pending-hold sweep default) | `AuroraMeter.Clock.now()`, fully qualified because a host copies it |
| `credits.ex:577` | `Date.utc_today()` | default `to` date for `spend_history/2` | `Clock.today()` |
| `credits.ex:631` | `DateTime.utc_now()` | default `now` for `expire_due/1` | `Clock.now()` |
| `credits/ledger.ex:411` | `DateTime.utc_now()` | `inserted_at`/`updated_at` on a new balance row | `Clock.now()` |
| `credits/ledger.ex:452` | `DateTime.utc_now()` | `inserted_at` on every ledger entry | `Clock.now()` |
| `credits/series.ex:56` | `Date.utc_today()` | default `to` date for the money series | `Clock.today()` |
| `entitlements.ex:280` | `Date.utc_today()` | the day captured by `with_quota/4` (`on`) | `Clock.today()` |
| `period.ex:27` | `DateTime.utc_now()` | default `now` for `Period.current/2` | `Clock.now()` |
| `storage/ecto.ex:23` | `DateTime.utc_now()` | flush receipt `inserted_at` | `Clock.now()` |
| `storage/ecto.ex:59` | `DateTime.utc_now()` | `upsert_counters/1` row timestamps | `Clock.now()` |
| `storage/ecto.ex:83` | `DateTime.utc_now()` | `add_counters/1` row timestamps | `Clock.now()` |
| `storage/ecto.ex:125` | `DateTime.utc_now()` | `add_history/1` row timestamps | `Clock.now()` |
| `storage/ecto.ex:177` | `DateTime.utc_now()` | `upsert_history/1` row timestamps | `Clock.now()` |
| `storage/ecto.ex:245` | `DateTime.utc_now()` | event row `inserted_at` (`insert_events/1`) | `Clock.now()` |

### Two sites the build document's tables did not list

The plan's tables were compiled from `DateTime.utc_now()` and `Date.utc_today()`
only. The wave 1b correction added `monotonic_ms/0` and widened the audit to
`System.os_time`, `System.system_time`, `System.monotonic_time` and `:timer.tc`,
which finds two more in core, both genuine in-memory elapsed spans and therefore
exactly what P07 is about:

| Core site | Reading | What it measures | Now |
|---|---|---|---|
| `subscriptions.ex:39` | `System.monotonic_time(:millisecond)` | the subscription cache TTL | `Clock.monotonic_ms()` |
| `lib/mix/tasks/aurora_meter.bench.ex:42` | `:timer.tc/1` | the benchmark's own elapsed span | `Clock.monotonic_ms()` |

`aurora_meter.bench.ex` is not on the plan's "Core files edited" list. It is
under `lib/`, so the acceptance criterion's grep covers it; the change is the
clock seam only and its elapsed figure moves from microsecond to millisecond
resolution (the benchmark runs for seconds). Build unit 08c owns this task's
numbers and `open-findings.md` C7 is still open against it.

## Pro

The plan's Pro table listed 15 `DateTime.utc_now()` / `Date.utc_today()` sites.
All of them moved to `AuroraMeter.Clock`, except the one documented exception.
The widened audit found five more that the table did not list (X61), all of them
genuine:

| Pro site | Reading | What it is | Now |
|---|---|---|---|
| `pro/plugs/audit_log.ex:79` and `:134` | `System.monotonic_time()` (native) | a request's elapsed span, in memory | `Clock.monotonic_ms()` |
| `pro/usage_reporter.ex:117` | `System.system_time(:second)` | the timestamp inside a Stripe meter-event payload | `DateTime.to_unix(Clock.now(), :second)` |
| `pro/webhook.ex:177` | `System.system_time(:second)` | the signature tolerance check against Stripe's own timestamp | `DateTime.to_unix(Clock.now(), :second)` |
| `pro/credits.ex:521` | `System.system_time(:second)` | the grant race window against Stripe's `created` | `DateTime.to_unix(Clock.now(), :second)` |

The four money-decision sites did not merely change source, they changed
**basis**: `in_cooldown?/1`, `resume/1`'s 23 hour horizon, `deliver/1`'s 23 hour
horizon and the columns they read. Those are in `02c-db-clock.md`.

Pro adds **no clock configuration of its own**: it consumes
`AuroraMeter.Clock` through the core seam, which is what
`free-pro-boundary.md` section 2 permits, and
`AuroraMeter.Pro.ClockAuditTest` asserts that `pro/config.ex` mentions no clock
key at all.

## After

```
$ bash tmp/v1/02c/audit.sh
=== core lib only ===
clean

$ grep -rnE "DateTime\.utc_now\(\)|Date\.utc_today\(\)|System\.os_time|System\.system_time|System\.monotonic_time|:timer\.tc" \
    aurora_meter/lib aurora_meter_pro/lib \
  | grep -v 'aurora_meter/lib/aurora_meter/clock.ex' \
  | grep -v 'aurora_meter_pro/lib/aurora_meter/pro/audit_log.ex:181'
clean
```

**One documented exception, in Pro:** `lib/aurora_meter/pro/audit_log.ex:181`
(`:180` before this unit's edits shifted it by one), inside a `@doc` example:

```elixir
AuroraMeter.Pro.AuditLog.stats(org, from: DateTime.add(DateTime.utc_now(), -86_400))
```

It is written source that a reader copies out of the generated documentation,
not code that runs, and it shows a host what a host would write. Core has **no**
exception: the equivalent `@doc` example at `credits.ex:353` was moved onto
`AuroraMeter.Clock.now()` instead, because `Clock` is core's own public API and
the example then also works under a frozen clock.

The same audits run inside **both** suites, so a new clock read fails the tests
rather than waiting for someone to remember the grep:
`AuroraMeter.ClockTest` ("P07 no module in lib/ reads a clock outside
AuroraMeter.Clock", "P06 no lib/ code compares a node-clock reading against
another instant", "P08 db_now/0 appears in no module on the hot path") and
`AuroraMeter.Pro.ClockAuditTest` (the same three, plus one asserting that every
`db_now/0` comparison is against a column stamped by a `clock_timestamp()`
fragment in the same file).

## What the seam is worth, and what it is not

`Clock.System.today/0` is `DateTime.to_date(now())`, so the date and the instant
come from one reading. That closes the two-clock-reads window at `counter.ex:63`
by construction, which is invariant P03 and is proven by
`test/aurora_meter/metering_test.exs`, "P03 incr/4's day bucket is the date of
the same clock read as the period".

What the seam does **not** give is a `now/0` that cannot go backwards. No wall
clock does. `02c-clock-choice.md` has the measurement and `02c-db-clock.md` has
what was done about it instead.
