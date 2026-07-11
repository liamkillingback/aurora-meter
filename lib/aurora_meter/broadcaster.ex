defmodule AuroraMeter.Broadcaster do
  @moduledoc """
  Periodically broadcasts touched counter values over `Phoenix.PubSub`.

  Phase 1 scaffold: the process boots and holds its interval but does not yet
  broadcast. Live fan-out is implemented in Phase 6.
  """

  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    {:ok, %{interval: AuroraMeter.Config.broadcast_interval()}}
  end
end
