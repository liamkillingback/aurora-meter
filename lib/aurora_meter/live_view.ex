defmodule AuroraMeter.LiveView do
  @moduledoc """
  Helper for consuming live usage updates in a LiveView (or any process).

      def mount(_params, _session, socket) do
        if connected?(socket), do: AuroraMeter.LiveView.subscribe(socket.assigns.current_org)
        {:ok, socket}
      end

      def handle_info({:aurora_meter, :usage, %{feature: feature, value: value}}, socket) do
        {:noreply, update_meter(socket, feature, value)}
      end

  ## The contract

  `subscribe/1` subscribes the calling process to one topic, and one message
  shape arrives on it.

  **Topic.** `AuroraMeter.Broadcaster.topic/1` of the resolved tenant key,
  which is `"aurora_meter:tenant:" <> tenant_key`. Build it with that function
  rather than with string concatenation of your own: the prefix is part of the
  supported API, the way it is assembled is not.

  **Message.**

      {:aurora_meter, :usage, %{feature: atom(), value: integer(), period_start: DateTime.t()}}

  One message per touched counter per tick, at most one tick every
  `:broadcast_interval` milliseconds (1000 by default). Match on the keys you
  need: the payload map gains keys additively across releases, so a match on
  the whole map will break where a match on three keys will not.

  Three properties worth knowing before you render the number.

    * **`value` includes units this node has reserved but not yet committed.**
      A `reserve/3` or `with_quota/4` call occupies quota immediately, and the
      broadcast reflects the counter as the entitlement check sees it. A meter
      can therefore tick up and then stay put when the reserved work commits.
    * **`value` is this node's converged view, not a database read.** With
      `cluster_sync: true` (the default) the broadcast is node-local, so a
      browser connected to node B sees node B's view; other nodes' increments
      arrive within one `:broadcast_interval`, and a flush re-bases every node
      on the database total within one `:flush_interval`.
    * **A day-bucket counter is never broadcast.** Only period counters are.
      Use `AuroraMeter.history/3` for the daily series.

  History day buckets and the cluster gossip topic are internal. Subscribe to
  this topic and, for balances, to `AuroraMeter.Credits.topic/1`.
  """

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Config
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  @doc "Subscribes the calling process to `tenant`'s live usage updates."
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(tenant) do
    PubSub.subscribe(Config.pubsub(), Broadcaster.topic(Tenant.to_key(tenant)))
  end
end
