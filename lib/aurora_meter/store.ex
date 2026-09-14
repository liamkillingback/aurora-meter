defmodule AuroraMeter.Store do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Owns the ETS tables that back real-time metering.

  This process does nothing on the hot path — it merely creates and owns public,
  named ETS tables so that writers (`AuroraMeter.Counter`) and readers hit ETS
  directly without a GenServer bottleneck:

    * `:aurora_meter_counters` — `{tenant_key, feature, bucket} => value`, where
      `bucket` is a period start (`DateTime`) or `{:day, Date}` for history
    * `:aurora_meter_dirty` — counter keys changed since the last database flush
    * `:aurora_meter_touched` — counter keys changed since the last PubSub broadcast
    * `:aurora_meter_subscription_cache` — `tenant_key => {subscription, expires_at}`

  It also listens on the subscription-invalidation PubSub topic so that a plan
  change applied on any node evicts the cached subscription on every node.

  If this process crashes the tables are lost; its supervisor restarts it and the
  tables are recreated (counter state rehydrates lazily from the database).
  """

  use GenServer

  alias AuroraMeter.Config
  alias AuroraMeter.Counter

  @counters :aurora_meter_counters
  @dirty :aurora_meter_dirty
  @touched :aurora_meter_touched
  @subscriptions :aurora_meter_subscription_cache
  @flush_batches :aurora_meter_flush_batches
  @invalidation_topic "aurora_meter:subscriptions"

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The ETS table holding counter values."
  @spec counters_table() :: atom()
  def counters_table, do: @counters

  @doc "The ETS table holding the dirty-key set (pending database flush)."
  @spec dirty_table() :: atom()
  def dirty_table, do: @dirty

  @doc "The ETS table holding the touched-key set (pending PubSub broadcast)."
  @spec touched_table() :: atom()
  def touched_table, do: @touched

  @doc "The ETS table caching subscription lookups."
  @spec subscription_cache_table() :: atom()
  def subscription_cache_table, do: @subscriptions

  @doc false
  @spec flush_batches_table() :: atom()
  def flush_batches_table, do: @flush_batches

  @doc false
  @spec snapshot_flush_batch() :: map() | nil
  def snapshot_flush_batch, do: GenServer.call(__MODULE__, :snapshot_flush_batch)

  @doc "The PubSub topic on which subscription changes are announced."
  @spec invalidation_topic() :: String.t()
  def invalidation_topic, do: @invalidation_topic

  @impl GenServer
  def init(_opts) do
    :ets.new(@counters, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@dirty, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@touched, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@subscriptions, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@flush_batches, [:set, :public, :named_table])

    :ok = Phoenix.PubSub.subscribe(Config.pubsub(), @invalidation_topic)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:snapshot_flush_batch, _from, state) do
    # Taking deltas and publishing their batch belong to the ETS owner. Killing
    # only the Flusher must not strand deltas between these two operations.
    batch =
      case :ets.lookup(@flush_batches, :pending) do
        [{:pending, batch}] -> batch
        [] -> snapshot()
      end

    {:reply, batch, state}
  end

  defp snapshot do
    taken =
      Counter.dirty_keys()
      |> Enum.map(fn key ->
        Counter.clear_dirty(key)
        {key, Counter.take_pending(key, :flush)}
      end)
      |> Enum.reject(fn {_key, delta} -> delta == 0 end)

    if taken != [] do
      counters =
        for {{tenant, feature, %DateTime{} = period}, delta} <- taken do
          %{tenant_key: tenant, feature: feature, period_start: period, delta: delta}
        end

      history =
        for {{tenant, feature, {:day, date}}, delta} <- taken do
          %{tenant_key: tenant, feature: feature, date: date, delta: delta}
        end

      batch = %{id: Ecto.UUID.generate(), counters: counters, history: history, taken: taken}
      :ets.insert(@flush_batches, {:pending, batch})
      batch
    end
  end

  @impl GenServer
  def handle_info({:aurora_meter, :subscription_changed, tenant_key}, state) do
    :ets.delete(@subscriptions, tenant_key)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
