defmodule AuroraMeter.ConfigSchemaColdTest do
  @moduledoc """
  `AuroraMeter.Config.Schema.ensure_exports!/4`, asked from a process that has
  never touched the module it is asked about (repair unit R8, `open-findings.md`
  X426 and X435).

  ## Why this file exists

  `ensure_exports!/4` is the boot-time contract check: `AuroraMeter.Config` runs
  it over every host-configured module, and X374 turned out to depend on it. It
  asks `function_exported?/3`, **which answers false for a module that is merely
  not loaded yet**, and a host-configured module is the least likely one in the
  system to be loaded: nothing has referenced a host's clock or plans module when
  configuration is validated.

  It is safe anyway, because the statement above the check is
  `if not Code.ensure_loaded?(module), do: raise`. That is an argument, and X426
  is what an argument is worth on its own: the same reasoning was applied to
  `LotMigration.cutover_blocked/0`, was wrong, and no install anywhere could move
  a wallet onto credit lots. So the argument is measured here instead.

  The shape is 11a's in `credits/lot_cutover_gate_test.exs`: clear anything that
  could answer the question by accident, unload the module, confirm the trap is
  real in this VM, and only then ask. `async: false`, because unloading a module
  is a node-wide act.

  ## Both directions

  A test that only proved "cold does not raise" would pass for a check that had
  been wired open and would accept a module missing every callback. The second
  test below puts a module that genuinely lacks the function to the same call and
  requires it to raise.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Config.Schema
  alias AuroraMeter.Test.ExportProbes.Complete
  alias AuroraMeter.Test.ExportProbes.Partial

  # The probes live in `test/support`, not in this file. A module defined inside
  # an `.exs` has no `.beam` on the code path, so purging it makes
  # `Code.ensure_loaded?/1` answer false for ever and the check below then
  # refuses it for the wrong reason entirely. The first version of this file did
  # exactly that and all three tests failed, which is the only reason the
  # mistake was visible.
  @contract {:exports, [{:ping, 0}, {:describe, 1}], "a module exporting ping/0 and describe/1"}

  setup do
    on_exit(fn ->
      Code.ensure_loaded!(Complete)
      Code.ensure_loaded!(Partial)
    end)

    :ok
  end

  test "I20 X426 ensure_exports!/4 accepts a module nothing has loaded" do
    unload!(Complete)

    refute :erlang.module_loaded(Complete),
           "the module is still loaded, so this test is not asking the question a host asks"

    # The trap itself, asserted rather than remembered. If this ever answers
    # true, the `Code.ensure_loaded?/1` above the check can go.
    refute function_exported?(Complete, :ping, 0),
           "function_exported?/3 now answers true for an unloaded module"

    assert Schema.ensure_exports!(:aurora_meter, :probe, Complete, @contract) == :ok,
           "a boot-time contract check refused a module that exports the contract, because " <>
             "nothing had happened to load it yet. That is X426 in the boot path."
  end

  test "I20 X426 and still refuses a module that really lacks the function" do
    # The other direction. Without this the test above passes for a check that
    # has stopped checking.
    unload!(Partial)
    refute :erlang.module_loaded(Partial)

    assert_raise ArgumentError, ~r/does not export describe\/1/, fn ->
      Schema.ensure_exports!(:aurora_meter, :probe, Partial, @contract)
    end
  end

  test "I20 and still refuses a module that cannot be loaded at all" do
    assert_raise ArgumentError, ~r/could not be loaded/, fn ->
      Schema.ensure_exports!(:aurora_meter, :probe, NoSuchModuleAnywhere, @contract)
    end
  end

  defp unload!(module) do
    :code.delete(module)
    :code.purge(module)
    :ok
  end
end
