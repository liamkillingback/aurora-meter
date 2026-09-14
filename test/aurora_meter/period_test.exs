defmodule AuroraMeter.PeriodTest do
  @moduledoc """
  Build unit 02c: the half-open UTC period contract.

  `async: false`: every test here freezes the node-wide clock, and most also
  swap the node-wide `period_source`.
  """

  use ExUnit.Case, async: false

  import AuroraMeter.Test, only: [travel: 1, travel: 2, with_clock: 2]

  alias AuroraMeter.Config
  alias AuroraMeter.Period
  alias AuroraMeter.Period.InvalidPeriodError
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.PeriodSources

  doctest AuroraMeter.Period

  @tenant "org_period_contract"
  @january_last ~U[2026-01-31 23:59:59.999999Z]
  @january_start ~U[2026-01-01 00:00:00Z]
  @february_start ~U[2026-02-01 00:00:00Z]

  describe "P01: the interval is half-open [start, end)" do
    test "P01 the calendar period is half-open: an instant at `end` resolves to the next period" do
      with_clock(@january_last, fn ->
        january = Period.current!(@tenant)
        assert january.start == @january_start
        assert january.end == @february_start

        travel(january.end)

        february = Period.current!(@tenant)
        assert february.start == @february_start
        refute february.start == january.start
      end)
    end

    test "P01 cross-month: 2026-01-31T23:59:59.999999Z and 2026-02-01T00:00:00Z resolve to different periods whose boundary instants are equal" do
      with_clock(@january_last, fn ->
        january = Period.current!(@tenant)
        travel(1, :microsecond)
        february = Period.current!(@tenant)

        assert january.start == @january_start
        assert february.start == @february_start
        assert january.end == february.start
        assert january.source == :calendar and february.source == :calendar
      end)
    end

    test "P01 leap day: 2028-02-29 resolves inside the February 2028 period and 2028-03-01T00:00:00Z starts the next" do
      with_clock(~U[2028-02-29 12:00:00Z], fn ->
        february = Period.current!(@tenant)
        assert february.start == ~U[2028-02-01 00:00:00Z]
        assert february.end == ~U[2028-03-01 00:00:00Z]

        travel(~U[2028-03-01 00:00:00Z])
        assert Period.current!(@tenant).start == ~U[2028-03-01 00:00:00Z]
      end)
    end

    test "P01 UTC boundary: an instant one microsecond before `end` is in the current period" do
      with_clock(~U[2026-02-28 23:59:59.999999Z], fn ->
        period = Period.current!(@tenant)

        assert period.start == @february_start
        assert period.end == ~U[2026-03-01 00:00:00Z]
        assert DateTime.compare(Config.clock().now(), period.end) == :lt
      end)
    end
  end

  describe "P05: a source that breaks the contract fails at first use" do
    test "P05 a source returning something that is not a map raises with reason :not_a_map" do
      assert %InvalidPeriodError{reason: :not_a_map} =
               rejected(PeriodSources.NotAMap, "NotAMap")
    end

    test "P05 a source returning a map without :source raises with reason :missing_key" do
      assert %InvalidPeriodError{reason: :missing_key} =
               rejected(PeriodSources.MissingKey, "MissingKey")
    end

    test "P05 a source returning a naive datetime raises InvalidPeriodError with reason :not_datetime and names the source" do
      assert %InvalidPeriodError{reason: :not_datetime} =
               rejected(PeriodSources.NaiveStart, "NaiveStart")
    end

    test "P05 a source returning a non-UTC zone raises with reason :not_utc" do
      assert %InvalidPeriodError{reason: :not_utc} = rejected(PeriodSources.NonUtc, "NonUtc")
    end

    test "P05 a source returning end == start raises with reason :inverted" do
      assert %InvalidPeriodError{reason: :inverted} =
               rejected(PeriodSources.ZeroLength, "ZeroLength")
    end

    test "P05 a source returning end < start raises with reason :inverted" do
      assert %InvalidPeriodError{reason: :inverted} =
               rejected(PeriodSources.Inverted, "Inverted")
    end

    test "P05 a source returning a window in the future raises with reason :not_containing" do
      assert %InvalidPeriodError{reason: :not_containing} =
               rejected(PeriodSources.FutureWindow, "FutureWindow")
    end

    test "P05 the error carries the source, the tenant key, the instant and the period" do
      error = rejected(PeriodSources.Inverted, "Inverted")

      assert error.source == PeriodSources.Inverted
      assert error.tenant_key == @tenant
      assert error.instant == @january_last
      assert %{start: %DateTime{}, end: %DateTime{}} = error.period
    end

    test "current/2 does not validate and returns the source's map unchanged" do
      with_source(PeriodSources.Inverted, @january_last, fn ->
        period = Period.current(@tenant)

        assert period.start == @february_start
        assert period.end == @january_start
      end)
    end
  end

  describe "containing/2" do
    test "containing/2 uses the source's containing/2 when exported" do
      with_source(PeriodSources.WeeklyWithContaining, @january_last, fn ->
        # 2025-12-08 is a Monday.
        period = Period.containing(@tenant, ~U[2025-12-10 09:00:00Z])

        assert period.source == :weekly_containing
        assert period.start == ~U[2025-12-08 00:00:00Z]
        assert period.end == ~U[2025-12-15 00:00:00Z]
      end)
    end

    test "containing/2 falls back to current/2 with the instant when containing/2 is not exported" do
      with_source(PeriodSources.Weekly, @january_last, fn ->
        period = Period.containing(@tenant, ~U[2025-12-10 09:00:00Z])

        assert period.source == :weekly
        assert period.start == ~U[2025-12-08 00:00:00Z]
        assert period.end == ~U[2025-12-15 00:00:00Z]
      end)
    end

    test "containing/2 raises :not_containing when the source cannot place the instant" do
      with_source(PeriodSources.IgnoresInstant, @january_last, fn ->
        error =
          assert_raise InvalidPeriodError, fn ->
            Period.containing(@tenant, ~U[2025-06-10 09:00:00Z])
          end

        assert error.reason == :not_containing
        assert error.instant == ~U[2025-06-10 09:00:00Z]
        assert error.message =~ "IgnoresInstant"
      end)
    end

    test "containing/2 answers the calendar month for a past instant under the default source" do
      with_clock(@january_last, fn ->
        period = Period.containing(@tenant, ~U[2025-06-10 09:00:00Z])

        assert period.start == ~U[2025-06-01 00:00:00Z]
        assert period.end == ~U[2025-07-01 00:00:00Z]
        assert period.source == :calendar
      end)
    end
  end

  describe "a custom source" do
    test "a custom weekly source buckets Monday 00:00:00Z to Monday 00:00:00Z and is accepted by current!/2" do
      # 2026-01-26 is a Monday; 2026-02-01 is the Sunday inside that same week,
      # which is also the instant a calendar source would call a new period.
      with_source(PeriodSources.Weekly, ~U[2026-02-01 12:00:00Z], fn ->
        period = Period.current!(@tenant)

        assert period.start == ~U[2026-01-26 00:00:00Z]
        assert period.end == ~U[2026-02-02 00:00:00Z]
        assert period.source == :weekly
      end)
    end
  end

  describe "the boot check" do
    test "boot raises when period_source does not export current/2" do
      TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.NoCurrent}], fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message

        assert message =~ "config :aurora_meter, period_source"
        assert message =~ "AuroraMeter.Test.PeriodSources.NoCurrent"
        assert message =~ "current/2"
        assert message =~ "AuroraMeter.Period"
      end)
    end

    test "boot raises when clock does not export now/0 and today/0" do
      TestConfig.with_config([{:aurora_meter, :clock, PeriodSources.NoNow}], fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message

        assert message =~ "config :aurora_meter, clock"
        assert message =~ "AuroraMeter.Test.PeriodSources.NoNow"
        assert message =~ "now/0"
        assert message =~ "AuroraMeter.Clock"
      end)
    end

    test "boot raises when a module-typed key names a module that cannot be loaded" do
      TestConfig.with_config([{:aurora_meter, :clock, NoSuchClockModule}], fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message

        assert message =~ "could not be loaded"
        assert message =~ "NoSuchClockModule"
      end)
    end
  end

  # Installs `source`, freezes the clock at `instant` and runs `fun`. The clock
  # helper notices that this process already holds the configuration token and
  # does not queue behind itself (open-findings.md X51).
  defp with_source(source, instant, fun) do
    TestConfig.with_config([{:aurora_meter, :period_source, source}], fn ->
      with_clock(instant, fun)
    end)
  end

  defp rejected(source, name) do
    with_source(source, @january_last, fn ->
      error = assert_raise(InvalidPeriodError, fn -> Period.current!(@tenant) end)

      assert error.message =~ name
      assert String.starts_with?(error.message, "AuroraMeter.Test.PeriodSources.")

      error
    end)
  end
end
