defmodule AuroraMeter.PlanTransitionPrecedenceTest do
  @moduledoc """
  Build unit 07b, G07 bullet 4: what happens when the billing provider and a
  scheduled local change both act on one tenant.

  Every provider-driven plan change reaches Aurora Meter through
  `AuroraMeter.Storage.put_subscription/1`, so that is where each test acts.
  `AuroraMeter.Pro.Subscriptions.sync/1` calls it with exactly this shape, and
  core owns the reaction so the Pro integration cannot forget to make it.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions

  @far_future ~U[2030-12-01 00:00:00Z]

  defp scheduled(to_plan, opts \\ []) do
    tenant = unique_tenant("prec")
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
    Subscriptions.invalidate(tenant)
    {:ok, transition} = Subscriptions.schedule_transition(tenant, to_plan, [ref: "r"] ++ opts)
    {tenant, transition}
  end

  # `AuroraMeter.Schema.Subscription.changeset/2` requires `plan_id` on every
  # write, upsert included, so a provider sync always names a plan even when it
  # has nothing new to say about one. That is why "the plan did not change" is a
  # branch the reaction has to have rather than a case it can assume away.
  defp sync(tenant, attrs) do
    base = %{tenant_key: tenant, plan_id: row(tenant).plan_id, status: "active"}
    {:ok, written} = Storage.put_subscription(Map.merge(base, attrs))

    Subscriptions.invalidate(tenant)
    written
  end

  defp transition(tenant), do: TestRepo.get_by!(PlanTransition, tenant_key: tenant, ref: "r")
  defp row(tenant), do: Storage.get_subscription(tenant)

  test "I17 a provider sync to a different plan cancels the pending transition" do
    {tenant, _} = scheduled(:scale)

    written = sync(tenant, %{plan_id: "payg", plan_version: "1"})

    assert written.plan_id == "payg"
    assert written.transition_state == "cancelled"

    settled = transition(tenant)
    assert settled.state == "cancelled"
    assert settled.detail["reason"] == "provider_override"
    assert settled.detail["observed"] == %{"plan_id" => "payg", "plan_version" => "1"}

    # And the local plan is never re-applied later.
    assert {:ok, %{applied: 0}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert row(tenant).plan_id == "payg"
  end

  test "I17 a provider sync to exactly the scheduled target applies the transition early" do
    {tenant, scheduled} = scheduled(:scale)

    written = sync(tenant, %{plan_id: "scale", plan_version: "1"})

    assert written.plan_id == "scale"
    assert written.transition_state == "applied"

    applied = transition(tenant)
    assert applied.state == "applied"
    assert applied.detail["reason"] == "provider_applied_early"
    assert %DateTime{} = applied.applied_at

    settled = row(tenant)
    assert settled.plan_fingerprint == AuroraMeter.Plans.get(:scale, "1").fingerprint
    assert settled.plan_effective_at == scheduled.effective_at
    assert %DateTime{} = settled.transition_applied_at

    # One audit row for one commercial change, and nothing left to apply.
    assert {:ok, %{applied: 0}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  test "X296 a provider naming the plan id without the version cancels, and Aurora Meter Pro no longer produces that shape" do
    # **Rewritten by build unit 07c, and the core behaviour it asserts is
    # unchanged.** What changed is the premise. When 07b wrote this test,
    # `AuroraMeter.Pro.Subscriptions.sync/1` sent `plan_id` and no version, so
    # this was the shape Pro produced and the early-apply branch above was
    # unreachable from Pro: every Stripe-confirmed upgrade to exactly the
    # scheduled target was classified `provider_override` and CANCELLED.
    #
    # 07c gave `AuroraMeter.Pro.Config.plan_for_price/1` a `{plan_id, version}`
    # return and made `sync/1` write both, so the shape below is now a
    # third-party `AuroraMeter.Billing.Provider` that has not adopted plan
    # versions, and nothing this programme ships. The Pro half is
    # `pro:test/aurora_meter/pro/plan_ref_test.exs` /
    # `test I17 X296 sync writes the plan id AND the version, so a confirmed
    # upgrade applies early instead of cancelling`.
    #
    # Strict pair equality stays the default and stays right: a provider that
    # named no version has said nothing about which contract it means, and
    # inventing one on its behalf would move the tenant onto a version nobody
    # asked for. The cancel is safe (the tenant lands on what the provider
    # said) and is still not what a confirmed upgrade should do, which is why
    # the fix was to make Pro speak the full pair rather than to loosen this.
    {tenant, _} = scheduled(:versioned, version: "2")

    sync(tenant, %{plan_id: "versioned"})

    settled = transition(tenant)
    assert settled.state == "cancelled"
    assert settled.detail["reason"] == "provider_override"
    assert settled.detail["observed"] == %{"plan_id" => "versioned", "plan_version" => "1"}
  end

  test "I17 a provider sync that does not change the plan leaves the transition pending" do
    {tenant, _} = scheduled(:scale)

    written = sync(tenant, %{plan_id: "pro", provider_subscription_id: "sub_1"})

    assert written.transition_state == "pending"
    assert transition(tenant).state == "pending"

    assert {:ok, %{applied: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  test "I17 a provider sync touching only provider ids leaves the transition pending" do
    {tenant, _} = scheduled(:scale)

    written = sync(tenant, %{provider_customer_id: "cus_1"})

    assert written.provider_customer_id == "cus_1"
    assert transition(tenant).state == "pending"
  end

  test "I17 a provider sync writing a non-entitled status cancels the pending transition" do
    {tenant, _} = scheduled(:scale)

    written = sync(tenant, %{status: "canceled"})

    assert written.status == "canceled"
    settled = transition(tenant)
    assert settled.state == "cancelled"
    assert settled.detail["reason"] == "subscription_not_entitled"
    assert settled.detail["status"] == "canceled"
  end

  test "I17 a cancellation wins over a sync that also names the scheduled target" do
    # The one ordering the build document numbers the other way round. A write
    # that both moves the plan to the scheduled target and ends the subscription
    # must not apply the transition: a tenant who is not entitled has no plan to
    # move to.
    {tenant, _} = scheduled(:scale)

    sync(tenant, %{plan_id: "scale", plan_version: "1", status: "canceled"})

    settled = transition(tenant)
    assert settled.state == "cancelled"
    assert settled.detail["reason"] == "subscription_not_entitled"
  end

  test "I17 a transition effective before a later cancellation applies normally" do
    {tenant, _} = scheduled(:scale, effective_at: ~U[2026-10-01 00:00:00Z])

    assert {:ok, %{applied: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert row(tenant).plan_id == "scale"

    # The cancellation arrives afterwards and settles nothing, because there is
    # nothing pending left to settle.
    sync(tenant, %{status: "canceled"})
    assert transition(tenant).state == "applied"
  end

  test "I17 a cancelled transition is never applied by a later run" do
    {tenant, _} = scheduled(:scale)
    {:ok, _} = Subscriptions.cancel_transition(tenant, "r")

    assert {:ok, %{applied: 0, skipped: 1}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)

    assert row(tenant).plan_id == "pro"
  end

  test "I17 a stale sync for an ended subscription cannot revive a cancelled transition" do
    {tenant, _} = scheduled(:scale)
    sync(tenant, %{status: "canceled"})
    assert transition(tenant).state == "cancelled"

    # The stale payload arrives again, naming the plan the transition targeted.
    sync(tenant, %{plan_id: "scale", plan_version: "1", status: "canceled"})

    assert transition(tenant).state == "cancelled"
    assert transition(tenant).detail["reason"] == "subscription_not_entitled"

    assert {:ok, %{applied: 0}} =
             Subscriptions.apply_due_transitions(tenant: tenant, now: @far_future)
  end

  test "I17 put_subscription with no pending transition opens no transaction" do
    tenant = unique_tenant("prec")
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)

    opened =
      transactions(fn ->
        {:ok, _} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "scale"})
      end)

    assert opened == 0,
           "put_subscription opened #{opened} transaction(s) for a tenant with nothing pending. " <>
             "The reaction costs one read and no transaction on the common path."

    # And the control: the same call with a pending transition does open one, so
    # a count of zero above is a fact about the branch and not about the counter.
    {:ok, _} = Subscriptions.schedule_transition(tenant, :payg, ref: "r")

    assert transactions(fn ->
             {:ok, _} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "free"})
           end) > 0
  end

  # `AuroraMeter.subscribe/3` opens one of its own (the `:db_now` stamp), so the
  # counter is scoped to the call under test rather than to the whole set-up.
  defp transactions(fun) do
    parent = self()
    id = "07b-tx-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:aurora_meter, :test_repo, :query],
      fn _event, _measure, meta, _config ->
        if meta.query =~ ~r/^(begin|savepoint)/i, do: send(parent, :transaction)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain(0)
  end

  defp drain(count) do
    receive do
      :transaction -> drain(count + 1)
    after
      0 -> count
    end
  end
end
