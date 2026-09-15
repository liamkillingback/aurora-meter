if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.ObanConcurrencyTest.UnguardedExpiry do
    @moduledoc """
    `AuroraMeter.Oban.CreditExpiry` with the `unique` option taken off, and
    nothing else changed.

    This is the negative control the X125 rule asks for: the duplicate-run
    property is guarded in two places, Oban's job uniqueness and the grant row's
    own `FOR UPDATE` re-read, so a test of one of them has to disable the other
    or it proves nothing about either. Disabling the ledger's half is not
    available to this unit (06a owns that file, and the constraint would still
    be there), so the control goes the other way: take uniqueness off, keep
    everything else, and see whether the outcome changes.
    """

    use Oban.Worker, queue: :aurora_meter, max_attempts: 3

    # A module attribute rather than an alias, because an alias to the module
    # this one is a copy of reads as though the two were interchangeable.
    @guarded AuroraMeter.Oban.CreditExpiry

    # It **delegates** rather than reimplementing, which is what makes it a
    # control: the only difference from `AuroraMeter.Oban.CreditExpiry` is the
    # missing `unique` on the line above. A copy of the body would drift from
    # the original and then prove nothing about it (build unit 05c, which gave
    # the worker its batch loop).
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{} = job), do: @guarded.perform(job)
  end

  defmodule AuroraMeter.ObanConcurrencyTest do
    @moduledoc """
    Two runs of one worker, on two independent connections, contending for one
    grant row.

    Not `AuroraMeter.DataCase`, for the reason `credits_concurrency_test.exs`
    gives: the sandbox wraps a test in one transaction on one connection, which
    serialises the contention this file exists to prove. Every task takes a real
    connection, the rows really commit, and the tenant's rows are deleted
    afterwards.
    """
    use ExUnit.Case, async: false

    import Ecto.Query, only: [from: 2]

    alias AuroraMeter.Credits
    alias AuroraMeter.Oban.CreditExpiry
    alias AuroraMeter.ObanConcurrencyTest.UnguardedExpiry
    alias AuroraMeter.Operations
    alias AuroraMeter.Schema.CreditTransaction
    alias AuroraMeter.Test.Connections
    alias AuroraMeter.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    @rendezvous_timeout 10_000

    setup do
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      tenant = AuroraMeter.Test.unique_tenant("obansched")

      on_exit(fn ->
        :ok = Sandbox.checkout(TestRepo, sandbox: false)
        # The checkpoint is installation-wide, so no `tenant_key LIKE` can reach
        # it and `cleanup!/1` cannot either (build unit 05c).
        Operations.clear_checkpoint(CreditExpiry.operation())
        Connections.cleanup!(tenant)
        Sandbox.checkin(TestRepo)
      end)

      {:ok, tenant: tenant}
    end

    test "I16 two CreditExpiry runs on independent connections expire each grant once", %{
      tenant: tenant
    } do
      grants = for n <- 1..12, do: due_grant(tenant, "promo#{n}:#{tenant}")
      assert length(grants) == 12

      results = Connections.run(2, fn _i -> CreditExpiry.perform(%Oban.Job{args: %{}}) end)

      # Assert on the rows, not on what the tasks returned (docs/testing.md).
      assert length(expiries(tenant)) == 12

      counted = for {:ok, report} <- results, do: report.counts["expired"]
      assert length(counted) == 2
      assert Enum.sum(counted) == 12

      # Every grant was promotional and every one of them is gone, so the
      # balance is the whole of it and `held` never moved.
      assert %{balance: 0, promotional: 0, held: 0} =
               Map.take(Credits.balance(tenant), [:balance, :promotional, :held])

      # Which side won how many is timing, and asserting a split would be a
      # flaky test. The distribution is the interesting number, so it is printed
      # when asked for and never otherwise (X135, X149: a test asserts every
      # time and records only when asked). The deterministic proof that a run
      # can lose, and that the grant row lock is what tells it so, is the next
      # test.
      race_report(%{test: :volume, won: counted})
    end

    test "I16 the CreditExpiry run that loses the grant row lock expires nothing", %{
      tenant: tenant
    } do
      result = contended(tenant, CreditExpiry)

      # One expiry row for a grant two runs both selected as due. The loser's
      # `{:ok, 0}` is the `expired_at` re-read inside the grant row's
      # `FOR UPDATE` answering, and `waiters` is the proof it had something to
      # lose: both runs were queued on that lock before either could commit.
      assert result.waiters >= 2
      assert result.expiries == 1
      assert result.winner == 1
      assert result.loser == 0

      race_report(%{test: :rendezvous, worker: CreditExpiry, result: result})
    end

    test "I16 the same is true with Oban's uniqueness removed, so uniqueness is not what answers",
         %{tenant: tenant} do
      # X125, and the result is the finding rather than the pass. Removing the
      # uniqueness layer changes nothing, because in this race there is no Oban
      # instance to deduplicate anything: `perform/1` is called directly on two
      # connections. What refuses the second expiry is the `expired_at` re-read
      # inside the grant row's `FOR UPDATE`, and the loser's `{:ok, 0}` is that
      # layer's own answer. So this file does not test uniqueness, and the
      # evidence says so rather than recording a pass for it.
      refute UnguardedExpiry.__opts__()[:unique]
      assert CreditExpiry.__opts__()[:unique][:period] == :infinity

      result = contended(tenant, UnguardedExpiry)

      assert result.waiters >= 2
      assert result.expiries == 1
      assert result.winner == 1
      assert result.loser == 0

      race_report(%{test: :rendezvous, worker: UnguardedExpiry, result: result})
    end

    # -- the rendezvous --------------------------------------------------------

    # Two runs of `worker` are made to contend for one grant row, deterministically.
    #
    # A third connection locks the grant row `FOR UPDATE` and holds it. Both
    # runs then select the grant as due (they must: nothing can set `expired_at`
    # while the lock is held) and block on the row lock. Only when Postgres
    # itself reports two backends waiting on a lock is the holder released, so
    # "both runs listed this grant" is observed rather than hoped for.
    #
    # X182 is why it is built this way. The assertion that matters lives in the
    # branch only the losing run reaches, and a race left to chance can give
    # that branch zero executions over every seed while the test stays green.
    # Here it runs once per call, and the count is returned and asserted.
    defp contended(tenant, worker) do
      grant = due_grant(tenant, "promo:#{tenant}")
      parent = self()

      locker =
        Task.async(fn ->
          Connections.checkout!()

          TestRepo.transaction(
            fn ->
              TestRepo.one!(
                from(t in CreditTransaction, where: t.id == ^grant.id, lock: "FOR UPDATE")
              )

              send(parent, :locked)
              receive do: (:release -> :ok)
            end,
            timeout: @rendezvous_timeout
          )
        end)

      assert_receive :locked, @rendezvous_timeout

      racers =
        for _ <- 1..2 do
          Task.async(fn ->
            Connections.checkout!()

            try do
              worker.perform(%Oban.Job{args: %{}})
            after
              Sandbox.checkin(TestRepo)
            end
          end)
        end

      waiters = await_waiters(2)
      send(locker.pid, :release)
      Task.await(locker, @rendezvous_timeout)

      counted = racers |> Enum.map(&Task.await(&1, @rendezvous_timeout)) |> Enum.map(&count!/1)

      %{
        expiries: length(expiries(tenant)),
        winner: Enum.max(counted),
        loser: Enum.min(counted),
        waiters: waiters
      }
    end

    # 05c: the worker returns its run report, so the number this test is about
    # is one field of it rather than the whole return.
    defp count!({:ok, %{counts: counts}}), do: Map.fetch!(counts, "expired")

    # Postgres' own view of the rendezvous. A backend queued behind the grant
    # row's lock is reported by the server as waiting on a lock, which is how
    # this test learns that both runs are past their listing query and behind
    # the holder rather than hoping they are. `async: false`, so no other test
    # module is running and contributing waiters.
    defp await_waiters(expected) do
      deadline = System.monotonic_time(:millisecond) + @rendezvous_timeout
      poll_waiters(expected, deadline)
    end

    defp poll_waiters(expected, deadline) do
      count = lock_waiters()

      cond do
        count >= expected ->
          count

        System.monotonic_time(:millisecond) > deadline ->
          flunk(
            "only #{count} of #{expected} runs reached the grant row lock before the deadline"
          )

        true ->
          Process.sleep(20)
          poll_waiters(expected, deadline)
      end
    end

    # `pg_stat_activity` rather than `pg_locks`: a backend queued behind a row
    # lock usually waits on the holder's `transactionid`, and a `transactionid`
    # lock carries no `database`, so the obvious `pg_locks` query filtered by
    # database counts zero of them. Measured on 2026-09-15, and it is the
    # difference between a rendezvous and a fifteen second timeout.
    defp lock_waiters do
      %{rows: [[count]]} =
        TestRepo.query!(
          """
          SELECT count(*) FROM pg_stat_activity
           WHERE datname = current_database()
             AND wait_event_type = 'Lock'
             AND pid <> pg_backend_pid()
          """,
          []
        )

      count
    end

    # -- fixtures --------------------------------------------------------------

    defp due_grant(tenant, reference) do
      {:ok, txn} =
        Credits.grant(tenant, 1_000_000,
          reference: reference,
          category: :promotional,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        )

      txn
    end

    defp expiries(tenant) do
      TestRepo.all(
        from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:expire)
      )
    end

    defp race_report(counts) do
      if System.get_env("AURORA_RACE_REPORT"), do: IO.puts("[05a race] " <> inspect(counts))
      :ok
    end
  end
end
