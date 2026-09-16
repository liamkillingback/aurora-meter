if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule AuroraMeter.LiveDashboard.Page do
    @moduledoc """
    An optional `Phoenix.LiveDashboard` page showing what Aurora Meter is doing
    on **this node**, with the runbook link beside each section.

        # router.ex, inside an already-authenticated scope
        live_dashboard "/dashboard",
          metrics: MyApp.Telemetry,
          on_mount: [{MyAppWeb.Admin, :ensure_operator}],
          additional_pages: [
            aurora_meter: {AuroraMeter.LiveDashboard.Page, authorized_by: {:assign, :operator?}}
          ]

    Compiled only when `phoenix_live_dashboard` is installed. Without it this
    module does not exist and nothing else in the package changes.

    ## Authorization is not optional and has no default

    `:authorized_by` is required. `AuroraMeter.LiveDashboard.Auth` holds the
    three accepted forms and the reasoning; the short version is that a library
    page cannot know who is signed in and will not guess, so adding this page to
    `additional_pages:` by copy-paste fails at registration until somebody makes
    a decision. The check is re-evaluated on every refresh as well as at mount,
    so a session that loses its marker stops seeing data without waiting for a
    remount.

    This page accepts `authorized_by: :host_route`, and
    `AuroraMeter.Pro.LiveDashboard.Page` does not. The asymmetry is the point:
    **this page renders no tenant key, feature name, reference or event id**.
    Every figure on it is a node-local aggregate, a checkpoint position or a
    configuration value.

    ## What it shows, and what it refuses to show

    Metering on this node, cluster convergence, the durable-event checkpoints,
    credit holds and debt in aggregate, checkpoint state grouped by operation,
    and the observability-relevant configuration.

    A section that cannot be read renders the word "unavailable" with an error
    class and its runbook link. It never renders `0` and never renders an empty
    table in place of a value it could not read: an operator reads both as "not
    a problem", and the case this page exists for is the one where it is.

    A gauge-derived figure whose last sample is older than three
    `:metrics_interval`s renders as stale with the sample age, because a figure
    whose sampler has stopped must not look current.

    The page is read-only. It renders no control that changes anything.
    """

    use Phoenix.LiveDashboard.PageBuilder

    alias AuroraMeter.LiveDashboard.Auth
    alias AuroraMeter.LiveDashboard.Sections

    @doc """
    Validates `:authorized_by` and carries it into the page session.

    Raises `ArgumentError` naming the option and the three accepted forms when
    it is absent or unrecognised, so the page cannot be added to
    `additional_pages:` by copy-paste without a decision being made.
    """
    @spec init(keyword()) :: {:ok, %{check: Auth.check()}}
    @impl Phoenix.LiveDashboard.PageBuilder
    def init(opts) do
      {:ok, %{check: Auth.validate!(opts, :core)}}
    end

    @doc """
    "Aurora Meter", or disabled with "Aurora Meter: not configured" when
    `AuroraMeter.Config.validate!/0` raises because the host added the page but
    not the library.
    """
    @spec menu_link(map(), map()) :: {:ok, String.t()} | {:disabled, String.t()}
    @impl Phoenix.LiveDashboard.PageBuilder
    def menu_link(_session, _capabilities) do
      AuroraMeter.Config.validate!()
      {:ok, "Aurora Meter"}
    rescue
      _error -> {:disabled, "Aurora Meter: not configured"}
    end

    @doc """
    Evaluates the configured check, then reads every section only if it passed.

    Params are ignored: nothing on this page is addressed by a URL.
    """
    @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:ok, Phoenix.LiveView.Socket.t()}
    @impl Phoenix.LiveDashboard.PageBuilder
    def mount(_params, session, socket) do
      {:ok, load(socket, session.check)}
    end

    @doc """
    Re-evaluates the check and re-reads the sections on LiveDashboard's timer,
    so a session that loses its marker stops seeing data without a remount.
    """
    @spec handle_refresh(Phoenix.LiveView.Socket.t()) ::
            {:noreply, Phoenix.LiveView.Socket.t()}
    @impl Phoenix.LiveDashboard.PageBuilder
    def handle_refresh(socket) do
      {:noreply, load(socket, socket.assigns.aurora_check)}
    end

    @doc "The page, or the refusal panel. Read-only: no form, no button."
    @impl Phoenix.LiveDashboard.PageBuilder
    def render(assigns) do
      ~H"""
      <AuroraMeter.LiveDashboard.View.page
        allowed?={@aurora_allowed?}
        check={@aurora_check}
        readings={@aurora_readings}
      />
      """
    end

    # The check runs BEFORE any section is read, so a refused session does not
    # even cause the queries, let alone render them.
    defp load(socket, check) do
      allowed? = Auth.allowed?(check, socket)

      readings =
        if allowed?, do: Enum.map(Sections.sections(), &{&1, Sections.read(&1)}), else: []

      socket
      |> assign(:aurora_check, check)
      |> assign(:aurora_allowed?, allowed?)
      |> assign(:aurora_readings, readings)
    end
  end
end
