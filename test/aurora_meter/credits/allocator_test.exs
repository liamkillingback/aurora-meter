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
  property "I10 every planned movement conserves: each lot's five buckets still sum to its amount" do
    check all(
            book <- book_generator(),
            amount <- StreamData.integer(1..(20 * @dollar)),
            request <- StreamData.member_of([:debit, :hold, :reverse, :restore])
          ) do
      tolerance = 0

      plan =
        case request do
          :debit -> Allocator.plan(book, {:debit, amount, @now, true, tolerance, 0})
          :hold -> Allocator.plan(book, {:hold, amount, @now, 0})
          :reverse -> Allocator.plan(book, {:reverse, "pi_1", amount, @now, 0})
          :restore -> Allocator.plan(book, {:restore, "pi_1", amount, @now, 0})
        end

      case plan do
        {:error, reason} when reason in [:insufficient_credits, :no_matching_lot] ->
          :ok

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

            :restore ->
              assert after_plan.balance == before.balance + moved.(:restore)
          end
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

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
  # X211 and X155 are about). The two percentages put value into `consumed` and
  # `reversed`, and half the purchased lots carry the payment the generated
  # requests name, so a reversal has something to find and something to miss.
  defp book_generator do
    StreamData.list_of(
      StreamData.tuple({
        StreamData.member_of([:paid, :promotional, :adjustment]),
        StreamData.integer(1..(5 * @dollar)),
        StreamData.member_of([nil, @oct, @nov, ~U[2026-09-01 00:00:00Z]]),
        StreamData.integer(0..100),
        StreamData.integer(0..100)
      }),
      min_length: 1,
      max_length: 6
    )
    |> StreamData.map(fn specs ->
      specs
      |> Enum.with_index(1)
      |> Enum.map(fn {{category, amount, expires_at, spent, given_back}, index} ->
        consumed = div(amount * spent, 100)
        reversed = div((amount - consumed) * given_back, 100)

        %{
          lot(category, index,
            amount: amount,
            expires_at: expires_at,
            source: source_for(category, index)
          )
          | available: amount - consumed - reversed,
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
