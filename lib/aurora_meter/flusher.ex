defmodule AuroraMeter.Flusher do
  @moduledoc """
  Periodically persists dirty ETS counters to the database.

  Phase 1 scaffold: the process boots and holds its interval but does not yet
  sweep. The flush algorithm (snapshot dirty keys, per-key delete, absolute-value
  upsert) is implemented in Phase 3.
  """

  use GenServer

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    {:ok, %{interval: AuroraMeter.Config.flush_interval()}}
  end
end
