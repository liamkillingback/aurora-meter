defmodule AuroraMeter.Store do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Owns the ETS tables that back real-time metering.

  This process does nothing on the hot path. It merely creates and owns public,
  named ETS tables so that writers (`AuroraMeter.Counter`) and readers hit ETS
  directly without a GenServer bottleneck:

    * `:aurora_meter_counters`: `{tenant_key, feature, bucket} => value`, where
      `bucket` is a period start (`DateTime`) or `{:day, Date}` for history
    * `:aurora_meter_dirty`: counter keys changed since the last database flush
    * `:aurora_meter_touched`: counter keys changed since the last PubSub broadcast
    * `:aurora_meter_subscription_cache`: `tenant_key => {subscription, expires_at}`

  It also listens on the subscription-invalidation PubSub topic so that a plan
  change applied on any node evicts the cached subscription on every node.

  If this process crashes the tables are lost; its supervisor restarts it and the
  tables are recreated (counter state rehydrates lazily from the database).
  """

  use GenServer

  require Logger

  alias AuroraMeter.Clock
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

  @doc false
  @spec emit_gauge() :: :ok
  def emit_gauge do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :emit_gauge)
    end
  end

  @doc false
  @spec gauge_sample() :: {map(), integer()} | nil
  def gauge_sample do
    case Process.whereis(__MODULE__) do
      nil -> nil
      _pid -> GenServer.call(__MODULE__, :gauge_sample, 2_000)
    end
  end

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

    interval = Config.metrics_interval()
    schedule_gauge(interval)

    # The tables above were just created, so the buffer really is empty now.
    # `last_gauge` is `nil` rather than a zero-filled sample: nothing has been
    # sampled yet, and a zero would read as a healthy, current reading.
    {:ok, %{gauge_interval: interval, empty_since_ms: Clock.monotonic_ms(), last_gauge: nil}}
  end

  @impl GenServer
  def handle_call(:emit_gauge, _from, state) do
    {:reply, :ok, gauge(state)}
  end

  def handle_call(:gauge_sample, _from, state) do
    {:reply, state.last_gauge, state}
  end

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

      # `snapshot_at` is when this node took the deltas out of ETS, and it is
      # read by exactly two things: `AuroraMeter.Flusher`'s heartbeat, which
      # tells `AuroraMeter.Retention` how old the oldest batch this node still
      # holds is, and (from build unit 08a) the pending-batch gauge.
      #
      # `Clock.now/0` and not `Clock.db_now/0`, and the reason is the contract
      # rather than convenience: there is no database in this function and there
      # must not be one. `snapshot/0` runs inside the ETS owner while the hot
      # path writes around it, and a round trip to Postgres here would put the
      # database on the path that exists to keep the database off it. What the
      # value is compared against, and the bound that comparison relies on, is
      # `AuroraMeter.Retention`'s to state, and it does.
      #
      # `taken_at_ms` is the same instant read with the other clock, and both
      # are here on purpose. `snapshot_at` is compared against rows the
      # database stamped, so it is wall shaped. `taken_at_ms` is only ever
      # subtracted from another reading taken in this node's memory, which is
      # what `pending_batch_age_ms` is, and a wall clock that steps backwards
      # 439 ms (open-findings X100) would make that age negative or absurd.
      batch = %{
        id: Ecto.UUID.generate(),
        counters: counters,
        history: history,
        taken: taken,
        snapshot_at: Clock.now(),
        taken_at_ms: Clock.monotonic_ms()
      }

      :ets.insert(@flush_batches, {:pending, batch})
      batch
    end
  end

  @impl GenServer
  def handle_info({:aurora_meter, :subscription_changed, tenant_key}, state) do
    :ets.delete(@subscriptions, tenant_key)
    {:noreply, state}
  end

  def handle_info(:gauge, state) do
    {:noreply, gauge(state)}
  after
    # In an `after` so a raise inside `gauge/1` cannot stop the gauges for good.
    # A missed sample is a missing point on a graph; a dead timer is a gauge
    # that reports nothing for ever and looks exactly like a quiet system.
    schedule_gauge(state.gauge_interval)
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- the gauge --------------------------------------------------------------

  defp schedule_gauge(0), do: :ok

  defp schedule_gauge(interval) when interval > 0,
    do: Process.send_after(self(), :gauge, interval)

  # Three `:ets.info/2` reads and one `:ets.lookup/2`, all constant time. It
  # never calls `AuroraMeter.Counter.dirty_keys/0`, which materialises the whole
  # table: this runs in the process that answers `:snapshot_flush_batch`, so its
  # cost is the flush path's cost.
  defp gauge(state) do
    now_ms = Clock.monotonic_ms()
    dirty = :ets.info(@dirty, :size) || 0
    empty_since = empty_since(state.empty_since_ms, dirty, now_ms)
    {batch_age, batch_items} = pending(now_ms)

    measurements = %{
      dirty_keys: dirty,
      counter_keys: :ets.info(@counters, :size) || 0,
      oldest_pending_age_ms: age(empty_since, now_ms),
      pending_batch_age_ms: batch_age,
      pending_batch_items: batch_items
    }

    :telemetry.execute([:aurora_meter, :store, :gauge], measurements, %{node: node()})

    # The sample is retained with the monotonic instant it was taken at, so
    # `AuroraMeter.Telemetry.gauges/0` and the dashboard can report the figure
    # AND its age without emitting an event of their own on every refresh. It is
    # written only after the execute, so a handler that raises leaves the
    # previous sample in place rather than a half-published one.
    %{state | empty_since_ms: empty_since, last_gauge: {measurements, now_ms}}
  rescue
    error ->
      Logger.warning(
        "AuroraMeter.Store could not emit its gauge; the next tick will try again: " <>
          Exception.message(error)
      )

      state
  end

  # `empty_since_ms` is when the dirty set was last **observed** empty, which is
  # exactly what `oldest_pending_age_ms` reports time since. A tick that finds
  # it empty moves the mark to now; a tick that finds work leaves the mark where
  # it was, so the age is measured from the last moment the buffer was known to
  # be clear rather than from the moment somebody first noticed it was not.
  #
  # It is seeded at `init/1` because the tables are created empty in the same
  # function, so "the buffer was clear when this process started" is a fact and
  # not an assumption.
  #
  # There is no per-key timestamp and there deliberately never will be: adding
  # one would put a clock read and a wider tuple write into the counter
  # increment, which is the hot path, to buy precision nobody needs at a ten
  # second sampling interval. This understates a true age by up to one interval,
  # so it is a lower bound, and `docs/telemetry.md` says so.
  defp empty_since(_previous, 0, now_ms), do: now_ms
  defp empty_since(previous, _dirty, _now_ms), do: previous

  defp age(since_ms, now_ms), do: max(now_ms - since_ms, 0)

  defp batch_age(nil, _now_ms), do: 0
  defp batch_age(taken_at_ms, now_ms), do: age(taken_at_ms, now_ms)

  defp pending(now_ms) do
    case :ets.lookup(@flush_batches, :pending) do
      [{:pending, batch}] ->
        # `0` and not a guess when the key is absent: a batch snapshotted by an
        # older release and carried across a hot upgrade has no `taken_at_ms`,
        # and inventing an age for it would be a made-up number on a graph an
        # operator is about to act on.
        {batch_age(Map.get(batch, :taken_at_ms), now_ms), length(batch.taken)}

      [] ->
        {0, 0}
    end
  end
end
