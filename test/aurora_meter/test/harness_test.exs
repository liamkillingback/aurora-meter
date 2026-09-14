defmodule AuroraMeter.Test.HarnessTest do
  @moduledoc false
  # The harness's own self-tests. Every later unit's proof rests on these, so
  # they run first and nothing else may be built until they pass. The Pro copy
  # carries identical descriptions, so a divergence between the two mirrors is
  # visible as a diff.
  use ExUnit.Case, async: false

  # The fault lane (01f, `mix v1.faults`) runs `--only fault`. Every module
  # that exercises a fault point carries the tag, or it silently drops out of
  # the lane that exists to run it.
  @moduletag :fault

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Storage
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo

  @period ~U[2026-07-01 00:00:00Z]
  @date ~D[2026-07-03]

  # -- Faults: ownership and lifecycle (Y1, Y6) -------------------------------

  test "Y1 a fault armed by one process does not fire for an unrelated process" do
    test_pid = self()
    :ok = Faults.arm(:before_commit, :raise, count: :infinity)

    # spawn_monitor, not spawn then monitor: the stranger can finish before the
    # monitor is set up, and the :DOWN then carries :noproc rather than :normal.
    {stranger, reference} =
      spawn_monitor(fn ->
        send(test_pid, {:stranger, Faults.check(:before_commit, %{from: :stranger})})
      end)

    assert_receive {:stranger, :ok}
    assert_receive {:DOWN, ^reference, :process, ^stranger, :normal}
    assert Faults.fired() == []
  end

  test "Y1 a fault armed by a test fires inside a Task.async child through $callers" do
    :ok = Faults.arm(:before_commit, :raise, label: :through_callers)

    task =
      Task.async(fn ->
        try do
          Faults.check(:before_commit, %{from: :task})
        rescue
          error in [Faults.Injected] -> {:injected, error.point, error.label}
        end
      end)

    assert Task.await(task) == {:injected, :before_commit, :through_callers}
    assert :ok = Faults.assert_fired!(:before_commit)
    assert [{:before_commit, %{label: :through_callers, from: :task}, _}] = Faults.fired()
  end

  test "Y1 a fault armed by a test fires inside a Task.Supervisor.async_nolink child" do
    supervisor = start_supervised!(Task.Supervisor)
    :ok = Faults.arm(:after_claim, :raise, label: :nolink)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          Faults.check(:after_claim, %{from: :nolink})
        rescue
          error in [Faults.Injected] -> {:injected, error.point}
        end
      end)

    assert Task.await(task) == {:injected, :after_claim}
    assert :ok = Faults.assert_fired!(:after_claim)
  end

  test "Y1 a bare spawn without owner: does not inherit the fault" do
    test_pid = self()
    :ok = Faults.arm(:before_commit, :raise, count: :infinity)

    spawn(fn ->
      # A bare spawn carries no $callers, so the chain is [self()] only.
      send(test_pid, {:bare, Process.get(:"$callers"), Faults.check(:before_commit, %{})})
    end)

    assert_receive {:bare, nil, :ok}
    assert Faults.fired() == []
  end

  test "Y6 assert_fired! raises and names the points that did fire" do
    :ok = Faults.arm(:after_claim, :raise)
    assert_raise Faults.Injected, fn -> Faults.check(:after_claim, %{}) end

    error = assert_raise ExUnit.AssertionError, fn -> Faults.assert_fired!(:during_recovery) end
    assert error.message =~ "expected a fault at :during_recovery to have fired"
    assert error.message =~ "Points that did fire: [:after_claim]"
  end

  test "a count: 1 fault consumed by twelve concurrent checkers fires exactly once" do
    supervisor = start_supervised!(Task.Supervisor)
    :ok = Faults.arm(:before_commit, :raise, count: 1)

    outcomes =
      1..12
      |> Enum.map(fn index ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          try do
            Faults.check(:before_commit, %{index: index})
          rescue
            Faults.Injected -> :fired
          end
        end)
      end)
      |> Task.await_many(10_000)

    assert Enum.count(outcomes, &(&1 == :fired)) == 1
    assert Enum.count(outcomes, &(&1 == :ok)) == 11
    assert length(Faults.fired()) == 1
  end

  test "a count: :infinity fault fires on every check" do
    :ok = Faults.arm(:during_shutdown, {:delay, 1}, count: :infinity)
    for _ <- 1..5, do: :ok = Faults.check(:during_shutdown, %{})
    assert length(Faults.fired()) == 5
  end

  test "a when: predicate that rejects the context leaves the call untouched" do
    :ok = Faults.arm(:before_commit, :raise, count: :infinity, when: &(&1[:statement] == :wanted))

    assert :ok = Faults.check(:before_commit, %{statement: :unwanted})
    assert Faults.fired() == []
    assert_raise Faults.Injected, fn -> Faults.check(:before_commit, %{statement: :wanted}) end
    assert :ok = Faults.assert_fired!(:before_commit)
  end

  test "faults armed by a process that then dies are disarmed" do
    test_pid = self()

    owner =
      spawn(fn ->
        :ok = Faults.arm(:during_recovery, :raise, count: :infinity)
        send(test_pid, :armed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :armed
    assert :ets.lookup(Faults, {owner, :during_recovery}) != []

    reference = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^reference, :process, ^owner, :normal}

    # The disarm is the server's :DOWN handler. Signals from the dying process
    # to two different monitors carry no relative ordering guarantee, so this
    # waits for the server's own handling rather than assuming it has happened.
    assert_eventually(fn -> :ets.lookup(Faults, {owner, :during_recovery}) == [] end)
  end

  # -- Faults: actions --------------------------------------------------------

  test ":raise raises AuroraMeter.Test.Faults.Injected carrying the point and the label" do
    :ok = Faults.arm(:before_ack_persist, :raise, label: :ack)

    error =
      assert_raise Faults.Injected, fn -> Faults.check(:before_ack_persist, %{item: "x"}) end

    assert error.point == :before_ack_persist
    assert error.label == :ack
    assert error.context == %{item: "x"}
  end

  test ":exit_kill_self kills the checking process and the monitor reports :killed" do
    supervisor = start_supervised!(Task.Supervisor)
    :ok = Faults.arm(:before_commit, :exit_kill_self)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Faults.check(:before_commit, %{})
        :never_reached
      end)

    assert_receive {:DOWN, reference, :process, pid, reason}, 5_000
    assert reference == task.ref
    assert pid == task.pid
    assert reason == :killed
    assert :ok = Faults.assert_fired!(:before_commit)
  end

  test "{:block_until, ref} blocks until released and the owner receives the rendezvous message" do
    supervisor = start_supervised!(Task.Supervisor)
    reference = make_ref()
    :ok = Faults.arm(:after_provider_accept, {:block_until, reference})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Faults.check(:after_provider_accept, %{})
        :released
      end)

    assert_receive {:aurora_fault_blocked, :after_provider_accept, blocked, ^reference}, 5_000
    assert blocked == task.pid
    refute_receive {_, :released}, 50

    :ok = Faults.release(blocked, reference)
    assert Task.await(task) == :released
  end

  test "{:block_until, ref} raises AuroraMeter.Test.Faults.Timeout naming the ref when never released" do
    reference = make_ref()
    :ok = Faults.arm(:after_provider_accept, {:block_until, reference}, block_timeout: 100)

    error = assert_raise Faults.Timeout, fn -> Faults.check(:after_provider_accept, %{}) end

    assert error.ref == reference
    assert error.point == :after_provider_accept
    assert error.owner == self()
    assert error.blocked == self()
    assert Exception.message(error) =~ "was never released after 100ms"
  end

  test "{:delay, ms} delays at least ms and records the delay in the fired log" do
    :ok = Faults.arm(:during_shutdown, {:delay, 40})
    started = System.monotonic_time(:millisecond)
    :ok = Faults.check(:during_shutdown, %{})
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 40
    assert [{:during_shutdown, %{action: {:delay, 40}}, _}] = Faults.fired()
  end

  test "arming an unknown point raises and names the valid points" do
    error = assert_raise ArgumentError, fn -> Faults.arm(:before_send, :raise) end
    assert error.message =~ "unknown fault point :before_send"
    for point <- Faults.points(), do: assert(error.message =~ inspect(point))
    assert length(Faults.points()) == 7
  end

  # -- Test.Config (Y2, Y3) ---------------------------------------------------

  test "Y2 with_config restores a key that existed" do
    before = Application.fetch_env!(:aurora_meter, :flush_interval)

    Config.with_config([{:aurora_meter, :flush_interval, 1_234}], fn ->
      assert Application.fetch_env!(:aurora_meter, :flush_interval) == 1_234
    end)

    assert Application.fetch_env!(:aurora_meter, :flush_interval) == before
  end

  test "Y2 with_config deletes a key that did not exist" do
    assert Application.fetch_env(:aurora_meter, :harness_probe) == :error

    Config.with_config([{:aurora_meter, :harness_probe, 1}], fn ->
      assert Application.fetch_env!(:aurora_meter, :harness_probe) == 1
    end)

    assert Application.fetch_env(:aurora_meter, :harness_probe) == :error
  end

  test "Y2 with_config restores after a raise, a throw and a caught exit" do
    before = Application.fetch_env!(:aurora_meter, :flush_interval)
    override = [{:aurora_meter, :flush_interval, 1_234}]

    assert_raise RuntimeError, fn -> Config.with_config(override, fn -> raise "boom" end) end
    assert Application.fetch_env!(:aurora_meter, :flush_interval) == before

    assert catch_throw(Config.with_config(override, fn -> throw(:thrown) end)) == :thrown
    assert Application.fetch_env!(:aurora_meter, :flush_interval) == before

    assert catch_exit(Config.with_config(override, fn -> exit(:gone) end)) == :gone
    assert Application.fetch_env!(:aurora_meter, :flush_interval) == before
  end

  test "Y2 with_config restores when the calling process is killed" do
    before = Application.fetch_env!(:aurora_meter, :flush_interval)
    test_pid = self()

    holder =
      spawn(fn ->
        Config.with_config([{:aurora_meter, :flush_interval, 4_321}], fn ->
          send(test_pid, :applied)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :applied
    assert Application.fetch_env!(:aurora_meter, :flush_interval) == 4_321

    Process.exit(holder, :kill)

    # Taking the token orders this test behind the server's :DOWN handling,
    # which is what restores the snapshot after an untrappable kill.
    Config.with_config([], fn -> :ok end)
    assert Application.fetch_env!(:aurora_meter, :flush_interval) == before
  end

  test "Y3 two concurrent with_config regions do not overlap" do
    test_pid = self()

    body = fn name ->
      fn ->
        Config.with_config([{:aurora_meter, :harness_probe, name}], fn ->
          send(test_pid, {:entered, name})
          # Inside a region the key carries this region's value and no other.
          assert Application.fetch_env!(:aurora_meter, :harness_probe) == name
          Process.sleep(30)
          assert Application.fetch_env!(:aurora_meter, :harness_probe) == name
          send(test_pid, {:left, name})
        end)
      end
    end

    first = Task.async(body.(:first))
    second = Task.async(body.(:second))
    Task.await_many([first, second], 5_000)

    events =
      for _ <- 1..4 do
        receive do
          event -> event
        after
          1_000 -> flunk("expected four region events")
        end
      end

    assert [{:entered, one}, {:left, one}, {:entered, two}, {:left, two}] = events
    assert one != two
    assert Application.fetch_env(:aurora_meter, :harness_probe) == :error
  end

  test "Y3 a waiter blocked longer than the report interval logs the current holder" do
    test_pid = self()
    :ok = Config.put_report_interval(50)
    on_exit(fn -> Config.put_report_interval(30_000) end)

    log =
      capture_log(fn ->
        holder =
          Task.async(fn ->
            Config.with_config([{:aurora_meter, :harness_probe, :held}], fn ->
              send(test_pid, :holding)
              Process.sleep(300)
            end)
          end)

        assert_receive :holding
        waiter = Task.async(fn -> Config.with_config([], fn -> :ok end) end)
        Task.await_many([holder, waiter], 5_000)
      end)

    assert log =~ "has waited 50ms for the configuration token"
    assert log =~ "holding [aurora_meter: :harness_probe]"
  end

  test "put_config restores in on_exit" do
    # on_exit callbacks run in reverse registration order, so this assertion is
    # registered first and therefore runs after put_config's own restore.
    on_exit(fn -> assert Application.fetch_env(:aurora_meter, :harness_probe) == :error end)

    :ok = Config.put_config([{:aurora_meter, :harness_probe, :setup_style}])
    assert Application.fetch_env!(:aurora_meter, :harness_probe) == :setup_style
  end

  # -- FaultStorage -----------------------------------------------------------

  test "FaultStorage implements every AuroraMeter.Storage callback" do
    assert FaultStorage.uncovered_callbacks(Storage) == []

    excused = MapSet.new(FaultStorage.uninstrumentable(), &elem(&1, 0))

    assert MapSet.subset?(
             MapSet.difference(MapSet.new(Storage.behaviour_info(:callbacks)), excused),
             MapSet.new(FaultStorage.instrumented_callbacks())
           )
  end

  test "every uninstrumented FaultStorage callback is a real callback with a reason" do
    declared = MapSet.new(Storage.behaviour_info(:callbacks))

    for {entry, reason} <- FaultStorage.uninstrumentable() do
      assert MapSet.member?(declared, entry),
             "#{inspect(entry)} is excused from instrumentation but is not a Storage callback"

      assert is_binary(reason) and String.trim(reason) != "",
             "#{inspect(entry)} is excused from instrumentation with no reason"
    end
  end

  test "FaultStorage delegates flush_batch unchanged when nothing is armed" do
    tenant = tenant!("harnessa")
    Connections.checkout!()
    id = Ecto.UUID.generate()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:ok, %{counters: [%{value: 5}], history: [%{value: 5}]}} =
               Storage.flush_batch(id, counters(tenant), history(tenant))
    end)

    assert Storage.load_counter(tenant, :ops, @period) == 5
    assert Faults.fired() == []
    TestRepo.delete_all(receipt_query(id))
  end

  test "seed for I02: :before_commit on flush_batch leaves no receipt, counter or history row" do
    tenant = tenant!("harnessa")
    Connections.checkout!()
    id = Ecto.UUID.generate()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      :ok = Faults.arm(:before_commit, :raise, when: &(&1[:callback] == :flush_batch))

      assert_raise Faults.Injected, fn ->
        Storage.flush_batch(id, counters(tenant), history(tenant))
      end

      :ok = Faults.assert_fired!(:before_commit)
    end)

    assert Storage.load_counter(tenant, :ops, @period) == nil
    assert Storage.load_history(tenant, :ops, @date) == nil
    assert TestRepo.get(FlushReceipt, id) == nil
  end

  test "seed for I01: :after_commit_before_ack commits the batch and raises before the caller learns" do
    tenant = tenant!("harnessa")
    Connections.checkout!()
    id = Ecto.UUID.generate()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      :ok = Faults.arm(:after_commit_before_ack, :raise, when: &(&1[:callback] == :flush_batch))

      assert_raise Faults.Injected, fn ->
        Storage.flush_batch(id, counters(tenant), history(tenant))
      end

      :ok = Faults.assert_fired!(:after_commit_before_ack)
    end)

    # The commit is real; only the acknowledgement was lost.
    assert Storage.load_counter(tenant, :ops, @period) == 5
    assert TestRepo.get(FlushReceipt, id)
    TestRepo.delete_all(receipt_query(id))
  end

  # -- FaultRepo --------------------------------------------------------------

  test "FaultRepo exports every repo function lib/ calls" do
    sites = FaultRepo.call_sites(["lib"])
    assert length(sites) > 20, "expected the parse to find the known repo call sites"
    assert FaultRepo.uncovered_call_sites(["lib"]) == []
  end

  test "FaultRepo classifies the receipt insert, counter upsert and history upsert distinctly" do
    assert FaultRepo.statement(FlushReceipt, :insert_all) == :receipt_insert
    assert FaultRepo.statement(Counter, :insert_all) == :counter_upsert
    assert FaultRepo.statement(History, :insert_all) == :history_upsert
    assert FaultRepo.statement(CreditTransaction, :insert) == :transaction_insert
    assert FaultRepo.statement(CreditTransaction, :update!) == :transaction_update
    assert FaultRepo.statement(CreditBalance, :update!) == :balance_update
    assert FaultRepo.statement(nil, :all) == :other
  end

  test "seed for I02: failing the history upsert rolls back the counter and the receipt" do
    assert_statement_rolls_back(:history_upsert)
  end

  test "seed for I02: failing the counter upsert rolls back the receipt" do
    assert_statement_rolls_back(:counter_upsert)
  end

  test "seed for I02: failing the receipt insert writes nothing" do
    assert_statement_rolls_back(:receipt_insert)
  end

  test "a rollback raised through the shim propagates as Ecto raises it" do
    Connections.checkout!()

    Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      assert {:error, :refused} = FaultRepo.transaction(fn -> FaultRepo.rollback(:refused) end)
    end)
  end

  # -- Connections (Y4) -------------------------------------------------------

  test "Y4 run/3 checks every connection back in when a body raises" do
    capture_log(fn ->
      assert catch_exit(Connections.run(4, fn index -> if index == 2, do: raise("boom") end))
    end)

    # Every connection the failed run took is back: a second run of the same
    # width succeeds rather than timing out on checkout.
    assert Connections.run(4, fn index -> index end) == [1, 2, 3, 4]
  end

  test "Y4 run/3 returns results in index order" do
    assert Connections.run(6, fn index -> index * 10 end) == [10, 20, 30, 40, 50, 60]
  end

  test "Y4 cleanup! deletes only rows whose tenant_key carries the prefix" do
    mine = tenant!("harnessa")
    theirs = tenant!("harnessb")
    Connections.checkout!()

    {:ok, _} = Storage.Ecto.add_counters(counters(mine) ++ counters(theirs))
    assert Storage.load_counter(mine, :ops, @period) == 5
    assert Storage.load_counter(theirs, :ops, @period) == 5

    :ok = Connections.cleanup!(mine)
    assert Storage.load_counter(mine, :ops, @period) == nil
    assert Storage.load_counter(theirs, :ops, @period) == 5
  end

  test "Y4 cleanup! refuses a prefix shorter than four characters" do
    Connections.checkout!()
    before = Connections.row_counts()

    error = assert_raise ArgumentError, fn -> Connections.cleanup!("ab") end
    assert error.message =~ "a prefix shorter than four characters"
    assert Connections.row_counts() == before

    assert_raise ArgumentError, fn -> Connections.cleanup!("not a tenant key") end
    assert Connections.row_counts() == before
  end

  test "Y4 cleanup! covers every schema the package owns" do
    known = MapSet.new(Connections.tables() ++ Connections.tenantless())
    schemas = package_schemas(:aurora_meter, "Elixir.AuroraMeter.Schema.")
    assert schemas != []

    for schema <- schemas do
      assert MapSet.member?(known, schema),
             "#{inspect(schema)} is not in AuroraMeter.Test.Connections.tables/0 or " <>
               "tenantless/0; a table added without a cleanup entry leaks rows into later runs"
    end
  end

  test "run/3 refuses more tasks than the pool can serve and says the arithmetic" do
    too_many = Connections.max_tasks() + 1
    error = assert_raise ArgumentError, fn -> Connections.run(too_many, fn index -> index end) end

    assert error.message =~ "refuses #{too_many} tasks"
    assert error.message =~ "#{Connections.pool_size()} - 4 = #{Connections.max_tasks()}"
  end

  # -- Kill (Y5) --------------------------------------------------------------

  test "Y5 a killed worker is observed as :killed, not as a caught exit" do
    assert {:killed, pid} =
             Kill.run(
               fn ->
                 Faults.check(:before_commit, %{})
                 :never_reached
               end,
               at: :before_commit
             )

    assert is_pid(pid)
    refute Process.alive?(pid)
    assert :ok = Faults.assert_fired!(:before_commit)
  end

  test "Y5 a worker killed before commit leaves nothing in the database" do
    tenant = tenant!("harnessa")
    id = Ecto.UUID.generate()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:killed, _} =
               Kill.run(
                 fn ->
                   Connections.checkout!()
                   Storage.flush_batch(id, counters(tenant), history(tenant))
                 end,
                 at: :before_commit,
                 when: &(&1[:callback] == :flush_batch)
               )
    end)

    Kill.assert_db!(fn ->
      assert Storage.load_counter(tenant, :ops, @period) == nil
      assert TestRepo.get(FlushReceipt, id) == nil
    end)
  end

  test "Y5 a worker killed after commit leaves the committed row and no acknowledgement" do
    tenant = tenant!("harnessa")
    id = Ecto.UUID.generate()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:killed, _} =
               Kill.run(
                 fn ->
                   Connections.checkout!()
                   Storage.flush_batch(id, counters(tenant), history(tenant))
                 end,
                 at: :after_commit_before_ack,
                 when: &(&1[:callback] == :flush_batch)
               )
    end)

    Kill.assert_db!(fn ->
      assert Storage.load_counter(tenant, :ops, @period) == 5
      assert TestRepo.get(FlushReceipt, id)
      TestRepo.delete_all(receipt_query(id))
    end)
  end

  test "Y5 run/2 fails the test when the worker finishes normally although a kill was armed" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Kill.run(fn -> :finished end, at: :during_recovery)
      end

    assert error.message =~ "expected the worker to be killed at :during_recovery"
    assert error.message =~ ":finished"
  end

  defmodule Restartable do
    @moduledoc false
    use GenServer

    @table :aurora_harness_restart_probe

    @doc false
    @spec table() :: atom()
    def table, do: @table

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      # Deliberately the shape of AuroraMeter.Store: :gen_server registers the
      # name before it calls init/1, so anything a test needs that init/1
      # creates does not exist yet at the moment the name resolves.
      :ets.new(@table, [:set, :public, :named_table])
      {:ok, %{}}
    end
  end

  test "Y5 await_restart! returns the new pid once the supervisor has replaced the old one" do
    # A supervisor of this module's own, so the self-test does not spend any of
    # AuroraMeter.Supervisor's three restarts in five seconds. AuroraMeter.KillTest
    # spends all three.
    supervisor =
      start_supervised!(%{
        id: :restart_probe,
        type: :supervisor,
        start: {Supervisor, :start_link, [[Restartable], [strategy: :one_for_one]]}
      })

    old = Process.whereis(Restartable)
    assert is_pid(old)

    Process.exit(old, :kill)
    restarted = Kill.await_restart!(Restartable, from: old, supervisor: supervisor)

    assert is_pid(restarted)
    refute restarted == old
    assert Process.whereis(Restartable) == restarted
    assert Process.alive?(supervisor)

    # The readiness half: whatever init/1 creates is there. Returning on the
    # registration alone made AuroraMeter.KillTest fail intermittently with
    # "the table identifier does not refer to an existing ETS table".
    assert :ets.lookup(Restartable.table(), :anything) == []
  end

  test "Y5 await_restart! raises naming both pids when nothing is restarted" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Kill.await_restart!(AuroraMeter.Test.Faults, timeout: 20)
      end

    assert error.message =~ "was not restarted within 20ms"
    assert error.message =~ "AuroraMeter.Test.Faults"
  end

  # -- Clock ------------------------------------------------------------------
  #
  # `AuroraMeter.Test.Clock` was 01b's temporary settable clock and said so in
  # its own moduledoc. Build unit 02c deleted it and replaced it with the real
  # seam: `AuroraMeter.Clock` behind the `clock:` key, `AuroraMeter.Clock.Fixed`
  # in `lib/`, and `AuroraMeter.Test.with_clock/2` to install it. Its tests moved
  # to `test/aurora_meter/clock_test.exs`, which covers rather more than these
  # two did: configuration restored on a raise and on an exit, visibility from an
  # unrelated process, and all four readings answered from one frozen instant.

  # -- helpers ----------------------------------------------------------------

  defp assert_statement_rolls_back(statement) do
    tenant = tenant!("harnessa")
    Connections.checkout!()
    id = Ecto.UUID.generate()
    counts_before = Connections.row_counts()

    Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      :ok =
        Faults.arm(:before_commit, :raise,
          label: statement,
          when: &(&1[:statement] == statement and &1[:kind] == :write)
        )

      assert_raise Faults.Injected, fn ->
        Storage.Ecto.flush_batch(id, counters(tenant), history(tenant))
      end

      :ok = Faults.assert_fired!(:before_commit)
    end)

    assert Storage.load_counter(tenant, :ops, @period) == nil
    assert Storage.load_history(tenant, :ops, @date) == nil
    assert TestRepo.get(FlushReceipt, id) == nil

    # The unfaulted retry writes the batch exactly once.
    assert {:ok, _} = Storage.Ecto.flush_batch(id, counters(tenant), history(tenant))
    assert Storage.load_counter(tenant, :ops, @period) == 5
    assert Storage.load_history(tenant, :ops, @date) == 5
    TestRepo.delete_all(receipt_query(id))

    # The conservation line scripts/v1/faults.sh consumes, taken after this
    # test has given back every row it owns, so a non-zero delta means the
    # harness leaked. A no-op unless AURORA_FAULT_REPORT names a file.
    :ok = Connections.cleanup!(tenant)
    counts_after = Connections.row_counts()
    delta = Map.new(counts_after, fn {k, v} -> {k, v - Map.fetch!(counts_before, k)} end)
    assert Enum.all?(delta, fn {_schema, change} -> change == 0 end), inspect(delta)

    Connections.report!(%{
      test: "seed for I02: failing the #{statement}",
      seed: ExUnit.configuration()[:seed],
      point: :before_commit,
      action: :raise,
      tenant_prefix: tenant,
      before: counts_before,
      after: counts_after,
      delta: delta
    })
  end

  defp tenant!(prefix) do
    tenant = AuroraMeter.Test.unique_tenant(prefix)
    on_exit(fn -> Connections.cleanup!(tenant) end)
    tenant
  end

  defp receipt_query(id), do: from(r in FlushReceipt, where: r.id == ^id)

  defp package_schemas(app, prefix) do
    app
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), prefix))
  end

  defp assert_eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the condition never held")
      true -> assert_eventually_after(fun, tries)
    end
  end

  defp assert_eventually_after(fun, tries) do
    # The only sleep in the harness self-tests, and the reason is written down:
    # a monitor's :DOWN handling in another process has no synchronisation
    # point a test can take.
    Process.sleep(5)
    assert_eventually(fun, tries - 1)
  end

  defp counters(tenant),
    do: [%{tenant_key: tenant, feature: :ops, period_start: @period, delta: 5}]

  defp history(tenant), do: [%{tenant_key: tenant, feature: :ops, date: @date, delta: 5}]
end
