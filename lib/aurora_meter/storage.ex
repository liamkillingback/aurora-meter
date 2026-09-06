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

  @callback upsert_counters([counter_row()]) :: :ok
  @callback load_counter(String.t(), atom() | String.t(), DateTime.t()) :: integer() | nil
  @callback upsert_history([history_row()]) :: :ok
  @callback load_history(String.t(), atom() | String.t(), Date.t()) :: integer() | nil
  @callback load_history_range(String.t(), atom() | String.t(), Date.t(), Date.t()) ::
              [history_point()]
  @callback get_subscription(String.t()) :: Subscription.t() | nil
  @callback put_subscription(map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  @callback insert_events([event_row()]) :: :ok
  @callback stream_counters(DateTime.t()) :: [Counter.t()]

  @doc "Upserts counter snapshots (absolute values) by `{tenant_key, feature, period_start}`."
  @spec upsert_counters([counter_row()]) :: :ok
  def upsert_counters(rows), do: impl().upsert_counters(rows)

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
