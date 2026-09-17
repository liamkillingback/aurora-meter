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
    alias AuroraMeter.Oban.CreditExpiry

    doctest AuroraMeter.Oban

    @cron_expression ~r/^[\d*\/,\- ]+$/
    @scheduler_doc "docs/operations/scheduler.md"

    # The longest uniqueness period either package permits itself, and therefore
    # the worst time one node death can stop a worker (`open-findings.md` X486).
    @ceiling 3_600

    describe "cron_entries/1" do
      test "returns one entry per available worker that has a schedule" do
        assert Scheduler.cron_entries() == [
                 {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
                 {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation},
                 {"7 * * * *", AuroraMeter.Oban.RecurringGrants},
                 {"*/5 * * * *", AuroraMeter.Oban.PlanTransitions},
                 {"40 3 * * *", AuroraMeter.Oban.Retention}
               ]
      end

      test "a worker whose operation module arrived is scheduled by that fact alone" do
        # This was the "omits a worker whose operation module is absent" case
        # until build unit 06d shipped `AuroraMeter.Credits.Recurrences`, and
        # PlanTransitions was the last absent half until 07b shipped
        # `apply_due_transitions/1`. Neither worker's source changed; the
        # predicate did, which is what `AuroraMeter.Oban`'s availability rule
        # promises.
        assert Code.ensure_loaded?(AuroraMeter.Credits.Recurrences)
        assert Scheduler.available?({AuroraMeter.Credits.Recurrences, :run, 1})
        assert AuroraMeter.Oban.RecurringGrants in scheduled_workers()

        assert Scheduler.available?({AuroraMeter.Subscriptions, :apply_due_transitions, 1})
        assert AuroraMeter.Oban.PlanTransitions in scheduled_workers()
      end

      test "omits a worker whose operation module exists without the function" do
        # The half of the predicate `Code.ensure_loaded?/1` alone cannot answer:
        # the module IS loaded, so only `function_exported?/3` can tell a
        # present operation from an absent one. Every registry entry names a
        # function that exists today, so the absent case is written by hand
        # rather than borrowed from whichever worker happens to be waiting.
        assert Code.ensure_loaded?(AuroraMeter.Subscriptions)
        assert Scheduler.available?({AuroraMeter.Subscriptions, :get, 1})
        refute Scheduler.available?({AuroraMeter.Subscriptions, :no_such_operation, 1})

        refute Enum.any?(Scheduler.__registry__(), fn {_worker, operation, _cron, _description} ->
                 not Scheduler.available?(operation)
               end)
      end

      test "an available operation is what makes a worker appear" do
        # The positive half of the same predicate, read the same way.
        assert Scheduler.available?({AuroraMeter.Credits, :expire_due, 1})
        assert Scheduler.available?({AuroraMeter.Credits, :reconcile_holds, 1})

        assert scheduled_workers() == [
                 AuroraMeter.Oban.CreditExpiry,
                 AuroraMeter.Oban.HoldReconciliation,
                 AuroraMeter.Oban.RecurringGrants,
                 AuroraMeter.Oban.PlanTransitions,
                 AuroraMeter.Oban.Retention
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
                 [
                   {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation},
                   {"7 * * * *", AuroraMeter.Oban.RecurringGrants},
                   {"*/5 * * * *", AuroraMeter.Oban.PlanTransitions},
                   {"40 3 * * *", AuroraMeter.Oban.Retention}
                 ]

        assert Scheduler.cron_entries(
                 exclude: [:hold_reconciliation, :retention, :recurring_grants, :plan_transitions]
               ) == [{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}]
      end

      test "honours :schedules, including for a worker that has no default" do
        assert Scheduler.cron_entries(schedules: %{hold_reconciliation: "0 * * * *"}) == [
                 {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
                 {"0 * * * *", AuroraMeter.Oban.HoldReconciliation},
                 {"7 * * * *", AuroraMeter.Oban.RecurringGrants},
                 {"*/5 * * * *", AuroraMeter.Oban.PlanTransitions},
                 {"40 3 * * *", AuroraMeter.Oban.Retention}
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
          assert Scheduler.validate!(config: config, rescue: :ignore) == :ok
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

    # -- X486: the rescue plugin neither package had ever mentioned -------------

    describe "X486 the missing Lifeline" do
      test "warns, and does not raise, when Aurora Meter work is scheduled with no Lifeline" do
        config = base_config(plugins: cron_plugin(crontab: Scheduler.cron_entries()))

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert Scheduler.validate!(config: config) == :ok
          end)

        assert log =~ "Lifeline"
        assert log =~ "executing"
      end

      test "says nothing once a Lifeline is configured" do
        assert Scheduler.rescue_advice(base_config()) == []
      end

      test "accepts any Lifeline, so a host on Oban Pro's DynamicLifeline is not scolded" do
        # Compared as a name suffix. Core must not reference an `Oban.Pro.*`
        # module, and the Pro plugin is the better answer for a host that has
        # it, so a check that named one module would tell the host with the
        # better one to install the worse one.
        # Written as a literal atom rather than as an alias, because
        # `Oban.Pro.Plugins.DynamicLifeline` is not a dependency of this package
        # and never will be: a host writes it in its own configuration and this
        # check only ever sees the name.
        dynamic_lifeline = :"Elixir.Oban.Pro.Plugins.DynamicLifeline"

        pro_style =
          base_config(
            plugins: cron_plugin(crontab: Scheduler.cron_entries()) ++ [{dynamic_lifeline, []}]
          )

        assert Scheduler.rescue_advice(pro_style) == []
      end

      test "says nothing when no Aurora Meter worker is scheduled at all" do
        # A host driving the operations from its own scheduler has no Oban job
        # to orphan. Advice it does not need is advice it learns to ignore.
        assert Scheduler.rescue_advice(
                 base_config(plugins: cron_plugin(crontab: [{"* * * * *", SomeHost.Worker}]))
               ) == []
      end

      test "rescue: :require turns the warning into a refusal naming the plugin" do
        config = base_config(plugins: cron_plugin(crontab: Scheduler.cron_entries()))

        error =
          assert_raise ConfigError, fn ->
            Scheduler.validate!(config: config, rescue: :require)
          end

        assert error.message =~ "Oban.Plugins.Lifeline"
        assert length(error.problems) == 1
      end

      test "an unrecognised :rescue mode is refused rather than ignored" do
        # `rescue: :warm` would otherwise behave exactly like `:ignore`, which
        # is the one outcome whoever typed it did not intend.
        assert_raise ArgumentError, ~r/:warn, :require or :ignore/, fn ->
          Scheduler.validate!(config: base_config(), rescue: :warm)
        end
      end

      test "rescue: :ignore says nothing and logs nothing" do
        config = base_config(plugins: cron_plugin(crontab: Scheduler.cron_entries()))

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            assert Scheduler.validate!(config: config, rescue: :ignore) == :ok
          end)

        refute log =~ "Lifeline"
      end
    end

    # -- X486: the wedge itself ------------------------------------------------

    describe "X486 a job wedged executing by a dead node" do
      # The behavioural half of this lives in Aurora Meter Pro's
      # `AuroraMeter.Pro.ObanWedgeTest`, which plants the row a killed node
      # leaves and asserts that the next enqueue is a new job. It covers **these**
      # workers too, by reading `__registry__/0`. It cannot live here: core's
      # dependency on Oban is optional, so this suite starts no Oban instance and
      # carries no `oban_jobs` table, and a test that cannot insert a job cannot
      # watch one being refused.
      #
      # What is left here is the property that makes the bound a bound, and it is
      # worth having in both places: Pro can be absent, and core's workers are
      # then wedged with nobody watching.

      test "no worker declares an infinite period beside :executing" do
        for {worker, unique} <- unique_workers() do
          assert is_integer(unique.period), """
          #{inspect(worker)} declares `period: #{inspect(unique.period)}` with :executing
          among its uniqueness states.

          A node killed while this worker runs leaves its job `executing` for ever, because
          nothing observes the death. An infinite period never lapses, so every later
          enqueue is deduplicated against that corpse and the worker stops permanently.
          That is `open-findings.md` X486, measured against Pro's outbox deliverer in soak
          run 1: delivery stopped at 09:24:16 and never resumed.

          Bound it. #{@scheduler_doc} states the rule.
          """

          assert unique.period <= @ceiling, """
          #{inspect(worker)} declares `period: #{unique.period}`, longer than the
          #{@ceiling} second ceiling #{@scheduler_doc} states. The period is the worst time
          this worker is stopped by one node death.
          """
        end
      end

      test "the scan reads the resolved options, not the declaration" do
        # `unique: [period: 60]` with no `:states` inherits Oban's defaults,
        # which include `:executing`. A check that read `__opts__()` would not
        # see it. Pro has a worker written exactly that way.
        assert %{states: states} = unique(CreditExpiry.new(%{}))
        assert :executing in states
        assert length(unique_workers()) >= 5
      end

      test "the periods are the ones the scheduler map publishes" do
        published =
          for cells <- period_table(),
              period = Enum.at(cells, 2),
              period =~ ~r/^\d+$/,
              into: %{},
              do: {module_cell(Enum.at(cells, 0)), String.to_integer(period)}

        declared = Map.new(unique_workers(), fn {worker, unique} -> {worker, unique.period} end)

        assert published == declared, """
        #{@scheduler_doc} and the workers disagree about the uniqueness periods.

        document: #{inspect(published)}
        workers : #{inspect(declared)}
        """
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

        # Only one left. `AuroraMeter.Oban.PlanTransitions` carried no cron
        # cell while its operation was absent and gained one in build unit 07b
        # with no edit to the worker, which is what the availability predicate
        # is for.
        assert unscheduled == [AuroraMeter.Oban.EventsReplay]

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

    # The configuration `docs/operations/scheduler.md` recommends, Lifeline
    # included. It gained the plugin with X486: the documented configuration and
    # the one the tests call "fine" have to be the same configuration, or the
    # warning this unit added would be firing through half of this file and
    # nobody would read it.
    defp base_config(overrides \\ []) do
      Keyword.merge(
        [
          repo: Application.get_env(:aurora_meter, :repo),
          queues: [aurora_meter: 5],
          plugins:
            cron_plugin(crontab: Scheduler.cron_entries()) ++
              [{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)}]
        ],
        overrides
      )
    end

    # The **resolved** uniqueness, as the engine computes it, rather than the
    # literal keyword list a worker declared.
    defp unique(changeset), do: Ecto.Changeset.get_change(changeset, :unique)

    defp unique_workers do
      for {worker, _mfa, _schedule, _description} <- Scheduler.__registry__(),
          resolved = unique(worker.new(%{})),
          is_map(resolved),
          :executing in resolved.states,
          do: {worker, resolved}
    end

    # Bounded to the first table after its own marker, the way `scheduler_table/0`
    # is: an unanchored scan for `| \`AuroraMeter.Oban.` reads the worker table
    # higher up the page, whose third cell is a cron expression rather than a
    # number, and a reader that crashes on the wrong table is a reader nobody
    # believes.
    defp period_table do
      @scheduler_doc
      |> File.read!()
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "<!-- scheduler:periods -->")))
      |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
      |> Enum.take_while(&String.starts_with?(&1, "|"))
      |> Enum.drop(2)
      |> Enum.map(fn line ->
        line
        |> String.trim()
        |> String.trim("|")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
      end)
    end

    # `rescue: :ignore` by default. Every caller of this helper is about some
    # other check, and a config built to fail one check is usually missing the
    # Lifeline as well; without this the X486 warning is logged through half
    # this file and stops meaning anything. The rescue tests pass the mode
    # themselves.
    defp raised(opts) do
      assert_raise(ConfigError, fn ->
        Scheduler.validate!(Keyword.put_new(opts, :rescue, :ignore))
      end)
    end

    # Bounded to the **first** table after the marker.
    #
    # It used to take every `|` line to the end of the file, and when X486 added
    # a second table lower down the page this reader swallowed it: fourteen rows
    # where there are six workers, `Worker` parsed as a module from a header
    # cell, and `binary_to_integer("Stopped for at most")`. Pro's equivalent
    # reader was bounded when the same thing happened to it; core's was not, and
    # the difference was invisible while there was only one table.
    defp scheduler_table do
      @scheduler_doc
      |> File.read!()
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "<!-- scheduler:core -->")))
      |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
      |> Enum.take_while(&String.starts_with?(&1, "|"))
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
        plugins: [
          {Oban.Plugins.Cron, crontab: Scheduler.cron_entries()},
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)}
        ]
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
