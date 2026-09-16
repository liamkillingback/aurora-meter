defmodule AuroraMeter.CreditsLotsTest do
  @moduledoc """
  The lot engine against the database (build unit 06a, V1 tasks 06.01 and
  06.04).

  A wallet is on the allocator when `lots_enabled_at` is set on its balance row,
  and on the legacy writer when it is not. Nothing sets it in production yet:
  `mix aurora_meter.credits.migrate_lots` (build unit 06b) is the cutover, and
  `Ledger.enable_lots!/1` here refuses any wallet that has a ledger row, so a
  test cannot use it to skip a replay it should have done.

  Three layers enforce conservation and each one is exercised here:

    * the per-lot CHECK constraints, which no code path can disable;
    * the in-transaction projection check, which compares the balance row
      against a `SUM` over the wallet's lots and raises
      `AuroraMeter.Credits.ConservationError` rather than committing;
    * the allocation trail, which reproduces every quantity by folding.
  """
  use AuroraMeter.DataCase, async: false
  use ExUnitProperties

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.ConservationError
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.LedgerFixtures

  @dollar 1_000_000
  @oct ~U[2026-10-01 00:00:00Z]
  @nov ~U[2026-11-01 00:00:00Z]
  @dec ~U[2026-12-01 00:00:00Z]

  test "I10 a grant writes one lot whose quantities, state and reference match the ledger row" do
    tenant = lot_wallet()
    {:ok, txn} = Credits.grant(tenant, 5 * @dollar, reference: "pay_1")

    assert [lot] = lots(tenant)
    assert lot.grant_transaction_id == txn.id
    assert lot.reference == "pay_1"
    assert lot.category == :paid
    assert lot.amount == 5 * @dollar
    assert lot.available == 5 * @dollar
    assert {lot.reserved, lot.consumed, lot.reversed, lot.expired} == {0, 0, 0, 0}
    assert lot.state == :open
    assert lot.seq > 0

    # And the projection the balance row is, which is checked in the same
    # transaction that wrote it.
    assert %{balance: 5_000_000, held: 0, available: 5_000_000} = Credits.balance(tenant)
    assert balance_row(tenant).projection_checked_at

    # A grant that creates value and touches nothing else needs no allocation:
    # an allocation is a MOVEMENT between buckets, and the lot arrived already
    # holding its own amount.
    assert allocations(tenant) == []
  end

  test "I10 a 6 USD debit against promotional A=3, promotional B=5 and paid P=10 takes A=3 and B=3" do
    # The acceptance criterion, at the database rather than in the planner:
    # G06 bullet 1 and the worked example in `v1-release.md` 10.1.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "a",
        category: :promotional,
        expires_at: @oct
      )

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "b",
        category: :promotional,
        expires_at: @nov
      )

    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "p")
    {:ok, debit} = Credits.debit(tenant, 6 * @dollar, "spend")

    assert lot(tenant, "a").available == 0
    assert lot(tenant, "b").available == 2 * @dollar
    assert lot(tenant, "p").available == 10 * @dollar

    assert lot(tenant, "a").state == :exhausted
    assert lot(tenant, "b").state == :open

    # One `consume` per lot touched, and the paid lot was not touched.
    trail = allocations(tenant, debit.id)
    assert length(trail) == 2
    assert Enum.all?(trail, &(&1.kind == :consume))
    assert amount_on(trail, lot(tenant, "a").id) == 3 * @dollar
    assert amount_on(trail, lot(tenant, "b").id) == 3 * @dollar

    assert Credits.balance(tenant).balance == 12 * @dollar
    assert Credits.balance(tenant).promotional == 2 * @dollar
  end

  test "I10 every lot quantity is reproduced by folding that lot's allocations" do
    # LI-06a-3, and the thing that makes a lot's quantities reconstructible
    # rather than merely asserted.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo",
        category: :promotional,
        expires_at: @nov
      )

    {:ok, _} = Credits.grant(tenant, 6 * @dollar, reference: "paid")
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "h1")
    {:ok, _} = Credits.settle("h1", @dollar)
    {:ok, _} = Credits.debit(tenant, 2 * @dollar, "d1")

    for lot <- lots(tenant) do
      folded = fold_allocations(tenant, lot.id, lot.amount)

      assert folded == Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]),
             "lot #{lot.reference}: the allocation trail says #{inspect(folded)} and the row " <>
               "says #{inspect(Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]))}"
    end
  end

  test "I12 expiry moves only the due lot's available to expired and leaves reserved alone" do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "due",
        category: :promotional,
        expires_at: @oct
      )

    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "later", category: :promotional)
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "h1")

    assert {:ok, report} = Credits.expire_due(@dec, limit: 10)
    assert report.expired == 1

    due = lot(tenant, "due")
    assert due.expired == 3 * @dollar
    assert due.reserved == 2 * @dollar
    assert due.available == 0
    # Still open: it holds a reservation, so the sweep has more to do once the
    # hold closes.
    assert due.state == :open

    # I12: the lot that was not due kept every micro-dollar.
    assert lot(tenant, "later").available == 4 * @dollar
    assert lot(tenant, "later").expired == 0

    # `expired` on the balance row, not on the public snapshot: the display
    # fields are 06c's.
    assert balance_row(tenant).expired == 3 * @dollar
  end

  test "I12 overlapping promotions expire their own remainder and never each other's" do
    # G06 bullet 3, and the defect the legacy `promotional` figure has: one
    # number per wallet cannot say which grant a spend came out of, so the first
    # grant to expire reclaimed value the second had contributed.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "oct",
        category: :promotional,
        expires_at: @oct
      )

    {:ok, _} =
      Credits.grant(tenant, 10 * @dollar,
        reference: "nov",
        category: :promotional,
        expires_at: @nov
      )

    # Spends soonest-expiry first, so October pays all 5 and November pays 7.
    {:ok, _} = Credits.debit(tenant, 12 * @dollar, "spend")
    assert lot(tenant, "oct").available == 0
    assert lot(tenant, "nov").available == 3 * @dollar

    # October is already exhausted, so the sweep at the end of October has
    # nothing of its own to take and does not reach into November's remainder.
    assert {:ok, report} = Credits.expire_due(~U[2026-10-02 00:00:00Z], limit: 10)
    assert report.expired == 0
    assert lot(tenant, "nov").available == 3 * @dollar
    assert Credits.balance(tenant).balance == 3 * @dollar

    # And in December November expires its own three, and no more.
    assert {:ok, report} = Credits.expire_due(@dec, limit: 10)
    assert report.expired == 1
    assert lot(tenant, "nov").expired == 3 * @dollar
    assert lot(tenant, "oct").expired == 0
    assert Credits.balance(tenant).balance == 0
  end

  test "I12 a reservation released on an expired lot becomes expired, never spendable" do
    # Finding L1 and the invariant breach `v1-release.md` 10.1 names: the legacy
    # ledger handed this value back as spendable and the sweep could never take
    # it again, because the grant was already stamped.
    #
    # The clock is moved rather than the dates, because the release itself has
    # to see the lot as past: `Credits.release/1` takes its instant from
    # `Clock.db_now/0`, so a test that only passed a late instant to the sweep
    # would be asserting about a lot the release still believed was live.
    tenant = lot_wallet()

    AuroraMeter.Test.with_clock(~U[2026-09-15 00:00:00.000000Z], fn ->
      {:ok, _} =
        Credits.grant(tenant, 5 * @dollar,
          reference: "promo",
          category: :promotional,
          expires_at: @oct
        )

      {:ok, _} = Credits.hold(tenant, 2 * @dollar, "h1")
    end)

    release =
      AuroraMeter.Test.with_clock(@dec, fn ->
        assert {:ok, _} = Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 10)
        assert lot(tenant, "promo").expired == 3 * @dollar

        {:ok, release} = Credits.release("h1")
        release
      end)

    promo = lot(tenant, "promo")
    assert promo.expired == 5 * @dollar
    assert promo.available == 0
    assert promo.reserved == 0
    assert promo.state == :expired

    # The release row says what it destroyed, because this is the one case where
    # a release moves the balance by something other than nothing.
    assert release.amount == -2 * @dollar
    assert release.metadata["expired_amount"] == 2 * @dollar
    assert [%{kind: :expire, amount: 2_000_000}] = allocations(tenant, release.id)

    assert Credits.balance(tenant).balance == 0
    assert Credits.balance(tenant).held == 0
    refute Credits.sufficient?(tenant, 1)
  end

  test "I12 a hold taken before expiry settles against its reserved portion afterwards" do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "promo",
        category: :promotional,
        expires_at: @oct
      )

    {:ok, _} =
      AuroraMeter.Test.with_clock(~U[2026-09-15 00:00:00.000000Z], fn ->
        Credits.hold(tenant, 2 * @dollar, "h1")
      end)

    settle =
      AuroraMeter.Test.with_clock(@dec, fn ->
        assert {:ok, _} = Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 10)

        # The work really ran and really cost 1.5 USD, so it is paid for out of
        # the reservation the hold made before the expiry, which is what
        # `hold/4` promised. The half it did not use is written off, not handed
        # back.
        {:ok, settle} = Credits.settle("h1", 1_500_000)
        settle
      end)

    promo = lot(tenant, "promo")
    assert promo.consumed == 1_500_000
    assert promo.expired == 3_500_000
    assert promo.available == 0
    assert settle.settled_amount == 1_500_000
    assert settle.metadata["expired_amount"] == 500_000

    assert Credits.balance(tenant).balance == 0
    assert Credits.balance(tenant).held == 0
  end

  test "I12 the expiry sweep run twice writes one expire row, one allocation and the reference expire:<lot_id>:0" do
    # Finding L7: a partial expiry used to take `System.unique_integer/1` into
    # its reference, so a retried pass wrote a second row.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "promo",
        category: :promotional,
        expires_at: @oct
      )

    lot_id = lot(tenant, "promo").id

    assert {:ok, %{examined: 1, expired: 1}} = Credits.expire_due(@dec, limit: 10)

    # The second pass does not examine it at all, which is stronger than
    # refusing it: `available = 0` takes the lot out of the candidate set, so a
    # sweep that runs every half hour does no work per already-expired lot
    # rather than one refused transaction each. The reference is idempotent as
    # well (finding L7), and the assertion below names the exact string.
    assert {:ok, %{examined: 0, expired: 0, failed: 0}} = Credits.expire_due(@dec, limit: 10)

    rows =
      TestRepo.all(
        from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:expire)
      )

    assert [%{reference: reference, amount: amount}] = rows
    assert reference == "expire:" <> lot_id <> ":0"
    assert amount == -3 * @dollar

    assert [%{kind: :expire}] = allocations(tenant, hd(rows).id)
    assert lot(tenant, "promo").state == :expired
  end

  test "I10 a settle stamps hold_transaction_id and updated_at on both rows" do
    # Finding L9: a settle or release row did not name its hold, and a hold row
    # was mutated in place with nothing recording when.
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")
    {:ok, hold} = Credits.hold(tenant, 2 * @dollar, "h1")

    assert is_nil(hold.updated_at)
    assert is_nil(hold.hold_transaction_id)

    {:ok, settle} = Credits.settle("h1", @dollar)

    assert settle.hold_transaction_id == hold.id
    # The settle row is not itself updated in place, so it has no `updated_at`.
    assert is_nil(settle.updated_at)

    closed = TestRepo.get!(CreditTransaction, hold.id)
    assert closed.status == :settled
    assert closed.updated_at, "the hold row was closed and nothing recorded when"
  end

  test "I10 a lot edited by hand is refused by aurora_meter_credit_lots_conservation_check" do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")
    id = lot(tenant, "pay").id

    error =
      assert_raise Postgrex.Error, fn ->
        TestRepo.query!(
          "UPDATE aurora_meter_credit_lots SET available = available + 1 WHERE id = $1",
          [Ecto.UUID.dump!(id)]
        )
      end

    assert error.postgres.constraint == "aurora_meter_credit_lots_conservation_check"

    # The negative control: the same edit that KEEPS the sum is accepted, so it
    # is the constraint that answered and not something about UPDATE on this
    # table.
    assert %{num_rows: 1} =
             TestRepo.query!(
               "UPDATE aurora_meter_credit_lots SET available = available - 1, " <>
                 "consumed = consumed + 1 WHERE id = $1",
               [Ecto.UUID.dump!(id)]
             )
  end

  test "I10 a balance row edited by hand raises ConservationError and the write is rolled back" do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")

    # One micro-dollar the lots cannot account for.
    TestRepo.query!(
      "UPDATE aurora_meter_credit_balances SET balance = balance + 1 WHERE tenant_key = $1",
      [tenant]
    )

    before_rows = TestRepo.aggregate(CreditTransaction, :count)
    before_allocations = TestRepo.aggregate(CreditAllocation, :count)

    error =
      assert_raise ConservationError, fn ->
        Credits.debit(tenant, @dollar, "spend")
      end

    assert error.tenant_key == tenant
    assert error.operation == :debit
    assert error.deltas.balance == 1
    assert error.message =~ "Nothing was written"

    # And nothing was: the raise aborted the transaction.
    assert TestRepo.aggregate(CreditTransaction, :count) == before_rows
    assert TestRepo.aggregate(CreditAllocation, :count) == before_allocations
    assert lot(tenant, "pay").available == 5 * @dollar
    assert balance_row(tenant).balance == 5 * @dollar + 1
  end

  test "I10 a settle above its hold records debt, which blocks a new hold until a grant repays it" do
    # The acceptance criterion in `v1-release.md` 10.1: never hide executed cost
    # by pretending settlement was not owed.
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")
    {:ok, _} = Credits.hold(tenant, 5 * @dollar, "h1")
    {:ok, settle} = Credits.settle("h1", 7 * @dollar)

    assert settle.amount == -7 * @dollar
    assert balance_row(tenant).debt == 2 * @dollar
    assert Credits.balance(tenant).balance == -2 * @dollar
    assert lot(tenant, "pay").consumed == 5 * @dollar

    refute Credits.sufficient?(tenant, 1)
    # The refusal names the debt rather than blaming the balance, which is
    # repair unit R3's half of X357 (finding X361).
    assert {:error, :debt_outstanding} = Credits.hold(tenant, @dollar, "h2")

    {:ok, grant} = Credits.grant(tenant, 3 * @dollar, reference: "top_up")

    assert balance_row(tenant).debt == 0
    assert Credits.balance(tenant).balance == @dollar
    assert lot(tenant, "top_up").available == @dollar
    assert lot(tenant, "top_up").consumed == 2 * @dollar

    # The repayment is a `consume` allocation on the new lot, so where the money
    # went is answerable rather than inferred.
    assert [%{kind: :consume, amount: 2_000_000}] = allocations(tenant, grant.id)
    assert {:ok, _} = Credits.hold(tenant, @dollar, "h3")
  end

  test "X355 debt outlives promotional availability, which is LI-06a-5 as repair unit R2 amends it" do
    # **The amended invariant, and the whole cost of R2's decision, on a wallet
    # that never saw a refund.** The defect X355 names is in
    # `Allocator.repay_debt/5`, which every settle, release and grant reaches,
    # so the shape is reachable from an overspend alone: no reversal is needed
    # and none is used here.
    #
    # LI-06a-5 said `debt > 0` implies `SUM(lot.available) = 0`. It now says so
    # over the wallet's **non-promotional** lots, because the rule that a
    # promotion is never consumed to repay a debt is the stronger one
    # (`architecture-map.md` 7.2, amended by R2).
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 3 * @dollar, reference: "pay")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)

    # Spend order puts the promotion first, so `h1` reserves the promotion whole
    # and `h2` reserves the paid lot whole.
    {:ok, _} = Credits.hold(tenant, 4 * @dollar, "h1")
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "h2")

    # `h2` costs 5 USD against a 3 USD reservation, and there is no availability
    # anywhere to cover the rest: 2 USD of executed cost becomes debt.
    {:ok, _} = Credits.settle("h2", 5 * @dollar)
    assert balance_row(tenant).debt == 2 * @dollar

    # The release hands 4 USD of promotional credit back, and the debt stands
    # beside it. **On the defect** the release repaid out of it: `promo` read
    # `available: 2_000_000, consumed: 2_000_000` and `debt: 0`.
    {:ok, _} = Credits.release("h1")

    assert lot(tenant, "promo").available == 4 * @dollar
    assert lot(tenant, "promo").consumed == 0
    assert lot(tenant, "pay").available == 0
    assert balance_row(tenant).debt == 2 * @dollar
    assert balance_row(tenant).promotional == 4 * @dollar
    assert Credits.balance(tenant).balance == 2 * @dollar

    # **What it costs, asserted rather than described.** The wallet holds a
    # positive balance made entirely of promotional credit and still refuses
    # every hold and debit, because `architecture-map.md` 7.2 says neither may
    # spend while `debt > 0`. That is X277's one bad shape, and R2 makes it
    # common rather than rare. Relaxing the refusal to `spendable/3` is a second
    # amendment and is deliberately not made here, nor by repair unit R3
    # (finding X361: it is the owner's, and it is commercial).
    #
    # **What R3 does change is the two things about this state that were wrong
    # whichever way that decision goes** (findings X357 and X361). The refusal
    # now names the debt instead of blaming the balance, and the two figures
    # that claim spendability report what this refusal will actually do. Before
    # R3 this wallet reported `spendable: 4_000_000` and
    # `promotional_spendable: 4_000_000` while refusing a hold of one
    # micro-dollar, which is the shape a support ticket is made of.
    assert {:error, :debt_outstanding} = Credits.hold(tenant, @dollar, "h3")
    assert {:error, :debt_outstanding} = Credits.debit(tenant, @dollar, "d1")

    frozen = Credits.balance(tenant)
    assert frozen.balance == 2 * @dollar
    assert frozen.promotional == 4 * @dollar
    assert frozen.debt == 2 * @dollar
    assert frozen.spendable == 0
    assert frozen.promotional_spendable == 0
    refute Credits.sufficient?(tenant, 1)

    # And the door out, which is why the grant clause keeps repaying out of the
    # lot it creates whatever its category: any incoming grant clears the debt
    # and the promotion is then spendable, whole.
    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "top_up")

    assert balance_row(tenant).debt == 0
    assert lot(tenant, "top_up").consumed == 2 * @dollar
    assert lot(tenant, "promo").available == 4 * @dollar

    # And the figures say so before the caller tries: the way out is visible in
    # `balance/1` and not only in the ledger's answer (R3, X361).
    cleared = Credits.balance(tenant)
    assert cleared.spendable == 4 * @dollar
    assert cleared.promotional_spendable == 4 * @dollar
    assert Credits.sufficient?(tenant, 4 * @dollar)

    assert {:ok, _} = Credits.debit(tenant, @dollar, "d2")
    assert lot(tenant, "promo").consumed == @dollar
  end

  test "I10 credit past its expires_at is not spendable before the sweep reaches it" do
    # The one deliberate compatibility change in this unit. In 0.4.0 this credit
    # stayed spendable until the next sweep, which made expiry a race; the
    # negative control is the same wallet one month earlier.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "promo",
        category: :promotional,
        expires_at: ~U[2020-01-01 00:00:00Z]
      )

    # The sweep has not run: the row still says the money is available.
    assert lot(tenant, "promo").available == 5 * @dollar
    assert lot(tenant, "promo").state == :open

    refute Credits.sufficient?(tenant, @dollar)
    assert {:error, :insufficient_credits} = Credits.hold(tenant, @dollar, "h1")
    assert {:error, :insufficient_credits} = Credits.debit(tenant, @dollar, "d1")

    {:ok, _} = Credits.grant(tenant, @dollar, reference: "live", category: :promotional)
    assert Credits.sufficient?(tenant, @dollar)
    assert {:ok, _} = Credits.debit(tenant, @dollar, "d2")
    assert lot(tenant, "live").consumed == @dollar
    assert lot(tenant, "promo").consumed == 0
  end

  test "I10 a wallet with lots_enabled_at null uses the legacy arithmetic and writes no lot" do
    # Built as a pre-release wallet on purpose. Since 0.5.0 a wallet is born on
    # the allocator, so `lots_enabled_at` is null only on a wallet that existed
    # before that release and that the migration has not reached.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("lots"))

    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "h1")
    {:ok, _} = Credits.settle("h1", @dollar)

    assert lots(tenant) == []
    assert allocations(tenant) == []
    assert is_nil(balance_row(tenant).lots_enabled_at)
    assert is_nil(balance_row(tenant).projection_checked_at)
    assert balance_row(tenant).debt == 0

    assert %{balance: 4_000_000, held: 0, available: 4_000_000} = Credits.balance(tenant)
  end

  test "I10 enable_lots! refuses a wallet that has a ledger row rather than cutting it over" do
    # A test seam that could be used to skip a replay would be a way to lose
    # money quietly. 06b owns the cutover, with its per-wallet reconciliation.
    #
    # The wallet is a pre-release one, because that is the only kind the
    # refusal is still about: a wallet created since 0.5.0 is on the allocator
    # already and has nothing to cut over.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("lots"))
    {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay")

    assert_raise ArgumentError, ~r/migrate_lots/, fn -> Ledger.enable_lots!(tenant) end
    assert is_nil(balance_row(tenant).lots_enabled_at)
  end

  test "I10 the balance row refuses a negative held, which nothing enforced before version 9" do
    # Finding X183: `held` was a bare bigint and the only thing standing between
    # a lost row lock and silent corruption was the lock. It is now a CHECK, so
    # the same mistake is a refused write.
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay")

    error =
      assert_raise Postgrex.Error, fn ->
        TestRepo.query!(
          "UPDATE aurora_meter_credit_balances SET held = -1 WHERE tenant_key = $1",
          [tenant]
        )
      end

    assert error.postgres.constraint == "aurora_meter_credit_balances_held_check"

    for {column, constraint} <- [
          {"promotional", "aurora_meter_credit_balances_promotional_check"},
          {"debt", "aurora_meter_credit_balances_debt_check"},
          {"expired", "aurora_meter_credit_balances_expired_check"}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          TestRepo.query!(
            "UPDATE aurora_meter_credit_balances SET #{column} = -1 WHERE tenant_key = $1",
            [tenant]
          )
        end

      assert error.postgres.constraint == constraint
    end
  end

  property "I10 a generated history on a lot wallet reconstructs the balance row, the debt, the held amount and every lot's allocations" do
    # **G06 bullet 4**, for the lot half. 01e's model test owns the flat-ledger
    # half and compares a generated history against an independent pure model;
    # this asks the narrower question the lot engine adds, over arbitrary valid
    # sequences: does the trail reproduce the rows?
    #
    # Three reconstructions, each from a different direction, and none of them
    # is the arithmetic the writer used:
    #
    #   * every lot's five quantities, folded from that lot's own allocations;
    #   * the balance row, projected from the lots;
    #   * the balance itself, summed from the ledger's own `amount` column,
    #     which is the law the flat ledger has always had and which the lot
    #     path must not break.
    check all(commands <- history(), max_runs: 40) do
      tenant = lot_wallet()
      Enum.each(commands, &execute(tenant, &1))

      row = balance_row(tenant)
      lots = lots(tenant)

      for lot <- lots do
        folded = fold_allocations(tenant, lot.id, lot.amount)

        assert folded == Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]),
               "#{tenant} lot #{lot.reference}: the allocation trail says #{inspect(folded)} " <>
                 "and the row says #{inspect(Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]))}" <>
                 "\ncommands: #{inspect(commands)}"

        assert lot.state == CreditLot.state_for(Map.put(folded, :amount, lot.amount))
      end

      available = Enum.reduce(lots, 0, &(&1.available + &2))
      reserved = Enum.reduce(lots, 0, &(&1.reserved + &2))
      expired = Enum.reduce(lots, 0, &(&1.expired + &2))

      promotional =
        lots
        |> Enum.filter(&(&1.category == :promotional))
        |> Enum.reduce(0, &(&1.available + &1.reserved + &2))

      assert row.balance == available + reserved - row.debt, "#{tenant}: #{inspect(commands)}"
      assert row.held == reserved, "#{tenant}: #{inspect(commands)}"
      assert row.promotional == promotional, "#{tenant}: #{inspect(commands)}"
      assert row.expired == expired, "#{tenant}: #{inspect(commands)}"
      assert row.debt >= 0

      # **LI-06a-5 as amended by repair unit R2** (findings X277 and X355):
      # `debt > 0` implies no **non-promotional** availability. Debt and
      # availability are exclusive because every incoming value repays debt
      # before it becomes available and every outgoing value drains availability
      # before it creates debt, and the promotional exclusion in
      # `architecture-map.md` 7.2 is the stronger rule where the two meet: a
      # debt is never repaid out of credit the wallet already holds if that
      # credit is promotional, so where the only availability left is
      # promotional the debt stands beside it until the next grant repays it.
      #
      # This assertion enforced the unamended form until R2, and R2 is the
      # change that makes the unamended form false on the settle and release
      # paths as well as on the reversal. Widening it here is the same decision
      # as the amendment in `architecture-map.md` 7.2 and in 06a's LI-06a-5, and
      # it is deliberately not silent: the non-promotional half is still
      # asserted exactly, so the invariant is weakened by precisely the promise
      # 7.2 makes and by nothing else.
      purchased_available =
        lots
        |> Enum.filter(&(&1.category != :promotional))
        |> Enum.reduce(0, &(&1.available + &2))

      if row.debt > 0,
        do: assert(purchased_available == 0, "#{tenant}: #{inspect(commands)}")

      # And the ledger's own law, which the flat ledger has always had: the
      # balance is the sum of every entry's amount.
      assert row.balance == ledger_sum(tenant), "#{tenant}: #{inspect(commands)}"
    end
  end

  test "I10 a grant's :source lands on the lot, which is how a refund finds the payment" do
    # 06e's seam, implemented here so 06e is wiring only: a paid reversal finds
    # the lots a payment funded by `source ->> 'payment_intent_id'`, which has
    # its own partial index. Atom keys and string keys both arrive as strings,
    # because jsonb has no atoms and a host writing one form and reading the
    # other would find nothing.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "pi_atoms",
        source: %{payment_intent_id: "pi_1", checkout_session_id: "cs_1"}
      )

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "pi_strings",
        source: %{"payment_intent_id" => "pi_2"}
      )

    {:ok, _} = Credits.grant(tenant, @dollar, reference: "no_source")

    assert lot(tenant, "pi_atoms").source == %{
             "payment_intent_id" => "pi_1",
             "checkout_session_id" => "cs_1"
           }

    assert lot(tenant, "pi_strings").source == %{"payment_intent_id" => "pi_2"}
    assert lot(tenant, "no_source").source == %{}

    # And the index's predicate really selects: the lot with no source is not in
    # it, so a refund lookup cannot wander into an unrelated grant.
    %{rows: rows} =
      TestRepo.query!(
        "SELECT reference FROM aurora_meter_credit_lots WHERE tenant_key = $1 " <>
          "AND source ->> 'payment_intent_id' = $2",
        [tenant, "pi_1"]
      )

    assert rows == [["pi_atoms"]]
  end

  test "I11 settling one hold below its reservation leaves a second hold's reservation on the same lot intact" do
    # **The defect 01e's independent lot model found** (finding X251), as a
    # deterministic regression. The planner used to hand back this hold's
    # ORIGINAL per-lot reservation on settle rather than what was left of it
    # after the settlement consumed part, which the lot's own `reserved` caps
    # away while there is only one hold on the lot and which steals the other
    # hold's reservation the moment there are two.
    #
    # **Note what did not catch it.** Conservation holds throughout: `reserved`
    # to `available` keeps the lot's five buckets summing to its amount, so the
    # CHECK constraint is satisfied. `held` still equals `sum(reserved)`, so the
    # projection check is satisfied. Every assertion 06a wrote against its own
    # implementation passed. It took a second implementation of the same design
    # to see it.
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "pay")

    {:ok, _} = Credits.hold(tenant, 4 * @dollar, "h1")
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "h2")

    assert lot(tenant, "pay").reserved == 7 * @dollar
    assert lot(tenant, "pay").available == 3 * @dollar

    # h1 cost 1 USD of its 4, so 3 USD go back to available and h2's 3 USD stay
    # reserved. The broken version handed back all 4 of h1's, leaving h2 holding
    # 2 USD of a reservation it never released.
    {:ok, _} = Credits.settle("h1", @dollar)

    lot = lot(tenant, "pay")
    assert lot.consumed == @dollar
    assert lot.reserved == 3 * @dollar, "h2's reservation was not left intact"
    assert lot.available == 6 * @dollar

    assert balance_row(tenant).held == 3 * @dollar

    # And h2 can still settle for everything it reserved, which is the promise
    # `hold/4` made to it and the thing the defect would have broken.
    {:ok, settle} = Credits.settle("h2", 3 * @dollar)
    assert settle.amount == -3 * @dollar
    assert balance_row(tenant).debt == 0
    assert lot(tenant, "pay").consumed == 4 * @dollar
    assert lot(tenant, "pay").available == 6 * @dollar
    assert balance_row(tenant).held == 0
  end

  test "I11 every ledger write takes the balance row, then the transaction row, then the lots" do
    # `architecture-map.md` 7.3 fixes ONE lock order for every ledger write, and
    # 0.4.0 had two: grant, hold and debit took the balance row first, while
    # settle, release and expiry took a transaction row first. No deadlock was
    # possible only because the second group locked exactly one transaction row
    # each, which stops being true the moment a third row class (the lots) joins
    # them.
    #
    # `pg_locks` says what a transaction HOLDS; it does not say in what order it
    # took them. The statement stream does, so that is what is asserted here and
    # `docs/evidence/v1/phase-06/06a-locks.md` carries both.
    #
    # This assertion discriminates by construction: before this unit a settle's
    # order was `[:transactions, :balances]`, which is not the list below in any
    # arrangement.
    tenant = lot_wallet()

    grant = locks_taken(fn -> Credits.grant(tenant, 5 * @dollar, reference: "pay") end)
    assert grant == [:balances, :lots]

    hold = locks_taken(fn -> Credits.hold(tenant, 2 * @dollar, "h1") end)
    assert hold == [:balances, :lots]

    settle = locks_taken(fn -> Credits.settle("h1", @dollar) end)
    assert settle == [:balances, :transactions, :lots]

    {:ok, _} = Credits.hold(tenant, @dollar, "h2")
    release = locks_taken(fn -> Credits.release("h2") end)
    assert release == [:balances, :transactions, :lots]

    debit = locks_taken(fn -> Credits.debit(tenant, @dollar, "d1") end)
    assert debit == [:balances, :lots]

    {:ok, _} =
      Credits.grant(tenant, @dollar,
        reference: "promo",
        category: :promotional,
        expires_at: ~U[2020-01-01 00:00:00Z]
      )

    expiry = locks_taken(fn -> Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 5) end)
    assert expiry == [:balances, :lots]
  end

  # -- the generated history --------------------------------------------------

  # Amounts are small multiples of a micro-dollar rather than round dollars, so
  # a plan that happens to divide evenly is not the only shape generated.
  defp history do
    StreamData.list_of(command(), min_length: 1, max_length: 12)
  end

  defp command do
    StreamData.one_of([
      StreamData.tuple({
        StreamData.constant(:grant),
        StreamData.integer(1..5_000_000),
        StreamData.member_of([:paid, :promotional, :adjustment]),
        StreamData.member_of([nil, :past, :future])
      }),
      StreamData.tuple({StreamData.constant(:hold), StreamData.integer(1..3_000_000)}),
      StreamData.tuple({StreamData.constant(:settle), StreamData.integer(0..4_000_000)}),
      StreamData.constant({:release}),
      StreamData.tuple({StreamData.constant(:debit), StreamData.integer(1..3_000_000)}),
      StreamData.constant({:expire})
    ])
  end

  # Every command is issued for real and every outcome is accepted: a refusal is
  # a legal outcome of a valid sequence and the properties above must hold after
  # one exactly as they do after a success. What is NOT accepted is a raise,
  # which is what a ConservationError would be.
  defp execute(tenant, {:grant, amount, category, expiry}) do
    Credits.grant(tenant, amount,
      reference: "#{tenant}:g#{next(tenant)}",
      category: category,
      expires_at: expires_at(category, expiry)
    )
  end

  defp execute(tenant, {:hold, amount}),
    do: Credits.hold(tenant, amount, "#{tenant}:h#{next(tenant)}")

  defp execute(tenant, {:settle, actual}) do
    case open_hold(tenant) do
      nil -> :no_hold
      reference -> Credits.settle(reference, actual)
    end
  end

  defp execute(tenant, {:release}) do
    case open_hold(tenant) do
      nil -> :no_hold
      reference -> Credits.release(reference)
    end
  end

  defp execute(tenant, {:debit, amount}),
    do: Credits.debit(tenant, amount, "#{tenant}:d#{next(tenant)}")

  defp execute(_tenant, {:expire}),
    do: Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 20)

  # Only a promotional grant may carry an expiry, and the ledger rejects one on
  # anything else, so the generator does not try to produce that shape.
  defp expires_at(:promotional, :past), do: ~U[2020-01-01 00:00:00Z]
  defp expires_at(:promotional, :future), do: ~U[2099-01-01 00:00:00Z]
  defp expires_at(_category, _expiry), do: nil

  defp next(tenant) do
    key = {__MODULE__, :seq, tenant}
    n = Process.get(key, 0) + 1
    Process.put(key, n)
    n
  end

  defp open_hold(tenant) do
    TestRepo.one(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant and t.kind == ^:hold and t.status == ^:pending,
        order_by: [asc: t.seq],
        limit: 1,
        select: t.reference
      )
    )
  end

  defp ledger_sum(tenant) do
    TestRepo.one!(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant,
        select: type(coalesce(sum(t.amount), 0), :integer)
      )
    )
  end

  # -- helpers ----------------------------------------------------------------

  # The `FOR UPDATE` statements `fun` issues, in the order it issued them, as
  # table names. Ecto's own query telemetry runs in the process that made the
  # query, so this records the real statement stream rather than a reconstruction.
  defp locks_taken(fun) do
    handler = "lock-order-#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> [] end)

    :telemetry.attach(
      handler,
      [:aurora_meter, :test_repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if String.contains?(query, "FOR UPDATE") do
          Agent.update(agent, &[table_of(query) | &1])
        end
      end,
      nil
    )

    try do
      fun.()
      agent |> Agent.get(& &1) |> Enum.reverse() |> Enum.dedup()
    after
      :telemetry.detach(handler)
      Agent.stop(agent)
    end
  end

  defp table_of(query) do
    cond do
      String.contains?(query, "aurora_meter_credit_balances") -> :balances
      String.contains?(query, "aurora_meter_credit_lots") -> :lots
      String.contains?(query, "aurora_meter_credit_transactions") -> :transactions
      true -> :other
    end
  end

  defp lot_wallet do
    tenant = unique_tenant("lots")
    Ledger.enable_lots!(tenant)
    tenant
  end

  defp lots(tenant) do
    TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))
  end

  defp lot(tenant, reference) do
    TestRepo.one!(
      from(l in CreditLot, where: l.tenant_key == ^tenant and l.reference == ^reference)
    )
  end

  defp allocations(tenant) do
    TestRepo.all(
      from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: [asc: a.seq])
    )
  end

  defp allocations(tenant, transaction_id) do
    TestRepo.all(
      from(a in CreditAllocation,
        where: a.tenant_key == ^tenant and a.transaction_id == ^transaction_id,
        order_by: [asc: a.seq]
      )
    )
  end

  defp amount_on(allocations, lot_id) do
    allocations |> Enum.filter(&(&1.lot_id == lot_id)) |> Enum.map(& &1.amount) |> Enum.sum()
  end

  defp balance_row(tenant), do: TestRepo.get_by!(CreditBalance, tenant_key: tenant)

  # The lot's five quantities rebuilt from its allocations alone, which is what
  # makes them reconstructible rather than merely asserted (LI-06a-3).
  defp fold_allocations(tenant, lot_id, amount) do
    tenant
    |> allocations()
    |> Enum.filter(&(&1.lot_id == lot_id))
    |> Enum.reduce(
      %{available: amount, reserved: 0, consumed: 0, reversed: 0, expired: 0},
      fn allocation, acc -> move(acc, allocation) end
    )
  end

  # **The recorded buckets, not a guess from `kind`.** This helper used to infer
  # the source (`if acc.reserved >= n, do: :reserved, else: :available` for a
  # consume, and so on), which is wrong whenever a wallet has both a reservation
  # and spare availability: the generated-history property below found
  # `[grant 4076543 adjustment, hold 738690, debit 483911]`, where the debit
  # comes out of `available` and the guess took it out of `reserved`. The
  # allocation row now records `from_bucket` and `to_bucket`, so the fold reads
  # the movement instead of reconstructing it.
  defp move(acc, %{from_bucket: from, to_bucket: to, amount: amount}),
    do: shift(acc, from, to, amount)

  defp shift(acc, from, to, amount) do
    acc |> Map.update!(from, &(&1 - amount)) |> Map.update!(to, &(&1 + amount))
  end
end
