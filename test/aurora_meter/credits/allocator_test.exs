defmodule AuroraMeter.Credits.AllocatorTest do
  @moduledoc """
  The pure planner of the allocation engine (build unit 06a, V1 task 06.04).

  No database and no clock: the planner takes a book of lots that have already
  been read and locked, and an instant, and returns the movements to make. That
  is the whole point of the split. The migration that replays a wallet's history
  into lots (06b) and the runtime that writes new ones drive the **same**
  function, so they cannot disagree about what a history means, and the decision
  can be tested without a transaction anywhere near it.

  Every test here is about a decision. The writes those decisions turn into are
  `AuroraMeter.CreditsLotsTest`'s, and the races they survive are
  `AuroraMeter.CreditsLotsConcurrencyTest`'s.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AuroraMeter.Credits.Allocator

  @dollar 1_000_000
  @oct ~U[2026-10-01 00:00:00Z]
  @nov ~U[2026-11-01 00:00:00Z]
  @now ~U[2026-09-15 00:00:00Z]

  test "I10 the spend order is promotional, then earliest expiry, then oldest grant, then seq" do
    # Built out of order on purpose: the key has to be total and it has to be
    # the only thing that decides, so the list order must not survive the sort.
    book = [
      lot(:paid, 1, expires_at: @oct, seq: 1),
      lot(:promotional, 2, expires_at: @nov, seq: 2),
      lot(:promotional, 3, expires_at: @oct, seq: 3),
      lot(:promotional, 4, expires_at: nil, seq: 4),
      lot(:adjustment, 5, expires_at: nil, seq: 5),
      lot(:promotional, 6, expires_at: @oct, seq: 6),
      lot(:promotional, 7, expires_at: @oct, granted_at: ~U[2020-01-01 00:00:00Z], seq: 7)
    ]

    assert order(book) == [
             # promotional, expiring soonest, oldest grant first, then seq
             7,
             3,
             6,
             # promotional, later expiry
             2,
             # promotional, never expires: last within its category
             4,
             # paid and adjustment rank together, and an expiry beats no expiry
             1,
             5
           ]
  end

  test "I10 a 6 USD debit against promotional A=3, promotional B=5 and paid P=10 takes A=3 and B=3" do
    a = lot(:promotional, 1, amount: 3 * @dollar, expires_at: @oct)
    b = lot(:promotional, 2, amount: 5 * @dollar, expires_at: @nov)
    p = lot(:paid, 3, amount: 10 * @dollar)

    # G06 bullet 1: the answer must not depend on the order the query returned
    # the lots in, so all six permutations are asserted rather than one.
    for permutation <- permutations([a, b, p]) do
      {:ok, plan} = Allocator.plan(permutation, {:debit, 6 * @dollar, @now, false, 0, 0})

      assert consumed(plan, a.id) == 3 * @dollar
      assert consumed(plan, b.id) == 3 * @dollar
      assert consumed(plan, p.id) == 0

      assert bucket(plan, a.id, :available) == 0
      assert bucket(plan, b.id, :available) == 2 * @dollar
      assert bucket(plan, p.id, :available) == 10 * @dollar

      # And the accounting: a spend against availability creates no debt.
      assert plan.debt_delta == 0
    end
  end

  test "I10 a lot past its expires_at is not eligible for a debit and is not consumed" do
    fresh = lot(:promotional, 1, amount: 2 * @dollar, expires_at: @nov)
    stale = lot(:promotional, 2, amount: 5 * @dollar, expires_at: ~U[2026-09-01 00:00:00Z])

    # The stale lot sorts FIRST under the spend order (its expiry is earlier),
    # so if eligibility were not applied it would be the one that paid.
    assert order([fresh, stale]) == [2, 1]

    assert {:error, :insufficient_credits} =
             Allocator.plan([fresh, stale], {:debit, 3 * @dollar, @now, false, 0, 0})

    {:ok, plan} = Allocator.plan([fresh, stale], {:debit, 2 * @dollar, @now, false, 0, 0})
    assert consumed(plan, fresh.id) == 2 * @dollar
    assert consumed(plan, stale.id) == 0
  end

  test "I10 a grant while debt is outstanding repays the debt before creating availability" do
    attrs = %{
      id: "new-lot",
      tenant_key: "t",
      category: :paid,
      amount: 3 * @dollar,
      reference: "r",
      expires_at: nil,
      granted_at: @now,
      seq: 9,
      source: %{}
    }

    {:ok, plan} = Allocator.plan([], {:grant, attrs, 2 * @dollar})

    assert plan.debt_delta == -2 * @dollar
    assert consumed(plan, "new-lot") == 2 * @dollar
    assert bucket(plan, "new-lot", :available) == @dollar

    # The balance moves by the whole grant, not by what is left of it: the
    # contribution rises by 1 USD and the debt falls by 2 USD.
    assert Allocator.projection(plan.book, 0).balance == @dollar
  end

  test "I10 settle below the reservation consumes the reserved subset and unreserves the rest" do
    reserved = held_lot(:paid, 1, amount: 10 * @dollar, reserved: 4 * @dollar)

    {:ok, plan} =
      Allocator.plan([reserved], {:settle, [{reserved.id, 4 * @dollar}], @dollar, @now, 0})

    assert consumed(plan, reserved.id) == @dollar
    assert kind_total(plan, reserved.id, :unreserve) == 3 * @dollar
    assert bucket(plan, reserved.id, :reserved) == 0
    assert bucket(plan, reserved.id, :available) == 9 * @dollar
    assert plan.debt_delta == 0
  end

  test "I10 settle above the reservation consumes remaining availability then records debt" do
    # 5 USD reserved out of a 5 USD lot: nothing else is available anywhere, so
    # a 7 USD settlement can only put the difference in debt.
    only = held_lot(:paid, 1, amount: 5 * @dollar, reserved: 5 * @dollar, available: 0)

    {:ok, plan} =
      Allocator.plan([only], {:settle, [{only.id, 5 * @dollar}], 7 * @dollar, @now, 0})

    assert consumed(plan, only.id) == 5 * @dollar
    assert plan.debt_delta == 2 * @dollar
    assert Allocator.projection(plan.book, 2 * @dollar).balance == -2 * @dollar

    # And with other funds present the shortfall comes out of them first.
    spare = lot(:paid, 2, amount: 3 * @dollar)

    {:ok, plan} =
      Allocator.plan([only, spare], {:settle, [{only.id, 5 * @dollar}], 7 * @dollar, @now, 0})

    assert consumed(plan, spare.id) == 2 * @dollar
    assert plan.debt_delta == 0
  end

  test "I12 a reservation released on a lot past its expiry becomes expired, never available" do
    # Finding L1 and the invariant it breaks. The legacy ledger handed this
    # value back as spendable, and the sweep could not take it again because the
    # grant was already stamped.
    expired = held_lot(:promotional, 1, amount: 5 * @dollar, reserved: 2 * @dollar, available: 0)
    expired = %{expired | expires_at: ~U[2026-09-01 00:00:00Z], expired: 3 * @dollar}

    {:ok, plan} = Allocator.plan([expired], {:release, [{expired.id, 2 * @dollar}], @now, 0})

    assert kind_total(plan, expired.id, :expire) == 2 * @dollar
    assert kind_total(plan, expired.id, :unreserve) == 0
    assert bucket(plan, expired.id, :available) == 0
    assert bucket(plan, expired.id, :expired) == 5 * @dollar

    # The negative control is the same release one day earlier, while the lot is
    # still live: then it is an unreserve and the value is spendable again. If
    # the `past?` test were removed both branches would take this one.
    live = %{expired | expires_at: @nov}
    {:ok, plan} = Allocator.plan([live], {:release, [{live.id, 2 * @dollar}], @now, 0})
    assert kind_total(plan, live.id, :unreserve) == 2 * @dollar
    assert kind_total(plan, live.id, :expire) == 0
  end

  test "I12 expiry moves only the due lot's available and refuses when it is all reserved" do
    due =
      held_lot(:promotional, 1,
        amount: 5 * @dollar,
        reserved: 2 * @dollar,
        available: 3 * @dollar
      )

    other = lot(:promotional, 2, amount: 4 * @dollar)

    {:ok, plan} = Allocator.plan([due, other], {:expire, due.id, @now})

    assert kind_total(plan, due.id, :expire) == 3 * @dollar
    assert bucket(plan, due.id, :reserved) == 2 * @dollar
    # I12: nothing of any other lot moved.
    assert bucket(plan, other.id, :available) == 4 * @dollar
    assert plan.movements |> Enum.map(& &1.lot_id) |> Enum.uniq() == [due.id]

    all_held = held_lot(:promotional, 3, amount: 2 * @dollar, reserved: 2 * @dollar, available: 0)
    assert {:error, :held} = Allocator.plan([all_held], {:expire, all_held.id, @now})

    spent = %{lot(:promotional, 4, amount: 2 * @dollar) | available: 0, consumed: 2 * @dollar}
    assert {:error, :already_expired} = Allocator.plan([spent], {:expire, spent.id, @now})
  end

  test "I10 reverse takes available, then consumed, then reserved, and only consumed creates debt" do
    funded =
      held_lot(:paid, 1, amount: 10 * @dollar, reserved: 2 * @dollar, available: 3 * @dollar)

    funded = %{funded | consumed: 5 * @dollar, source: %{"payment_intent_id" => "pi_1"}}
    promo = lot(:promotional, 2, amount: 4 * @dollar)

    {:ok, plan} = Allocator.plan([funded, promo], {:reverse, "pi_1", 9 * @dollar, @now, 0})

    assert kind_total(plan, funded.id, :reverse) == 9 * @dollar
    assert bucket(plan, funded.id, :available) == 0
    assert bucket(plan, funded.id, :consumed) == 0
    assert bucket(plan, funded.id, :reserved) == @dollar

    # Only the 5 USD that had already been spent becomes debt: taking value out
    # of `available` or `reserved` moves the balance directly.
    assert plan.debt_delta == 5 * @dollar

    # A paid reversal never touches a promotional lot, whatever order it sorts
    # in: the promotion did not come from that payment.
    assert bucket(plan, promo.id, :available) == 4 * @dollar
    assert {:error, :no_matching_lot} = Allocator.plan([promo], {:reverse, "pi_1", 1, @now, 0})
  end

  test "X262 the debt a reversal creates is repaid out of paid availability and never promotional" do
    # The finding: `{:reverse, ...}` did not carry the debt and so could not
    # repay it, leaving `debt > 0` beside availability other lots held, which
    # LI-06a-5 forbids and which makes `{:hold, ...}` refuse a hold the legacy
    # ledger accepted.
    #
    # And the boundary the fix must not cross. `architecture-map.md` 7.2:
    # "promotional lots are never touched by a paid reversal". Repaying out of
    # `eligible/2` would take the promotional lot first, because that is what
    # spend order does, and erase exactly the credit G06 bullet 5 protects.
    spent = %{
      lot(:paid, 1, amount: 10 * @dollar, source: %{"payment_intent_id" => "pi_1"})
      | available: 0,
        consumed: 10 * @dollar
    }

    other = lot(:paid, 2, amount: 6 * @dollar)
    promo = lot(:promotional, 3, amount: 4 * @dollar)

    {:ok, plan} = Allocator.plan([spent, other, promo], {:reverse, "pi_1", 10 * @dollar, @now, 0})

    # Ten reversed off the funded lot, ten of debt created, six of it repaid
    # out of the OTHER PAID lot, and four left because nothing else may pay it.
    assert kind_total(plan, spent.id, :reverse) == 10 * @dollar
    assert plan.debt_delta == 4 * @dollar
    assert bucket(plan, other.id, :available) == 0
    assert bucket(plan, other.id, :consumed) == 6 * @dollar

    # The promotional lot is untouched, and no movement names it at all.
    assert bucket(plan, promo.id, :available) == 4 * @dollar
    refute Enum.any?(plan.movements, &(&1.lot_id == promo.id))

    # The negative control for the exclusion: with only a promotional lot
    # beside the debt, the debt stays rather than eating the promotion.
    {:ok, promo_only} = Allocator.plan([spent, promo], {:reverse, "pi_1", 10 * @dollar, @now, 0})
    assert promo_only.debt_delta == 10 * @dollar
    assert bucket(promo_only, promo.id, :available) == 4 * @dollar
  end

  test "X250 a wallet-wide reverse takes the non-promotional lots in spend order and never the promotion" do
    # **Repair unit R1.** `{:reverse, :wallet, ...}` is the same request as the
    # source-scoped one with the payment filter dropped, so the bucket order and
    # the promotional exclusion are the same code rather than a second model.
    #
    # Before R1 there was no such request: `Ledger.reverse/5` planned a reversal
    # as `{:debit, ...}`, which drains `eligible/2` and therefore takes the
    # PROMOTIONAL lot first. This test discriminates on that by construction:
    # the promotion sorts first in spend order and has the earliest expiry, so a
    # debit-planned reversal takes it before it reaches either paid lot.
    promo = lot(:promotional, 1, amount: 4 * @dollar, expires_at: @oct)

    funded = %{
      lot(:paid, 2, amount: 10 * @dollar, source: %{"payment_intent_id" => "pi_1"})
      | available: 5 * @dollar,
        consumed: 5 * @dollar
    }

    other = lot(:adjustment, 3, amount: 2 * @dollar)

    {:ok, plan} =
      Allocator.plan([promo, funded, other], {:reverse, :wallet, 8 * @dollar, @now, 0})

    # Six off the payment's own lot (five available, one already spent) and two
    # off the adjustment lot, which ranks with paid and comes next by `seq`.
    assert kind_total(plan, funded.id, :reverse) == 6 * @dollar
    assert kind_total(plan, other.id, :reverse) == 2 * @dollar
    assert bucket(plan, funded.id, :available) == 0
    assert bucket(plan, funded.id, :consumed) == 4 * @dollar
    assert bucket(plan, funded.id, :reversed) == 6 * @dollar
    assert bucket(plan, other.id, :reversed) == 2 * @dollar

    # Only the one micro-dollar that had already been spent becomes debt, and
    # nothing is left to repay it out of.
    assert plan.debt_delta == @dollar

    # **The assertion the balance cannot make.** The balance falls by 8 USD
    # whether the promotion paid for it or the paid lots did, so it is the lots
    # that have to be asserted, per lot.
    assert bucket(plan, promo.id, :available) == 4 * @dollar
    refute Enum.any?(plan.movements, &(&1.lot_id == promo.id))
  end

  test "X250 a wallet-wide reverse a promotional-only wallet cannot fund becomes debt, not a spend" do
    # The shape the exclusion costs something in, and the one `architecture-map`
    # 7.2 is really about: there is credit in the wallet, the refund may not
    # have it, so the wallet ends owing money beside a live promotion. That is
    # the case X277 says LI-06a-5 has to be weakened for, and R1 widens it from
    # the source-scoped path to the wallet-wide one.
    promo = lot(:promotional, 1, amount: 4 * @dollar)

    {:ok, plan} = Allocator.plan([promo], {:reverse, :wallet, 3 * @dollar, @now, 0})

    assert plan.movements == []
    assert plan.debt_delta == 3 * @dollar
    assert bucket(plan, promo.id, :available) == 4 * @dollar

    # The money still comes off the balance in full: a reversal is never refused
    # for want of balance, and `debt` is what a negative balance is made of.
    assert Allocator.projection(plan.book, plan.debt_delta).balance ==
             Allocator.projection([promo], 0).balance - 3 * @dollar
  end

  test "X250 a wallet-wide reverse reaches a paid lot the expiry sweep has not caught up with" do
    # `purchased/1` has no eligibility filter, unlike `eligible/2`, and the
    # reason is arithmetic rather than taste: a lot past its `expires_at` that
    # the sweep has not reached still contributes its `available` to `balance`.
    # Skipping it would make the reversal create debt for value still on the
    # books, and the sweep would then destroy that value too, leaving the tenant
    # owing credit it never had.
    stale = lot(:paid, 1, amount: 3 * @dollar, expires_at: ~U[2026-09-01 00:00:00Z])
    live = lot(:paid, 2, amount: 3 * @dollar)

    {:ok, plan} = Allocator.plan([stale, live], {:reverse, :wallet, 2 * @dollar, @now, 0})

    assert kind_total(plan, stale.id, :reverse) == 2 * @dollar
    assert kind_total(plan, live.id, :reverse) == 0
    assert plan.debt_delta == 0
  end

  test "X250 a wallet-wide reverse takes reserved value last and beyond the lots becomes debt" do
    held = held_lot(:paid, 1, amount: 5 * @dollar, reserved: 2 * @dollar, available: @dollar)

    # amount 5, available 1, consumed 2, reserved 2.
    {:ok, plan} = Allocator.plan([held], {:reverse, :wallet, 9 * @dollar, @now, 0})

    assert kind_total(plan, held.id, :reverse) == 5 * @dollar
    assert bucket(plan, held.id, :reversed) == 5 * @dollar
    assert bucket(plan, held.id, :reserved) == 0

    # Two of debt from the consumed bucket and four from what no lot could give
    # back at all.
    assert plan.debt_delta == 6 * @dollar
  end

  test "X355 a release does not repay debt out of a promotional lot" do
    # **Repair unit R2, and the event that defeated R1's fix.** A refund
    # exhausts the paid lots, correctly leaves `debt` rather than touching the
    # promotion, and then the next release repays that same debt. Until R2 the
    # release repaid out of `eligible/2`, which is spend order, which takes the
    # promotional lot FIRST: the promotion paid for the refund after all, one
    # ordinary event later.
    #
    # A release is the cleanest shape to assert this on, because a release has
    # no spend of its own: every `:consume` movement in a release plan is a
    # repayment and nothing else.
    promo = held_lot(:promotional, 1, amount: 4 * @dollar, reserved: 4 * @dollar, available: 0)

    {:ok, plan} =
      Allocator.plan([promo], {:release, [{promo.id, 4 * @dollar}], @now, 10 * @dollar})

    # The reservation comes back as availability, and the debt stands beside it.
    assert kind_total(plan, promo.id, :unreserve) == 4 * @dollar
    assert bucket(plan, promo.id, :available) == 4 * @dollar
    assert bucket(plan, promo.id, :consumed) == 0
    assert plan.debt_delta == 0

    # On the defect this was `consumed: 4_000_000`, `available: 0` and
    # `debt_delta: -4_000_000`, and every conservation check passed on it.
    refute Enum.any?(plan.movements, &(&1.kind == :consume))
  end

  test "X355 a release still repays debt out of a paid lot, which is what makes the exclusion a rule and not a switch" do
    # The positive control for the test above, and the reason it is here: a fix
    # that stopped repaying at all would pass the assertion above and break
    # LI-06a-5 everywhere. Same shape, one word changed.
    paid = held_lot(:paid, 1, amount: 4 * @dollar, reserved: 4 * @dollar, available: 0)

    {:ok, plan} =
      Allocator.plan([paid], {:release, [{paid.id, 4 * @dollar}], @now, 10 * @dollar})

    assert kind_total(plan, paid.id, :unreserve) == 4 * @dollar
    assert kind_total(plan, paid.id, :consume) == 4 * @dollar
    assert bucket(plan, paid.id, :available) == 0
    assert plan.debt_delta == -4 * @dollar
  end

  test "X355 a release repays what the paid lots can cover and leaves the rest of the debt beside the promotion" do
    # Both halves in one plan, which is the state a refunded wallet is actually
    # in: some paid availability, a live promotion, and a debt larger than the
    # paid side can clear.
    promo = held_lot(:promotional, 1, amount: 6 * @dollar, reserved: 6 * @dollar, available: 0)
    paid = held_lot(:paid, 2, amount: 2 * @dollar, reserved: 2 * @dollar, available: 0)

    {:ok, plan} =
      Allocator.plan(
        [promo, paid],
        {:release, [{promo.id, 6 * @dollar}, {paid.id, 2 * @dollar}], @now, 5 * @dollar}
      )

    # Two of the five repaid, out of the paid lot only, and three left standing.
    assert plan.debt_delta == -2 * @dollar
    assert bucket(plan, paid.id, :consumed) == 2 * @dollar
    assert bucket(plan, paid.id, :available) == 0
    assert bucket(plan, promo.id, :available) == 6 * @dollar
    assert bucket(plan, promo.id, :consumed) == 0

    # **The amended LI-06a-5, asserted rather than described**: `debt > 0` with
    # promotional availability beside it is now a legal book, and it is the
    # whole cost of the decision in section 0 of R2's evidence.
    assert Allocator.projection(plan.book, 5 * @dollar + plan.debt_delta).promotional ==
             6 * @dollar
  end

  test "X355 a settle below its reservation does not repay debt out of a promotional lot" do
    # The second caller of `repay_debt/5`. `actual` is at or below what the hold
    # reserved, so the settlement itself consumes only from `:reserved` and any
    # `:available -> :consumed` movement in this plan is a repayment.
    promo = held_lot(:promotional, 1, amount: 4 * @dollar, reserved: 4 * @dollar, available: 0)

    {:ok, plan} =
      Allocator.plan([promo], {:settle, [{promo.id, 4 * @dollar}], @dollar, @now, 10 * @dollar})

    assert kind_total(plan, promo.id, :consume) == @dollar
    assert kind_total(plan, promo.id, :unreserve) == 3 * @dollar
    assert bucket(plan, promo.id, :available) == 3 * @dollar
    assert plan.debt_delta == 0

    # The one consume is the settlement's own, out of `:reserved`. Nothing moved
    # out of `:available`, which is where a repayment would have taken it.
    assert [%{from: :reserved, to: :consumed}] =
             Enum.filter(plan.movements, &(&1.kind == :consume))
  end

  test "X355 a settle above its reservation still SPENDS promotional credit, which the exclusion does not forbid" do
    # **The boundary, and it is as important as the rule.** The exclusion is
    # about repaying a debt, not about spending. `architecture-map.md` 7.2 and
    # D07 put promotional credit first in spend order, and executed work is a
    # spend: a settlement above its hold consumes remaining eligible
    # availability, promotional included, exactly as a debit does. A later unit
    # reading only the rule could over-apply it and quietly make promotions
    # unspendable, which is why this is pinned.
    held = held_lot(:paid, 1, amount: 2 * @dollar, reserved: 2 * @dollar, available: 0)
    promo = lot(:promotional, 2, amount: 4 * @dollar)

    {:ok, plan} =
      Allocator.plan([held, promo], {:settle, [{held.id, 2 * @dollar}], 5 * @dollar, @now, 0})

    assert bucket(plan, held.id, :consumed) == 2 * @dollar
    assert bucket(plan, promo.id, :consumed) == 3 * @dollar
    assert bucket(plan, promo.id, :available) == @dollar
    assert plan.debt_delta == 0
  end

  test "X355 a grant repays outstanding debt out of its own lot even when the grant is promotional" do
    # The one repayment that may consume promotional value, and it is the
    # decision R2 wrote down rather than an omission. `architecture-map.md` 7.2
    # gives it its own sentence, 01e's independent model implements it the same
    # way, and it is the only door out of the state the exclusion creates: a
    # wallet holding a promotion beside a debt can neither hold nor debit.
    attrs = %{
      id: "promo-lot",
      tenant_key: "t",
      category: :promotional,
      amount: 3 * @dollar,
      reference: "welcome",
      expires_at: nil,
      granted_at: @now,
      seq: 9,
      source: %{}
    }

    existing = lot(:promotional, 1, amount: 5 * @dollar)

    {:ok, plan} = Allocator.plan([existing], {:grant, attrs, 2 * @dollar})

    assert plan.debt_delta == -2 * @dollar
    assert consumed(plan, "promo-lot") == 2 * @dollar
    assert bucket(plan, "promo-lot", :available) == @dollar

    # And it reaches its own lot only: the promotion the wallet already held is
    # untouched, which is the half `repay_debt/5` owns.
    assert bucket(plan, existing.id, :available) == 5 * @dollar
    refute Enum.any?(plan.movements, &(&1.lot_id == existing.id))
  end

  test "I10 restore is capped by the lot's reversed amount and repays debt first" do
    lot = %{
      lot(:paid, 1, amount: 10 * @dollar)
      | available: 4 * @dollar,
        reversed: 6 * @dollar,
        source: %{"payment_intent_id" => "pi_1"}
    }

    {:ok, plan} = Allocator.plan([lot], {:restore, "pi_1", 9 * @dollar, @now, 2 * @dollar})

    # Nine asked for, six there.
    assert kind_total(plan, lot.id, :restore) == 6 * @dollar
    assert plan.debt_delta == -2 * @dollar
    assert bucket(plan, lot.id, :reversed) == 0
    assert bucket(plan, lot.id, :available) == 8 * @dollar
    assert bucket(plan, lot.id, :consumed) == 2 * @dollar
  end

  # **`:reverse` and `:restore` are in the generated requests from 06e.** 06a
  # could not put them here honestly: nothing called them, the lots carried no
  # `source`, and a property over a request no caller can reach proves the
  # planner is self-consistent and nothing else. `Credits.reverse_lot/4` reaches
  # them now (finding X250), and the X262 repayment makes a reversal's plan
  # carry movements on lots the reversal itself never names, which is exactly
  # the shape a conservation property is for.
  #
  # `:reverse_wallet` joined them in repair unit R1, and it is the request the
  # `aurora_meter_pro` refund fallback reaches on any wallet whose payment
  # provenance the migration could not derive (finding X263). Its arm asserts
  # the promotional exclusion over the movements, because conservation, the
  # CHECK constraints and the balance all hold on the defect it replaced.
  property "I10 every planned movement conserves: each lot's five buckets still sum to its amount" do
    check all(
            book <- book_generator(),
            amount <- StreamData.integer(1..(20 * @dollar)),
            request <-
              StreamData.member_of([:debit, :hold, :reverse, :reverse_wallet, :restore])
          ) do
      tolerance = 0

      plan =
        case request do
          :debit -> Allocator.plan(book, {:debit, amount, @now, true, tolerance, 0})
          :hold -> Allocator.plan(book, {:hold, amount, @now, 0})
          :reverse -> Allocator.plan(book, {:reverse, "pi_1", amount, @now, 0})
          :reverse_wallet -> Allocator.plan(book, {:reverse, :wallet, amount, @now, 0})
          :restore -> Allocator.plan(book, {:restore, "pi_1", amount, @now, 0})
        end

      case plan do
        {:error, reason} when reason in [:insufficient_credits, :no_matching_lot] ->
          # **A wallet-wide reversal is never refused, and this arm is where
          # the control caught the property passing vacuously.** Run against
          # the pre-R1 allocator, `{:reverse, :wallet, ...}` matched the
          # source-scoped clause, `:wallet` matched no lot's `payment_intent_id`,
          # and every generated case left through here without reaching a single
          # assertion below: the property was green over a request that never
          # ran (findings X325 and X350, a detector that can match nothing
          # passes everything it cannot see). The refusal itself has to be the
          # assertion.
          refute request == :reverse_wallet,
                 "a wallet-wide reversal was refused with #{inspect(reason)}; it is never " <>
                   "refused for want of balance, so this request did not reach the planner"

        {:ok, plan} ->
          for lot <- plan.book do
            assert lot.available + lot.reserved + lot.consumed + lot.reversed + lot.expired ==
                     lot.amount,
                   "lot #{lot.id} does not conserve: #{inspect(lot)}"

            for quantity <- [:available, :reserved, :consumed, :reversed, :expired] do
              assert Map.fetch!(lot, quantity) >= 0,
                     "lot #{lot.id} has a negative #{quantity}: #{inspect(lot)}"
            end
          end

          # And the wallet's own law, which is what the database check compares
          # against after every write.
          before = Allocator.projection(book, 0)
          after_plan = Allocator.projection(plan.book, plan.debt_delta)

          moved = fn kind ->
            plan.movements
            |> Enum.filter(&(&1.kind == kind))
            |> Enum.map(& &1.amount)
            |> Enum.sum()
          end

          case request do
            :debit ->
              assert after_plan.balance == before.balance - amount

            :hold ->
              assert after_plan.balance == before.balance

            # A reversal is capped by what its own lots hold, so the balance
            # falls by what it actually reversed and not by what was asked for.
            # The repayment X262 added is balance neutral by construction
            # (`available` to `consumed` while debt falls by the same), which is
            # what this arm asserts as well as the cap.
            :reverse ->
              assert after_plan.balance == before.balance - moved.(:reverse)

            # The wallet-wide reversal has no cap: what no lot could give back
            # is debt, so the balance falls by the full amount every time. That
            # is `reverse/5`'s contract, and it is **not** the assertion that
            # discriminates X250: a reversal planned as a debit also dropped the
            # balance by the full amount. The promotional arm below is.
            :reverse_wallet ->
              assert after_plan.balance == before.balance - amount

            :restore ->
              assert after_plan.balance == before.balance + moved.(:restore)
          end

          # **What a reversal may never do, on either scope** (X250, repair unit
          # R1): `architecture-map.md` 7.2, "promotional lots are never touched
          # by a paid reversal". Asserted over the movements rather than over the
          # projection, because the projection cannot tell which lot paid.
          if request in [:reverse, :reverse_wallet] do
            promotional =
              for lot <- book, lot.category == :promotional, into: MapSet.new(), do: lot.id

            for move <- plan.movements do
              refute MapSet.member?(promotional, move.lot_id),
                     "a #{request} moved #{move.amount} #{move.from} -> #{move.to} on a " <>
                       "promotional lot (#{move.lot_id})"
            end
          end
      end
    end
  end

  # **Repair unit R2, finding X355.** The deterministic tests above pin the
  # shapes a reader can hold in their head; this asks the same question over
  # arbitrary books and arbitrary outstanding debts, and it asserts the
  # repayment from **both** sides, which is what makes it more than a `refute`
  # that could be vacuous:
  #
  #   * no repayment movement may name a promotional lot (the rule); and
  #   * the repayment must equal `min(debt, what the non-promotional eligible
  #     lots could give)` (that the rule was not implemented by repaying less,
  #     or nothing at all).
  #
  # The second is computed from the FINAL book plus the repayment's own
  # movements rather than from the planner's internals, so it is an independent
  # arithmetic rather than a restatement of the code under test.
  #
  # **Neither request can be refused**, so unlike the property above there is no
  # error arm at all: a generated case cannot leave without reaching every
  # assertion. That is X325 and X350's shape closed by construction rather than
  # by a `refute` in the error arm. The counters below are the other half of the
  # same question, and they are asserted after the run: a property whose books
  # never held a promotion beside a debt would be green and would have measured
  # nothing.
  property "X355 a debt repayment never names a promotional lot, and takes everything the non-promotional lots can give" do
    Process.put({__MODULE__, :repaid_cases}, 0)
    Process.put({__MODULE__, :discriminating_cases}, 0)

    check all(
            book <- book_generator(),
            debt <- StreamData.integer(1..(20 * @dollar)),
            request <- StreamData.member_of([:release, :settle])
          ) do
      reservations = for lot <- book, lot.reserved > 0, do: {lot.id, lot.reserved}
      reserved_total = Enum.reduce(reservations, 0, fn {_id, amount}, acc -> acc + amount end)

      # `actual` at or below what the hold reserved, so the settlement consumes
      # only out of `:reserved` and every `:available -> :consumed` movement in
      # either plan is a repayment and nothing else.
      tuple =
        case request do
          :release -> {:release, reservations, @now, debt}
          :settle -> {:settle, reservations, div(reserved_total, 2), @now, debt}
        end

      assert {:ok, plan} = Allocator.plan(book, tuple)

      for lot <- plan.book do
        assert lot.available + lot.reserved + lot.consumed + lot.reversed + lot.expired ==
                 lot.amount,
               "lot #{lot.id} does not conserve: #{inspect(lot)}"

        for quantity <- [:available, :reserved, :consumed, :reversed, :expired] do
          assert Map.fetch!(lot, quantity) >= 0,
                 "lot #{lot.id} has a negative #{quantity}: #{inspect(lot)}"
        end
      end

      repayments = Enum.filter(plan.movements, &(&1.from == :available and &1.to == :consumed))
      repaid = repayments |> Enum.map(& &1.amount) |> Enum.sum()

      promotional = for lot <- book, lot.category == :promotional, into: MapSet.new(), do: lot.id

      for move <- repayments do
        refute MapSet.member?(promotional, move.lot_id),
               "a #{request} repaid #{move.amount} of debt out of promotional lot " <>
                 "#{move.lot_id}, which `repay_debt/5` may never do"
      end

      # What the repayment could have taken: every non-promotional lot the
      # expiry sweep has not passed, at the availability it held just before the
      # repayment, which is its final availability plus whatever was repaid out
      # of it.
      taken_from =
        Enum.reduce(
          repayments,
          %{},
          &Map.update(&2, &1.lot_id, &1.amount, fn a -> a + &1.amount end)
        )

      purchasable =
        plan.book
        |> Enum.filter(&(&1.category != :promotional and not expired_by?(&1, @now)))
        |> Enum.reduce(0, &(&1.available + Map.get(taken_from, &1.id, 0) + &2))

      assert repaid == min(debt, purchasable),
             "repaid #{repaid} of #{debt} with #{purchasable} non-promotional availability " <>
               "to take it from"

      assert plan.debt_delta == -repaid

      if repaid > 0, do: bump({__MODULE__, :repaid_cases})

      # The cases that can tell the fix from the defect: a debt still standing
      # after the repayment, with promotional availability the defect would have
      # taken it out of.
      promotional_left =
        plan.book
        |> Enum.filter(&(&1.category == :promotional and not expired_by?(&1, @now)))
        |> Enum.reduce(0, &(&1.available + &2))

      if debt - repaid > 0 and promotional_left > 0, do: bump({__MODULE__, :discriminating_cases})
    end

    # **Asserted, not printed** (findings X125, X214, X287). A property that
    # never generated the shape it is about is green and proves nothing, and the
    # two counters say which shape was reached: the first that a repayment
    # happened at all, the second that the defect and the fix would have
    # disagreed about it.
    assert Process.get({__MODULE__, :repaid_cases}, 0) > 0,
           "no generated case repaid any debt, so the equality above compared nothing"

    assert Process.get({__MODULE__, :discriminating_cases}, 0) > 0,
           "no generated case left a debt standing beside promotional availability, which is " <>
             "the only shape in which this property can tell X355's fix from the defect"
  end

  # **The planner's own statement of the figure every host reads**, at the
  # layer that decides it rather than at the layer that formats it (findings
  # X357 and X361). `Allocator.spendable/3` is what `Ledger.figures/1`,
  # `Ledger.spendable/1` and therefore `Credits.balance/1`, `Credits.summary/1`
  # and `Credits.sufficient?/2` all report, so the law asserted here is the law
  # a dashboard shows.
  #
  # **It is written as an attempt rather than as an arithmetic.** The property
  # reads the figure and then asks the planner for exactly that amount, and for
  # one micro-dollar more. A test that compared `spendable/3` against a formula
  # would pass on any future change that broke the formula and the planner in
  # the same way; this one cannot, because the two sides of it are the figure
  # and the decision.
  #
  # **Neither arm can be skipped**, which is X325 and X350's shape closed by
  # construction: `spendable > 0` and `spendable <= 0` exhaust the cases, and
  # each arm ends in an assertion. The counters below say which shapes the
  # generated books reached, because the shape this unit exists for (a debt
  # standing beside more availability than the debt) is the only one in which
  # the pre-R3 figure and the planner disagreed.
  property "X361 spendable/3 reports exactly what the planner will accept, and names the debt when it will accept nothing" do
    for key <- [:spendable_cases, :frozen_cases, :empty_cases, :discriminating_cases] do
      Process.put({__MODULE__, key}, 0)
    end

    check all(
            generated <- book_generator(),
            # **The shape is generated, not hoped for.** A first version drew
            # the debt as a uniform integer over twenty million micro-dollars
            # and let the book fall where it fell. It passed at five of ten
            # seeds and failed at the other five on its own counters: at seed
            # 42 no case reached a wallet with nothing eligible and no debt,
            # and at seeds 1337 and 13 none reached the one shape this unit
            # exists for, a debt standing beside MORE eligible availability
            # than the debt. A property that measures its subject at half the
            # seeds is X325 and X350's failure with a coin toss on top, so the
            # mode now names the shape and `shape/2` and `debt_for/4` make the
            # case actually be it.
            mode <-
              StreamData.member_of([:spendable, :frozen_under, :frozen_over, :empty]),
            share <- StreamData.integer(1..99),
            extra <- StreamData.integer(1..(5 * @dollar)),
            request <- StreamData.member_of([:hold, :debit])
          ) do
      book = shape(generated, mode)
      eligible_available = eligible_available(book, @now)
      debt = debt_for(mode, eligible_available, share, extra)
      spendable = Allocator.spendable(book, debt, @now)

      if spendable > 0 do
        # A wallet that may spend owes nothing. The planner refuses outright
        # while `debt > 0`, so a positive figure beside a debt is exactly the
        # state R3 closes and it must be unreachable.
        assert debt == 0, "spendable #{spendable} is positive beside a debt of #{debt}"

        assert {:ok, _plan} = Allocator.plan(book, ask(request, spendable, debt))

        assert {:error, :insufficient_credits} =
                 Allocator.plan(book, ask(request, spendable + 1, debt))

        bump({__MODULE__, :spendable_cases})
      else
        assert {:error, reason} = Allocator.plan(book, ask(request, 1, debt))

        expected = if debt > 0, do: :debt_outstanding, else: :insufficient_credits

        assert reason == expected,
               "a #{request} on a book with debt #{debt} was refused with " <>
                 "#{inspect(reason)} and should have been refused with #{inspect(expected)}"

        if debt > 0 do
          bump({__MODULE__, :frozen_cases})

          # The shape the pre-R3 figure got wrong: more eligible availability
          # than the debt, so `available - debt` was POSITIVE while the planner
          # accepted nothing at all.
          if eligible_available > debt, do: bump({__MODULE__, :discriminating_cases})
        else
          bump({__MODULE__, :empty_cases})
        end
      end
    end

    for {key, shape} <- [
          {:spendable_cases, "a wallet with something to spend"},
          {:frozen_cases, "a wallet frozen by a debt"},
          {:empty_cases, "a wallet with nothing eligible and no debt"},
          {:discriminating_cases,
           "a debt standing beside MORE eligible availability than the debt, which is the " <>
             "only shape in which the pre-R3 figure and the planner disagreed"}
        ] do
      assert Process.get({__MODULE__, key}, 0) > 0, "no generated case reached #{shape}"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp ask(:hold, amount, debt), do: {:hold, amount, @now, debt}
  defp ask(:debit, amount, debt), do: {:debit, amount, @now, false, 0, debt}

  # `:empty` moves every lot's availability into `consumed`, which conserves and
  # leaves nothing eligible to spend. The other three need something to spend,
  # so a book the generator left with less than two micro-dollars of eligible
  # availability gains one lot that has some; without it the mode would be a
  # label rather than a shape.
  defp shape(book, :empty),
    do: Enum.map(book, &%{&1 | consumed: &1.consumed + &1.available, available: 0})

  defp shape(book, _mode) do
    if eligible_available(book, @now) >= 2,
      do: book,
      else: book ++ [lot(:paid, length(book) + 1, amount: 4 * @dollar)]
  end

  defp eligible_available(book, now) do
    book
    |> Enum.reject(&expired_by?(&1, now))
    |> Enum.reduce(0, &(&1.available + &2))
  end

  # `:frozen_under` is the shape the pre-R3 figure got wrong: strictly positive
  # debt, strictly less than what is eligible, so `available - debt` was
  # positive while the planner accepted nothing.
  defp debt_for(mode, _available, _share, _extra) when mode in [:spendable, :empty], do: 0

  defp debt_for(:frozen_under, available, share, _extra),
    do: available |> Kernel.*(share) |> div(100) |> max(1) |> min(available - 1)

  defp debt_for(:frozen_over, available, _share, extra), do: available + extra

  defp bump(key), do: Process.put(key, Process.get(key, 0) + 1)

  defp expired_by?(%{expires_at: nil}, _now), do: false
  defp expired_by?(%{expires_at: at}, now), do: DateTime.compare(at, now) != :gt

  defp lot(category, seq, opts) do
    amount = Keyword.get(opts, :amount, @dollar)

    %{
      id: "lot-#{seq}",
      category: category,
      amount: amount,
      available: Keyword.get(opts, :available, amount),
      reserved: 0,
      consumed: 0,
      reversed: 0,
      expired: 0,
      expires_at: Keyword.get(opts, :expires_at),
      granted_at: Keyword.get(opts, :granted_at, ~U[2026-01-01 00:00:00Z]),
      seq: seq,
      source: Keyword.get(opts, :source, %{})
    }
  end

  defp held_lot(category, seq, opts) do
    amount = Keyword.fetch!(opts, :amount)
    reserved = Keyword.fetch!(opts, :reserved)
    available = Keyword.get(opts, :available, amount - reserved)

    %{
      lot(category, seq, Keyword.put(opts, :available, available))
      | reserved: reserved,
        consumed: amount - available - reserved
    }
  end

  defp order(book) do
    book
    |> Enum.sort_by(&Allocator.spend_key/1)
    |> Enum.map(& &1.seq)
  end

  defp consumed(plan, lot_id), do: kind_total(plan, lot_id, :consume)

  defp kind_total(plan, lot_id, kind) do
    plan.movements
    |> Enum.filter(&(&1.lot_id == lot_id and &1.kind == kind))
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  defp bucket(plan, lot_id, quantity) do
    plan.book |> Enum.find(&(&1.id == lot_id)) |> Map.fetch!(quantity)
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for item <- list, rest <- permutations(list -- [item]), do: [item | rest]
  end

  # **The generated lots carry history and provenance from 06e.** Before, every
  # generated lot was wholly `available` and carried no `source`, so a `:reverse`
  # would have found no lot and a `:restore` nothing to give back: the property
  # would have been green over two requests that never moved anything (the shape
  # X211 and X155 are about). The percentages put value into `consumed` and
  # `reversed`, and half the purchased lots carry the payment the generated
  # requests name, so a reversal has something to find and something to miss.
  #
  # **The third percentage is repair unit R2's, and it closed a hole the same
  # size as the ones above.** Until it, every generated lot had `reserved: 0`:
  # the `:reserved` bucket a reversal takes LAST was never reached by a single
  # generated case, and no settle or release could be generated at all, because
  # both are driven by a hold's reservations. The buckets a property cannot
  # reach are the ones it says nothing about.
  defp book_generator do
    StreamData.list_of(
      StreamData.tuple({
        StreamData.member_of([:paid, :promotional, :adjustment]),
        StreamData.integer(1..(5 * @dollar)),
        StreamData.member_of([nil, @oct, @nov, ~U[2026-09-01 00:00:00Z]]),
        StreamData.integer(0..100),
        StreamData.integer(0..100),
        StreamData.integer(0..100)
      }),
      min_length: 1,
      max_length: 6
    )
    |> StreamData.map(fn specs ->
      specs
      |> Enum.with_index(1)
      |> Enum.map(fn {{category, amount, expires_at, spent, given_back, held}, index} ->
        consumed = div(amount * spent, 100)
        reversed = div((amount - consumed) * given_back, 100)
        rest = amount - consumed - reversed
        reserved = div(rest * held, 100)

        %{
          lot(category, index,
            amount: amount,
            expires_at: expires_at,
            source: source_for(category, index)
          )
          | available: rest - reserved,
            reserved: reserved,
            consumed: consumed,
            reversed: reversed
        }
      end)
    end)
  end

  defp source_for(:promotional, _index), do: %{}
  defp source_for(_category, index) when rem(index, 2) == 1, do: %{"payment_intent_id" => "pi_1"}
  defp source_for(_category, index), do: %{"payment_intent_id" => "pi_#{index}"}
end
