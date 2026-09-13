defmodule AuroraMeter.FlushBatchConcurrencyTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import Ecto.Query

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Storage
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @period ~U[2026-07-01 00:00:00Z]
  @date ~D[2026-07-03]

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
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

  test "simultaneous deliveries of one batch commit its deltas once", %{tenant: tenant, id: id} do
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

  test "failure after the counter write rolls back both the counter and receipt", context do
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

  defp counters(tenant),
    do: [%{tenant_key: tenant, feature: :ops, period_start: @period, delta: 5}]

  defp history(tenant), do: [%{tenant_key: tenant, feature: :ops, date: @date, delta: 5}]
end
