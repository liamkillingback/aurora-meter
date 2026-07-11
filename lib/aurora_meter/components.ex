if Code.ensure_loaded?(Phoenix.Component) do
  defmodule AuroraMeter.Components do
    @moduledoc """
    Drop-in HEEx components for showing live usage. Compiled only when
    `Phoenix.Component` is available (the LiveView deps are optional).

    Pair with `AuroraMeter.LiveView.subscribe/1` for live updates.
    """

    use Phoenix.Component

    @doc "Renders a labelled usage bar for one feature."
    attr(:tenant, :any, required: true)
    attr(:feature, :atom, required: true)
    attr(:label, :string, default: nil)
    attr(:rest, :global)

    def usage_meter(assigns) do
      used = AuroraMeter.usage(assigns.tenant, assigns.feature)

      limit =
        case AuroraMeter.remaining(assigns.tenant, assigns.feature) do
          :unlimited -> nil
          remaining -> used + remaining
        end

      assigns =
        assigns
        |> assign(:used, used)
        |> assign(:limit, limit)
        |> assign(:pct, percent(used, limit))
        |> assign(:label, assigns.label || to_string(assigns.feature))
        |> assign(:usage_text, usage_text(used, limit))

      ~H"""
      <div class="aurora-meter" {@rest}>
        <span class="aurora-meter__label">{@label}</span>
        <div
          class="aurora-meter__bar"
          role="progressbar"
          aria-label={@label}
          aria-valuenow={@used}
          aria-valuemax={@limit}
        >
          <div class="aurora-meter__fill" style={"width: #{@pct}%"}></div>
        </div>
        <span class="aurora-meter__value">{@usage_text}</span>
      </div>
      """
    end

    @doc "Renders a usage meter for every feature in the tenant's plan."
    attr(:tenant, :any, required: true)
    attr(:rest, :global)

    def usage_summary(assigns) do
      features =
        case AuroraMeter.plan(assigns.tenant) do
          nil -> []
          plan -> Map.keys(plan.features)
        end

      assigns = assign(assigns, :features, features)

      ~H"""
      <div class="aurora-usage-summary" {@rest}>
        <.usage_meter :for={feature <- @features} tenant={@tenant} feature={feature} />
      </div>
      """
    end

    defp percent(_used, nil), do: 0
    defp percent(used, limit) when limit > 0, do: min(100, round(used / limit * 100))
    defp percent(_used, _limit), do: 0

    defp usage_text(used, nil), do: "#{used}"
    defp usage_text(used, limit), do: "#{used} / #{limit}"
  end
end
