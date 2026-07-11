# Start the host-owned processes a real application would provide (repo + pubsub),
# then the Aurora Meter runtime itself.
{:ok, _} =
  Supervisor.start_link(
    [
      AuroraMeter.TestRepo,
      {Phoenix.PubSub, name: AuroraMeter.TestPubSub},
      AuroraMeter
    ],
    strategy: :one_for_one,
    name: AuroraMeter.TestRootSupervisor
  )

Ecto.Adapters.SQL.Sandbox.mode(AuroraMeter.TestRepo, :manual)
ExUnit.start()
