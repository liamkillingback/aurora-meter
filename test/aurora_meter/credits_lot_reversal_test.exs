defmodule AuroraMeter.CreditsLotReversalTest do
  @moduledoc """
  `AuroraMeter.Credits.reverse_lot/4` and `restore_lot/4` (build unit 06e, V1
  task 06.06), the source-scoped reversal facade over 06a's allocator, and the
  **wallet-wide** `reverse/4` on a cut-over wallet (repair unit R1, finding
  X250).

  The `X250 ...` tests are R1's. Until it, `reverse/4` on a wallet the allocator
  owns was planned as a debit: it drained lots in spend order, which takes
  promotional credit FIRST, and wrote nothing into `reversed`. A customer's
  refund destroyed their promotion and left the paid credit that funded the
  purchase sitting in the wallet. The path is reachable from core and from
  `aurora_meter_pro`, whose refund fallback takes it on every wallet with no
  derivable payment provenance.

  The arithmetic lives in `AuroraMeter.Credits.Allocator` and is tested against
  the planner in `credits/allocator_test.exs`; what is tested here is the
  facade: the option validation, every error tuple, the allocation rows each
  call writes, and the promise `v1-release.md` 10.1 makes about a promotional
  lot in a wallet that has just been refunded.

  These two functions are also the wallet cutover's gate.
  `AuroraMeter.Credits.LotMigration.cutover_blocked/0` asks
  `function_exported?(AuroraMeter.Credits, :reverse_lot, 4)`, so defining
  `reverse_lot/4` at all opens it. The gate's own test lives in
  `credits_lot_migration_test.exs`; this file is the reason it is safe to open,
  which is why a stub would have been worse than nothing.

  `async: false`, because one test freezes the node-wide clock and one runs the
  wallet migration.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2]
  import Ecto.Query

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Test.LedgerFixtures

  @dollar 1_000_000
  @september ~U[2026-09-15 12:00:00Z]

  test "I10 reverse_lot takes only the lots matching the source" do
    tenant = lot_wallet()

    fund(tenant, "pi_1", 10 * @dollar)
    fund(tenant, "pi_2", 7 * @dollar)

    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)

    {:ok, txn} =
      Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_1:600",
        source: %{payment_intent_id: "pi_1"}
      )

    assert txn.kind == :reverse
    assert txn.category == :reversal
    assert txn.amount == -6 * @dollar

    assert %{reversed: 6_000_000, available: 4_000_000} = lot(tenant, "pi_1")
    assert %{reversed: 0, available: 7_000_000} = lot(tenant, "pi_2")
    assert %{reversed: 0, available: 4_000_000} = lot(tenant, "promo")

    # **The difference between the two functions, measured rather than argued,
    # and repair unit R1 changed what it is.** It used to be that the
    # wallet-wide reversal took the promotional lot, because the promotion sorts
    # first in spend order and `reverse/4` was planned as a debit (X250). It no
    # longer is: both functions exclude promotional lots and take the rest in
    # spend order. What still separates them is the cap and the provenance. This
    # one is capped by `pi_1`'s own lots; the wallet-wide one reaches `pi_1`
    # first only because it is the wallet's oldest non-promotional lot.
    {:ok, _} = Credits.reverse(tenant, 1 * @dollar, "wallet_wide")
    assert %{available: 4_000_000, consumed: 0, reversed: 0} = lot(tenant, "promo")
    assert %{available: 3_000_000, reversed: 7_000_000} = lot(tenant, "pi_1")
    assert %{available: 7_000_000, reversed: 0} = lot(tenant, "pi_2")
  end

  test "I10 reverse_lot above the cap returns exceeds_source and writes nothing" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 5 * @dollar)

    assert {:error, :exceeds_source} =
             Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_1:600",
               source: %{payment_intent_id: "pi_1"}
             )

    # Nothing written: no ledger row, no allocation, no movement on the lot.
    assert %{available: 5_000_000, reversed: 0} = lot(tenant, "pi_1")
    assert allocations(tenant) == []
    assert length(Credits.history(tenant)) == 1
    assert Credits.balance(tenant).balance == 5 * @dollar

    # `allow_partial: true` is the other half of the same decision: the cap is
    # reversed and the difference is recorded rather than lost.
    {:ok, txn} =
      Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_1:600",
        source: %{payment_intent_id: "pi_1"},
        allow_partial: true
      )

    assert txn.amount == -5 * @dollar
    assert txn.metadata["shortfall"] == @dollar
    assert %{available: 0, reversed: 5_000_000} = lot(tenant, "pi_1")
  end

  test "I10 reverse_lot of a spent lot raises debt by the unrecoverable amount" do
    # **06e's first acceptance criterion and G06 bullet 5**: a wallet funded by
    # P with 10 USD which then spends 6 USD and receives a 4 USD promotional
    # grant, refunded 10 USD for P.
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 6 * @dollar, "job_1")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)

    before = Credits.balance(tenant)

    {:ok, txn} =
      Credits.reverse_lot(tenant, 10 * @dollar, "refund:pi_1:1000",
        source: %{payment_intent_id: "pi_1"}
      )

    assert txn.amount == -10 * @dollar

    assert %{reversed: 10_000_000, available: 0, consumed: 0} = lot(tenant, "pi_1")
    assert %{available: 4_000_000, consumed: 0} = lot(tenant, "promo")
    assert row(tenant).debt == 6 * @dollar

    assert Credits.balance(tenant).balance == before.balance - 10 * @dollar
    assert Credits.balance(tenant).balance == -2 * @dollar
    assert Credits.balance(tenant).promotional == 4 * @dollar

    # **The assertion that carries the claim.** The balance is -2 USD whether
    # the promotion survives or is consumed to repay the debt, so a balance
    # assertion cannot discriminate and neither can conservation. What
    # discriminates is that no allocation this reversal wrote names the
    # promotional lot at all.
    promo_id = lot(tenant, "promo").id
    refute Enum.any?(allocations(tenant), &(&1.lot_id == promo_id))
  end

  test "X262 a reversal repays the debt it creates out of another paid lot" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 6 * @dollar)
    {:ok, _} = Credits.debit(tenant, 6 * @dollar, "job_1")
    fund(tenant, "pi_2", 10 * @dollar)

    {:ok, _} =
      Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_1:600",
        source: %{payment_intent_id: "pi_1"}
      )

    # Six reversed off `pi_1`'s consumed value, six of debt created, and all of
    # it repaid out of `pi_2`, which is what LI-06a-5 requires: debt and
    # availability are exclusive.
    assert %{reversed: 6_000_000} = lot(tenant, "pi_1")
    assert %{available: 4_000_000, consumed: 6_000_000} = lot(tenant, "pi_2")
    assert row(tenant).debt == 0

    # And the consequence X262 was measured by: a hold the legacy ledger would
    # have accepted on `sum(available) - debt` is accepted.
    assert {:ok, _} = Credits.hold(tenant, 4 * @dollar, "job_2")
  end

  test "I10 restore_lot is capped by the lots' reversed total" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)

    {:ok, _} =
      Credits.reverse_lot(tenant, 4 * @dollar, "refund:pi_1:400",
        source: %{payment_intent_id: "pi_1"}
      )

    assert {:error, :exceeds_reversed} =
             Credits.restore_lot(tenant, 5 * @dollar, "restore:pi_1:500",
               source: %{payment_intent_id: "pi_1"}
             )

    assert %{reversed: 4_000_000, available: 6_000_000} = lot(tenant, "pi_1")
    assert Credits.balance(tenant).balance == 6 * @dollar

    {:ok, txn} =
      Credits.restore_lot(tenant, 4 * @dollar, "restore:pi_1:400",
        source: %{payment_intent_id: "pi_1"}
      )

    assert txn.kind == :grant
    assert txn.category == :adjustment
    assert txn.amount == 4 * @dollar
    assert %{reversed: 0, available: 10_000_000} = lot(tenant, "pi_1")

    # A restoration creates no lot: it puts value back on the one the reversal
    # took it off, which is the whole point of scoping it to a source.
    assert length(lots(tenant)) == 1
  end

  test "I10 restore_lot repays outstanding debt before any of it becomes spendable" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 10 * @dollar, "job_1")

    {:ok, _} =
      Credits.reverse_lot(tenant, 10 * @dollar, "refund:pi_1:1000",
        source: %{payment_intent_id: "pi_1"}
      )

    assert row(tenant).debt == 10 * @dollar

    {:ok, _} =
      Credits.restore_lot(tenant, 10 * @dollar, "restore:pi_1:1000",
        source: %{payment_intent_id: "pi_1"}
      )

    # Ten restored and ten of debt repaid out of it: nothing spendable and
    # nothing owed, which is the honest end state of a refund that failed after
    # the money it took back had already been spent.
    assert row(tenant).debt == 0
    assert %{reversed: 0, available: 0, consumed: 10_000_000} = lot(tenant, "pi_1")
    assert Credits.balance(tenant).balance == 0
  end

  test "I10 reverse_lot and restore_lot are idempotent on the reference" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)

    {:ok, _} =
      Credits.reverse_lot(tenant, 3 * @dollar, "refund:pi_1:300",
        source: %{payment_intent_id: "pi_1"}
      )

    assert {:error, :duplicate_reference} =
             Credits.reverse_lot(tenant, 3 * @dollar, "refund:pi_1:300",
               source: %{payment_intent_id: "pi_1"}
             )

    {:ok, _} =
      Credits.restore_lot(tenant, @dollar, "restore:pi_1:100",
        source: %{payment_intent_id: "pi_1"}
      )

    assert {:error, :duplicate_reference} =
             Credits.restore_lot(tenant, @dollar, "restore:pi_1:100",
               source: %{payment_intent_id: "pi_1"}
             )

    assert %{reversed: 2_000_000, available: 8_000_000} = lot(tenant, "pi_1")

    # The two namespaces are their kinds' own (finding L2), so a restoration
    # may carry the string a reversal already used and neither is refused for
    # the other's write.
    assert {:ok, _} =
             Credits.restore_lot(tenant, @dollar, "refund:pi_1:300",
               source: %{payment_intent_id: "pi_1"}
             )
  end

  test "I10 reverse_lot with no matching lots returns no_matching_lots" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 5 * @dollar)

    assert {:error, :no_matching_lots} =
             Credits.reverse_lot(tenant, @dollar, "refund:pi_9:100",
               source: %{payment_intent_id: "pi_9"}
             )

    assert {:error, :no_matching_lots} =
             Credits.restore_lot(tenant, @dollar, "restore:pi_9:100",
               source: %{payment_intent_id: "pi_9"}
             )

    # And a wallet the allocator does not own: there are no lots at all, so
    # there is nothing to scope against and the caller falls back to the
    # wallet-wide path. This is the legacy wallet 06e's fallback exists for,
    # and the money still comes back.
    legacy = LedgerFixtures.legacy_wallet!(unique_tenant("lotrev"))
    {:ok, _} = Credits.grant(legacy, 5 * @dollar, reference: "pi_legacy")
    assert is_nil(row(legacy).lots_enabled_at)

    assert {:error, :no_matching_lots} =
             Credits.reverse_lot(legacy, @dollar, "refund:pi_legacy:100",
               source: %{payment_intent_id: "pi_legacy"}
             )

    assert {:ok, _} = Credits.reverse(legacy, @dollar, "refund:pi_legacy:100")
    assert Credits.balance(legacy).balance == 4 * @dollar
  end

  test "I10 reverse_lot writes one reverse allocation per lot touched" do
    tenant = lot_wallet()

    # Two lots from one payment, which is what a top-up plus a reconciliation
    # adjustment against the same PaymentIntent looks like.
    fund(tenant, "pi_1", 4 * @dollar, reference: "pi_1")
    fund(tenant, "pi_1", 3 * @dollar, reference: "pi_1:adjust")

    {:ok, txn} =
      Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_1:600",
        source: %{payment_intent_id: "pi_1"}
      )

    rows = allocations(tenant, txn.id)

    assert Enum.map(rows, &{&1.kind, &1.from_bucket, &1.to_bucket, &1.amount}) == [
             {:reverse, :available, :reversed, 4 * @dollar},
             {:reverse, :available, :reversed, 2 * @dollar}
           ]

    assert Enum.map(rows, & &1.lot_id) == [lot(tenant, "pi_1").id, lot(tenant, "pi_1:adjust").id]
  end

  test "I10 the :source option is validated rather than widened" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 2 * @dollar)

    for bad <- [
          [],
          [source: %{}],
          [source: %{payment_intent_id: "pi_1", checkout_session_id: "cs_1"}],
          [source: %{promotion: "welcome"}],
          [source: %{payment_intent_id: 1}],
          [source: "pi_1"]
        ] do
      assert_raise ArgumentError, ~r/payment_intent_id/, fn ->
        Credits.reverse_lot(tenant, @dollar, "refund:bad:#{:erlang.phash2(bad)}", bad)
      end

      assert_raise ArgumentError, ~r/payment_intent_id/, fn ->
        Credits.restore_lot(tenant, @dollar, "restore:bad:#{:erlang.phash2(bad)}", bad)
      end
    end

    # A string key names the same source, because jsonb has no atoms and a host
    # writing one form and reading the other would find nothing.
    assert {:ok, _} =
             Credits.reverse_lot(tenant, @dollar, "refund:pi_1:100",
               source: %{"payment_intent_id" => "pi_1"}
             )
  end

  test "I10 a reversal that reaches a reservation takes it last and leaves held consistent" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 3 * @dollar, "job_1")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "job_2")

    # available 5, consumed 3, reserved 2; the reversal asks for nine.
    {:ok, _} =
      Credits.reverse_lot(tenant, 9 * @dollar, "refund:pi_1:900",
        source: %{payment_intent_id: "pi_1"}
      )

    assert %{available: 0, consumed: 0, reserved: 1_000_000, reversed: 9_000_000} =
             lot(tenant, "pi_1")

    row = row(tenant)
    assert row.held == @dollar
    assert row.held == lot(tenant, "pi_1").reserved
    assert row.debt == 3 * @dollar
  end

  test "X250 a wallet-wide refund on a cut-over wallet takes the paid lot and leaves the promotion" do
    # **Repair unit R1, and the case forced rather than waited for.** A cut-over
    # wallet holding both promotional and paid credit, with the PAID lot the one
    # that funded the purchase, refunded through the wallet-wide path a caller
    # without payment provenance takes. `aurora_meter_pro`'s refund fallback is
    # that caller, on any wallet whose provenance the migration could not derive
    # (finding X263), which is a large minority of real wallets rather than an
    # edge.
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 5 * @dollar, "job_1")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)

    paid_before = lot(tenant, "pi_1")
    promo_before = lot(tenant, "promo")
    before = Credits.balance(tenant)

    assert %{available: 5_000_000, consumed: 5_000_000, reversed: 0} = paid_before
    assert %{available: 4_000_000, consumed: 0, reversed: 0} = promo_before

    {:ok, txn} = Credits.reverse(tenant, 6 * @dollar, "refund:pi_1:600")

    assert txn.kind == :reverse
    assert txn.category == :reversal
    assert txn.amount == -6 * @dollar

    # **The money, lot by lot.** Five out of `available` and one out of
    # `consumed`, all of it into `reversed`, and the one micro-dollar that had
    # already been spent becomes debt.
    assert %{available: 0, consumed: 4_000_000, reversed: 6_000_000} = lot(tenant, "pi_1")
    assert row(tenant).debt == @dollar

    # **And the promotional lot is identical, field for field.** Measured
    # against the row read before the refund rather than against a literal, so
    # nothing about it can have moved and moved back.
    assert reload(promo_before) == promo_before

    # **What the balance cannot tell you, which is why this test does not stop
    # at the balance.** The wallet is at 3 USD either way: before repair unit R1
    # the same call left `promo` at `available: 0, consumed: 4_000_000` and
    # `pi_1` at `available: 3_000_000, consumed: 7_000_000, reversed: 0` with
    # `debt: 0`, and the balance was 3 USD then too. Conservation held, every
    # CHECK held, `held = sum(reserved)` held.
    assert Credits.balance(tenant).balance == before.balance - 6 * @dollar
    assert Credits.balance(tenant).balance == 3 * @dollar

    # The `promotional` figure on the balance row moved to zero on the defect
    # and does not move now, which is what the legacy writer has always done for
    # a reversal (`Ledger.promotional_delta/2` has a clause for exactly this)
    # and what the lot path had stopped doing.
    assert Credits.balance(tenant).promotional == 4 * @dollar

    # No allocation this reversal wrote names the promotional lot at all, and
    # the ones it did write are `reverse` rather than `consume`: "writes nothing
    # into `reversed`" was the other half of X250.
    promo_id = promo_before.id
    written = allocations(tenant, txn.id)
    refute Enum.any?(written, &(&1.lot_id == promo_id))
    assert Enum.map(written, & &1.kind) == [:reverse, :reverse]
    assert Enum.map(written, & &1.amount) == [5 * @dollar, @dollar]
  end

  test "X250 a wallet-wide refund a promotional-only wallet cannot fund becomes debt" do
    # The shape the promotional rule costs something in. There is credit in the
    # wallet and the refund may not have it, so the wallet ends owing money
    # beside a live promotion: X277's bounded limit, now reachable from the
    # wallet-wide path as well as the source-scoped one.
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)
    promo_before = lot(tenant, "promo")

    {:ok, txn} = Credits.reverse(tenant, 3 * @dollar, "refund:unknown:300")

    assert txn.amount == -3 * @dollar
    assert reload(promo_before) == promo_before
    assert allocations(tenant, txn.id) == []

    row = row(tenant)
    assert row.debt == 3 * @dollar
    assert row.balance == @dollar
    assert row.promotional == 4 * @dollar
  end

  test "X250 a wallet-wide refund takes reserved value last and leaves held consistent" do
    # `reverse_lot/4`'s bucket order, on the wallet-wide path, with the same
    # reason: an open hold is work the host believes is still running, so it is
    # the last thing a refund takes.
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 3 * @dollar, "job_1")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "job_2")

    # available 5, consumed 3, reserved 2; the reversal asks for nine.
    {:ok, _} = Credits.reverse(tenant, 9 * @dollar, "refund:pi_1:900")

    assert %{available: 0, consumed: 0, reserved: 1_000_000, reversed: 9_000_000} =
             lot(tenant, "pi_1")

    row = row(tenant)
    assert row.held == @dollar
    assert row.held == lot(tenant, "pi_1").reserved
    assert row.debt == 3 * @dollar
  end

  test "X250 a wallet-wide refund is idempotent on its reference and writes once" do
    tenant = lot_wallet()
    fund(tenant, "pi_1", 5 * @dollar)

    {:ok, _} = Credits.reverse(tenant, 2 * @dollar, "refund:pi_1:200")

    assert {:error, :duplicate_reference} =
             Credits.reverse(tenant, 2 * @dollar, "refund:pi_1:200")

    assert %{available: 3_000_000, reversed: 2_000_000} = lot(tenant, "pi_1")
    assert length(allocations(tenant)) == 1
  end

  test "X355 the debt a wallet-wide refund leaves is not repaid out of the promotion by the release, the settle or the grant that follow" do
    # **Repair unit R2, and the whole sequence rather than the single call.**
    # R1 gave the refund itself the promotional exclusion and proved it per lot.
    # It held for exactly one transaction: the debt the refund left was repaid
    # by the next `release` or `settle` through `Allocator.repay_debt/5`, which
    # took `eligible/2` in spend order and therefore took the promotional lot
    # FIRST. A hold is released after any failed operation, so that is an
    # ordinary event and not an exotic one.
    #
    # Every step below asserts the promotional lot by struct equality against
    # the row read before it, so even `updated_at` moving is a failure
    # (`update_lots!/2` writes only touched lots). The one step that is allowed
    # to move it is the settlement, and it is allowed to move it only out of
    # `:reserved`, because that is the tenant spending a promotion on work.
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 10 * @dollar, "job_1")
    {:ok, _} = Credits.grant(tenant, 8 * @dollar, reference: "promo", category: :promotional)
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "h_release")
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "h_settle")

    # The paid lot is wholly spent and both holds reserved the promotion,
    # because promotional is what spend order takes first.
    assert %{available: 0, consumed: 10_000_000} = lot(tenant, "pi_1")
    assert %{available: 2_000_000, reserved: 6_000_000, consumed: 0} = lot(tenant, "promo")

    # ---- step 1: the refund. R1's fix, re-asserted as this sequence's premise.
    promo_before = lot(tenant, "promo")
    {:ok, _} = Credits.reverse(tenant, 10 * @dollar, "refund:pi_1:1000")

    assert %{available: 0, consumed: 0, reversed: 10_000_000} = lot(tenant, "pi_1")
    assert reload(promo_before) == promo_before
    assert row(tenant).debt == 10 * @dollar
    assert row(tenant).promotional == 8 * @dollar

    # ---- step 2: the release. This is X355.
    promo_before = lot(tenant, "promo")
    {:ok, _} = Credits.release("h_release")

    # The reservation came back as promotional availability and the debt stands
    # beside it. **On the defect** this read `available: 0, consumed: 5_000_000`
    # and `debt: 5_000_000`: the customer's promotion had paid for the refund.
    assert %{available: 5_000_000, reserved: 3_000_000, consumed: 0} = lot(tenant, "promo")
    assert lot(tenant, "promo").reversed == 0
    assert row(tenant).debt == 10 * @dollar
    assert row(tenant).promotional == 8 * @dollar
    assert reload(promo_before).consumed == promo_before.consumed

    # ---- step 3: the settle, which MAY spend the promotion and may not repay.
    {:ok, settle} = Credits.settle("h_settle", @dollar)
    assert settle.amount == -@dollar

    # One micro-dollar of work consumed out of the reservation, two handed back,
    # and not one micro-dollar out of `available` towards the debt.
    assert %{available: 7_000_000, reserved: 0, consumed: 1_000_000} = lot(tenant, "promo")
    assert row(tenant).debt == 10 * @dollar
    assert row(tenant).promotional == 7 * @dollar

    # ---- step 4: the grant, which is the one repayment that may take
    # promotional value, and the only door out of a frozen wallet.
    promo_before = lot(tenant, "promo")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "top_up", category: :paid)

    assert %{available: 0, consumed: 4_000_000} = lot(tenant, "top_up")
    assert row(tenant).debt == 6 * @dollar
    assert reload(promo_before) == promo_before

    # And the wallet's own law after all four, which held on the defect too and
    # is therefore the one figure here that discriminates nothing.
    row = row(tenant)
    assert row.balance == 7 * @dollar - 6 * @dollar
    assert row.balance == Credits.balance(tenant).balance

    # No allocation written by the release or by the grant names the promotional
    # lot, and the only one the settle wrote against it came out of `reserved`.
    promo_id = lot(tenant, "promo").id

    consumes =
      for a <- allocations(tenant), a.lot_id == promo_id, a.kind == :consume, do: a.amount

    assert consumes == [@dollar]
  end

  test "X355 reverse_lot/4 leaves the same debt and the release after it does not take the promotion either" do
    # **The function G06 bullet 5 is asserted against.** X355 is identical
    # through the source-scoped reversal, because the defect was never in either
    # reversal: it was in the repayment both of them hand the debt on to. If
    # this test is the one a reviewer reads, it is because the gate bullet says
    # "a refund of a spent paid lot does not erase later promotional credit",
    # and the refund of a spent paid lot is exactly the shape that creates the
    # debt this is about.
    tenant = lot_wallet()
    fund(tenant, "pi_1", 10 * @dollar)
    {:ok, _} = Credits.debit(tenant, 10 * @dollar, "job_1")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)
    {:ok, _} = Credits.hold(tenant, 4 * @dollar, "h1")

    {:ok, _} =
      Credits.reverse_lot(tenant, 10 * @dollar, "refund:pi_1:1000",
        source: %{payment_intent_id: "pi_1"}
      )

    promo_before = lot(tenant, "promo")
    assert %{available: 0, reserved: 4_000_000, consumed: 0} = promo_before
    assert row(tenant).debt == 10 * @dollar

    {:ok, _} = Credits.release("h1")

    # On the defect: `available: 0, consumed: 4_000_000` and `debt: 6_000_000`,
    # which is R1's deterministic reproduction of X355 line for line.
    assert reload(promo_before).consumed == 0
    assert %{available: 4_000_000, reserved: 0, consumed: 0} = lot(tenant, "promo")
    assert row(tenant).debt == 10 * @dollar
    assert row(tenant).promotional == 4 * @dollar
    assert Credits.balance(tenant).balance == -6 * @dollar
  end

  test "X274 a wallet the migration cut over takes a recurring allowance and still refunds right" do
    # **What opening the gate made reachable.** 06d's recurring grants refuse a
    # wallet whose `lots_enabled_at` is null, and no wallet had it set, so the
    # whole feature could not reach a production wallet. This is the first test
    # where one arrives on the lot path through the production route, takes an
    # allowance, and is then refunded for the payment that funded it.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("lotrev"))
    AuroraMeter.subscribe(tenant, :allowance)

    # A legacy wallet, written by the legacy ledger through the public API,
    # with the payment references a real Stripe top-up leaves behind: 06b's
    # fold derives `source.payment_intent_id` from exactly that shape.
    #
    # Since 0.5.0 that wallet has to be created as a pre-release one: this test
    # is about a wallet arriving on the lot path **through the migration**, and
    # a wallet created now is already there. The route a new host takes instead
    # is asserted by `credits_new_wallet_test.exs`.
    n = System.unique_integer([:positive])
    {paid_a, paid_b, manual} = {"pi_#{n}a", "pi_#{n}b", "top_up_#{n}"}

    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: paid_a)
    {:ok, _} = Credits.grant(tenant, 3 * @dollar, reference: paid_b)
    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: manual)
    {:ok, _} = Credits.debit(tenant, 6 * @dollar, "job_#{n}")

    refute Recurrences.lots?(tenant)
    {:ok, summary} = LotMigration.run(tenant: tenant, shadow: false, allow_cutover: true)
    assert hd(summary.reports).state == :migrated
    assert Recurrences.lots?(tenant)

    with_clock(@september, fn ->
      assert {:ok, run} = Recurrences.run(tenant: tenant)
      assert run.counts["granted"] == 1
    end)

    allowance = hd(Enum.filter(lots(tenant), &(&1.category == :promotional)))
    assert allowance.available == 5 * @dollar

    # The first payment funded 5 USD and the wallet's 6 USD debit consumed all
    # of it. The refund therefore reaches `consumed`, creates 5 USD of debt,
    # and X262 repays what the wallet's other PAID lots can cover.
    {:ok, _} =
      Credits.reverse_lot(tenant, 5 * @dollar, "refund:#{paid_a}:500",
        source: %{payment_intent_id: paid_a}
      )

    assert %{reversed: 5_000_000, available: 0, consumed: 0} = lot(tenant, paid_a)
    assert %{available: 0, consumed: 3_000_000} = lot(tenant, paid_b)
    assert %{available: 0, consumed: 2_000_000} = lot(tenant, manual)
    assert row(tenant).debt == @dollar

    # And the allowance is untouched, which is the whole of G06 bullet 5 for a
    # wallet whose promotional credit arrived from a recurrence rather than
    # from a hand-written grant.
    assert %{available: 5_000_000, consumed: 0, reversed: 0} = reload(allowance)
  end

  # -- helpers ----------------------------------------------------------------

  defp lot_wallet do
    tenant = unique_tenant("lotrev")
    Ledger.enable_lots!(tenant)
    tenant
  end

  defp fund(tenant, intent_id, amount, opts \\ []) do
    reference = Keyword.get(opts, :reference, intent_id)

    {:ok, txn} =
      Credits.grant(tenant, amount,
        reference: reference,
        category: :paid,
        source: %{payment_intent_id: intent_id}
      )

    txn
  end

  defp lots(tenant),
    do: TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))

  defp lot(tenant, reference),
    do:
      TestRepo.one!(
        from(l in CreditLot, where: l.tenant_key == ^tenant and l.reference == ^reference)
      )

  defp reload(%CreditLot{id: id}), do: TestRepo.get!(CreditLot, id)

  defp allocations(tenant),
    do:
      TestRepo.all(
        from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: [asc: a.seq])
      )

  defp allocations(tenant, transaction_id),
    do:
      TestRepo.all(
        from(a in CreditAllocation,
          where: a.tenant_key == ^tenant and a.transaction_id == ^transaction_id,
          order_by: [asc: a.seq]
        )
      )

  defp row(tenant),
    do: TestRepo.one!(from(b in CreditBalance, where: b.tenant_key == ^tenant))
end
