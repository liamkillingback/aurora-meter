defmodule AuroraMeter.CreditsAfterCommitTest do
  @moduledoc """
  Side effects deferred out of a host transaction (build unit 06c, finding L18,
  lower-level invariant LI-06c-3).

  Not a `DataCase` test, and the reason is the whole subject. The sandbox holds
  a transaction of its own, so a ledger call made under it would be nested
  inside *that* and every test here would be proving the deferral against an
  artefact of the harness rather than against a host's transaction. Each test
  checks out a real connection (`sandbox: false`), commits and rolls back for
  real, and deletes its rows afterwards.

  ## How the negative is proved

  "Nothing fired" is the easy claim to fake: a `refute_received` on an
  asynchronous message passes when the message is merely slow. So the telemetry
  handler here does not report *whether* it fired, it reports **when**: it reads
  a phase marker at the instant it runs and appends it. A handler that fires
  inside the host transaction records `:inside`, and the assertion that the
  recorded phases are exactly `[:after_drain]` fails with the phase that
  actually happened. The positive half is asserted in the same test from the
  same recording, so the mechanism is shown to work rather than shown to be
  absent.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @dollar 1_000_000

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    tenant = AuroraMeter.Test.unique_tenant("deferred")
    {:ok, phases} = Agent.start_link(fn -> {:before, []} end)

    on_exit(fn ->
      # The queue is per process and this process is about to move on to
      # another test, so an undrained one would leak an effect into it.
      Credits.after_commit(discard: true)
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      TestRepo.delete_all(from(t in CreditTransaction, where: t.tenant_key == ^tenant))
      TestRepo.delete_all(from(b in CreditBalance, where: b.tenant_key == ^tenant))
      Sandbox.checkin(TestRepo)
    end)

    %{tenant: tenant, phases: phases}
  end

  test "I10 a ledger call inside a host transaction emits nothing until after_commit is called",
       %{
         tenant: tenant,
         phases: phases
       } do
    watch(tenant, phases)
    Credits.subscribe(tenant)

    assert {:ok, :done} =
             TestRepo.transaction(fn ->
               assert {:ok, _txn} = Credits.grant(tenant, 10 * @dollar, reference: "g1")

               # The row is there for this transaction to see: the write itself
               # is not deferred, only what describes it.
               assert Credits.balance(tenant).balance == 10 * @dollar
               assert Credits.deferred_effects?()
               :done
             end)

    # Still nothing: the transaction has committed and the host has not yet
    # said so.
    phase(phases, :after_commit_before_drain)
    assert Credits.deferred_effects?()

    phase(phases, :after_drain)
    assert :ok = Credits.after_commit()
    refute Credits.deferred_effects?()

    # The positive and the negative from one recording. Exactly one telemetry
    # event fired, and it fired in the last phase.
    assert fired(phases) == [:after_drain]

    assert_receive {:aurora_meter, :credits, %{tenant_key: ^tenant, balance: 10_000_000}}, 1_000
  end

  test "I10 a host transaction that rolls back and calls after_commit(discard: true) emits nothing",
       %{tenant: tenant, phases: phases} do
    watch(tenant, phases)
    Credits.subscribe(tenant)

    assert {:error, :nope} =
             TestRepo.transaction(fn ->
               assert {:ok, _txn} = Credits.grant(tenant, 10 * @dollar, reference: "g1")
               TestRepo.rollback(:nope)
             end)

    phase(phases, :after_rollback)
    assert Credits.deferred_effects?()
    assert :ok = Credits.after_commit(discard: true)
    refute Credits.deferred_effects?()

    # Nothing described a write that no longer exists.
    assert fired(phases) == []
    assert Credits.balance(tenant).balance == 0

    refute_receive {:aurora_meter, :credits, _payload}, 200
  end

  test "I10 after_commit runs the deferred effects in order", %{tenant: tenant, phases: phases} do
    watch(tenant, phases)

    assert {:ok, :done} =
             TestRepo.transaction(fn ->
               {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "g1")
               {:ok, _} = Credits.hold(tenant, 2 * @dollar, "job:1")
               {:ok, _} = Credits.settle("job:1", @dollar)
               :done
             end)

    phase(phases, :after_drain)
    Credits.after_commit()

    # Three effects, in the order the writes happened, so a consumer that folds
    # them reconstructs the same sequence the ledger did.
    assert kinds(phases) == [:grant, :hold, :settle]
    assert fired(phases) == [:after_drain, :after_drain, :after_drain]

    # And the metadata says they were deferred, so an operator reading the
    # events can tell a late one from a slow one.
    assert deferred_flags(phases) == [true, true, true]
  end

  test "I10 deferred_effects? reports an undrained queue", %{tenant: tenant} do
    refute Credits.deferred_effects?()

    TestRepo.transaction(fn ->
      {:ok, _} = Credits.grant(tenant, @dollar, reference: "g1")
      :ok
    end)

    assert Credits.deferred_effects?()

    # It is per process: a host that spawns cannot see, or drain, another
    # process's queue, which is documented and is why the queue lives where
    # Ecto's transaction scope lives.
    assert Task.await(Task.async(fn -> Credits.deferred_effects?() end)) == false

    Credits.after_commit()
    refute Credits.deferred_effects?()
  end

  test "I10 a ledger call that owns its transaction is unaffected", %{
    tenant: tenant,
    phases: phases
  } do
    # **The control.** If `transact_outcome/1` deferred unconditionally, every
    # test above would still pass and every ordinary caller would silently stop
    # getting its effects. This is the case that says the condition is the
    # host's transaction and not the change itself.
    watch(tenant, phases)
    phase(phases, :immediate)

    assert {:ok, _txn} = Credits.grant(tenant, @dollar, reference: "g1")

    assert fired(phases) == [:immediate]
    refute Credits.deferred_effects?()
    assert deferred_flags(phases) == [false]
  end

  test "I10 a low-balance crossing inside a host transaction does not invoke the handler before commit",
       %{tenant: tenant, phases: phases} do
    # The concrete L18 hazard, and the reason the deferral is worth a public
    # function: the handler is where Pro enqueues an auto top-up. Firing it for
    # a balance the host then rolled back buys credit against a payment that
    # never happened.
    #
    # The handler records the phase it ran in **and** says so to this process.
    # Since finding X269 it runs in a watcher rather than in the writer, so it
    # is asynchronous: the phase recording is what proves it did not run early,
    # and the message is the synchronisation point that lets the positive half
    # be asserted without reading a value that may not have arrived yet.
    parent = self()

    handler = fn event ->
      Agent.update(phases, fn {p, log} -> {p, log ++ [{p, event}]} end)
      send(parent, {:handler_ran, event})
    end

    TestConfig.with_config([{:aurora_meter, :credits_low_balance_handler, handler}], fn ->
      {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
      {:ok, _} = Credits.set_low_balance_threshold(tenant, 5 * @dollar)

      phase(phases, :inside)

      assert {:ok, :done} =
               TestRepo.transaction(fn ->
                 {:ok, _} = Credits.debit(tenant, 6 * @dollar, "d0")
                 :done
               end)

      # Nothing has been queued to run it yet, so this is not a race with a
      # watcher: the effect is still on this process's own deferral queue.
      assert Credits.deferred_effects?()
      assert log(phases) == [], "the handler ran on a savepoint release"
      refute_received {:handler_ran, _}

      phase(phases, :after_drain)
      Credits.after_commit()

      assert_receive {:handler_ran, event}, 2_000
      assert event.spendable == 4 * @dollar
      assert event.crossing_id

      # ...and it ran in the last phase, which is the claim the phase marker
      # carries and which `assert_receive` alone would not.
      assert [{:after_drain, ^event}] = log(phases)
    end)
  end

  # -- helpers ----------------------------------------------------------------

  # A telemetry handler that records **when** it ran rather than that it ran.
  defp watch(tenant, phases) do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:aurora_meter, :credits, :grant],
          [:aurora_meter, :credits, :hold],
          [:aurora_meter, :credits, :settle],
          [:aurora_meter, :credits, :debit]
        ],
        &__MODULE__.record/4,
        %{tenant: tenant, phases: phases}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def record(event, _measurements, metadata, %{tenant: tenant, phases: phases}) do
    if metadata.tenant_key == tenant, do: append(phases, List.last(event), metadata)
    :ok
  end

  defp append(phases, kind, metadata),
    do: Agent.update(phases, fn {p, log} -> {p, log ++ [{p, kind, metadata}]} end)

  defp phase(phases, name), do: Agent.update(phases, fn {_p, log} -> {name, log} end)

  defp entries(phases), do: phases |> Agent.get(& &1) |> elem(1)

  defp fired(phases), do: Enum.map(entries(phases), &elem(&1, 0))
  defp kinds(phases), do: Enum.map(entries(phases), &elem(&1, 1))
  defp deferred_flags(phases), do: Enum.map(entries(phases), &elem(&1, 2).deferred)
  defp log(phases), do: entries(phases)
end
