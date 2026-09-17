defmodule AuroraMeter.Credits.LotCutoverGateTest do
  @moduledoc """
  The cutover gate, asked the way a host asks it (build unit 11a, finding X426).

  `AuroraMeter.Credits.LotMigration.cutover_blocked/0` decides whether a wallet
  may be moved onto credit lots. It is a behavioural probe: it asks whether the
  lot-aware refund path `AuroraMeter.Credits.reverse_lot/4` exists, so that it
  opened itself when that path shipped and nothing else could have opened it.

  It was asking with a bare `function_exported?/3`, **which answers false for a
  module that is merely not loaded yet**. In a host running
  `mix aurora_meter.credits.migrate_lots --no-shadow` nothing has referenced
  `AuroraMeter.Credits` before the task runs, so the probe reported the refund
  path missing, the task refused, and no install anywhere could cut a single
  wallet over. The refusal even printed finding X250, which repair unit R1 had
  closed.

  **Why no test saw it.** All three lot-cutover test files set
  `Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)`, and the
  probe is `escape_hatch or function_exported?(...)`. `or` short-circuits, so
  the branch that actually decides this in production had never been evaluated
  by anything. The lesson is X360's from the other side: a generator that cannot
  produce a shape is a suite that cannot fail on it, and **an escape hatch that
  every test takes is a branch no test can reach**.

  This module therefore does two things no other test does: it clears the escape
  hatch, and it unloads the module, which is the only way to reproduce the state
  a host is in. It is `async: false` for both reasons.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Credits.LotMigration

  setup do
    # The hatch must be off, or every assertion below is about the hatch.
    previous = Application.get_env(:aurora_meter_test, :allow_lot_cutover)
    Application.delete_env(:aurora_meter_test, :allow_lot_cutover)

    on_exit(fn ->
      if previous != nil,
        do: Application.put_env(:aurora_meter_test, :allow_lot_cutover, previous)

      Code.ensure_loaded!(AuroraMeter.Credits)
    end)

    :ok
  end

  test "I19 X426 the cutover is permitted in a process that has never touched AuroraMeter.Credits" do
    unload!(AuroraMeter.Credits)

    refute :erlang.module_loaded(AuroraMeter.Credits),
           "the module is still loaded, so this test is not asking the question a host asks"

    # The trap itself, asserted so that the reason for the line in
    # `cutover_wired?/0` is written down rather than remembered.
    refute function_exported?(AuroraMeter.Credits, :reverse_lot, 4),
           "function_exported?/3 now answers true for an unloaded module; if that is really " <>
             "so, the Code.ensure_loaded? in cutover_wired?/0 can go"

    assert LotMigration.cutover_blocked() == nil,
           "the cutover is refused in a host that has not yet referenced AuroraMeter.Credits. " <>
             "That is X426: no install can move a wallet onto lots, and the refusal quotes " <>
             "X250, which repair unit R1 closed."
  end

  test "I19 X426 the probe still refuses when the refund path really is absent" do
    # The other direction, so the test above is not passing because the probe
    # has been wired open. `reverse_lot/4` cannot be removed from a compiled
    # module, so the question is put to the probe's own condition.
    assert Code.ensure_loaded?(AuroraMeter.Credits)
    assert function_exported?(AuroraMeter.Credits, :reverse_lot, 4)

    refute function_exported?(AuroraMeter.Credits, :reverse_lot, 3),
           "a spurious arity would make the condition below vacuous"

    # A module that exists and does not carry the path: the probe must say no.
    refute Code.ensure_loaded?(AuroraMeter.Credits) and
             function_exported?(AuroraMeter.Credits, :no_such_refund_path, 4)
  end

  test "I19 X426 the escape hatch is not what permits it" do
    refute Application.get_env(:aurora_meter_test, :allow_lot_cutover),
           "setup did not clear the hatch"

    assert LotMigration.cutover_blocked() == nil
  end

  defp unload!(module) do
    :code.delete(module)
    :code.purge(module)
    :ok
  end
end
