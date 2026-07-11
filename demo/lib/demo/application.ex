defmodule Demo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Demo.Repo,
      {Phoenix.PubSub, name: Demo.PubSub},
      AuroraMeter
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
