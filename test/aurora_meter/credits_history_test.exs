defmodule AuroraMeter.CreditsHistoryTest do
  @moduledoc """
  `history/2`'s keyset cursor and the kinds it shows by default (build unit 06c,
  finding L8).

  The cursor exists because `:before` compares `inserted_at`, a wall-clock stamp
  that orders nothing, while the list is ordered by the ledger's own identity
  column. Two entries written in the same microsecond therefore have no order
  under `:before`, and a page boundary that lands between them skips one and
  repeats another.
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditTransaction

  @dollar 1_000_000

  test "I10 history paginates by cursor across rows sharing one microsecond" do
    tenant = unique_tenant("history")

    {:ok, _} = Credits.grant(tenant, 400 * @dollar, reference: "seed")

    for i <- 1..199 do
      {:ok, _} = Credits.debit(tenant, 1000, "d-#{i}")
    end

    # **Ten rows forced onto one microsecond**, which is the condition L8 is
    # about and which a wall clock produces on its own often enough to matter.
    # `seq` is untouched: the rows keep their true commit order and only the
    # timestamp collides.
    pinned = ~U[2026-09-15 12:00:00.000000Z]

    collided =
      TestRepo.all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant,
          order_by: [asc: t.seq],
          limit: 10,
          select: t.id
        )
      )

    {10, _} =
      TestRepo.update_all(
        from(t in CreditTransaction, where: t.id in ^collided),
        set: [inserted_at: pinned]
      )

    assert TestRepo.aggregate(
             from(t in CreditTransaction,
               where: t.tenant_key == ^tenant and t.inserted_at == ^pinned
             ),
             :count,
             :id
           ) == 10

    walked = walk(tenant, nil, [])

    assert length(walked) == 200, "the cursor walk returned #{length(walked)} of 200 rows"
    assert length(Enum.uniq(walked)) == 200, "the cursor walk returned a row twice"

    # The same 200 rows one page would have returned, in the same order.
    assert walked == Enum.map(Credits.history(tenant, limit: 500), & &1.id)
  end

  test "I10 history with :before is documented as lossy and still works" do
    # `:before` is kept because "what happened before lunchtime" is a filter and
    # is exactly what it is good at. This test asserts that it still filters,
    # and it asserts the loss rather than pretending it is not there.
    tenant = unique_tenant("history")
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
    for i <- 1..5, do: {:ok, _} = Credits.debit(tenant, 1000, "d-#{i}")

    pinned = ~U[2026-09-15 12:00:00.000000Z]

    ids =
      TestRepo.all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:debit,
          order_by: [asc: t.seq],
          select: t.id
        )
      )

    {5, _} =
      TestRepo.update_all(
        from(t in CreditTransaction, where: t.id in ^ids),
        set: [inserted_at: pinned]
      )

    # A page of two, then "everything before the last one I saw". All five share
    # the instant, so the filter cannot express "after the second of them" and
    # three rows are lost.
    page = Credits.history(tenant, kinds: [:debit], limit: 2)
    assert length(page) == 2

    next =
      Credits.history(tenant, kinds: [:debit], limit: 10, before: List.last(page).inserted_at)

    assert next == [], "the :before filter is no longer lossy; update its documentation"

    # The cursor form does not lose them.
    cursor_next =
      Credits.history(tenant, kinds: [:debit], limit: 10, cursor: Credits.cursor(List.last(page)))

    assert length(cursor_next) == 3
  end

  test "I10 history includes reversals by default" do
    # The compatibility promise of the new kind: a reversal was a `:debit` and
    # appeared in the default view, and it still appears now that it has a kind
    # of its own. A default that had not been updated would silently drop every
    # refund from the list a host renders.
    tenant = unique_tenant("history")
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "seed")
    {:ok, _} = Credits.debit(tenant, @dollar, "spend")
    {:ok, reversal} = Credits.reverse(tenant, 2 * @dollar, "refund:1")

    assert reversal.kind == :reverse
    assert reversal.category == :reversal
    assert CreditTransaction.reversal?(reversal)

    kinds = tenant |> Credits.history() |> Enum.map(& &1.kind)
    assert :reverse in kinds
    assert kinds == [:reverse, :debit, :grant]

    # And a legacy-shaped reversal, which is what any wallet written before
    # schema version 9 holds, is still in the default view.
    {1, _} =
      TestRepo.update_all(
        from(t in CreditTransaction, where: t.id == ^reversal.id),
        set: [kind: :debit]
      )

    legacy = Credits.history(tenant)
    assert length(legacy) == 3
    assert Enum.count(legacy, &CreditTransaction.reversal?/1) == 1
  end

  test "I10 history rejects :before together with :cursor" do
    tenant = unique_tenant("history")
    {:ok, txn} = Credits.grant(tenant, @dollar, reference: "seed")

    assert_raise ArgumentError, ~r/:before or :cursor, not both/, fn ->
      Credits.history(tenant, before: DateTime.utc_now(), cursor: Credits.cursor(txn))
    end

    assert_raise ArgumentError, ~r/cursor\/1/, fn ->
      Credits.history(tenant, cursor: "not-a-cursor")
    end
  end

  defp walk(tenant, cursor, acc) do
    opts = if cursor, do: [limit: 17, cursor: cursor], else: [limit: 17]

    case Credits.history(tenant, opts) do
      [] ->
        Enum.reverse(acc)

      page ->
        walk(
          tenant,
          Credits.cursor(List.last(page)),
          Enum.reverse(Enum.map(page, & &1.id)) ++ acc
        )
    end
  end
end
