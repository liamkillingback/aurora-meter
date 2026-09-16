# Runs only where phoenix_live_dashboard is installed. The page is the thin
# adapter; everything it is judged on is in sections_test.exs and view_test.exs,
# which run on every leg.
if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule AuroraMeter.LiveDashboard.PageTest do
    @moduledoc """
    Build unit 08b, invariant I20: the core LiveDashboard page refuses to exist
    until the host has written an authorization decision down, and re-reads that
    decision on every refresh.
    """
    use AuroraMeter.DataCase, async: false

    import ExUnit.CaptureLog
    import Phoenix.LiveViewTest

    alias AuroraMeter.LiveDashboard.Page
    alias AuroraMeter.LiveDashboard.Sections
    alias Phoenix.Component
    alias Phoenix.LiveView.Socket

    test "I20 dashboard page refuses without host auth: init/1 raises ArgumentError when :authorized_by is absent" do
      error = assert_raise ArgumentError, fn -> Page.init([]) end

      assert error.message =~ ":authorized_by"
      assert error.message =~ "{:assign, :key}"
      assert error.message =~ "{Module, :function, args}"
      assert error.message =~ ":host_route"
    end

    test "I20 dashboard page refuses without host auth: an unrecognised form raises and names the three" do
      error = assert_raise ArgumentError, fn -> Page.init(authorized_by: true) end

      assert error.message =~ "AuroraMeter.LiveDashboard.Page"
      assert error.message =~ "Accepted forms"
    end

    test "I20 dashboard page refuses without host auth: a check returning false renders the refusal panel and no section data" do
      {:ok, session} = Page.init(authorized_by: {:assign, :operator?})
      {:ok, socket} = Page.mount(%{}, session, socket_with(operator?: false))

      refute socket.assigns.aurora_allowed?
      assert socket.assigns.aurora_readings == []

      html = rendered_to_string(Page.render(socket.assigns))
      assert html =~ "not authorized"

      document = Floki.parse_fragment!(html)
      assert Floki.find(document, "table") == []
      assert Floki.find(document, "dl") == []
    end

    test "I20 dashboard page refuses without host auth: a check that raises is treated as false and logs a warning" do
      {:ok, session} = Page.init(authorized_by: {__MODULE__, :boom, []})

      log =
        capture_log(fn ->
          {:ok, socket} = Page.mount(%{}, session, socket_with([]))
          refute socket.assigns.aurora_allowed?
          assert socket.assigns.aurora_readings == []
        end)

      assert log =~ "authorization check"
      assert log =~ "boom"
    end

    test "I20 {:assign, key} requires the assign to be exactly true, not truthy" do
      {:ok, session} = Page.init(authorized_by: {:assign, :operator?})

      for truthy <- ["yes", 1, :ok, %{}] do
        {:ok, socket} = Page.mount(%{}, session, socket_with(operator?: truthy))

        refute socket.assigns.aurora_allowed?,
               "#{inspect(truthy)} was accepted as authorization; only true is"
      end

      {:ok, socket} = Page.mount(%{}, session, socket_with(operator?: true))
      assert socket.assigns.aurora_allowed?
    end

    test "I20 the core page accepts :host_route, because it renders no tenant-identifying value" do
      assert {:ok, %{check: :host_route}} = Page.init(authorized_by: :host_route)
    end

    test "the check is re-evaluated on refresh, so a session that loses its marker stops seeing data" do
      {:ok, session} = Page.init(authorized_by: {:assign, :operator?})
      {:ok, socket} = Page.mount(%{}, session, socket_with(operator?: true))

      assert socket.assigns.aurora_allowed?
      assert socket.assigns.aurora_readings != []

      revoked = Component.assign(socket, :operator?, false)
      {:noreply, refreshed} = Page.handle_refresh(revoked)

      refute refreshed.assigns.aurora_allowed?
      assert refreshed.assigns.aurora_readings == []
    end

    test "an authorized mount reads every section and the page renders no mutation control" do
      {:ok, session} = Page.init(authorized_by: :host_route)
      {:ok, socket} = Page.mount(%{}, session, socket_with([]))

      assert length(socket.assigns.aurora_readings) ==
               length(Sections.sections())

      html = rendered_to_string(Page.render(socket.assigns))
      document = Floki.parse_fragment!(html)

      assert Floki.find(document, "form") == []
      assert Floki.find(document, "button") == []
      assert Floki.attribute(document, "phx-click") == []
    end

    test "menu_link/2 names the page when the library is configured" do
      assert {:ok, "Aurora Meter"} = Page.menu_link(%{check: :host_route}, capabilities())
    end

    @doc false
    def boom(_socket, _args), do: raise("boom")

    # `Phoenix.LiveDashboard.PageBuilder`'s `capabilities()` is a map, not a
    # keyword list, which is what dialyzer said when the spec claimed otherwise.
    defp capabilities do
      %{
        applications: [],
        dashboard_running?: true,
        modules: [],
        processes: [],
        system_info: nil
      }
    end

    defp socket_with(assigns) do
      Enum.reduce(assigns, %Socket{}, fn {key, value}, socket ->
        Component.assign(socket, key, value)
      end)
    end
  end
end
