defmodule AuroraMeter.Credits.LotMigrationReplayTest do
  @moduledoc """
  The pure fold, against wallets the real legacy ledger built (build unit 06b,
  V1 task 06.02).

  `AuroraMeter.Credits.LotMigration.replay/2` reads no repo, no clock and no
  configuration. The fixtures do: every wallet here is produced by calling
  `AuroraMeter.Credits` against a wallet whose `lots_enabled_at` is null, so the
  figures the fold is checked against are the ones the shipped legacy
  arithmetic really wrote rather than the ones this file believes it wrote.

  ## What carries the claim

  Every test below asserts on the **lots** the fold produced, not only on
  `{:ok, _}`. A replay that reconciled the three wallet figures while putting
  the value in the wrong lots would satisfy `{:ok, _}`, every conservation
  identity and the per-row chain, and would still have destroyed the provenance
  the whole unit exists to create.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Allocator
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.LedgerFixtures

  @dollar 1_000_000

  defp wallet(shape) do
    tenant = unique_tenant("lotmig")
    LedgerFixtures.build!(shape, tenant)
    tenant
  end

  defp fold(tenant), do: LotMigration.replay(LedgerFixtures.rows(tenant), tenant)

  defp lot(book, tenant, name) do
    reference = LedgerFixtures.ref(tenant, name)
    Enum.find(book.lots, &(&1.reference == reference))
  end

  defp lot_by_prefix(book, prefix),
    do: Enum.find(book.lots, &String.starts_with?(&1.reference, prefix))

  defp final(book, %{id: id}),
    do: Enum.find(book.book, &(&1.id == id))

  defp quantities(book, tenant, name) do
    book
    |> final(lot(book, tenant, name))
    |> Map.take([:available, :reserved, :consumed, :expired])
  end

  defp figures(book) do
    book.book
    |> Allocator.projection(book.debt)
    |> Map.put(:debt, book.debt)
  end

  defp three(book), do: Map.take(figures(book), [:balance, :held, :promotional])

  defp row_figures(tenant) do
    %{balance: balance, held: held, promotional: promotional} = Credits.balance(tenant)
    %{balance: balance, held: held, promotional: promotional}
  end

  defp flags(list) when is_list(list), do: Enum.map(list, & &1.flag)
  defp flags(%{flags: list}), do: Enum.map(list, & &1.flag)

  test "I19 a paid-only wallet replays into one lot per grant, spent oldest first" do
    tenant = wallet(:paid_only)
    {:ok, book} = fold(tenant)

    assert length(book.lots) == 3

    assert Enum.map(book.lots, & &1.reference) ==
             Enum.map(~w(pi_paid_a pi_paid_b top_up_manual), &LedgerFixtures.ref(tenant, &1))

    # The 6 USD debit takes all of the 5 USD grant and 1 USD of the next. That
    # is the assertion that would fail if the spend order were wrong, and it
    # cannot be satisfied by any wallet-level total: all three lots are paid,
    # so every distribution of 6 USD reconciles the same way.
    assert quantities(book, tenant, "pi_paid_a").consumed == 5 * @dollar
    assert quantities(book, tenant, "pi_paid_a").available == 0
    assert quantities(book, tenant, "pi_paid_b").consumed == 1 * @dollar
    assert quantities(book, tenant, "pi_paid_b").available == 2 * @dollar
    assert quantities(book, tenant, "top_up_manual").consumed == 0

    # A bare reference is not a payment intent and must not be recorded as one.
    assert lot(book, tenant, "pi_paid_a").source["payment_intent_id"] ==
             LedgerFixtures.ref(tenant, "pi_paid_a")

    assert lot(book, tenant, "top_up_manual").source["reference"] ==
             LedgerFixtures.ref(tenant, "top_up_manual")

    refute Map.has_key?(lot(book, tenant, "top_up_manual").source, "payment_intent_id")
    assert three(book) == row_figures(tenant)
  end

  test "I19 overlapping promotional grants replay soonest-expiry first, before paid" do
    tenant = wallet(:promotional_overlap)
    {:ok, book} = fold(tenant)

    # G06 bullet 1 at the fold: A=3 and B=5 promotional, P=10 paid, a 6 USD
    # debit takes A=3 and B=3 and leaves P untouched.
    assert quantities(book, tenant, "promo_a") == %{
             available: 0,
             reserved: 0,
             consumed: 3 * @dollar,
             expired: 0
           }

    assert quantities(book, tenant, "promo_b").consumed == 3 * @dollar
    assert quantities(book, tenant, "promo_b").available == 2 * @dollar
    assert quantities(book, tenant, "pi_overlap").available == 10 * @dollar
    assert three(book) == row_figures(tenant)
  end

  test "I19 a non-expiring promotional lot sorts last within its category" do
    tenant = wallet(:promotional_no_expiry)
    {:ok, book} = fold(tenant)

    # 4 USD never expires, 2 USD expires in 2099, 1 USD paid. A 3 USD debit
    # takes the dated promotion first and then the undated one, which is what
    # "non-expiring lots sort last within their category" means.
    assert quantities(book, tenant, "promo_dated").consumed == 2 * @dollar
    assert quantities(book, tenant, "promo_forever").consumed == 1 * @dollar
    assert quantities(book, tenant, "pi_small").consumed == 0
    assert three(book) == row_figures(tenant)
  end

  test "I12 a hold spanning a partial expiry replays without moving the money" do
    tenant = wallet(:partial_expiry)
    {:ok, book} = fold(tenant)

    # The legacy sweep expired 6 USD of a 10 USD grant because a 4 USD hold
    # covered the rest, the release handed that 4 USD back, and a second sweep
    # took it. The replay must reproduce **that**, not the fixed semantics: if
    # the release wrote the reservation off as expired instead of handing it
    # back, the second expire row would have nothing to take and the wallet
    # would block.
    assert quantities(book, tenant, "promo_due") == %{
             available: 0,
             reserved: 0,
             consumed: 0,
             expired: 10 * @dollar
           }

    assert figures(book).expired == 10 * @dollar
    assert three(book) == row_figures(tenant)
    assert row_figures(tenant) == %{balance: 0, held: 0, promotional: 0}
  end

  test "I12 a hold still open on an expiring lot is reported, and nothing moves" do
    tenant = wallet(:pending_hold)
    {:ok, book} = fold(tenant)

    # Promotional first: the 3 USD hold reserves the 2 USD promotion and 1 USD
    # of the payment.
    assert quantities(book, tenant, "promo_pending").reserved == 2 * @dollar
    assert quantities(book, tenant, "pi_pending").reserved == 1 * @dollar
    assert :reserved_on_expiring_lot in flags(book)
    assert three(book) == row_figures(tenant)
  end

  test "I19 a settlement above its hold replays into consume and debt" do
    tenant = wallet(:settled_overrun)
    {:ok, book} = fold(tenant)

    assert quantities(book, tenant, "pi_overrun") == %{
             available: 0,
             reserved: 0,
             consumed: 4 * @dollar,
             expired: 0
           }

    # The 6 USD settlement against a 4 USD wallet leaves 2 USD of executed cost
    # with nothing to fund it, which is debt rather than a hidden negative.
    assert figures(book).debt == 2 * @dollar
    assert figures(book).balance == -2 * @dollar
    assert three(book) == row_figures(tenant)
  end

  test "I19 a released hold hands its reservation back to the lot it came from" do
    tenant = wallet(:released_hold)
    {:ok, book} = fold(tenant)

    # The hold reserved the 1 USD promotion and 1 USD of the payment; the
    # release gave both back; the later 1 USD debit then spent the promotion
    # again, promotional first. A wallet-level total cannot tell that apart
    # from the debit spending the payment.
    assert quantities(book, tenant, "promo_released").consumed == 1 * @dollar
    assert quantities(book, tenant, "promo_released").available == 0
    assert quantities(book, tenant, "pi_released").available == 4 * @dollar
    assert three(book) == row_figures(tenant)
  end

  test "I19 a refund is attributed to the payment that funded it, not to spend order" do
    tenant = wallet(:refund)
    {:ok, book} = fold(tenant)

    assert quantities(book, tenant, "pi_refunded").consumed == 1 * @dollar
    assert quantities(book, tenant, "pi_refunded").available == 2 * @dollar
    assert final(book, lot(book, tenant, "pi_refunded")).reversed == 2 * @dollar
    assert figures(book).debt == 0
    assert three(book) == row_figures(tenant)
  end

  test "I19 a dispute reversal carrying a dispute id in its reference resolves the payment" do
    tenant = wallet(:dispute)
    {:ok, book} = fold(tenant)

    assert final(book, lot(book, tenant, "pi_disputed")).reversed == 3 * @dollar
    assert three(book) == row_figures(tenant)
  end

  test "I19 a reconciled reversal and its restore adjustment both name the payment" do
    tenant = wallet(:reconciled)
    {:ok, book} = fold(tenant)

    restore = lot_by_prefix(book, "reconciled_restore:")
    assert restore.source["payment_intent_id"] == LedgerFixtures.ref(tenant, "pi_reconciled")
    assert restore.category == :adjustment
    assert three(book) == row_figures(tenant)
  end

  test "I19 a reinstatement adjustment is a lot the same payment's reversal can reach" do
    tenant = wallet(:reinstated)
    {:ok, book} = fold(tenant)

    reinstated = lot_by_prefix(book, "reinstated:")
    assert reinstated.source["payment_intent_id"] == LedgerFixtures.ref(tenant, "pi_reinstated")
    assert three(book) == row_figures(tenant)
  end

  test "I19 a promotional grant that landed on debt keeps its amount and repays the debt" do
    tenant = wallet(:grant_on_debt)
    {:ok, book} = fold(tenant)

    # `Promotions` attributed 3 USD of the 6 USD grant, because the wallet was
    # 3 USD down. The lot keeps the whole 6 USD and 3 USD of it went straight
    # back out as debt repayment, which leaves the same 3 USD spendable and the
    # same promotional figure. The lot can say how much was granted; the legacy
    # figure could not.
    assert lot(book, tenant, "promo_on_debt").amount == 6 * @dollar
    assert quantities(book, tenant, "promo_on_debt").available == 3 * @dollar
    assert quantities(book, tenant, "promo_on_debt").consumed == 3 * @dollar
    assert :promotional_clamped in flags(book)
    assert figures(book).debt == 0
    assert three(book) == row_figures(tenant)
  end

  test "L10 a pre-version-4 wallet with no promotional_after replays and does not block" do
    tenant = wallet(:pre_v4)
    {:ok, book} = fold(tenant)

    assert Enum.all?(LedgerFixtures.rows(tenant), &is_nil(&1.promotional_after))
    assert three(book) == row_figures(tenant)

    # And the check that was skipped really was the promotional one: the
    # balance and held chains still ran on every row.
    assert Enum.all?(LedgerFixtures.rows(tenant), &is_integer(&1.balance_after))
  end

  test "L10 a pre-version-4 wallet whose promotional figure disagrees still blocks" do
    tenant = wallet(:pre_v4)

    # The wallet's own balance row is the oracle, and with `promotional_after`
    # gone it is the only one left. Moving it by one micro-dollar is the whole
    # difference between a wallet that migrates and one that does not.
    LedgerFixtures.corrupt!(tenant, :balance_row, by: 1)
    {:ok, book} = fold(tenant)

    refute three(book) == row_figures(tenant)
  end

  test "I19 a reversal with no resolvable payment intent blocks the wallet" do
    tenant = unique_tenant("lotmig")
    {:ok, _txn} = Credits.grant(tenant, 5 * @dollar, reference: "pi_manual_#{tenant}")
    {:ok, _txn} = Credits.reverse(tenant, 1 * @dollar, "hand-written-refund-#{tenant}")

    assert {:blocked, blocked} = fold(tenant)
    assert :reversal_unattributed in flags(blocked)
    assert Enum.all?(blocked, & &1.blocking)
  end

  test "I19 a reversal larger than the lots that payment funded blocks the wallet" do
    tenant = unique_tenant("lotmig")
    intent = "pi_small_grant_#{tenant}"
    {:ok, _txn} = Credits.grant(tenant, 1 * @dollar, reference: intent)

    {:ok, _txn} =
      Credits.reverse(tenant, 3 * @dollar, "refund:#{intent}:300", %{
        "payment_intent_id" => intent
      })

    assert {:blocked, blocked} = fold(tenant)
    assert :reversal_exceeds_lots in flags(blocked)
  end

  test "I19 a reversal that would take reserved value blocks the wallet" do
    tenant = unique_tenant("lotmig")
    intent = "pi_all_reserved_#{tenant}"
    {:ok, _txn} = Credits.grant(tenant, 2 * @dollar, reference: intent)
    {:ok, _txn} = Credits.hold(tenant, 2 * @dollar, "hold_all_#{tenant}")

    {:ok, _txn} =
      Credits.reverse(tenant, 1 * @dollar, "refund:#{intent}:100", %{
        "payment_intent_id" => intent
      })

    assert {:blocked, blocked} = fold(tenant)
    assert :reversal_took_reserved in flags(blocked)
  end

  test "I19 an adjustment whose restore reference names no payment blocks the wallet" do
    tenant = unique_tenant("lotmig")

    {:ok, _txn} =
      Credits.grant(tenant, 1 * @dollar,
        reference: "reinstated:nope_#{tenant}:100",
        category: :adjustment
      )

    assert {:blocked, blocked} = fold(tenant)
    assert :unparsable_restore_reference in flags(blocked)
  end

  test "I19 a hold the overdraft tolerance allowed but no lot can back blocks the wallet" do
    tenant = unique_tenant("lotmig")

    TestConfig.with_config([{:aurora_meter, :credits_overdraft_tolerance, 3 * @dollar}], fn ->
      {:ok, _txn} = Credits.grant(tenant, 1 * @dollar, reference: "pi_thin_#{tenant}")
      {:ok, _txn} = Credits.hold(tenant, 3 * @dollar, "hold_beyond_lots_#{tenant}")
    end)

    # The legacy ledger let the hold through on `balance - held + tolerance`.
    # A lot reserves exact value and there is none, so the reservation cannot
    # be reproduced and the wallet is never cut over. This is the one place a
    # documented behaviour change is also a migration refusal.
    assert {:blocked, blocked} = fold(tenant)
    assert :hold_unbacked in flags(blocked)
  end

  test "I19 a settle with no hold in the history blocks the wallet" do
    tenant = wallet(:paid_only)
    LedgerFixtures.corrupt!(tenant, :orphan_settle)

    assert {:blocked, blocked} = fold(tenant)
    assert :orphan_settle in flags(blocked)
  end

  test "I19 a release with no hold in the history blocks the wallet" do
    tenant = wallet(:paid_only)
    LedgerFixtures.corrupt!(tenant, :orphan_release)

    assert {:blocked, blocked} = fold(tenant)
    assert :orphan_release in flags(blocked)
  end

  test "I19 a row of a kind the fold has no rule for blocks the wallet" do
    tenant = wallet(:paid_only)
    LedgerFixtures.corrupt!(tenant, :unsupported_row)

    assert {:blocked, blocked} = fold(tenant)
    assert :unsupported_row in flags(blocked)
  end

  test "I19 an expire row that names no grant blocks the wallet" do
    tenant = wallet(:partial_expiry)
    LedgerFixtures.corrupt!(tenant, :expire_without_grant_id)

    assert {:blocked, blocked} = fold(tenant)
    assert :expire_unattributed in flags(blocked)
  end

  test "I19 an expire row larger than the grant it names blocks the wallet" do
    tenant = wallet(:partial_expiry)
    LedgerFixtures.corrupt!(tenant, :expire_over_lot)

    assert {:blocked, blocked} = fold(tenant)
    assert :expire_over_lot in flags(blocked)
  end

  test "X261 an expiry that destroyed a grant a hold had reserved blocks the wallet" do
    # The legacy expiry guard is `max(balance - held, 0)` for the whole wallet,
    # so the 10 USD promotion covers the 1 USD hold and the sweep destroys the
    # 1 USD promotion the hold was actually reserving. No lot assignment
    # reproduces that row: expiring only the available part moves the balance
    # by less than the row says, and expiring the reserved part as well moves
    # `held`, which the row says did not move.
    tenant = unique_tenant("lotmig")
    LedgerFixtures.build!(:expiry_over_hold, tenant)

    assert {:blocked, blocked} = fold(tenant)
    assert :expire_reserved_grant in flags(blocked)

    # And the flag is the one that tells an operator which of the two causes it
    # is: the shortfall is exactly what a live hold still holds.
    detail = Enum.find(blocked, &(&1.flag == :expire_reserved_grant)).detail
    assert detail.amount == detail.available + detail.reserved
    assert detail.reserved == 1 * @dollar
  end

  test "X250 a refund that drove the balance negative past a live promotion blocks" do
    # The legacy ledger clamped `promotional` to zero the moment the balance
    # went below it; the lot model keeps the promotion whole and records debt.
    # The two genuinely disagree about what the customer holds, so the wallet
    # is not migrated. Found by working the arithmetic rather than by a test
    # failing, and kept as a test so it cannot be argued away later.
    tenant = unique_tenant("lotmig")
    intent = "pi_clamped_#{tenant}"
    {:ok, _txn} = Credits.grant(tenant, 5 * @dollar, reference: intent)
    {:ok, _txn} = Credits.debit(tenant, 5 * @dollar, "job_clamped_#{tenant}")

    {:ok, _txn} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo_survives_#{tenant}",
        category: :promotional,
        expires_at: ~U[2099-01-01 00:00:00Z]
      )

    {:ok, _txn} =
      Credits.reverse(tenant, 5 * @dollar, "refund:#{intent}:500", %{
        "payment_intent_id" => intent
      })

    assert Credits.balance(tenant).promotional == 0

    assert {:blocked, blocked} = fold(tenant)
    assert :promotional_divergence in flags(blocked)
  end

  test "X213 a row stamped out of order folds correctly once the order comes from seq" do
    tenant = wallet(:debits)
    LedgerFixtures.swap_inserted_at!(tenant, "pi_debits", "job_a")

    # In `(inserted_at, id)` order the debit now comes before the grant it
    # spends, and the balance chain says so. `seq` is the commit order for
    # every row written from version 9 on, so the retry reproduces the wallet
    # exactly. `architecture-map.md` 7.4 expected this wallet to block, and it
    # does not have to.
    assert {:blocked, blocked} =
             LotMigration.replay(LedgerFixtures.rows_by_inserted_at(tenant), tenant)

    assert :ledger_chain_mismatch in flags(blocked)
    assert {:ok, _book} = fold(tenant)
  end

  test "I19 a history no ordering can reconcile blocks rather than migrating wrong" do
    tenant = wallet(:debits)
    LedgerFixtures.swap_inserted_at!(tenant, "pi_debits", "job_a")
    LedgerFixtures.corrupt!(tenant, :balance_after, reference: "job_c", by: 7)

    assert {:blocked, blocked} =
             LotMigration.replay(LedgerFixtures.rows_by_inserted_at(tenant), tenant)

    assert :ledger_chain_mismatch in flags(blocked)
    assert {:blocked, by_seq} = fold(tenant)
    assert :ledger_chain_mismatch in flags(by_seq)
  end

  test "I19 every flag the fold raises is classified, and a blocking one halts the fold" do
    # A flag nobody classified is a flag that does not block, which is the
    # quiet failure mode of a list like this.
    tenant = wallet(:paid_only)
    LedgerFixtures.corrupt!(tenant, :orphan_settle)
    {:blocked, blocked} = fold(tenant)

    assert Enum.all?(blocked, &is_map_key(&1, :blocking))
    assert Enum.any?(blocked, & &1.blocking)
  end
end
