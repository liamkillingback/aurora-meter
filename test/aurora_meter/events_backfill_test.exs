defmodule AuroraMeter.EventsBackfillTest do
  @moduledoc """
  `mix aurora_meter.events.backfill` and the module behind it.

  The task exists to make a claim that must be exactly true: every event row an
  0.4.x node ever wrote can be given an identity, without losing what it
  already says and without becoming billable. So the tests run against a real
  database with really committed rows, not the sandbox, and the resume case is
  driven by an actual kill rather than by editing the checkpoint to whatever
  the author thinks a crash leaves behind.
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Events.Backfill
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Migrations
  alias AuroraMeter.Test.PeriodSources

  @checkpoint "events_backfill"

  describe "filling every legacy row" do
    test "I19 it fills every row, and no row twice" do
      with_legacy(12_000, fn repo ->
        {:ok, counts} = Backfill.run(repo: repo, batch_size: 1000)

        assert counts["scanned"] == 12_000
        assert counts["updated"] == 12_000
        assert counts["already_filled"] == 0
        assert counts["batches"] == 12
        assert Backfill.remaining(repo: repo) == 0

        %{rows: rows} =
          repo.query!(
            "SELECT count(*) FROM aurora_meter_events WHERE event_id <> 'legacy:' || id::text",
            []
          )

        assert rows == [[0]], "every identity is derived from the row's own primary key"
      end)
    end

    test "I19 it is idempotent: a second run updates nothing and changes no hash" do
      with_legacy(500, fn repo ->
        {:ok, first} = Backfill.run(repo: repo, batch_size: 100)
        before = Migrations.fingerprints(repo)

        # From the checkpoint: the cursor is past every row, so there is
        # nothing left to look at.
        {:ok, second} = Backfill.run(repo: repo, batch_size: 100)

        assert first["updated"] == 500
        assert second["scanned"] == 0
        assert second["updated"] == 0
        assert Migrations.fingerprints(repo) == before

        # And from nothing: a full rescan of a table that is already filled
        # must also update nothing. This is the case an operator reaches by
        # clearing the checkpoint and running it again "just to be sure".
        Checkpoints.delete(@checkpoint, repo: repo)
        {:ok, third} = Backfill.run(repo: repo, batch_size: 100)

        assert third["scanned"] == 500
        assert third["updated"] == 0
        assert third["already_filled"] == 500
        assert Migrations.fingerprints(repo) == before
      end)
    end

    test "I19 a run killed between batches resumes byte for byte" do
      uninterrupted =
        with_legacy(3000, fn repo ->
          {:ok, _counts} = Backfill.run(repo: repo, batch_size: 250)
          Migrations.fingerprints(repo)
        end)

      resumed =
        with_legacy(3000, fn repo ->
          killed = kill_after_batches(repo, 3, batch_size: 250)
          assert killed == :killed, "the run must really have been killed"

          checkpoint = Checkpoints.get(@checkpoint, repo: repo)
          assert checkpoint.cursor["seq"] > 0, "the cursor must name a committed batch"
          assert checkpoint.cursor["seq"] < 3000, "and the run must not have finished"
          assert Backfill.remaining(repo: repo) > 0

          # The killed run left state "running" behind, which is exactly the
          # state --force-resume exists for. Its advisory lock goes with the
          # connection, which the pool closes when it notices the client died,
          # so the refusal changes from :already_running to :stale_running
          # within a few tens of milliseconds. Waited for rather than slept
          # through, so this is a fact about the system and not about a sleep.
          assert {:error, :stale_running, _counts} =
                   await_lock_released(repo, batch_size: 250)

          {:ok, _counts} = Backfill.run(repo: repo, batch_size: 250, force_resume: true)
          assert Backfill.remaining(repo: repo) == 0

          Migrations.fingerprints(repo)
        end)

      assert length(uninterrupted) == 3000
      assert Enum.map(uninterrupted, &elem(&1, 0)) == Enum.map(resumed, &elem(&1, 0))

      assert Enum.map(uninterrupted, &elem(&1, 2)) == Enum.map(resumed, &elem(&1, 2)),
             "the payload hashes of an interrupted run and an uninterrupted one must be the " <>
               "same bytes, or a resume is a different answer to the same question"
    end

    test "I19 rows an old writer inserts during the run are picked up by the same pass" do
      with_legacy(400, fn repo ->
        handler = "backfill-late-writer-#{System.unique_integer([:positive])}"

        # An 0.4.x node writing through the old path while the backfill is in
        # flight: inserted at a batch boundary, from a connection of its own,
        # and waited on, so this is not a race. The new rows take a seq above
        # the cursor, which is exactly why a forward pass by seq reaches them.
        :telemetry.attach(
          handler,
          [:aurora_meter, :events, :backfill, :batch],
          fn _event, measure, _meta, _config ->
            if measure.batches == 1 do
              Task.await(
                Task.async(fn ->
                  Migrations.seed_legacy_events(repo, 50, tenant: "late_writer")
                end),
                15_000
              )
            end
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler) end)

        {:ok, counts} = Backfill.run(repo: repo, batch_size: 100)

        assert counts["scanned"] == 450
        assert counts["updated"] == 450
        assert Backfill.remaining(repo: repo) == 0
      end)
    end
  end

  describe "what it writes" do
    test "it resolves the period through the configured source" do
      with_legacy(2, fn repo ->
        {:ok, counts} = Backfill.run(repo: repo)

        assert counts["resolved"] == 2
        assert counts["unresolved"] == 0

        %{rows: [[period_start, source, attribution, occurred_at, inserted_at]]} =
          repo.query!(
            "SELECT period_start, period_source, attribution, occurred_at, inserted_at " <>
              "FROM aurora_meter_events ORDER BY seq LIMIT 1",
            []
          )

        assert NaiveDateTime.compare(period_start, ~N[2026-03-01 00:00:00]) == :eq
        assert source == "AuroraMeter.Period.Calendar"
        assert attribution == "resolved"
        assert occurred_at == inserted_at, "occurred_at is the approximation, and it is exact"
      end)
    end

    for {source, reason} <- [
          {PeriodSources.FutureWindow, "invalid_period:not_containing"},
          {PeriodSources.NotAMap, "invalid_period:not_a_map"}
        ] do
      test "it records an unresolved period when #{inspect(source)} cannot answer" do
        source = unquote(source)
        reason = unquote(reason)

        with_legacy(3, fn repo ->
          Config.with_config([{:aurora_meter, :period_source, source}], fn ->
            {:ok, counts} = Backfill.run(repo: repo)

            assert counts["resolved"] == 0
            assert counts["unresolved"] == 3
            assert counts["unresolved_reasons"] == %{reason => 3}

            %{rows: rows} =
              repo.query!(
                "SELECT DISTINCT attribution, period_source FROM aurora_meter_events",
                []
              )

            assert rows == [["unresolved", "AuroraMeter.Period.Calendar"]],
                   "a source that cannot place the instant gets the calendar month and a " <>
                     "flag saying so, never a guess presented as a fact"

            %{rows: [[period_start]]} =
              repo.query!("SELECT DISTINCT period_start FROM aurora_meter_events", [])

            assert NaiveDateTime.compare(period_start, ~N[2026-03-01 00:00:00]) == :eq
          end)
        end)
      end
    end

    test "it hashes a legacy row the way the documented tuple says" do
      with_legacy(1, fn repo ->
        {:ok, _counts} = Backfill.run(repo: repo)

        %{rows: [[id, hash, feature, quantity, occurred_at]]} =
          repo.query!(
            "SELECT id, payload_hash, feature, quantity, occurred_at " <>
              "FROM aurora_meter_events ORDER BY seq LIMIT 1",
            []
          )

        expected =
          Canonical.legacy_payload_hash(%{
            feature: feature,
            quantity: quantity,
            occurred_at: DateTime.from_naive!(occurred_at, "Etc/UTC"),
            metadata: %{}
          })

        assert hash == expected
        assert byte_size(hash) == 32
        refute is_nil(id)
      end)
    end

    test "L-03a-3 it writes no event totals" do
      with_legacy(100, fn repo ->
        {:ok, _counts} = Backfill.run(repo: repo)

        %{rows: [[totals]]} = repo.query!("SELECT count(*) FROM aurora_meter_event_totals", [])

        assert totals == 0,
               "a legacy event was never billed. Projecting it into the totals would make " <>
                 "unbilled history suddenly billable"
      end)
    end

    test "it leaves plan attribution null, because it cannot be reconstructed" do
      with_legacy(5, fn repo ->
        {:ok, _counts} = Backfill.run(repo: repo)

        %{rows: [[count]]} =
          repo.query!(
            "SELECT count(*) FROM aurora_meter_events " <>
              "WHERE plan_id IS NOT NULL OR plan_version IS NOT NULL",
            []
          )

        assert count == 0
      end)
    end

    test "it counts non-positive quantities and oversized metadata without failing" do
      with_legacy(1, fn repo ->
        Migrations.seed_legacy_events(repo, 1, tenant: "neg", quantity: -3)

        Migrations.seed_legacy_events(repo, 1,
          tenant: "fat",
          metadata: %{"blob" => String.duplicate("x", 20_000)}
        )

        {:ok, counts} = Backfill.run(repo: repo)

        assert counts["scanned"] == 3
        assert counts["updated"] == 3
        assert counts["nonpositive_quantity"] == 1
        assert counts["oversized_metadata"] == 1
      end)
    end
  end

  describe "bounds and refusals" do
    test "--dry-run writes nothing at all" do
      with_legacy(300, fn repo ->
        before = Migrations.fingerprints(repo)

        {:ok, dry} = Backfill.run(repo: repo, batch_size: 100, dry_run: true)

        assert Migrations.fingerprints(repo) == before

        assert Checkpoints.get(@checkpoint, repo: repo) == nil,
               "a dry run creates no checkpoint row either"

        {:ok, real} = Backfill.run(repo: repo, batch_size: 100)

        for key <- ~w(scanned updated already_filled resolved unresolved batches
                      nonpositive_quantity oversized_metadata) do
          assert dry[key] == real[key], "dry run and real run disagree on #{key}"
        end
      end)
    end

    test "--max-batches stops cleanly at the boundary and the next run continues" do
      with_legacy(500, fn repo ->
        {:ok, first} = Backfill.run(repo: repo, batch_size: 100, max_batches: 2)

        assert first["batches"] == 2
        assert first["updated"] == 200
        assert Backfill.remaining(repo: repo) == 300
        assert Checkpoints.get(@checkpoint, repo: repo).cursor["seq"] == first["cursor"]

        {:ok, second} = Backfill.run(repo: repo, batch_size: 100)

        assert second["updated"] == 300, "the second run reports its own work, not the total"
        assert Backfill.remaining(repo: repo) == 0
      end)
    end

    test "it refuses a second run while the checkpoint says running" do
      with_legacy(50, fn repo ->
        Checkpoints.put(@checkpoint, %{"seq" => 0}, %{}, "running", repo: repo)

        assert {:error, :stale_running, _counts} = Backfill.run(repo: repo)
        assert Backfill.remaining(repo: repo) == 50, "it must have changed nothing"

        {:ok, counts} = Backfill.run(repo: repo, force_resume: true)
        assert counts["updated"] == 50
      end)
    end

    test "it refuses a run while another connection holds the advisory lock" do
      with_legacy(50, fn repo ->
        parent = self()

        holder =
          Task.async(fn ->
            repo.checkout(fn ->
              repo.query!("SELECT pg_advisory_lock($1, $2)", [0x4155524F, 7])
              send(parent, :held)

              receive do
                :release -> :ok
              end

              repo.query!("SELECT pg_advisory_unlock($1, $2)", [0x4155524F, 7])
            end)
          end)

        assert_receive :held, 10_000

        assert {:error, :already_running, _counts} = Backfill.run(repo: repo)
        assert Backfill.remaining(repo: repo) == 50

        # Not even --force-resume can take a lock somebody holds. That is the
        # point of using a lock instead of a lease with a clock in it.
        assert {:error, :already_running, _counts} = Backfill.run(repo: repo, force_resume: true)
        assert Backfill.remaining(repo: repo) == 50

        send(holder.pid, :release)
        Task.await(holder, 10_000)

        {:ok, counts} = Backfill.run(repo: repo)
        assert counts["updated"] == 50
      end)
    end

    test "a paused checkpoint stops it, and pausing mid-run survives the run" do
      with_legacy(50, fn repo ->
        Checkpoints.pause(@checkpoint, repo: repo)

        assert {:error, :paused, _counts} = Backfill.run(repo: repo)
        assert Backfill.remaining(repo: repo) == 50

        Checkpoints.resume(@checkpoint, repo: repo)
        {:ok, counts} = Backfill.run(repo: repo)
        assert counts["updated"] == 50
        assert Checkpoints.paused?(@checkpoint, repo: repo) == false
      end)
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp with_legacy(count, fun) do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 6)
      if count > 0, do: Migrations.seed_legacy_events(repo, count)
      Migrations.up(repo, from: 7, version: 7)
      fun.(repo)
    end)
  end

  # Retries until the killed runner's connection has been reclaimed and its
  # advisory lock with it. Bounded, and it flunks rather than looping, so a
  # lock that is really stuck fails the test instead of hanging it.
  defp await_lock_released(repo, opts, attempts \\ 200) do
    case Backfill.run(Keyword.put(opts, :repo, repo)) do
      {:error, :already_running, _counts} when attempts > 0 ->
        Process.sleep(10)
        await_lock_released(repo, opts, attempts - 1)

      {:error, :already_running, _counts} ->
        flunk(
          "the advisory lock of a killed runner was still held after two seconds. It is " <>
            "released when the pool closes that connection; if it is not, a resume is " <>
            "blocked until something else reclaims it"
        )

      other ->
        other
    end
  end

  # Kills the runner after `n` committed batches, at a batch boundary, by
  # watching the telemetry the task emits. There is no fault point in the
  # existing harness that reaches a Mix-task-shaped worker, and editing the
  # checkpoint to what a crash "would have" left is the assumption under test.
  defp kill_after_batches(repo, n, opts) do
    handler = "backfill-kill-#{System.unique_integer([:positive])}"

    # spawn_monitor, not Task.async: a linked task that is killed takes the
    # test process and the disposable repo down with it, and then the test
    # proves nothing except that `kill` works.
    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        Backfill.run(Keyword.put(opts, :repo, repo))
      end)

    :telemetry.attach(
      handler,
      [:aurora_meter, :events, :backfill, :batch],
      fn _event, measure, _meta, _config ->
        if measure.batches >= n, do: Process.exit(pid, :kill)
      end,
      nil
    )

    send(pid, :go)

    result =
      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :killed
        {:DOWN, ^ref, :process, ^pid, reason} -> {:exited, reason}
      after
        30_000 -> :timeout
      end

    :telemetry.detach(handler)
    result
  end
end
