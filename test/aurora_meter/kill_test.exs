defmodule AuroraMeter.KillTest do
  @moduledoc """
  Actual process death: what survives a `Process.exit(pid, :kill)` and what does
  not (build unit 01c, `open-findings.md` T1).

  Before this module nothing in either suite killed a process. Death was
  simulated by editing rows into the shape the author believed a crash would
  leave, which is the assumption under test. Every kill here is untrappable and
  every one asserts a `:DOWN` reason of exactly `:killed`, so a catchable exit
  can never pass for process death (G01 bullet 2).

  **This module must stay `async: false` and must never be flipped to `true`.**
  Killing `AuroraMeter.Store` destroys the global ETS tables that every other
  test in the run shares; a kill racing an async test would surface as an
  unrelated failure somewhere else entirely. ExUnit runs synchronous modules one
  at a time, which is the only thing containing it.

  **This module consumes the whole of `AuroraMeter.Supervisor`'s restart
  budget.** The supervisor is `one_for_one` with OTP's defaults, three restarts
  in five seconds, and the three tests below kill a supervised child once each.
  A fourth automatic restart inside the same five seconds would take the
  supervisor down and every later test with it, so a unit adding a kill test
  here (03b, 05c) must either replace one of these or space them deliberately.
  `Supervisor.restart_child/2`, which `AuroraMeter.FlusherTest` uses, is a
  manual restart and does not count.
  """
  use ExUnit.Case, async: false

  # `mix v1.faults` (an alias in mix.exs) runs every module tagged :fault with a
  # fixed seed, and CI runs it as its own job. The tag is NOT excluded in
  # test/test_helper.exs, so this module also runs inside the ordinary `mix test`
  # and the dedicated job is a second, seeded run rather than the only one.
  @moduletag :fault

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    assert Process.alive?(Process.whereis(AuroraMeter.Supervisor)),
           "AuroraMeter.Supervisor is gone: an earlier kill test exhausted its restart budget"

    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    allow_flusher!()

    # Discard, never flush, what an earlier module left pending: see
    # AuroraMeter.StatementsTest's setup for why a drain flush in a non-sandbox
    # module poisons the test database across runs.
    :ok = AuroraMeter.Test.reset!()

    tenant = AuroraMeter.Test.unique_tenant("killt")
    counts_before = Connections.row_counts()

    # Receipt ids are collected in the test process's dictionary rather than in
    # an ETS table: a table created here is owned by the test process and is
    # already gone by the time `on_exit` runs in its own process.
    on_exit(fn -> Connections.cleanup!(tenant) end)

    {:ok, tenant: tenant, counts_before: counts_before, period: Period.current(tenant).start}
  end

  @test_root Path.expand("../..", __DIR__)
  @self "test/aurora_meter/kill_test.exs"
  @budget 3

  # The moduledoc above says this module spends the whole restart budget. It
  # said so before today too, and `store_gauge_test.exs` spent a fourth anyway,
  # which took `AuroraMeter.Supervisor` down mid-suite whenever the seed placed
  # the two `async: false` modules close together. A rule nothing enforces is one
  # already being broken (`open-findings.md` X153, X347, X349).
  #
  # So the moduledoc is now an assertion. A test that needs a child of
  # `AuroraMeter.Supervisor` to run `init/1` again should use
  # `Supervisor.terminate_child/2` plus `Supervisor.restart_child/2`, which runs
  # the same code and is not charged against restart intensity.
  test "this module is the only one that spends AuroraMeter.Supervisor's restart budget" do
    names = supervised_names()

    automatic =
      for path <- test_files(),
          {line, number} <- numbered_lines(path),
          automatic_restart?(line, names),
          do: {relative(path), number, String.trim(line)}

    {mine, others} = Enum.split_with(automatic, &(elem(&1, 0) == @self))

    assert others == [],
           "a supervised child of AuroraMeter.Supervisor is killed and left to restart " <>
             "automatically outside #{@self}: #{inspect(others)}. The supervisor is " <>
             "one_for_one with OTP's defaults, three restarts in five seconds, and this " <>
             "module spends all three, so that is a FOURTH: it takes the tree down and " <>
             "every later test with it whenever the seed runs the two modules close " <>
             "together. Use Supervisor.terminate_child/2 plus Supervisor.restart_child/2, " <>
             "which runs init/1 on the same path and is not charged against intensity."

    assert length(mine) == @budget,
           "#{@self} makes #{length(mine)} automatic restarts and the budget is " <>
             "#{@budget}: #{inspect(mine)}. Spending fewer is fine only if this number " <>
             "and the moduledoc are changed together; spending more is the same fault as " <>
             "spending one elsewhere."
  end

  defp test_files, do: Path.wildcard(Path.join(@test_root, "test/**/*.exs"))

  defp numbered_lines(path) do
    path |> File.read!() |> String.split("\n") |> Enum.with_index(1)
  end

  defp relative(path), do: Path.relative_to(path, @test_root)

  # The registered names of everything AuroraMeter.Supervisor is currently
  # supervising, read from the running tree rather than from a list kept here: a
  # child added by a later unit is covered without anyone remembering to.
  defp supervised_names do
    names =
      AuroraMeter.Supervisor
      |> Supervisor.which_children()
      |> Enum.flat_map(fn {id, pid, _type, _modules} -> [id | registered_name(pid)] end)
      |> Enum.map(&short_name/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    # A detector that can quietly match nothing is the failure mode this suite
    # keeps finding (X325). If the tree ever stops answering, say so here.
    refute Enum.empty?(names),
           "AuroraMeter.Supervisor reported no supervised children, so this guard would " <>
             "pass by matching nothing."

    names
  end

  # `Module.split/1` raises on an atom that is not an Elixir module, which a
  # child id is allowed to be.
  defp short_name(name) when is_atom(name) and name not in [nil, :undefined] do
    name |> Module.split() |> List.last()
  rescue
    ArgumentError -> nil
  end

  defp short_name(_other), do: nil

  defp registered_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> [name]
      _other -> []
    end
  end

  defp registered_name(_other), do: []

  # `await_restart!` waits for a *supervisor* to put a replacement in the
  # registry, so a call naming a child of AuroraMeter.Supervisor is one
  # automatic restart. A call carrying `supervisor:` names a different tree and
  # spends a different budget, which is what the harness's own tests do.
  defp automatic_restart?(line, names) do
    case Regex.run(~r/await_restart!\(\s*(?:[A-Z][\w.]*\.)?([A-Z]\w*)/, line) do
      [_match, name] -> MapSet.member?(names, name) and not String.contains?(line, "supervisor:")
      nil -> false
    end
  end

  test "I03 a with_quota caller killed with :kill is never billed and leaves a documented reservation",
       context do
    %{tenant: tenant, period: period} = context
    key = {tenant, :ai_generations, period}

    # The default plan is :free, whose hard limit on :ai_generations is 50.
    assert AuroraMeter.remaining(tenant, :ai_generations) == 50

    assert {:killed, pid} =
             Kill.run(
               fn ->
                 Connections.checkout!()

                 AuroraMeter.with_quota(tenant, :ai_generations, 3, fn ->
                   Faults.check(:before_commit, %{gated: :ai_generations})
                   :never_reached
                 end)
               end,
               at: :before_commit
             )

    refute Process.alive?(pid)
    :ok = Faults.assert_fired!(:before_commit)

    # The leak, measured: the reservation is still counted, and it is counted
    # only in `value` and `reserved`. `pending_flush` and `pending_gossip` are
    # both zero, which is why it can never be billed or gossiped as usage (Z1).
    assert [{^key, 3, 0, 0, 0, 3}] = :ets.lookup(Store.counters_table(), key)

    # Nothing reaches the database, on this flush or any later one.
    assert {:ok, _} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ai_generations, period) end) == nil
    assert fresh(fn -> Storage.load_history(tenant, :ai_generations, Date.utc_today()) end) == nil

    # The observable cost D09 accepts, and its exact size: 3 units of local
    # quota, occupied until the Store restarts or the period rolls over.
    assert AuroraMeter.remaining(tenant, :ai_generations) == 47
    assert AuroraMeter.usage(tenant, :ai_generations) == 3

    report!(context, :before_commit, "I03 killed with_quota caller")
  end

  test "I04 a killed caller's reservation continues to occupy the limit on that node", context do
    %{tenant: tenant, period: period} = context

    # A limit of 50, of which a killed caller takes 48 with it. The two that are
    # left are still admitted; the forty-nine that would have been are not.
    assert {:killed, _pid} =
             Kill.run(
               fn ->
                 Connections.checkout!()

                 AuroraMeter.with_quota(tenant, :ai_generations, 48, fn ->
                   Faults.check(:before_commit, %{gated: :ai_generations})
                 end)
               end,
               at: :before_commit
             )

    :ok = Faults.assert_fired!(:before_commit)

    assert [{_key, 48, 0, 0, 0, 48}] =
             :ets.lookup(Store.counters_table(), {tenant, :ai_generations, period})

    assert AuroraMeter.reserve(tenant, :ai_generations, 2) == :ok
    assert AuroraMeter.reserve(tenant, :ai_generations, 1) == {:error, :limit_exceeded}
    assert AuroraMeter.remaining(tenant, :ai_generations) == 0

    # Never billed, however much quota it occupies: only the two real units are
    # flushable, because the leaked 48 are reserved and not pending.
    track_receipt!(Store.snapshot_flush_batch().id)
    assert {:ok, _} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ai_generations, period) end) == 2

    report!(context, :before_commit, "I04 killed caller occupies the limit")
  end

  test "I01 a Flusher killed between the snapshot and the persist keeps the batch in Store",
       context do
    %{tenant: tenant, period: period} = context
    AuroraMeter.track(tenant, :ops, 6)

    # Exactly what Flusher.batch/0 does: the batch is taken by the ETS owner and
    # published into a table the Flusher does not own.
    batch = Store.snapshot_flush_batch()
    track_receipt!(batch.id)

    pid = kill!(Flusher)
    restarted = Kill.await_restart!(Flusher, from: pid)
    refute restarted == pid
    :ok = Sandbox.allow(TestRepo, self(), restarted)

    # Z4: the Flusher owns nothing. The pending batch is still there, under the
    # same id, so the retry is the identical batch.
    assert [{:pending, retained}] = :ets.lookup(Store.flush_batches_table(), :pending)
    assert retained.id == batch.id

    assert {:ok, _} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == 6
    assert fresh(fn -> receipt_count(batch.id) end) == 1

    report!(context, :kill, "I01 Flusher killed after the snapshot")
  end

  test "I01 a Store killed before the flush loses the buffered deltas, as documented", context do
    %{tenant: tenant, period: period} = context

    AuroraMeter.track(tenant, :ops, 6)
    batch = Store.snapshot_flush_batch()
    track_receipt!(batch.id)

    # And two more, buffered behind the batch that has already been taken.
    AuroraMeter.track(tenant, :ops, 2)

    pid = kill!(Store)
    restarted = Kill.await_restart!(Store, from: pid)
    refute restarted == pid

    # Z5: the Store owns the tables, so `one_for_one` hands it new, empty ones.
    # Both the retained batch and the two buffered units are gone.
    assert :ets.lookup(Store.flush_batches_table(), :pending) == []
    assert Store.snapshot_flush_batch() == nil
    assert :ets.lookup(Store.counters_table(), {tenant, :ops, period}) == []

    # This is the documented buffered-loss boundary (architecture-map section
    # 12, I01's known limits), not a defect: nothing was written, so nothing was
    # written twice either.
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == nil
    assert fresh(fn -> receipt_count(batch.id) end) == 0
    assert {:ok, 0} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == nil

    report!(context, :kill, "I01 Store killed before the flush")
  end

  test "I03 Counter.commit_work after a Store restart seeds rather than raising (C6, fixed in 03b)",
       context do
    %{tenant: tenant, period: period} = context
    on = Date.utc_today()

    # A deferred reservation, exactly as with_quota/4 takes one.
    assert :ok = Counter.reserve(tenant, :ai_generations, 2, period, nil, true)
    assert AuroraMeter.usage(tenant, :ai_generations) == 2

    pid = kill!(Store)
    _restarted = Kill.await_restart!(Store, from: pid)

    # C6, and this is the assertion 03b flipped. Neither `commit_work/5` nor
    # `release_work/4` called `ensure_seeded/1`, so both raised `ArgumentError`
    # from `:ets.update_counter/3` on a key the restart had taken away: a raise
    # *after* the caller's callback had already succeeded, carrying a message
    # that named neither the tenant nor the feature. Both now seed first.
    assert Counter.commit_work(tenant, :ai_generations, 2, period, on) == :ok

    # The reservation itself went with the table, which is the documented
    # buffered-loss boundary (architecture-map section 12). What must not be
    # lost is the work that *completed*: it is pending for the next flush.
    track_receipt!(Store.snapshot_flush_batch().id)
    assert {:ok, n} = Flusher.flush()
    assert n >= 1
    assert fresh(fn -> Storage.load_counter(tenant, :ai_generations, period) end) == 2

    # `release_work/4` on a key that was never warm takes the same path, and a
    # cold key needs no second kill to produce.
    assert Counter.release_work(tenant, :never_reserved, 2, period) == :ok
    assert Counter.value(tenant, :never_reserved, period) == -2

    # And the deferred reserve that always seeded still does. The view reads 2
    # and not 4, and that number is the price of the fix rather than a defect
    # in it: `commit_work/5` took `reserved` to -2 on a row whose reservation
    # the restart had already destroyed, and `Counter.rebase/3` adds `reserved`
    # into the value it rebases to, so this node's view sits one lost
    # reservation below the database until the next cold seed. The arithmetic
    # of `commit_work/5` is deliberately unchanged (03b's brief); what changed
    # is that it no longer raises out of a callback that has already succeeded.
    assert :ok = Counter.reserve(tenant, :ai_generations, 2, period, nil, true)
    assert AuroraMeter.usage(tenant, :ai_generations) == 2
    assert fresh(fn -> Storage.load_counter(tenant, :ai_generations, period) end) == 2

    report!(context, :kill, "I03 C6 commit_work after a Store restart")
  end

  # -- helpers ----------------------------------------------------------------

  defp kill!(name) do
    pid = Process.whereis(name)
    reference = Process.monitor(pid)
    Process.exit(pid, :kill)

    # Exactly :killed. A catchable exit reaching this assertion would mean the
    # test proved nothing about untrappable death.
    assert_receive {:DOWN, ^reference, :process, ^pid, :killed}, 5_000
    pid
  end

  defp allow_flusher! do
    :ok = Sandbox.allow(TestRepo, self(), Process.whereis(Flusher))
  end

  defp fresh(fun) do
    [result] = Connections.run(1, fn _index -> fun.() end)
    result
  end

  defp receipt_count(id),
    do: TestRepo.aggregate(from(r in FlushReceipt, where: r.id == ^id), :count)

  defp track_receipt!(id) do
    Process.put(:receipt_ids, [id | Process.get(:receipt_ids, [])])
    id
  end

  defp cleanup!(tenant) do
    :ok = Connections.cleanup!(tenant)
    ids = Process.get(:receipt_ids, [])
    Connections.checkout!()
    TestRepo.delete_all(from(r in FlushReceipt, where: r.id in ^ids))
    :ok
  end

  # The conservation line scripts/v1/faults.sh consumes, taken after this test
  # has given back every row it owns. A no-op unless AURORA_FAULT_REPORT names a
  # file.
  defp report!(context, point, label) do
    cleanup!(context.tenant)
    counts_after = Connections.row_counts()

    delta =
      Map.new(counts_after, fn {schema, count} ->
        {schema, count - Map.fetch!(context.counts_before, schema)}
      end)

    assert Enum.all?(delta, fn {_schema, change} -> change == 0 end), inspect(delta)

    Connections.report!(%{
      test: label,
      seed: ExUnit.configuration()[:seed],
      point: point,
      action: :exit_kill_self,
      tenant_prefix: context.tenant,
      before: context.counts_before,
      after: counts_after,
      delta: delta
    })
  end
end
