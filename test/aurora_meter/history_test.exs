defmodule AuroraMeter.HistoryTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Flusher
  alias AuroraMeter.Storage

  test "history/3 returns one point per day with today's live value" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 4)

    points = AuroraMeter.history(tenant, :ops, days: 7)

    assert length(points) == 7
    assert List.last(points) == %{date: Date.utc_today(), value: 4}
    assert Enum.all?(Enum.drop(points, -1), &(&1.value == 0))
  end

  test "day buckets flush to aurora_meter_history and rehydrate when cold" do
    tenant = unique_tenant()
    today = Date.utc_today()
    AuroraMeter.track(tenant, :ops, 3)

    {:ok, _} = Flusher.flush()
    assert Storage.load_history(tenant, :ops, today) == 3

    # Simulate a cold node: drop the warm ETS key and read again.
    :ets.delete(AuroraMeter.Store.counters_table(), {tenant, :ops, {:day, today}})
    assert AuroraMeter.history(tenant, :ops, days: 1) == [%{date: today, value: 3}]
  end

  test "stored days outside the warm set are merged with live days" do
    tenant = unique_tenant()
    yesterday = Date.add(Date.utc_today(), -1)

    :ok =
      Storage.upsert_history([%{tenant_key: tenant, feature: :ops, date: yesterday, value: 9}])

    AuroraMeter.track(tenant, :ops, 1)

    assert [%{value: 9}, %{value: 1}] = AuroraMeter.history(tenant, :ops, days: 2)
  end

  test "reservations and releases keep the day bucket in step with the period counter" do
    tenant = unique_tenant()
    AuroraMeter.subscribe(tenant, :free)

    assert :ok = AuroraMeter.reserve(tenant, :ai_generations, 5)
    assert {:error, :limit_exceeded} = AuroraMeter.reserve(tenant, :ai_generations, 100)

    assert_raise RuntimeError, fn ->
      AuroraMeter.with_quota(tenant, :ai_generations, 2, fn -> raise "boom" end)
    end

    [%{value: value}] = AuroraMeter.history(tenant, :ai_generations, days: 1)
    assert value == 5
    assert AuroraMeter.usage(tenant, :ai_generations) == 5
  end

  test "history can be switched off" do
    Application.put_env(:aurora_meter, :history, false)
    on_exit(fn -> Application.delete_env(:aurora_meter, :history) end)

    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 2)

    assert [%{value: 0}] = AuroraMeter.history(tenant, :ops, days: 1)
    assert AuroraMeter.usage(tenant, :ops) == 2
  end
end
