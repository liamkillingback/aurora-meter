defmodule AuroraMeter.FlusherTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  # This module arms faults (the lost-acknowledgement case below), so it carries
  # the tag that puts it in `mix v1.faults`. The tag is NOT excluded in
  # test/test_helper.exs, so the module also runs inside the ordinary `mix test`.
  @moduletag :fault

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Flusher
  alias AuroraMeter.LiveView
  alias AuroraMeter.Period
  alias AuroraMeter.Retention
  alias AuroraMeter.Storage
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage

  test "I01 a commit whose response was lost, then a foreign writer, cannot apply a delta twice" do
    {:ok, _} = Flusher.flush()
    tenant = unique_tenant()

    # Flusher.flush/0 is a GenServer.call, so the storage callback runs in the
    # Flusher process, which carries no $callers back to this test. The fault
    # names that pid as its owner, and the assertions below name it too.
    flusher = Process.whereis(Flusher)
    :ok = Faults.forget(owner: flusher)

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      # The AmbiguousStorage script, now a fault: the batch commits, a second
      # writer applies its own delta of 3 to the same counter, and only then
      # does the caller learn that anything went wrong. The scripted write sits
      # in the :when guard, which runs exactly once per check in the flushing
      # process.
      Faults.arm(:after_commit_before_ack, :raise,
        owner: flusher,
        count: 1,
        label: :foreign_write_then_raise,
        when: fn context ->
          if context[:callback] == :flush_batch do
            {:ok, _} =
              Storage.Ecto.add_counters([
                %{
                  tenant_key: tenant,
                  feature: :ops,
                  period_start: Period.current(tenant).start,
                  delta: 3
                }
              ])

            true
          else
            false
          end
        end
      )

      AuroraMeter.track(tenant, :ops, 5)

      # The id the Flusher is about to send, captured the way it captures it, so
      # the receipt this batch leaves behind can be counted.
      batch = AuroraMeter.Store.snapshot_flush_batch()

      assert {:error, _} = Flusher.flush()
      :ok = Faults.assert_fired!(:after_commit_before_ack, owner: flusher)
      AuroraMeter.track(tenant, :ops, 2)
      assert {:ok, _} = Flusher.flush()
      assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 8
      assert AuroraMeter.Counter.value(tenant, :ops, Period.current(tenant).start) == 10
      assert {:ok, _} = Flusher.flush()
      assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 10

      # One durable effect for the one batch, however many times it was sent.
      assert TestRepo.aggregate(
               from(r in AuroraMeter.Schema.FlushReceipt, where: r.id == ^batch.id),
               :count
             ) == 1
    end)
  end

  test "I01 a batch belongs to Store until acknowledged, while later usage stays pending" do
    {:ok, _} = Flusher.flush()
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 5)
    batch = AuroraMeter.Store.snapshot_flush_batch()
    AuroraMeter.track(tenant, :ops, 2)
    assert AuroraMeter.Store.snapshot_flush_batch() == batch
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 5
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 7
  end

  test "I01 a graceful shutdown persists pending counters" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 6)
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == nil

    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Flusher)
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 6

    {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Flusher)
  end

  test "a flush between a track and the next broadcast does not swallow the live update" do
    tenant = unique_tenant()
    :ok = LiveView.subscribe(tenant)

    AuroraMeter.track(tenant, :ops, 2)
    {:ok, _} = Flusher.flush()
    :ok = Broadcaster.broadcast_now()

    assert_receive {:aurora_meter, :usage, %{feature: :ops, value: 2}}
  end

  # -- the flush heartbeat (build unit 05d) -----------------------------------

  test "the batch carries snapshot_at" do
    {:ok, _} = Flusher.flush()
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 5)

    batch = AuroraMeter.Store.snapshot_flush_batch()

    assert %DateTime{} = batch.snapshot_at
    assert DateTime.diff(DateTime.utc_now(), batch.snapshot_at, :second) < 60

    # And it is stable across re-reads of the same pending batch, because the
    # pending entry is returned as it was stored rather than rebuilt.
    assert AuroraMeter.Store.snapshot_flush_batch().snapshot_at == batch.snapshot_at

    {:ok, _} = Flusher.flush()
  end

  test "the Flusher writes an idle heartbeat after a successful persist" do
    clear_heartbeats!()
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 5)

    assert {:ok, persisted} = Flusher.flush()
    assert persisted > 0

    assert %{state: "idle", cursor: cursor} = heartbeat()
    assert cursor["version"] == Retention.package_version()
    refute Map.has_key?(cursor, "pending_since")
  end

  test "the Flusher writes a pending heartbeat naming the batch after a failed persist" do
    clear_heartbeats!()
    tenant = unique_tenant()
    flusher = Process.whereis(Flusher)
    :ok = Faults.forget(owner: flusher)

    Config.with_config([{:aurora_meter, :storage, FaultStorage}], fn ->
      Faults.arm(:before_commit, :raise,
        owner: flusher,
        count: 1,
        label: :heartbeat_pending_case,
        when: fn context -> context[:callback] == :flush_batch end
      )

      AuroraMeter.track(tenant, :ops, 5)
      batch = AuroraMeter.Store.snapshot_flush_batch()

      assert {:error, _reason} = Flusher.flush()

      assert %{state: "pending", cursor: cursor} = heartbeat()
      assert cursor["batch_id"] == batch.id
      assert {:ok, pending_since, _} = DateTime.from_iso8601(cursor["pending_since"])
      assert DateTime.compare(pending_since, batch.snapshot_at) == :eq
    end)

    # And the next successful flush clears it, so a transient failure does not
    # block retention for ever.
    assert {:ok, _} = Flusher.flush()
    assert %{state: "idle"} = heartbeat()
  end

  test "a failing heartbeat write does not fail the flush" do
    clear_heartbeats!()
    tenant = unique_tenant()

    # The heartbeat table, renamed for the duration: every write against it
    # raises `undefined_table`, which is exactly what a database below core
    # schema version 7 does.
    TestRepo.query!("ALTER TABLE aurora_meter_checkpoints RENAME TO aurora_meter_checkpoints_x")

    on_exit(fn -> :ok end)

    AuroraMeter.track(tenant, :ops, 5)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, persisted} = Flusher.flush()
        assert persisted > 0
      end)

    TestRepo.query!("ALTER TABLE aurora_meter_checkpoints_x RENAME TO aurora_meter_checkpoints")

    assert log =~ "could not write its flush heartbeat"

    # The flush itself did everything it was supposed to: the deltas are
    # persisted and the pending batch is gone.
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 5
    assert :ets.lookup(AuroraMeter.Store.flush_batches_table(), :pending) == []
  end

  test "the Flusher writes at most one heartbeat per minute on idle ticks" do
    clear_heartbeats!()

    # Twenty consecutive ticks with nothing to send. The first writes (the
    # process has no heartbeat instant yet in this window); the rest are inside
    # the sixty second throttle.
    for _ <- 1..20, do: assert({:ok, 0} = Flusher.flush())

    first = heartbeat()
    assert first, "an idle node wrote no heartbeat at all, so it would look dead"

    for _ <- 1..20, do: assert({:ok, 0} = Flusher.flush())

    assert heartbeat().updated_at == first.updated_at,
           "an idle tick refreshed the heartbeat inside the throttle window"
  end

  defp heartbeat, do: Checkpoints.get("flush:" <> Retention.node_id())

  defp clear_heartbeats! do
    TestRepo.query!("DELETE FROM aurora_meter_checkpoints WHERE name LIKE 'flush:%'", [])
    # The throttle lives in the Flusher's own state, so a test that wants the
    # next tick to write has to restart it rather than only delete the row.
    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Flusher)
    {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Flusher)
    :ok
  end

  test "a broadcast only reports keys touched since the previous broadcast" do
    tenant = unique_tenant()
    :ok = LiveView.subscribe(tenant)

    AuroraMeter.track(tenant, :ops, 1)
    :ok = Broadcaster.broadcast_now()
    assert_receive {:aurora_meter, :usage, %{feature: :ops, value: 1}}

    :ok = Broadcaster.broadcast_now()
    refute_receive {:aurora_meter, :usage, %{feature: :ops}}, 50
  end
end
