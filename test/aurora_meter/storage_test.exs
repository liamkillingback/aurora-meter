defmodule AuroraMeter.StorageTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Storage

  @period ~U[2026-07-01 00:00:00Z]

  test "upsert_counters inserts, then replaces on conflict (no duplicate row)" do
    tenant = unique_tenant()

    assert :ok =
             Storage.upsert_counters([
               %{tenant_key: tenant, feature: :ai, period_start: @period, value: 5}
             ])

    assert Storage.load_counter(tenant, :ai, @period) == 5

    assert :ok =
             Storage.upsert_counters([
               %{tenant_key: tenant, feature: :ai, period_start: @period, value: 8}
             ])

    assert Storage.load_counter(tenant, :ai, @period) == 8
    assert Enum.count(Storage.stream_counters(@period), &(&1.tenant_key == tenant)) == 1
  end

  test "load_counter/3 returns nil for a missing key" do
    assert Storage.load_counter(unique_tenant(), :ai, @period) == nil
  end

  test "load_counter/3 accepts an atom or string feature" do
    tenant = unique_tenant()

    :ok =
      Storage.upsert_counters([
        %{tenant_key: tenant, feature: :ai, period_start: @period, value: 3}
      ])

    assert Storage.load_counter(tenant, :ai, @period) == 3
    assert Storage.load_counter(tenant, "ai", @period) == 3
  end

  test "put_subscription/1 upserts by tenant_key" do
    tenant = unique_tenant()

    assert {:ok, sub} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "free"})
    assert sub.plan_id == "free"

    assert {:ok, sub2} = Storage.put_subscription(%{tenant_key: tenant, plan_id: "pro"})
    assert sub2.plan_id == "pro"
    assert Storage.get_subscription(tenant).plan_id == "pro"
  end

  test "insert_events/1 appends rows" do
    tenant = unique_tenant()

    assert :ok =
             Storage.insert_events([
               %{tenant_key: tenant, feature: :ai, quantity: 1},
               %{tenant_key: tenant, feature: :ai, quantity: 2, metadata: %{"src" => "test"}}
             ])

    count = TestRepo.aggregate(from(e in Event, where: e.tenant_key == ^tenant), :count)
    assert count == 2
  end
end
