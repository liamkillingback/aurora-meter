if Code.ensure_loaded?(Phoenix.Component) do
  defmodule AuroraMeter.Components do
    @moduledoc """
    Drop-in HEEx components for showing live usage. Compiled only when
    `Phoenix.Component` is available (the LiveView deps are optional).

    They are unstyled by design (BEM-style `aurora-meter__*` classes) so they
    inherit your app's look; the Pro dashboard ships a styled version. Pair with
    `AuroraMeter.LiveView.subscribe/1` for live updates.
    """

    use Phoenix.Component

    @doc """
    Renders a labelled usage bar for one feature, driven by `AuroraMeter.quota/2`.

    Hard caps show `used / limit`; metered features show `used / included` and
    flag overage; boolean features show whether they are enabled.
    """
    attr(:tenant, :any, required: true)
    attr(:feature, :atom, required: true)
    attr(:label, :string, default: nil)
    attr(:rest, :global)

    def usage_meter(assigns) do
      quota = AuroraMeter.quota(assigns.tenant, assigns.feature)

      assigns =
        assigns
        |> assign(:quota, quota)
        |> assign(:label, assigns.label || to_string(assigns.feature))
        |> assign(:usage_text, usage_text(quota))

      ~H"""
      <div class={["aurora-meter", "aurora-meter--#{@quota.kind}"]} {@rest}>
        <span class="aurora-meter__label">{@label}</span>
        <div
          :if={@quota.kind in [:hard, :metered]}
          class="aurora-meter__bar"
          role="progressbar"
          aria-label={@label}
          aria-valuenow={@quota.used}
          aria-valuemax={@quota.limit || @quota.included}
        >
          <div class="aurora-meter__fill" style={"width: #{@quota.percent}%"}></div>
        </div>
        <span class="aurora-meter__value">{@usage_text}</span>
        <span :if={@quota.overage > 0} class="aurora-meter__overage">
          +{@quota.overage} over
        </span>
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
          plan -> plan.features |> Map.keys() |> Enum.sort()
        end

      assigns = assign(assigns, :features, features)

      ~H"""
      <div class="aurora-usage-summary" {@rest}>
        <.usage_meter :for={feature <- @features} tenant={@tenant} feature={feature} />
      </div>
      """
    end

    defp usage_text(%{kind: :hard, used: used, limit: limit}), do: "#{used} / #{limit}"
    defp usage_text(%{kind: :metered, used: used, included: inc}), do: "#{used} / #{inc}"
    defp usage_text(%{kind: :boolean, enabled: true}), do: "enabled"
    defp usage_text(%{kind: :boolean, enabled: false}), do: "not included"
    defp usage_text(%{used: used}), do: "#{used}"
  end
end
