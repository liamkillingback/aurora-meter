defmodule AuroraMeter.CreditsConcurrencyTest do
  @moduledoc false
  # async: false and no DataCase: the sandbox wraps a test in one transaction on
  # one connection, which would serialise the holds and hide the very race this
  # proves. Each task checks out a real connection (`sandbox: false`) instead,
  # so twenty transactions contend on the tenant's `FOR UPDATE` row lock and the
  # rows really commit; the test deletes them afterwards.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    tenant = AuroraMeter.Test.unique_tenant("concurrent")

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      TestRepo.delete_all(from(t in CreditTransaction, where: t.tenant_key == ^tenant))
      TestRepo.delete_all(from(b in CreditBalance, where: b.tenant_key == ^tenant))
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: tenant}
  end

  test "twenty concurrent $0.10 holds against $1.00 admit exactly ten", %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")

    results =
      1..20
      |> Enum.map(fn i ->
        Task.async(fn ->
          :ok = Sandbox.checkout(TestRepo, sandbox: false)
          result = Credits.hold(tenant, 100_000, "hold:#{tenant}:#{i}")
          Sandbox.checkin(TestRepo)
          result
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
    assert Enum.count(results, &match?({:error, :insufficient_credits}, &1)) == 10

    assert %{balance: 1_000_000, held: 1_000_000, available: 0} = Credits.balance(tenant)

    holds = Credits.history(tenant, kinds: [:hold], limit: 100)
    assert length(holds) == 10
    # Every entry snapshots a consistent running total: held_after climbs 1..10.
    assert holds |> Enum.map(& &1.held_after) |> Enum.sort() == Enum.map(1..10, &(&1 * 100_000))
  end

  test "concurrent settle and release of one hold: exactly one wins", %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")

    results =
      1..10
      |> Enum.map(fn i ->
        Task.async(fn ->
          :ok = Sandbox.checkout(TestRepo, sandbox: false)

          result =
            if rem(i, 2) == 0,
              do: Credits.settle("job:#{tenant}", 300_000),
              else: Credits.release("job:#{tenant}")

          Sandbox.checkin(TestRepo)
          result
        end)
      end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :already_settled}, &1)) == 9
    assert %{held: 0} = Credits.balance(tenant)
  end
end
