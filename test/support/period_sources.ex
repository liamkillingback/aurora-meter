defmodule AuroraMeter.Test.PeriodSources do
  @moduledoc """
  Period sources for `test/aurora_meter/period_test.exs` (build unit 02c).

  One valid weekly source, one weekly source that also exports the optional
  `containing/2`, one source that ignores the instant it is asked about, and one
  deliberately broken source per `AuroraMeter.Period.InvalidPeriodError` reason.
  Each broken source is the smallest thing that produces exactly one reason, so
  a test that names a reason names a module too.

  These ship in no archive: `elixirc_paths(:test)` compiles `test/support`.
  """

  @doc "Midnight UTC on `date`, the instant a day or week source starts at."
  @spec at(Date.t()) :: DateTime.t()
  def at(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defmodule Weekly do
    @moduledoc "Valid: ISO weeks starting Monday 00:00:00Z. No `containing/2`."

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Test.PeriodSources

    @impl AuroraMeter.Period
    def current(_tenant, now) do
      start_date = now |> DateTime.to_date() |> Date.beginning_of_week()

      %{
        start: PeriodSources.at(start_date),
        end: PeriodSources.at(Date.add(start_date, 7)),
        source: :weekly
      }
    end
  end

  defmodule WeeklyWithContaining do
    @moduledoc "Valid, and exports the optional callback so the dispatcher can be seen to use it."

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Test.PeriodSources

    @impl AuroraMeter.Period
    def current(_tenant, now), do: week(now, :weekly)

    @impl AuroraMeter.Period
    def containing(_tenant, instant), do: week(instant, :weekly_containing)

    defp week(instant, source) do
      start_date = instant |> DateTime.to_date() |> Date.beginning_of_week()

      %{
        start: PeriodSources.at(start_date),
        end: PeriodSources.at(Date.add(start_date, 7)),
        source: source
      }
    end
  end

  defmodule IgnoresInstant do
    @moduledoc """
    Valid for "now", useless for the past: it answers with the calendar month of
    the clock rather than of the instant it was asked about, which is what
    `containing/2` must refuse rather than guess around.
    """

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, _now), do: Calendar.current(tenant, AuroraMeter.Clock.now())
  end

  # The next three break the callback's *type*, not just its value, so they
  # deliberately do not declare `@behaviour AuroraMeter.Period`: Dialyzer proves
  # the mismatch and `mix check` fails on it (a bare `mix dialyzer` would not,
  # open-findings.md X49). A source module needs no behaviour attribute to be
  # configured as `period_source`, which is exactly the hole `Period.current!/2`
  # exists to close at runtime.
  defmodule NotAMap do
    @moduledoc "Broken: returns something that is not a map at all."

    def current(_tenant, _now), do: :no_period
  end

  defmodule MissingKey do
    @moduledoc "Broken: a map without `:source`."

    alias AuroraMeter.Period.Calendar

    def current(tenant, now), do: tenant |> Calendar.current(now) |> Map.delete(:source)
  end

  defmodule NaiveStart do
    @moduledoc "Broken: `:start` is a `NaiveDateTime`."

    alias AuroraMeter.Period.Calendar

    def current(tenant, now) do
      period = Calendar.current(tenant, now)
      %{period | start: DateTime.to_naive(period.start)}
    end
  end

  defmodule NonUtc do
    @moduledoc """
    Broken: `:start` carries a non-UTC zone.

    The struct is built by hand rather than through `DateTime.shift_zone/2`
    because the library declares no time zone database and must not need one.
    """

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, now) do
      period = Calendar.current(tenant, now)

      shifted = %DateTime{
        period.start
        | time_zone: "America/New_York",
          zone_abbr: "EST",
          utc_offset: -18_000,
          std_offset: 0
      }

      %{period | start: shifted}
    end
  end

  defmodule ZeroLength do
    @moduledoc "Broken: `end == start`, so the interval holds no instant."

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, now) do
      period = Calendar.current(tenant, now)
      %{period | end: period.start}
    end
  end

  defmodule Inverted do
    @moduledoc "Broken: `end < start`."

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, now) do
      period = Calendar.current(tenant, now)
      %{period | start: period.end, end: period.start}
    end
  end

  defmodule FutureWindow do
    @moduledoc "Broken: a well formed window that starts after the instant asked about."

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, now) do
      period = Calendar.current(tenant, now)

      %{
        period
        | start: DateTime.add(period.end, 1, :day),
          end: DateTime.add(period.end, 32, :day)
      }
    end
  end

  defmodule Stalled do
    @moduledoc """
    A correct `current/2` and a `containing/2` that never moves forward.

    Every single call it makes is valid: the window it returns really does
    contain the instant it was asked about, so `AuroraMeter.Period.containing/2`
    accepts it. What it never does is advance, because its start is a fixed
    floor and only its end grows. A walk that asked it for "the period after
    this one" for ever would get the same answer for ever, which is the shape
    build unit 06d detects by comparing consecutive starts rather than by
    trusting the source.
    """

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar
    alias AuroraMeter.Test.PeriodSources

    @floor ~D[2026-01-01]

    @impl AuroraMeter.Period
    def current(tenant, instant), do: Calendar.current(tenant, instant)

    @impl AuroraMeter.Period
    def containing(_tenant, instant) do
      next = instant |> DateTime.to_date() |> Date.end_of_month() |> Date.add(1)

      %{start: PeriodSources.at(@floor), end: PeriodSources.at(next), source: :stalled}
    end
  end

  defmodule RaisesForTenant do
    @moduledoc """
    The calendar month for every tenant except one whose key contains `"boom"`,
    for which it raises. Build unit 06d needs a source that fails for **one**
    tenant so a run can be shown to skip it and go on to the next, rather than
    one that fails for all of them and proves only that the run stops.
    """

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar

    @impl AuroraMeter.Period
    def current(tenant, instant) do
      if is_binary(tenant) and String.contains?(tenant, "boom") do
        raise RuntimeError, "this period source cannot place #{tenant}"
      end

      Calendar.current(tenant, instant)
    end
  end

  defmodule SubscriptionAligned do
    @moduledoc """
    `AuroraMeter.Pro.Period`'s shape, written in core so build unit 07b can test
    a subscription-aligned boundary without depending on the Pro package.

    The tenant's own `current_period_start`/`current_period_end` when the
    subscription is entitled and the instant is inside the window, and the
    calendar month otherwise. That is `pro/period.ex:20-36` line for line, and
    the point of restating it here is that the default `effective_at` of a
    scheduled transition is "the end of the tenant's current period" for
    whatever source the host configured, not for the calendar.
    """

    @behaviour AuroraMeter.Period

    alias AuroraMeter.Period.Calendar
    alias AuroraMeter.Schema.Subscription
    alias AuroraMeter.Subscriptions

    @impl AuroraMeter.Period
    def current(tenant, now) do
      case Subscriptions.get(tenant) do
        %Subscription{
          current_period_start: %DateTime{} = from,
          current_period_end: %DateTime{} = to
        } =
            subscription ->
          window(tenant, now, subscription, from, to)

        _none ->
          Calendar.current(tenant, now)
      end
    end

    defp window(tenant, now, subscription, from, to) do
      if Subscription.entitled?(subscription) and DateTime.compare(now, to) == :lt and
           DateTime.compare(now, from) != :lt do
        %{start: from, end: to, source: :subscription}
      else
        Calendar.current(tenant, now)
      end
    end
  end

  defmodule NoNow do
    @moduledoc "A clock missing `now/0`, for the boot check."
    def today, do: Date.utc_today()
    def monotonic_ms, do: 0
  end

  defmodule NoCurrent do
    @moduledoc "A period source missing `current/2`, for the boot check."
    def containing(_tenant, _instant), do: %{}
  end
end
