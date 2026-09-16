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

    alias AuroraMeter.Install.Plan
    alias AuroraMeter.Install.Support
    alias AuroraMeter.Install.Templates
    alias AuroraMeter.Migration
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

      # I19, L09b-3: the installer's migration names both ends of the range.
      # It used to emit `AuroraMeter.Migration.up()`, which runs to whatever
      # version the installed package has reached on the day it is applied, so
      # the same committed file produced one schema in the database it was
      # written against and a different one in a database created after the next
      # release (`open-findings.md` S1). The generator was fixed in 05c and the
      # installer was not, so two supported ways of installing this package
      # produced two different migrations.
      body = migration_body(igniter)
      latest = Migration.latest_version()

      assert body =~ "AuroraMeter.Migration.up(from: 1, version: #{latest}"
      assert body =~ "AuroraMeter.Migration.down(version: #{latest}, to: 1"

      refute_unbounded(body)
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

      test "I20 the declared floors and mix.exs name the same dependencies" do
        # Until build unit 09b this comparison was a sentence in a comment in
        # support.ex naming a test file that did not exist. A rule nothing
        # enforces is one already being broken (`open-findings.md` X153), and it
        # was: the matrix listed nine dependencies and mix.exs declared
        # fourteen, so `--check-support` was silent about phoenix_html, the
        # dashboard, OpenTelemetry, telemetry_metrics and plug.
        declared = Support.declared_deps() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

        in_mix =
          Mix.Project.config()
          |> Keyword.fetch!(:deps)
          |> Enum.reject(fn
            {_app, _requirement, opts} -> Keyword.has_key?(opts, :only)
            {_app, _requirement} -> false
          end)
          |> Enum.map(&elem(&1, 0))
          |> MapSet.new()

        assert MapSet.subset?(in_mix, declared),
               "mix.exs declares dependencies the support matrix says nothing about: " <>
                 inspect(MapSet.to_list(MapSet.difference(in_mix, declared)))

        # The other direction only holds on a build with no AURORA_ switch set:
        # those switches take dependencies out of mix.exs, and the matrix
        # describes what the package supports rather than what this leg built.
        if switched_build?() do
          :ok
        else
          assert MapSet.equal?(in_mix, declared),
                 "the support matrix names dependencies mix.exs does not: " <>
                   inspect(MapSet.to_list(MapSet.difference(declared, in_mix)))
        end
      end

      test "I20 the phoenix_live_view floor is 1.0.0 and agrees with mix.exs" do
        # D12 and finding C9: the floor a host is told about and the requirement
        # Hex resolves have to be the same number, or one of them is a lie.
        assert {:phoenix_live_view, "1.0.0", :optional} in Support.declared_deps()

        if switched_build?() do
          :ok
        else
          {:phoenix_live_view, requirement, _opts} =
            Mix.Project.config() |> Keyword.fetch!(:deps) |> List.keyfind(:phoenix_live_view, 0)

          assert requirement == "~> 1.0"
          assert Version.match?("1.0.0", requirement)
          refute Version.match?("0.20.17", requirement)
        end
      end

      test "I20 a dependency present whose guarded module was not compiled is an error row" do
        # The stale-build trap, induced through the real row code rather than by
        # constructing the row a test wants to see: the probe says
        # phoenix_live_view 1.2.0 is installed and AuroraMeter.Components is not
        # compiled, which is exactly a host that added the dependency after
        # aurora_meter was built.
        rows = Support.rows(probe: stale(:phoenix_live_view))
        row = Enum.find(rows, &(&1.name == "phoenix_live_view"))

        assert row.verdict == :stale_build
        assert row.resolved == "1.2.0"
        assert row.note =~ "AuroraMeter.Components was not compiled"
        assert row.note =~ "mix deps.compile aurora_meter --force"

        # And that verdict is what makes --check-support exit non-zero.
        refute Support.supported?(rows)
        assert Support.report(rows) =~ "NOT COMPILED IN"
      end

      test "I20 control: the same probe with the module compiled is ok" do
        # Without this the test above would pass for a probe that reported
        # :stale_build whatever it was given.
        rows = Support.rows(probe: compiled(:phoenix_live_view))
        row = Enum.find(rows, &(&1.name == "phoenix_live_view"))

        assert row.verdict == :ok
        assert Support.supported?(rows)
        refute Support.report(rows) =~ "NOT COMPILED IN"
      end

      test "I20 a dependency below its floor beats the stale-build check to the verdict" do
        # Order matters: a host on LiveView 0.20 has a version problem, not a
        # build problem, and telling it to recompile would send it round a loop.
        rows = Support.rows(probe: fn _app, _guard -> {"0.20.17", false} end)
        row = Enum.find(rows, &(&1.name == "phoenix_live_view"))

        assert row.verdict == :below_floor
        refute Support.supported?(rows)
      end

      test "I20 the abort message names every problem and the command that fixes it" do
        # What `--check-support` raises with when it refuses. It raises rather
        # than adding an Igniter issue, because an issue is displayed and the
        # task still exits 0, and a switch whose whole job is to answer
        # "is this host supported" has to answer in the exit status too. The
        # exit codes themselves are proved end to end against a real host
        # project in `docs/evidence/v1/phase-09/09b-support-matrix.md`.
        rows = Support.rows(probe: stale(:phoenix_live_view))
        summary = Support.problem_summary(rows)

        refute Support.supported?(rows)
        assert summary =~ "not supported on this host"
        assert summary =~ "phoenix_live_view 1.2.0 is installed but its integration is not"
        assert summary =~ "mix deps.compile aurora_meter --force"

        # And it says so the other way round when there is nothing wrong, so the
        # message is not a constant.
        assert Support.problem_summary(Support.rows()) ==
                 "Aurora Meter is supported on this host."
      end

      test "I20 an absent optional dependency is neither an error nor a stale build" do
        rows = Support.rows(probe: fn _app, _guard -> {nil, false} end)

        for name <- ~w(phoenix_live_view plug igniter oban) do
          assert Enum.find(rows, &(&1.name == name)).verdict == :absent
        end

        # The required ones are a different matter, and the report says so.
        assert Enum.find(rows, &(&1.name == "ecto_sql")).verdict == :below_floor
        refute Support.supported?(rows)
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

    describe "--feature-policy" do
      test "I20 a first run writes :deny with no flag given" do
        config = source(install(["--repo", "Demo.Repo"]), @config)

        assert config =~ "undeclared_feature_policy: :deny"
      end

      test "I20 --feature-policy warn writes :warn and not :deny" do
        config = source(install(["--repo", "Demo.Repo", "--feature-policy", "warn"]), @config)

        assert config =~ "undeclared_feature_policy: :warn"
        refute config =~ "undeclared_feature_policy: :deny"
      end

      test "I20 every documented value is accepted and written" do
        for value <- ~w(allow warn deny raise) do
          config = source(install(["--repo", "Demo.Repo", "--feature-policy", value]), @config)

          assert config =~ "undeclared_feature_policy: :#{value}",
                 "--feature-policy #{value} did not write :#{value}"
        end
      end

      test "I20 --feature-policy bogus creates no file at all" do
        igniter = install(["--repo", "Demo.Repo", "--feature-policy", "bogus"])

        # Not merely "the value was not written": the task refused before it
        # touched anything, so the igniter carries one issue and no change. That
        # is what Igniter needs in order to write nothing at all.
        assert_unchanged(igniter)
        assert [issue] = igniter.issues
        assert issue =~ "--feature-policy bogus"
        assert issue =~ "allow, warn, deny, raise"
        assert issue =~ "Nothing was written."
      end

      test "I20 a second run keeps a host-edited value and says which one it kept" do
        applied =
          ["--repo", "Demo.Repo"]
          |> install(files: %{@config => host_policy(":warn")})
          |> apply_igniter!()

        # The host's own value survived the first run, because the key was
        # already there.
        assert source(applied, @config) =~ "undeclared_feature_policy: :warn"

        second = Igniter.compose_task(applied, "aurora_meter.install", ["--repo", "Demo.Repo"])

        assert source(second, @config) =~ "undeclared_feature_policy: :warn"
        refute source(second, @config) =~ ":deny"

        # D04's other half: it reports that it kept the value. An installer that
        # keeps one silently cannot be told apart from one that wrote it.
        assert Enum.any?(second.notices, &(&1 =~ "already sets :undeclared_feature_policy")),
               "no notice said the existing value was kept: #{inspect(second.notices)}"

        kept = Enum.find(second.notices, &(&1 =~ "already sets :undeclared_feature_policy"))

        assert kept =~ "A fresh install would have been given"
        assert kept =~ ":deny"
      end

      test "I20 an explicit flag does not override a host's existing value either" do
        applied =
          ["--repo", "Demo.Repo"]
          |> install(files: %{@config => host_policy(":warn")})
          |> apply_igniter!()

        second =
          Igniter.compose_task(
            applied,
            "aurora_meter.install",
            ["--repo", "Demo.Repo", "--feature-policy", "deny"]
          )

        assert source(second, @config) =~ "undeclared_feature_policy: :warn"

        assert Enum.any?(second.notices, &(&1 =~ "You passed --feature-policy deny")),
               "the notice did not say the flag was ignored: #{inspect(second.notices)}"
      end
    end

    describe "--events-source" do
      test "I20 writes feature_sources with every pair given" do
        config =
          ["--repo", "Demo.Repo", "--events-source", "tokens:events"]
          |> Kernel.++(["--events-source", "requests:buffered"])
          |> install()
          |> source(@config)

        assert config =~ "feature_sources:"
        assert config =~ "tokens: :events"
        assert config =~ "requests: :buffered"
      end

      test "I20 one pair writes exactly that pair" do
        config =
          source(install(["--repo", "Demo.Repo", "--events-source", "tokens:events"]), @config)

        assert config =~ "feature_sources: %{tokens: :events}"
      end

      test "I20 no flag writes no feature_sources key at all" do
        refute source(install(["--repo", "Demo.Repo"]), @config) =~ "feature_sources"
      end

      test "I20 --events-source tokens:bogus creates no file at all" do
        igniter = install(["--repo", "Demo.Repo", "--events-source", "tokens:bogus"])

        assert_unchanged(igniter)
        assert [issue] = igniter.issues
        assert issue =~ "buffered, events"
        assert issue =~ "Nothing was written."
      end

      test "I20 a malformed pair creates no file at all" do
        igniter = install(["--repo", "Demo.Repo", "--events-source", "tokens"])

        assert_unchanged(igniter)
        assert [issue] = igniter.issues
        assert issue =~ "is not `feature:source`"
      end

      test "I20 a feature that is not a feature name creates no file at all" do
        igniter = install(["--repo", "Demo.Repo", "--events-source", "Tokens.Bad:events"])

        assert_unchanged(igniter)
        assert [issue] = igniter.issues
        assert issue =~ "which is not a feature name"
      end

      test "I20 the same feature twice creates no file at all" do
        igniter =
          install([
            "--repo",
            "Demo.Repo",
            "--events-source",
            "tokens:events",
            "--events-source",
            "tokens:buffered"
          ])

        assert_unchanged(igniter)
        assert [issue] = igniter.issues
        assert issue =~ "names tokens twice"
      end

      test "I20 a second run keeps a host-edited feature_sources value" do
        args = ["--repo", "Demo.Repo", "--events-source", "tokens:events"]

        applied =
          args
          |> install(files: %{@config => host_sources()})
          |> apply_igniter!()

        assert source(applied, @config) =~ "tokens: :buffered"

        second = Igniter.compose_task(applied, "aurora_meter.install", args)

        assert source(second, @config) =~ "tokens: :buffered"

        assert Enum.any?(second.notices, &(&1 =~ "already sets :feature_sources")),
               "no notice said the existing value was kept: #{inspect(second.notices)}"
      end
    end

    describe "a second run" do
      test "G05 I20 a plain second run changes every file not at all, byte by byte" do
        args = ["--repo", "Demo.Repo"]

        # The first run is applied, so the second starts from a project that
        # already has what the first wrote, which is what a host running the
        # task twice actually has. Composing twice into one igniter would leave
        # the first composition's changes in it and assert nothing.
        applied = install(args) |> apply_igniter!()
        second = Igniter.compose_task(applied, "aurora_meter.install", args)

        assert_unchanged(second)

        for path <- [@config, @application, "lib/demo/plans.ex"] do
          assert source(applied, path) == source(second, path),
                 "#{path} changed on the second run"
        end

        assert migration_body(applied) == migration_body(second)

        # A third, because a task that is idempotent once can still drift.
        third = second |> apply_igniter!() |> Igniter.compose_task("aurora_meter.install", args)
        assert_unchanged(third)
      end

      test "G05 I20 a second run with every option changes no file" do
        args = [
          "--repo",
          "Demo.Repo",
          "--feature-policy",
          "warn",
          "--events-source",
          "tokens:events",
          "--oban"
        ]

        applied = install(args) |> apply_igniter!()

        # Everything the options asked for really is in the first run, so the
        # no-op below is about idempotence and not about a task that did
        # nothing.
        config = source(applied, @config)
        assert config =~ "undeclared_feature_policy: :warn"
        assert config =~ "tokens: :events"
        assert config =~ "aurora_meter:"
        assert config =~ "AuroraMeter.Oban.CreditExpiry"

        second = Igniter.compose_task(applied, "aurora_meter.install", args)

        assert_unchanged(second)

        for path <- [@config, @application, "lib/demo/plans.ex"] do
          assert source(applied, path) == source(second, path),
                 "#{path} changed on the second run"
        end
      end

      test "I20 a second run adds no duplicate supervision child" do
        args = ["--repo", "Demo.Repo"]

        application =
          args
          |> install()
          |> apply_igniter!()
          |> Igniter.compose_task("aurora_meter.install", args)
          |> source(@application)

        assert occurrences(application, "AuroraMeter") == 1
      end
    end

    describe "what the installer will not write" do
      test "I20 no route, no component import and no LiveView reference anywhere" do
        # Invariant I20: the optional integrations stay optional. An installer
        # that imported the components or added a route would make LiveView a
        # requirement of installing at all, whatever mix.exs said.
        igniter = install(["--repo", "Demo.Repo", "--oban", "--events-source", "tokens:events"])

        sources =
          igniter.rewrite
          |> Rewrite.sources()
          |> Enum.map(&{&1.path, Rewrite.Source.get(&1, :content)})

        assert length(sources) >= 4, "expected the installer to have written something"

        for {path, content} <- sources,
            needle <- [
              "AuroraMeter.Components",
              "AuroraMeter.LiveView",
              "AuroraMeter.Plug",
              "Phoenix.Component",
              ~s(live "),
              "aurora_meter_pro",
              "AuroraMeter.Pro"
            ] do
          refute content =~ needle, "#{path} mentions #{needle}"
        end
      end
    end

    describe "the generated migration" do
      test "I19 the body names an explicit range and never calls up/0 or down/0" do
        refute_unbounded(migration_body(install(["--repo", "Demo.Repo"])))
      end

      test "I19 the installer and the generator emit the same body" do
        # They read one plan (`AuroraMeter.Install.Plan`). Before build unit 09b
        # the installer wrote `up()` and the generator wrote a pinned range, so
        # the two supported ways of installing this package produced two
        # different files and only one of them was reproducible.
        [file] = Plan.files(package: :core)
        body = migration_body(install(["--repo", "Demo.Repo"]))

        assert body =~ file.up
        assert body =~ file.down
      end
    end

    describe "the fallback without Igniter" do
      test "I20 the printed steps carry the config block and the options that were passed" do
        # The fallback definition of this task is only compiled on a build with
        # no Igniter, so what is asserted here is the text it prints, which is
        # the part that can be wrong. `AuroraMeter.HeadlessTest` asserts the
        # fallback task itself exists on that build.
        steps =
          Templates.manual_steps(%{policy: :warn, feature_sources: %{tokens: :events}})

        assert steps =~ "config :aurora_meter"
        assert steps =~ "undeclared_feature_policy: :warn"
        assert steps =~ "feature_sources: %{tokens: :events}"
        assert steps =~ "mix ecto.migrate"
        assert steps =~ "--events-source"
        assert steps =~ "--check-support"
        assert steps =~ "--dry-run"

        # And the default, for a run with no options at all.
        assert Templates.manual_steps() =~ "undeclared_feature_policy: :deny"
        refute Templates.manual_steps() =~ "feature_sources"
      end
    end

    # -- helpers ---------------------------------------------------------------

    # L09b-3. Anchored on the shape of a call with no arguments rather than on
    # one spelling of it, so a body that reintroduced `up( )` or `up()` with a
    # space would still be caught.
    defp refute_unbounded(body) do
      for call <- ["up", "down"] do
        refute Regex.match?(~r/AuroraMeter\.Migration\.#{call}\(\s*\)/, body),
               "the generated migration calls #{call}/0 with no version range:\n#{body}"
      end

      assert body =~ "from: 1", "the generated up names no lower bound:\n#{body}"
      assert body =~ "version: ", "the generated body names no upper bound:\n#{body}"
    end

    # A probe that says one dependency is installed and its guarded module is
    # not compiled, and tells the truth about every other row.
    defp stale(app) do
      fn
        ^app, _guard -> {"1.2.0", false}
        other, guard -> real_probe(other, guard)
      end
    end

    defp compiled(app) do
      fn
        ^app, _guard -> {"1.2.0", true}
        other, guard -> real_probe(other, guard)
      end
    end

    defp real_probe(app, guard) do
      resolved =
        case Application.spec(app, :vsn) do
          nil -> nil
          vsn -> List.to_string(vsn)
        end

      {resolved, guard != nil and Code.ensure_loaded?(guard)}
    end

    defp switched_build? do
      Enum.any?(
        ~w(AURORA_HEADLESS AURORA_NO_LIVEVIEW AURORA_NO_METRICS AURORA_NO_DASHBOARD AURORA_NO_OTEL),
        &(System.get_env(&1) == "1")
      )
    end

    defp host_policy(value) do
      """
      import Config

      config :aurora_meter,
        undeclared_feature_policy: #{value}
      """
    end

    defp host_sources do
      """
      import Config

      config :aurora_meter,
        feature_sources: %{tokens: :buffered}
      """
    end

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
