defmodule AuroraMeter.ClockTest do
  @moduledoc """
  Build unit 02c: the clock seam.

  `async: false` throughout: `AuroraMeter.Clock.Fixed` is one named agent and
  `clock:` is node-wide configuration, so every test here installs something
  every other process on the node can see. `AuroraMeter.DataCase` rather than a
  bare `ExUnit.Case`, because `db_now/0` really talks to the database and the
  cases that exercise it must not be faked.
  """

  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [travel: 1, travel: 2, with_clock: 2]

  alias AuroraMeter.Clock
  alias AuroraMeter.Test.Config, as: TestConfig

  doctest AuroraMeter.Clock

  @instant ~U[2026-01-31 23:59:59.999999Z]

  describe "the contract" do
    test "P02 Clock.now/0 returns a UTC DateTime with microsecond precision" do
      now = Clock.now()

      assert %DateTime{time_zone: "Etc/UTC"} = now
      assert {_microsecond, 6} = now.microsecond
    end

    test "P03 Clock.System.today/0 is the date of Clock.System.now/0" do
      # Nothing is frozen: the point is that the default implementation derives
      # the date from its own instant rather than reading a second clock. Two
      # reads a microsecond apart can straddle midnight, so the assertion
      # allows the date of either read and would still fail a today/0 built on
      # an unrelated clock.
      before = DateTime.to_date(Clock.System.now())
      today = Clock.System.today()
      later = DateTime.to_date(Clock.System.now())

      assert today in [before, later]
      assert Date.diff(later, before) in [0, 1]
    end

    test "Clock.System.now/0 tracks real time rather than drifting away from it" do
      # now/0 makes no monotonicity promise, but it is still a wall clock: the
      # tolerance is generous because this host's OS clock is yanked backwards
      # by up to 1.3 s every 32 s (02c-clock-choice.md), and a basis that
      # accumulated drift without bound would fail this within minutes.
      assert abs(DateTime.diff(Clock.System.now(), DateTime.utc_now(), :second)) <= 5
    end

    test "Clock.monotonic_ms/0 is an integer that never decreases" do
      readings = Enum.map(1..1_000, fn _ -> Clock.monotonic_ms() end)

      assert Enum.all?(readings, &is_integer/1)
      assert readings == Enum.sort(readings)
    end
  end

  describe "db_now/0 against the real database" do
    # Clock.Fixed answers db_now/0 from the frozen instant, so every test that
    # freezes the clock stops exercising the query. These four do not freeze it.

    test "Clock.System.db_now/0 returns a UTC DateTime from the database" do
      instant = Clock.System.db_now()

      assert %DateTime{time_zone: "Etc/UTC"} = instant
      assert {_microsecond, 6} = instant.microsecond
    end

    test "Clock.System.db_now/0 agrees with the node clock to within a few seconds" do
      # Both are real clocks on the same machine. This is the check that the
      # query returns the current instant and not, say, the epoch or a local
      # time read as UTC.
      assert abs(DateTime.diff(Clock.System.db_now(), Clock.System.now(), :second)) <= 5
    end

    test "Clock.System.db_now/0 advances inside one transaction" do
      # clock_timestamp() and not now(): now() is the transaction's start time
      # and would return the same instant for every call inside a transaction,
      # which is exactly wrong for "has enough time passed".
      {:ok, {first, second}} =
        AuroraMeter.Config.repo().transaction(fn ->
          first = Clock.System.db_now()
          Process.sleep(5)
          {first, Clock.System.db_now()}
        end)

      assert DateTime.compare(second, first) == :gt
    end

    test "Clock.System.db_now/0 raises an ArgumentError naming the repo key when none is configured" do
      TestConfig.with_config([{:aurora_meter, :repo, nil}], fn ->
        message = assert_raise(ArgumentError, fn -> Clock.System.db_now() end).message

        assert message =~ "db_now/0"
        assert message =~ "repo:"
        refute message =~ "falling back"
      end)
    end
  end

  describe "Clock.Fixed" do
    test "raises when configured without an instant" do
      TestConfig.with_config([{:aurora_meter, :clock, Clock.Fixed}], fn ->
        assert_raise RuntimeError, ~r/AuroraMeter\.Test\.with_clock\/2/, fn -> Clock.now() end
      end)
    end

    test "answers all four readings from the one frozen instant" do
      with_clock(@instant, fn ->
        assert Clock.now() == @instant
        assert Clock.db_now() == @instant
        assert Clock.today() == ~D[2026-01-31]

        travel(1, :hour)

        assert Clock.now() == ~U[2026-02-01 00:59:59.999999Z]
        assert Clock.db_now() == ~U[2026-02-01 00:59:59.999999Z]
        assert Clock.today() == ~D[2026-02-01]
      end)
    end

    test "monotonic_ms/0 advances by exactly the amount travel/2 moves the instant" do
      with_clock(@instant, fn ->
        before = Clock.monotonic_ms()
        travel(90, :second)
        assert Clock.monotonic_ms() - before == 90_000

        travel(-30, :second)
        assert Clock.monotonic_ms() - before == 60_000
      end)
    end

    test "monotonic_ms/0 shares a number line with the real monotonic clock" do
      # X62: if the fake returned the frozen instant's epoch milliseconds, a TTL
      # computed inside a frozen block would outlive the test by decades. The
      # subscription cache is the caller that would have suffered it.
      real_before = System.monotonic_time(:millisecond)
      frozen = with_clock(~U[2099-01-01 00:00:00Z], fn -> Clock.monotonic_ms() end)
      real_after = System.monotonic_time(:millisecond)

      assert frozen >= real_before
      assert frozen <= real_after + 1_000
    end

    test "today/0 is the date of the frozen instant" do
      with_clock(~U[2028-02-29 12:00:00Z], fn ->
        # `{0, 6}`, not `{0, 0}`: the fake honours the behaviour's "microsecond
        # precision" the way `Clock.System` does, so freezing a whole-second
        # instant cannot hand a `:utc_datetime_usec` column a value Ecto
        # refuses.
        assert Clock.now() == ~U[2028-02-29 12:00:00.000000Z]
        assert Clock.now().microsecond == {0, 6}
        assert Clock.today() == ~D[2028-02-29]
      end)
    end
  end

  describe "AuroraMeter.Test.with_clock/2" do
    test "restores the previous clock configuration after the block" do
      previous = Application.fetch_env(:aurora_meter, :clock)

      assert :ran = with_clock(@instant, fn -> :ran end)

      assert Application.fetch_env(:aurora_meter, :clock) == previous
      refute Clock.Fixed.running?()
    end

    test "restores the previous clock configuration when the block raises" do
      previous = Application.fetch_env(:aurora_meter, :clock)

      assert_raise RuntimeError, "boom", fn ->
        with_clock(@instant, fn -> raise "boom" end)
      end

      assert Application.fetch_env(:aurora_meter, :clock) == previous
      refute Clock.Fixed.running?()
    end

    test "restores the previous clock configuration when the block exits" do
      previous = Application.fetch_env(:aurora_meter, :clock)

      catch_exit(with_clock(@instant, fn -> exit(:bye) end))

      assert Application.fetch_env(:aurora_meter, :clock) == previous
      refute Clock.Fixed.running?()
    end

    test "travel/2 moves the fixed clock and is visible to another process" do
      parent = self()

      with_clock(@instant, fn ->
        travel(1, :microsecond)

        # A bare spawn, not a Task: no $callers, no process dictionary, no
        # shared ancestry. If the frozen instant reaches this process it is
        # because the agent is genuinely node-wide.
        spawn(fn -> send(parent, {:seen, Clock.now(), Clock.today()}) end)

        assert_receive {:seen, ~U[2026-02-01 00:00:00.000000Z], ~D[2026-02-01]}, 1_000
      end)
    end

    test "travel/1 raises outside a with_clock/2 block" do
      assert_raise RuntimeError, ~r/with_clock\/2/, fn -> travel(@instant) end
      assert_raise RuntimeError, ~r/with_clock\/2/, fn -> travel(1, :second) end
    end
  end

  describe "the host clock, as a negative control" do
    # This was the P06 soak. now/0 no longer claims to be monotone, so it
    # asserts nothing about that: it exists to keep the *reason* for the
    # database clock visible in the suite rather than only in a document. It
    # records how many times each host clock reading went backwards during the
    # run, and fails only if its own harness is broken.
    #
    # Duration matters: step 0 measured System.system_time/1 stepping backwards
    # on an exact 60 second cadence and DateTime.utc_now/0 about every 32
    # seconds, which is why a 45 second probe once reported zero and produced a
    # wrong answer (open-findings.md X60: minutes, not seconds).
    @tag timeout: 900_000
    test "records how far the host clock went backwards, and asserts nothing about now/0" do
      seconds = String.to_integer(System.get_env("AURORA_CLOCK_SOAK_SECONDS") || "150")
      loaders = System.schedulers_online()

      busy =
        for _ <- 1..loaders do
          spawn(fn ->
            burn = fn f ->
              :erlang.md5(:crypto.strong_rand_bytes(4096))
              f.(f)
            end

            burn.(burn)
          end)
        end

      try do
        {seam, control, samples} = soak(seconds)

        IO.puts(
          "\n[clock control] #{seconds}s, #{loaders} loaders, #{samples} samples: " <>
            "Clock.now/0 backwards=#{elem(seam, 0)} worst=#{us(elem(seam, 1))}s; " <>
            "DateTime.utc_now/0 backwards=#{elem(control, 0)} worst=#{us(elem(control, 1))}s"
        )

        # The harness, not the clock: a sampler that never sampled would report
        # zero backwards steps and look like good news.
        assert samples > 1_000
      after
        Enum.each(busy, &Process.exit(&1, :kill))
      end
    end
  end

  describe "the clock audits" do
    test "P07 no module in lib/ reads a clock outside AuroraMeter.Clock" do
      assert audit(~r/DateTime\.utc_now\(\)|Date\.utc_today\(\)/) == []

      assert audit(~r/System\.os_time|System\.system_time|System\.monotonic_time|:timer\.tc/) ==
               []
    end

    test "P06 no lib/ code compares a node-clock reading against another instant" do
      # The exact shape of B01 and L20: DateTime.diff(<node clock>, <persisted>).
      # A comparison against something read out of a row takes db_now/0.
      assert audit(~r/DateTime\.(diff|compare)\(\s*(Clock\.now\(\)|DateTime\.utc_now\(\))/) == []
    end

    test "P08 db_now/0 appears in no module on the hot path" do
      # `db_now()` with the parentheses: a call, not the `db_now: 0` entry in
      # config.ex's boot check, which declares the callback without reading it.
      callers =
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&(&1 |> File.read!() |> String.contains?("db_now()")))

      # The hot path is track/4, check/2, reserve/2,3 and with_quota/3,4, which
      # live in these four modules plus the ETS layer. None may consult the
      # database for the time.
      hot = [
        "lib/aurora_meter.ex",
        "lib/aurora_meter/counter.ex",
        "lib/aurora_meter/entitlements.ex",
        "lib/aurora_meter/period.ex",
        "lib/aurora_meter/store.ex"
      ]

      # The Mix task reads it to say how long a stalled backfill checkpoint has
      # said "running". Both sides of that comparison are database-stamped, and
      # it decides nothing: the backfill's refusal is decided by an advisory
      # lock, never by a clock (03a, open-findings.md X100). A Mix task is also
      # not a path, hot or otherwise.
      # A replay stamps `started_at` and `finished_at` into its checkpoint so an
      # operator can see how long a rebuild took. It is a REPORT: the replay's
      # exclusion is an advisory lock and its resumability is a cursor, so no
      # decision anywhere subtracts these (03d, open-findings.md X100). It is
      # read once per run and once per phase, never per batch and never on a
      # metering call.
      allowed = [
        "lib/aurora_meter/clock.ex",
        "lib/aurora_meter/credits.ex",
        "lib/aurora_meter/events/replay.ex",
        "lib/mix/tasks/aurora_meter.events.backfill.ex"
      ]

      assert callers -- allowed == []
      assert Enum.all?(hot, &(&1 not in callers))
    end
  end

  defp audit(pattern) do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&(&1 == "lib/aurora_meter/clock.ex"))
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> Regex.match?(pattern, line) end)
      |> Enum.map(fn {line, n} -> "#{path}:#{n}: #{String.trim(line)}" end)
    end)
  end

  defp soak(seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1_000
    step(deadline, {Clock.now(), 0, 0}, {DateTime.utc_now(), 0, 0}, 0)
  end

  defp step(deadline, seam, control, samples) do
    if System.monotonic_time(:millisecond) >= deadline do
      {{elem(seam, 1), elem(seam, 2)}, {elem(control, 1), elem(control, 2)}, samples}
    else
      step(
        deadline,
        compare(seam, Clock.now()),
        compare(control, DateTime.utc_now()),
        samples + 1
      )
    end
  end

  defp compare({previous, backwards, worst}, current) do
    case DateTime.compare(current, previous) do
      :lt -> {current, backwards + 1, max(worst, DateTime.diff(previous, current, :microsecond))}
      _forward -> {current, backwards, worst}
    end
  end

  defp us(microseconds), do: Float.round(microseconds / 1_000_000, 6)
end
