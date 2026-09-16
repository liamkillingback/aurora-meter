if Code.ensure_loaded?(Phoenix.Component) do
  defmodule AuroraMeter.LiveDashboard.View do
    @moduledoc """
    **Internal.** Not part of the supported API (see [API inventory](api.md)).
    It may change in any release, including a patch. A host mounts
    `AuroraMeter.LiveDashboard.Page`; this is what that page renders with.

    The rendering half of `AuroraMeter.LiveDashboard.Page`, as plain HEEx.

    It is separate from the page for one reason: `Phoenix.LiveDashboard` is an
    optional dependency and the behaviour the acceptance criteria are about (a
    refusal renders no data, an unreadable section renders "unavailable" and
    never a zero, a stale gauge says how stale) must be testable in a build that
    does not have it. This module needs only `Phoenix.Component`, which the
    package already declares optionally, so `Phoenix.LiveViewTest.render_component/2`
    can drive every panel directly.

    Nothing here reads anything. It renders what
    `AuroraMeter.LiveDashboard.Sections.read/1` returned, and the readings for
    every section are passed in together, so a page cannot render one section
    from a fresh read and another from a stale one.
    """

    use Phoenix.Component

    alias AuroraMeter.LiveDashboard.Auth
    alias AuroraMeter.LiveDashboard.Sections

    @titles %{
      metering: "Metering (this node)",
      cluster: "Cluster",
      durable_events: "Durable events",
      credits: "Credits",
      workers: "Workers",
      configuration: "Configuration"
    }

    @runbooks %{
      metering:
        {"Operations: when the database is unavailable",
         "https://hexdocs.pm/aurora_meter/operations.html#4-when-the-database-is-unavailable"},
      cluster:
        {"Clustering: guarantees", "https://hexdocs.pm/aurora_meter/clustering.html#guarantees"},
      durable_events:
        {"Operations: replay", "https://hexdocs.pm/aurora_meter/operations.html#6-replay"},
      credits:
        {"Operations: recovering stale holds",
         "https://hexdocs.pm/aurora_meter/operations.html#3-recovering-stale-holds"},
      workers:
        {"Operations: pause and resume",
         "https://hexdocs.pm/aurora_meter/operations.html#5-pause-and-resume"},
      configuration: {"Configuration", "https://hexdocs.pm/aurora_meter/configuration.html"}
    }

    @doc """
    The whole page.

    `readings` is `[{section, reading}]` in `Sections.sections/0` order,
    `allowed?` is the result of the host's authorization check and `check` is
    the configured check, named in the refusal panel.
    """
    attr(:allowed?, :boolean, required: true)
    attr(:check, :any, required: true)
    attr(:readings, :list, default: [])

    @spec page(map()) :: Phoenix.LiveView.Rendered.t()
    def page(assigns) do
      ~H"""
      <div class="aurora-dash">
        <.refusal :if={not @allowed?} check={@check} />
        <div :if={@allowed?}>
          <p class="aurora-dash__guarantee">{Sections.guarantee()}</p>
          <.section :for={{name, reading} <- @readings} name={name} reading={reading} />
        </div>
      </div>
      """
    end

    @doc """
    The panel shown when the configured check did not return `true`.

    It names the check and renders no row, count, tenant key, provider
    reference or payment value, because there is nothing it could render that
    the check has not refused.
    """
    attr(:check, :any, required: true)

    @spec refusal(map()) :: Phoenix.LiveView.Rendered.t()
    def refusal(assigns) do
      assigns = assign(assigns, :reason, Auth.describe(assigns.check))

      ~H"""
      <div class="aurora-dash__refused">
        <h3>Aurora Meter: not authorized</h3>
        <p>
          This session is not authorized to see Aurora Meter's operational data: {@reason}. Nothing is shown rather than a partial view.
        </p>
        <p>
          The check is configured with the page's <code>:authorized_by</code>
          option. See <a href="https://hexdocs.pm/aurora_meter/AuroraMeter.LiveDashboard.Auth.html">
            AuroraMeter.LiveDashboard.Auth
          </a>.
        </p>
      </div>
      """
    end

    @doc """
    One section: its figures, or the word "unavailable" with the error class and
    the runbook link.

    An unavailable section renders **no numeric cell at all**. It does not
    render `0` and it does not render an empty table: an operator reads both as
    "nothing is wrong", and the case this exists for is the one where something
    is wrong and nobody can see it.
    """
    attr(:name, :atom, required: true)
    attr(:reading, :any, required: true)

    @spec section(map()) :: Phoenix.LiveView.Rendered.t()
    def section(assigns) do
      {runbook_text, runbook_url} = Map.fetch!(@runbooks, assigns.name)

      assigns =
        assigns
        |> assign(:title, Map.fetch!(@titles, assigns.name))
        |> assign(:runbook_text, runbook_text)
        |> assign(:runbook_url, runbook_url)

      ~H"""
      <section class={"aurora-dash__section aurora-dash__section--#{@name}"}>
        <h3>{@title}</h3>
        <.unavailable :if={match?({:unavailable, _}, @reading)} reading={@reading} />
        <.figures :if={match?({:ok, _}, @reading)} name={@name} data={elem(@reading, 1)} />
        <p class="aurora-dash__runbook">
          Runbook: <a href={@runbook_url}>{@runbook_text}</a>
        </p>
      </section>
      """
    end

    attr(:reading, :any, required: true)

    defp unavailable(assigns) do
      assigns = assign(assigns, :class, elem(assigns.reading, 1))

      ~H"""
      <p class="aurora-dash__unavailable">
        unavailable ({inspect(@class)}) - this section could not be read, so no
        figure is shown for it. It is not zero and it is not empty.
      </p>
      """
    end

    attr(:name, :atom, required: true)
    attr(:data, :map, required: true)

    defp figures(%{name: :metering} = assigns) do
      ~H"""
      <dl class="aurora-dash__figures">
        <.figure label="counter keys" value={@data.counter_keys} />
        <.figure label="dirty keys" value={@data.dirty_keys} />
        <.figure label="touched keys" value={@data.touched_keys} />
        <.figure label="flush interval (ms)" value={@data.flush_interval} />
        <.gauge_figure
          label="oldest pending age (ms)"
          gauge={@data.gauge}
          key={:oldest_pending_age_ms}
        />
        <.gauge_figure
          label="retained batch age (ms)"
          gauge={@data.gauge}
          key={:pending_batch_age_ms}
        />
        <.gauge_figure
          label="retained batch items"
          gauge={@data.gauge}
          key={:pending_batch_items}
        />
      </dl>
      <p class="aurora-dash__note">
        The pending age is sampled every metrics_interval and is a lower bound:
        it is measured from the last tick that found the buffer clear, so it
        understates a true age by up to one interval.
      </p>
      """
    end

    defp figures(%{name: :cluster} = assigns) do
      ~H"""
      <dl class="aurora-dash__figures">
        <.figure label="cluster_sync" value={@data.enabled?} />
        <.figure label="broadcast interval (ms)" value={@data.broadcast_interval} />
        <.gauge_figure label="peers seen" gauge={@data.gauge} key={:peers} />
        <.gauge_figure
          label="since last message (ms)"
          gauge={@data.gauge}
          key={:since_last_message_ms}
        />
        <.gauge_figure
          label="unreconciled keys"
          gauge={@data.gauge}
          key={:unreconciled_keys}
        />
      </dl>
      <p :if={not @data.enabled?} class="aurora-dash__note">
        cluster_sync is off, so this node gossips with nobody and reports no
        convergence figures. That is a configuration, not a fault.
      </p>
      """
    end

    defp figures(%{name: :durable_events} = assigns) do
      ~H"""
      <dl class="aurora-dash__figures">
        <.checkpoint_figure label="projection" checkpoint={@data.projection} />
        <.checkpoint_figure label="backfill" checkpoint={@data.backfill} />
      </dl>
      <table :if={@data.generations != []} class="aurora-dash__table">
        <thead>
          <tr>
            <th>event-total generation</th>
            <th>rows</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @data.generations}>
            <td>{row.generation}</td>
            <td>{row.rows}</td>
          </tr>
        </tbody>
      </table>
      <p :if={@data.generations == []} class="aurora-dash__note">
        The event totals table was read and holds no rows for any generation.
      </p>
      """
    end

    defp figures(%{name: :credits} = assigns) do
      ~H"""
      <dl class="aurora-dash__figures">
        <.figure label="pending holds" value={@data.holds} />
        <.figure label="holds over 1 h" value={@data.holds_over_1h} />
        <.figure label="holds over 24 h" value={@data.holds_over_24h} />
        <.figure label="oldest hold age (s)" value={@data.oldest_hold_age_seconds} />
        <.figure label="wallets in debt" value={@data.wallets_in_debt} />
        <.figure label="total debt (micro-USD)" value={@data.total_debt_micro} />
      </dl>
      """
    end

    defp figures(%{name: :workers} = assigns) do
      ~H"""
      <table :if={@data.operations != []} class="aurora-dash__table">
        <thead>
          <tr>
            <th>operation</th>
            <th>state</th>
            <th>checkpoints</th>
            <th>newest age (s)</th>
            <th>oldest age (s)</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @data.operations}>
            <td>{row.operation}</td>
            <td>{row.state}</td>
            <td>{row.rows}</td>
            <td>{row.newest_age_seconds}</td>
            <td>{row.oldest_age_seconds}</td>
          </tr>
        </tbody>
      </table>
      <p :if={@data.operations == []} class="aurora-dash__note">
        The checkpoint table was read and holds no rows, so no operation has run
        on this database yet.
      </p>
      <p class="aurora-dash__note">
        Grouped by operation. A per-tenant operation's checkpoint name carries
        the tenant key in its scope, so whole names are never rendered here.
      </p>
      """
    end

    defp figures(%{name: :configuration} = assigns) do
      ~H"""
      <dl class="aurora-dash__figures">
        <.figure label="flush_interval" value={@data.flush_interval} />
        <.figure label="broadcast_interval" value={@data.broadcast_interval} />
        <.figure label="metrics_interval" value={@data.metrics_interval} />
        <.figure label="cluster_sync" value={@data.cluster_sync} />
        <.figure label="history" value={@data.history} />
        <.figure label="feature_sources" value={inspect(@data.feature_sources)} />
        <.figure
          label="undeclared_feature_policy"
          value={inspect(@data.undeclared_feature_policy)}
        />
        <.figure label="events_outbox" value={inspect(@data.events_outbox)} />
      </dl>
      """
    end

    attr(:label, :string, required: true)
    attr(:value, :any, required: true)

    defp figure(assigns) do
      ~H"""
      <div class="aurora-dash__figure">
        <dt>{@label}</dt>
        <dd>{format(@value)}</dd>
      </div>
      """
    end

    attr(:label, :string, required: true)
    attr(:gauge, :any, required: true)
    attr(:key, :atom, required: true)

    # A gauge that has never been sampled renders "not sampled yet", never 0. A
    # sample older than three metrics_intervals renders "stale" WITH its age, so
    # an operator can tell a stopped sampler from a slow one.
    defp gauge_figure(assigns) do
      ~H"""
      <div class="aurora-dash__figure">
        <dt>{@label}</dt>
        <dd :if={is_nil(@gauge)} class="aurora-dash__nosample">
          not sampled yet
        </dd>
        <dd :if={@gauge && @gauge.stale?} class="aurora-dash__stale">
          {format(Map.get(@gauge.measurements, @key))} stale (last sample {@gauge.age_ms} ms ago)
        </dd>
        <dd :if={@gauge && not @gauge.stale?}>
          {format(Map.get(@gauge.measurements, @key))}
        </dd>
      </div>
      """
    end

    attr(:label, :string, required: true)
    attr(:checkpoint, :any, required: true)

    defp checkpoint_figure(assigns) do
      ~H"""
      <div class="aurora-dash__figure">
        <dt>{@label}</dt>
        <dd :if={is_nil(@checkpoint)}>no checkpoint row</dd>
        <dd :if={@checkpoint}>
          {@checkpoint.state || "unknown"}, cursor {inspect(@checkpoint.cursor)}, updated {@checkpoint.updated_at}
        </dd>
      </div>
      """
    end

    # `nil` is the one value a figure can carry that is not a number, and it
    # means "there is no such thing here", never zero.
    defp format(nil), do: "none"
    defp format(true), do: "on"
    defp format(false), do: "off"
    defp format(value) when is_integer(value), do: Integer.to_string(value)
    defp format(value) when is_binary(value), do: value
    defp format(value), do: inspect(value)
  end
end
