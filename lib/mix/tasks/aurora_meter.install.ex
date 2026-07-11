defmodule Mix.Tasks.AuroraMeter.Install do
  @shortdoc "Installs Aurora Meter into the host app"

  @moduledoc """
  Generates the Aurora Meter migration and prints the configuration you still
  need to add. Equivalent to running `aurora_meter.gen.migration` plus a reminder.

      mix aurora_meter.install -r MyApp.Repo
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("aurora_meter.gen.migration", args)
    Mix.shell().info(next_steps())
  end

  defp next_steps do
    """

    Aurora Meter migration generated. Next:

      1. Run the migration:   mix ecto.migrate
      2. Configure it:

         config :aurora_meter,
           repo: MyApp.Repo,
           pubsub: MyApp.PubSub,
           plans: MyApp.Plans

      3. Add it to your supervision tree, after the Repo and PubSub:

         children = [MyApp.Repo, {Phoenix.PubSub, name: MyApp.PubSub}, AuroraMeter, ...]
    """
  end
end
