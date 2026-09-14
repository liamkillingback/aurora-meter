defmodule AuroraMeter.EventsGateTest do
  @moduledoc """
  Backpressure on the durable path: the admission gate, the transaction
  timeout, and the rule that a refused durable write never becomes a successful
  buffered one (build unit 03b).

  There is no clock in any of it. A concurrency limit at this timescale cannot
  be decided by comparing two wall-clock instants, because the shared database
  clock steps backwards by hundreds of milliseconds on this hardware
  (`open-findings.md` X100). The gate counts and monitors; the timeout is
  DBConnection's own timer on a statement, not a comparison of two stamped
  instants.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Events.Gate
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    AuroraMeter.Test.reset!()
    tenant = AuroraMeter.Test.unique_tenant("gate")
    on_exit(fn -> Connections.cleanup!(tenant) end)

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    %{tenant: tenant, at: DateTime.utc_now()}
  end

  # A process that takes a permit, says so, and holds it until released.
  defp holder(parent) do
    spawn(fn ->
      case Gate.enter() do
        {:ok, permit} ->
          send(parent, {:admitted, self(), permit})
          receive do: (:release -> Gate.leave(permit))

        error ->
          send(parent, {:refused, self(), error})
      end
    end)
  end

  defp saturate(limit) do
    parent = self()

    for _n <- 1..limit do
      pid = holder(parent)
      assert_receive {:admitted, ^pid, _permit}, 5_000
      pid
    end
  end

  defp release(pids), do: Enum.each(pids, &send(&1, :release))

  describe "admission" do
    test "the gate admits exactly record_max_concurrency callers and refuses the next" do
      TestConfig.with_config([{:aurora_meter, :record_max_concurrency, 3}], fn ->
        assert Gate.admitted() == 0
        held = saturate(3)
        assert Gate.admitted() == 3

        assert Gate.enter() == {:error, :overloaded}

        release(held)
        wait_until(fn -> Gate.admitted() == 0 end)

        assert {:ok, permit} = Gate.enter()
        Gate.leave(permit)
      end)
    end

    test "a killed admitted caller releases its permit" do
      TestConfig.with_config([{:aurora_meter, :record_max_concurrency, 2}], fn ->
        [first, second] = saturate(2)
        assert Gate.enter() == {:error, :overloaded}

        # `:kill` is untrappable: the caller runs no `after` block and no
        # `on_exit`. This is the whole reason the gate is a process that
        # monitors rather than a `:counters` reference.
        Process.exit(first, :kill)
        wait_until(fn -> Gate.admitted() == 1 end)

        assert {:ok, permit} = Gate.enter()
        Gate.leave(permit)
        release([second])
        wait_until(fn -> Gate.admitted() == 0 end)
      end)
    end

    test "leaving twice decrements once" do
      assert {:ok, permit} = Gate.enter()
      before = Gate.admitted()
      Gate.leave(permit)
      Gate.leave(permit)
      wait_until(fn -> Gate.admitted() == before - 1 end)
    end

    test "the gate does not admit while it is unreachable, and says so rather than crashing" do
      pid = Process.whereis(Gate)
      assert is_pid(pid)

      Process.unregister(Gate)

      try do
        assert Gate.enter() == {:error, :unavailable}
        assert Gate.admitted() == 0
      after
        Process.register(pid, Gate)
      end

      # The restore is asserted, not assumed (open-findings.md X97).
      assert Process.whereis(Gate) == pid
      assert {:ok, permit} = Gate.enter()
      Gate.leave(permit)
    end
  end

  describe "record/4 under backpressure" do
    test "with the gate saturated record/4 is overloaded and the ETS counter is unchanged", ctx do
      TestConfig.with_config([{:aurora_meter, :record_max_concurrency, 2}], fn ->
        AuroraMeter.track(ctx.tenant, :ai_generations, 4)
        before = AuroraMeter.usage(ctx.tenant, :ai_generations)

        held = saturate(2)

        assert {:error, {:unavailable, :overloaded}} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 100,
                   id: "refused",
                   occurred_at: ctx.at
                 )

        # L-03b-4: no fallback to track/4. A refused durable write must not
        # become a successful buffered one, or the caller would believe a fact
        # was recorded that has no identity and no way to be deduplicated.
        assert AuroraMeter.usage(ctx.tenant, :ai_generations) == before
        assert rows(ctx.tenant) == 0

        release(held)
      end)
    end

    test "an unreachable gate is {:unavailable, :gate_unavailable}, never a crash", ctx do
      pid = Process.whereis(Gate)
      Process.unregister(Gate)

      try do
        assert {:error, {:unavailable, :gate_unavailable}} =
                 AuroraMeter.record(ctx.tenant, :ai_generations, 1,
                   id: "no-gate",
                   occurred_at: ctx.at
                 )
      after
        Process.register(pid, Gate)
      end

      assert Process.whereis(Gate) == pid
      assert rows(ctx.tenant) == 0
    end

    test "a permit is returned even when the storage call raises", ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :record_max_concurrency, 1},
          {:aurora_meter, :storage, FaultStorage}
        ],
        fn ->
          Faults.arm(:before_commit, :raise,
            when: &(&1[:callback] == :record_events),
            label: :permit_leak
          )

          assert_raise Faults.Injected, fn ->
            AuroraMeter.record(ctx.tenant, :ai_generations, 1, id: "boom", occurred_at: ctx.at)
          end

          :ok = Faults.assert_fired!(:before_commit)
          wait_until(fn -> Gate.admitted() == 0 end)
        end
      )
    end
  end

  describe "record_timeout" do
    test "a database that never answers is {:unavailable, :timeout} within the timeout, never an exit",
         ctx do
      parent = self()

      # An ACCESS EXCLUSIVE lock on the events table from another connection is
      # "the database never answers" for this statement, without stopping the
      # server.
      locker =
        spawn(fn ->
          Connections.checkout!()

          Connections.repo().transaction(
            fn ->
              Connections.repo().query!(
                "LOCK TABLE aurora_meter_events IN ACCESS EXCLUSIVE MODE",
                []
              )

              send(parent, {:locked, self()})
              receive do: (:release -> :ok), after: (20_000 -> :ok)
            end,
            timeout: 30_000
          )

          send(parent, {:unlocked, self()})
          Sandbox.checkin(Connections.repo())
        end)

      assert_receive {:locked, ^locker}, 10_000

      TestConfig.with_config([{:aurora_meter, :record_timeout, 400}], fn ->
        started = System.monotonic_time(:millisecond)

        result =
          AuroraMeter.record(ctx.tenant, :ai_generations, 1,
            id: "never-answers",
            occurred_at: ctx.at
          )

        elapsed = System.monotonic_time(:millisecond) - started

        assert {:error, {:unavailable, reason}} = result
        assert reason in [:timeout, :pool_timeout]

        # The bound is the timeout plus the pool checkout, not "eventually".
        assert elapsed < 10_000, "the timeout took #{elapsed}ms"

        if System.get_env("AURORA_CONCURRENCY_REPORT") do
          IO.puts("\n[03b] record_timeout=400 reason=#{inspect(reason)} elapsed_ms=#{elapsed}")
        end
      end)

      send(locker, :release)
      assert_receive {:unlocked, ^locker}, 30_000

      # A statement timeout disconnects the connection, which takes this
      # process's sandbox ownership with it: the assertion that nothing was
      # written has to be made on a fresh one.
      Connections.checkout!()
      assert rows(ctx.tenant) == 0
    end
  end

  defp rows(tenant) do
    Connections.repo().aggregate(
      from(e in AuroraMeter.Schema.Event, where: e.tenant_key == ^tenant),
      :count
    )
  end

  # A bounded poll on a condition, never a sleep on a duration: the gate's
  # bookkeeping is a cast plus a monitor message and the test has no way to be
  # told when both have landed.
  defp wait_until(fun, remaining \\ 2_000) do
    cond do
      fun.() -> :ok
      remaining <= 0 -> flunk("condition never became true")
      true -> Process.sleep(5) || wait_until(fun, remaining - 5)
    end
  end
end
