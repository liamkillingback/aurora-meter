defmodule AuroraMeter.CreditsRecurrencesTest do
  @moduledoc """
  Recurring allowances, capped rollover and downtime catch-up (build unit 06d,
  V1 task 06.05, gate G06 bullet 6).

  `async: false`: every test here freezes the node-wide clock, because a period
  boundary is the subject and a test that cannot stand on either side of one
  proves nothing about it.

  Two rules the programme learned the hard way apply throughout.

  **Know which assertion carries the claim** (findings X242, X251, X254). A
  conservation check and a balance total are both satisfied by a wrong rollover:
  5,000,000 granted and 5,000,000 destroyed conserves exactly as well as
  5,000,000 granted, 1,000,000 carried and 4,000,000 destroyed. So every
  rollover test asserts the **carried lot's own amount** and the previous lot's
  buckets, which are the numbers a wrong cap moves.

  **A criterion is about a branch that runs** (X211, X155). The plan-edit test
  changes the cap as well as the amount, because the amount alone cannot
  discriminate: the row and the grant commit together, so a retry can never
  re-grant whatever it reads. The cap can, and does.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2, travel: 1]

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Operations
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditRecurrence
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Storage
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.LedgerFixtures
  alias AuroraMeter.Test.PeriodSources

  doctest AuroraMeter.Schema.CreditRecurrence

  @dollar 1_000_000
  @allowance 5 * @dollar
  @cap 1 * @dollar

  @june ~U[2026-06-15 12:00:00Z]
  @august ~U[2026-08-15 12:00:00Z]
  @september ~U[2026-09-15 12:00:00Z]
  @october ~U[2026-10-15 12:00:00Z]

  @september_start ~U[2026-09-01 00:00:00Z]
  @october_start ~U[2026-10-01 00:00:00Z]

  setup do
    on_exit(fn -> Operations.resume(Recurrences.operation()) end)
    :ok
  end

  # -- one live period ---------------------------------------------------------

  test "I18 one run grants one lot per entitled tenant for the current period" do
    tenant = tenant(:allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 1
      assert summary.counts["amount"] == @allowance
      assert summary.counts["rollover"] == 0
      refute summary.paused
    end)

    assert [lot] = lots(tenant)
    assert lot.amount == @allowance
    assert lot.available == @allowance
    assert lot.category == :promotional
    assert lot.expires_at == @october_start
    assert lot.state == :open

    assert [recurrence] = recurrences(tenant)
    assert recurrence.key == "recurring:monthly:allowance:1:2026-09-01T00:00:00Z"
    assert recurrence.state == :granted
    assert recurrence.period_start == @september_start
    assert recurrence.rollover_from_id == nil

    assert recurrence.policy == %{
             "amount" => @allowance,
             "category" => "promotional",
             "rollover" => @cap,
             "expires" => "period_end"
           }

    # The ledger row the recurrence names, and its reference. The key is unique
    # per tenant; the reference cannot be, because the ledger's index is global.
    assert [grant] = transactions(tenant, :grant)
    assert grant.id == recurrence.granted_transaction_id
    assert grant.amount == @allowance
    assert grant.reference == "recurring:#{tenant}:monthly:allowance:1:2026-09-01T00:00:00Z"
    assert grant.metadata["recurrence"] == "monthly"

    assert Credits.balance(tenant).available == @allowance
  end

  test "I18 two tenants on one plan reach the same period without colliding" do
    # The reference is the ledger's idempotency key and
    # `aurora_meter_credit_transactions` is UNIQUE (kind, reference) across every
    # tenant in the installation (open-findings.md X273). With the recurrence key
    # used as the reference, as the build document specified, the second tenant's
    # grant is refused as a duplicate of the first tenant's.
    a = tenant(:allowance)
    b = tenant(:allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: [a, b])
      assert summary.counts["granted"] == 2
      assert summary.counts["failed"] == 0
    end)

    assert [lot_a] = lots(a)
    assert [lot_b] = lots(b)
    assert lot_a.amount == @allowance and lot_b.amount == @allowance
    assert lot_a.reference != lot_b.reference

    # And both recurrence rows carry the same key, which is what makes
    # `UNIQUE (tenant_key, key)` the right index for it.
    assert [%{key: key}] = recurrences(a)
    assert [%{key: ^key}] = recurrences(b)
  end

  test "I18 running the job five times in one period produces one grant and four duplicates" do
    tenant = tenant(:allowance)

    results =
      with_clock(@september, fn ->
        for _ <- 1..5 do
          {:ok, summary} = Recurrences.run(tenant: tenant)
          summary.counts
        end
      end)

    assert Enum.map(results, & &1["granted"]) == [1, 0, 0, 0, 0]
    assert Enum.map(results, & &1["duplicate"]) == [0, 1, 1, 1, 1]
    assert Enum.map(results, & &1["skipped"]) == [0, 0, 0, 0, 0]

    assert length(lots(tenant)) == 1
    assert length(recurrences(tenant)) == 1
    assert length(transactions(tenant, :grant)) == 1
    assert Credits.balance(tenant).available == @allowance
  end

  test "I18 a cancelled subscription receives nothing and a past_due one receives its allowance" do
    cancelled = tenant(:allowance)
    past_due = tenant(:allowance)

    set_status(cancelled, "canceled")
    set_status(past_due, "past_due")

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: [cancelled, past_due])
      assert summary.counts["granted"] == 1
      assert summary.reasons["not_entitled"] == 1
    end)

    assert lots(cancelled) == []
    assert recurrences(cancelled) == []
    assert [%{amount: @allowance}] = lots(past_due)
  end

  test "I18 a plan that declares no allowance grants nothing at all" do
    tenant = tenant(:pro)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 0
      assert summary.reasons["no_recurring_credits"] == 1
    end)

    assert lots(tenant) == []
  end

  test "I18 a wallet the allocator does not own is skipped and told why" do
    # **"Does not own" means a wallet that predates the lots-on-creation
    # release, and since 0.5.0 that is the only thing it can mean.** A tenant
    # with no wallet at all is not skipped any more: the grant that pays the
    # allowance is what creates the wallet, and a wallet created now is born on
    # the allocator. That was the shape this test used to build, and building it
    # again would be asserting the old answer to a question that changed. The
    # new answer is asserted by `credits_new_wallet_test.exs` / `test X380
    # recurring_credits grants a real allowance to a wallet nobody enabled
    # anything on`, which is the case an allowance is actually for: a customer
    # who has just subscribed and has never been granted anything.
    tenant = LedgerFixtures.legacy_wallet!(unique_tenant("recur"))
    AuroraMeter.subscribe(tenant, :allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 0
      assert summary.reasons["lots_disabled"] == 1
    end)

    assert lots(tenant) == []
    assert recurrences(tenant) == []
    # And nothing at all was written, not even an empty wallet.
    assert Credits.balance(tenant).balance == 0
  end

  test "I18 the recurrence reference namespace is rejected for a manual grant" do
    tenant = tenant(:allowance)

    for call <- [
          fn -> Credits.grant(tenant, 1, reference: "recurring:anything") end,
          fn -> Credits.grant_with_status(tenant, 1, reference: "recurring:anything") end,
          fn -> Credits.hold(tenant, 1, "recurring:anything") end,
          fn -> Credits.debit(tenant, 1, "recurring:anything") end,
          fn -> Credits.reverse(tenant, 1, "recurring:anything") end
        ] do
      assert_raise ArgumentError, ~r/are reserved by the recurring-grant engine/, call
    end

    # Nothing else is reserved: a manual grant keeps using any string it likes,
    # including one that merely mentions the word.
    assert {:ok, _} = Credits.grant(tenant, 1, reference: "manual:recurring-ish")
  end

  test "I10 a recurring lot carries recurrence_key, plan_id and plan_version in its source" do
    tenant = tenant(:allowance)

    with_clock(@september, fn -> Recurrences.run(tenant: tenant) end)

    assert [lot] = lots(tenant)

    assert lot.source == %{
             "recurrence_key" => "recurring:monthly:allowance:1:2026-09-01T00:00:00Z",
             "recurrence" => "monthly",
             "plan_id" => "allowance",
             "plan_version" => "1"
           }

    # Provenance is readable through the public lot API, which is what makes a
    # rolled-over micro-dollar as auditable as any other (I10).
    assert [^lot | _] =
             Credits.Lots.for_source(tenant, %{recurrence_key: lot.source["recurrence_key"]})
             |> Enum.map(&AuroraMeter.TestRepo.get!(CreditLot, &1.id))
  end

  # -- rollover ----------------------------------------------------------------

  test "I18 an unused allowance rolls over capped at the policy cap and expires the rest" do
    tenant = tenant(:allowance)

    with_clock(@september, fn -> Recurrences.run(tenant: tenant) end)
    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    [september, october, carried] = lots(tenant)

    # September: nothing spent, so the whole allowance expired. 1,000,000 of it
    # came back as a lot of its own; the other 4,000,000 is gone.
    assert september.amount == @allowance
    assert september.available == 0
    assert september.expired == @allowance
    assert september.state == :expired

    assert carried.amount == @cap
    assert carried.reference =~ ":rollover"
    assert carried.expires_at == ~U[2026-11-01 00:00:00Z]

    assert october.amount == @allowance
    assert october.available == @allowance

    # The claim, and the assertion that carries it: the tenant holds one
    # allowance plus exactly the cap, and 4,000,000 was destroyed net of the
    # carry. Conservation alone would be satisfied by carrying nothing.
    assert Credits.balance(tenant).available == @allowance + @cap
    assert september.expired - carried.amount == 4 * @dollar

    assert [%{rollover_from_id: nil}, %{rollover_from_id: from}] = recurrences_asc(tenant)
    assert from == hd(recurrences_asc(tenant)).id
  end

  test "I18 a tenant that spent most of its allowance carries only what was left" do
    tenant = tenant(:allowance)

    with_clock(@september, fn ->
      Recurrences.run(tenant: tenant)
      {:ok, _} = Credits.debit(tenant, 4 * @dollar, tenant <> ":spend")
    end)

    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    [september, _october, carried] = lots(tenant)

    assert september.consumed == 4 * @dollar
    assert september.available == 0
    assert september.expired == @dollar
    # Everything September had left was carried, so nothing was destroyed.
    assert carried.amount == @dollar
    assert september.expired - carried.amount == 0
  end

  test "I18 a fully spent allowance rolls over nothing" do
    tenant = tenant(:allowance)

    with_clock(@september, fn ->
      Recurrences.run(tenant: tenant)
      {:ok, _} = Credits.debit(tenant, @allowance, tenant <> ":spend")
    end)

    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    assert [september, october] = lots(tenant)
    assert september.consumed == @allowance
    assert september.expired == 0
    assert october.amount == @allowance
    refute Enum.any?(lots(tenant), &(&1.reference =~ ":rollover"))
    assert Credits.balance(tenant).available == @allowance

    # And the row says so: a period that carried nothing names no source.
    assert [_september, %{rollover_from_id: nil}] = recurrences_asc(tenant)
  end

  test "I18 rollover is not compounded: two idle periods carry at most the cap into the third" do
    tenant = tenant(:allowance)

    for instant <- [@august, @september, @october] do
      with_clock(instant, fn -> Recurrences.run(tenant: tenant) end)
    end

    carried = Enum.filter(lots(tenant), &(&1.reference =~ ":rollover"))

    # Two carries, each of exactly the cap, never one of twice the cap and never
    # a cap that grew.
    assert Enum.map(carried, & &1.amount) == [@cap, @cap]

    # October holds its own allowance plus one cap. 6,000,000, never 7,000,000.
    assert Credits.balance(tenant).available == @allowance + @cap

    # The number that proves the cap is applied to the previous period as a
    # whole: September held 6,000,000 unused (its allowance plus August's
    # carry) and still passed on only 1,000,000.
    [_august, september_allowance, august_carry, _october, _september_carry] = lots(tenant)
    assert september_allowance.expired + august_carry.expired == @allowance + @cap
  end

  test "I18 a rollover is unaffected by whether the expiry sweep or the recurrence ran first" do
    swept = tenant(:allowance)
    unswept = tenant(:allowance)

    with_clock(@september, fn -> Recurrences.run(tenant: [swept, unswept]) end)

    with_clock(@october, fn ->
      # The sweep reaches the September lot first for one tenant and not for the
      # other. `available + expired` is invariant under that expiry, which is the
      # whole reason the carry can be read after it.
      {:ok, report} = Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 10)
      assert report.expired >= 2

      Recurrences.run(tenant: [swept, unswept])
    end)

    for tenant <- [swept, unswept] do
      assert [carried] = Enum.filter(lots(tenant), &(&1.reference =~ ":rollover"))
      assert carried.amount == @cap, "tenant #{tenant}"
      assert Credits.balance(tenant).available == @allowance + @cap
    end
  end

  test "I18 a plan with no rollover carries nothing and expires the whole allowance" do
    tenant = tenant(:allowance_flat)

    with_clock(@september, fn -> Recurrences.run(tenant: tenant) end)
    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    assert [september, october] = lots(tenant)
    assert september.expired == @allowance
    assert october.available == @allowance
    assert Credits.balance(tenant).available == @allowance
  end

  # -- catch-up ----------------------------------------------------------------

  test "I18 three missed periods are issued and expired in order and leave no fresh availability" do
    tenant = tenant(:allowance)

    # The tenant's first recurrence is June, then the job stops for three months.
    with_clock(@june, fn -> Recurrences.run(tenant: tenant) end)

    summary =
      with_clock(@october, fn ->
        {:ok, summary} = Recurrences.run(tenant: tenant, max_periods: 12)
        summary
      end)

    assert summary.counts["issued_and_expired"] == 3
    assert summary.counts["granted"] == 1

    rows = recurrences_asc(tenant)

    assert Enum.map(rows, &{&1.period_start, &1.state}) == [
             {~U[2026-06-01 00:00:00Z], :granted},
             {~U[2026-07-01 00:00:00Z], :issued_and_expired},
             {~U[2026-08-01 00:00:00Z], :issued_and_expired},
             {~U[2026-09-01 00:00:00Z], :issued_and_expired},
             {~U[2026-10-01 00:00:00Z], :granted}
           ]

    # Every historical period is in the ledger with its full amount, and every
    # one of them is worth nothing: issued and expired, not fresh funds.
    historical =
      Enum.filter(
        lots(tenant),
        &(&1.expires_at && DateTime.compare(&1.expires_at, @october) != :gt)
      )

    assert Enum.all?(historical, &(&1.available == 0)), inspect(historical)
    assert Enum.sum(Enum.map(historical, & &1.amount)) >= 3 * @allowance

    # The live period, and only the live period, is spendable: its own allowance
    # plus one capped carry out of September.
    assert Credits.balance(tenant).available == @allowance + @cap
  end

  test "I18 a historical period's grant, rollover and expiries chain exactly in one run" do
    tenant = tenant(:allowance)

    with_clock(@june, fn -> Recurrences.run(tenant: tenant) end)
    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    august =
      Enum.find(lots(tenant), fn lot ->
        lot.expires_at == ~U[2026-09-01 00:00:00Z] and not (lot.reference =~ ":rollover")
      end)

    assert august.amount == @allowance
    assert august.available == 0
    assert august.expired == @allowance
    assert august.state == :expired

    grant = AuroraMeter.TestRepo.get!(CreditTransaction, august.grant_transaction_id)
    expiry = Enum.find(transactions(tenant, :expire), &(&1.metadata["lot_id"] == august.id))

    assert expiry, "the historical lot has no expire row"
    assert expiry.seq > grant.seq

    # The chain the rows themselves carry (finding X254): the allowance is
    # granted, the carry out of July is granted beside it, and the allowance is
    # then destroyed. `balance_after` is computed under the balance row lock, so
    # this arithmetic holds only if nothing else committed in between.
    assert expiry.balance_after == grant.balance_after + @cap - @allowance
  end

  test "I18 a catch-up bounded by max_periods resumes chronologically on the next run" do
    tenant = tenant(:allowance)

    with_clock(~U[2026-05-15 12:00:00Z], fn -> Recurrences.run(tenant: tenant) end)

    first =
      with_clock(@october, fn ->
        {:ok, summary} = Recurrences.run(tenant: tenant, max_periods: 2)
        summary
      end)

    assert first.counts["catching_up"] == 1
    assert first.counts["issued_and_expired"] == 2
    assert first.counts["granted"] == 0

    assert Enum.map(recurrences_asc(tenant), & &1.period_start) == [
             ~U[2026-05-01 00:00:00Z],
             ~U[2026-06-01 00:00:00Z],
             ~U[2026-07-01 00:00:00Z]
           ]

    second =
      with_clock(@october, fn ->
        {:ok, summary} = Recurrences.run(tenant: tenant, max_periods: 12)
        summary
      end)

    assert second.counts["catching_up"] == 0

    assert Enum.map(recurrences_asc(tenant), & &1.period_start) == [
             ~U[2026-05-01 00:00:00Z],
             ~U[2026-06-01 00:00:00Z],
             ~U[2026-07-01 00:00:00Z],
             ~U[2026-08-01 00:00:00Z],
             ~U[2026-09-01 00:00:00Z],
             ~U[2026-10-01 00:00:00Z]
           ]

    assert Credits.balance(tenant).available == @allowance + @cap
  end

  test "I18 a tenant seen for the first time is not back-paid" do
    tenant = tenant(:allowance)

    with_clock(@october, fn -> Recurrences.run(tenant: tenant, max_periods: 12) end)

    assert [row] = recurrences(tenant)
    assert row.period_start == @october_start
    assert [lot] = lots(tenant)
    assert lot.available == @allowance
  end

  # -- the policy snapshot -----------------------------------------------------

  test "I18 a plan edited between two periods grants the new amount and keeps the old cap" do
    tenant = tenant(:allowance)

    with_clock(@september, fn -> Recurrences.run(tenant: tenant) end)

    # The plan is edited: the allowance rises to 9,000,000 and the cap to
    # 3,000,000. October is granted under the new plan; what September may carry
    # out of itself is still September's own cap of 1,000,000.
    TestConfig.with_config([{:aurora_meter, :plans, AuroraMeter.Test.EditedPlans}], fn ->
      with_clock(@october, fn ->
        assert {:ok, summary} = Recurrences.run(tenant: tenant)
        assert summary.counts["granted"] == 1
        assert summary.counts["amount"] == 9 * @dollar
        assert summary.counts["rollover"] == @cap
      end)

      # And a retry of September under the edited plan changes nothing at all.
      with_clock(@september, fn ->
        assert {:ok, summary} = Recurrences.run(tenant: tenant)
        assert summary.counts["duplicate"] == 1
        assert summary.counts["granted"] == 0
      end)
    end)

    [september, october, carried] = lots(tenant)

    assert september.amount == @allowance
    assert october.amount == 9 * @dollar

    # **This is the assertion the snapshot carries.** Reading the cap from the
    # compiled plan would carry 3,000,000 here, and every other number in this
    # test would still be right.
    assert carried.amount == @cap

    assert [%{policy: old}, %{policy: new}] = recurrences_asc(tenant)
    assert old["amount"] == @allowance and old["rollover"] == @cap
    assert new["amount"] == 9 * @dollar and new["rollover"] == 3 * @dollar
  end

  # -- the clock boundary ------------------------------------------------------

  test "I18 a run one microsecond before the boundary grants the old period, and at it the new" do
    tenant = tenant(:allowance)

    with_clock(~U[2026-09-30 23:59:59.999999Z], fn ->
      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)
      assert [%{period_start: @september_start}] = recurrences(tenant)

      travel(@october_start)

      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)
    end)

    assert Enum.map(recurrences_asc(tenant), & &1.period_start) ==
             [@september_start, @october_start]

    # September's lot expired at the boundary and passed on its cap; October's
    # is live. Neither period was granted twice and neither was skipped.
    assert [september, october, carried] = lots(tenant)
    assert september.expired == @allowance
    assert october.available == @allowance
    assert carried.amount == @cap
  end

  # -- operator controls -------------------------------------------------------

  test "I16 a paused run writes nothing and says it is paused" do
    tenant = tenant(:allowance)
    :ok = Operations.pause(Recurrences.operation())

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.paused
      assert summary.counts["granted"] == 0
    end)

    assert lots(tenant) == []
    assert recurrences(tenant) == []

    :ok = Operations.resume(Recurrences.operation())

    with_clock(@september, fn ->
      assert {:ok, %{paused: false}} = Recurrences.run(tenant: tenant)
    end)

    assert [_lot] = lots(tenant)
  end

  test "I18 a dry run reports what it would grant and writes nothing" do
    tenant = tenant(:allowance)

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant, dry_run: true)
      assert summary.dry_run
      assert summary.counts["granted"] == 1
      assert summary.counts["amount"] == @allowance
    end)

    assert lots(tenant) == []
    assert recurrences(tenant) == []
  end

  test "I18 status/1 reports the tenant's periods newest first" do
    tenant = tenant(:allowance)

    with_clock(@september, fn -> Recurrences.run(tenant: tenant) end)
    with_clock(@october, fn -> Recurrences.run(tenant: tenant) end)

    status = Recurrences.status(tenant: tenant)

    assert status.name == "credits_recurrences:global"
    refute status.paused
    assert Enum.map(status.recurrences, & &1.period_start) == [@october_start, @september_start]
  end

  test "I18 a tenant whose period source raises is skipped and the run continues" do
    # X211: the branch has to run. The source really raises, for this tenant and
    # not for the next, and both halves are asserted: the reason recorded, and
    # the tenant behind it granted.
    boom = tenant(:allowance, "recurboom")
    ordinary = tenant(:allowance)

    TestConfig.with_config([{:aurora_meter, :period_source, PeriodSources.RaisesForTenant}], fn ->
      with_clock(@september, fn ->
        assert {:ok, summary} = Recurrences.run(tenant: [boom, ordinary])
        assert summary.reasons["period_source_error"] == 1
        assert summary.counts["granted"] == 1
      end)
    end)

    assert lots(boom) == []
    assert [%{amount: @allowance}] = lots(ordinary)
  end

  test "I18 a subscription cancelled between the scan and the lock is refused under the lock" do
    # LI-06d-6. The gate runs inside the balance row lock, so the assertion that
    # carries the claim is that the *re-read* decides: the engine is handed a
    # tenant that was entitled when it was listed and is not when it commits.
    tenant = tenant(:allowance)

    request = fn ->
      with_clock(@september, fn ->
        Ledger.recurrence(tenant, cancelling_request(tenant))
      end)
    end

    assert {:ok, %{result: :skipped, reason: :not_entitled}} = request.()
    assert lots(tenant) == []
    assert recurrences(tenant) == []
  end

  # -- the scan, its cursor and its resumption ---------------------------------

  test "I16 the scan is bounded by limit and the next run continues from the cursor" do
    tenants = scan_fixture(5)

    first =
      with_clock(@september, fn ->
        {:ok, summary} = Recurrences.run(batch: 2, limit: 4)
        summary
      end)

    assert first.counts["examined"] == 4
    assert first.counts["granted"] == 4
    assert first.stopped == :max_batches
    assert first.cursor == %{"tenant_key" => Enum.at(tenants, 3)}

    second =
      with_clock(@september, fn ->
        {:ok, summary} = Recurrences.run(batch: 2, limit: 4)
        summary
      end)

    assert second.counts["granted"] == 1
    assert second.stopped == :complete
    assert second.cursor == nil

    for tenant <- tenants, do: assert([%{amount: @allowance}] = lots(tenant))
  end

  test "I16 a run killed mid-tenant resumes and reaches the same state as an uninterrupted one" do
    tenants = scan_fixture(4)

    # The kill lands after the first tenant's period has committed and before
    # the batch's checkpoint write, which is the window `AuroraMeter.Operations`
    # documents: the cursor is behind, so the rerun re-processes that tenant.
    with_clock(@september, fn ->
      # `spawn_monitor`, not `Task.async`: a task is linked, so a brutal kill
      # would take this test process with it and prove nothing.
      {pid, ref} =
        spawn_monitor(fn ->
          kill_after_first_grant(fn -> Recurrences.run(batch: 4, limit: 4) end)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 30_000
    end)

    # The first tenant's period committed; the batch's cursor did not, so the
    # rerun starts from the beginning of the scan and meets it again.
    assert [%{amount: @allowance}] = lots(hd(tenants))
    assert match?(nil, Operations.checkpoint(Recurrences.operation()))

    resumed =
      with_clock(@september, fn ->
        {:ok, summary} = Recurrences.run(batch: 4, limit: 4)
        summary
      end)

    # The re-processed tenant is a duplicate, not a second grant, and the three
    # behind it are granted once each.
    assert resumed.counts["granted"] == 3
    assert resumed.counts["duplicate"] == 1

    for tenant <- tenants do
      assert [lot] = lots(tenant)
      assert lot.amount == @allowance
      assert length(recurrences(tenant)) == 1
    end
  end

  test "I18 a storage adapter without list_subscriptions is refused rather than silently idle" do
    TestConfig.with_config([{:aurora_meter, :storage, AuroraMeter.Test.NoListingStorage}], fn ->
      assert {:error, {:unsupported, :list_subscriptions}} = Recurrences.run()
    end)
  end

  # -- negative controls -------------------------------------------------------

  test "I18 a naive per-period reference double-grants, which is what the engine replaces" do
    # **The negative control** (X125). A host cron that mints its own reference
    # per run rather than per period grants twice for one period, and every
    # conservation check in the package still passes. If this had granted once,
    # the idempotency the tests above assert would not be the engine's doing.
    tenant = tenant(:allowance)

    with_clock(@september, fn ->
      for i <- 1..2 do
        {:ok, _} = Credits.grant(tenant, @allowance, reference: "#{tenant}:naive:#{i}")
      end
    end)

    assert length(lots(tenant)) == 2
    assert Credits.balance(tenant).available == 2 * @allowance

    # And with the engine's key, the second attempt is a duplicate rather than a
    # second lot.
    with_clock(@september, fn ->
      Recurrences.run(tenant: tenant)
      Recurrences.run(tenant: tenant)
    end)

    assert length(Enum.filter(lots(tenant), &(&1.source["recurrence"] == "monthly"))) == 1
  end

  # -- helpers -----------------------------------------------------------------

  defp tenant(plan, prefix \\ "recur") do
    tenant = unique_tenant(prefix)
    AuroraMeter.subscribe(tenant, plan)
    Ledger.enable_lots!(tenant)
    tenant
  end

  # The scan reads every subscription in the installation, so a test of the
  # cursor has to own the whole table. Inside the sandbox this delete is rolled
  # back with the rest of the test and no other module's rows are touched.
  defp scan_fixture(count) do
    AuroraMeter.TestRepo.delete_all(AuroraMeter.Schema.Subscription)
    Operations.clear_checkpoint(Recurrences.operation())

    tenants =
      for i <- 1..count do
        tenant = "recurscan_#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        AuroraMeter.subscribe(tenant, :allowance)
        Ledger.enable_lots!(tenant)
        tenant
      end

    on_exit(fn -> Operations.clear_checkpoint(Recurrences.operation()) end)
    tenants
  end

  # Kills the calling process the first time a period is granted, from inside
  # the telemetry handler, which runs in the emitting process. The grant's own
  # transaction has already committed by then; the batch's checkpoint has not
  # been written.
  defp kill_after_first_grant(fun) do
    id = {__MODULE__, self()}

    :telemetry.attach(
      id,
      [:aurora_meter, :credits, :recurrence],
      fn _event, _measurements, %{result: result}, pid ->
        if result == :granted, do: Process.exit(pid, :kill)
      end,
      self()
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  defp set_status(tenant, status) do
    {:ok, _} =
      Storage.put_subscription(%{
        tenant_key: tenant,
        plan_id: "allowance",
        status: status
      })

    AuroraMeter.Subscriptions.invalidate(tenant)
  end

  defp lots(tenant) do
    AuroraMeter.TestRepo.all(
      from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq])
    )
  end

  defp recurrences(tenant) do
    AuroraMeter.TestRepo.all(
      from(r in CreditRecurrence,
        where: r.tenant_key == ^tenant,
        order_by: [desc: r.period_start]
      )
    )
  end

  defp recurrences_asc(tenant), do: Enum.reverse(recurrences(tenant))

  defp transactions(tenant, kind) do
    AuroraMeter.TestRepo.all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant and t.kind == ^kind,
        order_by: [asc: t.seq]
      )
    )
  end

  # A request whose gate cancels the subscription the moment it is asked, which
  # is the only way to be certain the check under the lock is the one that
  # decided rather than the scan's snapshot.
  defp cancelling_request(tenant) do
    period = AuroraMeter.Period.current!(tenant)

    %{
      key: Recurrences.key(:monthly, :allowance, "1", period.start),
      reference:
        Recurrences.reference(tenant, Recurrences.key(:monthly, :allowance, "1", period.start)),
      policy: %{
        name: :monthly,
        amount: @allowance,
        category: :promotional,
        rollover: @cap,
        expires: :period_end
      },
      policy_json: %{
        "amount" => @allowance,
        "category" => "promotional",
        "rollover" => @cap,
        "expires" => "period_end"
      },
      period: period,
      historical?: false,
      previous: nil,
      source: %{},
      metadata: %{},
      gate: fn _repo ->
        set_status(tenant, "canceled")
        {:skip, :not_entitled}
      end
    }
  end
end
