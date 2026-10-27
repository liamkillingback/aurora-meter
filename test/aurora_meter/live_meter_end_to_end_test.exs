# Compiled only when Phoenix.LiveViewTest is available, the same guard the
# other LiveView suites use, so the headless and plug_only legs still compile.
if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule AuroraMeter.LiveMeterEndToEndTest do
    @moduledoc """
    The live meter exactly as the README and `AuroraMeter.Components` document
    it, run through a real endpoint and a real LiveView process.

    1.0.0 shipped a snippet that never moved: `subscribe/1` subscribed the
    process, the broadcast arrived, and `assign_quota/4` dropped it because only
    `on_mount/4` recorded the tenant key. These tests mount the documented
    LiveView, track usage, run one broadcast tick and read the rendered page.
    """
    use AuroraMeter.DataCase, async: false

    import Phoenix.ConnTest, only: [build_conn: 0]
    import Phoenix.LiveViewTest

    alias AuroraMeter.Broadcaster

    @endpoint AuroraMeter.LiveMeterEndToEndTest.Endpoint

    defmodule Endpoint do
      @moduledoc false
      use Phoenix.Endpoint, otp_app: :aurora_meter
    end

    # The README's "Live usage in LiveView" section, verbatim apart from the
    # session lookup, which is the host's own.
    defmodule MeterLive do
      @moduledoc false
      use Phoenix.LiveView

      import AuroraMeter.Components

      def mount(_params, %{"org" => org}, socket) do
        if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)
        {:ok, assign(socket, org: org, quota: AuroraMeter.quota(org, :ai_generations))}
      end

      def handle_info({:aurora_meter, :usage, _payload} = message, socket) do
        {:noreply, AuroraMeter.LiveView.assign_quota(message, socket, :quota, :ai_generations)}
      end

      def render(assigns) do
        ~H"""
        <.usage_meter quota={@quota} />
        """
      end
    end

    # The README's on_mount form: an earlier hook assigns the tenant from the
    # session, and AuroraMeter.LiveView reads it from that assign.
    defmodule CurrentOrg do
      @moduledoc false
      def on_mount(:default, _params, session, socket) do
        {:cont, Phoenix.Component.assign(socket, :current_org, session["org"])}
      end
    end

    defmodule HookedMeterLive do
      @moduledoc false
      use Phoenix.LiveView

      import AuroraMeter.Components

      on_mount({AuroraMeter.LiveMeterEndToEndTest.CurrentOrg, :default})
      on_mount({AuroraMeter.LiveView, {:subscribe, assign: :current_org}})

      def mount(_params, _session, socket) do
        quota = AuroraMeter.quota(socket.assigns.current_org, :ai_generations)
        {:ok, assign(socket, quota: quota)}
      end

      def handle_info({:aurora_meter, :usage, _payload} = message, socket) do
        {:noreply, AuroraMeter.LiveView.assign_quota(message, socket, :quota, :ai_generations)}
      end

      def render(assigns) do
        ~H"""
        <.usage_meter quota={@quota} />
        """
      end
    end

    setup_all do
      Application.put_env(:aurora_meter, Endpoint,
        secret_key_base: String.duplicate("aurora_meter_live_meter_test_", 4),
        live_view: [signing_salt: "aurora_meter_live"],
        pubsub_server: AuroraMeter.Config.pubsub()
      )

      on_exit(fn -> Application.delete_env(:aurora_meter, Endpoint) end)
      :ok
    end

    setup do
      start_supervised!(Endpoint)
      org = unique_tenant("live_meter")
      {:ok, _} = AuroraMeter.subscribe(org, :free)
      %{org: org}
    end

    test "the documented subscribe/1 snippet moves the meter when usage moves", %{org: org} do
      {:ok, view, html} = live_isolated(build_conn(), MeterLive, session: %{"org" => org})
      assert html =~ "0 / 50"

      :ok = AuroraMeter.track(org, :ai_generations, 3)
      :ok = Broadcaster.broadcast_now()

      assert render(view) =~ "3 / 50"
    end

    test "the documented on_mount snippet moves the meter when usage moves", %{org: org} do
      {:ok, view, html} = live_isolated(build_conn(), HookedMeterLive, session: %{"org" => org})
      assert html =~ "0 / 50"

      :ok = AuroraMeter.track(org, :ai_generations, 4)
      :ok = Broadcaster.broadcast_now()

      assert render(view) =~ "4 / 50"
    end

    test "a message for a tenant the LiveView never subscribed to is dropped", %{org: org} do
      other = unique_tenant("live_meter_other")
      {:ok, _} = AuroraMeter.subscribe(other, :free)
      :ok = AuroraMeter.track(other, :ai_generations, 9)

      {:ok, view, _html} = live_isolated(build_conn(), MeterLive, session: %{"org" => org})

      # Delivered straight to the process, as a stale or misrouted message
      # would be: the meter must not show the other tenant's figure.
      send(
        view.pid,
        {:aurora_meter, :usage,
         %{tenant_key: other, feature: :ai_generations, value: 9, period_start: nil}}
      )

      html = render(view)
      assert html =~ "0 / 50"
      refute html =~ "9 / 50"
    end
  end
end
