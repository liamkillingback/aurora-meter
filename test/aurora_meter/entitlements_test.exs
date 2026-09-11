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

  describe "counter features" do
    test "are always allowed, never capped, and never report a percentage" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)
      AuroraMeter.track(tenant, :requests, 6)

      assert AuroraMeter.check(tenant, :requests) == :ok
      assert AuroraMeter.allowed?(tenant, :requests)
      assert AuroraMeter.entitled?(tenant, :requests)
      assert AuroraMeter.remaining(tenant, :requests) == :unlimited

      quota = AuroraMeter.quota(tenant, :requests)

      assert quota.feature == :requests
      assert quota.kind == :counter
      assert quota.used == 6
      assert quota.overage == 0
      assert quota.remaining == :unlimited
      assert %{start: %DateTime{}, end: %DateTime{}, source: _} = quota.period

      # The whole point of the kind: there is no denominator, so nothing here
      # may be mistaken for "6 of 0" or "0% used".
      assert quota.limit == nil
      assert quota.included == nil
      assert quota.percent == nil
      assert quota.unit_price == nil
      assert quota.value == nil
      assert quota.enabled == true
    end

    test "reserve/3 always admits and still increments the counter" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)

      for _ <- 1..25, do: assert(AuroraMeter.reserve(tenant, :requests) == :ok)
      assert AuroraMeter.reserve(tenant, :requests, 75) == :ok

      assert AuroraMeter.usage(tenant, :requests) == 100
      assert AuroraMeter.quota(tenant, :requests).used == 100
      assert AuroraMeter.check(tenant, :requests) == :ok
    end

    test "with_quota/3 never blocks a counter, however much is used" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)

      results =
        1..40
        |> Task.async_stream(
          fn _ -> AuroraMeter.with_quota(tenant, :requests, fn -> :done end) end,
          max_concurrency: 10,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, :done}, &1))
      assert AuroraMeter.usage(tenant, :requests) == 40
    end

    test "a counter is not metered: nothing reports an overage or a unit price" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)
      AuroraMeter.track(tenant, :requests, 5_000)

      quota = AuroraMeter.quota(tenant, :requests)

      assert quota.overage == 0
      assert quota.unit_price == nil
    end
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

  test "and when it exits, which is how gated work usually fails" do
    # A `GenServer.call`, a `Task.await`, a database checkout: they all time
    # out by exiting rather than raising, and an exit unwinds straight past a
    # `rescue`. The reservation was counted for good, so a plan's hard limit
    # ratcheted down every time a call timed out.
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    catch_exit(AuroraMeter.with_quota(tenant, :ai_generations, fn -> exit(:timeout) end))

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
  end

  test "and when it throws" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    catch_throw(AuroraMeter.with_quota(tenant, :ai_generations, fn -> throw(:nope) end))

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
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
