defmodule AuroraMeter.EventsReplayLargeTest do
  @moduledoc """
  Gate G03 bullet 4: a projection replay of at least 100,000 synthetic facts and
  corrections reproduces exact per-tenant, per-feature, per-period totals after
  interruption and restart (build unit 03d).

  Three runs, and each answers a different question:

    * **the kill.** 100,000 events, a real untrappable `:kill` inside a batch
      transaction, a restart, and two sha256 digests that have to be equal.
    * **the interleave.** Twelve independent recorders writing throughout a
      replay, against an aggregate computed straight from the events at the end.
    * **the activation.** A kill on either side of the generation swap, which
      has to leave a state `status/0` can name and a re-run can finish.

  Tagged `:slow` so it can be selected or skipped by hand. It is **not**
  excluded by default, and the build document's instruction to exclude it is
  the one place this unit did not follow it: `test/test_helper.exs` excludes
  exactly one tag, `:headless`, and `AuroraMeter.CiContractTest` asserts that it
  is the only one. A gate bullet that runs only when someone remembers a flag is
  the thing that guard exists to prevent.

  Rows are seeded with `insert_all` and the projection they would have produced
  is computed in SQL, rather than making 100,000 `AuroraMeter.record/4` calls:
  `seq` is still assigned by the database exactly as a real insert assigns it,
  which is the only property the scan depends on.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Events.Replay
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.RecordingOutbox
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :slow
  @moduletag :fault
  @moduletag timeout: 600_000

  @usage 90_000
  @corrections 10_000
  @tenants 50
  @features 5
  @periods 3
  @batch_size 1000
  @chunk 2_000

  @at ~U[2026-09-10 12:00:00.000000Z]
  @evidence "docs/evidence/v1/phase-03"

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    Connections.register_prefix("replaybig")
    Connections.reset_projection!()
    run = System.unique_integer([:positive])

    on_exit(fn ->
      Connections.cleanup!("replaybig")
      Connections.reset_projection!()
    end)

    %{run: run, seed: ExUnit.configuration()[:seed]}
  end

  defp repo, do: Connections.repo()

  # -- seeding ---------------------------------------------------------------

  # The three coordinates are taken from DIFFERENT digits of `i`, not all from
  # `rem(i, n)`: 5 divides 50, so deriving both tenant and feature that way
  # correlates them and 50 x 5 x 3 collapses to 150 keys instead of 750.
  defp tenant(run, i), do: "replaybig_#{run}_#{rem(i, @tenants)}"
  defp feature(i), do: "feature_#{rem(div(i, @tenants), @features)}"

  defp period(i) do
    DateTime.add(
      ~U[2026-07-01 00:00:00Z],
      rem(div(i, @tenants * @features), @periods) * 31,
      :day
    )
  end

  defp quantity(i), do: rem(i, 7) + 1

  # One row, shaped exactly as `record_events/2` writes one: an identity, a
  # payload hash, a resolved attribution and a period. Nothing here is legacy,
  # so every row is one the replay must project.
  defp usage_row(run, i, now) do
    %{
      id: Ecto.UUID.generate(),
      tenant_key: tenant(run, i),
      event_id: "u-#{i}",
      feature: feature(i),
      quantity: quantity(i),
      kind: "usage",
      original_event_id: nil,
      occurred_at: @at,
      inserted_at: now,
      period_start: period(i),
      period_source: "AuroraMeter.EventsReplayLargeTest",
      dimensions: %{},
      metadata: %{},
      attribution: "resolved",
      payload_hash: :crypto.hash(:sha256, "u-#{i}")
    }
  end

  # Each correction names a DISTINCT original and takes one unit off it, so the
  # cumulative bound I09 enforces is satisfied by construction and the seeded
  # projection is the one the live path would have produced.
  defp correction_row(run, i, now) do
    original = i * 9

    %{
      id: Ecto.UUID.generate(),
      tenant_key: tenant(run, original),
      event_id: "c-#{i}",
      feature: feature(original),
      quantity: 1,
      kind: "correction",
      original_event_id: "u-#{original}",
      occurred_at: @at,
      inserted_at: now,
      period_start: period(original),
      period_source: "AuroraMeter.EventsReplayLargeTest",
      dimensions: %{},
      metadata: %{},
      attribution: "resolved",
      payload_hash: :crypto.hash(:sha256, "c-#{i}")
    }
  end

  defp seed_events!(run, usage \\ @usage, corrections \\ @corrections) do
    now = DateTime.truncate(@at, :microsecond)

    # Usage first, so every original has a lower `seq` than its correction, as
    # the live path guarantees. That is what keeps the scan's running sum for a
    # key non-negative at every batch boundary.
    1..usage
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      repo().insert_all(Event, Enum.map(chunk, &usage_row(run, &1, now)))
    end)

    1..corrections
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      repo().insert_all(Event, Enum.map(chunk, &correction_row(run, &1, now)))
    end)

    :ok
  end

  # The projection those events would have left behind, written the way the
  # record transaction writes it: one row per key in the active generation.
  defp seed_projection!(run) do
    %{num_rows: rows} =
      repo().query!(
        """
        INSERT INTO aurora_meter_event_totals
          (id, tenant_key, feature, period_start, generation, quantity, events,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), tenant_key, feature, period_start, 0,
               sum(CASE WHEN kind = 'correction' THEN -quantity ELSE quantity END),
               count(*),
               (clock_timestamp() AT TIME ZONE 'UTC'), (clock_timestamp() AT TIME ZONE 'UTC')
          FROM aurora_meter_events
         WHERE tenant_key LIKE $1
         GROUP BY tenant_key, feature, period_start
        """,
        ["replaybig_#{run}_%"]
      )

    rows
  end

  # -- reading ---------------------------------------------------------------

  defp totals(run, generation) do
    pattern = "replaybig_#{run}_%"

    %{rows: rows} =
      repo().query!(
        """
        SELECT tenant_key, feature, period_start, quantity, events
          FROM aurora_meter_event_totals
         WHERE generation = $1 AND tenant_key LIKE $2
         ORDER BY tenant_key, feature, period_start
        """,
        [generation, pattern]
      )

    Enum.map(rows, fn [tenant, feature, period, quantity, events] ->
      {tenant, feature, NaiveDateTime.to_iso8601(period), quantity, events}
    end)
  end

  # The aggregate an operator would compute by hand: the events, and nothing
  # that has ever been through a projection.
  defp aggregate(run) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT tenant_key, feature, period_start,
               sum(CASE WHEN kind = 'correction' THEN -quantity ELSE quantity END)::bigint,
               count(*)::bigint
          FROM aurora_meter_events
         WHERE tenant_key LIKE $1
         GROUP BY tenant_key, feature, period_start
         ORDER BY tenant_key, feature, period_start
        """,
        ["replaybig_#{run}_%"]
      )

    Enum.map(rows, fn [tenant, feature, period, quantity, events] ->
      {tenant, feature, NaiveDateTime.to_iso8601(period), quantity, events}
    end)
  end

  defp digest(list) do
    list
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- the gate bullet -------------------------------------------------------

  test "I06 100,000 facts and corrections replay to exact totals after a kill and a restart",
       ctx do
    started = System.monotonic_time(:millisecond)
    :ok = seed_events!(ctx.run)
    keys = seed_projection!(ctx.run)

    assert keys == @tenants * @features * @periods

    live = totals(ctx.run, 0)
    before_digest = digest(live)
    assert live == aggregate(ctx.run)

    # The batch to stop at is derived from the suite seed, so a re-run with a
    # different seed kills somewhere else and the property is not proven at one
    # convenient boundary for ever.
    total_batches = div(@usage + @corrections, @batch_size)
    kill_batch = 1 + rem(ctx.seed, total_batches - 1)

    assert {:ok, first} =
             Replay.run(batch_size: @batch_size, max_batches: kill_batch, activate: false)

    assert first.batches == kill_batch
    committed = Checkpoints.get(Replay.checkpoint_name(1), repo: repo()).cursor["seq"]

    TestConfig.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:killed, _pid} =
               Kill.run(
                 fn ->
                   Connections.checkout!()
                   Replay.run(batch_size: @batch_size, activate: false)
                 end,
                 at: :before_commit,
                 when: fn context -> context[:callback] == :write_projection_totals end
               )
    end)

    # No batch is ever partially applied: the killed batch's transaction rolled
    # back with its connection and the cursor still names the last one that
    # committed.
    Kill.assert_db!(fn ->
      assert Checkpoints.get(Replay.checkpoint_name(1), repo: repo()).cursor["seq"] == committed
    end)

    assert {:ok, second} = Kill.assert_db!(fn -> resume(batch_size: @batch_size) end)

    assert second.activated
    assert second.differences == 0

    rebuilt = totals(ctx.run, 1)
    after_digest = digest(rebuilt)

    assert after_digest == before_digest
    assert rebuilt == live
    assert rebuilt == aggregate(ctx.run)

    # Every event under the watermark was read exactly once, give or take the
    # batch the kill rolled back, which the restart reads again.
    scanned = first.scanned + second.scanned
    assert scanned >= @usage + @corrections
    assert scanned <= @usage + @corrections + @batch_size

    write_json!("03d-replay-100k.json", %{
      events: @usage + @corrections,
      usage: @usage,
      corrections: @corrections,
      tenants: @tenants,
      features: @features,
      periods: @periods,
      keys: keys,
      batch_size: @batch_size,
      seed: ctx.seed,
      kill_batch: kill_batch,
      run1_scanned: first.scanned,
      run2_scanned: second.scanned,
      run1_batches: first.batches,
      run2_batches: second.batches,
      total_scanned: scanned,
      differences: second.differences,
      activated: second.activated,
      duration_ms: System.monotonic_time(:millisecond) - started,
      digest_before: before_digest,
      digest_after: after_digest,
      digests_equal: before_digest == after_digest,
      digest_of:
        "sha256 of :erlang.term_to_binary/1 over the sorted list of " <>
          "{tenant_key, feature, period_start_iso8601, quantity, events} for this run's keys, " <>
          "taken from the active generation before the replay and from the activated " <>
          "generation after it"
    })
  end

  test "I06 a replay interleaved with 12 concurrent recorders reproduces exact totals", ctx do
    # Volume is the other test's subject; this one's is interleaving, so it
    # seeds a tenth of the history and spends the time on the recorders.
    :ok = seed_events!(ctx.run, 9_000, 1_000)
    _keys = seed_projection!(ctx.run)

    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    # Twelve independent connections recording throughout the replay. Each one
    # is a real `AuroraMeter.record/4`, so each takes `FOR SHARE` on the
    # projection row, reads the building generation and writes both.
    recorders =
      for i <- 1..12 do
        Task.Supervisor.async(supervisor, fn ->
          own = Connections.checkout!()

          try do
            send(parent, {:ready, i})
            record_until_stopped(ctx.run, i, 0)
          after
            if own, do: Sandbox.checkin(Connections.repo())
          end
        end)
      end

    for i <- 1..12, do: assert_receive({:ready, ^i}, 10_000)

    assert {:ok, report} = Replay.run(batch_size: @batch_size, compare: :report)
    assert report.activated

    for recorder <- recorders, do: send(recorder.pid, :stop)
    written = Enum.map(recorders, &Task.await(&1, 60_000))

    # The activated generation against an aggregate computed from the events
    # themselves, after every recorder has finished. Nothing here reads the
    # projection twice.
    activated = totals(ctx.run, 1)
    independent = aggregate(ctx.run)

    assert activated == independent

    write_json!("03d-interleaved.json", %{
      seeded_events: 10_000,
      recorders: length(recorders),
      records_committed: Enum.sum(written),
      batch_size: @batch_size,
      scanned: report.scanned,
      batches: report.batches,
      differences: report.differences,
      keys_in_activated_generation: length(activated),
      keys_in_independent_aggregate: length(independent),
      equal: activated == independent,
      activated_generation_digest: digest(activated),
      independent_aggregate_digest: digest(independent),
      computed:
        "the activated generation read from aurora_meter_event_totals, and a GROUP BY over " <>
          "aurora_meter_events taken after every recorder stopped"
    })

    Supervisor.stop(supervisor)
  end

  test "I06 a replay interrupted at the activation leaves a consistent state either way", ctx do
    :ok = seed_events!(ctx.run, 9_000, 1_000)
    _keys = seed_projection!(ctx.run)
    live = totals(ctx.run, 0)

    # Killed BEFORE the swap commits: the built generation is complete and not
    # activated, and a re-run skips the scan, recompares and activates.
    TestConfig.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:killed, _pid} =
               Kill.run(
                 fn ->
                   Connections.checkout!()
                   Replay.run(batch_size: @batch_size)
                 end,
                 at: :before_commit,
                 when: fn context -> context[:callback] == :activate_projection end
               )
    end)

    Kill.assert_db!(fn ->
      status = Replay.status()
      assert status.active_generation == 0
      assert status.building_generation == 1
    end)

    assert {:ok, report} = Kill.assert_db!(fn -> resume(batch_size: @batch_size) end)

    assert report.activated
    # The scan had already finished, so the resumed run reads nothing.
    assert report.scanned == 0
    assert Replay.status().active_generation == 1
    assert totals(ctx.run, 1) == live
  end

  # -- helpers ---------------------------------------------------------------

  # Capped, then idle until the replay says stop. Uncapped, twelve connections
  # in a tight loop write more rows in the replay's window than the seeded
  # history has, which measures the pool rather than the interleaving.
  @records_each 150

  defp record_until_stopped(run, i, written) do
    receive do
      :stop -> written
    after
      0 ->
        if written >= @records_each do
          receive do
            :stop -> written
          after
            30_000 -> written
          end
        else
          case AuroraMeter.record(tenant(run, i), :ai_generations, 1,
                 id: "live-#{i}-#{written}",
                 occurred_at: @at
               ) do
            {:ok, _event, _outcome} -> record_until_stopped(run, i, written + 1)
            {:error, _reason} -> written
          end
        end
    end
  end

  # A killed runner releases its claim by its connection dying, and that is not
  # instantaneous: DBConnection has to notice the client exit and disconnect
  # before Postgres drops the session lock. Refusing is the safe direction to be
  # wrong in, and an operator retries. Bounded, and it says what it saw.
  defp resume(opts, attempts \\ 200) do
    case Replay.run(opts) do
      {:error, {:already_running, _status}} when attempts > 0 ->
        Process.sleep(5)
        resume(opts, attempts - 1)

      {:error, {:already_running, status}} ->
        flunk("the claim was still held 1s after the runner was killed: #{inspect(status)}")

      other ->
        other
    end
  end

  # Evidence is written only when it is asked for. Until 2026-09-15 this wrote
  # on every run, so an ordinary `mix test` rewrote three committed evidence
  # files from phase 03 with different numbers each time (open-findings.md
  # X135). Two things were wrong with that. The gate stopped leaving the tree
  # byte identical, which is the property `--output` was added to protect (X21,
  # X27). And a reviewer could no longer tell whether a committed evidence file
  # came from the run its report cites: it had already misled the orchestrator
  # once, whose verification run silently replaced 03d's digests with its own.
  #
  # The assertions above run every time regardless. This gate only controls
  # whether the run is also recorded, which is 03c's pattern
  # (`feature_source_evidence_test.exs`).
  defp write_json!(name, payload) do
    if System.get_env("AURORA_EVIDENCE") == "1" do
      File.mkdir_p!(@evidence)
      File.write!(Path.join(@evidence, name), Jason.encode_to_iodata!(payload, pretty: true))
    else
      :skipped
    end
  end
end
