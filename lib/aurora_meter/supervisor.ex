defmodule AuroraMeter.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AuroraMeter.Registry},
      # First, and it supervises nothing at rest. It exists so that a host
      # callback the library invokes runs in a process of its own: a callback
      # that raises must not take its caller down, and one that never returns
      # must be killable. `Task.async/1` links, which would give a raising
      # callback the caller's process.
      {Task.Supervisor, name: AuroraMeter.TaskSupervisor},
      AuroraMeter.Store,
      # Immediately after the Store: a durable write is admitted before it
      # touches a connection, and a caller that is refused must be refused
      # rather than queued behind a pool checkout.
      AuroraMeter.Events.Gate,
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
