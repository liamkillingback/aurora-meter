defmodule AuroraMeter.Broadcaster do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Fans live counter values out over `Phoenix.PubSub` on an interval, decoupled
  from the (slower) database flush, and ships this node's deltas to the other
  nodes.

  Each tick, for every counter touched since the previous tick:

    * the delta this node accumulated since its last tick (`pending_gossip`) is
      taken and collected; one `{:aurora_meter, :deltas, node, [...]}` message
      per tick goes to `AuroraMeter.Cluster` on every other node
    * period counters are broadcast on their tenant topic
      (`"aurora_meter:tenant:" <> tenant_key`) as
      `{:aurora_meter, :usage, %{feature:, value:, period_start:}}`

  With cluster sync on (the default) tenant broadcasts are **node-local**: every
  node informs its own LiveViews from its own converged view, so a browser
  connected to node B never receives node A's slightly different number. With
  `cluster_sync: false` they fan out cluster-wide as before.

  The touched set is independent of the flusher's dirty set, so a flush landing
  between a track and the next tick can never swallow an update.
  """

  use GenServer

  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias Phoenix.PubSub

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Broadcasts touched counters now, returning `:ok`."
  @spec broadcast_now() :: :ok
  def broadcast_now, do: GenServer.call(__MODULE__, :broadcast)

  @doc "The PubSub topic for a tenant's usage updates."
  @spec topic(String.t()) :: String.t()
  def topic(tenant_key), do: "aurora_meter:tenant:" <> tenant_key

  @impl GenServer
  def init(_opts) do
    interval = Config.broadcast_interval()
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:broadcast, state) do
    do_broadcast()
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:broadcast, _from, state), do: {:reply, do_broadcast(), state}

  @spec schedule(pos_integer()) :: reference()
  defp schedule(interval), do: Process.send_after(self(), :broadcast, interval)

  @spec do_broadcast() :: :ok
  defp do_broadcast do
    cluster? = Cluster.enabled?()

    {count, deltas} =
      Enum.reduce(Counter.touched_keys(), {0, []}, fn key, {count, deltas} ->
        Counter.clear_touched(key)
        deltas = take_gossip(key, deltas)

        if Counter.history_key?(key) do
          {count, deltas}
        else
          publish_usage(key, cluster?)
          {count + 1, deltas}
        end
      end)

    Cluster.publish_deltas(deltas)
    :telemetry.execute([:aurora_meter, :broadcast], %{count: count, deltas: length(deltas)}, %{})
    :ok
  end

  defp take_gossip(key, deltas) do
    case Counter.take_pending(key, :gossip) do
      0 -> deltas
      delta -> [{key, delta} | deltas]
    end
  end

  defp publish_usage({tenant_key, feature, period_start}, cluster?) do
    value = Counter.value(tenant_key, feature, period_start)

    message =
      {:aurora_meter, :usage, %{feature: feature, value: value, period_start: period_start}}

    if cluster? do
      PubSub.local_broadcast(Config.pubsub(), topic(tenant_key), message)
    else
      PubSub.broadcast(Config.pubsub(), topic(tenant_key), message)
    end
  end
end
