defmodule AuroraMeter.RealtimeTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  import Phoenix.LiveViewTest

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Components
  alias AuroraMeter.LiveView

  test "usage_meter renders the value and progressbar semantics" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    AuroraMeter.track(tenant, :ai_generations, 10)

    html = render_component(&Components.usage_meter/1, tenant: tenant, feature: :ai_generations)

    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-valuenow="10")
    assert html =~ ~s(aria-valuemax="50")
    assert html =~ "10 / 50"
  end

  test "usage_summary renders a meter for each plan feature" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)

    html = render_component(&Components.usage_summary/1, tenant: tenant)

    assert html =~ "ai_generations"
    assert html =~ "api_access"
  end

  test "the broadcaster fans usage out on the tenant topic" do
    tenant = unique_tenant()
    :ok = LiveView.subscribe(tenant)

    AuroraMeter.track(tenant, :ai_generations, 3)
    :ok = Broadcaster.broadcast_now()

    assert_receive {:aurora_meter, :usage, %{feature: :ai_generations, value: 3}}
  end
end
