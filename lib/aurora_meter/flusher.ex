defmodule AuroraMeter.Flusher do
  @moduledoc """
  Periodically persists dirty ETS counters to the database, and once more on
  shutdown so a deploy never drops the last interval of usage.

  Each cycle snapshots the dirty-key set and, per key, deletes the dirty mark,
  reads the current ETS value, and batches an absolute-value upsert. Deleting
  per key (not the whole table) means a key re-marked mid-sweep survives to the
  next cycle; absolute-value upserts make repeated flushes idempotent. Period
  counters go to `aurora_meter_counters`, day buckets to `aurora_meter_history`.
  """

  use GenServer

  alias AuroraMeter.Counter
  alias AuroraMeter.Storage

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Flushes dirty counters now, returning the number persisted."
  @spec flush() :: {:ok, non_neg_integer()}
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(_opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown and the final
    # flush happens before the VM (and the repo) go away.
    Process.flag(:trap_exit, true)
    interval = AuroraMeter.Config.flush_interval()
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:flush, state) do
    do_flush()
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, {:ok, do_flush()}, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    do_flush()
    :ok
  end

  @spec schedule(pos_integer()) :: reference()
  defp schedule(interval), do: Process.send_after(self(), :flush, interval)

  @spec do_flush() :: non_neg_integer()
  defp do_flush do
    {history_keys, period_keys} = Enum.split_with(Counter.dirty_keys(), &Counter.history_key?/1)

    counter_rows =
      Enum.map(period_keys, fn {tenant_key, feature, period_start} = key ->
        Counter.clear_dirty(key)

        %{
          tenant_key: tenant_key,
          feature: feature,
          period_start: period_start,
          value: Counter.value(tenant_key, feature, period_start)
        }
      end)

    history_rows =
      Enum.map(history_keys, fn {tenant_key, feature, {:day, date}} = key ->
        Counter.clear_dirty(key)

        %{
          tenant_key: tenant_key,
          feature: feature,
          date: date,
          value: Counter.day_value(tenant_key, feature, date)
        }
      end)

    if counter_rows != [], do: Storage.upsert_counters(counter_rows)
    if history_rows != [], do: Storage.upsert_history(history_rows)

    count = length(counter_rows) + length(history_rows)
    :telemetry.execute([:aurora_meter, :flush], %{count: count}, %{})
    count
  end
end
