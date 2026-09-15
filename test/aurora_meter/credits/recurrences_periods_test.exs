defmodule AuroraMeter.Credits.RecurrencesPeriodsTest do
  @moduledoc """
  The period walk, on its own (build unit 06d).

  `AuroraMeter.Credits.Recurrences.periods/4` is the whole of "which periods
  does this entitlement still owe", and it is written over the period source
  rather than over month arithmetic, so a weekly source, a subscription-aligned
  source and the calendar month all walk through the same code. It touches no
  database, which is why it is tested before anything is granted.

  `async: false`: every test swaps the node-wide `:period_source`.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.PeriodSources

  doctest AuroraMeter.Credits.Recurrences

  @tenant "org_recurrence_walk"
  @now ~U[2026-09-16 10:00:00Z]

  test "I18 a tenant with no previous recurrence gets only the current period" do
    assert {:ok, [period], :complete} = Recurrences.periods(@tenant, nil, @now, 12)
    assert period.start == ~U[2026-09-01 00:00:00Z]
    assert period.end == ~U[2026-10-01 00:00:00Z]
  end

  test "I18 a tenant already granted for the current period is owed nothing" do
    assert {:ok, [], :up_to_date} =
             Recurrences.periods(@tenant, ~U[2026-09-01 00:00:00Z], @now, 12)

    # And a recorded period in the future (a clock that moved backwards across a
    # boundary) is not a reason to grant the period again.
    assert {:ok, [], :up_to_date} =
             Recurrences.periods(@tenant, ~U[2026-10-01 00:00:00Z], @now, 12)
  end

  test "I18 the walk from three months ago yields three periods in chronological order" do
    assert {:ok, periods, :complete} =
             Recurrences.periods(@tenant, ~U[2026-06-01 00:00:00Z], @now, 12)

    assert Enum.map(periods, & &1.start) == [
             ~U[2026-07-01 00:00:00Z],
             ~U[2026-08-01 00:00:00Z],
             ~U[2026-09-01 00:00:00Z]
           ]

    # Chronological, contiguous and half-open: each period's end is the next
    # one's start, so no instant belongs to two of them and none to neither.
    assert periods
           |> Enum.chunk_every(2, 1, :discard)
           |> Enum.all?(fn [a, b] -> a.end == b.start end)
  end

  test "I18 the walk stops at max_periods and reports the remainder" do
    assert {:ok, periods, :truncated} =
             Recurrences.periods(@tenant, ~U[2026-01-01 00:00:00Z], @now, 3)

    assert Enum.map(periods, & &1.start) == [
             ~U[2026-02-01 00:00:00Z],
             ~U[2026-03-01 00:00:00Z],
             ~U[2026-04-01 00:00:00Z]
           ]

    # The bound is the claim, and this is the assertion that carries it: with
    # the budget removed the same call returns every month to September.
    assert {:ok, all, :complete} =
             Recurrences.periods(@tenant, ~U[2026-01-01 00:00:00Z], @now, 12)

    assert length(all) == 8
  end

  test "I18 a weekly custom period source yields weekly periods" do
    TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.Weekly}], fn ->
      assert {:ok, periods, :complete} =
               Recurrences.periods(@tenant, ~U[2026-08-24 00:00:00Z], @now, 12)

      assert Enum.map(periods, & &1.start) == [
               ~U[2026-08-31 00:00:00Z],
               ~U[2026-09-07 00:00:00Z],
               ~U[2026-09-14 00:00:00Z]
             ]

      # Weeks, not months: the walk did no month arithmetic anywhere.
      assert Enum.all?(periods, &(DateTime.diff(&1.end, &1.start, :day) == 7))
    end)
  end

  test "I18 a source exporting containing/2 is asked through it" do
    TestConfig.with_config(
      [{:aurora_meter, :period_source, PeriodSources.WeeklyWithContaining}],
      fn ->
        assert {:ok, periods, :complete} =
                 Recurrences.periods(@tenant, ~U[2026-08-31 00:00:00Z], @now, 12)

        # The live period comes from `current/2` and every past one from
        # `containing/2`, and the source stamps which answered.
        assert Enum.map(periods, & &1.start) ==
                 [~U[2026-09-07 00:00:00Z], ~U[2026-09-14 00:00:00Z]]

        assert Enum.map(periods, & &1.source) == [:weekly_containing, :weekly]
      end
    )
  end

  test "I18 a period source that does not advance is detected and does not loop" do
    TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.Stalled}], fn ->
      # Every single call this source makes is valid: the window contains the
      # instant it was asked about, so `Period.current!/2` accepts it. What it
      # never does is move, which only a walk can see.
      assert {:error, :period_source_stalled} =
               Recurrences.periods(@tenant, ~U[2026-06-01 00:00:00Z], @now, 12)
    end)
  end

  test "I18 a period source that raises is reported rather than propagated" do
    TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.RaisesForTenant}], fn ->
      assert {:error, {:period_source_error, %RuntimeError{}}} =
               Recurrences.periods("org_boom_1", nil, @now, 12)

      # The same source, a tenant it can place: the failure is the tenant's, not
      # the walk's.
      assert {:ok, [_september], :complete} = Recurrences.periods(@tenant, nil, @now, 12)
    end)
  end

  test "I18 a source that cannot place a past instant is an error, not a guess" do
    TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.IgnoresInstant}], fn ->
      assert {:error, {:period_source_error, %AuroraMeter.Period.InvalidPeriodError{} = error}} =
               Recurrences.periods(@tenant, ~U[2026-06-01 00:00:00Z], @now, 12)

      assert error.reason == :not_containing
    end)
  end
end
