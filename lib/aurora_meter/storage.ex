defmodule AuroraMeter.Storage do
  @moduledoc """
  Behaviour for persisting Aurora Meter state, plus dispatch helpers that route to
  the configured adapter (`AuroraMeter.Config.storage/0`, default
  `AuroraMeter.Storage.Ecto`).

  Only a Postgres/Ecto adapter ships in v1; this behaviour keeps the door open for
  others without building through it now.
  """

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Subscriptions

  @typedoc "A counter snapshot to persist. `feature` may be an atom or string."
  @type counter_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:period_start) => DateTime.t(),
          required(:value) => integer()
        }

  @typedoc "A day-bucket snapshot to persist."
  @type history_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:date) => Date.t(),
          required(:value) => integer()
        }

  @typedoc "A day bucket as read back: `%{date: Date.t(), value: integer()}`."
  @type history_point :: %{date: Date.t(), value: integer()}

  @typedoc "A raw usage event to persist."
  @type event_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          optional(:quantity) => integer(),
          optional(:metadata) => map()
        }

  @typedoc "A counter delta to add: `value = value + delta`."
  @type counter_delta :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:period_start) => DateTime.t(),
          required(:delta) => integer()
        }

  @typedoc "A day-bucket delta to add."
  @type history_delta :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:date) => Date.t(),
          required(:delta) => integer()
        }

  @typedoc "A total as returned after adding deltas. `feature` is a string."
  @type counter_total :: %{
          tenant_key: String.t(),
          feature: String.t(),
          period_start: DateTime.t(),
          value: integer()
        }

  @typedoc "A day-bucket total as returned after adding deltas."
  @type history_total :: %{
          tenant_key: String.t(),
          feature: String.t(),
          date: Date.t(),
          value: integer()
        }

  @callback upsert_counters([counter_row()]) :: :ok
  @callback add_counters([counter_delta()]) :: {:ok, [counter_total()]}
  @callback flush_batch(Ecto.UUID.t(), [counter_delta()], [history_delta()]) ::
              {:ok, %{counters: [counter_total()], history: [history_total()]}} | {:error, term()}
  @callback load_counter(String.t(), atom() | String.t(), DateTime.t()) :: integer() | nil
  @callback upsert_history([history_row()]) :: :ok
  @callback add_history([history_delta()]) :: {:ok, [history_total()]}
  @callback load_history(String.t(), atom() | String.t(), Date.t()) :: integer() | nil
  @callback load_history_range(String.t(), atom() | String.t(), Date.t(), Date.t()) ::
              [history_point()]
  @callback get_subscription(String.t()) :: Subscription.t() | nil
  @callback put_subscription(map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  @callback insert_events([event_row()]) :: :ok
  @callback stream_counters(DateTime.t()) :: [Counter.t()]

  @doc """
  Sets counter snapshots to absolute values by `{tenant_key, feature,
  period_start}`. For backfills and test fixtures; the flusher uses
  `add_counters/1` so that nodes add up instead of overwriting one another.
  """
  @spec upsert_counters([counter_row()]) :: :ok
  def upsert_counters(rows), do: impl().upsert_counters(rows)

  @doc """
  Adds deltas to counters (`value = value + delta`, inserting at `delta` when
  the row is new) and returns the resulting totals. This is what makes
  cluster-wide counting correct: each node writes only what it added.
  """
  @spec add_counters([counter_delta()]) :: {:ok, [counter_total()]}
  def add_counters([]), do: {:ok, []}
  def add_counters(rows), do: impl().add_counters(rows)

  @doc "Adds deltas to day buckets and returns the resulting totals. See `add_counters/1`."
  @spec add_history([history_delta()]) :: {:ok, [history_total()]}
  def add_history([]), do: {:ok, []}
  def add_history(rows), do: impl().add_history(rows)

  @doc """
  Atomically applies counter and history deltas once for `batch_id`.

  Adapters must persist the receipt and both sets of deltas in one transaction.
  A retry returns the current totals without applying either delta again.

  ## Examples

      {:ok, %{counters: [], history: []}} = AuroraMeter.Storage.flush_batch(Ecto.UUID.generate(), [], [])

  """
  @spec flush_batch(Ecto.UUID.t(), [counter_delta()], [history_delta()]) ::
          {:ok, %{counters: [counter_total()], history: [history_total()]}} | {:error, term()}
  def flush_batch(id, counters, history), do: impl().flush_batch(id, counters, history)

  @doc "Loads a single flushed counter value, or `nil` if absent."
  @spec load_counter(String.t(), atom() | String.t(), DateTime.t()) :: integer() | nil
  def load_counter(tenant_key, feature, period_start),
    do: impl().load_counter(tenant_key, feature, period_start)

  @doc "Upserts day-bucket snapshots (absolute values) by `{tenant_key, feature, date}`."
  @spec upsert_history([history_row()]) :: :ok
  def upsert_history(rows), do: impl().upsert_history(rows)

  @doc "Loads a single flushed day-bucket value, or `nil` if absent."
  @spec load_history(String.t(), atom() | String.t(), Date.t()) :: integer() | nil
  def load_history(tenant_key, feature, date), do: impl().load_history(tenant_key, feature, date)

  @doc "Loads the flushed day buckets for a feature between two dates (inclusive), oldest first."
  @spec load_history_range(String.t(), atom() | String.t(), Date.t(), Date.t()) ::
          [history_point()]
  def load_history_range(tenant_key, feature, from, to),
    do: impl().load_history_range(tenant_key, feature, from, to)

  @doc "Fetches a tenant's subscription straight from storage (uncached), or `nil`."
  @spec get_subscription(String.t()) :: Subscription.t() | nil
  def get_subscription(tenant_key), do: impl().get_subscription(tenant_key)

  @doc """
  Inserts or updates a tenant's subscription (upsert on `tenant_key`) and evicts
  it from the subscription cache on every node.
  """
  @spec put_subscription(map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def put_subscription(attrs) do
    result = impl().put_subscription(attrs)

    with {:ok, %Subscription{tenant_key: tenant_key}} <- result do
      Subscriptions.invalidate(tenant_key)
    end

    result
  end

  @doc "Appends raw usage events (durable mode / audit)."
  @spec insert_events([event_row()]) :: :ok
  def insert_events(rows), do: impl().insert_events(rows)

  @doc "Returns all counter snapshots for a period (used by Pro rollups)."
  @spec stream_counters(DateTime.t()) :: [Counter.t()]
  def stream_counters(period_start), do: impl().stream_counters(period_start)

  @spec impl() :: module()
  defp impl, do: AuroraMeter.Config.storage()
end
