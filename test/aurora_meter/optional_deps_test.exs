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

  defp headless?, do: System.get_env("AURORA_HEADLESS") == "1"

  test "I20 the optional integrations are present exactly when they were not switched off" do
    for module <- [Phoenix.Component, Phoenix.HTML, Igniter, Oban] do
      assert Code.ensure_loaded?(module) == not headless?(),
             "#{inspect(module)} loaded?=#{Code.ensure_loaded?(module)} with " <>
               "AURORA_HEADLESS=#{inspect(System.get_env("AURORA_HEADLESS"))}. " <>
               "The headless CI leg removes the optional dependencies in mix.exs; " <>
               "every other leg keeps them."
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
  alias AuroraMeter.Migration

  setup do
    assert System.get_env("AURORA_HEADLESS") == "1",
           "the :headless tests only mean anything on a build made with " <>
             "AURORA_HEADLESS=1. Run them with " <>
             "`AURORA_HEADLESS=1 mix test --include headless`."

    :ok
  end

  test "I20 Components are not compiled without Phoenix.Component" do
    refute Code.ensure_loaded?(Phoenix.Component)
    refute Code.ensure_loaded?(AuroraMeter.Components)
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
end
