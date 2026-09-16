defmodule AuroraMeter.CreditsLotMigrationResumeTest do
  @moduledoc """
  The wallet migration killed, resumed, and raced (build unit 06b, V1 task
  06.08).

  `async: false` and no `DataCase`: the sandbox wraps a test in one transaction
  on one connection, which is exactly what an interrupt test must not have. A
  killed process rolls its own transaction back and the only trustworthy state
  afterwards is what another connection can read, so every assertion here is a
  read of the database.

  **Never an unfiltered scan.** Every run below names its tenants. The scan
  form reads every balance row in the database, and rows committed by other
  non-sandbox modules are still there; a run without `tenant:` would migrate
  wallets belonging to another test. The cursor and scan mechanics are proved
  in the sandboxed file, where a shadow run can walk the whole table and write
  nothing.

  ## Forcing the contention rather than hoping for it

  Findings X182, X186 and X187: three units shipped a race test whose contended
  branch ran zero times while reporting green. The rendezvous here holds the
  wallet's balance row `FOR UPDATE` from a third connection until Postgres
  reports that both runners are waiting, and the count is asserted on an
  ordinary run (X214), not printed behind an environment variable. A row-lock
  waiter is invisible to `pg_locks` filtered by `database`, because it waits on
  the holder's `transactionid` and that row carries no database;
  `pg_stat_activity.wait_event_type = 'Lock'` is what sees it.
  """
  use ExUnit.Case, async: false

  @moduletag :fault
  @moduletag timeout: 180_000

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultRepo
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.LedgerFixtures
  alias AuroraMeter.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  @dollar 1_000_000

  setup do
    :ok = Sandbox.checkout(TestRepo, sandbox: false)
    Connections.register_prefix("lotmig")
    Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)

    on_exit(fn ->
      Application.delete_env(:aurora_meter_test, :allow_lot_cutover)
      :ok = Sandbox.checkout(TestRepo, sandbox: false)
      drop_checkpoints!()
      Connections.cleanup!("lotmig")
      Sandbox.checkin(TestRepo)
    end)

    :ok
  end

  # `Connections.cleanup!/1` deletes by tenant prefix and a checkpoint row has
  # no tenant column, so the run's own rows need their own sweep. Bounded by
  # the two names this unit writes, so it cannot reach another task's cursor.
  defp drop_checkpoints! do
    TestRepo.query!("DELETE FROM aurora_meter_checkpoints WHERE name LIKE 'lot_migration:%'", [])
    TestRepo.query!("DELETE FROM aurora_meter_checkpoints WHERE name = 'lot_migration'", [])
  end

  defp wallet(shape) do
    tenant = legacy_tenant()
    LedgerFixtures.build!(shape, tenant)
    tenant
  end

  defp migrate(tenants, opts \\ []) do
    LotMigration.run(
      Keyword.merge([tenant: List.wrap(tenants), shadow: false, allow_cutover: true], opts)
    )
  end

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: l.seq))

  defp allocations(tenant),
    do: TestRepo.all(from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: a.seq))

  defp row(tenant), do: TestRepo.one(from(b in CreditBalance, where: b.tenant_key == ^tenant))

  defp grant_count(tenant) do
    TestRepo.aggregate(
      from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:grant),
      :count,
      :id
    )
  end

  # One lot per grant row, counted two ways. `COUNT(*)` against
  # `COUNT(DISTINCT grant_transaction_id)` is what catches a wallet migrated
  # twice; the unique index would refuse the second write, so this is what says
  # the refusal happened rather than the work being skipped.
  defp migrated_exactly_once!(tenant) do
    lots = lots(tenant)

    assert length(lots) == grant_count(tenant), "#{tenant}: lot count"
    assert length(lots) == length(Enum.uniq(Enum.map(lots, & &1.grant_transaction_id)))
    assert row(tenant).lots_enabled_at
    assert row(tenant).projection_checked_at
  end

  defp figures(tenant) do
    %{balance: balance, held: held, promotional: promotional} = Credits.balance(tenant)
    %{balance: balance, held: held, promotional: promotional}
  end

  test "LI-06b-4 a kill inside a wallet's transaction leaves it untouched, and the rerun takes it" do
    tenant = wallet(:promotional_overlap)
    before = figures(tenant)

    {:killed, _pid} =
      Kill.run(
        fn ->
          Connections.checkout!()
          migrate(tenant, repo: FaultRepo)
        end,
        at: :before_commit,
        when: &(&1[:statement] == :balance_update and &1[:kind] == :write)
      )

    Kill.assert_db!(fn ->
      assert lots(tenant) == []
      assert allocations(tenant) == []
      assert is_nil(row(tenant).lots_enabled_at)
      assert row(tenant).debt == 0
      assert figures(tenant) == before

      # Every settle and release row still has the null it started with: the
      # backfill is inside the same transaction as everything else.
      assert TestRepo.all(
               from(t in CreditTransaction,
                 where: t.tenant_key == ^tenant and not is_nil(t.hold_transaction_id),
                 select: t.id
               )
             ) == []
    end)

    {:ok, summary} = migrate(tenant)
    assert hd(summary.reports).state == :migrated
    migrated_exactly_once!(tenant)
    assert figures(tenant) == before
  end

  test "LI-06b-4 a kill after one wallet commits leaves the rest for the rerun, once each" do
    wallets = for shape <- [:paid_only, :debits, :promotional_overlap], do: wallet(shape)
    before = Map.new(wallets, &{&1, figures(&1)})

    # `:after_commit_before_ack` fires when the outermost transaction commits,
    # which for this task is one wallet. The kill therefore lands between two
    # wallets, after the first one is durable and before its report row exists.
    {:killed, _pid} =
      Kill.run(
        fn ->
          Connections.checkout!()
          migrate(wallets, repo: FaultRepo)
        end,
        at: :after_commit_before_ack,
        count: 1
      )

    Kill.assert_db!(fn ->
      migrated = Enum.count(wallets, &row(&1).lots_enabled_at)

      assert migrated == 1,
             "expected exactly one wallet to have committed, got #{migrated}"

      # The wallet that did not commit has nothing at all, not a partial book.
      for tenant <- wallets, is_nil(row(tenant).lots_enabled_at) do
        assert lots(tenant) == []
        assert allocations(tenant) == []
      end
    end)

    {:ok, summary} = migrate(wallets)

    assert Enum.count(summary.reports, &(&1.state == :migrated)) == 2
    assert Enum.count(summary.reports, &(&1.state == :skipped)) == 1

    for tenant <- wallets do
      migrated_exactly_once!(tenant)
      assert figures(tenant) == Map.fetch!(before, tenant)
    end
  end

  test "LI-06b-3 two runs racing one wallet on its balance row migrate it exactly once" do
    tenant = wallet(:paid_only)
    before = figures(tenant)

    holder = hold_balance_row(tenant)
    parent = self()

    runners =
      for _ <- 1..2 do
        Task.async(fn ->
          Connections.checkout!()
          send(parent, :queued)
          migrate(tenant)
        end)
      end

    for _ <- 1..2, do: assert_receive(:queued, 30_000)

    # Both runners are now inside `lock_phase/5`, queued behind the row this
    # test holds. The count is the assertion: without it a race test that never
    # raced would report green (X182, X214).
    assert await_waiters(2, 500), "neither runner queued on the balance row lock"

    send(holder, :release)
    results = Task.await_many(runners, 60_000)

    states = Enum.map(results, fn {:ok, summary} -> hd(summary.reports).state end)
    assert Enum.sort(states) == [:migrated, :skipped]

    migrated_exactly_once!(tenant)
    assert figures(tenant) == before
  end

  test "I19 a ledger write committed during the snapshot lands in the tail, not in the snapshot" do
    tenant = wallet(:paid_only)
    reference = tenant <> ":committed_during_snapshot"

    # `max_tail: 0` is the discriminator. A row folded in from the tail defers
    # the wallet as busy; a row the snapshot had already seen migrates it. So
    # this assertion fails if the concurrent write did not really land after
    # the snapshot had been taken.
    {:ok, summary} =
      with_write_during_snapshot(tenant, reference, fn ->
        migrate(tenant, repo: FaultRepo, max_tail: 0)
      end)

    report = hd(summary.reports)
    assert report.state == :deferred
    assert report.reason == :too_busy
    assert lots(tenant) == []
    assert is_nil(row(tenant).lots_enabled_at)
  end

  test "X213 a tail row stamped before every snapshot row is still folded in commit order" do
    tenant = wallet(:paid_only)
    reference = tenant <> ":backdated_during_snapshot"

    {:ok, summary} =
      with_write_during_snapshot(
        tenant,
        reference,
        fn -> migrate(tenant, repo: FaultRepo) end,
        backdate: true
      )

    report = hd(summary.reports)

    # The concurrent debit carries an `inserted_at` from the year 2000, which
    # is what a wall clock stepping backwards produces and what
    # `architecture-map.md` section 7.4 expected to block the wallet. It does
    # not, because the tail is **appended** in `seq` order rather than merged
    # into the snapshot by timestamp, and a row committed after the snapshot is
    # causally after every row in it whatever its stamp says.
    assert report.state == :migrated
    migrated_exactly_once!(tenant)
    assert figures(tenant) == %{balance: 3 * @dollar, held: 0, promotional: 0}

    # The concurrent debit really is in the book: 6 USD from the snapshot plus
    # the 1 USD that landed in the tail.
    assert Enum.reduce(lots(tenant), 0, &(&1.consumed + &2)) == 7 * @dollar

    # And the discriminator. Merging the same rows by timestamp, which is what
    # a fold that trusted `inserted_at` would do, puts the debit before the
    # grant that funded it and the balance chain says so.
    assert {:blocked, flags} =
             LotMigration.replay(LedgerFixtures.rows_by_inserted_at(tenant), tenant)

    assert :ledger_chain_mismatch in Enum.map(flags, & &1.flag)
  end

  test "I19 a rerun after a completed run writes nothing and reports the wallet as skipped" do
    tenant = wallet(:debits)
    {:ok, _summary} = migrate(tenant)

    lots = lots(tenant)
    allocations = allocations(tenant)
    balance = row(tenant)

    {:ok, summary} = migrate(tenant)

    assert hd(summary.reports).state == :skipped
    assert lots(tenant) == lots
    assert allocations(tenant) == allocations
    assert row(tenant) == balance
  end

  test "I19 the aggregate checkpoint records the run and its cursor across two runs" do
    first = wallet(:paid_only)
    second = wallet(:debits)

    {:ok, _} = migrate(first)
    assert Checkpoints.get("lot_migration").cursor["tenant_key"] == first

    {:ok, _} = migrate(second)
    assert Checkpoints.get("lot_migration").cursor["tenant_key"] == second
    assert Checkpoints.get("lot_migration").counts["migrated"] == 1
    assert Checkpoints.get(LotMigration.checkpoint_name(first)).state == "migrated"
  end

  # -- the harness ------------------------------------------------------------

  # Blocks the migration between its snapshot read and its tail read, commits a
  # debit on another connection, and then releases it.
  #
  # The fault point is the **second** read of `aurora_meter_credit_balances` in
  # one wallet's pass: the unlocked look-up that decides what to do with the
  # wallet, and then the `FOR UPDATE` read that opens the lock phase. Blocking
  # before the second one puts the migration inside its transaction with no row
  # lock taken and its snapshot already read, which is the only window in which
  # a concurrent write is guaranteed to be outside the snapshot and inside the
  # tail.
  #
  # Blocking one statement later, before the tail read, would hold the balance
  # row and the writer would queue behind it for ever. That is not a
  # hypothetical: it is what this harness did first, and the five second block
  # timeout is what said so.
  #
  # The `max_tail: 0` test above is what proves the window is the one this
  # lands in rather than a window that merely looks like it.
  defp with_write_during_snapshot(tenant, reference, run, opts \\ []) do
    ref = make_ref()
    parent = self()
    counter = :"reads_#{System.unique_integer([:positive])}"

    Faults.arm(:before_commit, {:block_until, ref},
      owner: self(),
      count: 1,
      block_timeout: 30_000,
      when: fn context ->
        context[:statement] == :balance_update and context[:kind] == :read and
          nth_read(counter) == 2
      end
    )

    task = Task.async(fn -> Connections.checkout!() && run.() end)

    assert_receive {:aurora_fault_blocked, :before_commit, blocked, ^ref}, 30_000

    writer =
      Task.async(fn ->
        Connections.checkout!()
        {:ok, txn} = Credits.debit(tenant, @dollar, reference)
        if opts[:backdate], do: backdate!(txn.id)
        send(parent, :written)
      end)

    assert_receive :written, 30_000
    Task.await(writer, 30_000)

    send(blocked, {:aurora_fault_release, ref})
    Task.await(task, 60_000)
  end

  # The predicate runs once per check, in the checking process, which is what
  # makes a counter in its process dictionary sound here. `AuroraMeter.Test.Faults`
  # documents exactly that guarantee.
  defp nth_read(key) do
    n = Process.get(key, 0) + 1
    Process.put(key, n)
    n
  end

  defp backdate!(id) do
    TestRepo.update_all(
      from(t in CreditTransaction, where: t.id == ^id),
      set: [inserted_at: ~U[2000-01-01 00:00:00.000000Z]]
    )
  end

  defp hold_balance_row(tenant) do
    parent = self()

    pid =
      spawn(fn ->
        Connections.checkout!()

        TestRepo.transaction(fn ->
          TestRepo.query!(
            "SELECT id FROM aurora_meter_credit_balances WHERE tenant_key = $1 FOR UPDATE",
            [tenant]
          )

          send(parent, :holding)

          receive do
            :release -> :ok
          after
            30_000 -> :ok
          end
        end)
      end)

    assert_receive(:holding, 30_000)
    pid
  end

  defp await_waiters(_target, 0), do: false

  defp await_waiters(target, attempts) do
    %{rows: [[waiting]]} =
      TestRepo.query!(
        """
        SELECT count(*) FROM pg_stat_activity
         WHERE datname = current_database()
           AND wait_event_type = 'Lock'
           AND pid <> pg_backend_pid()
        """,
        []
      )

    if waiting >= target do
      true
    else
      Process.sleep(20)
      await_waiters(target, attempts - 1)
    end
  end

  # A wallet that predates the lots-on-creation release. See
  # `LedgerFixtures.legacy_wallet!/1`.
  defp legacy_tenant(prefix \\ "lotmig"),
    do: LedgerFixtures.legacy_wallet!(AuroraMeter.Test.unique_tenant(prefix))
end
