defmodule AuroraMeter.CreditsLotsApiTest do
  @moduledoc """
  The public lot read API (build unit 06c, V1 task 06.03).

  `AuroraMeter.Credits.Lots` is how a human answers "where did the money go"
  without reading `aurora_meter_credit_transactions` by hand, and it is the only
  route `free-pro-boundary.md` section 2 gives Pro to lot data. Every test here
  reads through the public functions and never through the schemas, so the
  question it answers is "can this be answered from the API" rather than "is the
  data in the database".
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Lots

  @dollar 1_000_000
  @oct ~U[2026-10-01 00:00:00Z]
  @nov ~U[2026-11-01 00:00:00Z]

  test "I10 Lots.list returns lots in the documented spend order" do
    tenant = lot_wallet()

    # Deliberately granted in an order that is not the spend order, so the list
    # is a statement about the ordering rather than about insertion.
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "paid-old")

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo-nov",
        category: :promotional,
        expires_at: @nov
      )

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "promo-oct",
        category: :promotional,
        expires_at: @oct
      )

    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "promo-none", category: :promotional)
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "paid-new")

    assert Enum.map(Lots.list(tenant), & &1.reference) ==
             ["promo-oct", "promo-nov", "promo-none", "paid-old", "paid-new"]

    # And it is the order the next debit actually takes, which is the claim the
    # moduledoc makes and the reason a caller may not override it. Without this
    # the list could be sorted by anything and the test would still pass.
    {:ok, _} = Credits.debit(tenant, 3 * @dollar + 1, "spend")

    assert Lots.get(tenant, "promo-oct").available == 0
    assert Lots.get(tenant, "promo-nov").available == 4 * @dollar - 1
    assert Lots.get(tenant, "promo-none").available == 2 * @dollar

    # `order: :granted_at` re-sorts the same lots for a human reading a history
    # and changes nothing about what a debit takes. `states: :all` because the
    # debit above has exhausted one of them and the default hides it.
    assert Enum.map(Lots.list(tenant, states: :all, order: :granted_at), & &1.reference) ==
             ["paid-old", "promo-nov", "promo-oct", "promo-none", "paid-new"]
  end

  test "I10 Lots.list with states: :all includes exhausted, expired and reversed lots" do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, @dollar, reference: "spent", source: %{payment_intent_id: "pi_spent"})

    {:ok, _} = Credits.grant(tenant, @dollar, reference: "kept")
    {:ok, _} = Credits.debit(tenant, @dollar, "drain")

    assert Enum.map(Lots.list(tenant), & &1.reference) == ["kept"]

    all = Lots.list(tenant, states: :all)
    assert Enum.sort(Enum.map(all, & &1.reference)) == ["kept", "spent"]
    assert Enum.find(all, &(&1.reference == "spent")).state == :exhausted

    assert Enum.map(Lots.list(tenant, states: [:exhausted]), & &1.reference) == ["spent"]
    assert Lots.list(tenant, categories: [:promotional]) == []
    assert Enum.map(Lots.list(tenant, categories: [:paid]), & &1.reference) == ["kept"]
  end

  test "I10 Lots.get accepts a lot id and a grant reference" do
    tenant = lot_wallet()
    {:ok, txn} = Credits.grant(tenant, 2 * @dollar, reference: "stripe:pi_123")

    by_reference = Lots.get(tenant, "stripe:pi_123")
    assert by_reference.amount == 2 * @dollar
    assert by_reference.grant_transaction_id == txn.id

    assert Lots.get(tenant, by_reference.id) == by_reference
    assert Lots.get(tenant, "no-such-reference") == nil
    assert Lots.get(tenant, Ecto.UUID.generate()) == nil

    # Another tenant's lot is not this tenant's, whichever handle is used.
    other = lot_wallet()
    assert Lots.get(other, "stripe:pi_123") == nil
    assert Lots.get(other, by_reference.id) == nil
  end

  test "I10 Lots.allocations reconstructs a settlement: consume then unreserve on the same lot" do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "pay")
    {:ok, hold} = Credits.hold(tenant, 4 * @dollar, "job:1")
    {:ok, settle} = Credits.settle("job:1", 1 * @dollar)

    lot = Lots.get(tenant, "pay")
    trail = Lots.allocations(tenant, lot_id: lot.id)

    assert Enum.map(trail, &{&1.kind, &1.from_bucket, &1.to_bucket, &1.amount}) == [
             {:reserve, :available, :reserved, 4 * @dollar},
             {:consume, :reserved, :consumed, 1 * @dollar},
             {:unreserve, :reserved, :available, 3 * @dollar}
           ]

    # Every movement names the ledger row that caused it, which is what makes
    # the trail an audit rather than a log.
    assert Enum.map(trail, & &1.transaction_id) == [hold.id, settle.id, settle.id]

    assert Enum.map(Lots.allocations(tenant, transaction_id: settle.id), & &1.kind) ==
             [:consume, :unreserve]

    assert Enum.map(Lots.allocations(tenant, reference: "job:1"), & &1.kind) ==
             [:reserve, :consume, :unreserve]

    # And the five quantities fall out of the fold, which is the point of
    # `from_bucket`/`to_bucket` (finding X249).
    assert lot_after(tenant, "pay") == %{
             available: 9 * @dollar,
             reserved: 0,
             consumed: 1 * @dollar,
             reversed: 0,
             expired: 0
           }
  end

  test "I10 Lots.for_source returns exactly the lots funded by one payment intent" do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "stripe:ch_a",
        source: %{payment_intent_id: "pi_wanted"}
      )

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "stripe:ch_b",
        source: %{payment_intent_id: "pi_wanted"}
      )

    {:ok, _} =
      Credits.grant(tenant, 7 * @dollar,
        reference: "stripe:ch_other",
        source: %{payment_intent_id: "pi_other"}
      )

    {:ok, _} =
      Credits.grant(tenant, 2 * @dollar,
        reference: "welcome",
        category: :promotional,
        source: %{promotion: "welcome"}
      )

    {:ok, _} = Credits.grant(tenant, @dollar, reference: "no-source")

    assert Enum.map(Lots.for_source(tenant, %{payment_intent_id: "pi_wanted"}), & &1.reference) ==
             ["stripe:ch_a", "stripe:ch_b"]

    assert Enum.map(Lots.for_source(tenant, %{payment_intent_id: "pi_other"}), & &1.reference) ==
             ["stripe:ch_other"]

    assert Lots.for_source(tenant, %{payment_intent_id: "pi_absent"}) == []

    # A promotional lot is not reachable from a payment, which is the property
    # a paid refund rests on: it must not find promotional credit.
    refute Enum.any?(
             Lots.for_source(tenant, %{payment_intent_id: "pi_wanted"}),
             &(&1.category == :promotional)
           )

    assert Enum.map(Lots.for_source(tenant, %{recurrence_key: "none"}), & &1.reference) == []
  end

  test "I10 Lots.for_source with an unsupported key raises" do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay", source: %{promotion: "welcome"})

    # **A key the matcher does not understand must not match everything.** The
    # caller here is a refund path, and "return every lot" is not a near miss.
    assert_raise ArgumentError, ~r/payment_intent_id/, fn ->
      Lots.for_source(tenant, %{promotion: "welcome"})
    end

    assert_raise ArgumentError, ~r/payment_intent_id/, fn ->
      Lots.for_source(tenant, %{"not_a_real_key_at_all" => "x"})
    end

    assert_raise ArgumentError, fn -> Lots.for_source(tenant, %{}) end
    assert_raise ArgumentError, fn -> Lots.for_source(tenant, %{payment_intent_id: 7}) end
  end

  test "I10 Lots.list paginates by cursor without skipping or repeating a lot" do
    tenant = lot_wallet()

    references = for i <- 1..25, do: "pay-#{String.pad_leading(to_string(i), 2, "0")}"

    for reference <- references do
      {:ok, _} = Credits.grant(tenant, @dollar, reference: reference)
    end

    walked = walk(tenant, nil, [])

    assert length(walked) == 25
    assert length(Enum.uniq(walked)) == 25
    assert walked == Enum.map(Lots.list(tenant, limit: 500), & &1.reference)

    # The same walk in the other order, because the two have different keysets
    # and only one of them is the composite one.
    assert length(Enum.uniq(walk(tenant, nil, [], order: :granted_at))) == 25
  end

  test "I10 a wallet that has not been cut over has no lots to read" do
    # The honest answer rather than a synthesised one: the legacy ledger does
    # not record which grant a spend came out of, so a lot list invented from it
    # would be a guess presented as provenance.
    tenant = unique_tenant("lotsapi")
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: "pay")

    assert Lots.list(tenant) == []
    assert Lots.list(tenant, states: :all) == []
    assert Lots.get(tenant, "pay") == nil
    assert Lots.allocations(tenant) == []
    assert Lots.for_source(tenant, %{payment_intent_id: "pi_1"}) == []
  end

  test "I10 Lots refuses an option it does not understand rather than ignoring it" do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, @dollar, reference: "pay")

    assert_raise ArgumentError, ~r/:states/, fn -> Lots.list(tenant, states: [:nonsense]) end
    assert_raise ArgumentError, ~r/:categories/, fn -> Lots.list(tenant, categories: [:x]) end
    assert_raise ArgumentError, ~r/:order/, fn -> Lots.list(tenant, order: :whatever) end
    assert_raise ArgumentError, ~r/:limit/, fn -> Lots.list(tenant, limit: 0) end
    assert_raise ArgumentError, ~r/:cursor/, fn -> Lots.list(tenant, cursor: 42) end

    # The cap is applied rather than the caller's number, so one call cannot ask
    # for the whole installation's lots.
    assert length(Lots.list(tenant, limit: 100_000)) == 1
  end

  # -- helpers ----------------------------------------------------------------

  defp walk(tenant, cursor, acc, opts \\ []) do
    page = Lots.list(tenant, Keyword.merge([limit: 7, cursor: cursor], opts))

    case page do
      [] ->
        Enum.reverse(acc)

      _ ->
        walk(tenant, List.last(page), Enum.reverse(Enum.map(page, & &1.reference)) ++ acc, opts)
    end
  end

  defp lot_after(tenant, reference) do
    lot = Lots.get(tenant, reference)
    Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired])
  end

  defp lot_wallet do
    tenant = unique_tenant("lotsapi")
    Ledger.enable_lots!(tenant)
    tenant
  end
end
