defmodule AuroraMeter.StorageTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Storage

  @period ~U[2026-07-01 00:00:00Z]

  # -- X220: the receipt is stamped by the database ---------------------------

  test "X220 a flush receipt's inserted_at comes from the database, not from the node clock" do
    tenant = unique_tenant()
    id = Ecto.UUID.generate()
    counters = [%{tenant_key: tenant, feature: :ai, period_start: @period, delta: 5}]

    # A node clock frozen decades in the past. `AuroraMeter.Retention` compares
    # this column against a cutoff the **database** computes, so a node-stamped
    # value is two clocks on one comparison and a receipt pruned early reopens
    # the double-count window I01 exists to close.
    AuroraMeter.Test.with_clock(~U[2020-01-01 00:00:00Z], fn ->
      assert {:ok, _} = Storage.flush_batch(id, counters, [])
    end)

    receipt = TestRepo.get!(FlushReceipt, id)

    assert DateTime.compare(receipt.inserted_at, ~U[2024-01-01 00:00:00Z]) == :gt,
           "the receipt was stamped #{inspect(receipt.inserted_at)}, which is the frozen node " <>
             "clock rather than the database's. Version 10's column default is what makes the " <>
             "omission in flush_batch/3 safe."
  end

  test "X220 the receipt still deduplicates a retried batch and does not move its timestamp" do
    tenant = unique_tenant()
    id = Ecto.UUID.generate()
    counters = [%{tenant_key: tenant, feature: :ai, period_start: @period, delta: 5}]

    assert {:ok, %{counters: [%{value: 5}]}} = Storage.flush_batch(id, counters, [])
    first = TestRepo.get!(FlushReceipt, id).inserted_at

    # The `on_conflict: :nothing` decision is unchanged by omitting the column:
    # the second call still adds nothing, and the receipt keeps the instant it
    # was first written at.
    assert {:ok, %{counters: [%{value: 5}]}} = Storage.flush_batch(id, counters, [])

    assert Storage.load_counter(tenant, :ai, @period) == 5
    assert TestRepo.get!(FlushReceipt, id).inserted_at == first
    assert TestRepo.aggregate(FlushReceipt, :count) >= 1
  end

  test "a batch receipt deduplicates counters and history after unrelated writes" do
    tenant = unique_tenant()
    id = Ecto.UUID.generate()
    date = ~D[2026-07-03]
    counters = [%{tenant_key: tenant, feature: :ai, period_start: @period, delta: 5}]
    history = [%{tenant_key: tenant, feature: :ai, date: date, delta: 5}]

    assert {:ok, %{counters: [%{value: 5}], history: [%{value: 5}]}} =
             Storage.flush_batch(id, counters, history)

    assert {:ok, _} = Storage.add_counters([%{hd(counters) | delta: 3}])
    assert {:ok, _} = Storage.add_history([%{hd(history) | delta: 3}])

    assert {:ok, %{counters: [%{value: 8}], history: [%{value: 8}]}} =
             Storage.flush_batch(id, counters, history)

    assert Storage.load_counter(tenant, :ai, @period) == 8
    assert Storage.load_history(tenant, :ai, date) == 8
  end

  test "a retried batch reads its totals back in one statement per table, not one per row" do
    tenant = unique_tenant()
    id = Ecto.UUID.generate()
    keys = for n <- 1..40, do: :"feature_#{n}"

    counters =
      Enum.map(keys, &%{tenant_key: tenant, feature: &1, period_start: @period, delta: 2})

    history =
      Enum.map(keys, &%{tenant_key: tenant, feature: &1, date: ~D[2026-07-03], delta: 2})

    # One key that has no row at all by the time of the retry answers 0.
    missing = %{tenant_key: tenant, feature: :never_written, period_start: @period, delta: 1}

    assert {:ok, _} = Storage.flush_batch(id, counters, history)
    assert {:ok, _} = Storage.add_counters([%{hd(counters) | delta: 3}])

    handler = "x372-#{id}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:aurora_meter, :test_repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test_pid, :query) end,
      nil
    )

    try do
      assert {:ok, %{counters: retried_counters, history: retried_history}} =
               Storage.flush_batch(id, counters ++ [missing], history)

      # The receipt insert, the transaction, and two reads. Not eighty-one.
      queries = count_messages(:query)
      assert queries >= 2, "no query was observed, so the handler is not attached"
      assert queries <= 6, "the retry branch issued #{queries} queries"

      assert hd(retried_counters).value == 5
      assert Enum.all?(tl(Enum.drop(retried_counters, -1)), &(&1.value == 2))
      assert List.last(retried_counters).value == 0
      assert List.last(retried_counters).feature == "never_written"
      assert length(retried_history) == 40
      assert Enum.all?(retried_history, &(&1.value == 2))
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(message, count \\ 0) do
    receive do
      ^message -> count_messages(message, count + 1)
    after
      0 -> count
    end
  end

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

  test "add_counters/1 inserts at the delta, then adds, and returns the totals" do
    tenant = unique_tenant()

    assert {:ok, [%{tenant_key: ^tenant, feature: "ai", value: 5}]} =
             Storage.add_counters([
               %{tenant_key: tenant, feature: :ai, period_start: @period, delta: 5}
             ])

    assert {:ok, [%{value: 8}]} =
             Storage.add_counters([
               %{tenant_key: tenant, feature: "ai", period_start: @period, delta: 3}
             ])

    assert {:ok, [%{value: 6}]} =
             Storage.add_counters([
               %{tenant_key: tenant, feature: :ai, period_start: @period, delta: -2}
             ])

    assert Storage.load_counter(tenant, :ai, @period) == 6
    assert Enum.count(Storage.stream_counters(@period), &(&1.tenant_key == tenant)) == 1
    assert Storage.add_counters([]) == {:ok, []}
  end

  test "add_history/1 adds to day buckets and returns the totals" do
    tenant = unique_tenant()
    date = ~D[2026-07-03]

    assert {:ok, [%{feature: "ai", date: ^date, value: 4}]} =
             Storage.add_history([%{tenant_key: tenant, feature: :ai, date: date, delta: 4}])

    assert {:ok, [%{value: 9}]} =
             Storage.add_history([%{tenant_key: tenant, feature: :ai, date: date, delta: 5}])

    assert Storage.load_history(tenant, :ai, date) == 9
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
