defmodule AuroraMeter.MeteringTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false
  use ExUnitProperties

  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Storage

  defp period, do: Period.current("t").start

  test "track/3 accumulates usage in the current period" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 2)
    AuroraMeter.track(tenant, :ops)
    assert AuroraMeter.usage(tenant, :ops) == 3
  end

  test "usage_all/1 returns every warm feature for the tenant" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 2)
    AuroraMeter.track(tenant, :ai, 5)
    assert AuroraMeter.usage_all(tenant) == %{ops: 2, ai: 5}
  end

  property "concurrent increments sum correctly" do
    check all(k <- integer(2..8), j <- integer(5..30), max_runs: 15) do
      tenant = unique_tenant()

      tasks =
        for _ <- 1..k do
          Task.async(fn -> Enum.each(1..j, fn _ -> AuroraMeter.track(tenant, :ops) end) end)
        end

      Enum.each(tasks, &Task.await(&1, :infinity))
      assert AuroraMeter.usage(tenant, :ops) == k * j
    end
  end

  test "I04 Counter.reserve blocks at the hard limit and rolls the increment back" do
    tenant = unique_tenant()
    p = period()

    assert :ok = Counter.reserve(tenant, :ops, 1, p, 2)
    assert :ok = Counter.reserve(tenant, :ops, 1, p, 2)
    assert {:error, :limit_exceeded} = Counter.reserve(tenant, :ops, 1, p, 2)
    assert Counter.value(tenant, :ops, p) == 2
  end

  test "Counter.value/3 rehydrates from the database when ETS is cold" do
    tenant = unique_tenant()

    :ok =
      Storage.upsert_counters([
        %{tenant_key: tenant, feature: :ops, period_start: period(), value: 7}
      ])

    assert AuroraMeter.usage(tenant, :ops) == 7
  end

  test "flush persists ETS values and repeated flushes are idempotent" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ops, 3)

    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, period()) == 3

    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, period()) == 3
  end

  test "a durable feature writes an event row on track" do
    tenant = unique_tenant()
    AuroraMeter.track(tenant, :ai, 1, durable: true)
    assert TestRepo.aggregate(from(e in Event, where: e.tenant_key == ^tenant), :count) == 1
  end

  test "track/4 emits [:aurora_meter, :track] telemetry" do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:aurora_meter, :track],
      fn _event, measurements, metadata, _config ->
        send(parent, {:track_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    AuroraMeter.track(unique_tenant(), :ops, 2)
    assert_receive {:track_event, %{count: 2}, %{feature: :ops}}
  end
end
