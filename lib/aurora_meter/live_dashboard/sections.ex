defmodule AuroraMeter.LiveDashboard.Sections do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch. A host mounts
  `AuroraMeter.LiveDashboard.Page`; this is what that page is built from.

  The data behind `AuroraMeter.LiveDashboard.Page`, read without any dashboard
  dependency at all.

  `read/1` answers `{:ok, data}` or `{:unavailable, class}` for one section. It
  is a plain module with no `Phoenix.LiveDashboard` reference, so it is compiled
  in every build, including one with none of the optional dependencies, and the
  rules below are testable there.

  ## "Unavailable", never zero

  A section that cannot read its source answers `{:unavailable, class}` and the
  page renders the word "unavailable" with that class. It never renders `0` and
  it never renders an empty table, because an operator reads both as "there is
  nothing wrong" and the case this exists for is the one where something is
  wrong and nobody can see it. The classes are:

  | Class | Cause |
  |---|---|
  | `:database_unavailable` | `DBConnection` or `Postgrex` refused the read |
  | `:timeout` | the read passed its 2,000 ms budget, or a `GenServer.call` did |
  | `:not_started` | the supervision tree is not running, so the ETS tables or the process are absent |
  | `:error` | anything else, including a raise inside the reader |

  Every database read carries `timeout: 2_000`, takes no lock, opens no
  transaction and has a bounded result set, so a slow database becomes
  "unavailable" rather than a hung LiveView.

  ## No tenant-identifying value, anywhere

  Every figure here is a node-local aggregate, a checkpoint position or a
  configuration value. No section returns a tenant key, a feature name, a
  reference or an event id, which is what lets the core page be shown behind a
  plain operator marker (`AuroraMeter.LiveDashboard.Auth`).

  That is a live constraint rather than a happy accident: `aurora_meter_checkpoints`
  names rows `"<operation>:<scope>"` and the scope is a **tenant key** for a
  per-tenant operation (`"lot_migration:org_42"`). `read(:workers)` therefore
  groups on `split_part(name, ':', 1)` in SQL and never returns a whole name.

  ## Gauge-derived figures and staleness

  Three measurements are sampled on a timer rather than computed on demand: how
  much is buffered, how old the oldest buffered thing is, and how far behind the
  cluster is. `read/1` reports them from the **last emitted sample** together
  with its age, and marks the figure stale when that age is more than three
  `:metrics_interval`s. A figure whose sampler has stopped must not look
  current; the age is shown so an operator can tell a stopped sampler from a
  slow one.

  Every age here is `AuroraMeter.Clock.monotonic_ms/0`, an in-memory span inside
  one node. Never a wall clock: a millisecond duration read from a clock that
  can step backwards is the defect `open-findings.md` X100 measured.
  """

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Clock
  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Store

  @sections [:metering, :cluster, :durable_events, :credits, :workers, :configuration]

  @timeout 2_000
  @stale_intervals 3
  @hour_seconds 3_600
  @day_seconds 86_400

  @typedoc "A section's reading, or the class of failure that stopped it."
  @type reading :: {:ok, map()} | {:unavailable, class()}

  @typedoc "Why a section could not be read."
  @type class :: :database_unavailable | :timeout | :not_started | :error

  @doc """
  The section names `read/1` accepts, in the order the page renders them.

  ## Examples

      iex> :metering in AuroraMeter.LiveDashboard.Sections.sections()
      true

  """
  @spec sections() :: [atom()]
  def sections, do: @sections

  @doc """
  The guarantee the metering buffer actually gives, as one line.

  It is on the page because a dashboard that shows a buffer without saying what
  happens to it invites the reading that the buffer is durable work in progress.
  It is not: it is a loss window.

  ## Examples

      iex> AuroraMeter.LiveDashboard.Sections.guarantee() =~ "can be lost"
      true

  """
  @spec guarantee() :: String.t()
  def guarantee do
    "Buffered usage that is not yet in an acknowledged flush batch can be lost " <>
      "with the VM. It is a loss window, not pending durable work. See the " <>
      "guarantee table in docs/metering.md."
  end

  @doc """
  Reads one section.

  Returns `{:ok, data}` or `{:unavailable, class}`. It never raises and never
  returns a zero in place of a value it could not read.

  ## Examples

      iex> match?({:ok, _} , AuroraMeter.LiveDashboard.Sections.read(:configuration))
      true

      iex> AuroraMeter.LiveDashboard.Sections.read(:no_such_section)
      {:unavailable, :error}

  """
  @spec read(atom()) :: reading()
  def read(section) do
    {:ok, do_read(section)}
  rescue
    error -> {:unavailable, class_for(error)}
  catch
    :exit, {:timeout, _call} -> {:unavailable, :timeout}
    :exit, {:noproc, _call} -> {:unavailable, :not_started}
    :exit, _other -> {:unavailable, :error}
  end

  @doc """
  Whether a sample `age_ms` old is stale, and the threshold that decided it.

  Stale is more than three `:metrics_interval`s. With `metrics_interval: 0` the
  library drives no timer at all and has no cadence to judge by, so nothing is
  stale and the age is reported on its own.

  ## Examples

      iex> AuroraMeter.LiveDashboard.Sections.stale?(1, 0)
      false

      iex> AuroraMeter.LiveDashboard.Sections.stale?(40_000, 10_000)
      true

      iex> AuroraMeter.LiveDashboard.Sections.stale?(20_000, 10_000)
      false

  """
  @spec stale?(non_neg_integer(), non_neg_integer()) :: boolean()
  def stale?(_age_ms, interval) when interval <= 0, do: false
  def stale?(age_ms, interval), do: age_ms > @stale_intervals * interval

  # -- the sections ----------------------------------------------------------

  defp do_read(:metering) do
    %{
      counter_keys: ets_size(Store.counters_table()),
      dirty_keys: ets_size(Store.dirty_table()),
      touched_keys: ets_size(Store.touched_table()),
      flush_interval: Config.flush_interval(),
      metrics_interval: Config.metrics_interval(),
      gauge: gauge([:aurora_meter, :store, :gauge])
    }
  end

  defp do_read(:cluster) do
    %{
      enabled?: Config.cluster_sync?(),
      broadcast_interval: Config.broadcast_interval(),
      metrics_interval: Config.metrics_interval(),
      gauge: gauge([:aurora_meter, :cluster, :lag])
    }
  end

  defp do_read(:durable_events) do
    %{
      projection: AuroraMeter.Checkpoints.get("events_projection"),
      backfill: AuroraMeter.Checkpoints.get("events_backfill"),
      generations: generations()
    }
  end

  defp do_read(:credits) do
    now = Clock.db_now()
    hour = DateTime.add(now, -@hour_seconds, :second)
    day = DateTime.add(now, -@day_seconds, :second)

    holds =
      repo().one(
        from(t in CreditTransaction,
          where: t.kind == ^:hold and t.status == ^:pending,
          select: %{
            holds: count(t.id),
            over_1h: filter(count(t.id), t.inserted_at < ^hour),
            over_24h: filter(count(t.id), t.inserted_at < ^day),
            oldest: min(t.inserted_at)
          }
        ),
        timeout: @timeout
      )

    debt =
      repo().one(
        from(b in CreditBalance,
          where: b.debt > 0,
          select: %{wallets: count(b.id), total: sum(b.debt)}
        ),
        timeout: @timeout
      )

    %{
      holds: holds.holds,
      holds_over_1h: holds.over_1h,
      holds_over_24h: holds.over_24h,
      oldest_hold_age_seconds: age_seconds(holds.oldest, now),
      wallets_in_debt: debt.wallets,
      total_debt_micro: to_integer(debt.total)
    }
  end

  # `split_part(name, ':', 1)` rather than the name, because the scope half of a
  # per-tenant operation's checkpoint name IS a tenant key
  # ("lot_migration:org_42"). Grouping in SQL also bounds the result: the number
  # of rows is operations times states, not one per tenant.
  defp do_read(:workers) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT split_part(name, ':', 1) AS operation,
               coalesce(state, 'unknown') AS state,
               count(*) AS rows,
               max(updated_at) AS newest,
               min(updated_at) AS oldest
        FROM aurora_meter_checkpoints
        GROUP BY 1, 2
        ORDER BY 1, 2
        LIMIT 100
        """,
        [],
        timeout: @timeout
      )

    now = Clock.db_now()

    operations =
      Enum.map(rows, fn [operation, state, count, newest, oldest] ->
        %{
          operation: operation,
          state: state,
          rows: count,
          newest_age_seconds: age_seconds(newest, now),
          oldest_age_seconds: age_seconds(oldest, now)
        }
      end)

    %{operations: operations}
  end

  defp do_read(:configuration) do
    %{
      flush_interval: Config.flush_interval(),
      broadcast_interval: Config.broadcast_interval(),
      metrics_interval: Config.metrics_interval(),
      cluster_sync: Config.cluster_sync?(),
      history: Config.history?(),
      feature_sources: Config.feature_sources(),
      undeclared_feature_policy: Config.undeclared_feature_policy(),
      events_outbox: Config.events_outbox()
    }
  end

  # -- helpers ---------------------------------------------------------------

  defp generations do
    %{rows: rows} =
      repo().query!(
        """
        SELECT generation, count(*) AS rows
        FROM aurora_meter_event_totals
        GROUP BY 1
        ORDER BY 1 DESC
        LIMIT 20
        """,
        [],
        timeout: @timeout
      )

    Enum.map(rows, fn [generation, count] -> %{generation: generation, rows: count} end)
  end

  # `nil` rather than a zero-filled map when nothing has sampled yet: a gauge
  # that reports zero when nothing is watching is worse than one that reports
  # nothing, because zero looks healthy.
  defp gauge(event) do
    case sample(event) do
      nil ->
        nil

      {measurements, at_ms} ->
        interval = Config.metrics_interval()
        age = max(Clock.monotonic_ms() - at_ms, 0)
        %{measurements: measurements, age_ms: age, stale?: stale?(age, interval)}
    end
  end

  defp sample([:aurora_meter, :store, :gauge]), do: Store.gauge_sample()
  defp sample([:aurora_meter, :cluster, :lag]), do: Cluster.lag_sample()

  defp ets_size(table) do
    case :ets.info(table, :size) do
      :undefined -> raise AuroraMeter.LiveDashboard.NotStartedError, table: table
      size -> size
    end
  end

  # Postgres `sum(bigint)` is `numeric`, which Ecto decodes as a Decimal. The
  # page renders micro-USD as an integer, and `Decimal.new("2000000")` in a cell
  # labelled "total debt (micro-USD)" is a leak of the storage type into the
  # operator's screen.
  defp to_integer(nil), do: 0
  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value

  defp age_seconds(nil, _now), do: nil
  defp age_seconds(%DateTime{} = at, now), do: max(DateTime.diff(now, at, :second), 0)

  defp age_seconds(%NaiveDateTime{} = at, now),
    do: age_seconds(DateTime.from_naive!(at, "Etc/UTC"), now)

  defp repo, do: Config.repo()

  defp class_for(%AuroraMeter.LiveDashboard.NotStartedError{}), do: :not_started
  defp class_for(%DBConnection.ConnectionError{}), do: :database_unavailable
  defp class_for(%DBConnection.OwnershipError{}), do: :database_unavailable
  defp class_for(%Postgrex.Error{}), do: :database_unavailable
  defp class_for(%ArgumentError{}), do: :error
  defp class_for(_other), do: :error
end

defmodule AuroraMeter.LiveDashboard.NotStartedError do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch. A host mounts
  `AuroraMeter.LiveDashboard.Page`; this is what that page is built from.

  Raised inside `AuroraMeter.LiveDashboard.Sections` when a node-local table or
  process the section reads is absent, which means the supervision tree is not
  running. `read/1` converts it into `{:unavailable, :not_started}`; it is never
  raised out of this module.
  """

  defexception [:table]

  @impl Exception
  def message(%{table: table}),
    do: "the ETS table #{inspect(table)} does not exist, so AuroraMeter is not started"
end
