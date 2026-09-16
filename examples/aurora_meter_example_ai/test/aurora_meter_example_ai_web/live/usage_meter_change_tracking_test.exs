defmodule AuroraMeterExampleAiWeb.UsageMeterChangeTrackingTest do
  @moduledoc """
  Why `AuroraMeterExampleAiWeb.GenerateLive` passes `data-usage={@usage_version}`
  into `AuroraMeter.Components.usage_meter/1`, and what happens when it does not.

  `usage_meter/1` calls `AuroraMeter.quota/2` **inside itself**, from the tenant
  it was given, so its output depends on data that is not in its assigns.
  LiveView's change tracking does not re-render a function component whose
  assigns did not change, so a socket that is correctly subscribed, is receiving
  the usage broadcast, and is re-rendering can still show a stale meter.

  Both LiveViews below subscribe to the same tenant, receive the same broadcast
  and re-render: `#tick` moves in both. Only the one whose meter invocation
  carries a changing attribute shows the new figure.

  This is a finding against the library rather than something the sample can
  fix, and it is recorded here so that a reader who copies the component
  without the extra attribute finds out from a failing test rather than from a
  customer.
  """
  use AuroraMeterExampleAiWeb.ConnCase, async: false
  use AuroraMeter.Test, reset: true

  import Phoenix.LiveViewTest

  alias AuroraMeterExampleAi.MeterProbeLive
  alias AuroraMeterExampleAi.SampleFixtures

  setup do
    org = SampleFixtures.org_fixture()
    %{org: org, session: %{"org_id" => org.id}}
  end

  test "the meter does not re-read the counter when nothing in its invocation changed",
       %{conn: conn, org: org, session: session} do
    {:ok, view, html} = live_isolated(conn, MeterProbeLive.Stale, session: session)
    assert html =~ "0 / 200"
    assert meter_value(render(view)) == "0 / 200"

    AuroraMeter.track(org, :images, 3)
    AuroraMeter.Test.broadcast!()

    after_ = render(view)

    # The socket received the broadcast and re-rendered: the tick moved.
    assert tick(after_) == "1",
           "the LiveView never received the broadcast, so this test is measuring nothing"

    # And the meter did not.
    assert meter_value(after_) == "0 / 200",
           "the meter updated without a changing assign, so the finding this file records is wrong"

    assert AuroraMeter.usage(org, :images) == 3
  end

  test "it does when one attribute of the invocation changes", %{
    conn: conn,
    org: org,
    session: session
  } do
    {:ok, view, _html} = live_isolated(conn, MeterProbeLive.Fresh, session: session)
    assert meter_value(render(view)) == "0 / 200"

    AuroraMeter.track(org, :images, 3)
    AuroraMeter.Test.broadcast!()

    after_ = render(view)
    assert tick(after_) == "1"
    assert meter_value(after_) == "3 / 200"
  end

  defp meter_value(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".aurora-meter__value")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp tick(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#tick")
    |> LazyHTML.text()
    |> String.trim()
  end
end
