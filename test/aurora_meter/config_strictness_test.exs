defmodule AuroraMeter.ConfigStrictnessTest do
  @moduledoc false
  # Build unit 02b. Configuration is read whole, defaults live in one place, and
  # module-typed keys are checked against the behaviour they name.
  #
  # async: false: every test here mutates the node's application environment,
  # always through AuroraMeter.Test.Config (build unit 01b), never by hand.
  use ExUnit.Case, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema

  @config_source "lib/aurora_meter/config.ex"

  describe "B01 the whole application environment is validated" do
    test "B01 an unknown key raises in strict mode and warns in transition mode" do
      with_config([{:aurora_meter, :flush_intervall, 500}], fn ->
        assert_raise NimbleOptions.ValidationError, fn -> Config.validate!(:strict) end

        log = capture_log(fn -> assert is_list(Config.validate!(:transition)) end)
        assert log =~ "unknown key"
        assert log =~ ":flush_intervall"
      end)
    end

    test "B01 the unknown-key message names the nearest schema key" do
      message = Schema.unknown_message(:aurora_meter, [:flush_intervall], Config.schema())

      assert message =~ ":flush_intervall"
      assert message =~ "did you mean :flush_interval?"
      assert message =~ "1.0 will refuse to boot"
    end

    test "B01 an unknown key with no near neighbour is still reported" do
      message = Schema.unknown_message(:aurora_meter, [:zzzz], Config.schema())

      assert message =~ ":zzzz"
      refute message =~ "did you mean"
    end

    test "B01 the transition-mode warning does not stop the rest of the configuration" do
      with_config([{:aurora_meter, :nonsense_key, :anything}], fn ->
        {opts, log} = with_log(fn -> Config.validate!(:transition) end)

        assert log =~ ":nonsense_key"
        assert opts[:repo] == AuroraMeter.TestRepo
        assert opts[:flush_interval] == 60_000
        refute Keyword.has_key?(opts, :nonsense_key)
      end)
    end
  end

  describe "B02 reserved keys" do
    test "B02 ecto_repos, included_applications and a repo module key are never reported as unknown" do
      # These three are exactly what the package's own config/config.exs and OTP
      # itself put into :aurora_meter's environment, which is why a naive
      # unknown-key check cannot simply reject everything outside the schema.
      env = Application.get_all_env(:aurora_meter)

      assert Keyword.has_key?(env, :ecto_repos)
      assert Keyword.has_key?(env, AuroraMeter.TestRepo)

      assert Schema.reserved?(:ecto_repos)
      assert Schema.reserved?(:included_applications)
      assert Schema.reserved?(AuroraMeter.TestRepo)
      refute Schema.reserved?(:flush_interval)

      assert Schema.unknown_keys(elem(Schema.split_reserved(env), 1), Config.schema()) == []
    end

    test "B02 a host repo module key boots cleanly in strict mode" do
      with_config([{:aurora_meter, MyApp.Repo, [pool_size: 5]}], fn ->
        assert is_list(Config.validate!(:strict))
      end)
    end
  end

  describe "B03 defaults are written once" do
    test "B03 every accessor returns the schema default when the key is unset" do
      for {key, default} <- Config.defaults() do
        assert without(key, fn -> apply(Config, accessor(key), []) end) == default,
               "accessor for #{inspect(key)} does not return the schema default"
      end
    end

    test "B03 every schema key with a default has an accessor" do
      exported = MapSet.new(Config.__info__(:functions))

      for {key, _default} <- Config.defaults() do
        assert MapSet.member?(exported, {accessor(key), 0}),
               "#{inspect(key)} has a schema default but no zero-arity accessor on AuroraMeter.Config"
      end
    end

    test "B03 no accessor restates a default" do
      # Content, not a line number (open-findings.md X67): there is exactly one
      # place in the module that reads the application environment with a
      # fallback, and it takes the fallback from @defaults.
      source = File.read!(@config_source)
      reads = source |> String.split("Application.get_env(") |> length() |> Kernel.-(1)

      assert reads == 1,
             "#{@config_source} reads the environment with a default in #{reads} places"

      assert source =~ "Application.get_env(:aurora_meter, key, Map.fetch!(@defaults, key))"
    end

    test "B03 the defaults map is the whole optional half of the schema" do
      # `get/1` reads it with `Map.fetch!/2`, so an accessor for a key the schema
      # does not declare fails at its first call rather than inventing a value.
      optional =
        Config.schema().schema
        |> Enum.reject(fn {_key, opts} -> Keyword.get(opts, :required, false) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      assert Config.defaults() |> Map.keys() |> Enum.sort() == optional
      refute Map.has_key?(Config.defaults(), :repo)
    end
  end

  describe "module-typed keys" do
    test "a module-typed key pointing at a module without the callback raises at boot naming the callback" do
      # AuroraMeter.Test.PolicyPlans is a real, loadable module that exports no
      # to_key/1, which is the shape of the mistake this check exists for.
      with_config([{:aurora_meter, :tenant, AuroraMeter.Test.PolicyPlans}], fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message

        assert message =~ "tenant"
        assert message =~ "AuroraMeter.Test.PolicyPlans"
        assert message =~ "to_key/1"
        assert message =~ "AuroraMeter.Tenant"
      end)
    end

    test "the same module-typed key fails AuroraMeter.start_link/1 itself" do
      # `start_link/1` validates before it starts anything, so this raises
      # without touching the tree the suite is already running on.
      with_config([{:aurora_meter, :tenant, AuroraMeter.Test.PolicyPlans}], fn ->
        assert_raise ArgumentError, ~r|does not export to_key/1|, fn ->
          AuroraMeter.start_link([])
        end
      end)

      assert is_pid(Process.whereis(AuroraMeter.Store))
    end

    test "a module-typed key naming a module that cannot be loaded raises at boot" do
      with_config([{:aurora_meter, :period_source, AuroraMeter.NoSuchPeriodSource}], fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message

        assert message =~ "period_source"
        assert message =~ "could not be loaded"
        assert message =~ "AuroraMeter.Period"
      end)
    end

    test "the clock's required callbacks are read from the behaviour, not restated" do
      # The list grew from two to four inside one day; a copy went stale twice.
      assert Schema.required_callbacks(AuroraMeter.Clock) == [
               db_now: 0,
               monotonic_ms: 0,
               now: 0,
               today: 0
             ]

      # And the optional callback of a behaviour that has one is not required.
      assert Schema.required_callbacks(AuroraMeter.Period) == [current: 2]
      assert {:containing, 2} in AuroraMeter.Period.behaviour_info(:callbacks)
    end

    test "every module-typed key in the contract list is checked against a real behaviour" do
      for {key, contract} <- Config.module_contracts() do
        assert Map.has_key?(Config.defaults(), key) or key == :plans,
               "#{inspect(key)} is checked but is not a schema key"

        case contract do
          {:behaviour, behaviour} -> assert Schema.required_callbacks(behaviour) != []
          {:exports, callbacks, _requirement} -> assert callbacks != []
        end
      end
    end
  end

  describe "plans checked at boot" do
    test "a default_plan that no plan declares warns in transition mode and raises in strict mode" do
      with_config([{:aurora_meter, :plans, AuroraMeter.Test.NoDefaultPlanPlans}], fn ->
        log = capture_log(fn -> Config.validate!(:transition) end)

        assert log =~ "default_plan: :free"
        assert log =~ "AuroraMeter.Test.NoDefaultPlanPlans"
        assert log =~ ":something_else"

        message = assert_raise(ArgumentError, fn -> Config.validate!(:strict) end).message
        assert message =~ "default_plan: :free"
      end)
    end

    test "a float unit_price warns once per plan and feature and never raises" do
      with_config([{:aurora_meter, :plans, AuroraMeter.Test.FloatPricePlans}], fn ->
        log = capture_log(fn -> assert is_list(Config.validate!(:strict)) end)

        assert log =~ "plan :free declares :float_priced with a float unit_price (0.05)"
        assert log =~ "plan :pro declares :float_priced with a float unit_price (0.05)"
        assert log =~ "Integer minor units (cents) are the supported form"
      end)
    end

    test "the package's own plans produce no float warning" do
      refute capture_log(fn -> Config.validate!() end) =~ "float unit_price"
    end
  end

  # Build unit 02d. The transition release's one deprecation notice.
  describe "deprecated keys" do
    test "a non-empty durable_features emits one deprecation warning per node at boot" do
      forget_warnings()

      with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
        log = capture_log(fn -> Config.validate!(:transition) end)

        assert log =~ "durable_features"
        assert log =~ "deprecated"
        assert log =~ "feature_sources"
        assert log =~ "docs/upgrading-to-1.0.md"
        assert occurrences(log, "durable_features: [:ai_generations] is deprecated") == 1

        # Once per node, not once per validation: a host that revalidates its
        # configuration (or runs a boot check twice) gets one line, not a stream.
        again = capture_log(fn -> Config.validate!(:transition) end)
        refute again =~ "is deprecated"
      end)
    end

    test "a non-empty durable_features warns in strict mode too and never raises" do
      forget_warnings()

      with_config([{:aurora_meter, :durable_features, [:ai_generations]}], fn ->
        log = capture_log(fn -> assert is_list(Config.validate!(:strict)) end)
        assert log =~ "is deprecated"
      end)
    end

    test "an empty durable_features list emits no warning" do
      forget_warnings()

      with_config([{:aurora_meter, :durable_features, []}], fn ->
        log = capture_log(fn -> Config.validate!(:transition) end)
        refute log =~ "durable_features"
      end)
    end

    test "durable_features unset emits no warning, because the default is the empty list" do
      forget_warnings()

      with_config([{:aurora_meter, :durable_features, :__placeholder__}], fn ->
        Application.delete_env(:aurora_meter, :durable_features)
        log = capture_log(fn -> Config.validate!(:transition) end)
        refute log =~ "durable_features"
      end)
    end
  end

  describe "release strictness" do
    test "Config.Schema.mode/0 matches the version in mix.exs" do
      version = Mix.Project.config()[:version]

      assert Schema.version() == version
      assert Schema.mode() == Schema.mode(version)
      assert Schema.mode() in [:transition, :strict]
    end

    test "the strictness threshold is 1.0.0-rc.0 and the policy default follows it" do
      assert Schema.mode("0.4.0") == :transition
      # 0.5.0 is the transition release itself (build unit 02d). It has to warn,
      # not deny: a release that silently starts denying undeclared features is
      # the outcome D04 exists to prevent, and the version bump is exactly the
      # kind of change that could flip a version-derived constant by accident.
      assert Schema.mode("0.5.0") == :transition
      assert Schema.mode("0.5.3") == :transition
      assert Schema.mode("1.0.0-rc.0") == :strict
      assert Schema.mode("1.0.0-rc.1") == :strict
      assert Schema.mode("1.0.0") == :strict

      expected = if Schema.mode() == :transition, do: :warn, else: :deny
      assert Schema.default_undeclared_feature_policy() == expected
      assert Config.defaults()[:undeclared_feature_policy] == expected
    end
  end

  # `with_config/2` snapshots the key before it overrides it and restores that
  # snapshot on the way out, including deleting a key that was absent, so
  # deleting inside the region is safe.
  defp without(key, fun) do
    with_config([{:aurora_meter, key, :__placeholder__}], fn ->
      Application.delete_env(:aurora_meter, key)
      fun.()
    end)
  end

  defp accessor(:history), do: :history?
  defp accessor(:cluster_sync), do: :cluster_sync?
  defp accessor(key), do: key

  defp forget_warnings do
    Schema.reset_warnings!()
    on_exit(&Schema.reset_warnings!/0)
  end

  defp occurrences(haystack, needle), do: length(String.split(haystack, needle)) - 1
end
