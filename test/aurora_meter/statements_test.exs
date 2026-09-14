defmodule AuroraMeter.StatementsTest do
  @moduledoc """
  I02: each statement of `AuroraMeter.Storage.Ecto.flush_batch/3` forced to fail
  in turn (build unit 01c).

  Not `AuroraMeter.DataCase`. The sandbox wraps a test in one transaction on one
  connection, so a rolled-back flush would be invisible: the assertion would read
  the same connection that aborted and see exactly what the test wanted to see.
  Every assertion here is made on a connection taken after the failure, through
  `AuroraMeter.Test.Connections.run/3`, which never saw the aborted transaction.
  That is the difference between this module and a smoke test.

  The flush is driven through `AuroraMeter.Flusher.flush/0`, the production
  entry point, which is a `GenServer.call`: the storage callback and therefore
  the fault check run in the Flusher process, so every fault here names that pid
  as its `owner:`. The Flusher is allowed onto this test's non-sandbox
  connection with `Ecto.Adapters.SQL.Sandbox.allow/3`; when the test process
  exits the ownership is released and the allowance with it.

  The three statements are the ones `storage/ecto.ex:20-55` issues, in order:
  the receipt insert, the counter upsert, the history upsert.
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
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    flusher = Process.whereis(Flusher)
    :ok = Sandbox.allow(TestRepo, self(), flusher)

    # DISCARD, never flush, whatever an earlier module left pending. This module
    # runs on real connections, so a drain flush here would commit another
    # module's sandbox-owned `org_<n>` deltas for good, and the next `mix test`
    # reuses those integers: the poisoned rows then seed a later run's counters.
    # reset!/0 throws the buffer away and touches no row, which is what a
    # non-sandbox module wants, and it is safe because this module is
    # `async: false`.
    :ok = AuroraMeter.Test.reset!()
    :ok = Faults.forget(owner: flusher)

    tenant = AuroraMeter.Test.unique_tenant("stmt")
    counts_before = Connections.row_counts()

    # Receipt ids are collected in the test process's dictionary rather than in
    # an ETS table: a table created here is owned by the test process and is
    # already gone by the time `on_exit` runs in its own process.
    on_exit(fn -> Connections.cleanup!(tenant) end)

    {:ok,
     tenant: tenant,
     flusher: flusher,
     counts_before: counts_before,
     period: Period.current(tenant).start,
     day: Date.utc_today()}
  end

  test "I02 a failing receipt insert writes nothing and reaches no later statement", context do
    %{tenant: tenant, flusher: flusher} = context
    AuroraMeter.track(tenant, :ops, 5)
    batch = take_batch!()

    parent = self()

    Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      # count: :infinity so the predicate keeps recording after the fault has
      # fired. The predicate is documented to run exactly once per check, in the
      # checking process, so the side effect is sound with a single checker and
      # the fired log becomes a log of every statement the transaction reached.
      :ok =
        Faults.arm(:before_commit, :raise,
          owner: flusher,
          count: :infinity,
          label: :receipt_insert,
          when: fn ctx ->
            if ctx[:kind] == :write, do: send(parent, {:reached, ctx[:statement]})
            ctx[:statement] == :receipt_insert and ctx[:kind] == :write
          end
        )

      assert {:error, _reason} = Flusher.flush()
      :ok = Faults.assert_fired!(:before_commit, owner: flusher)
      :ok = Faults.disarm(:before_commit, owner: flusher)
    end)

    reached = drain_reached()
    assert :receipt_insert in reached
    refute :counter_upsert in reached, "the counter upsert ran after the receipt insert failed"
    refute :history_upsert in reached, "the history upsert ran after the receipt insert failed"

    assert_nothing_written(context, batch)
    assert_retry_writes_once(context, batch)
    report!(context, :receipt_insert)
  end

  test "I02 a failing counter upsert rolls back the receipt", context do
    assert_statement_rolls_back(context, :counter_upsert)
  end

  test "I02 a failing history upsert rolls back the counter and the receipt", context do
    assert_statement_rolls_back(context, :history_upsert)
  end

  test "I02 a retry after a failed statement applies the deltas exactly once", context do
    %{tenant: tenant, flusher: flusher, period: period} = context
    AuroraMeter.track(tenant, :ops, 5)
    batch = take_batch!()

    Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      :ok =
        Faults.arm(:before_commit, :raise,
          owner: flusher,
          count: 1,
          label: :counter_upsert,
          when: &(&1[:statement] == :counter_upsert and &1[:kind] == :write)
        )

      assert {:error, _reason} = Flusher.flush()
      :ok = Faults.assert_fired!(:before_commit, owner: flusher)
    end)

    # The batch is retained under its original id, so the retry is the same
    # batch and not a fresh one built from whatever is pending now.
    assert Store.snapshot_flush_batch().id == batch.id

    assert {:ok, _} = Flusher.flush()

    # Exactly once: five, not ten, and one receipt for the one batch id.
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == 5
    assert fresh(fn -> receipt_count(batch.id) end) == 1

    # And a further flush with nothing pending adds nothing.
    assert {:ok, 0} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == 5
    report!(context, :counter_upsert)
  end

  # -- helpers ----------------------------------------------------------------

  defp assert_statement_rolls_back(context, statement) do
    %{tenant: tenant, flusher: flusher} = context
    AuroraMeter.track(tenant, :ops, 5)
    batch = take_batch!()

    Config.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      :ok =
        Faults.arm(:before_commit, :raise,
          owner: flusher,
          count: 1,
          label: statement,
          when: &(&1[:statement] == statement and &1[:kind] == :write)
        )

      assert {:error, _reason} = Flusher.flush()
      :ok = Faults.assert_fired!(:before_commit, owner: flusher)
    end)

    assert_nothing_written(context, batch)
    assert_retry_writes_once(context, batch)
    report!(context, statement)
  end

  # Every one of these reads happens on a connection checked out after the
  # failed transaction ended, so none of them can be reading uncommitted state
  # the aborting connection could still see.
  defp assert_nothing_written(context, batch) do
    %{tenant: tenant, period: period, day: day} = context

    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == nil
    assert fresh(fn -> Storage.load_history(tenant, :ops, day) end) == nil
    assert fresh(fn -> receipt_count(batch.id) end) == 0

    # The delta is not lost: it is still pending in the retained batch.
    assert Store.snapshot_flush_batch().id == batch.id
  end

  defp assert_retry_writes_once(context, batch) do
    %{tenant: tenant, period: period, day: day} = context

    assert {:ok, _} = Flusher.flush()
    assert fresh(fn -> Storage.load_counter(tenant, :ops, period) end) == 5
    assert fresh(fn -> Storage.load_history(tenant, :ops, day) end) == 5
    assert fresh(fn -> receipt_count(batch.id) end) == 1
    assert Counter.value(tenant, :ops, period) == 5
  end

  defp take_batch! do
    batch = Store.snapshot_flush_batch()
    assert %{id: id} = batch
    track_receipt!(id)
    batch
  end

  defp track_receipt!(id) do
    Process.put(:receipt_ids, [id | Process.get(:receipt_ids, [])])
    id
  end

  defp delete_receipts! do
    ids = Process.get(:receipt_ids, [])
    Connections.checkout!()
    TestRepo.delete_all(from(r in FlushReceipt, where: r.id in ^ids))
    :ok
  end

  defp fresh(fun) do
    [result] = Connections.run(1, fn _index -> fun.() end)
    result
  end

  defp receipt_count(id),
    do: TestRepo.aggregate(from(r in FlushReceipt, where: r.id == ^id), :count)

  defp drain_reached(statements \\ []) do
    receive do
      {:reached, statement} -> drain_reached([statement | statements])
    after
      0 -> statements
    end
  end

  # The conservation line scripts/v1/faults.sh consumes: this test's rows are
  # given back before the counts are taken, so a non-zero delta means the test
  # left something behind. A no-op unless AURORA_FAULT_REPORT names a file.
  defp report!(context, statement) do
    :ok = Connections.cleanup!(context.tenant)
    :ok = delete_receipts!()
    counts_after = Connections.row_counts()

    delta =
      Map.new(counts_after, fn {schema, count} ->
        {schema, count - Map.fetch!(context.counts_before, schema)}
      end)

    assert Enum.all?(delta, fn {_schema, change} -> change == 0 end), inspect(delta)

    Connections.report!(%{
      test: "I02 #{statement}",
      seed: ExUnit.configuration()[:seed],
      point: :before_commit,
      action: :raise,
      tenant_prefix: context.tenant,
      before: context.counts_before,
      after: counts_after,
      delta: delta
    })
  end
end
