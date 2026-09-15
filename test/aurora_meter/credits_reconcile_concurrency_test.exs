defmodule AuroraMeter.CreditsReconcileConcurrencyTest do
  @moduledoc false
  # async: false and no DataCase, following `credits_concurrency_test.exs`: the
  # sandbox wraps a test in one transaction on one connection, which serialises
  # the very races this file exists to prove. Every task takes a real connection
  # and the rows really commit; the tenant's rows are deleted afterwards.
  use ExUnit.Case, async: false

  @moduletag :fault

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Clock
  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  # A function, not a module attribute: an anonymous function cannot be escaped
  # into one.
  defp release_all, do: fn _hold -> :release end

  # Settles the even-numbered jobs for a quarter of their hold and releases the
  # odd-numbered ones, so one sweep exercises both terminal transitions.
  defp settle_even do
    fn %{reference: reference} ->
      if reference |> job_number() |> rem(2) == 0, do: {:settle, 25_000}, else: :release
    end
  end

  defp job_number("job" <> rest), do: rest |> String.split(":") |> hd() |> String.to_integer()

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    tenant = AuroraMeter.Test.unique_tenant("reconcile")

    on_exit(fn ->
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      Connections.cleanup!(tenant)
      Sandbox.checkin(TestRepo)
    end)

    {:ok, tenant: tenant}
  end

  defp cutoff, do: DateTime.add(Clock.now(), 1, :second)

  defp entries(tenant, kind) do
    TestRepo.all(from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^kind))
  end

  defp holds(tenant) do
    TestRepo.all(
      from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:hold)
    )
  end

  defp balance(tenant) do
    Credits.balance(tenant)
  end

  test "I11 a reconciler release and a caller settle produce exactly one terminal transition",
       %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 2_400_000, reference: "seed:#{tenant}")
    for n <- 1..12, do: {:ok, _} = Credits.hold(tenant, 100_000, "job#{n}:#{tenant}")

    at = cutoff()

    results =
      Connections.run(24, fn i ->
        n = div(i - 1, 2) + 1
        reference = "job#{n}:#{tenant}"

        if rem(i, 2) == 0 do
          {:settle, Credits.settle(reference, 40_000)}
        else
          {:reconcile,
           Credits.reconcile_holds(
             older_than: at,
             tenant: tenant,
             reference_prefix: reference,
             reconciler: release_all()
           )}
        end
      end)

    # Assert on the rows, not on what the tasks returned (docs/testing.md).
    settles = entries(tenant, :settle)
    releases = entries(tenant, :release)
    closed = holds(tenant)

    assert length(closed) == 12
    assert Enum.all?(closed, &(&1.status in [:settled, :released]))
    assert length(settles) + length(releases) == 12

    both =
      MapSet.intersection(
        MapSet.new(settles, & &1.reference),
        MapSet.new(releases, & &1.reference)
      )

    assert MapSet.size(both) == 0, "these holds were both settled and released: #{inspect(both)}"

    # X125: name the layer that answered. The only thing standing between a
    # settle and a release of one hold is the `FOR UPDATE` on the hold row in
    # `Ledger.pending_hold/3` and the `status = 'pending'` re-read inside it. The
    # `(kind, reference)` unique index cannot help here, because a `:settle` row
    # and a `:release` row for one reference differ in `kind` and the index
    # permits both (proved directly in
    # `AuroraMeter.CreditsReconcileHoldsTest`). So a loser must carry
    # `:already_settled`, the atom only that re-read produces; a changeset error
    # would mean a constraint answered and the lock did not.
    #
    # **And this loop may be empty, which is why it is not the proof.** Measured
    # over ten seeds on 2026-09-15, the caller's settle won all twelve holds
    # every time: `reconcile_holds/1` lists, spawns a task and calls back before
    # it writes, so it is always the slower of the two here. What this test
    # proves is the volume property, that twelve simultaneous pairs produce
    # twelve closing rows and no hold with both. Each direction of the race is
    # proved deterministically by a test of its own: the reconciler losing in the
    # next test, and the reconciler winning in the one after it.
    losers =
      for {:settle, {:error, reason}} <- results do
        refute match?(%Ecto.Changeset{}, reason),
               "a database constraint refused the settle, not the hold row lock: " <>
                 inspect(reason)

        reason
      end

    assert Enum.all?(losers, &(&1 == :already_settled))

    # Conservation. Every settle cost 40_000 and every release cost nothing, so
    # the balance follows from the winners alone and `held` is back to zero.
    expected = 2_400_000 - 40_000 * length(settles)
    assert %{balance: ^expected, held: 0, available: ^expected} = balance(tenant)

    reconciled = for {:reconcile, {:ok, report}} <- results, do: report
    assert length(reconciled) == 12
    assert Enum.sum(Enum.map(reconciled, & &1.released)) == length(releases)
    assert Enum.sum(Enum.map(reconciled, & &1.failed)) == 0

    # Which side won is timing, and asserting a split would be a flaky test. The
    # distribution is still the interesting number, so it is printed when asked
    # for and never otherwise (open-findings.md X135, X149: a test asserts every
    # time and records only when asked). The deterministic proof that the
    # reconciler can be the loser, and that the hold row lock is what tells it
    # so, is the next test.
    race_report(%{
      settled_by_caller: length(settles),
      released_by_reconciler: length(releases),
      settle_losers: length(losers),
      reconciler_already_closed: Enum.sum(Enum.map(reconciled, & &1.already_closed))
    })
  end

  test "I11 a reconciler decision applied after a concurrent settle is refused by the hold row lock",
       %{tenant: tenant} do
    # The deterministic half of the race above. The callback is held open until
    # the hold's own worker has settled and committed, so the reconciler's
    # release is applied strictly afterwards and must lose.
    #
    # X125: the layer that refuses it is named by the outcome. A `:settle` row
    # and a `:release` row for one reference differ in `kind`, so the
    # `(kind, reference)` unique index permits both and cannot be what answered.
    # The only thing that can is the `status = 'pending'` re-read inside
    # `Ledger.pending_hold/3`'s `FOR UPDATE`.
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")
    at = cutoff()
    parent = self()

    blocking = fn _hold ->
      send(parent, {:deciding, self()})
      receive do: ({:go, decision} -> decision)
    end

    run =
      Task.async(fn ->
        Connections.checkout!()
        Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: blocking)
      end)

    assert_receive {:deciding, callback}, 10_000

    # The worker finishes while the reconciler is still deciding.
    assert {:ok, _txn} = Credits.settle("job:#{tenant}", 400_000)

    send(callback, {:go, :release})

    assert {:ok, report} = Task.await(run, 30_000)
    assert report.examined == 1
    assert report.already_closed == 1
    assert report.released == 0
    assert report.failed == 0

    assert entries(tenant, :release) == []
    assert length(entries(tenant, :settle)) == 1
    assert [%CreditTransaction{status: :settled, settled_amount: 400_000}] = holds(tenant)
    assert %{balance: 600_000, held: 0} = balance(tenant)
  end

  test "I11 a with_credits caller whose hold the reconciler released records the executed cost",
       %{tenant: tenant} do
    # The other direction, and the one that can lose money. The reconciler wins:
    # it releases the hold while `with_credits/4` is still running the work. The
    # work then finishes and cost something, so the cost is recorded as a debit
    # on its own reference rather than dropped (open finding L4). Two real
    # connections, because the caller and the reconciler are two processes in
    # two transactions.
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    at = cutoff()
    parent = self()
    reference = "job:#{tenant}"

    caller =
      Task.async(fn ->
        Connections.checkout!()

        Credits.with_credits(tenant, 500_000, reference, fn ->
          send(parent, {:working, self()})
          receive do: (:finish -> {:ok, :done, 300_000})
        end)
      end)

    assert_receive {:working, _worker}, 10_000

    # The reconciler decides the work is abandoned, wrongly, and wins.
    assert {:ok, %{examined: 1, released: 1}} =
             Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: release_all())

    assert [%CreditTransaction{status: :released}] = holds(tenant)

    send(caller.pid, :finish)
    assert {:ok, :done} = Task.await(caller, 30_000)

    # No MatchError, no lost charge.
    assert length(entries(tenant, :release)) == 1
    assert entries(tenant, :settle) == []

    assert [%CreditTransaction{amount: -300_000, reference: debit_reference}] =
             entries(tenant, :debit)

    assert debit_reference == "settle_missed:" <> reference
    assert %{balance: 700_000, held: 0} = balance(tenant)
  end

  # Prints a race's observed distribution when AURORA_RACE_REPORT is set, and
  # writes nothing ever.
  defp race_report(counts) do
    if System.get_env("AURORA_RACE_REPORT") do
      IO.puts("[05b race] " <> inspect(counts))
    end

    :ok
  end

  test "I16 two reconcilers on two connections release one hold once", %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")
    at = cutoff()

    reports =
      Connections.run(2, fn _i ->
        Credits.reconcile_holds(
          older_than: at,
          tenant: tenant,
          reconciler: release_all()
        )
      end)

    assert [{:ok, a}, {:ok, b}] = reports
    assert length(entries(tenant, :release)) == 1
    assert entries(tenant, :settle) == []
    assert a.released + b.released == 1
    assert a.failed + b.failed == 0

    # The loser either listed the hold and was refused by the row lock
    # (`already_closed`), or listed after the winner committed and found
    # nothing (`examined: 0`). Both are correct; a second release row is not.
    loser = if a.released == 1, do: b, else: a
    assert loser.already_closed == 1 or loser.examined == 0

    assert %{balance: 1_000_000, held: 0} = balance(tenant)
  end

  test "I11 twenty-four concurrent reconciler runs over one hot wallet conserve the balance",
       %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_200_000, reference: "seed:#{tenant}")
    for n <- 1..12, do: {:ok, _} = Credits.hold(tenant, 100_000, "job#{n}:#{tenant}")
    at = cutoff()

    assert %{balance: 1_200_000, held: 1_200_000, available: 0} = balance(tenant)

    # Every task sweeps the whole tenant, so twenty-four runs contend for the
    # same twelve holds and the same balance row. Two hundred and eighty-eight
    # decisions, twelve of which may write.
    reports =
      Connections.run(24, fn _i ->
        Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: settle_even())
      end)

    settles = entries(tenant, :settle)
    releases = entries(tenant, :release)

    assert length(settles) == 6
    assert length(releases) == 6
    assert Enum.all?(holds(tenant), &(&1.status in [:settled, :released]))

    # Conservation: six settles at 25_000 and nothing else moved.
    expected = 1_200_000 - 6 * 25_000
    assert %{balance: ^expected, held: 0, available: ^expected} = balance(tenant)

    totals = for {:ok, report} <- reports, do: report
    assert length(totals) == 24
    assert Enum.sum(Enum.map(totals, & &1.released)) == 6
    assert Enum.sum(Enum.map(totals, & &1.settled)) == 6
    assert Enum.sum(Enum.map(totals, & &1.failed)) == 0
  end

  test "I16 killing the reconciler between the callback and the application leaves the hold pending",
       %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")
    at = cutoff()
    parent = self()

    blocking = fn _hold ->
      send(parent, {:in_callback, self()})
      receive do: ({:release_me, decision} -> decision)
    end

    reconciler =
      spawn(fn ->
        Connections.checkout!()
        Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: blocking)
      end)

    assert_receive {:in_callback, task}, 10_000

    # Killed after the decision was asked for and before it could be applied.
    monitor = Process.monitor(reconciler)
    Process.exit(reconciler, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^reconciler, :killed}, 10_000

    # The callback is under AuroraMeter.TaskSupervisor and was started with
    # `async_nolink`, so it outlived the process that asked it. Let it finish;
    # its answer has nowhere to go.
    send(task, {:release_me, :release})

    Kill.assert_db!(fn ->
      assert [%CreditTransaction{status: :pending}] = holds(tenant)
      assert entries(tenant, :release) == []
      assert entries(tenant, :settle) == []
      assert %{held: 500_000, balance: 1_000_000} = balance(tenant)
    end)

    # And the next run applies the decision normally: a lost decision costs a
    # cycle, never a hold that can no longer be reconciled. There is no lease on
    # a hold, which is why a crashed reconciler leaves nothing behind.
    assert {:ok, %{examined: 1, released: 1}} =
             Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: release_all())

    assert [%CreditTransaction{status: :released}] = holds(tenant)
    assert %{held: 0, balance: 1_000_000} = balance(tenant)
  end

  test "I16 killing the reconciler after the application commits leaves exactly one terminal transition",
       %{tenant: tenant} do
    {:ok, _} = Credits.grant(tenant, 1_000_000, reference: "seed:#{tenant}")
    {:ok, _} = Credits.hold(tenant, 500_000, "job:#{tenant}")
    at = cutoff()

    TestConfig.with_config(
      [{:aurora_meter, :repo, AuroraMeter.Test.FaultRepo}],
      fn ->
        assert {:killed, _pid} =
                 Kill.run(
                   fn ->
                     Connections.checkout!()

                     Credits.reconcile_holds(
                       older_than: at,
                       tenant: tenant,
                       reconciler: release_all()
                     )
                   end,
                   at: :after_commit_before_ack,
                   label: :reconciler_dies_after_commit
                 )

        Faults.assert_fired!(:after_commit_before_ack)
      end
    )

    # The release committed before the kill, so it stands.
    Kill.assert_db!(fn ->
      assert [%CreditTransaction{status: :released}] = holds(tenant)
      assert length(entries(tenant, :release)) == 1
    end)

    # The report was lost with the process. The next run re-lists nothing,
    # because the hold is no longer pending, and writes no second row.
    assert {:ok, %{examined: 0, released: 0, already_closed: 0}} =
             Credits.reconcile_holds(older_than: at, tenant: tenant, reconciler: release_all())

    assert length(entries(tenant, :release)) == 1
    assert %{held: 0, balance: 1_000_000} = balance(tenant)
  end
end
