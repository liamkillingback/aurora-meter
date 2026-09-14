defmodule AuroraMeter.EntitlementsTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [travel: 1, with_clock: 2]
  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Billing
  alias AuroraMeter.Billing.Noop
  alias AuroraMeter.Billing.Provider
  alias AuroraMeter.Config.Schema
  alias AuroraMeter.Counter
  alias AuroraMeter.Entitlements
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

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

  # G1 of docs/guarantees.md. `check/2` decides against the counter as it is and
  # holds nothing, so the same last unit is offered to every caller that asks
  # for it. The counter and the remaining count are read afterwards to show that
  # asking changed neither: a check that quietly reserved would be a different,
  # and much more surprising, function.
  test "check/2 is advisory: two callers are both allowed the last unit and nothing is reserved" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)
    AuroraMeter.track(tenant, :ai_generations, 49)
    period = Period.current(tenant).start
    key = {tenant, :ai_generations, period}

    assert AuroraMeter.remaining(tenant, :ai_generations) == 1

    # One unit left and two callers asking for it. Both are told yes, because
    # `check/2` answers from the counter as it stands and holds nothing.
    task = Task.async(fn -> AuroraMeter.check(tenant, :ai_generations) end)
    assert AuroraMeter.check(tenant, :ai_generations) == :ok
    assert Task.await(task) == :ok

    # The row is untouched by either question: `value` is still the 49 that were
    # tracked and `reserved` (the last position) is still zero. A `check/2` that
    # quietly reserved would show a 1 there, and would be a different function
    # from the one this page documents.
    assert [{^key, 49, _pending_flush, _pending_gossip, 0, 0}] =
             :ets.lookup(Store.counters_table(), key)

    assert AuroraMeter.usage(tenant, :ai_generations) == 49
    assert AuroraMeter.remaining(tenant, :ai_generations) == 1
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

  test "an undeclared feature follows the configured policy" do
    # The full matrix is AuroraMeter.FeaturePolicyTest (build unit 02b); this is
    # the one line that used to assert unconditional permissiveness.
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)

    with_config([{:aurora_meter, :undeclared_feature_policy, :allow}], fn ->
      assert AuroraMeter.check(tenant, :undeclared_thing) == :ok
      assert AuroraMeter.remaining(tenant, :undeclared_thing) == :unlimited
    end)

    with_config([{:aurora_meter, :undeclared_feature_policy, :deny}], fn ->
      assert AuroraMeter.check(tenant, :undeclared_thing) == {:error, :not_entitled}
      assert AuroraMeter.remaining(tenant, :undeclared_thing) == 0
    end)
  end

  test "plan/1 and Subscription.entitled?/1 agree for every status" do
    statuses =
      ~w(active trialing past_due canceled unpaid incomplete incomplete_expired paused)

    for status <- statuses do
      tenant = unique_tenant()

      {:ok, subscription} =
        Storage.put_subscription(%{tenant_key: tenant, plan_id: "pro", status: status})

      expected = if Subscription.entitled?(subscription), do: :pro, else: :free
      assert AuroraMeter.plan(tenant).id == expected, "status #{status}"
    end

    assert Subscription.entitled_statuses() == ~w(active trialing past_due)
  end

  test "subscribe/2 rejects an unknown plan in strict mode with plan_id: is not a known plan" do
    tenant = unique_tenant()

    assert {:error, changeset} = Entitlements.subscribe(tenant, :nope, :strict)
    assert plan_id_errors(changeset) == ["is not a known plan"]
    assert changeset.action == :insert
    assert Storage.get_subscription(tenant) == nil
  end

  test "subscribe/2 warns and writes in transition mode" do
    tenant = unique_tenant()
    Schema.reset_warnings!()
    on_exit(&Schema.reset_warnings!/0)

    log =
      capture_log(fn -> assert {:ok, _} = Entitlements.subscribe(tenant, :nope, :transition) end)

    assert log =~ ":nope is not declared by"
    assert log =~ "1.0 returns {:error, changeset}"
    assert Storage.get_subscription(tenant).plan_id == "nope"

    # The tenant silently resolves to the default plan, which is the defect the
    # 1.0 behaviour removes.
    assert AuroraMeter.plan(tenant).id == :free
  end

  test "I04 sixty concurrent with_quota calls against a limit of fifty admit exactly fifty on one node" do
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

  test "I04 an exiting callback releases its capacity" do
    # A `GenServer.call`, a `Task.await`, a database checkout: they all time
    # out by exiting rather than raising, and an exit unwinds straight past a
    # `rescue`. The reservation was counted for good, so a plan's hard limit
    # ratcheted down every time a call timed out.
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    catch_exit(AuroraMeter.with_quota(tenant, :ai_generations, fn -> exit(:timeout) end))

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
  end

  test "I04 a throwing callback releases its capacity" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    catch_throw(AuroraMeter.with_quota(tenant, :ai_generations, fn -> throw(:nope) end))

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
  end

  test "I04 a raising callback releases its capacity" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)

    assert_raise RuntimeError, fn ->
      AuroraMeter.with_quota(tenant, :ai_generations, fn -> raise "boom" end)
    end

    assert AuroraMeter.usage(tenant, :ai_generations) == 0
  end

  test "I03 a callback that flushed and then raises is not billed" do
    assert_not_billed(:raise, fn -> raise "boom" end)
  end

  test "I03 a callback that flushed and then throws is not billed" do
    assert_not_billed(:throw, fn -> throw(:nope) end)
  end

  test "I03 a callback that flushed and then exits is not billed" do
    assert_not_billed(:exit, fn -> exit(:timeout) end)
  end

  test "I03 a reservation is never in a flush batch" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)
    period = Period.current(tenant).start
    key = {tenant, :ai_generations, period}

    # Drain whatever an earlier test left dirty, so the snapshot below is this
    # test's answer and not somebody else's leftovers.
    {:ok, _} = Flusher.flush()

    assert :ok = Counter.reserve(tenant, :ai_generations, 3, period, nil, true)

    # Z1: a deferred reserve raises `value` and `reserved` and touches neither
    # `pending_flush` nor `pending_gossip`, so the key is not even dirty.
    assert [{^key, 3, 0, 0, 0, 3}] = :ets.lookup(Store.counters_table(), key)
    assert Store.snapshot_flush_batch() == nil

    assert {:ok, 0} = Flusher.flush()
    assert Storage.load_counter(tenant, :ai_generations, period) == nil

    # The local view does include it, which is what makes the quota strict on
    # this node (I04) while nothing is billed (I03).
    assert AuroraMeter.usage(tenant, :ai_generations) == 3
  end

  test "I03 a reservation committed against a captured day lands in that day's bucket (partial until 02c)" do
    # Partial until 02c: `lib/` has no clock seam (open finding C11), so the
    # crossing is expressed by passing the period and the day explicitly, which
    # is exactly what `with_quota/4` captures before the callback runs. 02c
    # introduces the seam and owns the full crossing test.
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)
    chosen_period = ~U[2026-01-01 00:00:00Z]
    chosen_day = ~D[2026-01-15]
    today = Date.utc_today()

    # The period half: `reserve/4` counts against the period it is given, not
    # against the one the clock is in.
    assert :ok = AuroraMeter.Entitlements.reserve(tenant, :ai_generations, 2, chosen_period)
    assert Counter.value(tenant, :ai_generations, chosen_period) == 2
    assert Counter.value(tenant, :ai_generations, Period.current(tenant).start) == 0

    # A plain reserve has no captured day, so its history goes to today. That is
    # the contrast the day half exists to make.
    assert Counter.day_value(tenant, :ai_generations, today) == 2

    # The day half: work that reserved yesterday commits into yesterday.
    assert :ok = Counter.reserve(tenant, :ai_generations, 3, chosen_period, nil, true)
    assert :ok = Counter.commit_work(tenant, :ai_generations, 3, chosen_period, chosen_day)
    assert Counter.day_value(tenant, :ai_generations, chosen_day) == 3
    assert Counter.day_value(tenant, :ai_generations, today) == 2
    assert Counter.value(tenant, :ai_generations, chosen_period) == 5
  end

  # Build unit 02c: the same crossing, now with the library's own clock frozen
  # rather than with the period and the day passed in by hand. P04: work
  # admitted in period P is committed to period P and to the UTC day of
  # admission, however long it takes to finish.
  describe "P04 work that crosses a period boundary" do
    @january ~U[2026-01-01 00:00:00Z]
    @february ~U[2026-02-01 00:00:00Z]
    @admission ~U[2026-01-31 23:59:59Z]
    @completion ~U[2026-02-01 00:00:01Z]

    test "P04 with_quota/4 admitted at 23:59:59 and finishing after midnight commits to the admission period" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :pro)

      with_clock(@admission, fn ->
        assert {:ok, :done} =
                 AuroraMeter.with_quota(tenant, :ai_generations, 3, fn ->
                   travel(@completion)
                   assert Period.current!(tenant).start == @february
                   :done
                 end)
      end)

      assert Counter.value(tenant, :ai_generations, @january) == 3
      assert Counter.value(tenant, :ai_generations, @february) == 0
    end

    test "P04 with_quota/4 crossing midnight commits to the admission UTC day bucket" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :pro)

      with_clock(@admission, fn ->
        assert {:ok, :done} =
                 AuroraMeter.with_quota(tenant, :ai_generations, 3, fn ->
                   travel(@completion)
                   :done
                 end)
      end)

      assert Counter.day_value(tenant, :ai_generations, ~D[2026-01-31]) == 3
      assert Counter.day_value(tenant, :ai_generations, ~D[2026-02-01]) == 0
    end

    test "P04 a released reservation after a period crossing releases from the admission period" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :pro)

      with_clock(@admission, fn ->
        assert_raise RuntimeError, "boom", fn ->
          AuroraMeter.with_quota(tenant, :ai_generations, 3, fn ->
            travel(@completion)
            raise "boom"
          end)
        end
      end)

      # Nothing is left counted in either period: the release took its three
      # back out of January, not out of February.
      assert Counter.value(tenant, :ai_generations, @january) == 0
      assert Counter.value(tenant, :ai_generations, @february) == 0
      assert Counter.day_value(tenant, :ai_generations, ~D[2026-01-31]) == 0
      assert Counter.day_value(tenant, :ai_generations, ~D[2026-02-01]) == 0
    end
  end

  test "I20 every Noop billing provider callback returns :not_configured" do
    assert Billing.checkout(unique_tenant(), :pro) == {:error, :not_configured}
    assert Billing.portal_url(unique_tenant()) == {:error, :not_configured}
    assert Billing.sync_subscription(%{"id" => "sub_example"}) == {:error, :not_configured}
    assert Noop.report_usage([]) == {:error, :not_configured}

    # Every callback the behaviour declares is answered above. A new one would
    # otherwise default to nothing at all on a core-only install.
    assert Enum.sort(Provider.behaviour_info(:callbacks)) == [
             billing_portal_url: 2,
             create_checkout_session: 2,
             report_usage: 1,
             sync_subscription: 1
           ]
  end

  defp plan_id_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Map.get(:plan_id)
  end

  # I03's central claim: work that did real, durable metering before it failed
  # is still not billed. The callback tracks a second feature, flushes it to the
  # database, reads the persisted counter for the gated feature back (Z1: the
  # reservation is not in it), and only then fails.
  defp assert_not_billed(kind, fail) do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :pro)
    period = Period.current(tenant).start

    gated = fn ->
      AuroraMeter.with_quota(tenant, :ai_generations, 3, fn ->
        AuroraMeter.track(tenant, :ops, 4)
        {:ok, _} = Flusher.flush()

        assert Storage.load_counter(tenant, :ops, period) == 4
        assert Storage.load_counter(tenant, :ai_generations, period) == nil

        fail.()
      end)
    end

    # catch_throw/1 and catch_exit/1 are macros, so the three kinds are branched
    # here rather than passed in as a function.
    case kind do
      :raise -> assert_raise RuntimeError, gated
      :throw -> assert catch_throw(gated.()) == :nope
      :exit -> assert catch_exit(gated.()) == :timeout
    end

    # The reservation is back, nothing was persisted for the gated feature, and
    # no later flush writes it either.
    assert AuroraMeter.usage(tenant, :ai_generations) == 0
    assert Storage.load_counter(tenant, :ai_generations, period) == nil

    {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ai_generations, period) == nil

    # And the work the callback really did is still there.
    assert Storage.load_counter(tenant, :ops, period) == 4
  end
end
