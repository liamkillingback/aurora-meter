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
    omitted), `--feature-policy`, `--events-source`, `--oban` and
    `--check-support`.

    ## `--feature-policy`

        mix aurora_meter.install --repo MyApp.Repo --feature-policy warn

    Writes `undeclared_feature_policy`, one of `deny` (the default for a new
    install), `raise`, `warn` or `allow`. It is written into your own
    `config/config.exs` rather than left to the library default, so that a later
    release changing that default cannot change what your application does.

    **It is created and never changed.** A second run of this task on a host
    that already sets the key keeps the host's value, says so, and names what a
    fresh install would have been given. That is deliberate: the upgrade path
    for an existing install is `:warn`, then `mix aurora_meter.features` until
    it reports nothing, then `:deny`, and an installer run for an unrelated
    reason must not put a running application back to the start of it.

    ## `--events-source`

        mix aurora_meter.install --repo MyApp.Repo \\
          --events-source tokens:events --events-source requests:buffered

    Writes `feature_sources`. A feature listed as `events` is recorded durably
    through `AuroraMeter.record/4` and projected, and `AuroraMeter.track/4`
    raises for it: a feature has exactly one reporting source. Pass the switch
    once per feature. Like the policy above it is created and never changed.

    An unknown source, a name that is not a feature name, or the same feature
    twice stops the task before it writes anything at all.

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
    alias AuroraMeter.Install.Options
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
          # `:keep`, so `--events-source` can be passed once per feature.
          events_source: :keep,
          feature_policy: :string,
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
        # Parsed and validated before anything is touched, so a bad value leaves
        # an igniter carrying one issue and no change at all. Igniter writes
        # nothing when there are issues, and an igniter with no change in it is
        # the strongest form of "created no file".
        case Options.parse(opts) do
          {:ok, settings} -> install(igniter, opts, settings)
          {:error, message} -> Igniter.add_issue(igniter, message)
        end
      end
    end

    defp install(igniter, opts, settings) do
      prefix = IgniterModule.module_name_prefix(igniter)

      {igniter, repo} = resolve_repo(igniter, opts[:repo])
      pubsub = module_option(opts[:pubsub], Module.concat(prefix, PubSub))
      plans = module_option(opts[:plans], Module.concat(prefix, Plans))

      igniter
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:repo], repo)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:pubsub], pubsub)
      |> IgniterConfig.configure("config.exs", :aurora_meter, [:plans], plans)
      |> feature_policy(settings.policy, opts[:feature_policy])
      |> feature_sources(settings.feature_sources)
      |> IgniterApp.add_new_child(AuroraMeter, after: fn mod -> mod in [repo, Phoenix.PubSub] end)
      |> create_plans(plans)
      |> IgniterEcto.gen_migration(repo, "add_aurora_meter",
        body: Templates.migration_body(),
        on_exists: :skip
      )
      |> maybe_oban(opts[:oban], repo)
      |> Igniter.add_notice(Templates.quickstart(repo, pubsub, plans, settings))
    end

    # -- the two keys a host is expected to tune -------------------------------

    # `configure_new/6` and not `configure/6` (decision D04, build unit 09b).
    #
    # `:repo`, `:pubsub` and `:plans` are overwritten on every run, and should
    # be: the operator passed them on the command line, so overwriting is what
    # was asked for. These two are the opposite. A host sets
    # `undeclared_feature_policy` during the 0.5.x transition, where the upgrade
    # path is `:warn` first and `:deny` once `mix aurora_meter.features` comes
    # back clean; running the installer again for an unrelated reason must not
    # quietly put the whole application back to `:deny` and start refusing
    # features in production.
    #
    # Whether the key was already there is read BEFORE the write, so the task
    # can say which of the two things it did. An installer that keeps a value
    # silently is indistinguishable from one that wrote it.
    defp feature_policy(igniter, policy, flag) do
      if IgniterConfig.configures_key?(
           igniter,
           "config.exs",
           :aurora_meter,
           [:undeclared_feature_policy]
         ) do
        Igniter.add_notice(igniter, Templates.kept_policy(policy, flag))
      else
        IgniterConfig.configure_new(
          igniter,
          "config.exs",
          :aurora_meter,
          [:undeclared_feature_policy],
          policy
        )
      end
    end

    defp feature_sources(igniter, sources) when map_size(sources) == 0, do: igniter

    defp feature_sources(igniter, sources) do
      if IgniterConfig.configures_key?(igniter, "config.exs", :aurora_meter, [:feature_sources]) do
        Igniter.add_notice(igniter, Templates.kept_sources(sources))
      else
        igniter
        |> IgniterConfig.configure_new(
          "config.exs",
          :aurora_meter,
          [:feature_sources],
          {:code, Sourceror.parse_string!(Templates.feature_sources(sources))}
        )
        |> Igniter.add_notice(Templates.sources_notice(sources))
      end
    end

    # -- --check-support -------------------------------------------------------

    defp check_support(igniter) do
      rows = Support.rows()

      if Support.supported?(rows) do
        Igniter.add_notice(igniter, Support.report(rows))
      else
        # `Mix.raise` and not `Igniter.add_issue`. An issue is displayed and the
        # task still **exits 0**: `Igniter.do_or_dry_run/2` returns `:issues` and
        # sets no exit status, so a CI step, an install script or a release check
        # could not tell a supported host from an unsupported one, which is the
        # entire job of this switch. `--check-support` writes nothing by
        # construction, so an abort here leaves nothing half done, and it is the
        # same behaviour the Igniter-less definition of this task already had.
        Mix.raise(Support.report(rows) <> "\n" <> Support.problem_summary(rows))
      end
    end

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

    `--feature-policy` and `--events-source` are understood here too. This
    version writes no configuration, so what they change is what it prints: the
    block you are told to paste is the one you asked for, not the default. A
    fallback that ignored a switch the operator passed would print one
    configuration while they had asked for another, and the host would paste the
    printed one.

    `--dry-run` prints the migration files this would generate, with their
    bodies, and writes nothing. It is implemented here because there is no
    Igniter to implement it: on the Igniter path `--dry-run` is Igniter's own
    global switch and this task must not declare a second one.
    """

    use Mix.Task

    alias AuroraMeter.Install.Options
    alias AuroraMeter.Install.Plan
    alias AuroraMeter.Install.Support
    alias AuroraMeter.Install.Templates

    @switches [feature_policy: :string, events_source: :keep, dry_run: :boolean]

    @impl Mix.Task
    def run(args) do
      if "--check-support" in args do
        check_support()
      else
        {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

        case Options.parse(opts) do
          {:ok, settings} -> install(args, opts[:dry_run], settings)
          {:error, message} -> Mix.raise(message)
        end
      end
    end

    defp install(_args, true, settings) do
      Mix.shell().info(dry_run_report())
      Mix.shell().info(Templates.manual_steps(settings))
    end

    defp install(args, _dry_run, settings) do
      Mix.Task.run("aurora_meter.gen.migration", args)
      Mix.shell().info(Templates.manual_steps(settings))
    end

    defp dry_run_report do
      files = Plan.files(package: :core)

      bodies =
        Enum.map_join(files, "\n", fn file ->
          """
            priv/repo/migrations/<timestamp>_#{file.suffix}.exs

                def up, do: #{file.up}
                def down, do: #{file.down}
          """
        end)

      """

      --dry-run: nothing was written. This would have generated \
      #{length(files)} migration #{if length(files) == 1, do: "file", else: "files"}:

      #{bodies}
      """
    end

    defp check_support do
      rows = Support.rows()
      Mix.shell().info(Support.report(rows))

      unless Support.supported?(rows) do
        Mix.raise(Support.problem_summary(rows))
      end
    end
  end
end
