if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.RetentionControlsTest do
    @moduledoc """
    Build unit 05d, and the row `open-findings.md` X215 left open: the retention
    worker's kill-and-resume and duplicate-jobs cases, which could not be proved
    in 05c because the worker did not exist yet.

    Not `AuroraMeter.DataCase`: a killed process cannot be killed inside the
    sandbox without taking the test's own connection with it, and "it resumed"
    is only a claim if the batches before the kill really committed. Every task
    here takes a real connection and the assertions are on rows.

    The fixtures are flush receipts stamped sixty days ago. Every other test in
    this suite writes receipts stamped now, so the default thirty day window
    reaches exactly this file's rows and nothing else's, which is what makes a
    non-sandbox test that deletes rows safe to run beside the others.
    """
    use ExUnit.Case, async: false

    alias AuroraMeter.Checkpoints
    alias AuroraMeter.Oban.Retention, as: Worker
    alias AuroraMeter.Operations
    alias AuroraMeter.Retention
    alias AuroraMeter.Schema.FlushReceipt
    alias AuroraMeter.Test.Connections
    alias AuroraMeter.TestRepo
    alias Ecto.Adapters.SQL.Sandbox

    import Ecto.Query, only: [from: 2]

    @moduletag timeout: 120_000

    @sixty_days 60 * 86_400
    @node "retainc_node"

    setup do
      :ok = Sandbox.checkout(TestRepo, sandbox: false)

      # The real Flusher would write a heartbeat of its own on an idle tick, and
      # on this connection that row is visible to the receipt rule.
      :sys.suspend(AuroraMeter.Flusher)

      clear!()

      on_exit(fn ->
        :ok = Sandbox.checkout(TestRepo, sandbox: false)
        clear!()
        Enum.each(Worker.operations(), &Operations.clear_checkpoint/1)
        :sys.resume(AuroraMeter.Flusher)
        Sandbox.checkin(TestRepo)
      end)

      idle_heartbeat!()

      :ok
    end

    test "I16 the retention worker resumes at its checkpoint after a kill" do
      planted = receipts!(50)

      # The fault point is the batch boundary itself: the telemetry handler runs
      # in the worker's own process, immediately after the checkpoint write and
      # before the next batch, so `Process.exit(self(), :kill)` there is exactly
      # "killed between batches" with nothing simulated.
      killed =
        kill_after_batches(2, fn ->
          Worker.perform(job(%{"only" => ["flush_receipts"], "batch_size" => 10}))
        end)

      assert killed == {:exit, :killed}

      # Two batches of ten committed, and the scan did not finish.
      assert remaining() == 30

      assert Operations.checkpoint(Retention.operation(:flush_receipts)).counts == %{
               "deleted" => 20,
               "examined" => 20
             }

      # The claim, and it is exact: the next run removes precisely the rows the
      # first did not, and no row was skipped. A delete sweep advances by doing
      # the work, so "resume" means the remaining set is exactly the complement
      # of what committed, which is what these two numbers say together.
      assert {:ok, %{flush_receipts: 30}} =
               Worker.perform(job(%{"only" => ["flush_receipts"], "batch_size" => 10}))

      assert remaining() == 0
      refute Enum.any?(planted, &TestRepo.get(FlushReceipt, &1))
    end

    test "I16 two retention jobs on independent connections delete every eligible row and none twice" do
      races = 5
      eligible = 20

      results =
        for _ <- 1..races do
          clear_receipts!()
          planted = receipts!(eligible)

          {waiters, deleted} = forced_race(hd(planted), eligible)

          assert Enum.sum(deleted) == eligible, """
          two concurrent prunes removed #{Enum.sum(deleted)} rows between them and there were
          #{eligible} to remove. A delete cannot remove a row twice, so a sum above the
          eligible count means the harness counted something else, and a sum below it means
          a row was skipped.
          """

          assert remaining() == 0
          %{waiters: waiters, deleted: deleted}
        end

      # X214's rule, met on an ordinary run rather than behind an environment
      # variable: the contended branch is counted and the count is asserted.
      # A rendezvous that stopped firing would make this zero, and a zero here
      # means the file measured two sequential prunes and proved nothing about
      # two concurrent ones.
      contended = Enum.count(results, &(&1.waiters >= 2))

      assert contended == races, """
      only #{contended} of #{races} races actually contended (waiters per race:
      #{inspect(Enum.map(results, & &1.waiters))}).

      The rendezvous holds one receipt row FOR UPDATE on a third connection until
      Postgres reports two waiters queued behind it. If it never fires, both
      prunes run one after the other and this file is a slow sequential test that
      still passes (open-findings.md X182, X186, X187).
      """

      # The control for the rendezvous itself (open-findings.md X125): the same
      # race with the holder removed and nothing else changed. If the unassisted
      # arm contends as often as the assisted one, the rendezvous is doing
      # nothing and the assertion above is not measuring what it claims.
      unassisted =
        for _ <- 1..races do
          clear_receipts!()
          planted = receipts!(eligible)
          {waiters, deleted} = unassisted_race(hd(planted), eligible)
          assert Enum.sum(deleted) == eligible
          waiters
        end

      unassisted_contended = Enum.count(unassisted, &(&1 >= 2))

      assert unassisted_contended < contended, """
      the unassisted race contended #{unassisted_contended} times out of #{races} and the
      assisted one #{contended}. They are the same, so the rendezvous is not what produced
      the contention and the assertion above measures something else.
      """

      race_report(%{
        test: :retention_forced_race,
        of: races,
        contended: contended,
        unassisted_contended: unassisted_contended,
        deleted_per_race: Enum.map(results, & &1.deleted)
      })
    end

    test "I16 the retention worker cancels nothing and reports a paused table" do
      receipts!(5)
      Operations.pause(Retention.operation(:flush_receipts))

      assert {:ok, {:blocked, report, [%{table: :flush_receipts, reason: :paused}]}} =
               Worker.perform(job(%{"only" => ["flush_receipts"]}))

      assert report.flush_receipts == 0
      assert remaining() == 5

      Operations.resume(Retention.operation(:flush_receipts))

      assert {:ok, %{flush_receipts: 5}} = Worker.perform(job(%{"only" => ["flush_receipts"]}))
    end

    test "the retention worker's job args are table names and bounded integers" do
      receipts!(6)

      # A malformed bound falls back to the default rather than being coerced,
      # so a bad argument cannot make a batch unbounded.
      assert {:ok, %{flush_receipts: 6}} =
               Worker.perform(
                 job(%{
                   "only" => ["flush_receipts"],
                   "batch_size" => "all of them",
                   "max_items" => -1
                 })
               )

      # And a name outside the allow list fails the job loudly rather than
      # silently pruning nothing.
      assert_raise ArgumentError, fn ->
        Worker.perform(job(%{"only" => ["aurora_meter_events"]}))
      end
    end

    test "the retention worker maps an unexpected return rather than matching on it" do
      # L05a-1: no `perform/1` hard-matches its operation's return.
      assert {:error, {:unexpected_return, :surprise}} = Worker.map_result(:surprise)
      assert {:ok, %{}} = Worker.map_result({:ok, %{}})
    end

    # -- the rendezvous --------------------------------------------------------

    # Two prunes on two independent connections, both blocked on one receipt row
    # a third connection holds `FOR UPDATE`, released only once Postgres reports
    # two waiters queued behind it.
    #
    # The waiter query does **not** filter on `database`: a row-lock waiter
    # blocks on the holder's `transactionid`, and a `transactionid` row in
    # `pg_locks` carries no database, so the obvious query returns nothing and
    # the rendezvous silently never fires (`open-findings.md` X186). This reads
    # `pg_stat_activity.wait_event_type` instead, which has the same property
    # and says what it means.
    defp forced_race(locked_id, eligible) do
      parent = self()
      {:ok, holder} = Task.Supervisor.start_link()

      lock =
        Task.Supervisor.async(holder, fn ->
          Connections.checkout!()

          TestRepo.transaction(fn ->
            TestRepo.query!(
              "SELECT id FROM aurora_meter_flush_receipts WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(locked_id)]
            )

            send(parent, :holding)

            receive do
              :release -> :ok
            after
              30_000 -> :timeout
            end
          end)
        end)

      assert_receive :holding, 5_000

      workers =
        for _ <- 1..2 do
          Task.Supervisor.async(holder, fn ->
            Connections.checkout!()
            send(parent, :ready)

            receive do: (:go -> :ok)

            # `max_items` twice `batch_size`, so the winner's second (empty)
            # batch ends its scan and the run reports `{:ok, _}` rather than a
            # budget it happened to fill exactly.
            {:ok, report} =
              Retention.prune(
                only: [:flush_receipts],
                batch_size: eligible,
                max_items: eligible * 2
              )

            report.flush_receipts
          end)
        end

      for _ <- 1..2, do: assert_receive(:ready, 5_000)
      Enum.each(workers, &send(&1.pid, :go))

      waiters = wait_for_waiters(2, 100)
      send(lock.pid, :release)
      Task.await(lock, 30_000)

      deleted = Enum.map(workers, &Task.await(&1, 30_000))
      Supervisor.stop(holder)

      {waiters, deleted}
    end

    # The same two workers released together, with no third connection holding
    # anything. Everything else is identical.
    defp unassisted_race(_locked_id, eligible) do
      parent = self()
      {:ok, supervisor} = Task.Supervisor.start_link()

      workers =
        for _ <- 1..2 do
          Task.Supervisor.async(supervisor, fn ->
            Connections.checkout!()
            send(parent, :ready)

            receive do: (:go -> :ok)

            {:ok, report} =
              Retention.prune(
                only: [:flush_receipts],
                batch_size: eligible,
                max_items: eligible * 2
              )

            report.flush_receipts
          end)
        end

      for _ <- 1..2, do: assert_receive(:ready, 5_000)
      Enum.each(workers, &send(&1.pid, :go))

      waiters = wait_for_waiters(2, 20)
      deleted = Enum.map(workers, &Task.await(&1, 30_000))
      Supervisor.stop(supervisor)

      {waiters, deleted}
    end

    defp wait_for_waiters(_target, 0), do: 0

    defp wait_for_waiters(target, attempts) do
      %{rows: [[count]]} =
        TestRepo.query!(
          """
          SELECT count(*) FROM pg_stat_activity
           WHERE wait_event_type = 'Lock' AND state = 'active' AND pid <> pg_backend_pid()
          """,
          []
        )

      if count >= target do
        count
      else
        Process.sleep(50)
        wait_for_waiters(target, attempts - 1)
      end
    end

    # -- fixtures --------------------------------------------------------------

    defp job(args), do: %Oban.Job{args: args}

    defp receipts!(count) do
      at = DateTime.add(DateTime.utc_now(), -@sixty_days, :second)
      rows = for _ <- 1..count, do: %{id: Ecto.UUID.generate(), inserted_at: at}
      {^count, _} = TestRepo.insert_all(FlushReceipt, rows)
      Enum.map(rows, & &1.id)
    end

    defp remaining do
      cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      TestRepo.aggregate(from(r in FlushReceipt, where: r.inserted_at < ^cutoff), :count)
    end

    defp idle_heartbeat! do
      Checkpoints.put(
        "flush:#{@node}",
        %{"version" => Retention.package_version()},
        %{},
        "idle"
      )
    end

    defp clear! do
      clear_receipts!()
      TestRepo.query!("DELETE FROM aurora_meter_checkpoints WHERE name LIKE 'flush:%'", [])
      Enum.each(Worker.operations(), &Operations.clear_checkpoint/1)
    end

    # Only this file's rows: every other test's receipts are stamped now.
    defp clear_receipts! do
      cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      TestRepo.delete_all(from(r in FlushReceipt, where: r.inserted_at < ^cutoff))
    end

    defp race_report(counts) do
      if System.get_env("AURORA_RACE_REPORT"), do: IO.puts("[05d retention] " <> inspect(counts))
      :ok
    end

    # `spawn_monitor`, not `Task.async`: a task is linked to the caller, so a
    # `:kill` inside it takes the test process with it.
    defp kill_after_batches(n, fun) do
      handler = "retainc-kill-#{System.unique_integer([:positive])}"
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      :telemetry.attach(
        handler,
        [:aurora_meter, :operations, :batch],
        fn _event, _measurements, _metadata, _config ->
          if Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) >= n do
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Connections.checkout!()
          send(parent, {:done, fun.()})
        end)

      result =
        receive do
          {:done, value} ->
            receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (5_000 -> :ok)
            value

          {:DOWN, ^ref, :process, ^pid, reason} ->
            {:exit, reason}
        after
          30_000 -> flunk("the worker neither finished nor died within 30 s")
        end

      :telemetry.detach(handler)
      Agent.stop(counter)

      result
    end
  end
end
