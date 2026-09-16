defmodule AuroraMeter.PlanRegistryConcurrencyTest do
  @moduledoc """
  `AuroraMeter.Plans.register!/0` under concurrency and under process death
  (build unit 07a, invariant I17; the 01b harness).

  Every test here runs on **independent, non-sandbox connections**. The sandbox
  wraps a test in one transaction on one connection, which serialises exactly
  the contention a unique index and `FOR UPDATE SKIP LOCKED` exist to survive,
  so a sandboxed version of any of these would prove nothing.

  Three shapes, and the third is the one with teeth:

    * twelve connections calling `register!/0` at once, asserting one row per
      `(plan_id, version)` and one decision;
    * a kill between assignment batches, and a kill inside one, asserting what
      committed and that a rerun finishes the rest;
    * **forced** contention: a transaction that holds a row lock while the
      assignment runs, so `SKIP LOCKED` is observed skipping rather than hoped
      to have skipped. The number of rows it skipped is counted and asserted on
      an ordinary run (`open-findings.md` X182, X214).
  """
  use ExUnit.Case, async: false

  @moduletag :fault

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.Plans
  alias AuroraMeter.Plans.Snapshot
  alias AuroraMeter.Schema.PlanVersion
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @tenants 40

  # More than one **productive** assignment batch, which is what "killed
  # between batches" needs to mean anything: `AuroraMeter.Plans.register!/0`
  # assigns 5,000 rows per transaction, so a fixture smaller than that has one
  # batch and a kill after it has nothing left to resume.
  @batch 5_000
  @over_one_batch 5_100

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    prefix = AuroraMeter.Test.unique_tenant("planconc")

    on_exit(fn ->
      Plans.reset_registry()
      ConfigSchema.reset_warnings!()
      Connections.cleanup!(prefix)
    end)

    {:ok, prefix: prefix}
  end

  test "I17 twelve concurrent register! calls insert one row per plan id and version" do
    clear_snapshots!()

    results =
      Connections.run(12, fn _index ->
        Connections.checkout!()
        Plans.register!()
      end)

    assert Enum.all?(results, &(&1 == :ok))

    rows = TestRepo.all(PlanVersion)
    keys = Enum.map(rows, &{&1.plan_id, &1.version})

    # One row per key: the unique index absorbed every losing insert through
    # `on_conflict: :nothing` rather than raising out of somebody's boot.
    assert keys == Enum.uniq(keys)
    assert length(keys) == map_size(AuroraMeter.TestPlans.__aurora_plans__())

    # And every one of them holds the fingerprint the compiler computed, so no
    # racing writer stored a half-built definition.
    for {{id, version}, plan} <- AuroraMeter.TestPlans.__aurora_plans__() do
      row = Enum.find(rows, &(&1.plan_id == Atom.to_string(id) and &1.version == version))
      assert row.fingerprint == plan.fingerprint
    end
  end

  test "I17 twelve concurrent put_plan_version calls for one key leave exactly one row" do
    clear_snapshots!()

    attrs = %{
      plan_id: "concurrent_probe",
      version: "1",
      fingerprint: :crypto.hash(:sha256, "concurrent_probe"),
      definition: %{"fingerprint_version" => Snapshot.fingerprint_version(), "price" => 1},
      effective_at: nil
    }

    on_exit(fn ->
      Connections.checkout!()
      TestRepo.delete_all(from(v in PlanVersion, where: v.plan_id == "concurrent_probe"))
    end)

    results =
      Connections.run(12, fn _index ->
        Connections.checkout!()
        Storage.put_plan_version(attrs)
      end)

    # Every caller is told it succeeded, because losing the race is not a
    # failure: the row it wanted exists.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 12

    rows = TestRepo.all(from(v in PlanVersion, where: v.plan_id == "concurrent_probe"))
    assert length(rows) == 1
  end

  test "I17 twelve concurrent register! calls reach the same conflict decision" do
    clear_snapshots!()
    assert :ok = Plans.register!()

    # `:warn` rather than `:raise`, because twelve raising tasks would be twelve
    # task exits and the thing under test is that they all *decide* the same
    # way, not how a raise propagates out of `Task.async_stream`.
    logs =
      TestConfig.with_config(
        [
          {:aurora_meter, :plan_version_conflict, :warn},
          {:aurora_meter, :plans, AuroraMeter.Test.EditedVersionPlans}
        ],
        fn ->
          Connections.run(12, fn _index ->
            Connections.checkout!()

            ExUnit.CaptureLog.capture_log(fn ->
              ConfigSchema.reset_warnings!()
              assert :ok = Plans.register!()
            end)
          end)
        end
      )

    conflicted = Enum.count(logs, &(&1 =~ "plan versioned version 1"))

    assert conflicted == 12,
           "expected all twelve connections to reach the same conflict decision, " <>
             "#{conflicted} did. A registry whose answer depends on which node booted first " <>
             "would let one deploy accept a repricing another refused."

    # And no connection wrote a new definition over the stored one.
    row =
      TestRepo.one(from(v in PlanVersion, where: v.plan_id == "versioned" and v.version == "1"))

    assert row.fingerprint ==
             AuroraMeter.TestPlans.__aurora_plans__()[{:versioned, "1"}].fingerprint
  end

  test "I17 SKIP LOCKED makes a concurrent assignment take the rows another transaction is not holding",
       %{prefix: prefix} do
    clear_snapshots!()
    assert :ok = Plans.register!()
    seed_unnamed!(prefix, @tenants)

    held = 12
    locked_ids = Enum.take(unnamed_ids(prefix), held)
    assert length(locked_ids) == held

    # A second connection that takes and HOLDS the row locks. Without this the
    # test would be hoping two schedulers interleave; with it, the contention is
    # a fact of the test rather than a wish (X182). `test` is captured out here
    # on purpose: `self()` inside the task's own closure is the task.
    test = self()
    {:ok, holder} = Task.start_link(fn -> hold_rows(locked_ids, test) end)
    assert_receive {:locked, ^holder}, 5_000

    started = System.monotonic_time(:millisecond)
    {:ok, batch} = Storage.assign_legacy_plan_versions(1_000)
    elapsed = System.monotonic_time(:millisecond) - started

    send(holder, :release)

    skipped = @tenants - batch.assigned

    # The counted contended branch, asserted on an ordinary run (X214). A zero
    # here does not mean "no flake", it means the lock was never taken or
    # SKIP LOCKED stopped skipping, and both are behaviour changes.
    assert skipped == held,
           "expected the assignment to skip the #{held} rows another transaction holds and " <>
             "take the other #{@tenants - held}; it assigned #{batch.assigned}, so it skipped " <>
             "#{skipped}. Either the holder never took its locks, or SKIP LOCKED is no longer " <>
             "in the statement and this batch queued behind a lock it should have stepped over."

    # And it did not wait for them. The bound is loose on purpose: the claim is
    # "did not block on a held lock", not "was fast".
    assert elapsed < 2_000

    # The held rows are still unnamed, and the next run finishes them once the
    # other transaction has actually committed. Waiting for the holder rather
    # than sleeping: `send/2` returns before the transaction ends, and an
    # assignment issued in between would correctly skip the rows again.
    assert length(unnamed_ids(prefix)) == held
    assert_receive {:released, ^holder}, 5_000

    assert {:ok, %{assigned: ^held}} = Storage.assign_legacy_plan_versions(1_000)
    assert unnamed_ids(prefix) == []
  end

  test "I17 two concurrent assignments take disjoint batches and leave every row named",
       %{prefix: prefix} do
    clear_snapshots!()
    assert :ok = Plans.register!()
    seed_unnamed!(prefix, @tenants)

    # Batches of one, so twelve connections really do have to divide the work
    # rather than the first one taking all of it.
    results =
      Connections.run(12, fn _index ->
        Connections.checkout!()
        drain(0)
      end)

    total = Enum.sum(results)
    workers_that_assigned = Enum.count(results, &(&1 > 0))

    assert total == @tenants,
           "the batches were not disjoint: #{inspect(results)} sums to #{total}, not #{@tenants}"

    assert workers_that_assigned > 1,
           "one connection did all #{@tenants} rows, so nothing about concurrency was exercised"

    assert unnamed_ids(prefix) == []
  end

  test "I17 register! killed between assignment batches resumes and completes on the next run",
       %{prefix: prefix} do
    clear_snapshots!()
    assert :ok = Plans.register!()
    seed_unnamed!(prefix, @over_one_batch)

    before = count_subscriptions(prefix)

    killed =
      with_fault_storage(fn ->
        # `after_commit_before_ack` on the first assignment: the batch is
        # durable and the loop has not yet counted it, which is exactly
        # "between batches". `:count` is how many times a fault may fire, not
        # which call it fires on, so one firing at this point is the first
        # batch.
        Kill.run(fn -> Plans.register!() end,
          at: :after_commit_before_ack,
          count: 1,
          when: &(&1[:callback] == :assign_legacy_plan_versions),
          label: "07a assignment between batches"
        )
      end)

    assert {:killed, _pid} = killed

    partial = Kill.assert_db!(fn -> length(unnamed_ids(prefix)) end)

    # The committed prefix is exactly one batch, and the remainder is exactly
    # what is left. A test that only asserted "some rows remain" would pass on a
    # batch loop that committed a partial transaction.
    assert partial == @over_one_batch - @batch,
           "expected the first batch to have committed #{@batch} rows and " <>
             "#{@over_one_batch - @batch} to remain, #{partial} remain"

    # The predicate is the checkpoint: the next run does the rest.
    assert :ok = Kill.assert_db!(fn -> Plans.register!() end)

    Kill.assert_db!(fn ->
      assert unnamed_ids(prefix) == []
      assert count_subscriptions(prefix) == before
    end)
  end

  test "I17 register! killed inside a batch commits nothing from that batch", %{prefix: prefix} do
    clear_snapshots!()
    assert :ok = Plans.register!()
    seed_unnamed!(prefix, @tenants)

    killed =
      with_fault_storage(fn ->
        # Before the statement runs at all, on the first batch: nothing from it
        # can have committed.
        Kill.run(fn -> Plans.register!() end,
          at: :before_commit,
          count: 1,
          when: &(&1[:callback] == :assign_legacy_plan_versions),
          label: "07a assignment inside a batch"
        )
      end)

    assert {:killed, _pid} = killed

    Kill.assert_db!(fn ->
      assert length(unnamed_ids(prefix)) == @tenants
      assert count_subscriptions(prefix) == @tenants
    end)

    assert :ok = Kill.assert_db!(fn -> Plans.register!() end)
    Kill.assert_db!(fn -> assert unnamed_ids(prefix) == [] end)
  end

  # -- helpers ----------------------------------------------------------------

  defp clear_snapshots! do
    Connections.checkout!()
    TestRepo.delete_all(PlanVersion)
    Plans.reset_registry()
    :ok
  end

  # `insert_all` and not `put_subscription/1` per row: the kill tests need more
  # than 5,000 rows to have more than one productive batch, and 5,100 round
  # trips would dominate the run. Rows land in exactly the shape core schema
  # version 10 leaves an existing install in: every column present, every plan
  # column NULL.
  defp seed_unnamed!(prefix, count) do
    Connections.checkout!()
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        %{
          tenant_key: "#{prefix}_#{index}",
          plan_id: "versioned",
          status: "active",
          inserted_at: now,
          updated_at: now
        }
      end

    {^count, _} = TestRepo.insert_all(Subscription, rows)
    :ok
  end

  defp unnamed_ids(prefix) do
    TestRepo.all(
      from(s in Subscription,
        where: like(s.tenant_key, ^"#{prefix}%") and is_nil(s.plan_version),
        select: s.id,
        order_by: s.id
      )
    )
  end

  defp count_subscriptions(prefix) do
    TestRepo.aggregate(from(s in Subscription, where: like(s.tenant_key, ^"#{prefix}%")), :count)
  end

  # Takes a real row lock on `ids` and holds it until told to let go, on its own
  # connection. `FOR UPDATE` without `SKIP LOCKED`, because the holder is
  # standing in for an ordinary writer and not for another registration.
  defp hold_rows(ids, reply_to) do
    Connections.checkout!()

    TestRepo.transaction(fn ->
      TestRepo.all(from(s in Subscription, where: s.id in ^ids, lock: "FOR UPDATE"))
      send(reply_to, {:locked, self()})

      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end
    end)

    # After the transaction, not inside it: the locks are gone only once it has
    # committed, and the caller needs to know that rather than assume it.
    send(reply_to, {:released, self()})
  end

  defp drain(assigned) do
    case Storage.assign_legacy_plan_versions(1) do
      {:ok, %{assigned: 0}} -> assigned
      {:ok, batch} -> drain(assigned + batch.assigned)
      {:error, _reason} -> assigned
    end
  end

  defp with_fault_storage(fun) do
    TestConfig.with_config([{:aurora_meter, :storage, AuroraMeter.Test.FaultStorage}], fn ->
      try do
        fun.()
      after
        Faults.disarm_all()
      end
    end)
  end
end
