if Code.ensure_loaded?(Phoenix.Component) do
  defmodule AuroraMeter.Components do
    @moduledoc """
    Drop-in HEEx components for showing live usage and credit spend. Compiled
    only when `Phoenix.Component` is available (the LiveView deps are optional).

    They are unstyled by design (BEM-style `aurora-meter__*`, `aurora-spend-chart__*`
    and `aurora-credit-summary__*` classes) so they inherit your app's look; the
    Pro dashboard ships a styled version. Nothing here declares a colour: the
    charts paint with `currentColor`, so they take the text colour your design
    system already set. There is no JavaScript — the chart is inline SVG and the
    tooltips are `<title>` elements. Pair with `AuroraMeter.LiveView.subscribe/1`
    for live usage updates.

    Money components render dollars through `AuroraMeter.Credits.Money`, never
    raw micro-dollars:

        <.spend_chart points={AuroraMeter.Credits.spend_history(@org, days: 30)} />
        <.credit_summary summary={AuroraMeter.Credits.summary(@org)} />

    """

    use Phoenix.Component

    alias AuroraMeter.Credits.Money

    # The chart's coordinate space. The SVG is drawn at this fixed width and
    # stretched horizontally to whatever the host gives it
    # (`preserveAspectRatio="none"`), so the y axis stays 1:1 with `:height`
    # pixels and bar heights mean what they say.
    @chart_width 1_000

    # A zero-spend bucket still draws this many units, so a quiet day reads as
    # "nothing happened" rather than "no data" — the hole a naive chart leaves.
    @baseline_height 1

    # Room at the top of the plot for the grant markers.
    @marker_height 4
    @marker_gap 3

    @doc """
    Renders a labelled usage bar for one feature, driven by `AuroraMeter.quota/2`.

    Hard caps show `used / limit`; metered features show `used / included` and
    flag overage; counters show the bare count with no bar (they have no
    denominator — ADR 0006); boolean features show whether they are enabled;
    integer features show their plan value.
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

    @doc """
    Renders a spend-per-bucket bar chart from `AuroraMeter.Credits.spend_history/2`.

    Every bucket in `points` gets a bar, including the empty ones: a zero-spend
    day is a baseline, never a gap. Buckets where credit was granted carry a
    marker above the bar when `show_grants` is set. Amounts in the axis labels
    and in the `<title>` tooltips are dollars, formatted with
    `AuroraMeter.Credits.Money.format/2`.

    ## Examples

        <.spend_chart points={AuroraMeter.Credits.spend_history(@org, days: 30)} />

        <.spend_chart
          points={AuroraMeter.Credits.spend_history(@org, bucket: :month, days: 365)}
          label="Spend per month"
          height={160}
        />

    """
    attr(:points, :list, required: true)
    attr(:height, :integer, default: 120)
    attr(:label, :string, default: "Spend per day")
    attr(:show_grants, :boolean, default: true)
    attr(:rest, :global)

    def spend_chart(assigns) do
      points = assigns.points
      peak = points |> Enum.map(& &1.spent) |> Enum.max(fn -> 0 end)

      assigns =
        assigns
        |> assign(:bars, bars(points, assigns.height, peak, assigns.show_grants))
        |> assign(:peak_text, Money.format(peak))
        |> assign(:zero_text, Money.format(0))
        |> assign(:total_text, Money.format(Enum.reduce(points, 0, &(&1.spent + &2))))
        |> assign(:range_text, range_text(points))
        |> assign(:view_box, "0 0 #{@chart_width} #{assigns.height}")
        # `@marker_height` inside ~H would be read as an assign, not the
        # module attribute, so it is passed through explicitly.
        |> assign(:marker_height, @marker_height)

      ~H"""
      <div class="aurora-spend-chart" {@rest}>
        <div class="aurora-spend-chart__header">
          <span class="aurora-spend-chart__label">{@label}</span>
          <span class="aurora-spend-chart__total">{@total_text}</span>
        </div>
        <svg
          :if={@bars != []}
          class="aurora-spend-chart__svg"
          viewBox={@view_box}
          width="100%"
          height={@height}
          preserveAspectRatio="none"
          role="img"
          aria-label={"#{@label}: #{@total_text} over #{@range_text}"}
        >
          <g :for={bar <- @bars} class="aurora-spend-chart__bucket">
            <rect
              class={[
                "aurora-spend-chart__bar",
                bar.spent == 0 && "aurora-spend-chart__bar--zero"
              ]}
              x={bar.x}
              y={bar.y}
              width={bar.width}
              height={bar.height}
              fill="currentColor"
            >
              <title>{bar.title}</title>
            </rect>
            <rect
              :if={bar.marker}
              class="aurora-spend-chart__grant"
              x={bar.x}
              y="0"
              width={bar.width}
              height={@marker_height}
              fill="currentColor"
            >
              <title>{bar.marker}</title>
            </rect>
          </g>
        </svg>
        <p :if={@bars == []} class="aurora-spend-chart__empty">No spend yet</p>
        <div :if={@bars != []} class="aurora-spend-chart__axis">
          <span class="aurora-spend-chart__axis-max">{@peak_text}</span>
          <span class="aurora-spend-chart__axis-range">{@range_text}</span>
          <span class="aurora-spend-chart__axis-min">{@zero_text}</span>
        </div>
      </div>
      """
    end

    @doc """
    Renders the credit balance and burn from `AuroraMeter.Credits.summary/1` as a
    description list.

    Held, promotional and granted figures only appear when they are non-zero.
    `daily_burn` and `runway_days` render as `"—"` when they are `nil` — there is
    no honest number to show for a tenant that has not spent anything, and this
    component will not invent one.

    ## Examples

        <.credit_summary summary={AuroraMeter.Credits.summary(@org)} />

    """
    attr(:summary, :map, required: true)
    attr(:rest, :global)

    def credit_summary(assigns) do
      ~H"""
      <dl class="aurora-credit-summary" {@rest}>
        <div class="aurora-credit-summary__item aurora-credit-summary__item--available">
          <dt class="aurora-credit-summary__label">Available</dt>
          <dd class="aurora-credit-summary__value">{Money.format(@summary.available)}</dd>
        </div>
        <div
          :if={@summary.held > 0}
          class="aurora-credit-summary__item aurora-credit-summary__item--held"
        >
          <dt class="aurora-credit-summary__label">On hold</dt>
          <dd class="aurora-credit-summary__value">{Money.format(@summary.held)}</dd>
        </div>
        <div
          :if={@summary.promotional > 0}
          class="aurora-credit-summary__item aurora-credit-summary__item--promotional"
        >
          <dt class="aurora-credit-summary__label">Promotional</dt>
          <dd class="aurora-credit-summary__value">{Money.format(@summary.promotional)}</dd>
        </div>
        <div class="aurora-credit-summary__item aurora-credit-summary__item--spent">
          <dt class="aurora-credit-summary__label">Spent this period</dt>
          <dd class="aurora-credit-summary__value">{Money.format(@summary.spent_this_period)}</dd>
        </div>
        <div
          :if={@summary.granted_this_period > 0}
          class="aurora-credit-summary__item aurora-credit-summary__item--granted"
        >
          <dt class="aurora-credit-summary__label">Added this period</dt>
          <dd class="aurora-credit-summary__value">{Money.format(@summary.granted_this_period)}</dd>
        </div>
        <div class="aurora-credit-summary__item aurora-credit-summary__item--burn">
          <dt class="aurora-credit-summary__label">Daily burn</dt>
          <dd class="aurora-credit-summary__value">{burn_text(@summary.daily_burn)}</dd>
        </div>
        <div class="aurora-credit-summary__item aurora-credit-summary__item--runway">
          <dt class="aurora-credit-summary__label">Runway</dt>
          <dd class="aurora-credit-summary__value">{runway_text(@summary.runway_days)}</dd>
        </div>
      </dl>
      """
    end

    # `daily_burn` is routinely a fraction of a cent (that is the whole point of
    # micro-dollars), and `format/2`'s two decimals would render an honest burn
    # as "$0.00". `format_compact/1` keeps it non-zero and still shows dollars.
    @spec burn_text(non_neg_integer() | nil) :: String.t()
    defp burn_text(nil), do: "—"
    defp burn_text(micro), do: Money.format_compact(micro) <> " / day"

    @spec runway_text(non_neg_integer() | nil) :: String.t()
    defp runway_text(nil), do: "—"
    defp runway_text(1), do: "1 day"
    defp runway_text(days), do: "#{days} days"

    @spec bars([map()], pos_integer(), non_neg_integer(), boolean()) :: [map()]
    defp bars([], _height, _peak, _show_grants), do: []

    defp bars(points, height, peak, show_grants) do
      count = length(points)
      slot = @chart_width / count
      width = slot * 0.72
      offset = slot * 0.14
      plot = max(@baseline_height, height - @marker_height - @marker_gap)

      points
      |> Enum.with_index()
      |> Enum.map(fn {point, index} ->
        bar = bar_height(point.spent, peak, plot)

        %{
          spent: point.spent,
          x: coord(index * slot + offset),
          y: coord(height - bar),
          width: coord(width),
          height: coord(bar),
          title: title(point),
          marker: show_grants && point.granted > 0 && grant_title(point)
        }
      end)
    end

    # A zero bucket is drawn at `@baseline_height` rather than skipped: the bar
    # says "we looked, and nothing was spent". Everything else scales against the
    # tallest bucket, so a flat series still fills the plot.
    @spec bar_height(non_neg_integer(), non_neg_integer(), number()) :: number()
    defp bar_height(0, _peak, _plot), do: @baseline_height
    defp bar_height(_spent, 0, _plot), do: @baseline_height

    defp bar_height(spent, peak, plot),
      do: max(@baseline_height, Float.round(spent / peak * plot, 2))

    @spec title(map()) :: String.t()
    defp title(%{date: date, spent: spent, granted: granted}) when granted > 0,
      do: "#{date}: #{Money.format(spent)} spent · #{Money.format(granted)} added"

    defp title(%{date: date, spent: spent}), do: "#{date}: #{Money.format(spent)} spent"

    @spec grant_title(map()) :: String.t()
    defp grant_title(%{date: date, granted: granted}),
      do: "#{date}: #{Money.format(granted)} added"

    @spec range_text([map()]) :: String.t()
    defp range_text([]), do: ""
    defp range_text([only]), do: "#{only.date}"
    defp range_text(points), do: "#{hd(points).date} – #{List.last(points).date}"

    @spec coord(number()) :: String.t()
    defp coord(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

    defp usage_text(%{kind: :hard, used: used, limit: limit}), do: "#{used} / #{limit}"
    defp usage_text(%{kind: :metered, used: used, included: inc}), do: "#{used} / #{inc}"
    # ADR 0006: a counter renders bare. Never "#{used} / #{nil}", never a percentage.
    defp usage_text(%{kind: :counter, used: used}), do: "#{used}"
    defp usage_text(%{kind: :boolean, enabled: true}), do: "enabled"
    defp usage_text(%{kind: :boolean, enabled: false}), do: "not included"
    defp usage_text(%{kind: :feature, value: value}), do: "#{value}"
    defp usage_text(%{used: used}), do: "#{used}"
  end
end
