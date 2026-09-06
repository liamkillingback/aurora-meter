defmodule AuroraMeter.SubscriptionsTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Subscriptions

  test "a subscription that is not in an entitled status falls back to the default plan" do
    tenant = unique_tenant()

    for status <- ~w(canceled unpaid incomplete incomplete_expired paused) do
      {:ok, _} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "pro", status: status})
      assert AuroraMeter.plan(tenant).id == :free, "#{status} should not grant the plan"
    end

    for status <- Subscription.entitled_statuses() do
      {:ok, _} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "pro", status: status})
      assert AuroraMeter.plan(tenant).id == :pro, "#{status} should grant the plan"
    end
  end

  test "plan lookups are served from the cache until the subscription is written" do
    tenant = unique_tenant()
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
    assert AuroraMeter.plan(tenant).id == :pro

    # A write that bypasses Storage (e.g. raw SQL) is invisible until the TTL passes...
    TestRepo.update_all(
      from(s in Subscription, where: s.tenant_key == ^tenant),
      set: [plan_id: "free"]
    )

    assert AuroraMeter.plan(tenant).id == :pro

    assert [{^tenant, %Subscription{}, _expires}] =
             :ets.lookup(Store.subscription_cache_table(), tenant)

    # ...or until it is invalidated explicitly.
    :ok = Subscriptions.invalidate(tenant)
    assert AuroraMeter.plan(tenant).id == :free
  end

  test "an invalidation broadcast from another node evicts the local entry" do
    tenant = unique_tenant()
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
    assert AuroraMeter.plan(tenant).id == :pro

    TestRepo.update_all(
      from(s in Subscription, where: s.tenant_key == ^tenant),
      set: [plan_id: "scale"]
    )

    Phoenix.PubSub.broadcast(
      AuroraMeter.TestPubSub,
      Store.invalidation_topic(),
      {:aurora_meter, :subscription_changed, tenant}
    )

    # The Store handles the message asynchronously; give it a moment.
    :sys.get_state(Store)
    assert AuroraMeter.plan(tenant).id == :scale
  end

  test "a TTL of 0 disables the cache" do
    Application.put_env(:aurora_meter, :subscription_cache_ttl, 0)
    on_exit(fn -> Application.delete_env(:aurora_meter, :subscription_cache_ttl) end)

    tenant = unique_tenant()
    {:ok, _} = AuroraMeter.subscribe(tenant, :pro)

    TestRepo.update_all(
      from(s in Subscription, where: s.tenant_key == ^tenant),
      set: [plan_id: "free"]
    )

    assert AuroraMeter.plan(tenant).id == :free
    assert :ets.lookup(Store.subscription_cache_table(), tenant) == []
  end

  test "quota/2 describes each feature kind" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    AuroraMeter.track(tenant, :ai_generations, 10)

    assert %{kind: :hard, used: 10, limit: 50, remaining: 40, percent: 20, overage: 0} =
             AuroraMeter.quota(tenant, :ai_generations)

    assert %{kind: :boolean, enabled: false} = AuroraMeter.quota(tenant, :api_access)
    assert %{kind: :undeclared, remaining: :unlimited} = AuroraMeter.quota(tenant, :nothing)

    metered = unique_tenant()
    AuroraMeter.subscribe(metered, :scale)
    AuroraMeter.track(metered, :ai_generations, 1_500)

    assert %{
             kind: :metered,
             included: 1_000,
             unit_price: 2,
             overage: 500,
             percent: 100,
             remaining: :unlimited,
             period: %{start: %DateTime{}}
           } = AuroraMeter.quota(metered, :ai_generations)
  end

  test "reserve/3 emits [:aurora_meter, :reserve] telemetry with the outcome" do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:aurora_meter, :reserve],
      fn _event, measurements, metadata, _config ->
        send(parent, {:reserve_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)

    :ok = AuroraMeter.reserve(tenant, :ai_generations, 50)
    assert_receive {:reserve_event, %{qty: 50}, %{result: :ok, feature: :ai_generations}}

    {:error, :limit_exceeded} = AuroraMeter.reserve(tenant, :ai_generations)
    assert_receive {:reserve_event, %{qty: 1}, %{result: :limit_exceeded}}

    {:error, :not_entitled} = AuroraMeter.reserve(tenant, :api_access)
    assert_receive {:reserve_event, _, %{result: :not_entitled}}
  end
end
