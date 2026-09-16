defmodule AuroraMeterExampleAi.MeterProbeLive do
  @moduledoc """
  Two minimal LiveViews that differ in exactly one attribute, so the sample can
  prove why `AuroraMeterExampleAiWeb.GenerateLive` passes a changing assign into
  `AuroraMeter.Components.usage_meter/1`.

  Both subscribe to the same tenant, both receive the same usage broadcast, and
  both re-render. `Stale` invokes the meter with assigns that never change;
  `Fresh` adds one that does.
  """

  defmodule Stale do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      org = AuroraMeterExampleAi.Repo.get!(AuroraMeterExampleAi.Orgs.Org, session["org_id"])
      AuroraMeter.LiveView.subscribe(org)
      {:ok, socket |> assign(:org, org) |> assign(:tick, 0)}
    end

    def handle_info({:aurora_meter, :usage, _payload}, socket) do
      {:noreply, update(socket, :tick, &(&1 + 1))}
    end

    def handle_info(_other, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <div id="tick">{@tick}</div>
      <AuroraMeter.Components.usage_meter tenant={@org} feature={:images} label="images" />
      """
    end
  end

  defmodule Fresh do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      org = AuroraMeterExampleAi.Repo.get!(AuroraMeterExampleAi.Orgs.Org, session["org_id"])
      AuroraMeter.LiveView.subscribe(org)
      {:ok, socket |> assign(:org, org) |> assign(:tick, 0)}
    end

    def handle_info({:aurora_meter, :usage, _payload}, socket) do
      {:noreply, update(socket, :tick, &(&1 + 1))}
    end

    def handle_info(_other, socket), do: {:noreply, socket}

    def render(assigns) do
      ~H"""
      <div id="tick">{@tick}</div>
      <AuroraMeter.Components.usage_meter
        tenant={@org}
        feature={:images}
        label="images"
        data-usage={@tick}
      />
      """
    end
  end
end
