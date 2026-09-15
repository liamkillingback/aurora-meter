defmodule AuroraMeter.CreditsConcurrencyTest do
  @moduledoc false
  # async: false and no DataCase: the sandbox wraps a test in one transaction on
  # one connection, which would serialise the holds and hide the very race this
  # proves. Each task checks out a real connection (`sandbox: false`) instead,
  # so twenty transactions contend on the tenant's `FOR UPDATE` row lock and the
  # rows really commit; the test deletes them afterwards.
  use ExUnit.Case, async: false

  # `mix v1.faults` (an alias in mix.exs) runs every module tagged :fault with a
  # fixed seed, and CI runs it as its own job. The tag is NOT excluded in
  # test/test_helper.exs, so this module also runs inside the ordinary `mix test`
  # and the dedicated job is a second, seeded run rather than the only one.
  @moduletag :fault

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @doc false
  def handle_event(event, measurements, metadata, %{parent: parent, tenant: tenant}) do
    if metadata.tenant_key == tenant,
      do: send(parent, {:telemetry, event, measurements, metadata})

    :ok
  end

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

  test "I10 a refusal does not destroy the caller's own transaction", %{tenant: tenant} do
    # A host wraps a ledger call in its own transaction — a settle beside the
    # status flip it arms, say — and the ledger refuses, because the hold was
    # already settled by a delivery that arrived twice. Answered with
    # `repo.rollback/1` that refusal took the host's transaction with it:
    # `rollback/1` in a nested transaction marks the whole thing whatever the
    # mode, Postgres aborts back to the outermost BEGIN, the host's own writes
    # are undone and its next statement fails too.
    #
    # Not a DataCase test: the sandbox already holds a transaction, so the
    # ledger's would be nested inside *it* and the abort would unwind no
    # further than the sandbox's own savepoint. The bug is invisible there,
    # which is how it survived a round of auditing with a passing test.
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    reference = "refused:#{tenant}"
    :ok = Credits.hold(tenant, 100_000, reference) |> then(fn {:ok, _} -> :ok end)
    {:ok, _} = Credits.settle(reference, 100_000)

    outcome =
      TestRepo.transaction(fn ->
        {:ok, _} = TestRepo.insert(%CreditBalance{tenant_key: tenant <> ":witness"})

        # The same settle again, as a redelivery does.
        refused = Credits.settle(reference, 100_000)

        # The caller's connection is still usable, which it would not be if the
        # refusal had aborted the transaction.
        {:ok, %{rows: [[1]]}} = SQL.query(TestRepo, "SELECT 1", [])
        refused
      end)

    assert {:ok, {:error, :already_settled}} = outcome

    # And the caller's own write committed.
    assert TestRepo.get_by(CreditBalance, tenant_key: tenant <> ":witness")

    TestRepo.delete_all(from(b in CreditBalance, where: b.tenant_key == ^(tenant <> ":witness")))
  end

  test "I11 twenty concurrent $0.10 holds against $1.00 admit exactly ten", %{tenant: tenant} do
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

  test "I11 fifty independent connections holding against one hot wallet admit exactly the funded count",
       %{tenant: tenant} do
    # $2.50, which covers exactly twenty-five $0.10 holds and no more.
    {:ok, _} = Credits.grant(tenant, 2_500_000, reference: "seed:#{tenant}")

    # Connections.run/3 refuses more tasks than the pool can serve (30 less the
    # four it reserves), so the fifty attempts are made in two waves of
    # twenty-five against the same wallet and the admitted count is cumulative.
    # Every wave contends on the same balance row lock.
    results =
      Enum.flat_map([0, 25], fn offset ->
        Connections.run(25, fn i ->
          Credits.hold(tenant, 100_000, "hot:#{tenant}:#{offset + i}")
        end)
      end)

    assert length(results) == 50
    assert Enum.count(results, &match?({:ok, _}, &1)) == 25
    assert Enum.count(results, &match?({:error, :insufficient_credits}, &1)) == 25

    assert %{balance: 2_500_000, held: 2_500_000, available: 0} = Credits.balance(tenant)

    holds = Credits.history(tenant, kinds: [:hold], limit: 100)
    assert length(holds) == 25

    # Every entry snapshots a consistent running total: held_after climbs 1..25
    # with no repeat, which is what two holds spending the same funds would
    # break.
    assert holds |> Enum.map(& &1.held_after) |> Enum.sort() == Enum.map(1..25, &(&1 * 100_000))
  end

  test "I10 a host transaction that rolls back emits nothing, because the side effects were deferred (L18)",
       %{tenant: tenant} do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:aurora_meter, :credits, :grant],
        &__MODULE__.handle_event/4,
        %{parent: self(), tenant: tenant}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :host_rolled_back} =
             TestRepo.transaction(fn ->
               assert {:ok, _txn} = Credits.grant(tenant, 1_000_000, reference: "l18:#{tenant}")

               # Before build unit 06c this line asserted the opposite.
               # `transact_outcome/1` emitted when its own `repo.transaction/1`
               # returned, and inside a host transaction that return is a
               # savepoint release rather than a commit, so telemetry, PubSub
               # and the low-balance handler had all already described a balance
               # the host was about to throw away (finding L18).
               refute_received {:telemetry, [:aurora_meter, :credits, :grant], _m, _meta}

               # The queue is what holds them, and it is per process, so a host
               # can assert it has not forgotten the drain.
               assert Credits.deferred_effects?()

               TestRepo.rollback(:host_rolled_back)
             end)

    # The rollback branch discards rather than drains: the writes are gone, so
    # nothing may describe them.
    assert :ok = Credits.after_commit(discard: true)
    refute Credits.deferred_effects?()
    refute_received {:telemetry, [:aurora_meter, :credits, :grant], _m, _meta}

    assert Credits.history(tenant, kinds: [:grant], limit: 10) == []
    assert Credits.available(tenant) == 0
  end

  test "I11 concurrent settle and release of one hold: exactly one wins", %{tenant: tenant} do
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
