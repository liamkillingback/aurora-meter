defmodule AuroraMeter.CreditsNewWalletTest do
  @moduledoc """
  A wallet created after this release is born on the allocator, and a wallet
  that predates it changes only through the explicit migration (repair unit R6,
  `open-findings.md` X380, X283, X255).

  **Why this file exists rather than an assertion added to the lot tests.**
  Every other lot test in this suite calls `Ledger.enable_lots!/1` to get a lot
  wallet, which is a function that is not on the public facade and that a host
  cannot reach. So the whole of phase 06 was proved against a wallet no
  installation could produce: lots, allocation trails, `debt`, `expired`,
  `:debt_outstanding` and the plan DSL's `recurring_credits` were all
  implemented, tested, documented, and unreachable. Nothing in this file calls
  `enable_lots!`, and that absence is the point. A wallet here is created the
  way a host's first `Credits.grant/3` creates one.

  The other half is asserted just as hard: a wallet that already exists is not
  moved by anything. `Ledger.locked_row/2` stamps the flag on an
  `INSERT ... ON CONFLICT DO NOTHING`, so it either creates a wallet or writes
  nothing, and "writes nothing" is what every existing wallet gets. The second
  block drives every writing entry point on the facade over a pre-release
  wallet and asserts the flag is still null at the end of each one.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Lots
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Oban.CreditExpiry
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Test.LedgerFixtures

  @dollar 1_000_000
  @september ~U[2026-09-15 12:00:00Z]
  @october_start ~U[2026-10-01 00:00:00Z]

  # A month start `n` months ahead of today, for a promotional expiry that has
  # to be in the future whenever the suite runs.
  defp month_start_ahead(n) do
    today = Date.utc_today()
    months = today.year * 12 + today.month - 1 + n
    DateTime.new!(Date.new!(div(months, 12), rem(months, 12) + 1, 1), ~T[00:00:00], "Etc/UTC")
  end

  # -- the money, per lot, on a wallet a host could really have ----------------

  test "X380 a wallet created the way a host creates one keeps a per-lot trail through grant, hold, settle and refund" do
    # **The whole walk on one wallet, because the claim is about the trail and
    # not about any single row.** Nothing here enables anything: `tenant` is a
    # string, and the first `grant/3` is what brings the wallet into being.
    tenant = unique_tenant("newwallet")

    # Granted deliberately out of spend order, so the ordering assertion below
    # is about D07's rule and not about insertion order.
    {:ok, _paid_old} =
      Credits.grant(tenant, 10 * @dollar,
        reference: "pi_old",
        source: %{payment_intent_id: "pi_old"}
      )

    {:ok, _} =
      Credits.grant(tenant, 4 * @dollar,
        reference: "promo_late",
        category: :promotional,
        expires_at: month_start_ahead(2)
      )

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "promo_soon",
        category: :promotional,
        expires_at: month_start_ahead(1)
      )

    {:ok, _} =
      Credits.grant(tenant, 5 * @dollar,
        reference: "pi_new",
        source: %{payment_intent_id: "pi_new"}
      )

    assert balance_row(tenant).lots_enabled_at, "the wallet was not born on the allocator"

    # (1) There are lots at all, one per grant, which is what X380 (1) says
    # there are none of.
    assert length(Lots.list(tenant)) == 4

    # (2) **D07's credit priority, observable.** Promotional before paid,
    # earliest expiry first within a category, then the oldest paid grant.
    assert Enum.map(Lots.list(tenant), & &1.reference) ==
             ["promo_soon", "promo_late", "pi_old", "pi_new"]

    # (3) And it is the order a real spend takes, which is the claim the
    # ordering makes. 5 USD drains `promo_soon` (3) and reaches 2 into
    # `promo_late`.
    {:ok, hold} = Credits.hold(tenant, 5 * @dollar, "job")
    assert Lots.get(tenant, "promo_soon").reserved == 3 * @dollar
    assert Lots.get(tenant, "promo_late").reserved == 2 * @dollar
    assert Lots.get(tenant, "pi_old").reserved == 0

    # (4) The settle costs less than the hold: the reservation is consumed and
    # the remainder handed back, per lot.
    {:ok, settle} = Credits.settle("job", 4 * @dollar)

    assert %{consumed: 3_000_000, reserved: 0, available: 0} =
             buckets(Lots.get(tenant, "promo_soon"))

    assert %{consumed: 1_000_000, reserved: 0, available: 3_000_000} =
             buckets(Lots.get(tenant, "promo_late"))

    # (5) **The allocation trail exists and names the row that caused each
    # movement**, which is X380 (2): today there is no trail at all.
    trail = Lots.allocations(tenant, reference: "job")

    assert Enum.map(trail, &{&1.kind, &1.amount, &1.transaction_id}) == [
             {:reserve, 3 * @dollar, hold.id},
             {:reserve, 2 * @dollar, hold.id},
             {:consume, 3 * @dollar, settle.id},
             {:consume, 1 * @dollar, settle.id},
             {:unreserve, 1 * @dollar, settle.id}
           ]

    # (6) A refund of one payment finds the lot that payment funded and leaves
    # the promotional lots alone (`architecture-map.md` 7.2).
    promotional_before =
      Enum.map(["promo_soon", "promo_late"], &buckets(Lots.get(tenant, &1)))

    assert {:ok, _} =
             Credits.reverse_lot(tenant, 6 * @dollar, "refund:pi_old:600",
               source: %{payment_intent_id: "pi_old"}
             )

    assert Lots.get(tenant, "pi_old").reversed == 6 * @dollar
    assert Lots.get(tenant, "pi_old").available == 4 * @dollar
    assert Lots.get(tenant, "pi_new").reversed == 0

    assert Enum.map(["promo_soon", "promo_late"], &buckets(Lots.get(tenant, &1))) ==
             promotional_before

    assert Enum.any?(Lots.allocations(tenant), &(&1.kind == :reverse))

    # (7) The refund found enough availability, so it created no debt, and the
    # lots still project the balance row exactly.
    row = balance_row(tenant)
    lots = lots(tenant)
    assert row.debt == 0

    assert row.balance ==
             Enum.reduce(lots, 0, &(&1.available + &1.reserved + &2)) - row.debt

    assert row.held == Enum.reduce(lots, 0, &(&1.reserved + &2))
  end

  test "X380 the same walk on a wallet that predates the release produces no lot and no allocation" do
    # **The before half, and it is what makes the test above mean something.**
    # Identical script, one difference: the wallet existed already. Every
    # assertion the test above makes is unavailable here, which is precisely
    # what X380 reported for every wallet on every installation.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("newwallet"))

    {:ok, _} =
      Credits.grant(tenant, 10 * @dollar,
        reference: "old_pi_old",
        source: %{payment_intent_id: "old_pi_old"}
      )

    {:ok, _} =
      Credits.grant(tenant, 3 * @dollar,
        reference: "old_promo",
        category: :promotional,
        expires_at: month_start_ahead(1)
      )

    {:ok, _} = Credits.hold(tenant, 5 * @dollar, "old_job")
    {:ok, _} = Credits.settle("old_job", 4 * @dollar)

    assert is_nil(balance_row(tenant).lots_enabled_at)
    assert Lots.list(tenant) == []
    assert Lots.allocations(tenant) == []
    assert lots(tenant) == []
    assert allocations(tenant) == []

    # The money is still right; it is the provenance that is missing.
    assert Credits.balance(tenant).balance == 9 * @dollar
  end

  # -- the half the decision rests on ------------------------------------------

  test "X283 no path but creation touches an existing wallet's lots_enabled_at" do
    # **The property the decision stands or falls on.** `locked_row/2` is on
    # every writing path in the ledger, so if the stamp could reach a wallet
    # that already exists, an installation's population would move under it on
    # `mix deps.update`, which is exactly what 06b, 06e and repair unit R1
    # refused to do and were right to refuse.
    #
    # Every writing entry point on the facade is driven over one pre-release
    # wallet, and the flag is re-read after each. `on_conflict: :nothing` is
    # what makes this hold, and a change that swapped it for an upsert would
    # fail here rather than in production.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("newwallet"))
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    steps = [
      {"grant", fn -> Credits.grant(tenant, 10 * @dollar, reference: "u_grant") end},
      {"hold", fn -> Credits.hold(tenant, 2 * @dollar, "u_hold") end},
      {"settle", fn -> Credits.settle("u_hold", @dollar) end},
      {"hold again", fn -> Credits.hold(tenant, @dollar, "u_hold2") end},
      {"release", fn -> Credits.release("u_hold2") end},
      {"debit", fn -> Credits.debit(tenant, @dollar, "u_debit") end},
      {"reverse", fn -> Credits.reverse(tenant, @dollar, "u_reverse") end},
      {"threshold", fn -> Credits.set_low_balance_threshold(tenant, @dollar) end},
      {"balance", fn -> Credits.balance(tenant) end},
      {"history", fn -> Credits.history(tenant) end},
      {"summary", fn -> Credits.summary(tenant) end},
      {"expiring grant",
       fn ->
         Credits.grant(tenant, @dollar,
           reference: "u_promo",
           category: :promotional,
           expires_at: past
         )
       end},
      {"expire_due", fn -> Credits.expire_due() end},
      {"reconcile_holds",
       fn ->
         Credits.reconcile_holds(
           tenant: tenant,
           older_than: DateTime.add(DateTime.utc_now(), 60, :second)
         )
       end},
      {"recurrences", fn -> Recurrences.run(tenant: tenant) end}
    ]

    for {name, step} <- steps do
      step.()

      assert is_nil(balance_row(tenant).lots_enabled_at),
             "#{name} moved an existing wallet onto the allocator"

      assert lots(tenant) == [], "#{name} wrote a lot on an existing wallet"
      assert allocations(tenant) == [], "#{name} wrote an allocation on an existing wallet"
    end

    # And the migration is still the only door: after all of that the wallet is
    # exactly where it started.
    assert is_nil(balance_row(tenant).lots_enabled_at)
  end

  test "X283 a wallet created before this release and one created after it coexist" do
    # The split population the decision accepts, asserted rather than assumed,
    # because it is what `docs/upgrading-to-lots.md` now has to explain to a
    # host who will meet both in one database.
    before = LedgerFixtures.legacy_wallet!(unique_tenant("newwallet"))
    later = unique_tenant("newwallet")

    {:ok, _} = Credits.grant(before, 5 * @dollar, reference: "split_before")
    {:ok, _} = Credits.grant(later, 5 * @dollar, reference: "split_after")

    assert is_nil(balance_row(before).lots_enabled_at)
    assert balance_row(later).lots_enabled_at

    assert Lots.list(before) == []
    assert [%{reference: "split_after"}] = Lots.list(later)

    # Same money, different provenance, which is the whole of the difference.
    assert Credits.balance(before).balance == Credits.balance(later).balance
  end

  # -- what the decision makes reachable ---------------------------------------

  test "X380 recurring_credits grants a real allowance to a wallet nobody enabled anything on" do
    # **X380 (7), which is the most visible consequence of the decision.**
    # `Recurrences` scans only wallets whose `lots_enabled_at` is set
    # (`recurrences.ex:844`), so before this change a plan that declared a
    # monthly allowance granted nothing at all, for ever, on every
    # installation. Nothing here enables lots.
    tenant = unique_tenant("newwallet")
    AuroraMeter.subscribe(tenant, :allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 1
      assert summary.counts["amount"] == 5 * @dollar
    end)

    assert [lot] = lots(tenant)
    assert lot.amount == 5 * @dollar
    assert lot.available == 5 * @dollar
    assert lot.category == :promotional
    assert lot.expires_at == @october_start

    # And the allowance is spendable, which is the difference between a row and
    # a feature. Read inside the period it was granted for: the lot expires at
    # @october_start, so after that date it is correctly no longer spendable.
    with_clock(DateTime.add(@september, 3_600, :second), fn ->
      assert Credits.balance(tenant).spendable == 5 * @dollar
      assert {:ok, _} = Credits.debit(tenant, 2 * @dollar, "spend_allowance")
    end)

    assert Lots.get(tenant, lot.reference).consumed == 2 * @dollar
  end

  test "X380 a recurring allowance reaches nothing on a wallet that predates the release" do
    # The control for the test above, and the state every installation was in.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("newwallet"))
    AuroraMeter.subscribe(tenant, :allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 0
    end)

    assert lots(tenant) == []
    assert Credits.balance(tenant).available == 0
  end

  test "X380 debt, expired and the :debt_outstanding refusal are reachable on a new wallet" do
    # X380 (4), (5) and (6): three figures that were permanently zero and one
    # refusal term no installation could produce. Repair unit R3's honest
    # figures and X361's owner decision are both about this state.
    tenant = unique_tenant("newwallet")
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, _} = Credits.grant(tenant, 2 * @dollar, reference: "debt_paid")
    {:ok, _} = Credits.hold(tenant, 2 * @dollar, "debt_job")
    {:ok, _} = Credits.settle("debt_job", 5 * @dollar)

    figures = Credits.balance(tenant)
    assert figures.debt == 3 * @dollar

    # `spendable` is `min(available - debt, 0)` while a debt stands
    # (`Allocator.spendable_figure/2`), so an underwater wallet reports what it
    # owes rather than a cheerful zero. Nothing is spendable either way, which
    # is the assertion that matters and is made by the refusals below.
    assert figures.spendable == -3 * @dollar
    assert figures.promotional_spendable == 0

    # The refusal names the debt rather than blaming the balance.
    assert {:error, :debt_outstanding} = Credits.hold(tenant, 1, "debt_after")
    assert {:error, :debt_outstanding} = Credits.debit(tenant, 1, "debt_after")

    # A grant of any category is the way out, and it is the only one.
    {:ok, _} = Credits.grant(tenant, 3 * @dollar, reference: "debt_topup")
    assert Credits.balance(tenant).debt == 0

    # And `expired` moves too, on a second wallet so the debt above cannot be
    # what is being measured.
    other = unique_tenant("newwallet")

    {:ok, _} =
      Credits.grant(other, @dollar,
        reference: "expired_promo",
        category: :promotional,
        expires_at: past
      )

    assert {:ok, _} = Credits.expire_due()
    assert Credits.balance(other).expired == @dollar
  end

  test "X384 a bounded expiry page over a new wallet's lots carries a cursor, and paging drains every due lot" do
    # `Ledger.expire_due/2` runs in two phases: the legacy grant scan and then
    # the lot phase, which every wallet created since 1.0 goes through. The lot
    # phase used to carry no cursor, so a bounded page that filled up there
    # returned `cursor: nil` with due lots still open, and
    # `AuroraMeter.Oban.CreditExpiry`, which pages until the cursor is nil,
    # reported `stopped: :complete` after one batch. It now carries
    # `{:lots, expires_at, id}` and the next page resumes from it.
    tenant = unique_tenant("newwallet")
    past = DateTime.add(DateTime.utc_now(), -1, :day)

    for n <- 1..6 do
      {:ok, _} =
        Credits.grant(tenant, @dollar,
          reference: "x384_#{n}_#{tenant}",
          category: :promotional,
          expires_at: past
        )
    end

    assert length(lots(tenant)) == 6
    now = DateTime.utc_now()

    # A page bounded at two examines two, expires two, and says more is waiting.
    assert {:ok, first} = Credits.expire_due(now, limit: 2)
    assert first.examined == 2
    assert first.expired == 2
    assert {:lots, %DateTime{}, _id} = first.cursor
    assert Enum.count(lots(tenant), &(&1.state == :open)) == 4

    # Paging with the same pinned instant drains the rest, page by page, and
    # the scan ends with a nil cursor only when nothing due is left.
    pages = page_until_done(now, first.cursor, 1)
    assert pages == 4

    assert Enum.all?(lots(tenant), &(&1.state == :expired))
    assert Credits.balance(tenant).expired == 6 * @dollar
  end

  test "X384 a page that fills up exactly at the end of the grant phase hands the lot phase on" do
    legacy = LedgerFixtures.legacy_wallet!(unique_tenant("newwallet_legacy"))
    fresh = unique_tenant("newwallet_fresh")
    past = DateTime.add(DateTime.utc_now(), -1, :day)

    {:ok, _} =
      Credits.grant(legacy, @dollar,
        reference: "x384_legacy_#{legacy}",
        category: :promotional,
        expires_at: past
      )

    {:ok, _} =
      Credits.grant(fresh, @dollar,
        reference: "x384_fresh_#{fresh}",
        category: :promotional,
        expires_at: past
      )

    now = DateTime.utc_now()
    {:ok, first} = Credits.expire_due(now, limit: 1, after: nil)

    # Whatever the first page covered, paging to the end expires both wallets.
    page_until_done(now, first.cursor, 1)

    # A legacy wallet records expiry on the grant row; its promotional
    # remainder is what goes. A new wallet reports it as `expired`.
    assert Credits.balance(legacy).promotional == 0
    assert Credits.balance(legacy).balance == 0
    assert Credits.balance(fresh).expired == @dollar
  end

  if Code.ensure_loaded?(AuroraMeter.Oban.CreditExpiry) do
    test "X384 the expiry worker pages through a new wallet's lots and reports complete only at the end" do
      tenant = unique_tenant("newwallet")
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      for n <- 1..5 do
        {:ok, _} =
          Credits.grant(tenant, @dollar,
            reference: "x384_worker_#{n}_#{tenant}",
            category: :promotional,
            expires_at: past
          )
      end

      job = %Oban.Job{args: %{"batch_size" => 2, "max_batches" => 10}}
      assert {:ok, report} = CreditExpiry.perform(job)

      # Two, two and one: three batches, and `:complete` only after the third.
      assert report.counts["expired"] == 5
      assert report.stopped == :complete
      assert report.batches >= 3
      assert Enum.all?(lots(tenant), &(&1.state == :expired))
    end
  end

  defp page_until_done(_now, nil, pages), do: pages

  defp page_until_done(now, cursor, pages) do
    {:ok, report} = Credits.expire_due(now, limit: 2, after: cursor)
    if report.examined == 0, do: assert(is_nil(report.cursor))
    page_until_done(now, report.cursor, pages + 1)
  end

  # -- helpers -----------------------------------------------------------------

  defp balance_row(tenant), do: TestRepo.get_by(CreditBalance, tenant_key: tenant)

  defp lots(tenant) do
    import Ecto.Query, only: [from: 2]
    TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: l.seq))
  end

  defp allocations(tenant) do
    import Ecto.Query, only: [from: 2]
    TestRepo.all(from(a in CreditAllocation, where: a.tenant_key == ^tenant, order_by: a.seq))
  end

  defp buckets(lot), do: Map.take(lot, [:available, :reserved, :consumed])
end
