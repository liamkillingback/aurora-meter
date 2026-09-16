defmodule AuroraMeterExampleAi.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AuroraMeterExampleAiWeb.Telemetry,
      AuroraMeterExampleAi.Repo,
      {DNSCluster,
       query: Application.get_env(:aurora_meter_example_ai, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: AuroraMeterExampleAi.PubSub},

      # Aurora Meter needs the repo and the PubSub, and the endpoint needs
      # Aurora Meter: a request that arrives in the window between the endpoint
      # accepting connections and the ETS tables existing would fail on a
      # missing table. `mix aurora_meter.install` appended this line at the end
      # of the list, after the endpoint; it has been moved.
      AuroraMeter,

      # The reference exporter. It is an Agent that records what it was handed
      # and answers what it was told to, and it writes no file and no row: see
      # `AuroraMeterExampleAi.SampleOutbox.Drainer`.
      AuroraMeter.Exporter.Journal,
      {AuroraMeterExampleAi.SampleOutbox.Drainer,
       interval: Application.get_env(:aurora_meter_example_ai, :outbox_interval, 1_000)},

      # Start to serve requests, typically the last entry
      AuroraMeterExampleAiWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AuroraMeterExampleAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AuroraMeterExampleAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
