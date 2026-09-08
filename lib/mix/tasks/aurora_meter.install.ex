if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AuroraMeter.Install do
    @shortdoc "Installs Aurora Meter into the host app (config, supervisor, plans, migration)"

    @moduledoc """
    Installs Aurora Meter into a Phoenix (or plain Ecto) application in one
    step, powered by [Igniter](https://hexdocs.pm/igniter):

        mix igniter.install aurora_meter
        # or, once the dep is in mix.exs:
        mix aurora_meter.install --repo MyApp.Repo

    It will

      * add `config :aurora_meter, repo: ..., pubsub: ..., plans: ...` to `config/config.exs`
      * add `AuroraMeter` to your application's children, after the repo and PubSub
      * create a `MyApp.Plans` module with a `:free` and a `:pro` plan (never overwrites one you have)
      * generate the migration that delegates to `AuroraMeter.Migration`

    Options: `--repo`, `--pubsub`, `--plans` (module names; all inferred when omitted).

    Without Igniter available the task falls back to generating the migration
    and printing the remaining steps.
    """

    use Igniter.Mix.Task

    alias AuroraMeter.Install.Templates
    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Module, as: IgniterModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :aurora_meter,
        example: "mix aurora_meter.install --repo MyApp.Repo",
        schema: [repo: :string, pubsub: :string, plans: :string],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      prefix = IgniterModule.module_name_prefix(igniter)

      {igniter, repo} = resolve_repo(igniter, opts[:repo])
      pubsub = module_option(opts[:pubsub], Module.concat(prefix, PubSub))
      plans = module_option(opts[:plans], Module.concat(prefix, Plans))

      igniter
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:repo], repo)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:pubsub], pubsub)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:plans], plans)
      |> IgniterApp.add_new_child(AuroraMeter, after: fn mod -> mod in [repo, Phoenix.PubSub] end)
      |> create_plans(plans)
      |> IgniterEcto.gen_migration(repo, "add_aurora_meter",
        body: Templates.migration_body(),
        on_exists: :skip
      )
      |> Igniter.add_notice(Templates.quickstart(repo, pubsub, plans))
    end

    defp resolve_repo(igniter, nil) do
      case IgniterEcto.select_repo(igniter, label: "Which repo should Aurora Meter use?") do
        {igniter, nil} ->
          prefix = IgniterModule.module_name_prefix(igniter)
          {igniter, Module.concat(prefix, Repo)}

        {igniter, repo} ->
          {igniter, repo}
      end
    end

    defp resolve_repo(igniter, repo), do: {igniter, IgniterModule.parse(repo)}

    defp module_option(nil, default), do: default
    defp module_option(name, _default), do: IgniterModule.parse(name)

    # Never clobber a plans module the app already has.
    defp create_plans(igniter, plans) do
      case IgniterModule.module_exists(igniter, plans) do
        {true, igniter} ->
          igniter

        {false, igniter} ->
          IgniterModule.create_module(igniter, plans, Templates.plans_module(plans))
      end
    end
  end
else
  defmodule Mix.Tasks.AuroraMeter.Install do
    @shortdoc "Installs Aurora Meter into the host app"

    @moduledoc """
    Generates the Aurora Meter migration and prints the configuration you still
    need to add. With [Igniter](https://hexdocs.pm/igniter) in your deps the same
    task also writes the config, supervision child and a starter plans module:

        mix igniter.install aurora_meter

    Without it:

        mix aurora_meter.install -r MyApp.Repo
    """

    use Mix.Task

    alias AuroraMeter.Install.Templates

    @impl Mix.Task
    def run(args) do
      Mix.Task.run("aurora_meter.gen.migration", args)
      Mix.shell().info(Templates.manual_steps())
    end
  end
end
