defmodule AuroraMeter.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AuroraMeter.Registry},
      AuroraMeter.Store,
      AuroraMeter.Cluster,
      AuroraMeter.Flusher,
      AuroraMeter.Broadcaster,
      # Last, and deliberately: the post-start checks need the rest of the tree
      # up, and they return `:ignore` so nothing is left running.
      AuroraMeter.BootChecks
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
