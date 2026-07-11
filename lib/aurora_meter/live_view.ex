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
