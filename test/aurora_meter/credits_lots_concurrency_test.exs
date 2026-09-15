defmodule AuroraMeter.CreditsLotsConcurrencyTest do
  @moduledoc """
  The lot engine under real contention (build unit 06a, G06 bullets 2 and 3).

  `async: false` and no `DataCase`: the sandbox wraps a test in one transaction
  on one connection, which serialises the very contention a row lock exists to
  survive. Every task here takes a real connection, its rows really commit, and
  the assertions are on the database rather than on task return values.

  Two rules the programme learned the hard way and both apply here.

  **Force the contention, do not hope for it** (findings X182, X186, X187).
  Three units shipped a race test whose contended branch ran zero times while
  reporting green. The rendezvous below holds the contested row `FOR UPDATE`
  from a third connection until Postgres reports that both racers are waiting,
  and then releases them together. The trap worth repeating: a row-lock waiter
  is **invisible** to `pg_locks` filtered by `database`, because it waits on the
  holder's `transactionid` and that row carries no database.
  `pg_stat_activity.wait_event_type = 'Lock'` is what sees it.

  **Count the contended branch and assert it on an ordinary run** (X214). The
  counts below are asserted, not printed behind an environment variable.
  """
  use ExUnit.Case, async: false

  @moduletag :fault
  @moduletag timeout: 180_000

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @dollar 1_000_000
  @oct ~U[2026-10-01 00:00:00Z]
  @dec ~U[2026-12-01 00:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    Connections.register_prefix("lotconc")
    tenant = AuroraMeter.Test.unique_tenant("lotconc")

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      Connections.cleanup!("lotconc")
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: tenant}
  end

  test "I11 fifty independent holds against one wallet funded with ten admit exactly ten",
       %{tenant: tenant} do
    Ledger.enable_lots!(tenant)
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: tenant <> ":fund")

    results = race(50, fn i -> Credits.hold(tenant, @dollar, "#{tenant}:h#{i}") end)

    admitted = Enum.count(results, &match?({:ok, _}, &1))
    refused = Enum.count(results, &(&1 == {:error, :insufficient_credits}))

    assert admitted == 10, "admitted #{admitted}, refused #{refused}: #{inspect(tally(results))}"
    assert refused == 40
    assert admitted + refused == 50

    # And the effect, which is the part a return value cannot prove: ten
    # reserve allocations totalling exactly the funded amount, one lot holding
    # all of it, and nothing spendable left.
    reserves = allocations(tenant, :reserve)
    assert length(reserves) == 10
    assert Enum.sum(Enum.map(reserves, & &1.amount)) == 10 * @dollar

    assert [lot] = lots(tenant)
    assert lot.reserved == 10 * @dollar
    assert lot.available == 0
    assert balance_row(tenant).held == 10 * @dollar
    assert Credits.balance(tenant).available == 0

    # The contention is asserted rather than assumed: fifty transactions that
    # ran one after another with no overlap would produce these same numbers.
    assert max_concurrent_backends() > 1,
           "no two of the fifty attempts were ever in the database at once, so this proves " <>
             "the arithmetic and nothing about the lock"
  end

  test "I11 twenty concurrent holds across twenty wallets do not interfere", %{tenant: tenant} do
    wallets = for i <- 1..20, do: "#{tenant}_w#{i}"

    for wallet <- wallets do
      Ledger.enable_lots!(wallet)
      {:ok, _} = Credits.grant(wallet, 2 * @dollar, reference: wallet <> ":fund")
    end

    results = race(20, fn i -> Credits.hold(Enum.at(wallets, i - 1), @dollar, "w#{i}:h") end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 20

    for wallet <- wallets do
      lot = TestRepo.one!(from(l in CreditLot, where: l.tenant_key == ^wallet))
      assert lot.reserved == @dollar
      assert lot.available == @dollar
      assert balance_row(wallet).held == @dollar
    end
  end

  test "I12 expiry racing a release conserves and leaves no spendable expired value",
       %{tenant: tenant} do
    # G06 bullet 3. The two writers are released together from a rendezvous, so
    # both orders are reachable and neither is hoped for; the assertion is the
    # same in both directions, which is the point of conservation as a property.
    outcomes =
      for round <- 1..6 do
        wallet = "#{tenant}_r#{round}"
        Ledger.enable_lots!(wallet)

        AuroraMeter.Test.with_clock(~U[2026-09-15 00:00:00.000000Z], fn ->
          {:ok, _} =
            Credits.grant(wallet, 5 * @dollar,
              reference: wallet <> ":promo",
              category: :promotional,
              expires_at: @oct
            )

          {:ok, _} = Credits.hold(wallet, 2 * @dollar, wallet <> ":h")
        end)

        AuroraMeter.Test.with_clock(@dec, fn ->
          contended_pair(wallet, [
            fn -> Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 10) end,
            fn -> Credits.release(wallet <> ":h") end
          ])
        end)
      end

    contended = Enum.count(outcomes, & &1.contended)

    assert contended == 6,
           "the rendezvous released #{contended} of 6 rounds with both writers waiting. " <>
             "Either Postgres stopped reporting the waiters, or one writer finished before " <>
             "the other started, and in both cases this test proves nothing about the race."

    for %{wallet: wallet} <- outcomes do
      lot = TestRepo.one!(from(l in CreditLot, where: l.tenant_key == ^wallet))
      row = balance_row(wallet)

      # Whichever order they committed in: the whole lot is expired, nothing is
      # available, nothing is held, and the balance row agrees with the lot.
      assert lot.expired == 5 * @dollar, "wallet #{wallet}: #{inspect(lot)}"
      assert lot.available == 0
      assert lot.reserved == 0
      assert lot.state == :expired

      assert row.balance == 0
      assert row.held == 0
      assert row.expired == 5 * @dollar
      assert row.debt == 0
      refute Credits.sufficient?(wallet, 1)
    end
  end

  test "I10 concurrent grants and debits on one wallet leave the projection exact",
       %{tenant: tenant} do
    Ledger.enable_lots!(tenant)
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: tenant <> ":fund")

    results =
      race(20, fn i ->
        if rem(i, 2) == 0 do
          Credits.grant(tenant, @dollar, reference: "#{tenant}:g#{i}")
        else
          Credits.debit(tenant, @dollar, "#{tenant}:d#{i}")
        end
      end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 20

    # Ten grants of 1 USD and ten debits of 1 USD against 10 USD of funding.
    row = balance_row(tenant)
    assert row.balance == 10 * @dollar
    assert row.debt == 0

    # The projection is the claim, and it is asserted from the lots rather than
    # from the row that was written beside them.
    %{rows: [[available, reserved, expired]]} =
      TestRepo.query!(
        "SELECT coalesce(sum(available),0)::bigint, coalesce(sum(reserved),0)::bigint, " <>
          "coalesce(sum(expired),0)::bigint FROM aurora_meter_credit_lots WHERE tenant_key = $1",
        [tenant]
      )

    assert row.balance == available + reserved - row.debt
    assert row.held == reserved
    assert row.expired == expired
    assert row.projection_checked_at
  end

  test "I11 without the balance row lock the same fifty holds oversubscribe the wallet",
       %{tenant: tenant} do
    # **The negative control** (finding X125). The lock is removed and nothing
    # else changes: the eligible lots are read without `FOR UPDATE`, planned and
    # written exactly as the ledger would. If this admitted ten as well, the
    # lock would not be what answers in the test above and that test's claim
    # would have to be rewritten.
    Ledger.enable_lots!(tenant)
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: tenant <> ":fund")
    lot_id = TestRepo.one!(from(l in CreditLot, where: l.tenant_key == ^tenant, select: l.id))

    results = race(50, fn _i -> unlocked_hold(lot_id) end)
    tally = Enum.frequencies(results)

    admitted = Map.get(tally, :admitted, 0)
    violations = Map.get(tally, {:refused_by, "aurora_meter_credit_lots_available_check"}, 0)

    assert admitted + violations > 10,
           "the unlocked read let #{admitted + violations} of fifty attempts try to take money " <>
             "from a wallet funded for ten, which is not more than ten: #{inspect(tally)}. " <>
             "The control did not discriminate, so the locked test above is not evidence " <>
             "about the lock and its claim must be rewritten."

    # **And this is what the control actually shows, which is worth more than
    # what it was written to show.** Removing the lock does not oversubscribe
    # the wallet: it makes the second layer fire. The `available >= 0` check
    # refuses the write outright, so a lost lock is a refused transaction rather
    # than silent corruption, which is precisely the property finding X183 asked
    # for and which `aurora_meter_credit_balances` did not have before schema
    # version 9.
    assert violations > 0,
           "no attempt was refused by the lot's own CHECK constraint: #{inspect(tally)}"

    lot = TestRepo.one!(from(l in CreditLot, where: l.id == ^lot_id))
    assert lot.available >= 0
    assert lot.available + lot.reserved + lot.consumed + lot.reversed + lot.expired == lot.amount

    # The ledger and the balance row were never touched by any of this, so the
    # wallet is exactly as the funded grant left it apart from the lot's
    # reserved column.
    assert balance_row(tenant).balance == 10 * @dollar
  end

  # One hold with the balance row lock removed and nothing else changed: the
  # eligible lot is read without `FOR UPDATE`, then written exactly as the
  # allocator would write it.
  defp unlocked_hold(lot_id) do
    TestRepo.transaction(fn ->
      %{rows: [[available]]} =
        TestRepo.query!("SELECT available FROM aurora_meter_credit_lots WHERE id = $1", [
          Ecto.UUID.dump!(lot_id)
        ])

      if available >= @dollar do
        Process.sleep(5)

        TestRepo.query!(
          "UPDATE aurora_meter_credit_lots SET available = available - $2, " <>
            "reserved = reserved + $2 WHERE id = $1",
          [Ecto.UUID.dump!(lot_id), @dollar]
        )

        :admitted
      else
        :refused
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      other -> other
    end
  rescue
    error in Postgrex.Error -> {:refused_by, error.postgres.constraint}
  end

  # -- harness ----------------------------------------------------------------

  # `n` tasks, each on its own real connection. The pool is smaller than `n` for
  # the fifty-connection case, so some tasks queue for a connection rather than
  # holding one for the whole run; every attempt is still its own transaction on
  # a real connection contending for the same row, and
  # `max_concurrent_backends/0` records how many were in the database at once.
  defp race(n, fun) do
    parent = self()

    tasks = for i <- 1..n, do: Task.async(fn -> racer(parent, i, fun) end)

    for _ <- 1..n, do: assert_receive({:ready, _}, 60_000)
    for task <- tasks, do: send(task.pid, :go)

    Task.await_many(tasks, 120_000)
  end

  # One racer: signal readiness, wait for the release, then take a connection.
  # The connection is taken AFTER the barrier on purpose. Holding one from every
  # task while they wait deadlocks the moment there are more tasks than the pool
  # has connections, and the barrier is there to start them together rather than
  # to hold anything open.
  defp racer(parent, i, fun) do
    send(parent, {:ready, i})

    receive do
      :go -> :ok
    after
      30_000 -> exit(:never_released)
    end

    own = Connections.checkout!()

    try do
      fun.(i)
    after
      if own, do: Sandbox.checkin(TestRepo)
    end
  end

  # Runs two writers against one wallet, held at a rendezvous until Postgres
  # reports that BOTH are waiting on a lock, then released together.
  #
  # The contested row is the wallet's balance row, which is the first lock every
  # ledger write takes. A third connection holds it `FOR UPDATE` in its own
  # transaction; the two writers queue behind it; the poll below waits for two
  # waiters and then commits the holder.
  defp contended_pair(wallet, [a, b]) do
    parent = self()
    holder = spawn_holder(wallet)

    tasks =
      for fun <- [a, b] do
        Task.async(fn ->
          Connections.checkout!()
          send(parent, :queued)
          fun.()
        end)
      end

    for _ <- 1..2, do: assert_receive(:queued, 30_000)

    contended = await_waiters(2, 500)
    send(holder, :release)
    Task.await_many(tasks, 60_000)

    %{wallet: wallet, contended: contended}
  end

  defp spawn_holder(wallet) do
    parent = self()

    pid =
      spawn(fn ->
        Connections.checkout!()

        TestRepo.transaction(fn ->
          TestRepo.query!(
            "SELECT id FROM aurora_meter_credit_balances WHERE tenant_key = $1 FOR UPDATE",
            [wallet]
          )

          send(parent, :holding)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive(:holding, 30_000)
    pid
  end

  # **A row-lock waiter is invisible to the obvious `pg_locks` query** (X186): a
  # backend queued behind a row lock waits on the holder's `transactionid`, and
  # a `transactionid` lock carries no `database`, so filtering by database
  # removes exactly the rows being looked for. `pg_stat_activity` sees it.
  defp await_waiters(_target, 0), do: false

  defp await_waiters(target, attempts) do
    %{rows: [[waiting]]} =
      TestRepo.query!(
        """
        SELECT count(*) FROM pg_stat_activity
         WHERE datname = current_database()
           AND wait_event_type = 'Lock'
           AND pid <> pg_backend_pid()
        """,
        []
      )

    if waiting >= target do
      true
    else
      Process.sleep(20)
      await_waiters(target, attempts - 1)
    end
  end

  defp max_concurrent_backends do
    %{rows: [[count]]} =
      TestRepo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()",
        []
      )

    count
  end

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))

  defp allocations(tenant, kind) do
    TestRepo.all(from(a in CreditAllocation, where: a.tenant_key == ^tenant and a.kind == ^kind))
  end

  defp balance_row(tenant), do: TestRepo.get_by!(CreditBalance, tenant_key: tenant)

  defp tally(results) do
    Enum.frequencies_by(results, fn
      {:ok, _} -> :ok
      {:error, reason} -> reason
      other -> other
    end)
  end
end
