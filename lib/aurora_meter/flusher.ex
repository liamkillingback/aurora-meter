defmodule AuroraMeter.Flusher do
  @moduledoc """
  Persists buffered usage in idempotent database batches.

  Each immutable batch has a UUID. Storage commits its receipt and counter
  and history deltas together. An uncertain response retries the same batch,
  even if another node has since written those counters.

  Pending batches live in Store-owned ETS and survive a Flusher restart.
  Loss of the Store or VM can lose unflushed usage, as with other buffered
  metering; use durable tracking when that loss is unacceptable.
  """
  use GenServer
  require Logger
  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Flushes pending usage. An error retains the batch for an idempotent retry.

  ## Examples

      {:ok, count} = AuroraMeter.Flusher.flush()
      is_integer(count)
      #=> true

  """
  @spec flush() :: {:ok, non_neg_integer()} | {:error, term()}
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    interval = Config.flush_interval()
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:flush, state) do
    do_flush()
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, do_flush(), state}

  @impl true
  def terminate(_reason, _state) do
    with {:ok, _} <- do_flush(), do: do_flush()
    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :flush, interval)

  defp do_flush do
    case batch() do
      nil -> {:ok, 0}
      batch -> persist(batch)
    end
  rescue
    error -> failed(Exception.message(error))
  catch
    kind, reason -> failed({kind, reason})
  end

  defp batch do
    case :ets.lookup(Store.flush_batches_table(), :pending) do
      [{:pending, batch}] -> batch
      [] -> Store.snapshot_flush_batch()
    end
  end

  defp persist(batch) do
    case Storage.flush_batch(batch.id, batch.counters, batch.history) do
      {:ok, %{counters: counters, history: history}} ->
        originals = Map.new(batch.taken, fn {key, _} -> {triple(key), key} end)
        totals = Enum.map(counters ++ history, &{Map.fetch!(originals, triple(&1)), &1.value})
        Enum.each(totals, fn {key, total} -> Counter.rebase(key, total) end)
        :ets.delete(Store.flush_batches_table(), :pending)
        Cluster.publish_totals(totals)
        count = length(batch.taken)
        delta_sum = Enum.sum(Enum.map(batch.taken, &elem(&1, 1)))
        :telemetry.execute([:aurora_meter, :flush], %{count: count, delta_sum: delta_sum}, %{})
        {:ok, count}

      {:error, reason} ->
        failed(reason)
    end
  end

  defp failed(reason) do
    Logger.error("AuroraMeter flush failed; the same batch will be retried: #{inspect(reason)}")

    count =
      case :ets.lookup(Store.flush_batches_table(), :pending) do
        [{:pending, batch}] -> length(batch.taken)
        [] -> 0
      end

    :telemetry.execute([:aurora_meter, :flush, :error], %{count: count}, %{error: reason})
    {:error, reason}
  end

  defp triple({tenant, feature, {:day, date}}),
    do: {tenant, to_string(feature), Date.to_iso8601(date)}

  defp triple({tenant, feature, %DateTime{} = period}),
    do: {tenant, to_string(feature), DateTime.to_unix(period)}

  defp triple(%{tenant_key: tenant, feature: feature, date: date}),
    do: {tenant, to_string(feature), Date.to_iso8601(date)}

  defp triple(%{tenant_key: tenant, feature: feature, period_start: period}),
    do: {tenant, to_string(feature), DateTime.to_unix(period)}
end
