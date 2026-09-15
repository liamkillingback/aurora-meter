defmodule AuroraMeter.CreditsFiguresTest do
  @moduledoc """
  The four money figures `balance/1` and `summary/1` gained in build unit 06c
  (V1 task 06.07), and the compatibility of the six that were already there.

  The point of the unit is that after credit lots `balance - held` is no longer
  the whole story: value can be reserved, destroyed by expiry, or owed, and a
  reader that sees one signed integer has to guess which. Each test below
  therefore pins one figure to a state the others cannot produce.
  """
  use AuroraMeter.DataCase, async: false
  use ExUnitProperties

  alias AuroraMeter.Clock
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Schema.CreditTransaction

  @dollar 1_000_000
  @past ~U[2020-01-01 00:00:00Z]

  test "I11 summary reports spendable, held, expired, debt and promotional_spendable independently" do
    tenant = lot_wallet()

    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "paid")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "job:1")

    summary = Credits.summary(tenant)

    assert summary.balance == 14 * @dollar
    assert summary.held == 3 * @dollar
    assert summary.available == 11 * @dollar
    assert summary.spendable == 11 * @dollar
    assert summary.promotional == 4 * @dollar
    # The hold reserved promotional credit first, which is the spend order, so
    # one of the two promotional figures moved and the other did not.
    assert summary.promotional_spendable == @dollar
    assert summary.debt == 0
    assert summary.expired == 0

    # And `balance/1` says the same thing, because `summary/1` is built from it.
    snapshot = Credits.balance(tenant)

    assert Map.take(snapshot, [:spendable, :promotional_spendable, :debt, :expired]) ==
             Map.take(summary, [:spendable, :promotional_spendable, :debt, :expired])
  end

  test "I12 expired value appears in expired and never in spendable" do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "stale",
        category: :promotional,
        expires_at: @past
      )

    {:ok, _} = Credits.grant(tenant, @dollar, reference: "good")

    # **Before the sweep.** Credit past its `expires_at` is already unspendable,
    # which is what makes expiry bookkeeping rather than a race, and it is the
    # single clearest difference between `available` and `spendable`.
    before = Credits.balance(tenant)
    assert before.balance == 5 * @dollar
    assert before.available == 5 * @dollar
    assert before.spendable == @dollar
    assert before.promotional_spendable == 0
    assert before.expired == 0

    {:ok, _} = Credits.expire_due(Clock.db_now())

    later = Credits.balance(tenant)
    assert later.balance == @dollar
    assert later.available == @dollar
    assert later.spendable == @dollar
    assert later.expired == 4 * @dollar
    assert later.debt == 0

    # Destroyed value is reported apart from spent value, which is I12's whole
    # claim: a reader must never have to infer which of the two happened.
    assert Credits.summary(tenant).expired == 4 * @dollar
    assert Credits.summary(tenant).spent_this_period == 4 * @dollar
  end

  test "I11 debt appears in debt and makes spendable zero" do
    tenant = lot_wallet()

    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "paid")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "job:1")
    {:ok, _} = Credits.settle("job:1", 5 * @dollar)

    snapshot = Credits.balance(tenant)

    assert snapshot.balance == -3 * @dollar
    assert snapshot.held == 0
    assert snapshot.available == -3 * @dollar
    assert snapshot.debt == 3 * @dollar
    # **Not clamped at zero.** `spendable` is exactly the figure `sufficient?/2`
    # compares against, so it goes negative when the debt exceeds eligible
    # availability; clamping it for display would make the reported figure and
    # the ledger's refusal disagree, and the refusal is the thing being
    # reported.
    assert snapshot.spendable == -3 * @dollar
    assert snapshot.promotional_spendable == 0
    refute Credits.sufficient?(tenant, 1)

    assert {:error, :insufficient_credits} = Credits.debit(tenant, 1, "after-debt")

    # A grant repays the debt before creating availability, so both figures move
    # together and neither is left describing a state the other denies.
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "topup")
    repaid = Credits.balance(tenant)
    assert repaid.debt == 0
    assert repaid.spendable == @dollar
    assert repaid.balance == @dollar
  end

  test "I10 a legacy wallet reports spendable equal to available, debt zero and expired zero" do
    # The compatibility promise of the four new keys: a host that has not run
    # the lot migration sees figures that restate what it already had, so a
    # dashboard can render them without asking which writer owns the wallet.
    tenant = unique_tenant("figures")

    empty = Credits.balance(tenant)
    assert empty.spendable == empty.available
    assert {empty.debt, empty.expired, empty.promotional_spendable} == {0, 0, 0}

    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: "paid")
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: "promo", category: :promotional)
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, "job:1")

    snapshot = Credits.balance(tenant)
    assert snapshot.spendable == snapshot.available
    assert snapshot.spendable == 11 * @dollar
    assert snapshot.promotional_spendable == snapshot.promotional
    assert snapshot.debt == 0
    assert snapshot.expired == 0

    # Including when the balance is negative, which a legacy settle above its
    # hold produces and which is not the same thing as debt.
    {:ok, _} = Credits.settle("job:1", 20 * @dollar)
    overrun = Credits.balance(tenant)
    assert overrun.balance < 0
    assert overrun.spendable == overrun.available
    assert overrun.debt == 0

    summary = Credits.summary(tenant)
    assert summary.spendable == summary.available
    assert {summary.debt, summary.expired} == {0, 0}
  end

  test "I10 balance stays signed and spendable is the figure the ledger refuses on" do
    # The existing keys keep their meaning, which is the compatibility half of
    # task 06.03: `balance` is signed and `available` is `balance - held`,
    # whatever the new figures say.
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "stale",
        category: :promotional,
        expires_at: @past
      )

    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "paid")
    {:ok, _} = Credits.hold(tenant, @dollar, "job:1")

    snapshot = Credits.balance(tenant)

    assert snapshot.balance == 5 * @dollar
    assert snapshot.available == snapshot.balance - snapshot.held
    assert snapshot.available == 4 * @dollar
    # Three of the five dollars are past their expiry, so they are not spendable
    # even though nothing has swept them.
    assert snapshot.spendable == @dollar

    # And the refusal follows `spendable`, not `available`: this is what would
    # still pass if `spendable` were merely a copy of `available`.
    assert Credits.sufficient?(tenant, @dollar)
    refute Credits.sufficient?(tenant, @dollar + 1)
    assert {:error, :insufficient_credits} = Credits.hold(tenant, 2 * @dollar, "job:2")
  end

  test "I10 Money.assert_range! refuses an amount above the documented limit before any write" do
    tenant = unique_tenant("figures")
    over = Money.max_micro() + 1

    for call <- [
          fn -> Credits.grant(tenant, over, reference: "x") end,
          fn -> Credits.hold(tenant, over, "x") end,
          fn -> Credits.debit(tenant, over, "x") end,
          fn -> Credits.reverse(tenant, over, "x") end,
          fn -> Credits.settle("x", over) end,
          fn -> Credits.set_low_balance_threshold(tenant, over) end
        ] do
      assert_raise ArgumentError, ~r/outside the range AuroraMeter.Credits can hold/, call
    end

    # Nothing was written by any of the six, including the balance row that
    # `locked_row/2` creates on the way into a transaction.
    assert Ledger.fetch(tenant) == nil
    assert Credits.history(tenant, limit: 10) == []
  end

  property "I10 for any generated operation sequence, summary/1's figures agree with the lot tables" do
    # **The display projection, checked against SQL rather than against the code
    # that produced it.** `balance/1` computes `spendable` and
    # `promotional_spendable` with one aggregate; this recomputes them from the
    # lot rows with a different query and compares. A figure that drifted from
    # the lots it claims to summarise would show up here and nowhere else,
    # because every other test in this file states one expected number.
    check all(commands <- history(), max_runs: 40) do
      tenant = lot_wallet()
      Enum.each(commands, &execute(tenant, &1))

      summary = Credits.summary(tenant)
      snapshot = Credits.balance(tenant)
      truth = from_lots(tenant)

      assert summary.spendable == truth.spendable, "#{tenant}: #{inspect(commands)}"

      assert summary.promotional_spendable == truth.promotional_spendable,
             "#{tenant}: #{inspect(commands)}"

      assert summary.debt == truth.debt, "#{tenant}: #{inspect(commands)}"
      assert summary.expired == truth.expired, "#{tenant}: #{inspect(commands)}"
      assert summary.held == truth.reserved, "#{tenant}: #{inspect(commands)}"
      assert summary.balance == truth.available + truth.reserved - truth.debt

      # The two entry points cannot disagree about the same wallet.
      assert Map.take(summary, [
               :balance,
               :available,
               :spendable,
               :held,
               :promotional,
               :promotional_spendable,
               :debt,
               :expired
             ]) ==
               Map.take(snapshot, [
                 :balance,
                 :available,
                 :spendable,
                 :held,
                 :promotional,
                 :promotional_spendable,
                 :debt,
                 :expired
               ])

      # `spendable` is never above `available`: it is the same money less what
      # has expired and less what is owed.
      assert summary.spendable <= summary.available, "#{tenant}: #{inspect(commands)}"
      assert summary.promotional_spendable >= 0
      assert summary.expired >= 0
      assert summary.debt >= 0
    end
  end

  # The same figures, recomputed from the lot rows with a query that is not the
  # one `Ledger.figures/1` issues.
  defp from_lots(tenant) do
    %{rows: [[available, reserved, promotional_available, expired]]} =
      TestRepo.query!(
        """
        SELECT coalesce(sum(available) FILTER (WHERE state = 'open'
                        AND (expires_at IS NULL OR expires_at > now())), 0)::bigint,
               coalesce(sum(reserved), 0)::bigint,
               coalesce(sum(available) FILTER (WHERE state = 'open' AND category = 'promotional'
                        AND (expires_at IS NULL OR expires_at > now())), 0)::bigint,
               coalesce(sum(expired), 0)::bigint
          FROM aurora_meter_credit_lots WHERE tenant_key = $1
        """,
        [tenant]
      )

    %{rows: [[all_available, debt]]} =
      TestRepo.query!(
        """
        SELECT coalesce((SELECT sum(available) FROM aurora_meter_credit_lots
                          WHERE tenant_key = $1), 0)::bigint,
               (SELECT debt FROM aurora_meter_credit_balances WHERE tenant_key = $1)
        """,
        [tenant]
      )

    %{
      spendable: available - debt,
      promotional_spendable: promotional_available,
      reserved: reserved,
      expired: expired,
      debt: debt,
      available: all_available
    }
  end

  # A small generator: enough shapes to reach every figure, short enough that
  # forty runs stay inside the file's budget. Reversals are excluded because
  # `Credits.reverse/4` does not take the lot path yet (finding X250, owed to
  # 06e), so including them would be asserting against behaviour 06e replaces.
  defp history do
    StreamData.list_of(
      StreamData.one_of([
        StreamData.tuple({StreamData.constant(:grant), StreamData.integer(1..5_000_000)}),
        StreamData.tuple({StreamData.constant(:promo), StreamData.integer(1..5_000_000)}),
        StreamData.tuple({StreamData.constant(:stale), StreamData.integer(1..5_000_000)}),
        StreamData.tuple({StreamData.constant(:hold), StreamData.integer(1..3_000_000)}),
        StreamData.tuple({StreamData.constant(:debit), StreamData.integer(1..3_000_000)}),
        StreamData.constant({:settle, 0}),
        StreamData.constant({:release, 0}),
        StreamData.constant({:expire, 0})
      ]),
      min_length: 1,
      max_length: 12
    )
  end

  defp execute(tenant, {:grant, amount}),
    do: Credits.grant(tenant, amount, reference: reference(tenant))

  defp execute(tenant, {:promo, amount}),
    do:
      Credits.grant(tenant, amount,
        reference: reference(tenant),
        category: :promotional,
        expires_at: ~U[2099-01-01 00:00:00Z]
      )

  defp execute(tenant, {:stale, amount}),
    do:
      Credits.grant(tenant, amount,
        reference: reference(tenant),
        category: :promotional,
        expires_at: @past
      )

  defp execute(tenant, {:hold, amount}), do: Credits.hold(tenant, amount, reference(tenant))
  defp execute(tenant, {:debit, amount}), do: Credits.debit(tenant, amount, reference(tenant))

  defp execute(tenant, {:settle, _}) do
    case open_hold(tenant) do
      nil -> :ok
      hold -> Credits.settle(hold.reference, div(hold.held_delta, 2) + 1)
    end
  end

  defp execute(tenant, {:release, _}) do
    case open_hold(tenant) do
      nil -> :ok
      hold -> Credits.release(hold.reference)
    end
  end

  defp execute(_tenant, {:expire, _}), do: Credits.expire_due(Clock.db_now())

  defp open_hold(tenant) do
    import Ecto.Query, only: [from: 2]

    TestRepo.one(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant and t.kind == ^:hold and t.status == ^:pending,
        order_by: [asc: t.seq],
        limit: 1
      )
    )
  end

  defp reference(tenant), do: "#{tenant}:#{System.unique_integer([:positive])}"

  defp lot_wallet do
    tenant = unique_tenant("figures")
    Ledger.enable_lots!(tenant)
    tenant
  end
end
