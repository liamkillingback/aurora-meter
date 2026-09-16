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
  alias AuroraMeter.Clock
  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Retention
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  # How often an **idle** node refreshes its heartbeat. A node with no traffic
  # still has to prove it is alive, or its row goes stale and blocks a receipt
  # prune for ever; but writing one on every tick would be 17,280 writes a day
  # to say nothing changed. A successful or failed flush writes one regardless
  # of this interval, because those two carry news.
  @heartbeat_interval 60_000

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
    {:ok, %{interval: interval, heartbeat_at: nil, heartbeat_warned?: false}}
  end

  @impl true
  def handle_info(:flush, state) do
    {_result, state} = do_flush(state)
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state) do
    {result, state} = do_flush(state)
    {:reply, result, state}
  end

  @impl true
  def terminate(_reason, state) do
    case do_flush(state) do
      {{:ok, _}, state} -> do_flush(state)
      _failed -> :ok
    end

    :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :flush, interval)

  defp do_flush(state) do
    case batch() do
      nil -> {{:ok, 0}, idle_heartbeat(state)}
      batch -> persist(batch, state)
    end
  rescue
    error -> failed(Exception.message(error), state)
  catch
    kind, reason -> failed({kind, reason}, state)
  end

  defp batch do
    case :ets.lookup(Store.flush_batches_table(), :pending) do
      [{:pending, batch}] -> batch
      [] -> Store.snapshot_flush_batch()
    end
  end

  # One span around the storage write, and the two existing events left exactly
  # as they were. A host attached to `[:aurora_meter, :flush]` or
  # `[:aurora_meter, :flush, :error]` sees no change at all; a host that wants
  # flush *latency*, which is the single most useful operational number the
  # buffered path has, attaches to `[:aurora_meter, :flush, :stop]`.
  #
  # An `{:error, reason}` from storage is a result and not an exception, so it
  # is `:stop` with `result: :error` rather than `:exception`. A raise is
  # `:exception`, re-raised by `:telemetry.span/3` into `do_flush/1`'s rescue,
  # which emits the legacy error event as it always did.
  defp flush_batch(batch) do
    metadata = %{
      batch_id: batch.id,
      counter_rows: length(batch.counters),
      history_rows: length(batch.history)
    }

    :telemetry.span([:aurora_meter, :flush], metadata, fn ->
      result = Storage.flush_batch(batch.id, batch.counters, batch.history)

      measurements = %{
        count: length(batch.taken),
        delta_sum: Enum.sum(Enum.map(batch.taken, &elem(&1, 1)))
      }

      {result, measurements, Map.put(metadata, :result, span_result(result))}
    end)
  end

  defp span_result({:ok, _}), do: :ok
  defp span_result(_error), do: :error

  defp persist(batch, state) do
    case flush_batch(batch) do
      {:ok, %{counters: counters, history: history}} ->
        originals = Map.new(batch.taken, fn {key, _} -> {triple(key), key} end)
        totals = Enum.map(counters ++ history, &{Map.fetch!(originals, triple(&1)), &1.value})
        Enum.each(totals, fn {key, total} -> Counter.rebase(key, total) end)
        :ets.delete(Store.flush_batches_table(), :pending)
        Cluster.publish_totals(totals)
        count = length(batch.taken)
        delta_sum = Enum.sum(Enum.map(batch.taken, &elem(&1, 1)))
        :telemetry.execute([:aurora_meter, :flush], %{count: count, delta_sum: delta_sum}, %{})

        # After the pending entry is cleared, never before: the heartbeat says
        # "this node holds nothing older than now", and it must not be able to
        # say so while the batch is still in the table.
        {{:ok, count}, heartbeat(state, :idle)}

      {:error, reason} ->
        failed(reason, state)
    end
  end

  defp failed(reason, state) do
    Logger.error("AuroraMeter flush failed; the same batch will be retried: #{inspect(reason)}")

    pending =
      case :ets.lookup(Store.flush_batches_table(), :pending) do
        [{:pending, batch}] -> batch
        [] -> nil
      end

    count = if pending, do: length(pending.taken), else: 0

    :telemetry.execute([:aurora_meter, :flush, :error], %{count: count}, %{error: reason})

    # Best effort, and the reason it can be: when the database is what failed,
    # this write fails too. That is exactly the case the staleness half of
    # `AuroraMeter.Retention`'s receipt rule covers, because a heartbeat that
    # stopped being written is a heartbeat that goes stale and blocks.
    state = if pending, do: heartbeat(state, {:pending, pending}), else: state

    {{:error, reason}, state}
  end

  # -- the heartbeat ----------------------------------------------------------

  # An idle tick has no news, so it refreshes at most once per
  # `@heartbeat_interval`. `Clock.monotonic_ms/0` and not `now/0`: this is an
  # in-memory span inside one process and nothing else ever reads it
  # (`AuroraMeter.Clock`).
  defp idle_heartbeat(%{heartbeat_at: at} = state) do
    if is_nil(at) or Clock.monotonic_ms() - at >= @heartbeat_interval do
      heartbeat(state, :idle)
    else
      state
    end
  end

  # A heartbeat must never be able to fail a flush. `record_flush_state/2`
  # already catches everything, and the result is logged once at `:warning` and
  # at `:debug` after that, so a database below core schema version 7 says so
  # once rather than every five seconds.
  defp heartbeat(state, what) do
    case Retention.record_flush_state(what) do
      :ok ->
        %{state | heartbeat_at: Clock.monotonic_ms()}

      {:error, reason} ->
        state = warn_heartbeat(state, reason)
        %{state | heartbeat_at: Clock.monotonic_ms()}
    end
  end

  defp warn_heartbeat(%{heartbeat_warned?: true} = state, reason) do
    Logger.debug("AuroraMeter flush heartbeat write failed again: #{inspect(reason)}")
    state
  end

  defp warn_heartbeat(state, reason) do
    Logger.warning("""
    AuroraMeter could not write its flush heartbeat: #{inspect(reason)}

    The flush itself is unaffected. What this costs is retention: a node whose \
    heartbeat is stale blocks AuroraMeter.Retention.prune(only: [:flush_receipts]), \
    which is the safe direction. A database below core schema version 7 has no \
    aurora_meter_checkpoints table and will report this on every flush; later \
    occurrences are logged at :debug.
    """)

    %{state | heartbeat_warned?: true}
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
