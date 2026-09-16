defmodule AuroraMeter.CreditsRecurrencesVersionsTest do
  @moduledoc """
  Build unit 07c, task 07.08: a recurring allowance is issued under the contract
  the period was sold under, not under whatever the tenant is on today and not
  under whatever version happens to be effective now.

  Build unit 06d wrote the version segment of the recurrence key as the literal
  `"1"` and resolved the plan by id alone, which are two different defects with
  the same cause. The second is the one gate G07 bullet 1 names in as many
  words: *deploying plan v2 leaves a tenant on v1 with their recurring grant
  amount unchanged*.

  `async: false`, because every test here freezes the node-wide clock: a period
  boundary is the subject.
  """
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [with_clock: 2]
  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Recurrences
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditRecurrence
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Test.Config, as: TestConfig

  @dollar 1_000_000
  @v1_allowance 5 * @dollar
  @v2_allowance 9 * @dollar

  @since ~U[2020-01-01 00:00:00Z]
  @september ~U[2026-09-15 12:00:00Z]
  @september_start ~U[2026-09-01 00:00:00Z]
  @october ~U[2026-10-15 12:00:00Z]
  @october_start ~U[2026-10-01 00:00:00Z]

  defp tenant_on(plan, version, prefix \\ "recurv") do
    tenant = unique_tenant(prefix)
    AuroraMeter.Test.subscribe_since!(tenant, plan, @since, version: version)
    Ledger.enable_lots!(tenant)
    tenant
  end

  defp recurrences(tenant) do
    TestRepo.all(
      from(r in CreditRecurrence, where: r.tenant_key == ^tenant, order_by: [asc: r.period_start])
    )
  end

  defp lots(tenant) do
    TestRepo.all(from(l in CreditLot, where: l.tenant_key == ^tenant, order_by: [asc: l.seq]))
  end

  test "I18 a recurring grant uses the plan version effective for the period" do
    tenant = tenant_on(:versioned, "1")

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 1
      assert summary.counts["amount"] == @v1_allowance
    end)

    assert [row] = recurrences(tenant)

    # The key names the version, and the version it names is the tenant's own.
    assert row.key ==
             Recurrences.key(:monthly, :versioned, "1", @september_start)

    assert row.key == "recurring:monthly:versioned:1:2026-09-01T00:00:00Z"
    assert row.policy["amount"] == @v1_allowance
    assert [%{amount: @v1_allowance}] = lots(tenant)
  end

  test "I18 a tenant pinned to version 2 is granted version 2's allowance and key" do
    # The negative control for the test above: the same plan, the same period,
    # one field of the subscription row apart. Without it "the version was
    # used" and "the default was used" look identical, because version 1 is
    # also what the literal said.
    tenant = tenant_on(:versioned, "2")

    with_clock(@september, fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] == 1
      assert summary.counts["amount"] == @v2_allowance
    end)

    assert [row] = recurrences(tenant)
    assert row.key == "recurring:monthly:versioned:2:2026-09-01T00:00:00Z"
    assert row.policy["amount"] == @v2_allowance
    assert row.policy["rollover"] == 3 * @dollar
    assert [%{amount: @v2_allowance}] = lots(tenant)
  end

  test "I17 deploying version 2 leaves a tenant on version 1 with an unchanged allowance" do
    # G07 bullet 1, the recurring-grant half. `AuroraMeter.Plans.get/1` answers
    # the version effective NOW, and resolving the plan with it is what used to
    # pay this tenant version 2's allowance the moment version 2 shipped.
    tenant = tenant_on(:versioned, "1")

    TestConfig.with_config(
      [{:aurora_meter, :plans, AuroraMeter.Test.VersionTwoLivePlans}],
      fn ->
        assert AuroraMeter.Plans.get(:versioned).version == "2"

        with_clock(@september, fn ->
          assert {:ok, summary} = Recurrences.run(tenant: tenant)
          assert summary.counts["granted"] == 1
          assert summary.counts["amount"] == @v1_allowance
        end)
      end
    )

    assert [row] = recurrences(tenant)
    assert row.key == "recurring:monthly:versioned:1:2026-09-01T00:00:00Z"
    assert row.policy["amount"] == @v1_allowance
    assert row.policy["rollover"] == 1 * @dollar
  end

  test "I18 a version 2 that drops the allowance does not stop a version 1 tenant being paid" do
    # The shape negative control C7 needs, and the reason it exists. The engine
    # resolves a plan to decide which entitlements a tenant is owed at all;
    # resolving it with the version effective **now** skips a version 1 tenant
    # with `reason: :no_recurring_credits` the moment a version 2 that dropped
    # the allowance ships, and the per-period policy lookup never runs because
    # there is no period to run it for.
    tenant = tenant_on(:versioned, "1")

    TestConfig.with_config(
      [{:aurora_meter, :plans, AuroraMeter.Test.AllowanceDroppedPlans}],
      fn ->
        assert AuroraMeter.Plans.get(:versioned).version == "2"
        assert AuroraMeter.Plans.get(:versioned).recurring_credits == []

        with_clock(@september, fn ->
          assert {:ok, summary} = Recurrences.run(tenant: tenant)
          assert summary.counts["granted"] == 1
          assert summary.counts["amount"] == @v1_allowance
          assert summary.reasons["no_recurring_credits"] in [nil, 0]
        end)
      end
    )

    assert [row] = recurrences(tenant)
    assert row.key == "recurring:monthly:versioned:1:2026-09-01T00:00:00Z"
  end

  test "I18 a recurrence key written before this unit is not granted a second time" do
    # Every key build unit 06d wrote carries the literal "1". A tenant on
    # version 1 mints the identical string, so the `UNIQUE (tenant_key, key)`
    # guard still sees it; and the period guard above it never gets that far,
    # because the period is already recorded.
    tenant = tenant_on(:versioned, "1")

    with_clock(@september, fn ->
      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)

      assert {:ok, %{counts: %{"granted" => 0, "duplicate" => 1}}} =
               Recurrences.run(tenant: tenant)
    end)

    assert [_one] = recurrences(tenant)
    assert [_one_lot] = lots(tenant)
  end

  test "I18 a transition at a period boundary produces one grant for each period at its own version" do
    tenant = tenant_on(:versioned, "1")

    with_clock(@september, fn ->
      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)
    end)

    # October: the tenant moves to version 2 at the boundary, and the applied
    # transition is the record of it.
    AuroraMeter.Test.subscribe_since!(tenant, :versioned, @october_start, version: "2")

    TestRepo.insert!(%PlanTransition{
      tenant_key: tenant,
      ref: "boundary",
      from_plan_id: "versioned",
      from_version: "1",
      to_plan_id: "versioned",
      to_version: "2",
      effective_at: @october_start,
      state: "applied",
      confirm: "local",
      applied_at: DateTime.utc_now()
    })

    with_clock(@october, fn ->
      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)
    end)

    assert [september, october] = recurrences(tenant)
    assert september.key == "recurring:monthly:versioned:1:2026-09-01T00:00:00Z"
    assert october.key == "recurring:monthly:versioned:2:2026-10-01T00:00:00Z"
    assert september.policy["amount"] == @v1_allowance
    assert october.policy["amount"] == @v2_allowance

    # One grant for each period, never two for one, and September's allowance
    # is not restated at October's amount.
    assert length(recurrences(tenant)) == 2
  end

  test "I18 a catch-up period before an upgrade is granted at the version that period was sold under" do
    # The case the whole change exists for. A tenant upgraded in October whose
    # sweep has not run since August is owed September at September's contract,
    # not at October's.
    tenant = tenant_on(:versioned, "1")

    with_clock(@september, fn ->
      assert {:ok, %{counts: %{"granted" => 1}}} = Recurrences.run(tenant: tenant)
    end)

    AuroraMeter.Test.subscribe_since!(tenant, :versioned, @october_start, version: "2")

    TestRepo.insert!(%PlanTransition{
      tenant_key: tenant,
      ref: "upgrade",
      from_plan_id: "versioned",
      from_version: "1",
      to_plan_id: "versioned",
      to_version: "2",
      effective_at: @october_start,
      state: "applied",
      confirm: "local",
      applied_at: DateTime.utc_now()
    })

    # November, with October never swept: October is caught up and November is
    # live, and the two are one contract apart from September.
    with_clock(~U[2026-11-15 12:00:00Z], fn ->
      assert {:ok, summary} = Recurrences.run(tenant: tenant)
      assert summary.counts["granted"] + summary.counts["issued_and_expired"] == 2
    end)

    versions =
      tenant
      |> recurrences()
      |> Enum.map(fn row -> {row.period_start, row.key |> String.split(":") |> Enum.at(3)} end)

    assert versions == [
             {@september_start, "1"},
             {@october_start, "2"},
             {~U[2026-11-01 00:00:00Z], "2"}
           ]
  end
end
