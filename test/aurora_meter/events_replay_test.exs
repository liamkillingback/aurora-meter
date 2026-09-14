defmodule AuroraMeter.EventsReplayTest.BlockingOutbox do
  @moduledoc """
  An `AuroraMeter.Events.Outbox` that stops inside the record transaction.

  `enqueue/2` is step 5 of the record transaction, which is after step 1 took
  `FOR SHARE` on the `events_projection` row and after step 2 inserted the
  event. A record parked here is therefore exactly "an in-flight record
  transaction holding the share lock", which is the thing the announcement has
  to wait for.

  The rendezvous is `AuroraMeter.Test.Faults`, so a lost release raises at the
  rendezvous rather than failing somewhere unrelated five seconds later.
  """

  @behaviour AuroraMeter.Events.Outbox

  alias AuroraMeter.Events.Outbox
  alias AuroraMeter.Test.Faults

  @impl Outbox
  @spec enqueue([Outbox.item()], Outbox.context()) :: :ok
  def enqueue(_items, _context) do
    Faults.check(:before_commit, %{callback: :outbox})
    :ok
  end
end

defmodule AuroraMeter.EventsReplayTest do
  @moduledoc """
  Build unit 03d: rebuilding `aurora_meter_event_totals` into an isolated
  generation while the system keeps recording.

  Not `AuroraMeter.DataCase`. The whole subject is interleaving: an
  announcement that waits for an in-flight record, a scan that runs beside
  concurrent writers, an activation a reader must not see half of. The sandbox
  wraps a test in one transaction on one connection, which serialises exactly
  the contention being tested, so every assertion here runs on independent
  connections through `AuroraMeter.Test.Connections` and is made against the
  database rather than against a return value.

  `async: false` and a projection reset in `setup`, not only in `on_exit`: the
  `events_projection` checkpoint row is one row for the whole installation, and
  an interruption test cannot guarantee its own teardown by construction
  (`open-findings.md` X109).
  """
  use ExUnit.Case, async: false

  # The `## Examples` on `status/0`, `prune/1`, `checkpoint_name/1` and
  # `claim_name/0` are claims, and a claim nothing runs is a claim that rots.
  # They run here because this is the only module with the non-sandbox
  # connection two of them need.
  doctest AuroraMeter.Events.Replay

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Counter
  alias AuroraMeter.Events
  alias AuroraMeter.Events.Replay
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.RecordingOutbox
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :fault

  @period ~U[2026-09-01 00:00:00Z]
  @at ~U[2026-09-10 12:00:00.000000Z]

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    Connections.reset_projection!()
    tenant = AuroraMeter.Test.unique_tenant("replay")

    on_exit(fn ->
      Connections.cleanup!(tenant)
      Connections.reset_projection!()
    end)

    %{tenant: tenant, period: @period, at: @at}
  end

  # -- the substrate ---------------------------------------------------------

  defp repo, do: Connections.repo()

  defp record!(tenant, id, quantity, opts \\ []) do
    {:ok, event, outcome} =
      AuroraMeter.record(tenant, Keyword.get(opts, :feature, :ai_generations), quantity,
        id: id,
        occurred_at: Keyword.get(opts, :occurred_at, @at)
      )

    {event, outcome}
  end

  defp totals(tenant, generation) do
    repo().all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant and t.generation == ^generation,
        order_by: [asc: t.feature, asc: t.period_start],
        select: %{
          feature: t.feature,
          period_start: t.period_start,
          quantity: t.quantity,
          events: t.events
        }
      )
    )
  end

  defp max_seq do
    %{rows: [[seq]]} = repo().query!("SELECT coalesce(max(seq), 0) FROM aurora_meter_events", [])
    seq
  end

  defp projection_watermark, do: projection_cursor()["watermark"]

  defp projection_cursor do
    %{cursor: cursor} = Checkpoints.get("events_projection", repo: repo())
    cursor
  end

  # The aggregate an operator would compute by hand, straight from the events,
  # with no projection involved. Every "the rebuild is right" assertion is made
  # against this rather than against the live totals, so a shared bug in both
  # cannot pass.
  defp aggregate(tenant) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT feature, period_start,
               sum(CASE WHEN kind = 'correction' THEN -quantity ELSE quantity END)::bigint,
               count(*)::bigint
          FROM aurora_meter_events
         WHERE tenant_key = $1 AND period_start IS NOT NULL
           AND attribution <> 'legacy_track'
           AND event_id NOT LIKE 'legacy:%' AND event_id NOT LIKE 'track:%'
         GROUP BY feature, period_start
         ORDER BY feature, period_start
        """,
        [tenant]
      )

    Enum.map(rows, fn [feature, period, quantity, events] ->
      %{
        feature: feature,
        period_start: DateTime.from_naive!(period, "Etc/UTC"),
        quantity: quantity,
        events: events
      }
    end)
  end

  # -- phase 1: the announcement --------------------------------------------

  describe "the announcement" do
    test "the watermark is at least the maximum committed seq", ctx do
      record!(ctx.tenant, "a", 5)
      record!(ctx.tenant, "b", 7)
      before = max_seq()

      assert {:ok, announced} = Storage.begin_projection_generation()

      assert announced.generation == 1
      assert announced.active_generation == 0
      assert announced.seed_generation == -1
      assert announced.watermark >= before
      refute announced.resumed

      assert projection_cursor()["building_generation"] == 1
      assert projection_cursor()["watermark"] == announced.watermark
      assert projection_cursor()["seed_generation"] == -1
    end

    test "the announcement seeds the building generation from the active one", ctx do
      record!(ctx.tenant, "a", 5)
      record!(ctx.tenant, "b", 7)

      assert {:ok, _announced} = Storage.begin_projection_generation()

      # The seed is what keeps a concurrent correction off the check
      # constraint: the building generation is never below the active one plus
      # what the scan has added, and the scan has added nothing yet.
      assert totals(ctx.tenant, 1) == totals(ctx.tenant, 0)
      assert totals(ctx.tenant, -1) == totals(ctx.tenant, 0)
    end

    test "a second announcement resumes the first rather than starting a third", ctx do
      record!(ctx.tenant, "a", 5)
      assert {:ok, first} = Storage.begin_projection_generation()
      assert {:ok, second} = Storage.begin_projection_generation()

      assert second.generation == first.generation
      assert second.watermark == first.watermark
      assert second.seeded == 0
      assert second.resumed
    end

    test "I06 the announcement waits for an in-flight record transaction", ctx do
      reference = make_ref()
      Faults.arm(:before_commit, {:block_until, reference}, owner: self(), count: 1)

      parent = self()

      {:ok, supervisor} = Task.Supervisor.start_link()

      recorder =
        Task.Supervisor.async(supervisor, fn ->
          TestConfig.with_config(
            [{:aurora_meter, :events_outbox, AuroraMeter.EventsReplayTest.BlockingOutbox}],
            fn ->
              AuroraMeter.record(ctx.tenant, :ai_generations, 42, id: "held", occurred_at: @at)
            end
          )
        end)

      # The recorder is parked inside its transaction, holding FOR SHARE on the
      # projection row and having already inserted its event.
      assert_receive {:aurora_fault_blocked, :before_commit, blocked, ^reference}, 5_000

      announcer =
        Task.Supervisor.async(supervisor, fn ->
          own = Connections.checkout!()

          try do
            send(parent, {:announcing, self()})
            result = Storage.begin_projection_generation()
            send(parent, {:announced, System.monotonic_time(:millisecond)})
            result
          after
            if own, do: Sandbox.checkin(Connections.repo())
          end
        end)

      assert_receive {:announcing, _pid}, 5_000

      # It cannot have finished: the exclusive lock is behind the recorder's
      # share lock. A negative assertion needs a window, and 300 ms is far
      # longer than the announcement takes when it is not blocked (measured at
      # single-digit milliseconds in the tests above).
      refute_receive {:announced, _at}, 300

      send(blocked, {:aurora_fault_release, reference})
      assert {:ok, _event, :inserted} = Task.await(recorder, 10_000)
      assert {:ok, announced} = Task.await(announcer, 10_000)

      # And the event the held transaction committed is under the watermark, so
      # the scan will see it.
      %{rows: [[seq]]} =
        repo().query!(
          "SELECT seq FROM aurora_meter_events WHERE tenant_key = $1 AND event_id = $2",
          [ctx.tenant, "held"]
        )

      assert seq <= announced.watermark

      Supervisor.stop(supervisor)
    end
  end

  # -- phase 2: the scan -----------------------------------------------------

  describe "the scan" do
    test "I06 a rebuilt generation reproduces the live totals for usage events", ctx do
      record!(ctx.tenant, "a", 5)
      record!(ctx.tenant, "b", 7)
      record!(ctx.tenant, "c", 11)

      assert {:ok, report} = Replay.run(batch_size: 2, activate: false)

      assert report.generation == 1
      assert report.differences == 0
      refute report.activated
      assert totals(ctx.tenant, 1) == aggregate_as_totals(ctx.tenant)
    end

    test "I09 a correction contributes a negative quantity and a positive event count", ctx do
      {event, :inserted} = record!(ctx.tenant, "a", 10)

      assert {:ok, _correction, :inserted} =
               AuroraMeter.correct(ctx.tenant, event.event_id, 4, id: "a-fix")

      assert [%{quantity: 6, events: 2}] = totals(ctx.tenant, 0)

      assert {:ok, report} = Replay.run(activate: false)
      assert report.differences == 0
      assert [%{quantity: 6, events: 2}] = totals(ctx.tenant, 1)
    end

    test "I06 the scan is bounded by the watermark and the tail arrives by the dual write", ctx do
      record!(ctx.tenant, "a", 5)
      record!(ctx.tenant, "b", 7)

      assert {:ok, announced} = Storage.begin_projection_generation()

      # Ten records after the announcement. Each writes both generations and
      # each is above the watermark, so the scan must not read one of them.
      for i <- 1..10, do: record!(ctx.tenant, "tail-#{i}", 1)

      batches = attach_batches()
      assert {:ok, report} = Replay.run(activate: false)

      %{rows: [[under]]} =
        repo().query!("SELECT count(*) FROM aurora_meter_events WHERE seq <= $1", [
          announced.watermark
        ])

      assert report.scanned == under
      assert Enum.sum(Enum.map(batches.(), & &1.scanned)) == under

      # 5 + 7 from the scan, ten 1s from the dual write, and the seed taken
      # back out, which is the whole of the arithmetic.
      assert [%{quantity: 22, events: 12}] = totals(ctx.tenant, 1)
      assert totals(ctx.tenant, 1) == totals(ctx.tenant, 0)
    end

    test "the scan resumes at its cursor after a bounded window", ctx do
      for i <- 1..6, do: record!(ctx.tenant, "e-#{i}", 1)

      assert {:ok, first} = Replay.run(batch_size: 2, max_batches: 1, activate: false)
      assert first.scanned == 2
      refute first.activated

      assert {:ok, second} = Replay.run(batch_size: 2, activate: false)

      # The counts describe THIS run; the cursor is what carries across. The
      # bound is the whole table rather than this tenant's six rows, because
      # `scanned` counts every event under the watermark and the suite leaves
      # other tenants' rows committed.
      %{rows: [[under]]} =
        repo().query!("SELECT count(*) FROM aurora_meter_events WHERE seq <= $1", [
          projection_watermark()
        ])

      assert first.scanned + second.scanned == under
      assert second.differences == 0
      assert [%{quantity: 6, events: 6}] = totals(ctx.tenant, 1)
    end

    test "a legacy track row is in the events table and in no rebuilt total", ctx do
      record!(ctx.tenant, "a", 5)

      :ok =
        Storage.insert_events([
          %{
            tenant_key: ctx.tenant,
            feature: :ai_generations,
            quantity: 99,
            metadata: %{},
            period_start: @period,
            period_source: "test"
          }
        ])

      assert {:ok, report} = Replay.run(activate: false)

      assert report.scanned > report.projected
      assert report.differences == 0
      assert [%{quantity: 5, events: 1}] = totals(ctx.tenant, 1)
    end
  end

  # -- the correction hazard the seed exists for -----------------------------

  describe "a correction while a generation is building" do
    test "I09 a correction for an unscanned original commits and lands in both generations",
         ctx do
      {event, :inserted} = record!(ctx.tenant, "a", 10)

      # Announced, so the building generation exists and every write goes to
      # both; NOT scanned, so without the seed the building generation's row
      # for this key would be at zero and a negative delta would be refused by
      # `aurora_meter_event_totals_quantity_check`.
      assert {:ok, _announced} = Storage.begin_projection_generation()

      {result, log} =
        with_log(fn -> AuroraMeter.correct(ctx.tenant, event.event_id, 4, id: "a-fix") end)

      # X125, and this order is the whole point. `record_correction/2`
      # translates a violation of `aurora_meter_event_totals_quantity_check`
      # into `{:error, {:invalid, [quantity: :exceeds_original]}}`, which is
      # the SAME tuple the cumulative bound produces, so asserting on the
      # return value alone cannot tell "the seed held" from "the constraint
      # refused a legal correction". The log names the layer, so it is asserted
      # first and it says so in the message.
      refute log =~ "aurora_meter_event_totals_quantity_check",
             "the totals check constraint refused this correction, which means the building " <>
               "generation's row for the key went below zero. The announcement's seed is what " <>
               "prevents that, and without it a legal correction is refused with a wholly " <>
               "misleading reason. Log:
" <> log

      assert {:ok, _correction, :inserted} = result

      assert [%{quantity: 6, events: 2}] = totals(ctx.tenant, 0)

      assert {:ok, report} = Replay.run(activate: true)
      assert report.differences == 0
      assert Events.count(ctx.tenant, :ai_generations, @period) == %{quantity: 6, events: 2}
    end

    test "L-03d-1 the seed is fully removed, so a built generation is the events and nothing else",
         ctx do
      record!(ctx.tenant, "a", 5)
      record!(ctx.tenant, "b", 7)

      assert {:ok, report} = Replay.run(activate: false)
      assert report.differences == 0

      # No seed row survives the drain, in any tenant.
      assert count("SELECT count(*) FROM aurora_meter_event_totals WHERE generation < 0") == 0
      assert totals(ctx.tenant, 1) == aggregate_as_totals(ctx.tenant)
    end
  end

  # -- phase 3: the comparison ----------------------------------------------

  describe "the comparison" do
    test "I06 require_match refuses to activate when a difference exists", ctx do
      record!(ctx.tenant, "a", 5)
      plant!(ctx.tenant, 1000)

      assert {:error, {:projection_mismatch, summary}} = Replay.run()

      assert summary.generation == 1
      assert summary.differences >= 1
      assert Enum.any?(summary.keys, &(&1.tenant_key == ctx.tenant))
      assert Replay.status().active_generation == 0
      assert Events.total(ctx.tenant, :ai_generations, @period) == 1005
    end

    test "report activates in spite of a difference, and the built generation is the events",
         ctx do
      record!(ctx.tenant, "a", 5)
      plant!(ctx.tenant, 1000)

      assert {:ok, report} = Replay.run(compare: :report)

      assert report.activated
      assert report.differences >= 1
      assert Replay.status().active_generation == 1
      assert Events.total(ctx.tenant, :ai_generations, @period) == 5
    end
  end

  # -- phase 4: activation ---------------------------------------------------

  describe "activation" do
    test "L-03d-3 a reader across an activation sees exactly two values and never a partial sum",
         ctx do
      record!(ctx.tenant, "a", 5)
      plant!(ctx.tenant, 1000)

      parent = self()
      tenant = ctx.tenant
      {:ok, supervisor} = Task.Supervisor.start_link()

      reader =
        Task.Supervisor.async(supervisor, fn ->
          own = Connections.checkout!()

          try do
            send(parent, :reading)
            read_until(tenant, [])
          after
            if own, do: Sandbox.checkin(Connections.repo())
          end
        end)

      assert_receive :reading, 5_000
      assert {:ok, report} = Replay.run(compare: :report, rehydrate: false)
      assert report.activated

      send(reader.pid, :stop)
      observed = Task.await(reader, 10_000)
      distinct = Enum.uniq(observed)

      assert distinct -- [1005, 5] == [],
             "a reader observed #{inspect(distinct)}, which contains a value that is neither " <>
               "the old total nor the new one"

      assert 5 in distinct, "the reader never saw the new generation"
      assert 1005 in distinct, "the reader never saw the old generation"

      write_atomicity_evidence!(observed, distinct)
      Supervisor.stop(supervisor)
    end

    test "L-03d-4 the previous generation survives activation and can be reactivated", ctx do
      record!(ctx.tenant, "a", 5)
      plant!(ctx.tenant, 1000)

      assert {:ok, report} = Replay.run(compare: :report)
      assert report.activated
      assert Events.total(ctx.tenant, :ai_generations, @period) == 5

      status = Replay.status()
      assert status.active_generation == 1
      assert status.previous_generation == 0

      # Nothing is rebuilt to go back: the rows were never deleted.
      assert :ok = Storage.activate_projection(status.previous_generation)
      assert Events.total(ctx.tenant, :ai_generations, @period) == 1005
    end

    test "activation re-seats a warm events-source counter", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :feature_sources, %{ai_generations: :events}}],
        fn ->
          record!(ctx.tenant, "a", 5)
          plant!(ctx.tenant, 1000)

          # Warm the key from the live generation.
          assert Counter.value(ctx.tenant, :ai_generations, @period) == 1005

          assert {:ok, report} = Replay.run(compare: :report)
          assert report.activated
          assert Counter.value(ctx.tenant, :ai_generations, @period) == 5
        end
      )
    end
  end

  # -- pause, claim and prune ------------------------------------------------

  describe "pause and resume" do
    test "a paused replay stops within one batch and resumes at its cursor", ctx do
      for i <- 1..6, do: record!(ctx.tenant, "e-#{i}", 1)

      assert {:ok, first} = Replay.run(batch_size: 2, max_batches: 1, activate: false)
      assert first.scanned == 2

      name = Replay.checkpoint_name(1)
      before = Checkpoints.get(name, repo: repo()).cursor["seq"]

      :ok = Checkpoints.pause(name, repo: repo())
      assert {:ok, :paused, status} = Replay.run(batch_size: 2, activate: false)
      assert status.building_generation == 1
      assert status.replay.state == "paused"

      # The cursor is untouched by the pause, which is what makes a resume free.
      assert Checkpoints.get(name, repo: repo()).cursor["seq"] == before

      :ok = Checkpoints.resume(name, repo: repo())
      assert {:ok, report} = Replay.run(batch_size: 2, activate: false)
      assert report.differences == 0
      assert totals(ctx.tenant, 1) == aggregate_as_totals(ctx.tenant)
    end
  end

  describe "the claim" do
    test "a second replay is refused while the first holds the claim, and runs once it does not",
         ctx do
      record!(ctx.tenant, "a", 5)

      parent = self()
      {:ok, supervisor} = Task.Supervisor.start_link()

      holder =
        Task.Supervisor.async(supervisor, fn ->
          own = Connections.checkout!()

          try do
            Checkpoints.claim(
              Replay.claim_name(),
              fn ->
                send(parent, :held)

                receive do
                  :release -> :ok
                after
                  10_000 -> :timeout
                end
              end,
              repo: repo()
            )
          after
            if own, do: Sandbox.checkin(Connections.repo())
          end
        end)

      assert_receive :held, 5_000

      # No clock anywhere in this decision: the lock is held or it is not.
      assert {:error, {:already_running, status}} = Replay.run()
      assert status.active_generation == 0

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 10_000)

      assert {:ok, report} = Replay.run()
      assert report.activated

      Supervisor.stop(supervisor)
    end
  end

  describe "prune/1" do
    test "prune/1 refuses the active generation and deletes a retired one", ctx do
      record!(ctx.tenant, "a", 5)

      assert {:ok, report} = Replay.run()
      assert report.activated
      assert Replay.status().active_generation == 1

      assert Replay.prune(1) == {:error, :active}
      assert Replay.prune(7) == {:error, :not_found}

      before = count("SELECT count(*) FROM aurora_meter_event_totals WHERE generation = 0")
      assert before > 0
      assert {:ok, ^before} = Replay.prune(0)
      assert count("SELECT count(*) FROM aurora_meter_event_totals WHERE generation = 0") == 0
    end

    test "prune/1 abandons a half-built generation and clears it from the projection state",
         ctx do
      for i <- 1..6, do: record!(ctx.tenant, "e-#{i}", 1)
      assert {:ok, _first} = Replay.run(batch_size: 2, max_batches: 1, activate: false)

      assert Replay.status().building_generation == 1
      assert {:ok, deleted} = Replay.prune(1)
      assert deleted > 0

      status = Replay.status()
      assert status.building_generation == nil
      assert status.seed_generation == nil
      assert status.watermark == nil
      assert count("SELECT count(*) FROM aurora_meter_event_totals WHERE generation <> 0") == 0

      # A fresh build starts again from nothing and is still right.
      assert {:ok, report} = Replay.run()
      assert report.generation == 1
      assert report.differences == 0
    end
  end

  # -- I08: a replay is silent ----------------------------------------------

  describe "side effects" do
    test "I08 a replay enqueues nothing, grants nothing, notifies nothing and flushes nothing",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :events_outbox, RecordingOutbox},
          {:aurora_meter, :feature_sources, %{ai_generations: :events}}
        ],
        fn ->
          record!(ctx.tenant, "a", 5)
          record!(ctx.tenant, "b", 7)
          RecordingOutbox.reset!()

          Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(ctx.tenant))

          id = "replay-silence-#{System.unique_integer([:positive])}"
          owner = self()

          :telemetry.attach_many(
            id,
            [
              [:aurora_meter, :flush],
              [:aurora_meter, :flush, :error],
              [:aurora_meter, :credits, :grant],
              [:aurora_meter, :record, :stop]
            ],
            fn event, _measurements, _metadata, _config ->
              send(owner, {:forbidden_telemetry, event})
            end,
            nil
          )

          on_exit(fn -> :telemetry.detach(id) end)
          :ets.delete_all_objects(Store.dirty_table())

          assert {:ok, report} = Replay.run()
          assert report.activated

          assert RecordingOutbox.items() == []
          assert RecordingOutbox.calls() == 0
          refute_received {:forbidden_telemetry, _event}
          refute_received {:aurora_meter, :usage, _payload}
          refute_received {:aurora_meter, :event, _payload}
          assert Store.snapshot_flush_batch() == nil
          assert :ets.info(Store.dirty_table(), :size) == 0

          # The only rows a replay writes are totals and checkpoints: no new
          # event, and no counter row for an events-source feature.
          assert Storage.load_counter(ctx.tenant, :ai_generations, @period) == nil
        end
      )
    end
  end

  # -- status ----------------------------------------------------------------

  describe "status/0" do
    test "status/0 reports the generations, the watermark and the replay checkpoint", ctx do
      record!(ctx.tenant, "a", 5)

      assert Replay.status() == %{
               active_generation: 0,
               building_generation: nil,
               previous_generation: nil,
               seed_generation: nil,
               watermark: nil,
               replay: nil
             }

      assert {:ok, _first} = Replay.run(batch_size: 1, max_batches: 1, activate: false)

      building = Replay.status()
      assert building.building_generation == 1
      assert building.seed_generation == -1
      assert is_integer(building.watermark)
      assert building.replay.state == "running"
      assert is_binary(building.replay.cursor["heartbeat_at"])
      assert building.replay.cursor["runner"] =~ "#PID"

      assert {:ok, report} = Replay.run()
      assert report.activated

      done = Replay.status()
      assert done.active_generation == 1
      assert done.previous_generation == 0
      assert done.building_generation == nil
      assert done.watermark == nil
      assert done.replay == nil
    end
  end

  # -- the kill, which is the whole of resumability --------------------------

  test "I06 restart and replay reproduce the same totals", ctx do
    for i <- 1..8, do: record!(ctx.tenant, "e-#{i}", i)
    {event, :inserted} = record!(ctx.tenant, "fix-me", 20)
    assert {:ok, _c, :inserted} = AuroraMeter.correct(ctx.tenant, event.event_id, 6, id: "fix")

    live = totals(ctx.tenant, 0)

    # Killed in the middle of a batch, on a supervised task, with a real
    # untrappable :kill. The batch's transaction rolls back with the connection
    # and the cursor names the last batch that really committed.
    # Two batches committed, so there is real progress for the kill to land
    # after, and the built generation holds part of the history.
    assert {:ok, first} = Replay.run(batch_size: 2, max_batches: 2, activate: false)
    assert first.batches == 2
    committed = Checkpoints.get(Replay.checkpoint_name(1), repo: repo()).cursor["seq"]
    assert committed > 0
    partial = totals(ctx.tenant, 1)

    # Then a real, untrappable kill inside the very next batch's transaction.
    TestConfig.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      assert {:killed, _pid} =
               Kill.run(
                 fn ->
                   Connections.checkout!()
                   Replay.run(batch_size: 2, activate: false)
                 end,
                 at: :before_commit,
                 when: fn context -> context[:callback] == :write_projection_totals end
               )
    end)

    # After a kill the only trustworthy state is what the database says: the
    # worker's connection went back to the pool and Postgres rolled its
    # transaction back. The cursor still names the last batch that really
    # committed, and the totals are exactly what that batch left, because the
    # totals write and the cursor advance are ONE transaction.
    Kill.assert_db!(fn ->
      assert Checkpoints.get(Replay.checkpoint_name(1), repo: repo()).cursor["seq"] == committed
      assert totals(ctx.tenant, 1) == partial
    end)

    assert {:ok, report} =
             Kill.assert_db!(fn -> run_once_the_claim_is_free(batch_size: 2, activate: false) end)

    assert report.differences == 0
    assert totals(ctx.tenant, 1) == live
    assert totals(ctx.tenant, 1) == aggregate_as_totals(ctx.tenant)
  end

  # -- helpers used above ----------------------------------------------------

  defp plant!(tenant, quantity) do
    :ok =
      Storage.write_projection_totals(0, [
        %{
          tenant_key: tenant,
          feature: "ai_generations",
          period_start: @period,
          quantity: quantity,
          events: 0
        }
      ])
  end

  # A killed runner releases its claim by its CONNECTION dying, which is the
  # whole point of a session advisory lock (there is no lease and no clock in
  # it). The death is not instantaneous, though: DBConnection notices the client
  # exit, disconnects the connection, and Postgres releases the lock when that
  # backend goes away. A re-run in the same millisecond can still be told
  # `:already_running`, which is the safe direction to be wrong in (it refuses,
  # it never admits a second runner) and which an operator retries.
  #
  # Bounded, and it reports what it saw rather than hanging.
  defp run_once_the_claim_is_free(opts, attempts \\ 200) do
    case Replay.run(opts) do
      {:error, {:already_running, _status}} when attempts > 0 ->
        Process.sleep(5)
        run_once_the_claim_is_free(opts, attempts - 1)

      {:error, {:already_running, status}} ->
        flunk("the claim was still held 1s after the runner was killed: #{inspect(status)}")

      other ->
        other
    end
  end

  defp count(sql) do
    %{rows: [[n]]} = repo().query!(sql, [])
    n
  end

  defp read_until(tenant, acc) do
    acc = [Events.total(tenant, :ai_generations, @period) | acc]

    receive do
      :stop -> Enum.reverse(acc)
    after
      0 -> read_until(tenant, acc)
    end
  end

  # Records only when asked (open-findings.md X135, X149). This wrote on every
  # run until 2026-09-15, so an ordinary `mix test` rewrote a committed evidence
  # file with different numbers each time, the gate stopped leaving the tree byte
  # identical, and a reviewer could not tell which run produced the committed
  # file. It escaped the first sweep of X135 because it names the path inline
  # rather than through the `@evidence` attribute the other writers use, which is
  # why `evidence_writes_test.exs` now checks this by parsing rather than by
  # grepping for a constant.
  #
  # The assertions in the test above run every time regardless.
  defp write_atomicity_evidence!(observed, distinct) do
    if System.get_env("AURORA_EVIDENCE") != "1" do
      :skipped
    else
    File.mkdir_p!("docs/evidence/v1/phase-03")

    File.write!("docs/evidence/v1/phase-03/03d-activation-atomicity.txt", """
    L-03d-3: AuroraMeter.Events.total/3, read in a tight loop on an independent
    non-sandbox connection, across one activation.

    Test: AuroraMeter.EventsReplayTest / test activation L-03d-3 a reader across
    an activation sees exactly two values and never a partial sum

    old active generation (0) total: 1005  (5 recorded, 1000 planted on the row)
    new active generation (1) total: 5     (the rebuild, which is the events)

    reads: #{length(observed)}
    distinct values, in the order first seen: #{inspect(distinct)}

    Every read is one of the two. A partial sum is any other number, and the
    assertion `distinct -- [1005, 5] == []` is what refuses one.
    """)
    end
  end

  defp aggregate_as_totals(tenant) do
    Enum.map(aggregate(tenant), fn row ->
      %{
        feature: row.feature,
        period_start: row.period_start,
        quantity: row.quantity,
        events: row.events
      }
    end)
  end

  defp attach_batches do
    owner = self()
    id = "replay-batches-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:aurora_meter, :replay, :batch],
      fn _event, measurements, metadata, _config ->
        send(owner, {:replay_batch, Map.merge(measurements, metadata)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)

    fn -> drain_batches([]) end
  end

  defp drain_batches(acc) do
    receive do
      {:replay_batch, batch} -> drain_batches([batch | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
