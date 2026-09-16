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
      `{:aurora_meter, :usage, %{tenant_key:, feature:, value:, period_start:}}`

  With cluster sync on (the default) tenant broadcasts are **node-local**: every
  node informs its own LiveViews from its own converged view, so a browser
  connected to node B never receives node A's slightly different number. With
  `cluster_sync: false` they fan out cluster-wide as before.

  The touched set is independent of the flusher's dirty set, so a flush landing
  between a track and the next tick can never swallow an update.
  """

  use GenServer

  require Logger

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

  # **The tick survives a tick it cannot serve** (`open-findings.md` X348).
  #
  # `do_broadcast/0` opens with `Counter.touched_keys/0`, which is
  # `:ets.tab2list/1` on a table `AuroraMeter.Store` owns. A tick that lands
  # between a Store crash and its restart raises `:badarg`, and until this
  # rescue existed that killed the Broadcaster. The shipped
  # `broadcast_interval` default is **one second**, so a host whose Store
  # crashed had a live chance of it on every crash, and two such pairs close
  # together took the whole supervision tree down with the buffered deltas in
  # it.
  #
  # This is the fix `AuroraMeter.Flusher.do_flush/1` has had all along: a
  # `rescue` and a `catch`, and the next tick scheduled either way. A broadcast
  # that cannot read the tables has nothing to publish, and once the Store is
  # back the next tick publishes everything touched since, because the touched
  # set is read fresh every time rather than carried in this process's state.
  #
  # There is no new telemetry event here on purpose. `docs/telemetry.md` and
  # `docs/api.md` are a published contract that `AuroraMeter.Test.TelemetryCensus`
  # holds the tree to, and a failed broadcast is an operational log line rather
  # than a metric a host should be building an alert on: the thing worth alerting
  # on is the Store crash itself.
  @impl GenServer
  def handle_info(:broadcast, state) do
    safe_broadcast()
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # The synchronous call does NOT rescue, and that is deliberate. `broadcast_now/0`
  # is called by tests and by a host that wants a value on screen right now; a
  # caller asking for one broadcast and being told `:ok` when nothing could be
  # read is the silent pass this suite keeps finding (X325). The periodic tick
  # has nobody to tell, which is why it is the one that swallows.
  @impl GenServer
  def handle_call(:broadcast, _from, state), do: {:reply, do_broadcast(), state}

  @spec schedule(pos_integer()) :: reference()
  defp schedule(interval), do: Process.send_after(self(), :broadcast, interval)

  @spec safe_broadcast() :: :ok
  defp safe_broadcast do
    do_broadcast()
  rescue
    error -> broadcast_failed(Exception.message(error))
  catch
    kind, reason -> broadcast_failed({kind, reason})
  end

  @spec broadcast_failed(term()) :: :ok
  defp broadcast_failed(reason) do
    Logger.error(
      "AuroraMeter broadcast failed; the next tick will publish what is still touched: " <>
        inspect(reason)
    )

    :ok
  end

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

    # `tenant_key` is on the payload as well as in the topic because a process
    # can hold more than one subscription, and because `unsubscribe/2` stops
    # routing without emptying a mailbox: a message broadcast before the
    # unsubscribe and delivered after it is otherwise indistinguishable from a
    # current one, and a usage value is an absolute per-feature total, so a
    # stale one persists on screen until that feature moves again.
    # `AuroraMeter.LiveView.handle_usage/2` drops on this key.
    message =
      {:aurora_meter, :usage,
       %{
         tenant_key: tenant_key,
         feature: feature,
         value: value,
         period_start: period_start
       }}

    if cluster? do
      PubSub.local_broadcast(Config.pubsub(), topic(tenant_key), message)
    else
      PubSub.broadcast(Config.pubsub(), topic(tenant_key), message)
    end
  end
end
