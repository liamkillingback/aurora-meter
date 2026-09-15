defmodule AuroraMeter.CreditsLotReversalTest do
  @moduledoc """
  `AuroraMeter.Credits.reverse_lot/4` and `restore_lot/4` (build unit 06e, V1
  task 06.06), the source-scoped reversal facade over 06a's allocator.

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

    # **The difference between the two functions, measured rather than argued.**
    # The promotional lot sorts FIRST in spend order, so the wallet-wide
    # reversal takes it, and no figure on the balance row says which lot paid.
    {:ok, _} = Credits.reverse(tenant, 1 * @dollar, "wallet_wide")
    assert %{available: 3_000_000, consumed: 1_000_000} = lot(tenant, "promo")
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
    legacy = unique_tenant("lotrev")
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

  test "X274 a wallet the migration cut over takes a recurring allowance and still refunds right" do
    # **What opening the gate made reachable.** 06d's recurring grants refuse a
    # wallet whose `lots_enabled_at` is null, and no wallet had it set, so the
    # whole feature could not reach a production wallet. This is the first test
    # where one arrives on the lot path through the production route, takes an
    # allowance, and is then refunded for the payment that funded it.
    tenant = unique_tenant("lotrev")
    AuroraMeter.subscribe(tenant, :allowance)

    # A legacy wallet, written by the legacy ledger through the public API,
    # with the payment references a real Stripe top-up leaves behind: 06b's
    # fold derives `source.payment_intent_id` from exactly that shape.
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
