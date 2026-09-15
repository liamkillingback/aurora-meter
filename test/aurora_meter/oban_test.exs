# The whole file is compiled only when Oban is, exactly like the code it tests.
# On the `headless` CI leg there is no `AuroraMeter.Oban` to test and the
# absence is asserted by `AuroraMeter.HeadlessTest` instead.
if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.ObanTest do
    @moduledoc """
    The registry, `cron_entries/1`, `validate!/1` and the result mapping.

    It reads configuration and reflects on compiled modules. It opens no
    database connection, starts nothing and mutates nothing, so it is
    `async: true`. The one test that needs `Application.put_env/3` lives in its
    own `async: false` module at the bottom of this file (`open-findings.md`
    X165).
    """
    use ExUnit.Case, async: true

    alias AuroraMeter.Oban, as: Scheduler
    alias AuroraMeter.Oban.ConfigError

    doctest AuroraMeter.Oban

    @cron_expression ~r/^[\d*\/,\- ]+$/
    @scheduler_doc "docs/operations/scheduler.md"

    describe "cron_entries/1" do
      test "returns one entry per available worker that has a schedule" do
        assert Scheduler.cron_entries() == [
                 {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
                 {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation}
               ]
      end

      test "omits a worker whose operation module is not compiled into this build" do
        # RecurringGrants is absent because its whole operation module is
        # absent. The assertion names that reason rather than only the absence,
        # so a renamed worker cannot make this pass for the wrong cause.
        refute Code.ensure_loaded?(AuroraMeter.Credits.Recurrences)
        refute Scheduler.available?({AuroraMeter.Credits.Recurrences, :run, 1})
        refute AuroraMeter.Oban.RecurringGrants in scheduled_workers()
      end

      test "omits a worker whose operation module exists without the function" do
        # PlanTransitions is the other half of the predicate and the one that
        # discriminates: the module IS loaded, so only `function_exported?/3`
        # can answer. `Code.ensure_loaded?/1` alone would schedule it.
        assert Code.ensure_loaded?(AuroraMeter.Subscriptions)
        assert Scheduler.available?({AuroraMeter.Subscriptions, :get, 1})
        refute Scheduler.available?({AuroraMeter.Subscriptions, :apply_due_transitions, 1})
        refute AuroraMeter.Oban.PlanTransitions in scheduled_workers()
      end

      test "an available operation is what makes a worker appear" do
        # The positive half of the same predicate, read the same way.
        assert Scheduler.available?({AuroraMeter.Credits, :expire_due, 1})
        assert Scheduler.available?({AuroraMeter.Credits, :reconcile_holds, 1})

        assert scheduled_workers() == [
                 AuroraMeter.Oban.CreditExpiry,
                 AuroraMeter.Oban.HoldReconciliation
               ]
      end

      test "EventsReplay has an available operation and is still not scheduled" do
        # Availability is not the reason this one is absent: a projection
        # rebuild is an operator action, so its registry entry carries no
        # schedule at all.
        assert Scheduler.available?({AuroraMeter.Events.Replay, :run, 1})
        refute AuroraMeter.Oban.EventsReplay in scheduled_workers()

        assert {AuroraMeter.Oban.EventsReplay, _operation, nil, _description} =
                 List.keyfind(Scheduler.__registry__(), AuroraMeter.Oban.EventsReplay, 0)
      end

      test "honours :include, by module and by short name" do
        assert Scheduler.cron_entries(include: [AuroraMeter.Oban.CreditExpiry]) ==
                 [{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}]

        assert Scheduler.cron_entries(include: [:credit_expiry]) ==
                 [{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}]
      end

      test "honours :exclude, by module and by short name" do
        assert Scheduler.cron_entries(exclude: [AuroraMeter.Oban.CreditExpiry]) ==
                 [{"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation}]

        assert Scheduler.cron_entries(exclude: [:hold_reconciliation]) ==
                 [{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}]
      end

      test "honours :schedules, including for a worker that has no default" do
        assert Scheduler.cron_entries(schedules: %{hold_reconciliation: "0 * * * *"}) == [
                 {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
                 {"0 * * * *", AuroraMeter.Oban.HoldReconciliation}
               ]

        assert Scheduler.cron_entries(
                 include: [:events_replay],
                 schedules: %{events_replay: "0 4 * * *"}
               ) == [{"0 4 * * *", AuroraMeter.Oban.EventsReplay}]
      end

      test "every registry entry names a worker that exists and declares the queue" do
        for {worker, _operation, _schedule, description} <- Scheduler.__registry__() do
          assert Code.ensure_loaded?(worker), "#{inspect(worker)} is in the registry and absent"
          assert worker.__opts__()[:queue] == Scheduler.queue()
          assert is_binary(description) and description != ""
        end
      end
    end

    describe "validate!/1" do
      test "returns :ok for the crontab cron_entries/1 produced" do
        assert Scheduler.validate!(config: base_config()) == :ok
      end

      test "raises when the aurora_meter queue is absent" do
        error = raised(config: base_config(queues: [default: 10]))

        assert error.message =~ ":queues"
        assert error.message =~ "aurora_meter"
      end

      test "raises when the queue limit is zero" do
        assert raised(config: base_config(queues: [aurora_meter: 0])).message =~ "limit is 0"

        assert raised(config: base_config(queues: [aurora_meter: [limit: 0]])).message =~
                 "limit is 0"
      end

      test "raises when the Oban repo differs from the configured Aurora repo" do
        error = raised(config: base_config(repo: SomeOther.Repo))

        assert error.message =~ ":repo"
        assert error.message =~ "SomeOther.Repo"
        assert error.message =~ inspect(Application.get_env(:aurora_meter, :repo))
      end

      test "raises when the Oban configuration has no repo at all" do
        assert raised(config: Keyword.delete(base_config(), :repo)).message =~ "no `:repo`"
      end

      test "raises when a crontab names an AuroraMeter.Oban module this build lacks" do
        # A module outside the namespace is not this check's business: a host's
        # own worker may legitimately be compiled elsewhere, and refusing it
        # would make the validator wrong about somebody else's code.
        assert Scheduler.validate!(
                 config: base_config(plugins: cron_plugin(crontab: [{"* * * * *", Absent}]))
               ) == :ok

        error =
          raised(
            config:
              base_config(
                plugins: cron_plugin(crontab: [{"* * * * *", AuroraMeter.Oban.Missing}])
              )
          )

        assert error.message =~ ":crontab"
        assert error.message =~ "AuroraMeter.Oban.Missing"
      end

      test "raises when the crontab names one worker twice" do
        entries = [
          {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
          {"0 4 * * *", AuroraMeter.Oban.CreditExpiry}
        ]

        error = raised(config: base_config(plugins: cron_plugin(crontab: entries)))

        assert error.message =~ "2 times"
      end

      test "raises when both the core and the Pro expiry workers are registered" do
        # The crontab is supplied as data. Core never references the Pro module:
        # the check compares module-name strings, which is why this test can
        # name a module that is not a dependency of this package.
        entries = [
          {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
          {"*/30 * * * *", AuroraMeter.Pro.Credits.Expirer}
        ]

        error = raised(config: base_config(plugins: cron_plugin(crontab: entries)))

        # X125: name the layer that answered. Two of this validator's own checks
        # could refuse a two-entry crontab and only one of them is under test.
        # These are two DIFFERENT modules, so the duplicate-entry check cannot
        # be what fired, and the message must not claim it did.
        assert error.message =~ "AuroraMeter.Pro.Credits.Expirer"
        assert error.message =~ "deprecated"
        refute error.message =~ "times, so every tick"
        assert length(error.problems) == 1
      end

      test "either expiry worker alone is accepted" do
        # The other half of the discrimination: the check must not fire on a
        # crontab carrying only one of them, or it would refuse the supported
        # configuration as well as the unsupported one.
        for worker <- [AuroraMeter.Oban.CreditExpiry, AuroraMeter.Pro.Credits.Expirer] do
          config = base_config(plugins: cron_plugin(crontab: [{"*/30 * * * *", worker}]))
          assert Scheduler.validate!(config: config) == :ok
        end
      end

      test "raises on an unresolvable cron timezone and accepts a resolvable one" do
        ok = base_config(plugins: cron_plugin(crontab: [], timezone: "Etc/UTC"))
        assert Scheduler.validate!(config: ok) == :ok

        error =
          raised(config: base_config(plugins: cron_plugin(crontab: [], timezone: "Mars/Olympus")))

        assert error.message =~ ":timezone"
        assert error.message =~ "Mars/Olympus"
      end

      test "raises when :testing is left on outside the test environment" do
        config = base_config(testing: :manual)

        # `:env` is what makes this testable without mutating Mix's environment,
        # which is global and would make the whole module `async: false`.
        assert Scheduler.validate!(config: config, env: :test) == :ok

        error = raised(config: config, env: :prod)
        assert error.message =~ ":testing"
        assert error.message =~ ":manual"
      end

      test "reports every problem in one pass" do
        error =
          raised(
            config: [
              repo: SomeOther.Repo,
              queues: [],
              plugins: cron_plugin(crontab: [], timezone: "Mars/Olympus")
            ]
          )

        assert length(error.problems) == 3
      end

      test "raises ArgumentError when told neither :config nor :otp_app" do
        assert_raise ArgumentError, ~r/:config/, fn -> Scheduler.validate!([]) end
      end

      test "accepts a queue name other than the default" do
        assert Scheduler.validate!(config: base_config(queues: [other: 3]), queue: :other) == :ok
      end
    end

    describe "result/1, the one place a worker maps an operation's return" do
      test "maps every documented shape and refuses to raise on an unknown one" do
        assert Scheduler.result(:ok) == :ok
        assert Scheduler.result({:ok, 3}) == {:ok, 3}
        assert Scheduler.result({:ok, %{examined: 0}}) == {:ok, %{examined: 0}}
        assert Scheduler.result({:error, :boom}) == {:error, :boom}
        assert Scheduler.result({:cancel, :not_implemented}) == {:cancel, :not_implemented}
        assert Scheduler.result(:surprise) == {:error, {:unexpected_return, :surprise}}
      end
    end

    describe "the scheduler map" do
      test "docs/operations/scheduler.md lists exactly the entries cron_entries/1 returns" do
        rows = scheduler_rows()
        assert length(rows) == length(Scheduler.__registry__())

        scheduled =
          for {worker, schedule} <- rows,
              Regex.match?(@cron_expression, schedule),
              do: {schedule, worker}

        assert scheduled == Scheduler.cron_entries(), """
        #{@scheduler_doc} and AuroraMeter.Oban.cron_entries/1 disagree.

        document: #{inspect(scheduled)}
        registry: #{inspect(Scheduler.cron_entries())}

        The two published Pro schedules drifted exactly this way. The table is
        the map an operator copies; it may not invent a schedule the registry
        does not have.
        """
      end

      test "a worker with no cron cell exists and is not scheduled" do
        unscheduled =
          for {worker, schedule} <- scheduler_rows(),
              not Regex.match?(@cron_expression, schedule),
              do: worker

        assert unscheduled == [
                 AuroraMeter.Oban.EventsReplay,
                 AuroraMeter.Oban.RecurringGrants,
                 AuroraMeter.Oban.PlanTransitions
               ]

        for worker <- unscheduled do
          assert Code.ensure_loaded?(worker)
          refute worker in scheduled_workers()
        end
      end

      test "the document's max_attempts column matches what each worker declares" do
        for {worker, attempts} <- scheduler_attempts() do
          assert worker.__opts__()[:max_attempts] == attempts,
                 "#{@scheduler_doc} says #{inspect(worker)} has max_attempts #{attempts}"
        end
      end
    end

    # -- helpers ---------------------------------------------------------------

    defp scheduled_workers, do: Enum.map(Scheduler.cron_entries(), &elem(&1, 1))

    defp cron_plugin(opts), do: [{Oban.Plugins.Cron, opts}]

    defp base_config(overrides \\ []) do
      Keyword.merge(
        [
          repo: Application.get_env(:aurora_meter, :repo),
          queues: [aurora_meter: 5],
          plugins: cron_plugin(crontab: Scheduler.cron_entries())
        ],
        overrides
      )
    end

    defp raised(opts), do: assert_raise(ConfigError, fn -> Scheduler.validate!(opts) end)

    defp scheduler_table do
      @scheduler_doc
      |> File.read!()
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "<!-- scheduler:core -->")))
      |> Enum.filter(&String.starts_with?(&1, "|"))
      |> Enum.drop(2)
      |> Enum.map(fn line ->
        line
        |> String.trim()
        |> String.trim("|")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
      end)
    end

    defp scheduler_rows do
      for cells <- scheduler_table(),
          do: {module_cell(Enum.at(cells, 0)), code(Enum.at(cells, 2))}
    end

    defp scheduler_attempts do
      for cells <- scheduler_table(),
          do: {module_cell(Enum.at(cells, 0)), String.to_integer(Enum.at(cells, 3))}
    end

    defp module_cell(cell), do: Module.concat([code(cell)])

    defp code(cell) do
      case Regex.run(~r/^`(.+)`$/, cell) do
        [_, text] -> text
        _ -> cell
      end
    end
  end

  defmodule AuroraMeter.ObanConfigLookupTest do
    @moduledoc """
    `validate!(otp_app:)` reads an application environment, so this module writes
    one key and is `async: false` (`open-findings.md` X165: a config region does
    not protect against a concurrent reader).
    """
    use ExUnit.Case, async: false

    alias AuroraMeter.Oban, as: Scheduler

    setup do
      on_exit(fn -> Application.delete_env(:aurora_meter_test, MyHost.Oban) end)
      :ok
    end

    test "accepts :otp_app and :name as an alternative to :config" do
      config = [
        repo: Application.get_env(:aurora_meter, :repo),
        queues: [aurora_meter: 5],
        plugins: [{Oban.Plugins.Cron, crontab: Scheduler.cron_entries()}]
      ]

      Application.put_env(:aurora_meter_test, MyHost.Oban, config)
      assert Scheduler.validate!(otp_app: :aurora_meter_test, name: MyHost.Oban) == :ok

      Application.put_env(:aurora_meter_test, MyHost.Oban, Keyword.put(config, :queues, []))

      assert_raise AuroraMeter.Oban.ConfigError, fn ->
        Scheduler.validate!(otp_app: :aurora_meter_test, name: MyHost.Oban)
      end
    end
  end
end
