defmodule AuroraMeter.Credits.Allocator do
  @moduledoc false

  # The single allocation engine (V1 task 06.04). Every operation that moves
  # credit on a cut-over wallet goes through it: debit, hold, settle, release,
  # expiry, reversal and restoration. One implementation, so the runtime and the
  # wallet migration that replays a history cannot disagree about what a history
  # means.
  #
  # Two layers, deliberately in one module so the seam between them is visible:
  #
  #   * **Planner** (`plan/2`), pure. It takes a book of lot maps that have
  #     already been read and locked, and a request, and returns the movements
  #     to make. No repo, no clock, no configuration: the instant is passed in.
  #     This is the function the model test drives and the function 06b's
  #     migration replays with.
  #   * **Applier** (`apply_plan/6`), repo bound. It writes the allocation rows,
  #     updates the lot rows, updates the balance row and runs the conservation
  #     check. It decides nothing.
  #
  # ## The spend order (D07)
  #
  #     {category_rank, expiry_rank, granted_at, seq}
  #     category_rank: promotional -> 0, paid -> 1, adjustment -> 1
  #     expiry_rank:   {0, expires_at} when expires_at is not null, else {1, 0}
  #
  # Promotional before paid, earliest expiry first, non-expiring last within its
  # category, oldest grant next, and `seq` as the total tiebreak. `seq` and not
  # `id`: a uuid is random, so `id` would make two lots granted in the same tick
  # spend in an order that has nothing to do with which came first. The key is
  # total, so the order a query happens to return lots in cannot change what a
  # debit spends.
  #
  # ## Eligibility
  #
  # A lot is spendable when its state is `:open` and it is not past its
  # `expires_at`. A lot whose expiry has passed but which the sweep has not
  # reached yet is **not** spendable. That is a deliberate change from 0.4.0,
  # where such credit stayed spendable until the next sweep, and it is what makes
  # expiry bookkeeping rather than a race.
  #
  # ## Debt
  #
  # With `contribution = available + reserved` and
  # `balance = sum(contribution) - debt`:
  #
  #   * taking X from `available` moves contribution by -X and debt by 0:
  #     balance -X. Correct for a spend.
  #   * taking X from `consumed` moves contribution by 0, so debt must rise by X
  #     for balance to fall by X. Correct for reversing money already spent.
  #   * taking X from `reserved` moves contribution by -X and debt by 0:
  #     balance -X. Correct: the hold that lost its reservation will settle,
  #     find nothing reserved and create its own debt for the work it did.
  #   * adding a lot of X while debt is D gives contribution +X - min(X, D) and
  #     debt -min(X, D): balance +X. Correct.

  import Ecto.Query

  alias AuroraMeter.Credits.ConservationError
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot

  @typedoc false
  @type bucket :: :available | :reserved | :consumed | :reversed | :expired

  @typedoc false
  @type lot :: %{
          id: Ecto.UUID.t(),
          category: CreditLot.category(),
          amount: non_neg_integer(),
          available: non_neg_integer(),
          reserved: non_neg_integer(),
          consumed: non_neg_integer(),
          reversed: non_neg_integer(),
          expired: non_neg_integer(),
          expires_at: DateTime.t() | nil,
          granted_at: DateTime.t(),
          seq: integer(),
          source: map()
        }

  @typedoc false
  @type movement :: %{
          lot_id: Ecto.UUID.t(),
          from: bucket(),
          to: bucket(),
          amount: pos_integer(),
          kind: CreditAllocation.kind()
        }

  @typedoc false
  @type plan :: %{
          movements: [movement()],
          debt_delta: integer(),
          book: [lot()],
          new_lot: map() | nil
        }

  @quantities [:available, :reserved, :consumed, :reversed, :expired]

  # -- the planner (pure) -----------------------------------------------------

  @doc false
  @spec plan([lot()], tuple()) :: {:ok, plan()} | {:error, atom()}

  # A grant creates one lot and then repays outstanding debt out of it before
  # any of it becomes spendable. The lot's id is settled by the caller (it is
  # the row it is about to insert), so the planner is still pure.
  def plan(book, {:grant, attrs, debt}) do
    repaid = min(attrs.amount, debt)

    lot =
      attrs
      |> Map.merge(%{
        available: attrs.amount,
        reserved: 0,
        consumed: 0,
        reversed: 0,
        expired: 0
      })

    movements =
      if repaid > 0 do
        [movement(lot.id, :available, :consumed, repaid, :consume)]
      else
        []
      end

    {:ok,
     %{
       movements: movements,
       debt_delta: -repaid,
       book: apply_movements(book ++ [lot], movements),
       new_lot: lot
     }}
  end

  def plan(book, {:debit, amount, now, allow_negative?, tolerance, debt}) do
    {movements, unmet} = take(book, amount, eligible(book, now), :available, :consumed, :consume)

    cond do
      # **A debit is refused while the wallet owes money, exactly as a hold is.**
      # `architecture-map.md` 7.2: "New holds and debits cannot spend while
      # `debt > 0`". 06a's first implementation refused the hold and not the
      # debit, which 01e's independent lot model caught on a generated history
      # (finding X251): a wallet 17 USD in debt accepted a one-micro-dollar
      # debit because a release had put availability back beside the debt.
      debt > 0 and not allow_negative? ->
        {:error, :insufficient_credits}

      unmet == 0 ->
        {:ok, plan_of(book, movements, 0)}

      allow_negative? ->
        # Already left the payment provider: refusing it would only make the
        # ledger disagree with reality. The part that had no lot to come out of
        # is debt, which is the honest record.
        {:ok, plan_of(book, movements, unmet)}

      unmet <= tolerance ->
        {:ok, plan_of(book, movements, unmet)}

      true ->
        {:error, :insufficient_credits}
    end
  end

  # A hold reserves exact lots, so it can only reserve what exists. The
  # overdraft tolerance therefore does not extend a hold on a cut-over wallet
  # the way it extends a debit: there is no lot to reserve against. It is a
  # documented behaviour change and it only reaches a host that configured a
  # non-zero `:credits_overdraft_tolerance`, which defaults to 0.
  def plan(book, {:hold, amount, now, debt}) do
    if debt > 0 do
      {:error, :insufficient_credits}
    else
      {movements, unmet} =
        take(book, amount, eligible(book, now), :available, :reserved, :reserve)

      if unmet == 0 do
        {:ok, plan_of(book, movements, 0)}
      else
        {:error, :insufficient_credits}
      end
    end
  end

  # `reservations` is `[{lot_id, amount}]`, this hold's live `reserve`
  # allocations. Consume what the work actually cost out of the reservation
  # first, hand back what it did not, and only then reach for other funds.
  def plan(book, {:settle, reservations, actual, now, debt_before}) do
    ordered = order_reservations(book, reservations)

    {book, consumed_movements, remaining, remainders} =
      consume_reservations(book, ordered, actual)

    # **`remainders`, not `ordered`.** What is left to hand back is this hold's
    # reservation less what this settlement just consumed of it, per lot. Using
    # the original amounts again unreserves the consumed part a second time,
    # which is invisible while this hold is the only reservation on the lot (the
    # lot's own `reserved` caps it) and steals another hold's reservation the
    # moment there are two. Found by 01e's independent lot model on a generated
    # history, finding X251: a lot whose model said `reserved: 23030658` read
    # `1874663` in the database, and conservation held throughout because
    # `reserved` to `available` keeps the sum.
    {book, release_movements} = release_reservations(book, remainders, now)

    {book, extra_movements, unmet} =
      if remaining > 0 do
        {moves, unmet} =
          take(book, remaining, eligible(book, now), :available, :consumed, :consume)

        {apply_movements(book, moves), moves, unmet}
      else
        {book, [], 0}
      end

    {book, movements, debt_delta} =
      repay_debt(
        book,
        consumed_movements ++ release_movements ++ extra_movements,
        unmet,
        debt_before,
        now
      )

    {:ok, %{movements: movements, debt_delta: debt_delta, book: book, new_lot: nil}}
  end

  def plan(book, {:release, reservations, now, debt_before}) do
    ordered = order_reservations(book, reservations)
    {book, movements} = release_reservations(book, ordered, now)
    {book, movements, debt_delta} = repay_debt(book, movements, 0, debt_before, now)

    {:ok, %{movements: movements, debt_delta: debt_delta, book: book, new_lot: nil}}
  end

  # Expiry acts on one lot and only on its `available` bucket, which is I12:
  # it cannot reach later or unrelated funds because it never looks at another
  # lot. Reserved value stays reserved and is written off when the hold that
  # holds it is released or settles.
  def plan(book, {:expire, lot_id, _now}) do
    case Enum.find(book, &(&1.id == lot_id)) do
      nil ->
        {:error, :not_found}

      %{available: 0, reserved: reserved} when reserved > 0 ->
        {:error, :held}

      %{available: 0} ->
        {:error, :already_expired}

      lot ->
        movements = [movement(lot.id, :available, :expired, lot.available, :expire)]
        {:ok, plan_of(book, movements, 0)}
    end
  end

  # A refund or a chargeback, scoped to the lots the payment funded.
  # `available` first so the refund destroys as little as possible, `consumed`
  # next (which is what raises debt), `reserved` last because an open hold is
  # work the host believes is still running.
  def plan(book, {:reverse, payment_intent_id, amount, _now}) do
    targets = funded_by(book, payment_intent_id)

    if targets == [] do
      {:error, :no_matching_lot}
    else
      {book, movements, _left} =
        Enum.reduce([:available, :consumed, :reserved], {book, [], amount}, fn
          _bucket, {book, moves, 0} ->
            {book, moves, 0}

          bucket, {book, moves, left} ->
            ids = Enum.map(targets, & &1.id)
            {new_moves, unmet} = take(book, left, ids, bucket, :reversed, :reverse)
            {apply_movements(book, new_moves), moves ++ new_moves, unmet}
        end)

      debt_delta =
        movements
        |> Enum.filter(&(&1.from == :consumed))
        |> Enum.reduce(0, &(&1.amount + &2))

      {:ok,
       %{
         movements: movements,
         debt_delta: debt_delta,
         book: book,
         new_lot: nil
       }}
    end
  end

  def plan(book, {:restore, payment_intent_id, amount, _now, debt}) do
    targets = funded_by(book, payment_intent_id)

    if targets == [] do
      {:error, :no_matching_lot}
    else
      ids = Enum.map(targets, & &1.id)
      {restores, _unmet} = take(book, amount, ids, :reversed, :available, :restore)
      book = apply_movements(book, restores)

      restored = Enum.reduce(restores, 0, &(&1.amount + &2))
      repay = min(restored, debt)

      {repayments, _} =
        take(book, repay, Enum.map(targets, & &1.id), :available, :consumed, :consume)

      {:ok,
       %{
         movements: restores ++ repayments,
         debt_delta: -Enum.reduce(repayments, 0, &(&1.amount + &2)),
         book: apply_movements(book, repayments),
         new_lot: nil
       }}
    end
  end

  @doc false
  @spec spend_key(lot()) :: tuple()
  def spend_key(lot) do
    {category_rank(lot.category), expiry_rank(lot.expires_at), granted_rank(lot.granted_at),
     lot.seq}
  end

  @doc false
  @spec spendable([lot()], non_neg_integer(), DateTime.t()) :: integer()
  def spendable(book, debt, now) do
    eligible_ids = eligible(book, now)

    book
    |> Enum.filter(&(&1.id in eligible_ids))
    |> Enum.reduce(0, &(&1.available + &2))
    |> Kernel.-(debt)
  end

  @doc false
  @spec projection([lot()], non_neg_integer()) :: %{
          balance: integer(),
          held: non_neg_integer(),
          promotional: non_neg_integer(),
          expired: non_neg_integer()
        }
  def projection(book, debt) do
    Enum.reduce(
      book,
      %{balance: -debt, held: 0, promotional: 0, expired: 0},
      fn lot, acc ->
        contribution = lot.available + lot.reserved

        %{
          balance: acc.balance + contribution,
          held: acc.held + lot.reserved,
          promotional:
            acc.promotional + if(lot.category == :promotional, do: contribution, else: 0),
          expired: acc.expired + lot.expired
        }
      end
    )
  end

  # -- planner internals ------------------------------------------------------

  # **Every incoming value repays outstanding debt before it becomes
  # spendable**, and value handed back by an unreserve is incoming value. Without
  # this a release could put availability beside an outstanding debt, which
  # breaks LI-06a-5 (`debt > 0` implies no availability) and lets a wallet spend
  # money it owes. A grant has repaid debt since the first draft; 01e's
  # independent lot model is what showed that the other two doors were open
  # (finding X251).
  #
  # Eligible lots only, in spend order. Repaying out of a lot that is past its
  # `expires_at` would turn money that is about to be destroyed into debt
  # relief, which is a different and worse arithmetic: debt repayment is a
  # spend, so it spends what a spend could.
  defp repay_debt(book, movements, debt_delta, debt_before, now) do
    debt = debt_before + debt_delta

    if debt <= 0 do
      {book, movements, debt_delta}
    else
      {repayments, _unmet} =
        take(book, debt, eligible(book, now), :available, :consumed, :consume)

      repaid = Enum.reduce(repayments, 0, &(&1.amount + &2))
      {apply_movements(book, repayments), movements ++ repayments, debt_delta - repaid}
    end
  end

  defp plan_of(book, movements, debt_delta) do
    %{
      movements: movements,
      debt_delta: debt_delta,
      book: apply_movements(book, movements),
      new_lot: nil
    }
  end

  defp movement(lot_id, from, to, amount, kind),
    do: %{lot_id: lot_id, from: from, to: to, amount: amount, kind: kind}

  # The ids of the lots a spend may touch, in spend order. Order is the whole
  # point: the caller passes the list to `take/6`, which walks it.
  defp eligible(book, now) do
    book
    |> Enum.filter(fn lot ->
      lot.available + lot.reserved > 0 and not past?(lot.expires_at, now)
    end)
    |> Enum.sort_by(&spend_key/1)
    |> Enum.map(& &1.id)
  end

  defp past?(nil, _now), do: false
  defp past?(expires_at, now), do: DateTime.compare(expires_at, now) != :gt

  # Walks `ids` in the order given, moving what each lot can spare from `from`
  # to `to` until `amount` is met. Returns the movements and what is left
  # unmet, so every caller decides for itself what an unmet remainder means.
  defp take(book, amount, ids, from, to, kind) do
    index = Map.new(book, &{&1.id, &1})

    {movements, left} =
      Enum.reduce(ids, {[], amount}, fn
        _id, {moves, 0} ->
          {moves, 0}

        id, {moves, left} ->
          lot = Map.fetch!(index, id)
          taken = min(Map.fetch!(lot, from), left)

          if taken > 0 do
            {moves ++ [movement(id, from, to, taken, kind)], left - taken}
          else
            {moves, left}
          end
      end)

    {movements, left}
  end

  defp apply_movements(book, movements) do
    Enum.reduce(movements, book, fn move, acc ->
      Enum.map(acc, &apply_movement(&1, move))
    end)
  end

  defp apply_movement(%{id: id} = lot, %{lot_id: id} = move) do
    lot
    |> Map.update!(move.from, &(&1 - move.amount))
    |> Map.update!(move.to, &(&1 + move.amount))
  end

  defp apply_movement(lot, _move), do: lot

  # A hold's reservations are consumed and released in spend order, so a
  # settlement below its estimate hands back the credit the tenant would have
  # spent last rather than the credit it would have spent first.
  defp order_reservations(book, reservations) do
    index = Map.new(book, &{&1.id, &1})

    reservations
    |> Enum.filter(fn {lot_id, amount} -> amount > 0 and Map.has_key?(index, lot_id) end)
    |> Enum.sort_by(fn {lot_id, _amount} -> spend_key(Map.fetch!(index, lot_id)) end)
  end

  # Returns the movements, what of `actual` is still unmet, and **what this hold
  # still holds per lot afterwards**, which is what `release_reservations/3`
  # hands back.
  defp consume_reservations(book, reservations, actual) do
    Enum.reduce(reservations, {book, [], actual, []}, fn {lot_id, reserved},
                                                         {book, moves, left, remainders} ->
      lot = Enum.find(book, &(&1.id == lot_id))

      # Capped by the lot's own `reserved` as well as by this hold's record of
      # it, because a reversal can take reserved value away without the hold
      # knowing.
      held_here = min(reserved, lot.reserved)
      taken = min(held_here, left)
      remainders = remainders ++ [{lot_id, held_here - taken}]

      if taken > 0 do
        move = movement(lot_id, :reserved, :consumed, taken, :consume)
        {apply_movements(book, [move]), moves ++ [move], left - taken, remainders}
      else
        {book, moves, left, remainders}
      end
    end)
  end

  # **I12 and finding L1.** Whatever this hold still holds on a lot that has
  # passed its expiry is written off rather than handed back: nothing of an
  # expired lot is ever spendable again. Before this, a reservation released
  # after its grant expired became spendable until the next sweep, and the
  # sweep could not take it back because the grant was already stamped.
  defp release_reservations(book, reservations, now) do
    Enum.reduce(reservations, {book, []}, fn {lot_id, reserved}, {book, moves} ->
      lot = Enum.find(book, &(&1.id == lot_id))
      amount = min(reserved, lot.reserved)

      cond do
        amount == 0 ->
          {book, moves}

        past?(lot.expires_at, now) ->
          move = movement(lot_id, :reserved, :expired, amount, :expire)
          {apply_movements(book, [move]), moves ++ [move]}

        true ->
          move = movement(lot_id, :reserved, :available, amount, :unreserve)
          {apply_movements(book, [move]), moves ++ [move]}
      end
    end)
  end

  # Promotional lots are never touched by a paid reversal, because a promotion
  # did not come from that payment and cannot be handed back to it.
  defp funded_by(book, payment_intent_id) do
    book
    |> Enum.filter(fn lot ->
      lot.category != :promotional and
        Map.get(lot.source || %{}, "payment_intent_id") == payment_intent_id
    end)
    |> Enum.sort_by(&spend_key/1)
  end

  defp category_rank(:promotional), do: 0
  defp category_rank(_paid_or_adjustment), do: 1

  defp expiry_rank(nil), do: {1, 0}
  defp expiry_rank(expires_at), do: {0, DateTime.to_unix(expires_at, :microsecond)}

  defp granted_rank(nil), do: 0
  defp granted_rank(granted_at), do: DateTime.to_unix(granted_at, :microsecond)

  # -- the applier (repo bound) -----------------------------------------------

  @doc false
  @spec book(module(), String.t()) :: [lot()]
  def book(repo, tenant_key) do
    # `ORDER BY id` and not the spend order. Postgres may re-fetch a
    # concurrently updated row, so `FOR UPDATE` does not promise acquisition in
    # output order; what the ordering buys is that any two transactions that
    # did reach here without the balance lock would still queue in the same
    # direction. The balance row lock is what actually gives one writer per
    # wallet, and no path that touches a lot without it may be added.
    from(l in CreditLot,
      where: l.tenant_key == ^tenant_key,
      order_by: [asc: l.id],
      lock: "FOR UPDATE"
    )
    |> repo.all()
    |> Enum.map(&to_lot/1)
  end

  @doc false
  @spec reservations(module(), Ecto.UUID.t()) :: [{Ecto.UUID.t(), non_neg_integer()}]
  def reservations(repo, hold_transaction_id) do
    # What this hold still holds, per lot: its `reserve` allocations less
    # everything that has since taken value out of `reserved` for it. A
    # reversal can take reserved value away without the hold knowing, so the
    # planner caps every reservation by the lot's own `reserved` as well.
    from(a in CreditAllocation,
      where: a.transaction_id == ^hold_transaction_id,
      group_by: a.lot_id,
      select:
        {a.lot_id,
         type(
           sum(
             fragment(
               "CASE WHEN ? = 'reserve' THEN ? WHEN ? IN ('unreserve','consume','expire','reverse') THEN -? ELSE 0 END",
               a.kind,
               a.amount,
               a.kind,
               a.amount
             )
           ),
           :integer
         )}
    )
    |> repo.all()
    |> Enum.map(fn {lot_id, amount} -> {lot_id, max(amount || 0, 0)} end)
    |> Enum.filter(fn {_lot_id, amount} -> amount > 0 end)
  end

  @doc """
  What this plan moves the balance row by.

  **Deltas, not absolutes, and the distinction is the whole conservation
  check.** Writing the row from `projection/2` over the plan's own book and then
  comparing it with a sum over the lots would be the same arithmetic run twice:
  it could not disagree, and a check that cannot fail proves nothing (finding
  X125's shape). Moving the row by a delta makes the lots an independent
  statement of the same fact, so a row that had already drifted is caught by the
  next write to it.
  """
  @spec deltas([lot()], plan(), non_neg_integer(), non_neg_integer()) :: map()
  def deltas(book, plan, debt_before, debt_after) do
    before = projection(book, debt_before)
    later = projection(plan.book, debt_after)

    Map.new(before, fn {key, value} -> {key, Map.fetch!(later, key) - value} end)
  end

  @doc false
  @spec apply_plan(module(), CreditBalance.t(), map(), map(), DateTime.t(), atom()) ::
          CreditBalance.t()
  def apply_plan(repo, row, txn, applied, now, operation) do
    %{plan: plan, deltas: deltas, debt_after: debt_after} = applied
    now = microsecond(now)

    insert_new_lot!(repo, plan.new_lot, txn, now)
    write_allocations!(repo, row.tenant_key, txn.id, plan.movements, now)
    update_lots!(repo, plan)

    updated =
      row
      |> Ecto.Changeset.change(
        balance: row.balance + deltas.balance,
        held: row.held + deltas.held,
        promotional: row.promotional + deltas.promotional,
        debt: debt_after,
        expired: row.expired + deltas.expired
      )
      |> repo.update!()

    check!(repo, updated, operation, txn.reference)
  end

  # The conservation check, and it is a re-read rather than a recomputation.
  # Comparing the planner's own arithmetic with itself would prove nothing; this
  # asks the database what the lots now say and compares that with the row that
  # was just written. Both are inside the transaction, so it sees its own
  # writes and a concurrent writer cannot be what it catches.
  @doc false
  @spec check!(module(), CreditBalance.t(), atom(), String.t() | nil) :: CreditBalance.t()
  def check!(repo, row, operation, reference) do
    %{rows: [[available, reserved, promotional, expired]]} =
      repo.query!(
        """
        SELECT coalesce(sum(available), 0)::bigint, coalesce(sum(reserved), 0)::bigint,
               coalesce(sum(available + reserved)
                        FILTER (WHERE category = 'promotional'), 0)::bigint,
               coalesce(sum(expired), 0)::bigint
          FROM aurora_meter_credit_lots
         WHERE tenant_key = $1
        """,
        [row.tenant_key]
      )

    expected = %{
      balance: available + reserved - row.debt,
      held: reserved,
      promotional: promotional,
      expired: expired
    }

    actual = %{
      balance: row.balance,
      held: row.held,
      promotional: row.promotional,
      expired: row.expired
    }

    deltas =
      Map.new(actual, fn {key, value} -> {key, value - Map.fetch!(expected, key)} end)

    if Enum.all?(deltas, fn {_key, delta} -> delta == 0 end) do
      stamp_checked!(repo, row)
    else
      :telemetry.execute(
        [:aurora_meter, :credits, :conservation_error],
        %{
          balance_delta: deltas.balance,
          held_delta: deltas.held,
          promotional_delta: deltas.promotional,
          expired_delta: deltas.expired
        },
        %{tenant_key: row.tenant_key, operation: operation, reference: reference}
      )

      raise ConservationError,
        tenant_key: row.tenant_key,
        operation: operation,
        reference: reference,
        expected: expected,
        actual: actual,
        deltas: deltas
    end
  end

  defp stamp_checked!(repo, row) do
    # Database stamped, like every other timestamp a decision may one day be
    # made from. It is one statement rather than a second round trip, and it
    # cannot drift from the node that happened to write the row.
    {1, [checked_at]} =
      repo.update_all(
        from(b in CreditBalance,
          where: b.id == ^row.id,
          select: b.projection_checked_at,
          update: [
            set: [projection_checked_at: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")]
          ]
        ),
        []
      )

    %{row | projection_checked_at: checked_at}
  end

  defp insert_new_lot!(_repo, nil, _txn, _now), do: :ok

  defp insert_new_lot!(repo, lot, txn, now) do
    attrs =
      lot
      |> Map.take(
        [:tenant_key, :reference, :category, :amount, :expires_at, :source] ++ @quantities
      )
      |> Map.merge(%{
        grant_transaction_id: txn.id,
        granted_at: now,
        state: CreditLot.state_for(lot)
      })

    %CreditLot{id: lot.id}
    |> CreditLot.changeset(attrs)
    |> repo.insert!()
  end

  defp write_allocations!(_repo, _tenant_key, _txn_id, [], _now), do: :ok

  defp write_allocations!(repo, tenant_key, txn_id, movements, now) do
    rows =
      Enum.map(movements, fn move ->
        %{
          id: Ecto.UUID.generate(),
          tenant_key: tenant_key,
          lot_id: move.lot_id,
          transaction_id: txn_id,
          kind: move.kind,
          from_bucket: move.from,
          to_bucket: move.to,
          amount: move.amount,
          inserted_at: now
        }
      end)

    repo.insert_all(CreditAllocation, rows)
    :ok
  end

  # One UPDATE per lot the plan touched, by primary key, with no ON CONFLICT:
  # the row is already locked, the new quantities are the planner's, and the
  # CHECK constraints are what refuse a wrong one.
  defp update_lots!(repo, plan) do
    touched = plan.movements |> Enum.map(& &1.lot_id) |> Enum.uniq()
    new_lot_id = plan.new_lot && plan.new_lot.id

    plan.book
    |> Enum.filter(&(&1.id in touched and &1.id != new_lot_id))
    |> Enum.each(fn lot ->
      quantities = Map.take(lot, @quantities)

      {1, _} =
        repo.update_all(
          from(l in CreditLot,
            where: l.id == ^lot.id,
            update: [set: [updated_at: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")]]
          ),
          set:
            Enum.to_list(quantities) ++
              [state: CreditLot.state_for(Map.put(quantities, :amount, lot.amount))]
        )
    end)

    # The new lot, when the grant repaid debt out of it, is updated through the
    # same path after its insert so one code path owns the state function.
    if new_lot_id && new_lot_id in touched do
      lot = Enum.find(plan.book, &(&1.id == new_lot_id))
      quantities = Map.take(lot, @quantities)

      {1, _} =
        repo.update_all(
          from(l in CreditLot,
            where: l.id == ^new_lot_id,
            update: [set: [updated_at: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")]]
          ),
          set:
            Enum.to_list(quantities) ++
              [state: CreditLot.state_for(Map.put(quantities, :amount, lot.amount))]
        )
    end

    :ok
  end

  # The expiry sweep pins its instant to the second, and `granted_at` and an
  # allocation's `inserted_at` are `utc_datetime_usec`, which refuses anything
  # coarser. `DateTime.truncate/2` only ever LOWERS precision, so it cannot do
  # this. Both columns are display values (the order is `seq`), so one instant
  # for every row of one transaction is exactly right.
  defp microsecond(%DateTime{microsecond: {value, _precision}} = instant),
    do: %{instant | microsecond: {value, 6}}

  defp to_lot(%CreditLot{} = lot) do
    %{
      id: lot.id,
      category: lot.category,
      amount: lot.amount,
      available: lot.available,
      reserved: lot.reserved,
      consumed: lot.consumed,
      reversed: lot.reversed,
      expired: lot.expired,
      expires_at: lot.expires_at,
      granted_at: lot.granted_at,
      seq: lot.seq,
      source: lot.source || %{}
    }
  end
end
