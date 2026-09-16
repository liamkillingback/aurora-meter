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
  alias AuroraMeter.Config
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Schema.CreditLot
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

    # **The refusal names the debt** (repair unit R3, findings X357 and X361).
    # It was `:insufficient_credits` until R3, which is the same word the
    # ledger uses for a wallet that was never funded, so a host could not tell
    # "top this up" from "this is frozen until the debt clears" and a support
    # agent went looking for a grant that is not missing.
    assert {:error, :debt_outstanding} = Credits.debit(tenant, 1, "after-debt")
    assert {:error, :debt_outstanding} = Credits.hold(tenant, 1, "after-debt-hold")

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
    check all(
            commands <- history(),
            finisher <- StreamData.member_of([:fund, :freeze, :drain]),
            max_runs: 40
          ) do
      tenant = lot_wallet()
      Enum.each(commands, &execute(tenant, &1))
      finish(tenant, finisher)

      summary = Credits.summary(tenant)
      snapshot = Credits.balance(tenant)
      truth = from_lots(tenant)

      # **Both figures answer a question about the planner, so the lots alone
      # do not settle them** (repair unit R3, findings X357 and X361). While a
      # debt stands, `hold/4` and `debit/4` refuse before they look at a lot,
      # so neither figure may be positive however much availability the lots
      # hold. `from_lots/1` recomputes the raw aggregates in SQL and the rule
      # is applied to them here; the assertion that the rule is the **planner's**
      # is `planner_agrees!/1` below, which attempts the figure rather than
      # restating it.
      expected_spendable =
        if truth.debt > 0,
          do: min(truth.eligible_available - truth.debt, 0),
          else: truth.eligible_available

      expected_promotional = if truth.debt > 0, do: 0, else: truth.promotional_available

      assert summary.spendable == expected_spendable, "#{tenant}: #{inspect(commands)}"

      assert summary.promotional_spendable == expected_promotional,
             "#{tenant}: #{inspect(commands)}"

      # And the figures agree with what the ledger will actually do, on every
      # generated wallet rather than on the ones this file names.
      bump({__MODULE__, :property_branches, planner_agrees!(tenant)})

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

    # **Which shapes the generated wallets actually reached**, asserted rather
    # than hoped for (X125, X325, X350, and 06a's own `book_generator/0` hole
    # X360). A run in which no generated history ever ended in debt would be
    # green and would have said nothing at all about the figure this unit
    # repairs, and the first version of this assertion failed at two seeds in
    # ten for exactly that reason, which is why `finish/2` exists: the generated
    # history is still the body of the case, and the finisher makes the state it
    # ends in something the counter can rely on.
    for branch <- [:spendable, :frozen, :empty] do
      assert Process.get({__MODULE__, :property_branches, branch}, 0) > 0,
             "no generated history left the wallet in the #{branch} state, so the " <>
               "figure/planner agreement was never checked there"
    end
  end

  test "X361 a refund the wallet cannot cover reports nothing spendable, names the debt and clears on a grant" do
    # **The state forced, not described** (findings X357 and X361). A wallet
    # with a promotion and an open hold takes a refund larger than the paid
    # credit it has left. Repair unit R1 made the reversal spare the promotion
    # and repair unit R2 stopped the next event repaying the debt out of it, so
    # after both the wallet sits on promotional credit, owes money, and refuses
    # everything. Until R3 it also **advertised** that credit as spendable.
    tenant = refunded_wallet_before_refund()

    before = Credits.balance(tenant)

    assert before.balance == 9 * @dollar
    assert before.held == 3 * @dollar
    assert before.available == 6 * @dollar
    assert before.spendable == 6 * @dollar
    assert before.promotional == 8 * @dollar
    assert before.promotional_spendable == 5 * @dollar
    assert before.debt == 0
    assert before.expired == 0
    assert planner_agrees!(tenant) == :spendable

    # Read after `planner_agrees!/1`, which holds and releases: the claim below
    # is that the **refund** does not move this lot, so the row it is compared
    # against has to be the one the refund started from.
    promo_before = lot(tenant, named(tenant, "promo"))

    # 5 USD back to the payment provider. The paid lot has 1 USD left and 9 USD
    # already spent, so one comes out of `available`, four out of `consumed`,
    # and four become debt.
    {:ok, _} = Credits.reverse(tenant, 5 * @dollar, named(tenant, "refund"))

    assert lot(tenant, named(tenant, "pay")).available == 0
    assert lot(tenant, named(tenant, "pay")).consumed == 5 * @dollar
    assert lot(tenant, named(tenant, "pay")).reversed == 5 * @dollar
    # R1 and R2's promise, restated here because it is the reason the figures
    # can lie at all: the promotion is byte identical, `updated_at` included.
    assert lot(tenant, named(tenant, "promo")) == promo_before

    after_refund = Credits.balance(tenant)

    # **Field by field.** The four that report what the wallet holds or owes
    # are unchanged in meaning and still report the total.
    assert after_refund.balance == 4 * @dollar
    assert after_refund.held == 3 * @dollar
    assert after_refund.available == 1 * @dollar
    assert after_refund.promotional == 8 * @dollar
    assert after_refund.debt == 4 * @dollar
    assert after_refund.expired == 0

    # **And the two that claim spendability report what the planner will
    # accept, which is nothing.** Before R3 they read `spendable: 1_000_000`
    # and `promotional_spendable: 5_000_000`, both positive, beside a positive
    # debt and a ledger that refused every hold and every debit.
    assert after_refund.spendable == 0
    assert after_refund.promotional_spendable == 0
    refute Credits.sufficient?(tenant, 1)

    # The refusal names the debt rather than blaming the balance.
    assert {:error, :debt_outstanding} = Credits.hold(tenant, 1, "h-after")
    assert {:error, :debt_outstanding} = Credits.debit(tenant, 1, "d-after")
    assert planner_agrees!(tenant) == :frozen

    # `summary/1` is built from `balance/1`, so the dashboard reads the same
    # thing the API does.
    summary = Credits.summary(tenant)
    assert summary.spendable == 0
    assert summary.promotional_spendable == 0
    assert summary.debt == 4 * @dollar
    assert summary.promotional == 8 * @dollar

    # **The way out, which is what a host has to be able to tell a customer.**
    # A grant of any category repays the debt out of the lot it is creating,
    # and the promotion that was standing beside it is spendable, whole.
    {:ok, _} = Credits.grant(tenant, 4 * @dollar, reference: named(tenant, "top_up"))

    cleared = Credits.balance(tenant)
    assert cleared.debt == 0
    assert cleared.promotional == 8 * @dollar
    assert cleared.spendable == 5 * @dollar
    assert cleared.promotional_spendable == 5 * @dollar
    assert lot(tenant, named(tenant, "promo")) == promo_before
    assert lot(tenant, named(tenant, "top_up")).consumed == 4 * @dollar
    assert planner_agrees!(tenant) == :spendable
  end

  test "X361 the figures and the planner agree in every state a wallet can be in" do
    # **The assertion that carries this unit, table driven so it covers the
    # states rather than one of them.** Every case reads a figure and then
    # attempts exactly that amount; none of them compares a figure with a
    # number written here, so a future change that made `spendable` wrong in a
    # new way would have to make `hold/4` wrong in the same way to get past it.
    cases = [
      {:healthy_mixed, &mixed_wallet/0, :spendable},
      {:promotional_only, &promotional_wallet/0, :spendable},
      {:frozen_with_credit, &refunded_wallet/0, :frozen},
      {:frozen_underwater, &overrun_wallet/0, :frozen},
      {:expired_only, &expired_wallet/0, :empty},
      {:legacy_funded, &legacy_wallet/0, :spendable},
      {:legacy_overrun, &legacy_overrun_wallet/0, :empty},
      {:never_funded, fn -> unique_tenant("figures") end, :empty}
    ]

    reached =
      for {name, build, expected_branch} <- cases, into: %{} do
        tenant = build.()
        branch = planner_agrees!(tenant)

        assert branch == expected_branch,
               "#{name}: expected the wallet to be #{expected_branch} and it was #{branch}, " <>
                 "figures #{inspect(Credits.balance(tenant))}"

        {name, branch}
      end

    # **The cases reach the shapes this test is about**, counted rather than
    # assumed: a table whose rows all landed in one branch would pass and would
    # have tested one state eight times (X125, X350).
    counts = reached |> Map.values() |> Enum.frequencies()
    assert Map.get(counts, :spendable, 0) >= 3
    assert Map.get(counts, :frozen, 0) >= 2
    assert Map.get(counts, :empty, 0) >= 3

    # And the one shape the whole unit exists for: a wallet reporting money it
    # holds, beside a debt, spending none of it. Asserted on the figures rather
    # than on the builder, so it stays true if the builder changes.
    frozen = Credits.balance(refunded_wallet())
    assert frozen.balance > 0
    assert frozen.promotional > 0
    assert frozen.debt > 0
    assert frozen.spendable == 0
    assert frozen.promotional_spendable == 0
  end

  # **The figure and the planner, compared by attempting the figure.** This is
  # the anti-drift assertion for findings X357 and X361: `spendable` is
  # documented as "what a hold or a debit would actually be allowed to take",
  # so the test takes it at its word and takes exactly that much. It returns
  # the branch it exercised, because a caller has to be able to assert that its
  # cases reached the state it thinks they did.
  defp planner_agrees!(tenant) do
    snapshot = Credits.balance(tenant)
    tolerance = Config.credits_overdraft_tolerance()

    # A part cannot be larger than the whole it is a part of.
    assert snapshot.promotional_spendable <= max(snapshot.spendable, 0),
           "#{tenant}: promotional_spendable #{snapshot.promotional_spendable} is larger " <>
             "than spendable #{snapshot.spendable}"

    branch =
      if snapshot.spendable > 0 do
        # A wallet that may spend owes nothing: the planner refuses outright
        # while `debt > 0`, so a positive spendable figure beside a debt is
        # precisely the lie R3 closes.
        assert snapshot.debt == 0, "#{tenant}: spendable is positive beside a debt"

        # One micro-dollar more than was advertised is refused ...
        assert {:error, :insufficient_credits} =
                 Credits.hold(tenant, snapshot.spendable + tolerance + 1, ref())

        # ... and exactly what was advertised is accepted.
        reference = ref()
        assert {:ok, _} = Credits.hold(tenant, snapshot.spendable, reference)

        if snapshot.promotional_spendable > 0 and lots?(tenant) do
          # Spend order takes promotional credit first, so a hold of everything
          # spendable reserves every promotional micro-dollar that was
          # spendable, which is what "the part of `spendable` that came from
          # promotional lots" means.
          assert Credits.balance(tenant).promotional_spendable == 0
        end

        {:ok, _} = Credits.release(reference)
        :spendable
      else
        assert {:error, hold_reason} = Credits.hold(tenant, 1, ref())
        assert {:error, debit_reason} = Credits.debit(tenant, 1, ref())
        assert hold_reason == debit_reason

        expected = if snapshot.debt > 0, do: :debt_outstanding, else: :insufficient_credits

        assert hold_reason == expected,
               "#{tenant}: a wallet with debt #{snapshot.debt} refused with " <>
                 "#{inspect(hold_reason)} and should have refused with #{inspect(expected)}"

        if snapshot.debt > 0, do: :frozen, else: :empty
      end

    # The advisory figure `sufficient?/2` reports agrees with both.
    assert Credits.sufficient?(tenant, max(snapshot.spendable, 1)) ==
             snapshot.spendable > 0

    branch
  end

  defp ref, do: "r3:#{System.unique_integer([:positive])}"

  defp lots?(tenant) do
    match?(%{lots_enabled_at: %DateTime{}}, Ledger.fetch(tenant))
  end

  defp bump(key), do: Process.put(key, Process.get(key, 0) + 1)

  # `aurora_meter_credit_transactions` is unique on `(kind, reference)` across
  # **every** tenant, so a builder that used a bare "promo" would collide with
  # the next wallet this file builds rather than with anything it is testing.
  defp named(tenant, name), do: "#{tenant}:#{name}"

  defp mixed_wallet do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 10 * @dollar, reference: named(tenant, "paid"))

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: named(tenant, "promo"),
        category: :promotional
      )

    {:ok, _} = Credits.hold(tenant, 3 * @dollar, named(tenant, "job"))
    tenant
  end

  defp promotional_wallet do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: named(tenant, "promo"),
        category: :promotional
      )

    tenant
  end

  # The X361 wallet: a refund larger than the paid credit left, with a
  # promotion standing beside the debt it creates.
  defp refunded_wallet do
    tenant = refunded_wallet_before_refund()
    {:ok, _} = Credits.reverse(tenant, 5 * @dollar, named(tenant, "refund"))
    tenant
  end

  defp refunded_wallet_before_refund do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 10 * @dollar,
        reference: named(tenant, "pay"),
        source: %{payment_intent_id: "pi_r3"}
      )

    {:ok, _} = Credits.debit(tenant, 9 * @dollar, named(tenant, "spend"))

    {:ok, _} =
      Credits.grant(tenant, 8 * @dollar,
        reference: named(tenant, "promo"),
        category: :promotional
      )

    # Spend order reserves the promotion first, which is what makes this an
    # ordinary wallet rather than a contrived one.
    {:ok, _} = Credits.hold(tenant, 3 * @dollar, named(tenant, "job"))
    tenant
  end

  # Debt with nothing left beside it, so `spendable` is negative rather than
  # zero: the figure is capped at what the planner accepts, not clamped.
  defp overrun_wallet do
    tenant = lot_wallet()
    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: named(tenant, "paid"))
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, named(tenant, "job"))
    {:ok, _} = Credits.settle(named(tenant, "job"), 5 * @dollar)
    tenant
  end

  # Refused, and **not** for the debt: the other refusal keeps its own word.
  defp expired_wallet do
    tenant = lot_wallet()

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: named(tenant, "stale"),
        category: :promotional,
        expires_at: @past
      )

    tenant
  end

  defp legacy_wallet do
    tenant = unique_tenant("figures")
    {:ok, _} = Credits.grant(tenant, 5 * @dollar, reference: named(tenant, "paid"))
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, named(tenant, "job"))
    tenant
  end

  # A legacy wallet can go negative without any `debt` at all, and it must go
  # on refusing with `:insufficient_credits`: no wallet a published version can
  # produce sees the new atom.
  defp legacy_overrun_wallet do
    tenant = unique_tenant("figures")
    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: named(tenant, "paid"))
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, named(tenant, "job"))
    {:ok, _} = Credits.settle(named(tenant, "job"), 5 * @dollar)
    tenant
  end

  defp lot(tenant, reference) do
    import Ecto.Query, only: [from: 2]

    TestRepo.one(
      from(l in CreditLot, where: l.tenant_key == ^tenant and l.reference == ^reference)
    )
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
      eligible_available: available,
      promotional_available: promotional_available,
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
        StreamData.constant({:overrun, 0}),
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

  # **`:overrun` is repair unit R3's, and it closed a hole the same shape as
  # X360's.** Every other command settles at or below its hold, no reversal is
  # generated, and a refused debit writes nothing, so **no generated history
  # could put a wallet into debt**: `truth.debt` was zero in every case this
  # property has ever run, and every assertion it makes about `debt` and about
  # what a debt does to `spendable` was comparing zero with zero. A settlement
  # far above its reservation is the cheapest command that reaches the state.
  defp execute(tenant, {:overrun, _}) do
    case open_hold(tenant) do
      nil -> :ok
      hold -> Credits.settle(hold.reference, hold.held_delta + 50 * @dollar)
    end
  end

  defp execute(_tenant, {:expire, _}), do: Credits.expire_due(Clock.db_now())

  # **Three finishers, each of which puts the wallet into one of the three
  # states `planner_agrees!/1` distinguishes, whatever the generated history
  # did.** The history decides what the wallet is made of; the finisher decides
  # which of the three shapes it ends in, so the counters below the property are
  # a statement about coverage rather than a wish.
  #
  # `:freeze` is the one that matters and it is deliberately not an overrun: it
  # grants a live promotion and then refunds more than every non-promotional
  # micro-dollar the generator can produce (twelve commands of at most 5 USD,
  # so 100 USD always exceeds it), which leaves a debt beside promotional
  # credit that survives it. That is the X357 wallet, reached from a generated
  # history rather than from a fixture.
  defp finish(tenant, :fund) do
    {:ok, _} =
      Credits.grant(tenant, current_debt(tenant) + 7 * @dollar, reference: reference(tenant))

    :ok
  end

  defp finish(tenant, :freeze) do
    {:ok, _} =
      Credits.grant(tenant, 6 * @dollar,
        reference: reference(tenant),
        category: :promotional,
        expires_at: ~U[2099-01-01 00:00:00Z]
      )

    {:ok, _} = Credits.reverse(tenant, 100 * @dollar, reference(tenant))
    :ok
  end

  defp finish(tenant, :drain) do
    debt = current_debt(tenant)
    if debt > 0, do: {:ok, _} = Credits.grant(tenant, debt, reference: reference(tenant))

    spendable = Credits.balance(tenant).spendable
    if spendable > 0, do: {:ok, _} = Credits.debit(tenant, spendable, reference(tenant))
    :ok
  end

  defp current_debt(tenant) do
    case Ledger.fetch(tenant) do
      nil -> 0
      row -> row.debt
    end
  end

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
