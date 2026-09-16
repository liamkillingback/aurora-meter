defmodule AuroraMeter.OptionalIntegrationsTest do
  @moduledoc """
  Invariant I20, decision D03: the Phoenix, LiveView, Igniter and Oban
  integrations are optional, and the library is usable without them.

  This module carries no tag, so it runs on every CI leg, and it asserts BOTH
  directions from one place: on an ordinary build the optional modules must be
  there, and on the `headless` leg they must not. A one directional assertion
  would pass for the wrong reason the day the optional dependency quietly stopped
  being fetched.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.LiveDashboard.Auth
  alias AuroraMeter.LiveDashboard.Sections
  alias AuroraMeter.OpenTelemetry.Bridge

  defp headless?, do: System.get_env("AURORA_HEADLESS") == "1"
  defp no_metrics?, do: System.get_env("AURORA_NO_METRICS") == "1"
  defp no_live_view?, do: System.get_env("AURORA_NO_LIVEVIEW") == "1"

  # `Code.ensure_loaded?/1` first. `function_exported?/3` answers **false for a
  # function that exists** when its module has not been loaded, and modules load
  # on demand, so the bare form asks "has something already called into this
  # module in this run", which is a question about the seed.
  #
  # On a `refute` it is worse than a flake, and that is why every call site in
  # this file uses the helper: an unloaded module answers `false`, so the
  # refutation passes whether or not the function is there, and the absence the
  # leg exists to prove is never actually tested.
  #
  # The comment in `I20 the installer prints steps instead of raising without
  # Igniter` below has recorded this since build unit 03b. Build unit 09a wrote
  # the bare form anyway, in three places in this file and one in
  # `doc_examples_test.exs`, which is X153: a rule nothing enforces is one
  # already being broken. `AuroraMeter.ExportedIdiomTest` enforces it now.
  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  test "I20 the optional integrations are present exactly when they were not switched off" do
    # The two that only `AURORA_HEADLESS` removes.
    for module <- [Igniter, Oban] do
      assert Code.ensure_loaded?(module) == not headless?(),
             "#{inspect(module)} loaded?=#{Code.ensure_loaded?(module)} with " <>
               "AURORA_HEADLESS=#{inspect(System.get_env("AURORA_HEADLESS"))}. " <>
               "The headless CI leg removes the optional dependencies in mix.exs; " <>
               "every other leg keeps them."
    end

    # `plug` is removed by `AURORA_HEADLESS` and by nothing else: it is
    # deliberately NOT removed with the LiveView pair, because the
    # `AURORA_NO_LIVEVIEW` leg exists precisely to be a build that has Plug and
    # no LiveView (build unit 09a).
    assert Code.ensure_loaded?(Plug.Conn) == not headless?(),
           "Plug.Conn loaded?=#{Code.ensure_loaded?(Plug.Conn)} with " <>
             "AURORA_HEADLESS=#{inspect(System.get_env("AURORA_HEADLESS"))}"

    # The LiveView pair has a switch of its own as well (X337's shape: a test
    # that reads one environment variable is a test about one leg, and a second
    # switch makes it wrong in whichever direction the build happens to be).
    for module <- [Phoenix.Component, Phoenix.HTML] do
      assert Code.ensure_loaded?(module) == not (headless?() or no_live_view?()),
             "#{inspect(module)} loaded?=#{Code.ensure_loaded?(module)} with " <>
               "AURORA_HEADLESS=#{inspect(System.get_env("AURORA_HEADLESS"))} and " <>
               "AURORA_NO_LIVEVIEW=#{inspect(System.get_env("AURORA_NO_LIVEVIEW"))}"
    end

    # `telemetry_metrics` has a narrow switch of its own (`open-findings.md`
    # X327), so it is asserted against BOTH. This clause used to read
    # `== not headless?()` for all five, which meant the `AURORA_NO_METRICS`
    # leg could never have passed this file: `Telemetry.Metrics` is absent on it
    # and `headless?()` is false. 08a ran that leg on Pro only, where this test
    # does not exist, so nothing said so.
    assert Code.ensure_loaded?(Telemetry.Metrics) == not (headless?() or no_metrics?()),
           "Telemetry.Metrics loaded?=#{Code.ensure_loaded?(Telemetry.Metrics)} with " <>
             "AURORA_HEADLESS=#{inspect(System.get_env("AURORA_HEADLESS"))} and " <>
             "AURORA_NO_METRICS=#{inspect(System.get_env("AURORA_NO_METRICS"))}"
  end

  test "I20 AuroraMeter.Plug.EnsureEntitled is compiled exactly when Plug.Conn is available" do
    # lib/aurora_meter/plug/ensure_entitled.ex opens with
    # `if Code.ensure_loaded?(Plug.Conn) do`, the same shape components.ex uses.
    #
    # Written as an equality rather than as a `refute` on the headless leg, so
    # it is non-vacuous on every leg: on an ordinary build it is the positive
    # control (both true), and the day the module stops compiling for some
    # unrelated reason this fails everywhere instead of passing quietly on the
    # one leg that only ever asserts an absence.
    assert Code.ensure_loaded?(AuroraMeter.Plug.EnsureEntitled) ==
             Code.ensure_loaded?(Plug.Conn)

    if Code.ensure_loaded?(Plug.Conn) do
      assert exported?(AuroraMeter.Plug.EnsureEntitled, :init, 1)
      assert exported?(AuroraMeter.Plug.EnsureEntitled, :call, 2)
    end
  end

  test "I20 AURORA_NO_LIVEVIEW removes the LiveView pair and the dashboard, and nothing else" do
    # The narrow-switch rule (X327, X331). This one has to remove
    # `phoenix_live_dashboard` as well, because the dashboard declares
    # `phoenix_live_view` as REQUIRED and leaving it would pull LiveView back in
    # through the other declaration. `plug` must SURVIVE: that is the whole
    # point of the leg.
    if no_live_view?() do
      refute Code.ensure_loaded?(Phoenix.Component)
      refute Code.ensure_loaded?(Phoenix.LiveView)
      refute Code.ensure_loaded?(Phoenix.HTML)
      refute Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)
      refute Code.ensure_loaded?(AuroraMeter.Components)
      refute Code.ensure_loaded?(AuroraMeter.LiveDashboard.Page)

      for still_here <- [Plug.Conn, Igniter, Oban, Telemetry.Metrics] do
        assert Code.ensure_loaded?(still_here),
               "AURORA_NO_LIVEVIEW removed #{inspect(still_here)}, which is not what it is " <>
                 "for. The leg exists to be a host with Plug and no LiveView; a leg that " <>
                 "also removed Plug would say nothing about the plug (X327)."
      end

      # And the half of AuroraMeter.LiveView that needs no LiveView still
      # WORKS, not merely exists. `test/aurora_meter/live_view_test.exs` is
      # guarded on `Phoenix.LiveView` and does not compile on this leg, so
      # without these four lines the leg would assert an export and nothing
      # about behaviour.
      tenant = "plugonly_#{System.unique_integer([:positive])}"

      assert :ok = AuroraMeter.LiveView.subscribe(tenant)
      assert AuroraMeter.LiveView.topics(tenant) == [usage: AuroraMeter.Broadcaster.topic(tenant)]
      assert :ok = AuroraMeter.LiveView.subscribe(tenant, topics: [:usage, :credits])
      assert :ok = AuroraMeter.LiveView.unsubscribe(tenant, topics: [:usage, :credits])

      # `exported?/3`, never bare `function_exported?/3`. On a `refute` the bare
      # form is worse than a flake: an unloaded module answers `false` and the
      # refutation passes for a reason that has nothing to do with the leg. It
      # would have passed here even with the four functions compiled.
      refute exported?(AuroraMeter.LiveView, :on_mount, 4)
      refute exported?(AuroraMeter.LiveView, :switch_tenant, 2)
      refute exported?(AuroraMeter.LiveView, :handle_usage, 2)
    else
      # X337 once more, and this one was caught by running the headless leg
      # rather than by reasoning: `AURORA_HEADLESS` removes the LiveView pair
      # too, so a bare `assert Code.ensure_loaded?(Phoenix.Component)` here
      # makes this test fail on the headless leg, where its `if` branch does not
      # run and its `else` branch is wrong.
      assert Code.ensure_loaded?(Phoenix.Component) == not headless?()
    end
  end

  test "I20 AuroraMeter.Components is compiled exactly when Phoenix.Component is available" do
    # lib/aurora_meter/components.ex opens with
    # `if Code.ensure_loaded?(Phoenix.Component) do`, which is what makes a
    # headless build possible at all.
    assert Code.ensure_loaded?(AuroraMeter.Components) ==
             Code.ensure_loaded?(Phoenix.Component)
  end

  test "I20 the AuroraMeter.Oban namespace is compiled exactly when Oban is available" do
    # lib/aurora_meter/oban.ex and every file under lib/aurora_meter/oban/ open
    # with `if Code.ensure_loaded?(Oban) do`, the same shape components.ex uses.
    # The workers are asserted one by one: the umbrella compiling says nothing
    # about a worker file whose guard was left off.
    for module <- [
          AuroraMeter.Oban,
          AuroraMeter.Oban.ConfigError,
          AuroraMeter.Oban.CreditExpiry,
          AuroraMeter.Oban.HoldReconciliation,
          AuroraMeter.Oban.EventsReplay,
          AuroraMeter.Oban.RecurringGrants,
          AuroraMeter.Oban.PlanTransitions
        ] do
      assert Code.ensure_loaded?(module) == Code.ensure_loaded?(Oban),
             "#{inspect(module)} loaded?=#{Code.ensure_loaded?(module)} with Oban " <>
               "loaded?=#{Code.ensure_loaded?(Oban)}"
    end
  end

  test "I20 the install task exists either way, with or without Igniter" do
    assert Code.ensure_loaded?(Mix.Tasks.AuroraMeter.Install)
    assert function_exported?(Mix.Tasks.AuroraMeter.Install, :run, 1)
  end

  test "I20 the LiveDashboard page is compiled exactly when phoenix_live_dashboard is available" do
    # lib/aurora_meter/live_dashboard/page.ex opens with
    # `if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do`.
    assert Code.ensure_loaded?(AuroraMeter.LiveDashboard.Page) ==
             Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)

    # And the behaviour the page is judged on is NOT behind that guard. The data
    # readers and the authorization contract are plain modules, so a build with
    # no dashboard dependency still compiles and still tests them.
    assert Code.ensure_loaded?(Sections)
    assert Code.ensure_loaded?(Auth)
    assert is_list(Sections.sections())
  end

  test "I20 AURORA_NO_DASHBOARD removes the dashboard dependency and nothing else" do
    # The narrow-switch rule from `open-findings.md` X327: a switch that removes
    # more than the thing it is named for produces a build no host can have, and
    # the leg then tests nothing about the thing it is named for. This asserts
    # the narrowness rather than claiming it.
    if System.get_env("AURORA_NO_DASHBOARD") == "1" do
      refute Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)
      refute Code.ensure_loaded?(AuroraMeter.LiveDashboard.Page)

      for still_here <- [Phoenix.Component, Phoenix.HTML, Igniter, Oban, Telemetry.Metrics] do
        assert Code.ensure_loaded?(still_here),
               "AURORA_NO_DASHBOARD removed #{inspect(still_here)}, which is not what it is " <>
                 "for. A switch that removes four dependencies a host requires builds a " <>
                 "configuration nobody can be in (open-findings.md X327)."
      end
    else
      # X337 again, two switches later: AURORA_NO_LIVEVIEW removes the dashboard
      # too (it declares phoenix_live_view as required) and so does
      # AURORA_HEADLESS, so this else branch has to name every switch that
      # reaches the dashboard rather than assert it is always there. Without the
      # AURORA_NO_LIVEVIEW clause the plug_only leg could never have passed this
      # file; without the AURORA_HEADLESS clause the headless leg could not,
      # which is exactly the defect X337 records against the telemetry_metrics
      # clause and which this line had reintroduced.
      assert Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) ==
               not (no_live_view?() or headless?())
    end
  end

  test "I20 AuroraMeter.OpenTelemetry is compiled exactly when opentelemetry_api is available" do
    # lib/aurora_meter/open_telemetry.ex opens with
    # `if Code.ensure_loaded?(:otel_tracer) do`. Everything the bridge actually
    # DOES lives in AuroraMeter.OpenTelemetry.Bridge, which is never guarded, so
    # the handler rules and the redaction are tested in a build with no
    # OpenTelemetry at all.
    assert Code.ensure_loaded?(AuroraMeter.OpenTelemetry) == Code.ensure_loaded?(:otel_tracer)

    assert Code.ensure_loaded?(Bridge)
    assert is_list(Bridge.default_events())
  end

  test "I20 AURORA_NO_OTEL removes the OpenTelemetry pair and nothing else" do
    # The narrow-switch rule (`open-findings.md` X327, X331). It removes the API
    # and the test-only SDK; everything else optional stays.
    if System.get_env("AURORA_NO_OTEL") == "1" do
      refute Code.ensure_loaded?(:otel_tracer)
      refute Code.ensure_loaded?(AuroraMeter.OpenTelemetry)

      for still_here <- [
            Phoenix.Component,
            Phoenix.HTML,
            Igniter,
            Oban,
            Telemetry.Metrics,
            Phoenix.LiveDashboard.PageBuilder
          ] do
        assert Code.ensure_loaded?(still_here),
               "AURORA_NO_OTEL removed #{inspect(still_here)}, which is not what it is for"
      end

      # And every rule the bridge is judged on is still compiled and still
      # answers, which is the whole point of keeping it out of the guard.
      assert Code.ensure_loaded?(Bridge)
      assert length(Bridge.default_events()) == 6
      assert [:aurora_meter, :track] in Bridge.never_by_default()
    else
      # X337's shape, found by build unit 09a's headless run and NOT introduced
      # by it: `AURORA_HEADLESS` removes the OpenTelemetry pair as well, so this
      # branch asserted the presence of something the headless leg had correctly
      # removed, and the headless leg has been red on this test since 08b landed
      # it. The leg is not part of `mix check`, so nothing said so (X246).
      assert Code.ensure_loaded?(:otel_tracer) == not headless?()
      assert Code.ensure_loaded?(AuroraMeter.OpenTelemetry) == not headless?()

      unless headless?() do
        assert function_exported?(AuroraMeter.OpenTelemetry, :attach, 1)
        assert function_exported?(AuroraMeter.OpenTelemetry, :detach, 0)
        assert function_exported?(AuroraMeter.OpenTelemetry, :detach, 1)
      end
    end
  end

  test "I20 AuroraMeter.Telemetry.Metrics is compiled exactly when Telemetry.Metrics is available" do
    # lib/aurora_meter/telemetry/metrics.ex opens with
    # `if Code.ensure_loaded?(Telemetry.Metrics) do`, the same shape
    # components.ex and the Oban namespace use.
    assert Code.ensure_loaded?(AuroraMeter.Telemetry.Metrics) ==
             Code.ensure_loaded?(Telemetry.Metrics)
  end

  test "I20 AuroraMeter.Telemetry itself never depends on the optional dependency" do
    # The catalogue, the tag rules and the redaction helper are the contract;
    # the presets are a convenience over it. A host without `telemetry_metrics`
    # loses the list and not a single signal, and `lib/` must not reference the
    # preset module anywhere or the guard above would be decorative.
    assert Code.ensure_loaded?(AuroraMeter.Telemetry)
    assert is_list(AuroraMeter.Telemetry.events())
    assert AuroraMeter.Telemetry.redact(%{tenant_key: "org_synthetic"}) == %{}

    # The AST, not a substring. Both modules are named in prose all over the
    # documentation, and a text search cannot tell a sentence about
    # `AuroraMeter.Telemetry.Metrics.metrics/1` from a call to it.
    referencing =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != "lib/aurora_meter/telemetry/metrics.ex",
          references_metrics?(File.read!(path)),
          do: path

    assert referencing == [],
           "lib/ references the optional preset module outside its own guarded " <>
             "file: #{inspect(referencing)}"
  end

  defp references_metrics?(source) do
    {:ok, tree} = Code.string_to_quoted(source)

    {_tree, found} =
      Macro.prewalk(tree, false, fn
        {:__aliases__, _, segments} = node, acc when is_list(segments) ->
          {node, acc or Enum.take(segments, -2) == [:Telemetry, :Metrics]}

        node, acc ->
          {node, acc}
      end)

    found
  end
end

defmodule AuroraMeter.HeadlessTest do
  @moduledoc """
  The half of invariant I20 that can only be asserted on a build with no optional
  dependency present.

  These tests assert the ABSENCE of modules, so they are meaningless, and would
  fail, on an ordinary build. That is why `:headless` is the one tag excluded in
  test/test_helper.exs, and why the `headless` CI leg is the one leg that passes
  `--include headless`.
  """
  use AuroraMeter.DataCase, async: true

  @moduletag :headless

  alias AuroraMeter.Credits
  alias AuroraMeter.Install.Templates
  alias AuroraMeter.LiveDashboard.Auth
  alias AuroraMeter.LiveDashboard.Sections
  alias AuroraMeter.Migration
  alias AuroraMeter.OpenTelemetry.Bridge

  setup do
    assert System.get_env("AURORA_HEADLESS") == "1",
           "the :headless tests only mean anything on a build made with " <>
             "AURORA_HEADLESS=1. Run them with " <>
             "`AURORA_HEADLESS=1 mix test --include headless`."

    :ok
  end

  test "I20 the dashboard page and the OpenTelemetry bridge are absent without their dependencies" do
    refute Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)
    refute Code.ensure_loaded?(AuroraMeter.LiveDashboard.Page)
    refute Code.ensure_loaded?(:otel_tracer)
    refute Code.ensure_loaded?(AuroraMeter.OpenTelemetry)
    refute Code.ensure_loaded?(:otel_simple_processor)

    # And the readers, the authorization contract and the bridge itself are all
    # still here, which is the whole claim: a host with no dashboard and no
    # tracer loses two adapters, not the behaviour behind them.
    assert Code.ensure_loaded?(Sections)
    assert Code.ensure_loaded?(Auth)
    assert Code.ensure_loaded?(Bridge)
    assert {:ok, _config} = Sections.read(:configuration)
  end

  test "I20 Components are not compiled without Phoenix.Component" do
    refute Code.ensure_loaded?(Phoenix.Component)
    refute Code.ensure_loaded?(AuroraMeter.Components)
  end

  test "I20 AuroraMeter.Plug.EnsureEntitled is not compiled without Plug" do
    refute Code.ensure_loaded?(Plug.Conn)
    refute Code.ensure_loaded?(AuroraMeter.Plug.EnsureEntitled)

    # `plug` was already in an ordinary build before build unit 09a declared it,
    # dragged in by phoenix -> phoenix_live_view (X331's shape). This asserts
    # the absence on the leg that removes the lot, so the guard is a fact about
    # the resolved tree rather than about which dependency happened to carry it.
    refute Enum.any?(Application.loaded_applications(), &(elem(&1, 0) == :plug))
  end

  test "I20 AuroraMeter.LiveView.subscribe/1 works with no Phoenix.LiveView loaded" do
    refute Code.ensure_loaded?(Phoenix.LiveView)

    # The half of the module that needs no LiveView is still here and still
    # does what 0.4.0 did, which is the whole claim D03 makes about Phoenix DX:
    # a headless host loses the socket helpers, not the subscription.
    tenant = unique_tenant("headless")

    assert :ok = AuroraMeter.LiveView.subscribe(tenant)
    assert AuroraMeter.LiveView.topics(tenant) == [usage: AuroraMeter.Broadcaster.topic(tenant)]

    :ok = AuroraMeter.track(tenant, :ai_generations, 2)
    :ok = AuroraMeter.Test.broadcast!()
    assert_receive {:aurora_meter, :usage, %{tenant_key: ^tenant, value: 2}}

    assert :ok = AuroraMeter.LiveView.unsubscribe(tenant)

    # And the socket helpers are genuinely absent rather than merely unused.
    # `exported?/3` rather than bare `function_exported?/3`: an unloaded module
    # answers `false` too, and this leg is the one place the absence is the
    # whole claim, so a refutation that cannot tell "absent" from "not yet
    # loaded" is asserting nothing.
    refute exported?(AuroraMeter.LiveView, :on_mount, 4)
    refute exported?(AuroraMeter.LiveView, :switch_tenant, 2)
    refute exported?(AuroraMeter.LiveView, :handle_usage, 2)
  end

  test "I20 the AuroraMeter.Oban namespace is absent without Oban" do
    refute Code.ensure_loaded?(Oban)
    refute Code.ensure_loaded?(AuroraMeter.Oban)
    refute Code.ensure_loaded?(AuroraMeter.Oban.CreditExpiry)
    refute Code.ensure_loaded?(AuroraMeter.Oban.HoldReconciliation)

    # And the operations the workers wrap are still here, which is the whole
    # claim: a host with another scheduler loses the wrappers, not the work.
    assert function_exported?(Credits, :expire_due, 1)
    assert function_exported?(Credits, :reconcile_holds, 1)
  end

  test "I20 AuroraMeter.Telemetry.Metrics is absent without telemetry_metrics" do
    refute Code.ensure_loaded?(Telemetry.Metrics)
    refute Code.ensure_loaded?(AuroraMeter.Telemetry.Metrics)

    # And the contract is entirely here: every event, the tag rules and the
    # redaction helper. A host with no reporter loses the preset list, which is
    # a convenience, and not a signal.
    assert length(AuroraMeter.Telemetry.events()) > 15
    assert AuroraMeter.Telemetry.tag_allow_list() == [:result, :kind, :exporter, :state, :worker]

    assert AuroraMeter.Telemetry.redact(%{tenant_key: "org_synthetic", result: :ok}) ==
             %{result: :ok}

    assert :ok = AuroraMeter.Telemetry.emit_gauges()
  end

  test "I20 the installer prints steps instead of raising without Igniter" do
    refute Code.ensure_loaded?(Igniter)

    # The fallback definition in lib/mix/tasks/aurora_meter.install.ex is a plain
    # Mix.Task that generates the migration and prints what is left to do. The
    # task is not run here, because running it would write a migration into the
    # working tree; what is asserted is that the documented fallback exists and
    # that the printed steps are real.
    # `Code.ensure_loaded?/1` first, and it is not decoration:
    # `function_exported?/3` answers `false` for a module that is merely
    # compiled, and nothing in `lib/` references a Mix task, so whether it
    # happens to be loaded when this test runs depends on the order of the run
    # and on whether the build was cold. Measured during build unit 03b: the
    # first `mix test` on a fresh headless build failed here and the second,
    # identical, passed.
    assert Code.ensure_loaded?(Mix.Tasks.AuroraMeter.Install)
    assert function_exported?(Mix.Tasks.AuroraMeter.Install, :run, 1)
    refute function_exported?(Mix.Tasks.AuroraMeter.Install, :igniter, 1)

    steps = Templates.manual_steps()
    assert is_binary(steps)
    assert steps =~ "config :aurora_meter"
  end

  test "I20 the facade, credits and migrations work with no optional dependency present" do
    tenant = unique_tenant("headless")

    :ok = AuroraMeter.track(tenant, :ai_generations, 3)
    assert AuroraMeter.usage(tenant, :ai_generations) == 3
    assert AuroraMeter.check(tenant, :ai_generations) == :ok

    assert {:ok, _} = Credits.grant(tenant, 5_000_000, reference: "headless-grant")
    assert %{balance: 5_000_000, available: 5_000_000} = Credits.balance(tenant)

    assert is_integer(Migration.latest_version())
    assert Migration.latest_version() >= 1
  end

  # See the identical helper in `AuroraMeter.OptionalIntegrationsTest` above for
  # why the bare `function_exported?/3` is never used here. It matters most in
  # this module: every assertion in it is an absence, and an unloaded module
  # answers `false` to `function_exported?/3` whether or not the function exists,
  # so the bare form would let this whole leg pass without proving anything.
  defp exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
