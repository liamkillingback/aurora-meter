defmodule AuroraMeter.EntitlementsTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Billing

  test "subscribe/2 assigns a plan and plan/1 resolves it" do
    tenant = unique_tenant()
    assert {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
    assert AuroraMeter.plan(tenant).id == :pro
  end

  test "the default plan applies without a subscription" do
    assert AuroraMeter.plan(unique_tenant()).id == :free
  end

  test "check/2 allows under a hard cap and reports remaining" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    AuroraMeter.track(tenant, :ai_generations, 10)
    assert AuroraMeter.check(tenant, :ai_generations) == :ok
    assert AuroraMeter.remaining(tenant, :ai_generations) == 40
  end

  test "check/2 blocks a hard cap at the limit" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    AuroraMeter.track(tenant, :ai_generations, 50)
    assert AuroraMeter.check(tenant, :ai_generations) == {:error, :limit_exceeded}
    assert AuroraMeter.remaining(tenant, :ai_generations) == 0
  end

  test "a metered feature is always allowed and reports :unlimited" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :scale)
    AuroraMeter.track(tenant, :ai_generations, 5_000)
    assert AuroraMeter.check(tenant, :ai_generations) == :ok
    assert AuroraMeter.remaining(tenant, :ai_generations) == :unlimited
  end

  test "feature access is gated by the plan" do
    free = unique_tenant()
    AuroraMeter.subscribe(free, :free)
    refute AuroraMeter.entitled?(free, :api_access)
    assert AuroraMeter.check(free, :api_access) == {:error, :not_entitled}

    pro = unique_tenant()
    AuroraMeter.subscribe(pro, :pro)
    assert AuroraMeter.entitled?(pro, :api_access)
    assert AuroraMeter.check(pro, :api_access) == :ok
  end

  test "an integer feature is always entitled and readable with feature_value/3" do
    free = unique_tenant()
    AuroraMeter.subscribe(free, :free)
    assert AuroraMeter.check(free, :seats) == :ok
    assert AuroraMeter.entitled?(free, :seats)
    assert AuroraMeter.remaining(free, :seats) == :unlimited
    assert AuroraMeter.feature_value(free, :seats) == 1
    assert AuroraMeter.feature_value(free, :api_access) == false
    assert AuroraMeter.feature_value(free, :ai_generations, :none) == :none
    assert AuroraMeter.feature_value(free, :nothing, 0) == 0

    assert %{kind: :feature, value: 1, enabled: true, remaining: :unlimited} =
             AuroraMeter.quota(free, :seats)

    pro = unique_tenant()
    AuroraMeter.subscribe(pro, :pro)
    assert AuroraMeter.feature_value(pro, :seats) == 5
    assert AuroraMeter.reserve(pro, :seats) == :ok

    # No subscription: the default plan's value.
    assert AuroraMeter.feature_value(unique_tenant(), :seats) == 1
  end

  test "an undeclared feature is permissive" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    assert AuroraMeter.check(tenant, :undeclared_thing) == :ok
    assert AuroraMeter.remaining(tenant, :undeclared_thing) == :unlimited
  end

  test "with_quota/3 enforces the hard limit under concurrency" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)

    results =
      1..60
      |> Task.async_stream(
        fn _ -> AuroraMeter.with_quota(tenant, :ai_generations, fn -> :done end) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, :done}, &1)) == 50
    assert Enum.count(results, &match?({:error, :limit_exceeded}, &1)) == 10
    assert AuroraMeter.usage(tenant, :ai_generations) == 50
  end

  test "with_quota releases the reservation when the function raises" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    assert_raise RuntimeError, fn ->
      AuroraMeter.with_quota(tenant, :ai_generations, fn -> raise "boom" end)
    end

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
  end

  test "the Noop billing provider returns :not_configured" do
    assert Billing.checkout(unique_tenant(), :pro) == {:error, :not_configured}
    assert Billing.portal_url(unique_tenant()) == {:error, :not_configured}
  end
end
