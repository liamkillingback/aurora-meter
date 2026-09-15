defmodule AuroraMeter.CreditsLotsFaultsTest do
  @moduledoc """
  The lot engine under process death and injected database faults (build unit
  06a, finding X243).

  This file exists because "every lot write is inside one `repo.transaction/1`,
  so a partial effect cannot persist" is an **argument**, and the method here is
  that arguments get measured. A lot-path write now touches four tables in one
  transaction (the ledger row, the lot, the allocations, the balance row) plus a
  conservation check that re-reads a fifth thing. The claim that none of it
  survives a failure is worth more than the shape of the code that makes it.

  `async: false` and no `DataCase`: the sandbox wraps a test in one transaction
  on one connection, so a killed process would take the test's own connection
  with it and, worse, the batches before the kill would never really have
  committed. Every assertion here is read back on an independent connection
  after the writer is dead, because after a kill the only trustworthy state is
  what the database says.

  **What each test asserts is the wallet, not the absence of an error.** Zero
  lots, zero allocations, an unchanged balance row and the conservation property
  itself, so a fault that left a lot row behind without its allocation would
  fail here even though nothing was raised to the caller.
  """
  use ExUnit.Case, async: false

  @moduletag :fault
  @moduletag timeout: 120_000

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @dollar 1_000_000

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    Connections.register_prefix("lotfault")
    tenant = AuroraMeter.Test.unique_tenant("lotfault")

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      Connections.cleanup!("lotfault")
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: tenant}
  end

  # -- the four armed fault points --------------------------------------------
  #
  # `FaultRepo` fires `:before_commit` at every repo call with the statement,
  # the schema and the repo function in its context, so "the four points" of the
  # build document are four predicates over one shim rather than four shims:
  # the ledger row insert, the lot insert or update, the allocation insert, and
  # the balance row update. Each is the last thing to happen before the one
  # after it, so arming at each is arming at each stage boundary.

  test "I10 a writer killed before the ledger row is inserted leaves the wallet untouched",
       %{tenant: tenant} do
    funded = fund(tenant)

    outcome =
      kill_at(
        fn context ->
          context[:repo_fun] == :insert and context[:schema] == CreditTransaction
        end,
        fn -> Credits.debit(tenant, @dollar, "#{tenant}:d1") end
      )

    assert {:killed, _pid} = outcome
    assert_untouched(tenant, funded)
  end

  test "I10 a writer killed after the ledger row and before the allocations leaves the wallet untouched",
       %{tenant: tenant} do
    funded = fund(tenant)

    outcome =
      kill_at(
        fn context ->
          context[:repo_fun] == :insert_all and context[:schema] == CreditAllocation
        end,
        fn -> Credits.debit(tenant, @dollar, "#{tenant}:d1") end
      )

    assert {:killed, _pid} = outcome

    # The ledger row was inserted before the kill and is gone with it: the
    # transaction had not committed, so Postgres rolled it back when the
    # worker's connection closed.
    assert_untouched(tenant, funded)
  end

  test "I10 a writer killed after the allocations and before the lot update leaves the wallet untouched",
       %{tenant: tenant} do
    funded = fund(tenant)

    outcome =
      kill_at(
        fn context ->
          context[:repo_fun] == :update_all and context[:schema] == CreditLot
        end,
        fn -> Credits.debit(tenant, @dollar, "#{tenant}:d1") end
      )

    assert {:killed, _pid} = outcome
    assert_untouched(tenant, funded)
  end

  test "I10 a writer killed after the lot update and before the balance update leaves the wallet untouched",
       %{tenant: tenant} do
    funded = fund(tenant)

    outcome =
      kill_at(
        fn context ->
          context[:repo_fun] == :update! and context[:schema] == CreditBalance
        end,
        fn -> Credits.debit(tenant, @dollar, "#{tenant}:d1") end
      )

    assert {:killed, _pid} = outcome
    assert_untouched(tenant, funded)
  end

  test "I10 a writer killed after commit, before its reply, leaves exactly one effect and no second one on retry",
       %{tenant: tenant} do
    # The one window that really does persist, and it is today's behaviour for
    # every ledger call: the work is committed and the caller never hears. What
    # makes it safe is the reference, decided under the balance row lock.
    funded = fund(tenant)

    outcome =
      Kill.run(
        fn ->
          Connections.checkout!()

          TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
            Faults.arm(:after_commit_before_ack, :exit_kill_self,
              count: 1,
              label: :lot_debit_committed
            )

            result = Credits.debit(tenant, @dollar, "#{tenant}:d1")
            Faults.check(:after_commit_before_ack, %{result: result})
            result
          end)
        end,
        timeout: 30_000
      )

    assert {:killed, _pid} = outcome

    # Committed: one lot, one consume allocation, the balance moved.
    Kill.assert_db!(fn ->
      assert [lot] = lots(tenant)
      assert lot.consumed == @dollar
      assert lot.available == funded - @dollar
      assert [%{kind: :consume, amount: @dollar}] = allocations(tenant)
      assert balance_row(tenant).balance == funded - @dollar
      assert_conserves(tenant)
    end)

    # And the retry the caller makes, having heard nothing, is refused by the
    # reference rather than debiting a second time.
    Kill.assert_db!(fn ->
      assert {:error, :duplicate_reference} = Credits.debit(tenant, @dollar, "#{tenant}:d1")
      assert length(allocations(tenant)) == 1
      assert balance_row(tenant).balance == funded - @dollar
      assert_conserves(tenant)
    end)
  end

  test "I10 the control: with no fault armed the same writer completes and the wallet moves",
       %{tenant: tenant} do
    # **The negative control for the four tests above** (finding X125). Every
    # one of them asserts that nothing happened, and a writer that never ran at
    # all would satisfy every one of them. This is the same harness with the
    # arming removed: it must complete, and the wallet must move.
    funded = fund(tenant)

    outcome =
      Kill.run(
        fn ->
          Connections.checkout!()
          Credits.debit(tenant, @dollar, "#{tenant}:d1")
        end,
        timeout: 30_000
      )

    assert {:completed, {:ok, _txn}} = outcome

    Kill.assert_db!(fn ->
      assert [lot] = lots(tenant)
      assert lot.consumed == @dollar
      assert [%{kind: :consume}] = allocations(tenant)
      assert balance_row(tenant).balance == funded - @dollar
      assert_conserves(tenant)
    end)
  end

  # -- injected database faults ------------------------------------------------

  test "I10 forcing the allocation insert to fail leaves the lot and the balance untouched",
       %{tenant: tenant} do
    funded = fund(tenant)

    assert_raises_and_leaves_nothing(tenant, funded, fn context ->
      context[:repo_fun] == :insert_all and context[:schema] == CreditAllocation
    end)
  end

  test "I10 forcing the lot update to fail leaves the ledger row uncommitted",
       %{tenant: tenant} do
    funded = fund(tenant)

    assert_raises_and_leaves_nothing(tenant, funded, fn context ->
      context[:repo_fun] == :update_all and context[:schema] == CreditLot
    end)
  end

  test "I10 forcing the balance update to fail rolls back the allocations",
       %{tenant: tenant} do
    funded = fund(tenant)

    assert_raises_and_leaves_nothing(tenant, funded, fn context ->
      context[:repo_fun] == :update! and context[:schema] == CreditBalance
    end)
  end

  test "I10 forcing the new lot's insert to fail leaves the grant uncommitted", %{tenant: tenant} do
    # The grant path rather than the debit path: it is the only operation that
    # inserts a lot, and `insert!/1` is one of the two repo functions this unit
    # added to `FaultRepo`'s surface.
    Ledger.enable_lots!(tenant)

    assert_raise Faults.Injected, fn ->
      TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
        Faults.arm(:before_commit, :raise,
          count: 1,
          label: :lot_insert,
          when: fn context -> context[:repo_fun] == :insert! and context[:schema] == CreditLot end
        )

        Credits.grant(tenant, 5 * @dollar, reference: "#{tenant}:pay")
      end)
    end

    Faults.disarm_all()

    assert lots(tenant) == []
    assert allocations(tenant) == []
    assert TestRepo.aggregate(txns(tenant), :count) == 0
    assert balance_row(tenant).balance == 0
    assert_conserves(tenant)
  end

  test "I10 the fault control: the same three statements without a fault all commit together",
       %{tenant: tenant} do
    # **The negative control for the three fault tests.** They assert that
    # nothing persisted; a writer whose statements never ran would satisfy them
    # too. Through `FaultRepo` with nothing armed, all three statements run and
    # all three effects are there.
    funded = fund(tenant)

    TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
      assert {:ok, _txn} = Credits.debit(tenant, @dollar, "#{tenant}:d1")
    end)

    assert [lot] = lots(tenant)
    assert lot.consumed == @dollar
    assert [%{kind: :consume, amount: @dollar}] = allocations(tenant)
    assert balance_row(tenant).balance == funded - @dollar
    assert_conserves(tenant)
  end

  # -- helpers ----------------------------------------------------------------

  defp fund(tenant) do
    Ledger.enable_lots!(tenant)
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "#{tenant}:pay")
    5 * @dollar
  end

  # Runs `fun` in a supervised task on its own real connection, and kills that
  # task from inside the repo shim at the first statement matching `predicate`.
  # The kill lands inside the ledger's transaction, on the transaction's own
  # connection, which is the only way to test this: the connection dies with the
  # process and Postgres rolls back what it was holding.
  defp kill_at(predicate, fun) do
    Kill.run(
      fn ->
        Connections.checkout!()

        TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
          Faults.arm(:before_commit, :exit_kill_self,
            count: 1,
            label: :lot_write,
            when: predicate
          )

          fun.()
        end)
      end,
      timeout: 30_000
    )
  end

  defp assert_raises_and_leaves_nothing(tenant, funded, predicate) do
    assert_raise Faults.Injected, fn ->
      TestConfig.with_config([{:aurora_meter, :repo, FaultRepo}], fn ->
        Faults.arm(:before_commit, :raise, count: 1, label: :lot_write, when: predicate)
        Credits.debit(tenant, @dollar, "#{tenant}:d1")
      end)
    end

    Faults.disarm_all()
    assert_untouched(tenant, funded)
  end

  # The wallet as the funding grant left it: one lot holding all of it, no
  # allocation, one ledger row (the grant), the balance row unmoved, and the
  # conservation property intact.
  defp assert_untouched(tenant, funded) do
    Kill.assert_db!(fn ->
      assert [lot] = lots(tenant)
      assert lot.available == funded
      assert lot.consumed == 0
      assert lot.reserved == 0

      assert allocations(tenant) == []
      assert TestRepo.aggregate(txns(tenant), :count) == 1

      row = balance_row(tenant)
      assert row.balance == funded
      assert row.held == 0
      assert row.debt == 0
      assert row.expired == 0

      assert_conserves(tenant)
    end)
  end

  # The invariant itself, read from the database rather than from the writer's
  # own arithmetic. A fault that left a lot row moved without its allocation, or
  # a balance row moved without its lot, fails here even though nothing was
  # raised to a caller.
  defp assert_conserves(tenant) do
    row = balance_row(tenant)
    lots = lots(tenant)

    available = Enum.reduce(lots, 0, &(&1.available + &2))
    reserved = Enum.reduce(lots, 0, &(&1.reserved + &2))
    expired = Enum.reduce(lots, 0, &(&1.expired + &2))

    assert row.balance == available + reserved - row.debt
    assert row.held == reserved
    assert row.expired == expired

    for lot <- lots do
      assert lot.available + lot.reserved + lot.consumed + lot.reversed + lot.expired ==
               lot.amount
    end
  end

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))

  defp allocations(tenant) do
    TestRepo.all(
      from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: [asc: a.seq])
    )
  end

  defp txns(tenant), do: from(t in CreditTransaction, where: t.tenant_key == ^tenant)

  defp balance_row(tenant), do: TestRepo.get_by!(CreditBalance, tenant_key: tenant)
end
