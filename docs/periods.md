# Periods, boundaries and the clock

Every counter Aurora Meter keeps is a counter *for a period*. This page is the
contract: what a period is, which instant belongs to which one, where "now"
comes from, and what a custom period source has to return.

## A period is a half-open UTC interval

```elixir
%{start: ~U[2026-02-01 00:00:00Z], end: ~U[2026-03-01 00:00:00Z], source: :calendar}
```

`[start, end)`: **`start` belongs to the period, `end` does not.**

The `end` of period N is the `start` of period N+1, so no instant belongs to two
periods and no instant belongs to none. That is the whole reason for the
convention. Two other things depend on it:

- **Counter identity.** A counter row is keyed by `{tenant_key, feature,
  period_start}`. If two adjacent periods shared a `start`, two periods' usage
  would land in one row and one invoice.
- **Attribution never has a gap.** An increment at exactly midnight on the first
  of the month is counted once, in the new period. There is no instant the
  library has to guess about.

`AuroraMeter.Schema.Counter.period_start` is `utc_datetime`, second precision. A
custom source must therefore not produce two periods whose starts differ only in
sub-second precision: they would collapse into one row. `Period.current!/2` does
not enforce this (a single call sees one period and cannot compare two), so it
is stated here instead.

### The boundary rule

> An increment at exactly `end` belongs to the **next** period.

```elixir
AuroraMeter.Test.with_clock(~U[2026-01-31 23:59:59.999999Z], fn ->
  AuroraMeter.track(org, :api_calls, 2)   # counted in January
  AuroraMeter.Test.travel(1, :microsecond)
  AuroraMeter.track(org, :api_calls, 5)   # counted in February
end)
```

## UTC only

`start` and `end` must be `DateTime` structs whose `time_zone` is `"Etc/UTC"`.
Anything else is rejected.

A billing month that starts at midnight in the customer's own time zone is a
real requirement, and it is a **host** concern, not the library's: convert in
your own period source, and return the UTC instants the conversion produces.
The library never needs a time zone database, and a stored `period_start` never
changes meaning because a host's configuration did.

## Where "now" comes from

Every instant and every date inside the library comes from
`AuroraMeter.Clock`, the module configured under `clock:`:

```elixir
config :aurora_meter, clock: AuroraMeter.Clock.System   # the default
```

`AuroraMeter.Clock.System` is the only value supported in production.

### Four questions, four readings

| Question | Callback | Promise |
|---|---|---|
| What period is this? What do I display? What goes in `inserted_at`? | `now/0` | Wall-clock shaped and cheap. **It promises nothing about monotonicity and may step backwards.** |
| What UTC day is this? | `today/0` | The date of `now/0`, never a second clock read. |
| How long has this *in-memory* thing taken? (a cache TTL, a timeout, a span inside one process) | `monotonic_ms/0` | Strictly monotone within a node. Never persisted, never compared across nodes. |
| Has enough time passed since something *persisted*? | `db_now/0` | The one clock every node in a cluster shares. Costs a round trip. |

**The rule: stamp and compare with the same clock, and for anything persisted
that clock is the database's.**

A decision that compares "now" against a timestamp read out of a row takes
`db_now/0`, and that row's timestamp must itself have been stamped by the
database, with a `fragment("clock_timestamp()")` in the insert or update, or a
column default. Writing `db_now/0`'s result back from Elixir would be correct
but leaves the guarantee resting on every future caller remembering; a
database-stamped column cannot be written from the wrong clock at all.

### Why `now/0` is allowed to go backwards

Because there is no wall clock that does not, and pretending otherwise is worse
than saying so.

`DateTime.utc_now/0` reads the operating system's clock, which the OS steps
backwards on an NTP correction, a leap second or a hypervisor adjustment. Erlang
system time is monotonic time plus the VM's time offset, and in
`multi_time_warp`, the OTP 29 default, the runtime resyncs that offset on a
timer. Measured on one development host over 420 seconds under load, with
337,900,054 samples of each reading: `DateTime.utc_now/0` and `System.os_time/1`
each stepped backwards 13 times, largest 1.330921 s; `System.system_time/1`
stepped backwards 6 times and further, largest 2.647191 s, on an exact 60 second
cadence; `System.monotonic_time/1` never. `+C no_time_warp` removes the resync,
but the host owns `+C` and this is a library, so a VM flag is a diagnosis and
not a remedy. The full measurement is in
`docs/evidence/v1/phase-02/02c-clock-choice.md`.

So `Clock.System.now/0` reads `System.system_time/1` for **cost** (about 31 ns
against 323 ns, and `AuroraMeter.track/4` reads it on every increment), the
contract says plainly that it makes no monotonicity promise, and anything that
needs a shared, stable "now" takes `db_now/0` instead.

Two things this does not claim:

- **`db_now/0` does not make Postgres's clock perfect.** That host's clock can be
  corrected too. What it removes is the skew *between two clocks*, which is the
  class of defect that bit this library, and it leaves a single, operationally
  managed clock in its place.
- **Ordering never takes a clock at all.** Rows are ordered by a sequence
  number, not by a timestamp. A clock is for answering "when", never "in what
  order".

`Clock.System.today/0` is the date of its own `now/0`, never a second clock
read: reading twice opens a window in which an increment at midnight lands in
the period of one day and the day bucket of another.

### `db_now/0`

`SELECT clock_timestamp() AT TIME ZONE 'UTC'` through the configured repo.
`clock_timestamp()` and not `now()`, because `now()` is the transaction's start
time and returns the same instant for every call inside one transaction, which
is exactly wrong for "has enough time passed".

It costs a round trip, so it is **never** on the `track/4`, `check/2`,
`reserve/2,3` or `with_quota/3,4` path. With no repo configured it raises an
`ArgumentError` naming the `repo` key rather than falling back to a node clock,
because a silent fallback would put back the two-clock comparison it exists to
remove. The SQL is Postgres; on anything else, configure your own `clock`
module.

### Freezing the clock in a test

```elixir
defmodule MyApp.BillingTest do
  use ExUnit.Case, async: false      # the fixed clock is global to the node

  import AuroraMeter.Test, only: [with_clock: 2, travel: 1, travel: 2]

  test "a month boundary does not move usage" do
    with_clock(~U[2026-01-31 23:59:59Z], fn ->
      AuroraMeter.track("org_1", :api_calls, 2)
      travel(~U[2026-02-01 00:00:01Z])
      AuroraMeter.track("org_1", :api_calls, 5)
    end)
  end
end
```

`with_clock/2` installs `AuroraMeter.Clock.Fixed`, starts it at the instant,
runs the block, then stops the agent and restores the previous configuration,
on a raise as well as on a normal return. `travel/1` moves it to an instant and
`travel/2` moves it by an amount; both raise outside a `with_clock/2` block so
they cannot silently do nothing.

`Clock.Fixed` answers **all four** readings from the one frozen instant,
`db_now/0` included, so a decision that consults the database's clock is exactly
as testable as one that consults the node's. `monotonic_ms/0` moves in step with
the frozen instant, and is an offset from a real monotonic reading rather than
the frozen instant's epoch milliseconds, so a cache TTL computed inside a frozen
block does not come back with an expiry decades in the future.

The cost of freezing is that a frozen `db_now/0` stops exercising the query. Keep
at least one test that calls `AuroraMeter.Clock.System.db_now/0` directly, so the
fake cannot drift away from the thing it stands in for.

## The `AuroraMeter.Period` behaviour

```elixir
@callback current(tenant :: term(), now :: DateTime.t()) :: t()
@callback containing(tenant :: term(), instant :: DateTime.t()) :: t()   # optional
```

Configure a source with:

```elixir
config :aurora_meter, period_source: MyApp.DailyPeriod
```

At boot, `AuroraMeter.Config.validate!/0` checks that the module is loadable and
exports `current/2`, and raises an `ArgumentError` naming the key, the module
and the missing callback otherwise. `containing/2` is optional and is never
required. There is deliberately no probe call with a synthetic tenant: a custom
source may legitimately raise for a tenant it does not know, and a probe would
invent a boot failure.

A source must be **pure**: two calls with the same tenant and the same instant
must return the same period. `Period.current!/2` holds no state and concurrent
callers cannot interfere with each other, so anything a source memoises is the
source's own problem.

### The four validation rules

`AuroraMeter.Period.current!/2` checks the source's answer on **every call**,
including on the `AuroraMeter.track/4` hot path. The check is a pattern match
and three comparisons, with no allocation.

| # | Rule | `reason` when broken |
|---|---|---|
| 1 | the result is a map carrying `:start`, `:end` and `:source` (extra keys are allowed and ignored) | `:not_a_map`, `:missing_key` |
| 2 | `start` and `end` are `DateTime` structs with `time_zone == "Etc/UTC"` | `:not_datetime`, `:not_utc` |
| 3 | `DateTime.compare(start, end) == :lt` | `:inverted` |
| 4 | `start <= now` and `now < end` | `:not_containing` |

A failure raises `AuroraMeter.Period.InvalidPeriodError`, carrying `source`,
`tenant_key`, `period`, `instant` and `reason`, with a message that names the
source module first, because the source is what has to be fixed:

```
** (AuroraMeter.Period.InvalidPeriodError) MyApp.DailyPeriod returned a period whose
:start or :end is not in Etc/UTC. An AuroraMeter period is a half-open UTC interval
[start, end): start belongs to the period, end does not, and the interval must contain
the instant it is resolved for. reason=:not_utc tenant_key="org_1"
instant=~U[2026-02-10 09:00:00Z] period=%{...}
```

`AuroraMeter.Period.current/2` is the same read **without** validation. It is
kept for hosts that call it directly; everything inside the library uses
`current!/2`.

### `containing/2`: the period that held a past instant

```elixir
AuroraMeter.Period.containing(org, ~U[2025-12-10 09:00:00Z])
```

The dispatcher calls the source's `containing/2` when it exports one, and
`current/2` with the past instant otherwise, then applies rule 4 to that instant.
A source that is a pure function of the instant (the calendar month is) needs no
`containing/2` of its own.

When the source cannot place the instant, `containing/2` **raises**
`InvalidPeriodError` with `reason: :not_containing`. That raise is the contract,
not an accident: guessing a period for an event is a billing error that is
invisible until the invoice. A caller that must degrade rather than fail rescues
it and records that the attribution is unresolved:

```elixir
period =
  try do
    AuroraMeter.Period.containing(tenant, occurred_at)
  rescue
    AuroraMeter.Period.InvalidPeriodError -> nil
  end
```

## Pro's subscription source

`AuroraMeter.Pro.Period` returns the provider's subscription window when the
tenant has an entitled subscription **and** the instant falls inside it
(`start <= instant < end`), and the calendar month otherwise.

`containing/2` marks the fallback with a distinct atom, `source:
:calendar_fallback`, so a later reader can tell "the subscription window
answered" from "we used a calendar month because we had nothing better".
`current/2` never produces `:calendar_fallback`; it keeps `:calendar`, so a host
matching on that atom is unaffected.

Pro does not store historical subscription windows, so `containing/2` answers
from the *current* window. That is right for an instant inside it and is
explicitly a fallback for anything older.

## Recipe: a daily period

```elixir
defmodule MyApp.DailyPeriod do
  @moduledoc "Usage buckets to the UTC day."

  @behaviour AuroraMeter.Period

  @impl AuroraMeter.Period
  def current(_tenant, now), do: day(DateTime.to_date(now))

  @impl AuroraMeter.Period
  def containing(_tenant, instant), do: day(DateTime.to_date(instant))

  defp day(date) do
    %{
      start: DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
      end: DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC"),
      source: :daily
    }
  end
end
```

## Recipe: a weekly period

```elixir
defmodule MyApp.WeeklyPeriod do
  @moduledoc "Usage buckets to the ISO week: Monday 00:00:00 UTC to Monday 00:00:00 UTC."

  @behaviour AuroraMeter.Period

  @impl AuroraMeter.Period
  def current(_tenant, now), do: week(DateTime.to_date(now))

  @impl AuroraMeter.Period
  def containing(_tenant, instant), do: week(DateTime.to_date(instant))

  defp week(date) do
    monday = Date.beginning_of_week(date, :monday)

    %{
      start: DateTime.new!(monday, ~T[00:00:00], "Etc/UTC"),
      end: DateTime.new!(Date.add(monday, 7), ~T[00:00:00], "Etc/UTC"),
      source: :weekly
    }
  end
end
```

**Changing the week start changes counter identity.** Moving from Monday to
Sunday gives every future counter a different `period_start`, so the usage
already recorded under the old boundary stays where it is and the new boundary
starts a new row. Treat it as a deliberate migration with a cutover date, not as
a configuration tweak.

Both modules are compiled and exercised verbatim by
`test/aurora_meter/examples_test.exs`, so a recipe that stops satisfying the
contract fails this repository's suite.

## What this page does not cover

- Durable event recording and occurrence-time attribution.
- Recurring credit grants on a period boundary.
- Scheduled plan transitions at a period boundary.

Those arrive with the durable event and plan version work; they all resolve a
past instant through `containing/2` and inherit the contract above.
