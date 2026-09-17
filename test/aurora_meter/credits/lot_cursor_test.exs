defmodule AuroraMeter.Credits.LotCursorTest do
  @moduledoc """
  The resume cursor, asked the way the upgrade guide asks it (repair unit R8,
  `open-findings.md` X427 and X434).

  ## What was wrong

  `docs/upgrading-to-lots.md` tells an operator to run
  `mix aurora_meter.credits.migrate_lots` in shadow first (step 1) and then for
  real (step 4). Both runs read and wrote **one** aggregate cursor, and the scan
  is `where tenant_key > cursor`. So the rehearsal walked every wallet and left
  the cursor on the last one, and the real run that followed scanned past the
  end of the table: `wallets 0, migrated 0, blocked 0`, **exit 0**, and not one
  wallet cut over. An operator following our own documentation migrated nothing
  and was told it had worked. Build unit 11a's matrix recorded a clean S5 twice
  over a database in which all sixteen wallets were still on the legacy writer.

  ## What fixes it

  Shadow and real keep **separate** cursors. `architecture-map.md` 7.4 is
  binding and says shadow mode "computes and reports without writing": the
  per-wallet rows are the report, but the cursor is control state the next run
  obeys, and a rehearsal that changes what the real run does is writing.

  Two supporting rules, both about not destroying progress:

    * a run that examines no wallet never overwrites a cursor (a zero-wallet run
      used to write null over it, which is why the symptom alternated with how
      many times the task had been invoked, and which could erase an interrupted
      real run's resume point);
    * `--retry-blocked` starts from the first wallet, because every wallet it is
      for is **behind** the cursor by construction (X434).

  ## The assertion that matters

  `wallets: 0` had two opposite meanings and one printed form. The tests below
  produce both and assert they are now told apart: "there was nothing to do"
  against "the cursor was past everything", the second of which fails the run.
  A test that only proved the documented sequence migrates wallets would pass
  for a build that had simply stopped resuming at all.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Test.LedgerFixtures
  alias Mix.Tasks.AuroraMeter.Credits.MigrateLots

  setup do
    Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)
    on_exit(fn -> Application.delete_env(:aurora_meter_test, :allow_lot_cutover) end)
    :ok
  end

  describe "the documented operator sequence" do
    test "I19 X427 shadow then real, with no extra flags, migrates the wallets" do
      keys = wallets([:paid_only, :debits, :released_hold])

      # Step 1 of docs/upgrading-to-lots.md, exactly as written.
      {:ok, rehearsal} = LotMigration.run(shadow: true)
      assert rehearsal.wallets >= 3

      # Step 4, exactly as written: --no-shadow and nothing else. Before R8 this
      # examined zero wallets and exited 0.
      {:ok, real} = LotMigration.run(shadow: false, allow_cutover: true)

      examined = Enum.map(real.reports, & &1.tenant_key)
      assert Enum.all?(keys, &(&1 in examined)), "the real run skipped wallets the rehearsal saw"

      assert real.resumed_from == nil,
             "the real run resumed from the rehearsal's cursor, which is X427"

      # And the money actually moved. `wallets examined` is not `wallets
      # migrated`: 11a's R3 comparator passed vacuously for exactly that reason.
      for key <- keys do
        assert cut_over?(key), "#{key} was examined and is still on the legacy writer"
      end
    end

    test "I19 X427 the rehearsal leaves the real cursor untouched" do
      wallets([:paid_only, :debits])

      {:ok, _} = LotMigration.run(shadow: true)

      assert Checkpoints.get("lot_migration") == nil,
             "the shadow run wrote the real migration's cursor row"

      status = LotMigration.status()
      assert status.cursor == nil
      assert is_binary(status.shadow_cursor), "the shadow run kept no cursor of its own"
    end
  end

  describe "a run that migrates nothing" do
    test "I19 X427 says so when it skipped everything, and fails" do
      keys = wallets([:paid_only, :debits])

      # The state the shared cursor produced: the real cursor sits past every
      # wallet while every wallet is still on the legacy writer.
      past_everything = max_key()
      Checkpoints.put("lot_migration", %{"tenant_key" => past_everything}, %{}, "complete")

      {:ok, summary} = LotMigration.run(shadow: false, allow_cutover: true)

      assert summary.wallets == 0
      assert summary.migrated == 0
      assert summary.unexamined >= length(keys), "the run examined nothing and did not notice"
      assert summary.state == "skipped_by_cursor"
      assert summary.resumed_from == past_everything

      assert_raise Mix.Error, ~r/examined no wallets/, fn ->
        MigrateLots.report({:ok, summary})
      end
    end

    test "I19 X427 says so when there was nothing to do, and does not fail" do
      # **The discrimination.** Same `wallets: 0`, opposite verdict. Without this
      # the test above would pass for a build that failed every idle re-run.
      keys = wallets([:paid_only, :debits])

      {:ok, first} = LotMigration.run(shadow: false, allow_cutover: true)
      assert first.migrated >= length(keys)

      {:ok, again} = LotMigration.run(shadow: false, allow_cutover: true)

      assert again.wallets == 0, "the cursor did not carry over between real runs"
      assert again.unexamined == 0
      assert again.state == "complete"
      assert again.resumed_from == max_key()

      assert MigrateLots.report({:ok, again}) == :ok
    end

    test "I19 X427 does not erase the cursor it did not advance" do
      # The half that makes an interrupted real run resumable at all, and the
      # half 11b depends on. A zero-wallet run used to write a null cursor, so
      # the run after it started from the beginning again.
      wallets([:paid_only])
      {:ok, _} = LotMigration.run(shadow: false, allow_cutover: true)

      reached = Checkpoints.get("lot_migration").cursor["tenant_key"]
      assert reached == max_key()

      {:ok, idle} = LotMigration.run(shadow: false, allow_cutover: true)
      assert idle.wallets == 0

      assert Checkpoints.get("lot_migration").cursor["tenant_key"] == reached,
             "a run that examined nothing erased the resume point"
    end
  end

  describe "retry-blocked" do
    test "I19 X434 reaches a wallet behind the cursor" do
      # The documented remedy for a blocked wallet is to fix the data and re-run
      # with --retry-blocked. Every wallet it is for is behind the cursor,
      # because the run that declined it carried on past it, so resuming from
      # the cursor scans the one stretch of the table that cannot contain them.
      keys = wallets([:paid_only, :debits])

      # `shadow: false`, and that is not decoration. A shadow run reads the
      # SHADOW cursor, so seeding the real one and then rehearsing proves
      # nothing: the first version of this test did exactly that and passed with
      # the fix reverted. Control c3 caught it.
      Checkpoints.put("lot_migration", %{"tenant_key" => max_key()}, %{}, "complete")

      {:ok, summary} =
        LotMigration.run(shadow: false, allow_cutover: true, retry_blocked: true)

      examined = Enum.map(summary.reports, & &1.tenant_key)
      assert Enum.all?(keys, &(&1 in examined)), "--retry-blocked resumed from the cursor"
      assert summary.resumed_from == nil
    end

    test "I19 X434 does not drag the forward cursor backwards" do
      wallets([:paid_only, :debits])
      forward = max_key()
      Checkpoints.put("lot_migration", %{"tenant_key" => forward}, %{}, "complete")

      # `max_wallets: 1` so the sweep stops well short of where the forward pass
      # got to. Which wallet it stops on is not this test's business, because
      # the table holds rows other legs committed; that it stopped somewhere
      # else is, and the guard assertion below says so rather than letting the
      # test pass when the two keys happen to coincide.
      {:ok, summary} =
        LotMigration.run(
          shadow: false,
          allow_cutover: true,
          retry_blocked: true,
          max_wallets: 1
        )

      assert summary.cursor != nil and summary.cursor != forward,
             "the sweep ended on the forward cursor, so this test cannot discriminate"

      assert Checkpoints.get("lot_migration").cursor["tenant_key"] == forward,
             "a retry sweep moved the cursor the forward pass resumes from"
    end
  end

  describe "the cursor rows themselves" do
    test "I19 X427 the shadow cursor cannot collide with a wallet's checkpoint" do
      # `checkpoint_name/1` always emits "lot_migration:" <> something, and the
      # wallet listing selects on that prefix. So the aggregate rows are
      # unreachable as wallets even for a tenant whose key is literally
      # "shadow", which is the one name a reader worries about.
      assert LotMigration.checkpoint_name("shadow") == "lot_migration:shadow"
      refute LotMigration.checkpoint_name("shadow") == "lot_migration_shadow"

      wallets([:paid_only])
      {:ok, _} = LotMigration.run(shadow: true)

      names = Enum.map(LotMigration.status().wallets, & &1.name)
      refute "lot_migration_shadow" in names
      refute "lot_migration" in names
    end
  end

  # -- the harness ------------------------------------------------------------

  # The wallets this test made, **in the order the scan will reach them**.
  #
  # Not `Enum.sort/1`. The scan is `order_by: [asc: b.tenant_key]`, so the order
  # is the database's collation, and Postgres's default collation disagrees with
  # Elixir's byte order for exactly the keys this helper generates:
  # `"lotcur_123" < "lotcur_45"` by bytes, the other way round under en_US.
  # Sorting here instead of asking the table made the cursor assertions below
  # fail on a correct tree.
  defp wallets(shapes) do
    keys =
      for shape <- shapes do
        tenant = unique_tenant("lotcur")
        LedgerFixtures.build!(shape, tenant)
        tenant
      end

    TestRepo.all(
      from(b in CreditBalance,
        where: b.tenant_key in ^keys,
        order_by: [asc: b.tenant_key],
        select: b.tenant_key
      )
    )
  end

  # **The scan is over the whole table, not over this test's wallets.**
  #
  # `aurora_meter_credit_balances` holds rows committed outside the sandbox by
  # other legs (a `headless_06c_*` wallet turned up here), so "the last wallet"
  # is not this test's last wallet and a cursor seeded from `keys` leaves rows
  # after it. Every cursor a test seeds is therefore read from the table, which
  # makes these assertions independent of what else is in it.
  defp max_key do
    TestRepo.one(from(b in CreditBalance, select: max(b.tenant_key)))
  end

  defp cut_over?(tenant_key) do
    TestRepo.get_by(CreditBalance, tenant_key: tenant_key).lots_enabled_at != nil
  end
end
