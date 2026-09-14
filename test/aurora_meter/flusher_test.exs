defmodule AuroraMeter.FlusherTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  # This module arms faults (the lost-acknowledgement case below), so it carries
  # the tag that puts it in `mix v1.faults`. The tag is NOT excluded in
  # test/test_helper.exs, so the module also runs inside the ordinary `mix test`.
  @moduletag :fault

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Flusher
  alias AuroraMeter.LiveView
  alias AuroraMeter.Period
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
