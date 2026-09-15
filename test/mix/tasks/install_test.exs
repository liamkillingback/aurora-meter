# Compiled only when Igniter.Test is available, the same guard
# lib/aurora_meter/components.ex:1 uses on the module under test here.
# Without it the `headless` CI leg (AURORA_HEADLESS=1, build unit 01f)
# cannot compile its test suite at all, and invariant I20 ("optional
# integrations remain optional") could never be proved by running
# anything. igniter is an optional dependency.
#
# The absence of this module on a headless build is asserted positively by
# test/aurora_meter/optional_deps_test.exs, so a guard that silently
# swallowed the whole suite would be caught.
if Code.ensure_loaded?(Igniter.Test) do
  defmodule Mix.Tasks.AuroraMeter.InstallTest do
    @moduledoc false
    # async: false — `Igniter.Test.test_project/1` puts the generated project's
    # config into the *global* application environment, so while this runs
    # `AuroraMeter.Config.repo/0` briefly answers `Demo.Repo`. Racing it against
    # an async test that touches the database fails that test, not this one.
    use ExUnit.Case, async: false

    import Igniter.Test

    alias AuroraMeter.Install.Support
    alias Igniter.Mix.Task.Info
    alias Mix.Tasks.AuroraMeter.Install, as: InstallTask

    @config "config/config.exs"
    @application "lib/demo/application.ex"

    test "wires config, supervision child, a plans module and the migration" do
      igniter =
        test_project(app_name: :demo)
        |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])

      # A fresh test project has no config.exs, so the installer creates it.
      assert_creates(igniter, @config)

      config = source(igniter, @config)

      assert config =~ "config :aurora_meter"
      assert config =~ "repo: Demo.Repo"
      assert config =~ "pubsub: Demo.PubSub"
      assert config =~ "plans: Demo.Plans"

      # Build unit 02b: a new install denies a feature no plan declares from its
      # first boot. An existing install upgrades the other way round, which is
      # why this line is only ever generated and never migrated in.
      assert config =~ "undeclared_feature_policy: :deny"

      # Likewise the application module is created in a bare test project.
      assert_creates(igniter, @application)

      assert source(igniter, @application) =~ "children = [AuroraMeter]"

      assert_creates(igniter, "lib/demo/plans.ex")

      plans = source(igniter, "lib/demo/plans.ex")

      assert plans =~ "use AuroraMeter.Plans"
      assert plans =~ "plan :free do"

      assert migration_body(igniter) =~ "AuroraMeter.Migration.up()"
    end

    test "a second run does not duplicate the policy line" do
      igniter =
        test_project(app_name: :demo)
        |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])
        |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])

      config = source(igniter, @config)

      assert length(String.split(config, "undeclared_feature_policy")) - 1 == 1
      assert length(String.split(config, "plans: Demo.Plans")) - 1 == 1
    end

    test "does not overwrite an existing plans module" do
      igniter =
        test_project(
          app_name: :demo,
          files: %{
            "lib/demo/plans.ex" => """
            defmodule Demo.Plans do
              use AuroraMeter.Plans

              plan :custom do
                price 0
              end
            end
            """
          }
        )
        |> Igniter.compose_task("aurora_meter.install", ["--repo", "Demo.Repo"])

      assert_unchanged(igniter, "lib/demo/plans.ex")
    end

    describe "--oban" do
      test "adds the queue, the Cron plugin and every recommended entry to a project with no Oban configuration" do
        igniter = install(["--repo", "Demo.Repo", "--oban"])

        config = source(igniter, @config)

        # Whitespace tolerant: the formatter breaks `config :demo, Oban, ...`
        # across lines once the value is long, and what matters is that the key
        # is the host's own app with `Oban` under it.
        assert config =~ ~r/config :demo,\s*\n?\s*Oban,/
        assert config =~ "repo: Demo.Repo"
        assert config =~ "queues: [aurora_meter: 5]"
        assert config =~ "Oban.Plugins.Cron"

        for {schedule, worker} <- AuroraMeter.Oban.cron_entries() do
          assert config =~ "{#{inspect(schedule)}, #{inspect(worker)}}",
                 "#{inspect(worker)} is missing from the generated crontab"
        end

        # The startup validation call, once.
        application = source(igniter, @application)
        assert application =~ "AuroraMeter.Oban.validate!(otp_app: :demo)"
        assert occurrences(application, "AuroraMeter.Oban.validate!") == 1
      end

      test "adds only the missing cron entries to a project that already has some" do
        igniter = install(["--repo", "Demo.Repo", "--oban"], files: %{@config => partial_oban()})

        config = source(igniter, @config)

        # The concurrency the host chose, untouched. Asserted as an absence too:
        # `=~ "aurora_meter: 2"` alone would pass a config that had gained a
        # second `aurora_meter: 5` beside it.
        assert config =~ "aurora_meter: 2"
        refute config =~ "aurora_meter: 5"

        # The schedule the host chose for the expiry sweep, untouched, and no
        # second entry for the same worker beside it.
        assert config =~ ~s({"0 4 * * *", AuroraMeter.Oban.CreditExpiry})
        assert occurrences(config, "AuroraMeter.Oban.CreditExpiry") == 1

        # And the one it did not have.
        assert config =~ "AuroraMeter.Oban.HoldReconciliation"

        # The host's own worker and its own plugin are still there.
        assert config =~ "Demo.Workers.Nightly"
        assert config =~ "Oban.Plugins.Pruner"
      end

      test "G05 a second run of the installer changes nothing" do
        args = ["--repo", "Demo.Repo", "--oban"]

        # The first run is **applied**, so the second run starts from a project
        # that already has everything the first one wrote, which is what a host
        # running the task twice actually has.
        #
        # `assert_unchanged/1` on an igniter that merely composed the task twice
        # would be meaningless: the first composition's own changes are still in
        # it, so it is changed whatever the second composition did. Applying
        # first is what turns the assertion into the G05 claim.
        applied = install(args) |> apply_igniter!()

        second = Igniter.compose_task(applied, "aurora_meter.install", args)

        assert_unchanged(second)

        # And byte identical, file by file, so a reader of the evidence does not
        # have to take `changed?/1`'s word for it.
        for path <- [@config, @application, "lib/demo/plans.ex"] do
          assert source(applied, path) == source(second, path),
                 "#{path} changed on the second run"
        end

        assert migration_body(applied) == migration_body(second)

        # A third run, for the same reason the second one exists: a task that is
        # idempotent once can still drift on the next.
        third = second |> apply_igniter!() |> Igniter.compose_task("aurora_meter.install", args)
        assert_unchanged(third)
      end

      test "the same is true for a host that already runs Oban" do
        args = ["--repo", "Demo.Repo", "--oban"]

        applied =
          args |> install(files: %{@config => partial_oban()}) |> apply_igniter!()

        assert_unchanged(Igniter.compose_task(applied, "aurora_meter.install", args))
      end

      test "the installer adds the validate!/1 call once and not twice" do
        args = ["--repo", "Demo.Repo", "--oban"]

        application =
          args
          |> install()
          |> Igniter.compose_task("aurora_meter.install", args)
          |> Igniter.compose_task("aurora_meter.install", args)
          |> source(@application)

        assert occurrences(application, "AuroraMeter.Oban.validate!") == 1
      end

      test "a bare Oban.Plugins.Cron gains a crontab rather than being left without one" do
        igniter = install(["--repo", "Demo.Repo", "--oban"], files: %{@config => bare_cron()})

        config = source(igniter, @config)

        assert config =~ "crontab:"
        assert config =~ "AuroraMeter.Oban.CreditExpiry"
      end
    end

    describe "--check-support" do
      test "writes no file and reports every row" do
        igniter = install(["--check-support"])

        assert_unchanged(igniter)

        assert [notice] = igniter.notices
        assert notice =~ "Aurora Meter support check"
        assert notice =~ "elixir"
        assert notice =~ "erlang/otp"
        assert notice =~ "oban"
      end

      test "every row this host resolves is at or above its floor" do
        # If this ever fails on a supported host, the floors and the CI matrix
        # disagree, which is the thing the switch exists to tell a host about.
        assert Support.supported?(),
               Support.report()
      end

      test "a row below its floor is not supported, and one that is absent and optional is" do
        below = %{
          name: "oban",
          resolved: "2.16.0",
          floor: "2.17.0",
          verdict: :below_floor,
          note: nil
        }

        absent = %{name: "oban", resolved: nil, floor: "2.17.0", verdict: :absent, note: nil}

        refute Support.supported?([below])
        assert Support.supported?([absent])
      end

      test "the Postgres row is never checked, because checking it means connecting" do
        row = Enum.find(Support.rows(), &(&1.name == "postgres"))

        assert row.verdict == :unknown
        assert row.resolved == nil
        assert row.note =~ "connecting"
      end
    end

    describe "--dry-run" do
      test "is Igniter's own global switch, and this task does not declare a second one" do
        # The build document asks this unit for a `--dry-run` switch. Igniter
        # already has one, as a global option every task inherits, and declaring
        # it again here would be two flags with one name. What this unit owes is
        # therefore the assertion that the claim in the moduledoc is true, not a
        # second implementation (`open-findings.md` X192).
        info = InstallTask.info([], nil)

        refute Keyword.has_key?(info.schema, :dry_run)

        global = Info.global_options() |> Keyword.fetch!(:switches)

        assert Keyword.get(global, :dry_run) == :boolean
      end
    end

    # -- helpers ---------------------------------------------------------------

    defp install(args, opts \\ []) do
      [app_name: :demo]
      |> Keyword.merge(opts)
      |> test_project()
      |> Igniter.compose_task("aurora_meter.install", args)
    end

    defp source(igniter, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    end

    defp migration_body(igniter) do
      path =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.map(& &1.path)
        |> Enum.find(&String.match?(&1, ~r{priv/repo/migrations/\d+_add_aurora_meter\.exs}))

      assert path, "expected a migration to be generated"

      source(igniter, path)
    end

    defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1

    # A host that already runs Oban, with its own queue concurrency, its own
    # plugin, its own worker and its own schedule for one of ours.
    defp partial_oban do
      """
      import Config

      config :demo, Oban,
        repo: Demo.Repo,
        queues: [aurora_meter: 2, mailers: 10],
        plugins: [
          Oban.Plugins.Pruner,
          {Oban.Plugins.Cron,
           crontab: [
             {"0 4 * * *", AuroraMeter.Oban.CreditExpiry},
             {"@daily", Demo.Workers.Nightly}
           ]}
        ]
      """
    end

    defp bare_cron do
      """
      import Config

      config :demo, Oban,
        repo: Demo.Repo,
        queues: [aurora_meter: 3],
        plugins: [Oban.Plugins.Cron]
      """
    end
  end
end
