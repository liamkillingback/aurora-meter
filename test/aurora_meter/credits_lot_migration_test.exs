defmodule AuroraMeter.CreditsLotMigrationTest do
  @moduledoc """
  The wallet migration against the database (build unit 06b, V1 tasks 06.02 and
  06.08).

  Every wallet here was built by the real legacy ledger, so the three figures
  the migration reconciles against were produced by the shipped legacy
  arithmetic rather than by this file.

  `async: false`, because several tests change the application environment and
  because the cutover door below is a node-wide flag.

  ## The cutover door

  `AuroraMeter.Credits.LotMigration` refused a real cutover while there was no
  lot-aware refund path (`open-findings.md` X250). Build unit 06e defines
  `AuroraMeter.Credits.reverse_lot/4`, which is the gate's own condition, so
  the door is open and one test asserts that it is and that a wallet really
  goes through it. Every other test here still opens the maintainer door, which
  lives under the harness's own OTP application and which the library's
  configuration never reads, because those tests are about the replay rather
  than about the gate.
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Operations
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.LedgerFixtures
  alias Mix.Tasks.AuroraMeter.Credits.MigrateLots

  @dollar 1_000_000

  defp allow_cutover! do
    Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)
    on_exit(fn -> Application.delete_env(:aurora_meter_test, :allow_lot_cutover) end)
  end

  defp wallet(shape) do
    tenant = unique_tenant("lotmig")
    LedgerFixtures.build!(shape, tenant)
    tenant
  end

  defp migrate(tenant, opts \\ []) do
    {:ok, summary} =
      LotMigration.run(Keyword.merge([tenant: tenant, shadow: false, allow_cutover: true], opts))

    summary
  end

  defp shadow(tenant, opts \\ []) do
    {:ok, summary} = LotMigration.run(Keyword.merge([tenant: tenant, shadow: true], opts))
    summary
  end

  defp only(summary), do: hd(summary.reports)

  defp row(tenant), do: TestRepo.one(from(b in CreditBalance, where: b.tenant_key == ^tenant))

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: l.seq))

  defp allocations(tenant),
    do: TestRepo.all(from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: a.seq))

  defp figures(tenant) do
    %{balance: balance, held: held, promotional: promotional} = Credits.balance(tenant)
    %{balance: balance, held: held, promotional: promotional}
  end

  defp flags(report), do: Enum.map(report.flags, & &1.flag)

  # The three identities `v1-release.md` 10.1 states, read back from the
  # database rather than from the planner that wrote it.
  defp identities(tenant) do
    %{rows: [[available, reserved, promotional]]} =
      TestRepo.query!(
        """
        SELECT coalesce(sum(available), 0)::bigint, coalesce(sum(reserved), 0)::bigint,
               coalesce(sum(available + reserved) FILTER (WHERE category = 'promotional'), 0)::bigint
          FROM aurora_meter_credit_lots WHERE tenant_key = $1
        """,
        [tenant]
      )

    balance = row(tenant)

    %{
      balance: available + reserved - balance.debt,
      held: reserved,
      promotional: promotional
    }
  end

  test "I19 every fixture wallet migrates with balance, held and promotional unchanged" do
    allow_cutover!()

    for shape <- LedgerFixtures.shapes() do
      tenant = wallet(shape)
      before = figures(tenant)

      summary = migrate(tenant)

      assert only(summary).state == :migrated, "#{shape}: #{inspect(flags(only(summary)))}"
      assert figures(tenant) == before, "#{shape} moved the money"

      # And the lots say the same thing, read back with SQL. This is the
      # assertion that fails if the fold reconciled the wallet totals while
      # putting the value in lots that do not add up to them.
      assert identities(tenant) == before, "#{shape} lots disagree with the row"
      assert lots(tenant) != []
      assert row(tenant).lots_enabled_at
      assert row(tenant).projection_checked_at
    end
  end

  test "I19 a wallet holding a reverse row migrates and reconciles, and so does one holding the legacy shape (X266)" do
    # **The test finding X266 asks for, and it is two wallets rather than one
    # because the two row shapes are permanent.**
    #
    # Build unit 06c gave a reversal its own `kind: :reverse`. `LotMigration`'s
    # fold dispatches on `kind`, and anything it has no clause for is
    # `:unsupported_row`, which is **blocking**. So the API change alone, with
    # no other error, would have refused migration to every wallet that had ever
    # taken a refund after the change, on top of the roughly two thirds reach
    # X263 had just measured, and nothing in the suite would have said so:
    # before this test no case asserted that a wallet containing a reversal
    # migrates at all.
    #
    # The legacy half is not decoration. Rows written before the change keep
    # `kind: :debit, category: :reversal` for ever, so a fold that handled only
    # the new shape would break every wallet that has already taken a refund,
    # which is the larger population by far.
    allow_cutover!()

    new_shape = legacy_tenant()
    {:ok, _} = Credits.grant(new_shape, 5 * @dollar, reference: "pi_x266", source: %{})

    {:ok, reversal} =
      Credits.reverse(new_shape, 2 * @dollar, "refund:pi_x266:200", %{
        "payment_intent_id" => "pi_x266"
      })

    assert reversal.kind == :reverse, "the row this test is about was not written"
    assert reversal.category == :reversal

    legacy = legacy_tenant()
    {:ok, _} = Credits.grant(legacy, 5 * @dollar, reference: "pi_x266_legacy")

    {:ok, _} =
      Credits.reverse(legacy, 2 * @dollar, "refund:pi_x266_legacy:200", %{
        "payment_intent_id" => "pi_x266_legacy"
      })

    # Rewritten to the pre-version-9 shape in place, which is exactly what is in
    # the log of any installation that took a refund before upgrading.
    {1, _} =
      TestRepo.update_all(
        from(t in CreditTransaction, where: t.tenant_key == ^legacy and t.kind == ^:reverse),
        set: [kind: :debit]
      )

    assert TestRepo.one(
             from(t in CreditTransaction,
               where: t.tenant_key == ^legacy and t.kind == ^:debit,
               select: t.category
             )
           ) == :reversal

    for tenant <- [new_shape, legacy] do
      before = figures(tenant)
      summary = migrate(tenant)
      report = only(summary)

      assert report.state == :migrated, "#{tenant}: #{inspect(flags(report))}"
      refute :unsupported_row in flags(report)
      assert figures(tenant) == before, "#{tenant} moved the money"
      assert identities(tenant) == before, "#{tenant} lots disagree with the row"

      # The reversal actually reached a lot rather than being folded as a
      # nothing: 3 USD left of 5 after a 2 USD refund, and the lot says which
      # 2 USD went.
      assert [lot] = lots(tenant)
      assert lot.reversed == 2 * @dollar
      assert lot.available == 3 * @dollar

      assert Enum.any?(allocations(tenant), &(&1.kind == :reverse)),
             "#{tenant}: no reverse allocation, so the fold treated the row as something else"
    end
  end

  test "I19 one lot per grant row, and every allocation names the ledger row that caused it" do
    allow_cutover!()
    tenant = wallet(:promotional_overlap)
    migrate(tenant)

    grants =
      TestRepo.all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:grant,
          select: t.id
        )
      )

    assert Enum.sort(Enum.map(lots(tenant), & &1.grant_transaction_id)) == Enum.sort(grants)

    assert length(lots(tenant)) ==
             length(Enum.uniq(Enum.map(lots(tenant), & &1.grant_transaction_id)))

    txn_ids = MapSet.new(TestRepo.all(from(t in CreditTransaction, select: t.id)))
    lot_ids = MapSet.new(Enum.map(lots(tenant), & &1.id))

    for allocation <- allocations(tenant) do
      assert MapSet.member?(txn_ids, allocation.transaction_id)
      assert MapSet.member?(lot_ids, allocation.lot_id)
      assert allocation.from_bucket != allocation.to_bucket
      assert allocation.amount > 0
    end
  end

  test "I19 migration writes debt and expired and leaves the three legacy figures alone" do
    allow_cutover!()
    overrun = wallet(:settled_overrun)
    expired = wallet(:partial_expiry)

    before_overrun = row(overrun)
    migrate(overrun)
    migrate(expired)

    assert row(overrun).debt == 2 * @dollar
    assert row(overrun).balance == before_overrun.balance
    assert row(overrun).held == before_overrun.held
    assert row(overrun).promotional == before_overrun.promotional
    assert row(expired).expired == 10 * @dollar
    assert row(expired).debt == 0
  end

  test "L9 migration backfills hold_transaction_id on every settle and release row" do
    allow_cutover!()
    settled = wallet(:settled_overrun)
    released = wallet(:released_hold)

    # The precondition is the point: a 0.4.0 row has none, and without this
    # assertion the test would pass against rows the ledger had already filled
    # in and would prove nothing about the backfill.
    assert closers(settled) |> Enum.all?(&is_nil(&1.hold_transaction_id))

    migrate(settled)
    migrate(released)

    for tenant <- [settled, released], closer <- closers(tenant) do
      assert closer.hold_transaction_id
      hold = TestRepo.get!(CreditTransaction, closer.hold_transaction_id)
      assert hold.kind == :hold
      assert hold.tenant_key == tenant
      assert hold.reference == closer.reference
    end

    # `updated_at` stays null: the row was not changed by a writer, it was
    # given a column that had never been filled in.
    assert closers(settled) |> Enum.all?(&is_nil(&1.updated_at))
  end

  defp closers(tenant) do
    TestRepo.all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant and t.kind in [^:settle, ^:release],
        order_by: t.seq
      )
    )
  end

  test "LI-06b-6 a shadow run writes no lot, no allocation and no balance change" do
    tenant = wallet(:promotional_overlap)
    before = row(tenant)

    summary = shadow(tenant)

    assert only(summary).state == :shadow_ok
    assert lots(tenant) == []
    assert allocations(tenant) == []
    assert row(tenant) == before
    assert is_nil(row(tenant).lots_enabled_at)

    # The only thing it wrote is the report, which is the whole point of
    # running it first.
    assert %{state: "shadow_ok"} = Checkpoints.get(LotMigration.checkpoint_name(tenant))
  end

  test "I19 a shadow run reaches the same verdict as the real run that follows it" do
    allow_cutover!()

    verdicts =
      for shape <- LedgerFixtures.shapes() do
        tenant = wallet(shape)
        shadowed = only(shadow(tenant)).state
        real = only(migrate(tenant)).state
        {shape, shadowed, real}
      end

    for {shape, shadowed, real} <- verdicts do
      assert {shadowed, real} in [{:shadow_ok, :migrated}, {:blocked, :blocked}],
             "#{shape}: shadow said #{shadowed}, the real run said #{real}"
    end
  end

  test "LI-06b-3 a second run over a migrated wallet writes nothing at all" do
    allow_cutover!()
    tenant = wallet(:paid_only)
    migrate(tenant)

    lots = lots(tenant)
    allocations = allocations(tenant)
    balance = row(tenant)

    summary = migrate(tenant)

    assert only(summary).state == :skipped
    assert only(summary).reason == :already_migrated
    assert lots(tenant) == lots
    assert allocations(tenant) == allocations
    assert row(tenant) == balance
  end

  test "I19 a blocked wallet keeps lots_enabled_at null, has no lots and records its reason" do
    allow_cutover!()
    tenant = legacy_tenant()
    {:ok, _txn} = Credits.grant(tenant, 5 * @dollar, reference: "pi_blocked")
    {:ok, _txn} = Credits.reverse(tenant, 1 * @dollar, "hand-written-refund")

    summary = migrate(tenant)

    assert only(summary).state == :blocked
    assert :reversal_unattributed in flags(only(summary))
    assert is_nil(row(tenant).lots_enabled_at)
    assert lots(tenant) == []
    assert allocations(tenant) == []
    assert row(tenant).debt == 0

    checkpoint = Checkpoints.get(LotMigration.checkpoint_name(tenant))
    assert checkpoint.state == "blocked"
    assert [%{"flag" => "reversal_unattributed", "blocking" => true}] = checkpoint.counts["flags"]

    # And the legacy writer still owns it, which is what "left exactly as it
    # was found" has to mean for a wallet a customer is still using.
    assert {:ok, _txn} = Credits.debit(tenant, 1 * @dollar, "job_after_block")
    assert Credits.balance(tenant).balance == 3 * @dollar
  end

  test "I19 a wallet a previous run blocked is still counted as blocked by the next one" do
    # Otherwise a shadow run reports the wallet and the real run that follows
    # exits zero with the wallet still on the legacy writer, which is exactly
    # the shape of "a skipped required suite is a failure" applied to money.
    allow_cutover!()
    tenant = legacy_tenant()
    block_reversal_unattributed(tenant)

    first = migrate(tenant)
    assert only(first).state == :blocked
    assert first.state == "complete_with_blocked"

    second = migrate(tenant)
    assert only(second).state == :blocked
    assert only(second).reason == :blocked_before
    assert second.blocked == 1
    assert second.state == "complete_with_blocked"

    # The second run did not repeat the replay and did not overwrite the
    # reasons the first one wrote.
    checkpoint = Checkpoints.get(LotMigration.checkpoint_name(tenant))
    assert Enum.any?(checkpoint.counts["flags"], &(&1["flag"] == "reversal_unattributed"))
    assert only(second).rows == 0

    # `--retry-blocked` is what asks for the work again.
    retried = migrate(tenant, retry_blocked: true)
    assert only(retried).rows > 0
    assert :reversal_unattributed in flags(only(retried))
  end

  test "I19 every blocking flag has a wallet that triggers it and none of them migrate" do
    allow_cutover!()

    cases = [
      {:reversal_unattributed, &block_reversal_unattributed/1},
      {:reversal_exceeds_lots, &block_reversal_exceeds/1},
      {:reversal_took_reserved, &block_reversal_reserved/1},
      {:unparsable_restore_reference, &block_unparsable_restore/1},
      {:hold_unbacked, &block_hold_unbacked/1},
      {:orphan_settle, &block_orphan_settle/1},
      {:orphan_release, &block_orphan_release/1},
      {:unsupported_row, &block_unsupported_row/1},
      {:expire_unattributed, &block_expire_unattributed/1},
      {:expire_over_lot, &block_expire_over_lot/1},
      {:expire_reserved_grant, &block_expire_reserved_grant/1},
      {:promotional_divergence, &block_promotional_divergence/1},
      {:projection_mismatch, &block_projection_mismatch/1},
      {:history_out_of_order, &block_history_out_of_order/1}
    ]

    for {name, build} <- cases do
      tenant = legacy_tenant()
      build.(tenant)

      summary = migrate(tenant)
      report = only(summary)

      assert report.state == :blocked, "#{name}: the wallet was #{report.state}"
      assert name in flags(report), "#{name}: got #{inspect(flags(report))}"
      assert is_nil(row(tenant).lots_enabled_at), "#{name}: the wallet was cut over"
      assert lots(tenant) == [], "#{name}: lots were written"
      assert allocations(tenant) == [], "#{name}: allocations were written"

      checkpoint = Checkpoints.get(LotMigration.checkpoint_name(tenant))
      assert checkpoint.state == "blocked", "#{name}: no checkpoint reason"
      assert Enum.any?(checkpoint.counts["flags"], &(&1["flag"] == to_string(name)))
    end
  end

  defp block_reversal_unattributed(tenant) do
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pi_a")
    {:ok, _} = Credits.reverse(tenant, 1 * @dollar, "no-provenance")
  end

  defp block_reversal_exceeds(tenant) do
    {:ok, _} = Credits.grant(tenant, 1 * @dollar, reference: "pi_b")

    {:ok, _} =
      Credits.reverse(tenant, 3 * @dollar, "refund:pi_b:300", %{"payment_intent_id" => "pi_b"})
  end

  defp block_reversal_reserved(tenant) do
    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "pi_c")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "hold_c")

    {:ok, _} =
      Credits.reverse(tenant, 1 * @dollar, "refund:pi_c:100", %{"payment_intent_id" => "pi_c"})
  end

  defp block_unparsable_restore(tenant) do
    {:ok, _} =
      Credits.grant(tenant, @dollar,
        reference: "reinstated:not-an-intent:100",
        category: :adjustment
      )
  end

  defp block_hold_unbacked(tenant) do
    TestConfig.with_config([{:aurora_meter, :credits_overdraft_tolerance, 3 * @dollar}], fn ->
      {:ok, _} = Credits.grant(tenant, @dollar, reference: "pi_d")
      {:ok, _} = Credits.hold(tenant, 3 * @dollar, "hold_d")
    end)
  end

  defp block_orphan_settle(tenant) do
    LedgerFixtures.build!(:paid_only, tenant)
    LedgerFixtures.corrupt!(tenant, :orphan_settle)
  end

  defp block_orphan_release(tenant) do
    LedgerFixtures.build!(:paid_only, tenant)
    LedgerFixtures.corrupt!(tenant, :orphan_release)
  end

  defp block_unsupported_row(tenant) do
    LedgerFixtures.build!(:paid_only, tenant)
    LedgerFixtures.corrupt!(tenant, :unsupported_row)
  end

  defp block_expire_unattributed(tenant) do
    LedgerFixtures.build!(:partial_expiry, tenant)
    LedgerFixtures.corrupt!(tenant, :expire_without_grant_id)
  end

  defp block_expire_over_lot(tenant) do
    LedgerFixtures.build!(:partial_expiry, tenant)
    LedgerFixtures.corrupt!(tenant, :expire_over_lot)
  end

  defp block_expire_reserved_grant(tenant) do
    LedgerFixtures.build!(:expiry_over_hold, tenant)
  end

  defp block_promotional_divergence(tenant) do
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pi_e")
    {:ok, _} = Credits.debit(tenant, 5 * @dollar, "job_e")

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo_e",
        category: :promotional,
        expires_at: ~U[2099-01-01 00:00:00Z]
      )

    {:ok, _} =
      Credits.reverse(tenant, 5 * @dollar, "refund:pi_e:500", %{"payment_intent_id" => "pi_e"})
  end

  defp block_projection_mismatch(tenant) do
    LedgerFixtures.build!(:paid_only, tenant)
    LedgerFixtures.corrupt!(tenant, :balance_row, by: 1)
  end

  defp block_history_out_of_order(tenant) do
    LedgerFixtures.build!(:debits, tenant)
    LedgerFixtures.swap_inserted_at!(tenant, "pi_debits", "job_a")
    LedgerFixtures.corrupt!(tenant, :balance_after, reference: "job_c", by: 7)
  end

  test "I19 a wallet larger than max_rows is deferred, paused and left untouched" do
    allow_cutover!()
    tenant = wallet(:debits)
    before = row(tenant)

    summary = migrate(tenant, max_rows: 2)
    report = only(summary)

    assert report.state == :deferred
    assert report.reason == :too_large
    assert report.rows == 4
    assert lots(tenant) == []
    assert row(tenant) == before
    assert Operations.paused?(LotMigration.checkpoint_name(tenant))

    # A paused wallet stays paused: a later run with a higher bound does not
    # quietly pick it up, because the operator chose the pause. It is still
    # reported, as deferred rather than blocked, because deferring it was a
    # decision somebody took rather than work nobody has looked at.
    again = only(migrate(tenant, max_rows: 1000))
    assert again.state == :deferred
    assert again.reason == :paused
    assert lots(tenant) == []

    Operations.resume(LotMigration.checkpoint_name(tenant))
    assert only(migrate(tenant, max_rows: 1000)).state == :migrated
  end

  test "LI-06b-6 a shadow run never pauses a wallet it defers" do
    tenant = wallet(:debits)

    assert only(shadow(tenant, max_rows: 2)).state == :deferred
    refute Operations.paused?(LotMigration.checkpoint_name(tenant))
  end

  test "X250 the cutover gate is open, and a wallet really cuts over through the production route" do
    # **The half nothing asserted.** 06b's gate is
    # `function_exported?(AuroraMeter.Credits, :reverse_lot, 4)`, and until 06e
    # the suite only ever proved it was shut. A stub `reverse_lot/4` would have
    # opened it and every test would still have passed, which is why the
    # opening is asserted here beside a refund that has to behave.
    #
    # No maintainer door: `allow_cutover!/0` is deliberately not called, so
    # this is the production route that was refused before this unit.
    assert LotMigration.cutover_blocked() == nil
    assert function_exported?(Credits, :reverse_lot, 4)

    # A legacy wallet carrying the reference shape a real Stripe top-up leaves
    # behind, because that is what the fold derives `source.payment_intent_id`
    # from and the refund below has to be able to find its own payment.
    tenant = legacy_tenant()
    intent = "pi_#{System.unique_integer([:positive])}"
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: intent)
    {:ok, _} = Credits.debit(tenant, 6 * @dollar, "job_#{intent}")
    before = figures(tenant)

    {:ok, summary} = LotMigration.run(tenant: tenant, shadow: false, allow_cutover: true)
    report = hd(summary.reports)

    assert report.state == :migrated
    assert row(tenant).lots_enabled_at
    assert figures(tenant) == before
    assert Checkpoints.get(LotMigration.checkpoint_name(tenant))

    # The wallet is now on the allocator, which is what the gate was guarding,
    # so the hazard X250 named has to be gone rather than merely unreachable.
    # The promotion arrives after the payment and after the spend, exactly as
    # `v1-release.md` 10.1 describes it.
    {:ok, _promo} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo_after_#{intent}",
        category: :promotional
      )

    {:ok, _txn} =
      Credits.reverse_lot(tenant, 10 * @dollar, "refund:#{intent}:1000",
        source: %{payment_intent_id: intent}
      )

    by_reference = Map.new(lots(tenant), &{&1.reference, &1})

    assert by_reference[intent].reversed == 10 * @dollar
    assert by_reference["promo_after_#{intent}"].available == 4 * @dollar
    assert by_reference["promo_after_#{intent}"].consumed == 0
    assert row(tenant).debt == 6 * @dollar

    # And the refusal the gate leaves behind: a real cutover still needs to be
    # asked for.
    assert {:error, :cutover_not_requested} =
             LotMigration.run(tenant: wallet(:paid_only), shadow: false)
  end

  test "X221 a tenant key that is not a legal operation name still gets a checkpoint" do
    allow_cutover!()

    tenant =
      LedgerFixtures.legacy_wallet!(
        "lotmig ops@example.com/#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> Checkpoints.delete(LotMigration.checkpoint_name(tenant)) end)

    {:ok, _txn} = Credits.grant(tenant, 2 * @dollar, reference: "pi_odd_key")

    name = LotMigration.checkpoint_name(tenant)
    assert String.starts_with?(name, "lot_migration:sha256-")

    # The name shape is what `AuroraMeter.Operations` enforces, and the whole
    # point is that every call this unit makes into that module survives a
    # tenant key nobody sanitised.
    assert Operations.paused?(name) == false
    summary = migrate(tenant)

    assert only(summary).state == :migrated
    assert Checkpoints.get(name).counts["tenant_key"] == tenant
    assert only(summary).checkpoint == name
  end

  test "I10 the cutover stamps projection_checked_at, which only the conservation check writes" do
    allow_cutover!()
    tenant = wallet(:promotional_overlap)

    assert is_nil(row(tenant).projection_checked_at)
    migrate(tenant)
    assert row(tenant).projection_checked_at
  end

  test "LI-06b-4 a write that fails inside the cutover leaves the wallet entirely untouched" do
    allow_cutover!()
    tenant = wallet(:paid_only)
    before = row(tenant)

    Faults.arm(:before_commit, :raise,
      when: &(&1[:statement] == :balance_update and &1[:kind] == :write)
    )

    summary =
      LotMigration.run(
        tenant: tenant,
        shadow: false,
        allow_cutover: true,
        repo: AuroraMeter.Test.FaultRepo
      )
      |> elem(1)

    Faults.assert_fired!(:before_commit)

    assert only(summary).state == :blocked
    assert :exception in flags(only(summary))
    assert lots(tenant) == []
    assert allocations(tenant) == []
    assert row(tenant) == before
  end

  test "LI-06b-4 the same wallet migrates cleanly once the fault is gone" do
    # The control for the test above: without it, "nothing was written" is also
    # what a migration that never ran would produce (X125).
    allow_cutover!()
    tenant = wallet(:paid_only)

    summary = LotMigration.run(tenant: tenant, shadow: false, allow_cutover: true, repo: TestRepo)

    assert only(elem(summary, 1)).state == :migrated
    assert lots(tenant) != []
  end

  test "I19 a migrated wallet keeps answering the public credit API" do
    allow_cutover!()
    tenant = wallet(:paid_only)
    migrate(tenant)

    # Whatever else changed, the surface a host calls did not.
    assert %{balance: 4_000_000, held: 0, available: 4_000_000} = Credits.balance(tenant)
    assert {:ok, _txn} = Credits.grant(tenant, @dollar, reference: "pi_after")
    assert {:ok, _txn} = Credits.hold(tenant, @dollar, "hold_after")
    assert Credits.balance(tenant).held == @dollar
    assert {:ok, _txn} = Credits.settle("hold_after", @dollar)
    assert {:ok, _txn} = Credits.debit(tenant, @dollar, "job_after")

    assert %{balance: 3_000_000, held: 0, available: 3_000_000, promotional: 0, currency: "usd"} =
             Credits.balance(tenant)

    assert length(Credits.history(tenant, limit: 50)) > 4
  end

  test "I19 the run reports every wallet it examined, and the summary counts them" do
    allow_cutover!()
    good = wallet(:paid_only)
    bad = legacy_tenant()
    block_reversal_unattributed(bad)

    {:ok, summary} =
      LotMigration.run(tenant: [good, bad], shadow: false, allow_cutover: true)

    assert summary.wallets == 2
    assert summary.migrated == 1
    assert summary.blocked == 1
    assert summary.state == "complete_with_blocked"
    assert Enum.map(summary.reports, & &1.tenant_key) == [good, bad]
    assert Checkpoints.get("lot_migration").state == "complete_with_blocked"
  end

  test "I19 a run with a blocked wallet fails the Mix task rather than reporting success" do
    summary = %{
      shadow: false,
      wallets: 2,
      migrated: 1,
      blocked: 1,
      deferred: 0,
      skipped: 0,
      rows: 4,
      lots: 1,
      allocations: 1,
      lock_ms_max: 2,
      duration_ms: 5,
      cursor: "org_2",
      state: "complete_with_blocked",
      reports: [
        %{
          tenant_key: "org_2",
          state: :blocked,
          reason: :ambiguous,
          flags: [%{flag: :reversal_unattributed, blocking: true, detail: %{}}]
        }
      ]
    }

    assert_raise Mix.Error, ~r/1 wallets were not migrated/, fn ->
      MigrateLots.report({:ok, summary})
    end

    assert MigrateLots.report({:ok, %{summary | blocked: 0}}) == :ok

    # And a refused cutover is not a success either: the operator asked for
    # something and did not get it. The reason is written out here rather than
    # read from `cutover_blocked/0`, which answers `nil` from 06e on: the task
    # has to keep reporting a refusal it can still be handed (a future gate, or
    # an older node), and a test that fed it today's `nil` would assert nothing.
    assert_raise Mix.Error, ~r/X250/, fn ->
      MigrateLots.report(
        {:error, {:cutover_blocked, %{finding: "X250", reason: "the lot-aware refund path"}}}
      )
    end

    assert_raise Mix.Error, ~r/no cutover was requested/, fn ->
      MigrateLots.report({:error, :cutover_not_requested})
    end
  end

  test "X213 a wallet whose stored timestamps are out of order migrates from seq instead" do
    allow_cutover!()
    tenant = wallet(:debits)
    before = figures(tenant)
    LedgerFixtures.swap_inserted_at!(tenant, "pi_debits", "job_a")

    report = only(migrate(tenant))

    # `(inserted_at, id)` puts the debit before the grant it spends and the
    # balance chain refuses it; `seq` is commit order for every row written
    # from version 9 on. The label is on the report so an operator can see
    # which wallets carry backwards-stamped rows.
    assert report.state == :migrated
    assert report.ordering == :seq
    assert figures(tenant) == before
    assert identities(tenant) == before
  end

  test "I19 the scan resumes from the aggregate cursor and skips what is behind it" do
    # A shadow run, deliberately: the scan reads every balance row in the
    # database, and a real run here would reach wallets belonging to another
    # test. Shadow writes nothing but checkpoint rows, which this sandbox rolls
    # back.
    keys = for shape <- [:paid_only, :debits, :released_hold], do: wallet(shape)
    [first, second, third] = Enum.sort(keys)

    Checkpoints.put("lot_migration", %{"tenant_key" => second}, %{}, "running")

    {:ok, summary} = LotMigration.run(shadow: true, resume: true)
    examined = Enum.map(summary.reports, & &1.tenant_key)

    refute first in examined
    refute second in examined
    assert third in examined

    {:ok, fresh} = LotMigration.run(shadow: true, resume: false)
    assert first in Enum.map(fresh.reports, & &1.tenant_key)
  end

  test "I19 a recurring grant cannot reach a wallet the migration has yet to replay" do
    # 06d writes recurring grants through the ordinary grant path, so they are
    # invisible to this fold only because they refuse a wallet the allocator
    # does not own. That is 06d's structural argument and this is the
    # measurement of it: the gate answers `false` for exactly the wallets the
    # migration replays, and `true` only after the cutover it performs.
    allow_cutover!()
    tenant = wallet(:paid_only)

    rows =
      TestRepo.aggregate(
        from(t in CreditTransaction, where: t.tenant_key == ^tenant),
        :count,
        :id
      )

    refute Recurrences.lots?(tenant)
    assert {:ok, summary} = Recurrences.run(tenant: tenant)
    assert Map.get(summary.counts, "granted", 0) == 0

    assert TestRepo.aggregate(
             from(t in CreditTransaction, where: t.tenant_key == ^tenant),
             :count,
             :id
           ) == rows

    assert only(migrate(tenant)).state == :migrated
    assert Recurrences.lots?(tenant)
  end

  test "I19 report-only re-reports a migrated wallet without demoting its verdict" do
    allow_cutover!()
    tenant = wallet(:paid_only)
    migrate(tenant)

    lots = lots(tenant)
    report = only(migrate(tenant, report_only: true))

    assert report.state == :skipped
    assert report.reason == :already_migrated
    assert report.lots == length(lots)
    assert lots(tenant) == lots

    # And the checkpoint still says what happened to the wallet rather than what
    # this run did about it.
    assert Checkpoints.get(LotMigration.checkpoint_name(tenant)).state == "migrated"
  end

  test "I19 status reports the aggregate cursor and every wallet verdict" do
    allow_cutover!()
    tenant = wallet(:paid_only)
    migrate(tenant)

    status = LotMigration.status()

    assert status.cursor == tenant
    assert status.state == "complete"
    assert Enum.any?(status.wallets, &(&1.tenant_key == tenant and &1.state == "migrated"))
  end

  test "I19 down(version: 9) refuses without confirm_data_loss, which is what protects the lots" do
    # Owned and proved by 06a in `migration_v9_test.exs`; asserted here because
    # this is the unit that first puts money in those tables.
    assert 9 in AuroraMeter.Migration.data_loss_versions()
  end

  # A wallet that predates the lots-on-creation release, which is what this
  # module's whole subject is. Since 0.5.0 `Ledger.locked_row/2` stamps
  # `lots_enabled_at` on the INSERT that creates a wallet, so the first ledger
  # call against an unknown tenant produces a wallet the allocator already
  # owns. A wallet with a legacy history to replay has to be created as one.
  defp legacy_tenant(prefix \\ "lotmig"),
    do: LedgerFixtures.legacy_wallet!(unique_tenant(prefix))
end
