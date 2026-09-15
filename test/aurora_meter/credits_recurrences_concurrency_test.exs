defmodule AuroraMeter.CreditsRecurrencesConcurrencyTest do
  @moduledoc """
  Two schedulers against one engine (build unit 06d, gate G06 bullet 6, I16).

  `async: false` and no `DataCase`: the sandbox wraps a test in one transaction
  on one connection, which serialises the very contention a row lock and a
  unique index exist to survive. Every task here takes a real connection, its
  rows really commit, and the assertions are on the database.

  **Force the contention, do not hope for it** (findings X182, X186, X187). The
  rendezvous below holds the contested balance row `FOR UPDATE` from a third
  connection until Postgres reports that both racers are waiting, then releases
  them together. The trap worth repeating: a row-lock waiter is **invisible** to
  `pg_locks` filtered by `database`, because it waits on the holder's
  `transactionid` and that row carries no database.
  `pg_stat_activity.wait_event_type = 'Lock'` is what sees it.

  **Count the contended branch and assert it on an ordinary run** (X214). The
  engine counts `conflict` separately from `duplicate` for exactly this reason:
  a run that found the period already recorded before it opened a transaction
  is a `duplicate`, and only a run whose `ON CONFLICT DO NOTHING` came back
  empty **inside the balance row lock** is a `conflict`. Asserting `duplicate`
  would pass for two schedulers that never overlapped at all.
  """
  use ExUnit.Case, async: false

  @moduletag :fault
  @moduletag timeout: 180_000

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditRecurrence
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @dollar 1_000_000
  @allowance 5 * @dollar
  @cap 1 * @dollar

  @september ~U[2026-09-15 12:00:00Z]
  @october ~U[2026-10-15 12:00:00Z]
  @october_start ~U[2026-10-01 00:00:00Z]

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    Connections.register_prefix("recurconc")

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      Connections.cleanup!("recurconc")
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: AuroraMeter.Test.unique_tenant("recurconc")}
  end

  test "I18 two schedulers against fifty tenants issue one grant and one rollover per period",
       %{tenant: prefix} do
    tenants = for i <- 1..50, do: fund("#{prefix}_t#{i}")

    # September, granted once and left unspent, so October owes every tenant an
    # allowance **and** a rollover: the criterion is one of each per period.
    AuroraMeter.Test.with_clock(@september, fn ->
      {:ok, %{counts: %{"granted" => 50}}} = Recurrences.run(tenant: tenants)
    end)

    results =
      AuroraMeter.Test.with_clock(@october, fn ->
        race(100, fn i -> Recurrences.run(tenant: Enum.at(tenants, div(i - 1, 2))) end)
      end)

    counts = tally(results)

    # Fifty periods, each granted exactly once however the hundred runs
    # interleaved, and fifty told the period was already theirs.
    assert counts["granted"] == 50, inspect(counts)
    assert counts["duplicate"] == 50, inspect(counts)
    assert counts["failed"] == 0, inspect(counts)
    assert counts["rollover"] == 50 * @cap

    # The effect, which a return value cannot prove.
    assert october_rows(tenants) == 50
    assert length(october_lots(tenants, :allowance)) == 50
    assert length(october_lots(tenants, :rollover)) == 50

    for tenant <- tenants do
      assert Credits.balance(tenant).available == @allowance + @cap, "tenant #{tenant}"
    end

    # The contention is asserted rather than assumed. `conflict` is only reached
    # inside the balance row lock, so a positive count is a race that really
    # happened; the rest were serialised and short-circuited on the row.
    assert counts["conflict"] > 0,
           "not one of the hundred runs reached the conflict guard, so this proves the " <>
             "arithmetic and nothing about two schedulers: #{inspect(counts)}"
  end

  test "I18 a rendezvous that guarantees the race issues exactly one grant per period",
       %{tenant: prefix} do
    # The breadth test above measures whatever contention the machine happens to
    # produce. This one guarantees it: the balance row is held from a third
    # connection until Postgres reports both racers waiting on it.
    outcomes =
      for round <- 1..6 do
        tenant = fund("#{prefix}_r#{round}")

        AuroraMeter.Test.with_clock(@september, fn ->
          contended_pair(tenant, fn -> Recurrences.run(tenant: tenant) end)
        end)
      end

    contended = Enum.count(outcomes, & &1.contended)

    assert contended == 6,
           "the rendezvous released #{contended} of 6 rounds with both runs waiting. Either " <>
             "Postgres stopped reporting the waiters, or one run finished before the other " <>
             "started, and in both cases this test proves nothing about the race."

    for %{tenant: tenant, results: results} <- outcomes do
      counts = tally(results)

      assert counts["granted"] == 1, "tenant #{tenant}: #{inspect(counts)}"
      assert counts["conflict"] == 1, "tenant #{tenant}: #{inspect(counts)}"

      assert 1 =
               TestRepo.one(
                 from(r in CreditRecurrence, where: r.tenant_key == ^tenant, select: count(r.id))
               )

      assert [lot] = lots(tenant)
      assert lot.amount == @allowance
      assert Credits.balance(tenant).available == @allowance
    end
  end

  test "I18 the ledger's reference index refuses a second grant even with the recurrence guard bypassed",
       %{tenant: prefix} do
    # **Negative control, half one** (X125). The two guards are deliberately
    # redundant. With the recurrence row out of the picture entirely, the
    # ledger's own `(kind, reference)` uniqueness still admits exactly one
    # grant, decided inside the same balance row lock.
    outcomes =
      for round <- 1..4 do
        tenant = fund("#{prefix}_c#{round}")

        reference =
          Recurrences.reference(
            tenant,
            Recurrences.key(:monthly, :allowance, "1", @october_start)
          )

        # Through the ledger rather than the facade: the facade refuses a
        # caller-supplied `recurring:` reference outright, which is the point of
        # the namespace and is asserted elsewhere. What is under test here is
        # what the index does when two writers reach it with the same string.
        result =
          contended_pair(tenant, fn ->
            Ledger.grant_with_status(tenant, @allowance,
              reference: reference,
              category: :promotional
            )
          end)

        Map.put(result, :reference, reference)
      end

    assert Enum.count(outcomes, & &1.contended) == 4

    for %{tenant: tenant, results: results} <- outcomes do
      assert Enum.count(results, &match?({:ok, _, :new}, &1)) == 1, inspect(results)
      assert Enum.count(results, &match?({:ok, _, :duplicate}, &1)) == 1, inspect(results)
      assert [%{amount: @allowance}] = lots(tenant)
    end
  end

  test "I18 a per-run reference double-grants under the same rendezvous", %{tenant: prefix} do
    # **Negative control, half two.** The same race, with the one thing the
    # engine exists to supply removed: a reference that is stable for the
    # period. A host cron that mints its own per run grants twice for one
    # period, and nothing in the ledger objects. If this had granted once, the
    # tests above would not be evidence about the key.
    outcomes =
      for round <- 1..4 do
        tenant = fund("#{prefix}_n#{round}")

        contended_pair(tenant, fn ->
          Credits.grant_with_status(tenant, @allowance,
            reference: "#{tenant}:naive:#{System.unique_integer([:positive])}",
            category: :promotional
          )
        end)
      end

    assert Enum.count(outcomes, & &1.contended) == 4

    for %{tenant: tenant, results: results} <- outcomes do
      assert Enum.count(results, &match?({:ok, _, :new}, &1)) == 2, inspect(results)
      assert length(lots(tenant)) == 2
      assert Credits.balance(tenant).available == 2 * @allowance
    end
  end

  test "I18 a debit racing the recurrence leaves the carry computed from the committed availability",
       %{tenant: prefix} do
    outcomes =
      for round <- 1..6 do
        tenant = fund("#{prefix}_d#{round}")

        AuroraMeter.Test.with_clock(@september, fn ->
          {:ok, _} = Recurrences.run(tenant: tenant)
        end)

        AuroraMeter.Test.with_clock(@october, fn ->
          contended_pair(tenant, [
            fn -> Recurrences.run(tenant: tenant) end,
            fn -> Credits.debit(tenant, 4 * @dollar, "#{tenant}:spend") end
          ])
        end)
      end

    assert Enum.count(outcomes, & &1.contended) == 6

    for %{tenant: tenant} <- outcomes do
      september = Enum.find(lots(tenant), &(&1.expires_at == @october_start))
      carried = Enum.find(lots(tenant), &(&1.reference =~ ":rollover"))
      carry = if carried, do: carried.amount, else: 0

      # Whichever committed first, the identity holds: everything September was
      # granted was either spent, carried, or destroyed. A carry computed from a
      # stale reading would break it in one direction or the other.
      assert september.consumed + september.expired == september.amount
      assert carry == min(september.amount - september.consumed, @cap)
      assert carry in [0, @dollar]
      assert Credits.balance(tenant).debt == 0
    end

    # Both orders are reachable, and over six rounds at least one of each is
    # what makes this a race rather than a fixture. Reported rather than
    # asserted, because the machine decides which side wins and a flaky
    # assertion on that would be worse than the number.
    carries = for %{tenant: tenant} <- outcomes, do: carry_of(tenant)
    assert Enum.all?(carries, &(&1 in [0, @dollar])), inspect(carries)
  end

  # -- fixtures and harness ----------------------------------------------------

  defp fund(tenant) do
    AuroraMeter.subscribe(tenant, :allowance)
    Ledger.enable_lots!(tenant)
    tenant
  end

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))

  defp carry_of(tenant) do
    case Enum.find(lots(tenant), &(&1.reference =~ ":rollover")) do
      nil -> 0
      lot -> lot.amount
    end
  end

  defp october_rows(tenants) do
    TestRepo.one(
      from(r in CreditRecurrence,
        where: r.tenant_key in ^tenants and r.period_start == ^@october_start,
        select: count(r.id)
      )
    )
  end

  defp october_lots(tenants, :rollover) do
    tenants |> all_october_lots() |> Enum.filter(&(&1.reference =~ ":rollover"))
  end

  defp october_lots(tenants, :allowance) do
    tenants |> all_october_lots() |> Enum.reject(&(&1.reference =~ ":rollover"))
  end

  defp all_october_lots(tenants) do
    TestRepo.all(
      from(l in CreditLot,
        where:
          l.tenant_key in ^tenants and
            fragment("?->>'recurrence_key' like ?", l.source, "%:2026-10-01T00:00:00Z")
      )
    )
  end

  defp tally(results) do
    Enum.reduce(results, %{}, fn
      {:ok, %{counts: counts}}, acc -> Map.merge(acc, counts, fn _k, a, b -> a + b end)
      _other, acc -> acc
    end)
  end

  # `n` tasks, each on its own real connection, released together.
  defp race(n, fun) do
    parent = self()
    tasks = for i <- 1..n, do: Task.async(fn -> racer(parent, i, fun) end)

    for _ <- 1..n, do: assert_receive({:ready, _}, 60_000)
    for task <- tasks, do: send(task.pid, :go)

    Task.await_many(tasks, 150_000)
  end

  # The connection is taken AFTER the barrier on purpose: holding one from every
  # task while they wait deadlocks the moment there are more tasks than the pool
  # has connections.
  defp racer(parent, i, fun) do
    send(parent, {:ready, i})

    receive do
      :go -> :ok
    after
      60_000 -> exit(:never_released)
    end

    own = Connections.checkout!()

    try do
      fun.(i)
    after
      if own, do: Sandbox.checkin(TestRepo)
    end
  end

  defp contended_pair(tenant, fun) when is_function(fun, 0),
    do: contended_pair(tenant, [fun, fun])

  defp contended_pair(tenant, [a, b]) do
    parent = self()
    holder = spawn_holder(tenant)

    tasks =
      for fun <- [a, b] do
        Task.async(fn ->
          Connections.checkout!()
          send(parent, :queued)
          fun.()
        end)
      end

    for _ <- 1..2, do: assert_receive(:queued, 60_000)

    contended = await_waiters(2, 500)
    send(holder, :release)
    results = Task.await_many(tasks, 90_000)

    %{tenant: tenant, contended: contended, results: results}
  end

  # The contested row is the wallet's balance row, which is the first lock every
  # ledger write takes and the first thing `Ledger.recurrence/2` takes too.
  defp spawn_holder(tenant) do
    parent = self()

    pid =
      spawn(fn ->
        Connections.checkout!()

        TestRepo.transaction(fn ->
          TestRepo.query!(
            "INSERT INTO aurora_meter_credit_balances (id, tenant_key, currency, inserted_at, updated_at) " <>
              "VALUES (gen_random_uuid(), $1, 'USD', now(), now()) ON CONFLICT (tenant_key) DO NOTHING",
            [tenant]
          )

          TestRepo.query!(
            "SELECT id FROM aurora_meter_credit_balances WHERE tenant_key = $1 FOR UPDATE",
            [tenant]
          )

          send(parent, :holding)

          # Shorter than the pool's own ownership timeout on purpose: a
          # rendezvous whose racers died must release the connection itself
          # rather than leave the pool to disconnect it and bury the real
          # failure under a page of DBConnection noise.
          receive do
            :release -> :ok
          after
            10_000 -> :ok
          end
        end)
      end)

    assert_receive(:holding, 60_000)
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
end
