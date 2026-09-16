defmodule AuroraMeter.CreditsLotMigrationPropertyTest do
  @moduledoc """
  Generated **legacy** histories, replayed into lots and checked against the
  balance row the legacy ledger itself produced (build unit 06b, V1 task 06.02).

  The rest of this unit is fourteen hand-chosen wallet shapes, and they were
  chosen by the same mind that wrote the fold. That is the blind spot a
  generator exists to cover, and the precedent is one unit old: 06a had three
  hand-written histories, a fifty-connection test and a two-node run all
  passing, and a generated history found three money defects in twelve samples.

  ## What is generated, and what it is checked against

  `AuroraMeter.Test.LedgerCommands.history/1` (01e) draws a state-dependent
  sequence of grants in all three categories, holds, settles above and below
  their hold, releases, debits and expiry sweeps. This module executes it
  through the shipped `AuroraMeter.Credits` API against a wallet whose
  `lots_enabled_at` is null, which is the legacy writer, and rewrites two
  things as it goes: paid grants get payment-intent shaped references and a
  `{:reverse, ...}` command becomes a Pro-shaped refund naming one of them.
  Without that every reversal would be refused for want of provenance, which is
  correct behaviour and a waste of a generated history.

  The wallet is then aged to the shape a 0.4.0 database has (null
  `hold_transaction_id`) and put through `AuroraMeter.Credits.LotMigration`.
  The comparison is against figures this module did not compute:

    * the fold's running projection against **every row's** `balance_after`,
      `held_after` and `promotional_after`, inside the fold;
    * the folded book's projection against the balance row, before the cutover
      commits;
    * after the cutover, `balance`, `held` and `promotional` read back through
      the public API and again straight out of the lots with SQL;
    * **each lot's five quantities against a fold of that lot's own
      allocations**, which is the one direction nothing else in this unit
      checks and the one that would catch a lot table and an allocation trail
      that disagree.

  ## Silence is not success

  The teardown raises when the property compared **nothing**, because a run in
  which every history was legitimately refused would otherwise be green for the
  wrong reason (06a's first cross-oracle run compared zero histories on three
  of seven seeds and only found out because it asserted that it had not). The
  compared, refused and reordered counts are printed per run.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  # A guard against a hang, not a budget. One history is up to forty real
  # ledger writes plus a migration, all on independent connections.
  @moduletag timeout: 600_000

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.LotMigration
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.LedgerCommands
  alias AuroraMeter.Test.LedgerFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @counts {__MODULE__, :counts}

  # **Every exclusion is measured and named with the finding that closes it.**
  # A blocked wallet is only allowed to be one of these three; anything else
  # fails the property with the history that produced it.
  #
  #   * `promotional_divergence`: the legacy ledger clamps `promotional` to
  #     `max(balance_after, 0)` after every entry, so a refund that drives the
  #     balance negative zeroes it permanently while the lot model keeps the
  #     promotion whole and records debt. The two accounts genuinely disagree
  #     about what the customer holds and the migration will not pick a winner
  #     (finding X257).
  #   * `reversal_took_reserved`: the refund would have to take value a pending
  #     hold has reserved, which moves `held` where the legacy row did not.
  #   * `reversal_exceeds_lots`: the generator draws a reversal amount with no
  #     upper bound, so it can take back more than the payment it names ever
  #     granted. The legacy ledger allows that; the lot model cannot reproduce
  #     it, because there is nothing left in the lot to reverse.
  #   * `expire_reserved_grant`: **this property found it.** The legacy expiry
  #     guard is wallet wide (`max(balance - held, 0)`), not per grant, so when
  #     other grants cover the held amount it destroys a grant in full although
  #     a live hold was reserving part of it. No lot assignment reproduces such
  #     a row (finding X261).
  #
  # `hold_unbacked` is allowed **only when the wallet owes money**, which is
  # the fifth thing this property found (finding X262): `Allocator.plan/2`'s
  # `{:reverse, ...}` creates debt without repaying it out of the availability
  # other lots still hold, so the book ends in a state 06a's own LI-06a-5
  # forbids, and a hold the legacy ledger then accepted on
  # `sum(available) - debt >= amount` is refused outright. The **other** cause
  # of `hold_unbacked`, a hold the overdraft tolerance let through with no lot
  # to reserve from, has `debt == 0` and its own named test, and this property
  # runs with the tolerance at its default of zero, so it must never appear
  # here.
  @refusals [
    :promotional_divergence,
    :reversal_took_reserved,
    :reversal_exceeds_lots,
    :expire_reserved_grant
  ]

  setup_all do
    Connections.checkout!()

    # A run killed mid-history leaves committed rows under this module's own
    # tenants, and `Credits.expire_due/1` is not tenant scoped, so one leaked
    # promotional grant turns every later expiry into a false failure.
    Connections.register_prefix("lotprop")
    Connections.cleanup!("lotprop")
    drop_checkpoints!()

    before = Connections.row_counts()
    :persistent_term.put(@counts, blank())

    on_exit(fn ->
      Connections.checkout!()
      remaining = Connections.row_counts()

      if remaining != before do
        raise "#{inspect(__MODULE__)} left rows behind: #{inspect(before)} -> " <>
                "#{inspect(remaining)}"
      end

      counts = :persistent_term.get(@counts, %{})
      total = counts.compared + counts.refused + counts.skipped

      IO.puts(
        "[06b replay property] compared: #{counts.compared}, refused: #{counts.refused}, " <>
          "skipped: #{counts.skipped}, reordered by seq: #{counts.reordered}, " <>
          "refusals: #{inspect(counts.flags)}"
      )

      if total > 0 and counts.compared == 0 do
        raise "the replay property refused or skipped all #{total} histories and compared " <>
                "none of them, so it proved nothing about the wallet migration against the " <>
                "balance rows the legacy ledger wrote"
      end

      :persistent_term.erase(@counts)
    end)

    :ok
  end

  property "I19 a generated legacy history replays into lots that reproduce its balance row" do
    check all(history <- legacy_history(), max_runs: LedgerCommands.runs(20)) do
      own? = Connections.checkout!()
      tenant = legacy_tenant()

      try do
        issued = drive(tenant, history)
        if issued > 0, do: verify!(tenant, history), else: bump(:skipped)
      after
        Connections.cleanup!(tenant)
        drop_checkpoints!()
        if own?, do: Sandbox.checkin(Connections.repo())
      end
    end
  end

  test "X125 the property's comparison can fail: one micro-dollar moved between two buckets" do
    # The negative control. The property passes by comparing a replay with a
    # balance row, and it would pass just as happily if the comparison were
    # vacuous. One micro-dollar is moved between two buckets of a committed
    # lot, which no operation would do and which the lot's own CHECK constraint
    # permits because the sum is unchanged. Every direction the property checks
    # must notice: the allocation fold, and the SQL identities.
    own? = Connections.checkout!()
    tenant = legacy_tenant()

    try do
      history = [
        {:grant, "g1", 5_000_000, :paid, nil},
        {:hold, "h1", 2_000_000},
        {:debit, "d1", 1_000_000}
      ]

      assert drive(tenant, history) == 3
      verify!(tenant, history)

      [lot] = lots(tenant)

      Connections.repo().query!(
        "UPDATE aurora_meter_credit_lots SET available = available - 1, reserved = reserved + 1 " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(lot.id)]
      )

      assert_raise ExUnit.AssertionError, fn -> assert_allocation_fold!(tenant) end
      assert_raise ExUnit.AssertionError, fn -> assert_identities!(tenant, figures(tenant)) end
    after
      Connections.cleanup!(tenant)
      drop_checkpoints!()
      if own?, do: Sandbox.checkin(Connections.repo())
    end
  end

  # -- the generated history --------------------------------------------------

  # 01e's generator, with nothing removed. 06a's cross-oracle has to drop
  # `:reverse` and turn expiry off, because its oracle is a second model of the
  # **runtime**; this unit's oracle is the wallet's own balance row, which knows
  # what really happened whatever it was, so nothing has to be excluded from
  # what is generated. What may be excluded from what is **compared** is the
  # three refusals above, each counted.
  defp legacy_history, do: LedgerCommands.history()

  # -- executing one history against the legacy writer ------------------------

  defp drive(tenant, history) do
    Enum.reduce(history, {0, []}, fn command, {issued, intents} ->
      case issue(tenant, command, intents) do
        :skip -> {issued, intents}
        {:ok, intents} -> {issued + 1, intents}
      end
    end)
    |> elem(0)
  end

  # A paid grant's reference is payment-intent shaped, so a later reversal has
  # something real to name. This is not a fiction: `aurora_meter_pro` grants a
  # payment with the bare PaymentIntent id as the reference, which is exactly
  # the shape the migration parses.
  defp issue(tenant, {:grant, reference, amount, :paid, _expires_at}, intents) do
    intent = "pi_" <> scope(tenant, reference)

    case Credits.grant(tenant, amount, reference: intent) do
      {:ok, txn} -> {:ok, [{intent, txn.amount} | intents]}
      _duplicate_or_error -> {:ok, intents}
    end
  end

  defp issue(tenant, {:grant, reference, amount, category, expires_at}, intents) do
    _ =
      Credits.grant(tenant, amount,
        reference: scope(tenant, reference),
        category: category,
        expires_at: expires_at
      )

    {:ok, intents}
  end

  defp issue(tenant, {:hold, reference, amount}, intents) do
    _ = Credits.hold(tenant, amount, scope(tenant, reference))
    {:ok, intents}
  end

  defp issue(tenant, {:settle, reference, actual}, intents) do
    _ = Credits.settle(scope(tenant, reference), actual)
    {:ok, intents}
  end

  defp issue(tenant, {:release, reference}, intents) do
    _ = Credits.release(scope(tenant, reference))
    {:ok, intents}
  end

  defp issue(tenant, {:debit, reference, amount}, intents) do
    _ = Credits.debit(tenant, amount, scope(tenant, reference))
    {:ok, intents}
  end

  # A reversal before any payment has been recorded, or after every payment has
  # been reversed in full, is skipped rather than issued bare. An unattributable
  # refund is a documented refusal with its own named test; spending a generated
  # history on it would prove nothing this property is for.
  # The amount is capped at what the payment has **left** to give back, which
  # is what `aurora_meter_pro` does: `v1-release.md` 10.1 requires a reversal to
  # be "capped by the actual credited amount after current refund/dispute
  # reconciliation", and Pro's `do_reverse_grant/6` subtracts what previous
  # reversals of the same payment already took. Uncapped, the generator draws
  # refunds larger than the payment they name, which the legacy ledger allows
  # and the lot model refuses; that refusal has its own named test, and
  # spending generated histories on it only shrinks what this property
  # compares.
  defp issue(tenant, {:reverse, reference, amount}, intents) do
    case Enum.split_while(intents, fn {_intent, left} -> left == 0 end) do
      {_spent, []} ->
        :skip

      {spent, [{intent, left} | rest]} ->
        taken = min(amount, left)

        _ =
          Credits.reverse(tenant, taken, "refund:#{intent}:#{scope(tenant, reference)}", %{
            "source" => "refund",
            "payment_intent_id" => intent
          })

        {:ok, spent ++ [{intent, left - taken} | rest]}
    end
  end

  # `Credits.expire_due/1` is not tenant scoped, so a grant belonging to some
  # other tenant would be expired by this history's call. Counting them first
  # turns a leak into a named failure instead of a false disagreement three
  # histories later.
  defp issue(_tenant, {:expire_due, now}, intents) do
    guard_foreign_due!(now)
    _ = Credits.expire_due(now)
    {:ok, intents}
  end

  defp scope(tenant, reference), do: reference <> "_" <> tenant

  defp guard_foreign_due!(now) do
    foreign =
      Connections.repo().aggregate(
        from(t in CreditTransaction,
          join: b in CreditBalance,
          on: b.tenant_key == t.tenant_key,
          where:
            is_nil(b.lots_enabled_at) and t.kind == ^:grant and t.category == ^:promotional and
              not is_nil(t.expires_at) and t.expires_at <= ^now and is_nil(t.expired_at) and
              not like(t.tenant_key, "lotprop%")
        ),
        :count,
        :id
      )

    if foreign > 0 do
      raise "#{foreign} promotional grants belonging to another tenant are due at " <>
              "#{inspect(now)}. `Credits.expire_due/1` is not tenant scoped, so this " <>
              "history's sweep would expire them and every count after it would be wrong."
    end
  end

  # -- the comparison ---------------------------------------------------------

  defp verify!(tenant, history) do
    # Age it to the shape a 0.4.0 database has. Every row written before core
    # schema version 9 carries a null `hold_transaction_id`, and without this
    # `assert_holds_linked!/1` would be asserting against values the legacy
    # writer had already filled in rather than against the backfill.
    LedgerFixtures.age!(tenant)

    before = figures(tenant)
    {:ok, shadow} = LotMigration.run(tenant: tenant, shadow: true)
    report = hd(shadow.reports)

    case report.state do
      :shadow_ok -> compared!(tenant, history, before, report)
      :blocked -> refused!(tenant, history, report)
      other -> flunk(message(tenant, history, "the shadow run said #{inspect(other)}"))
    end
  end

  defp compared!(tenant, history, before, shadow_report) do
    if shadow_report.ordering == :seq, do: bump(:reordered)

    Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)

    try do
      {:ok, real} = LotMigration.run(tenant: tenant, shadow: false, allow_cutover: true)
      report = hd(real.reports)

      unless report.state == :migrated do
        flunk(message(tenant, history, "the real run said #{inspect(report.state)}"))
      end

      # The three figures the legacy ledger produced, unchanged, read back
      # through the public API.
      assert figures(tenant) == before, message(tenant, history, "the money moved")

      # And the same three read straight out of the lots, which is what fails if
      # the fold reconciled the wallet totals with the value in the wrong lots.
      assert_identities!(tenant, before)

      # Each lot's five quantities against a fold of its own allocations.
      assert_allocation_fold!(tenant)

      assert_one_lot_per_grant!(tenant)
      assert_holds_linked!(tenant)

      row = balance_row(tenant)
      assert row.lots_enabled_at, message(tenant, history, "the wallet was not cut over")
      assert row.projection_checked_at, message(tenant, history, "no conservation check ran")
      assert row.debt >= 0 and row.expired >= 0

      bump(:compared)
    after
      Application.delete_env(:aurora_meter_test, :allow_lot_cutover)
    end
  end

  defp refused!(tenant, history, report) do
    blocking = for flag <- report.flags, flag.blocking, do: flag.flag
    unexpected = for flag <- report.flags, flag.blocking, not allowed?(flag), do: flag.flag

    if unexpected != [] do
      detail = for flag <- report.flags, flag.blocking, do: {flag.flag, flag.detail}

      flunk(
        message(
          tenant,
          history,
          "blocked with #{inspect(detail, pretty: true, limit: :infinity)}, which is not one " <>
            "of the documented refusals #{inspect(@refusals)}"
        )
      )
    end

    # A refused wallet is untouched, and that is asserted rather than assumed.
    assert lots(tenant) == []
    assert is_nil(balance_row(tenant).lots_enabled_at)
    bump(:refused)

    report.flags
    |> Enum.filter(& &1.blocking)
    |> Enum.map(&label/1)
    |> Enum.uniq()
    |> Enum.each(&tally/1)
  end

  # `promotional_divergence` has two causes and they are not the same size, so
  # the tally names the row kind that raised it. A `:debit` or `:settle` is the
  # hold-versus-promotional case (finding X263); a `:reverse` is the refund
  # clamp (X257).
  defp label(%{flag: :promotional_divergence, detail: %{kind: kind}}),
    do: :"promotional_divergence_#{kind}"

  defp label(%{flag: flag}), do: flag

  # The one refusal whose legitimacy depends on **why** it fired, not on which
  # flag it is. See `@refusals` and finding X262.
  defp allowed?(%{flag: :hold_unbacked, detail: %{debt: debt}}), do: debt > 0
  defp allowed?(%{flag: flag}), do: flag in @refusals

  defp assert_identities!(tenant, expected) do
    %{rows: [[available, reserved, promotional]]} =
      Connections.repo().query!(
        """
        SELECT coalesce(sum(available), 0)::bigint, coalesce(sum(reserved), 0)::bigint,
               coalesce(sum(available + reserved)
                        FILTER (WHERE category = 'promotional'), 0)::bigint
          FROM aurora_meter_credit_lots WHERE tenant_key = $1
        """,
        [tenant]
      )

    debt = balance_row(tenant).debt

    assert %{
             balance: available + reserved - debt,
             held: reserved,
             promotional: promotional
           } == expected
  end

  # **The direction nothing else in this unit checks.** A lot arrives holding
  # its whole amount as `available`; every allocation moves value from one
  # bucket to another. Folding a lot's own allocations must therefore reproduce
  # the five quantities the lot row carries, and a lot table that disagrees with
  # its allocation trail has destroyed the provenance this unit exists to
  # create while satisfying every total in the wallet.
  defp assert_allocation_fold!(tenant) do
    trail =
      from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: a.seq)
      |> Connections.repo().all()
      |> Enum.group_by(& &1.lot_id)

    for lot <- lots(tenant) do
      folded =
        trail
        |> Map.get(lot.id, [])
        |> Enum.reduce(
          %{available: lot.amount, reserved: 0, consumed: 0, reversed: 0, expired: 0},
          fn allocation, acc ->
            acc
            |> Map.update!(allocation.from_bucket, &(&1 - allocation.amount))
            |> Map.update!(allocation.to_bucket, &(&1 + allocation.amount))
          end
        )

      assert folded ==
               Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]),
             "lot #{lot.reference}: the allocation trail folds to #{inspect(folded)} and the " <>
               "row says #{inspect(Map.take(lot, [:available, :reserved, :consumed, :reversed, :expired]))}"
    end
  end

  defp assert_one_lot_per_grant!(tenant) do
    grants =
      Connections.repo().aggregate(
        from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:grant),
        :count,
        :id
      )

    lots = lots(tenant)
    assert length(lots) == grants
    assert length(lots) == length(Enum.uniq(Enum.map(lots, & &1.grant_transaction_id)))
  end

  defp assert_holds_linked!(tenant) do
    closers =
      Connections.repo().all(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind in [^:settle, ^:release]
        )
      )

    for closer <- closers do
      assert closer.hold_transaction_id, "#{closer.reference} was not linked to its hold"

      hold = Connections.repo().get!(CreditTransaction, closer.hold_transaction_id)
      assert hold.kind == :hold
      assert hold.tenant_key == tenant
      assert hold.reference == closer.reference
    end
  end

  # -- plumbing ---------------------------------------------------------------

  defp figures(tenant) do
    %{balance: balance, held: held, promotional: promotional} = Credits.balance(tenant)
    %{balance: balance, held: held, promotional: promotional}
  end

  defp balance_row(tenant),
    do: Connections.repo().one(from(b in CreditBalance, where: b.tenant_key == ^tenant))

  defp lots(tenant),
    do:
      Connections.repo().all(
        from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: l.seq)
      )

  defp drop_checkpoints! do
    Connections.repo().query!(
      "DELETE FROM aurora_meter_checkpoints WHERE name LIKE 'lot_migration%'",
      []
    )
  end

  defp bump(key) do
    counts = :persistent_term.get(@counts, blank())
    :persistent_term.put(@counts, Map.update!(counts, key, &(&1 + 1)))
  end

  # Which refusals the generator actually produced, so the evidence says what
  # was excluded rather than that something was.
  defp tally(flag) do
    counts = :persistent_term.get(@counts, blank())
    flags = Map.update(counts.flags, flag, 1, &(&1 + 1))
    :persistent_term.put(@counts, %{counts | flags: flags})
  end

  defp blank, do: %{compared: 0, refused: 0, reordered: 0, skipped: 0, flags: %{}}

  # The whole history, in the form `AuroraMeter.CreditsRegressionsTest` replays,
  # so a failure can be reproduced without the seed.
  defp message(tenant, history, what) do
    """
    #{what}

    tenant:  #{tenant}
    history: #{inspect(history, limit: :infinity, pretty: true)}
    """
  end

  # A wallet that predates the lots-on-creation release. See
  # `LedgerFixtures.legacy_wallet!/1`.
  defp legacy_tenant(prefix \\ "lotprop"),
    do: LedgerFixtures.legacy_wallet!(AuroraMeter.Test.unique_tenant(prefix))
end
