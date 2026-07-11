defmodule AuroraMeter.Flusher do
  @moduledoc """
  Periodically persists dirty ETS counters to the database.

  Each cycle snapshots the dirty-key set and, per key, deletes the dirty mark,
  reads the current ETS value, and batches an absolute-value upsert. Deleting
  per key (not the whole table) means a key re-marked mid-sweep survives to the
  next cycle; absolute-value upserts make repeated flushes idempotent.
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
    rows =
      Enum.map(Counter.dirty_keys(), fn {tenant_key, feature, period_start} = key ->
        Counter.clear_dirty(key)

        %{
          tenant_key: tenant_key,
          feature: feature,
          period_start: period_start,
          value: Counter.value(tenant_key, feature, period_start)
        }
      end)

    if rows != [], do: Storage.upsert_counters(rows)

    :telemetry.execute([:aurora_meter, :flush], %{count: length(rows)}, %{})
    length(rows)
  end
end
