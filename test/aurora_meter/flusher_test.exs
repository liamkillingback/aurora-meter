defmodule AuroraMeter.FlusherTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Flusher
  alias AuroraMeter.LiveView
  alias AuroraMeter.Period
  alias AuroraMeter.Storage

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

  test "the migration module reports its latest version" do
    assert AuroraMeter.Migration.latest_version() == 4
  end
end
