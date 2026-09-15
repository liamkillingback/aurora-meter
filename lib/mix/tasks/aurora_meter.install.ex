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

    Options: `--repo`, `--pubsub`, `--plans` (module names; all inferred when
    omitted), `--oban` and `--check-support`.

    ## `--oban`

        mix aurora_meter.install --repo MyApp.Repo --oban

    Wires the optional `AuroraMeter.Oban.*` workers into the host's own Oban
    instance:

      * `config :my_app, Oban` when it is absent, with the repo, an
        `aurora_meter` queue and a `Oban.Plugins.Cron` plugin carrying
        `AuroraMeter.Oban.cron_entries/1`;
      * when it is present, the `aurora_meter` queue **only if absent**, the Cron
        plugin **only if absent**, and each recommended crontab entry **only if
        no entry already names that worker**;
      * the `AuroraMeter.Oban.validate!/1` call in `Application.start/2`.

    **It never edits a value you already set.** A queue concurrency you chose, a
    schedule you chose, and the order of your plugins all survive untouched; an
    entry whose worker is already scheduled is left exactly as written, whatever
    its schedule. That is the rule, and it is why running the installer twice
    changes nothing at all.

    ## `--check-support`

        mix aurora_meter.install --check-support

    Prints what this host resolves against Aurora Meter's declared floors and
    exits non-zero when something present is below one. It writes no file,
    generates nothing, and **connects to no database**: a Postgres server
    version can only be learned by asking the server, so the floor is printed
    and the check is yours to run. See `AuroraMeter.Install.Support`.

    ## `--dry-run`

    `--dry-run` is Igniter's own global switch and needs no declaration here: it
    prints the diff the task would apply and writes nothing. It works for this
    task exactly as it works for every other Igniter task, including the
    `--oban` work above.

    Without Igniter available the task falls back to generating the migration
    and printing the remaining steps; `--check-support` works there too.
    """

    use Igniter.Mix.Task

    alias AuroraMeter.Install.Oban, as: InstallOban
    alias AuroraMeter.Install.Support
    alias AuroraMeter.Install.Templates
    alias Igniter.Libs.Ecto, as: IgniterEcto
    alias Igniter.Project.Application, as: IgniterApp
    alias Igniter.Project.Config, as: IgniterConfig
    alias Igniter.Project.Module, as: IgniterModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :aurora_meter,
        example: "mix aurora_meter.install --repo MyApp.Repo --oban",
        # `dry_run` is deliberately absent: it is one of Igniter's global
        # switches, already parsed and already implemented, and declaring it
        # here would be a second flag with the same name.
        schema: [
          repo: :string,
          pubsub: :string,
          plans: :string,
          oban: :boolean,
          check_support: :boolean
        ],
        aliases: [r: :repo]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options

      if opts[:check_support] do
        check_support(igniter)
      else
        install(igniter, opts)
      end
    end

    defp install(igniter, opts) do
      prefix = IgniterModule.module_name_prefix(igniter)

      {igniter, repo} = resolve_repo(igniter, opts[:repo])
      pubsub = module_option(opts[:pubsub], Module.concat(prefix, PubSub))
      plans = module_option(opts[:plans], Module.concat(prefix, Plans))

      igniter
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:repo], repo)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:pubsub], pubsub)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:plans], plans)
      # A new install denies a feature no plan declares from its first boot.
      # The upgrade path for an existing install is the opposite (warn, then
      # scan with `mix aurora_meter.features`, then deny), which is why this is
      # written unconditionally here and documented separately.
      |> IgniterConfig.configure(
        "config.exs",
        :aurora_meter,
        [:undeclared_feature_policy],
        :deny
      )
      |> IgniterApp.add_new_child(AuroraMeter, after: fn mod -> mod in [repo, Phoenix.PubSub] end)
      |> create_plans(plans)
      |> IgniterEcto.gen_migration(repo, "add_aurora_meter",
        body: Templates.migration_body(),
        on_exists: :skip
      )
      |> maybe_oban(opts[:oban], repo)
      |> Igniter.add_notice(Templates.quickstart(repo, pubsub, plans))
    end

    # -- --check-support -------------------------------------------------------

    defp check_support(igniter) do
      rows = Support.rows()
      igniter = Igniter.add_notice(igniter, Support.report(rows))

      if Support.supported?(rows) do
        igniter
      else
        Igniter.add_issue(
          igniter,
          "Aurora Meter is not supported on this host: " <>
            Enum.map_join(below_floor(rows), ", ", &"#{&1.name} #{&1.resolved} < #{&1.floor}")
        )
      end
    end

    defp below_floor(rows), do: Enum.filter(rows, &(&1.verdict == :below_floor))

    # -- --oban ----------------------------------------------------------------

    defp maybe_oban(igniter, true, repo), do: oban(igniter, repo)
    defp maybe_oban(igniter, _absent, _repo), do: igniter

    # The merge itself is `AuroraMeter.Install.Oban`'s, because Aurora Meter
    # Pro's installer does exactly the same thing with its own entries and a
    # copy of a hundred lines of Sourceror across a package boundary is a copy
    # that will drift.
    defp oban(igniter, repo) do
      otp_app = IgniterApp.app_name(igniter)
      entries = AuroraMeter.Oban.cron_entries()

      igniter
      |> InstallOban.wire(otp_app: otp_app, repo: repo, entries: entries)
      |> InstallOban.validate_call(otp_app)
      |> Igniter.add_notice(Templates.oban_notice(entries))
    end

    # -- the pre-existing work -------------------------------------------------

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

    `--check-support` works here too, and is the same check: it prints what this
    host resolves against Aurora Meter's floors and exits non-zero when
    something present is below one.
    """

    use Mix.Task

    alias AuroraMeter.Install.Support
    alias AuroraMeter.Install.Templates

    @impl Mix.Task
    def run(args) do
      if "--check-support" in args do
        check_support()
      else
        Mix.Task.run("aurora_meter.gen.migration", args)
        Mix.shell().info(Templates.manual_steps())
      end
    end

    defp check_support do
      rows = Support.rows()
      Mix.shell().info(Support.report(rows))

      unless Support.supported?(rows) do
        Mix.raise("Aurora Meter is not supported on this host; see the report above.")
      end
    end
  end
end
