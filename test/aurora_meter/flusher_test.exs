defmodule AuroraMeter.FlusherTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Flusher
  alias AuroraMeter.LiveView
  alias AuroraMeter.Period
  alias AuroraMeter.Storage

  test "an ambiguous commit followed by another writer cannot apply its delta twice" do
    {:ok, _} = Flusher.flush()

    start_supervised!(%{
      id: AuroraMeter.AmbiguousStorage,
      start: {Agent, :start_link, [fn -> true end, [name: AuroraMeter.AmbiguousStorage]]}
    })

    previous = Application.get_env(:aurora_meter, :storage)
    Application.put_env(:aurora_meter, :storage, AuroraMeter.AmbiguousStorage)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:aurora_meter, :storage, previous),
        else: Application.delete_env(:aurora_meter, :storage)
    end)

    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 5)
    assert {:error, _} = Flusher.flush()
    AuroraMeter.track(tenant, :ops, 2)
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 8
    assert AuroraMeter.Counter.value(tenant, :ops, Period.current(tenant).start) == 10
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, Period.current(tenant).start) == 10
  end

  test "a batch belongs to Store until acknowledged, while later usage stays pending" do
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

  test "the flusher persists pending counters when it is shut down" do
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
