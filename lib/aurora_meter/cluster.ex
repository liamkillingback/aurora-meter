defmodule AuroraMeter.Cluster do
  @moduledoc """
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

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias Phoenix.PubSub

  @topic "aurora_meter:cluster"

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

  @impl GenServer
  def init(_opts) do
    if enabled?(), do: :ok = PubSub.subscribe(Config.pubsub(), @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:aurora_meter, kind, origin, batch}, state) when kind in [:deltas, :totals] do
    handle_batch(kind, origin, batch)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:apply, kind, origin, batch}, _from, state) do
    handle_batch(kind, origin, batch)
    {:reply, :ok, state}
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
          base when is_integer(base) and total >= base -> Counter.rebase(key, total) == :ok
          _cold_or_stale -> false
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
end
