defmodule AuroraMeter.FlushBatchConcurrencyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  # `mix v1.faults` (an alias in mix.exs) runs every module tagged :fault with a
  # fixed seed, and CI runs it as its own job. The tag is NOT excluded in
  # test/test_helper.exs, so this module also runs inside the ordinary `mix test`
  # and the dedicated job is a second, seeded run rather than the only one.
  @moduletag :fault

  import Ecto.Query

  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @period ~U[2026-07-01 00:00:00Z]
  @date ~D[2026-07-03]

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)

    # Flusher.flush/0 is a GenServer.call and the Flusher owns no connection of
    # its own, so the test lends it this one. The allowance dies with the test
    # process's ownership.
    :ok = Sandbox.allow(TestRepo, self(), Process.whereis(Flusher))

    # Discard, never flush, what an earlier module left pending: see
    # AuroraMeter.StatementsTest's setup for why a drain flush in a non-sandbox
    # module poisons the test database across runs.
    :ok = AuroraMeter.Test.reset!()

    tenant = AuroraMeter.Test.unique_tenant("flush_batch")
    id = Ecto.UUID.generate()

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      TestRepo.delete_all(from(c in Counter, where: c.tenant_key == ^tenant))
      TestRepo.delete_all(from(h in History, where: h.tenant_key == ^tenant))
      TestRepo.delete_all(from(r in FlushReceipt, where: r.id == ^id))
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: tenant, id: id}
  end

  test "I01 twelve independent connections deliver one batch once", %{tenant: tenant, id: id} do
    supervisor = start_supervised!(Task.Supervisor)

    results =
      1..12
      |> Enum.map(fn _ ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          :ok = Sandbox.checkout(TestRepo, sandbox: false)

          try do
            Storage.flush_batch(id, counters(tenant), history(tenant))
          after
            Sandbox.checkin(TestRepo)
          end
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.all?(
             results,
             &match?({:ok, %{counters: [%{value: 5}], history: [%{value: 5}]}}, &1)
           )

    assert Storage.load_counter(tenant, :ops, @period) == 5
    assert Storage.load_history(tenant, :ops, @date) == 5
    assert TestRepo.get!(FlushReceipt, id)
  end

  test "I02 an invalid history row rolls back the counter and the receipt", context do
    invalid_history = [%{hd(history(context.tenant)) | date: "invalid"}]

    assert_raise Ecto.ChangeError, fn ->
      Storage.flush_batch(context.id, counters(context.tenant), invalid_history)
    end

    assert Storage.load_counter(context.tenant, :ops, @period) == nil
    assert TestRepo.get(FlushReceipt, context.id) == nil

    assert {:ok, _} =
             Storage.flush_batch(context.id, counters(context.tenant), history(context.tenant))

    assert Storage.load_counter(context.tenant, :ops, @period) == 5
    assert Storage.load_history(context.tenant, :ops, @date) == 5
  end

  test "I01 new deltas arriving during a retry are not lost and are not applied twice", %{
    tenant: tenant
  } do
    flusher = Process.whereis(Flusher)
    :ok = Faults.forget(owner: flusher)
    period = Period.current(tenant).start

    AuroraMeter.track(tenant, :ops, 5)
    first = Store.snapshot_flush_batch()

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      # The commit lands and the caller never learns: the batch stays pending.
      :ok =
        Faults.arm(:after_commit_before_ack, :raise,
          owner: flusher,
          count: 1,
          label: :lost_acknowledgement,
          when: &(&1[:callback] == :flush_batch)
        )

      assert {:error, _reason} = Flusher.flush()
      :ok = Faults.assert_fired!(:after_commit_before_ack, owner: flusher)
    end)

    # New usage while the batch is retained. It accumulates in `pending_flush`
    # on a key whose batch has already been taken, which is the interleaving
    # v1-release.md section 17 requires.
    AuroraMeter.track(tenant, :ops, 3)
    assert Store.snapshot_flush_batch().id == first.id

    # The retry re-sends the identical batch; the receipt dedupes it, so the
    # database still holds five and not ten.
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, period) == 5

    # The three were never in that batch and were not lost: the local view is
    # already eight, and the next batch carries them.
    assert AuroraMeter.Counter.value(tenant, :ops, period) == 8
    second = Store.snapshot_flush_batch()
    refute second.id == first.id

    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, period) == 8
    assert receipt_count(first.id) == 1
    assert receipt_count(second.id) == 1

    TestRepo.delete_all(from(r in FlushReceipt, where: r.id in ^[first.id, second.id]))
  end

  defp receipt_count(id),
    do: TestRepo.aggregate(from(r in FlushReceipt, where: r.id == ^id), :count)

  defp counters(tenant),
    do: [%{tenant_key: tenant, feature: :ops, period_start: @period, delta: 5}]

  defp history(tenant), do: [%{tenant_key: tenant, feature: :ops, date: @date, delta: 5}]
end
