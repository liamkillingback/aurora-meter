defmodule AuroraMeter.Cluster do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Keeps every node's counters converging on the same totals.

  Each node meters into its own ETS table. Two things make the cluster agree:

    * **Delta gossip.** Every broadcaster tick this node publishes the deltas
      it accumulated (`pending_gossip`) on the `"aurora_meter:cluster"` topic;
      other nodes add them to their own view (`AuroraMeter.Counter.apply_remote/2`).
      Convergence is one `:broadcast_interval` (1 s by default).
    * **Total announcements.** Every flush writes deltas to Postgres and gets
      the authoritative totals back; this node re-bases on them at once and
      publishes them so the others re-base too
      (`AuroraMeter.Counter.rebase/2`). Anything gossip missed heals within one
      `:flush_interval` (5 s by default). Announced totals are applied only
      upward (a late announcement never drags a fresher view back); this node's
      own flush re-bases unconditionally.

  Messages from this node are ignored (its own bumps are already in its view).
  With `config :aurora_meter, cluster_sync: false` nothing is published or
  applied and tenant broadcasts fan out cluster-wide as before. A
  non-distributed `Phoenix.PubSub` is fine: every message is then local and
  dropped, so a single node behaves exactly as it did.
  """

  use GenServer

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Store
  alias Phoenix.PubSub

  @topic "aurora_meter:cluster"

  # A peer heard from less recently than this many BROADCAST intervals ago
  # leaves the map. The broadcast interval and not the metrics interval, because
  # the broadcast interval is the cadence peers actually gossip at, it is always
  # non-zero, and a host that has set `metrics_interval: 0` and drives the gauge
  # itself still needs the map bounded: a scheduler that gives each pod its own
  # node name rotates them for the life of the deployment.
  @peer_intervals 10

  # The `remote` column of `{key, value, pending_flush, pending_gossip, remote,
  # reserved}`: how much of this key's value came from another node and has not
  # been superseded by an authoritative flush total.
  @unreconciled_spec [{{:_, :_, :_, :_, :"$1", :_}, [{:"=/=", :"$1", 0}], [true]}]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic nodes exchange deltas and totals on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Whether cross-node sync is on (`:cluster_sync`, default `true`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.cluster_sync?()

  @doc "Publishes this node's deltas (`[{key, delta}]`) to the other nodes."
  @spec publish_deltas([{Counter.key(), integer()}]) :: :ok
  def publish_deltas([]), do: :ok

  def publish_deltas(deltas) do
    if enabled?() do
      PubSub.broadcast(Config.pubsub(), @topic, {:aurora_meter, :deltas, node(), deltas})
    end

    :ok
  end

  @doc "Publishes authoritative totals (`[{key, total}]`) from a flush to the other nodes."
  @spec publish_totals([{Counter.key(), integer()}]) :: :ok
  def publish_totals([]), do: :ok

  def publish_totals(totals) do
    if enabled?() do
      PubSub.broadcast(Config.pubsub(), @topic, {:aurora_meter, :totals, node(), totals})
    end

    :ok
  end

  @doc """
  Applies a batch as if it had arrived from `origin`, synchronously. Used by
  `AuroraMeter.Test.simulate_node/3` and `simulate_flush/2`.
  """
  @spec apply(:deltas | :totals, node(), [{Counter.key(), integer()}]) :: :ok
  def apply(kind, origin, batch) when kind in [:deltas, :totals] do
    GenServer.call(__MODULE__, {:apply, kind, origin, batch})
  end

  @doc false
  @spec emit_lag() :: :ok
  def emit_lag do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :emit_lag)
    end
  end

  @impl GenServer
  def init(_opts) do
    interval = Config.metrics_interval()

    if enabled?() do
      :ok = PubSub.subscribe(Config.pubsub(), @topic)
      schedule_lag(interval)
    end

    {:ok, %{lag_interval: interval, peers: %{}, last_message_ms: nil}}
  end

  @impl GenServer
  def handle_info({:aurora_meter, kind, origin, batch}, state) when kind in [:deltas, :totals] do
    handle_batch(kind, origin, batch)
    {:noreply, note_peer(state, origin)}
  end

  def handle_info(:lag, state) do
    # `enabled?/0` is read on the tick and not only at init: a host that turns
    # cluster_sync off at runtime should stop reporting cluster lag, and a lag
    # of zero from a node that is not clustered is a number an operator would
    # read as convergence.
    {:noreply, maybe_lag(state)}
  after
    schedule_lag(state.lag_interval)
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:emit_lag, _from, state) do
    {:reply, :ok, maybe_lag(state)}
  end

  def handle_call({:apply, kind, origin, batch}, _from, state) do
    handle_batch(kind, origin, batch)
    {:reply, :ok, note_peer(state, origin)}
  end

  defp handle_batch(_kind, origin, _batch) when origin == node(), do: :ok

  defp handle_batch(:deltas, origin, deltas) do
    applied = Enum.count(deltas, fn {key, delta} -> Counter.apply_remote(key, delta) == :ok end)
    emit(:deltas, origin, applied)
  end

  defp handle_batch(:totals, origin, totals) do
    applied =
      Enum.count(totals, fn {key, total} ->
        case Counter.base(key) do
          # Only move forward: a late announcement must not undo a fresher
          # base; the next flush re-bases this node unconditionally anyway.
          base when is_integer(base) and total >= base ->
            Counter.rebase(key, total, :gossip) == :ok

          _cold_or_stale ->
            false
        end
      end)

    emit(:totals, origin, applied)
  end

  defp emit(kind, origin, count) do
    :telemetry.execute([:aurora_meter, :cluster, :apply], %{count: count}, %{
      kind: kind,
      origin: origin
    })
  end

  # -- the lag gauge ----------------------------------------------------------

  defp schedule_lag(0), do: :ok
  defp schedule_lag(interval) when interval > 0, do: Process.send_after(self(), :lag, interval)

  # This node's own messages are not gossip: `handle_batch/3` drops them, and a
  # peer map containing self would report one peer on a single-node deployment.
  defp note_peer(state, origin) when origin == node(), do: state

  defp note_peer(state, origin) do
    now_ms = Clock.monotonic_ms()
    %{state | peers: Map.put(state.peers, origin, now_ms), last_message_ms: now_ms}
  end

  defp maybe_lag(state), do: if(enabled?(), do: lag(state), else: state)

  # The wire format `{:aurora_meter, kind, node(), batch}` carries no timestamp,
  # so true end to end gossip lag is not measurable without changing it, and
  # changing it would make a new node's messages fall through an old node's
  # catch-all clause during a rolling upgrade. What is reported instead is
  # locally observable: how many peers this node has heard from, how long since
  # the last one, and how many keys still carry value from a peer that no flush
  # total has superseded.
  #
  # Every age here is `Clock.monotonic_ms/0`. They are spans inside one node's
  # memory, never persisted and never compared across nodes, which is the one
  # reading that cannot step backwards (open-findings X100).
  defp lag(state) do
    now_ms = Clock.monotonic_ms()
    peers = prune_peers(state.peers, now_ms)

    measurements =
      %{
        peers: map_size(peers),
        since_last_message_ms: since(state.last_message_ms, now_ms)
      }
      |> put_unreconciled()

    :telemetry.execute([:aurora_meter, :cluster, :lag], measurements, %{node: node()})

    # The pruned map is written back, not merely counted: a map that is filtered
    # for the report and kept in full in the state reports the right number and
    # grows for ever anyway, which is the leak this prune exists to close.
    %{state | peers: peers}
  rescue
    error ->
      Logger.warning(
        "AuroraMeter.Cluster could not emit its lag gauge; the next tick will try again: " <>
          Exception.message(error)
      )

      state
  end

  defp prune_peers(peers, now_ms) do
    horizon = @peer_intervals * Config.broadcast_interval()
    :maps.filter(fn _node, seen_ms -> now_ms - seen_ms <= horizon end, peers)
  end

  # `-1` and not `0` for "no peer has ever been heard from". Zero on this
  # measurement means "a message arrived just now", which is the opposite, and
  # a dashboard cannot tell a silent cluster from a busy one if both read zero.
  defp since(nil, _now_ms), do: -1
  defp since(last_ms, now_ms), do: max(now_ms - last_ms, 0)

  # A select_count over the counters table is a scan, so it is bounded by
  # `:metrics_scan_ceiling` and **omitted** above it rather than reported as
  # zero. Absent is a gap on a graph; zero is a claim that everything has
  # converged, and this gauge exists precisely for the case where it has not.
  #
  # The design this replaces kept a running `{:remote_keys, n}` counter updated
  # from `Counter.apply_remote/2` and `Counter.rebase/3`. It is exact and it is
  # constant time, and it puts bookkeeping whose only consumer is a graph onto
  # the gossip apply path, where getting the cold-to-non-zero and
  # rebase-clears-remote transitions slightly wrong yields a plausible wrong
  # number rather than an obvious failure. 08a's own build document records
  # this ceiling as the sanctioned fallback.
  defp put_unreconciled(measurements) do
    ceiling = Config.metrics_scan_ceiling()
    table = Store.counters_table()
    size = :ets.info(table, :size)

    if is_integer(size) and ceiling > 0 and size <= ceiling do
      Map.put(measurements, :unreconciled_keys, :ets.select_count(table, @unreconciled_spec))
    else
      measurements
    end
  end
end
