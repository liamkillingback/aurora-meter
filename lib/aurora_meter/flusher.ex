defmodule AuroraMeter.Flusher do
  @moduledoc """
  Periodically persists dirty ETS counters to the database, and once more on
  shutdown so a deploy never drops the last interval of usage.

  Each cycle snapshots the dirty-key set and, per key, deletes the dirty mark
  and **takes the pending delta** (what this node added since its last flush).
  Deltas are written with `value = value + Δ` (`AuroraMeter.Storage.add_counters/1`),
  so several nodes flushing the same counter add up instead of overwriting one
  another. The database returns the resulting totals; this node re-bases its
  view on them and announces them to the cluster (`AuroraMeter.Cluster`).

  Deleting the dirty mark per key (not the whole table) means a key re-marked
  mid-sweep survives to the next cycle. If the database write fails the taken
  deltas are put back and re-marked dirty, the error is logged and reported via
  `[:aurora_meter, :flush, :error]`, and the process keeps running; a database
  outage costs latency, not usage. Period counters go to
  `aurora_meter_counters`, day buckets to `aurora_meter_history`.
  """

  use GenServer

  require Logger

  alias AuroraMeter.Cluster
  alias AuroraMeter.Counter
  alias AuroraMeter.Storage

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Flushes dirty counters now, returning the number of keys persisted."
  @spec flush() :: {:ok, non_neg_integer()}
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

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
    taken =
      Counter.dirty_keys()
      |> Enum.map(fn key ->
        Counter.clear_dirty(key)
        {key, Counter.take_pending(key, :flush)}
      end)
      |> Enum.reject(fn {_key, delta} -> delta == 0 end)

    {history, period} = Enum.split_with(taken, fn {key, _} -> Counter.history_key?(key) end)

    counter_rows =
      for {{tenant_key, feature, period_start}, delta} <- period do
        %{tenant_key: tenant_key, feature: feature, period_start: period_start, delta: delta}
      end

    history_rows =
      for {{tenant_key, feature, {:day, date}}, delta} <- history do
        %{tenant_key: tenant_key, feature: feature, date: date, delta: delta}
      end

    try do
      totals = add(counter_rows, :counters, period) ++ add(history_rows, :history, history)
      Enum.each(totals, fn {key, total} -> Counter.rebase(key, total) end)
      Cluster.publish_totals(totals)

      delta_sum = taken |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      count = length(taken)
      :telemetry.execute([:aurora_meter, :flush], %{count: count, delta_sum: delta_sum}, %{})
      count
    rescue
      error ->
        Enum.each(taken, fn {key, delta} -> Counter.restore_pending(key, delta) end)

        Logger.error(
          "AuroraMeter flush failed (#{length(taken)} keys kept pending): " <>
            Exception.message(error)
        )

        :telemetry.execute([:aurora_meter, :flush, :error], %{count: length(taken)}, %{
          error: error
        })

        0
    end
  end

  # Writes deltas and pairs the returned totals back with their ETS keys.
  # Returned features are strings and period starts are second-precision, so
  # match on a normalised triple rather than on the struct.
  @spec add([map()], :counters | :history, [{Counter.key(), integer()}]) ::
          [{Counter.key(), integer()}]
  defp add([], _kind, _taken), do: []

  defp add(rows, kind, taken) do
    {:ok, returned} =
      case kind do
        :counters -> Storage.add_counters(rows)
        :history -> Storage.add_history(rows)
      end

    by_triple = Map.new(taken, fn {key, _delta} -> {triple(key), key} end)

    Enum.flat_map(returned, fn row ->
      case Map.fetch(by_triple, triple(row)) do
        {:ok, key} -> [{key, row.value}]
        :error -> []
      end
    end)
  end

  defp triple({tenant_key, feature, {:day, %Date{} = date}}),
    do: {tenant_key, to_string(feature), Date.to_iso8601(date)}

  defp triple({tenant_key, feature, %DateTime{} = period_start}),
    do: {tenant_key, to_string(feature), DateTime.to_unix(period_start)}

  defp triple(%{tenant_key: t, feature: f, date: %Date{} = d}),
    do: {t, to_string(f), Date.to_iso8601(d)}

  defp triple(%{tenant_key: t, feature: f, period_start: %DateTime{} = p}),
    do: {t, to_string(f), DateTime.to_unix(p)}
end
