defmodule AuroraMeter.RecordBatchTest do
  @moduledoc """
  `AuroraMeter.record_batch/2`: input order, collapsing, the request-size
  bounds, and the rule that one bad element takes the whole batch with it
  (build unit 03b).
  """
  use AuroraMeter.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.RecordingOutbox

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = unique_tenant("batch")
    %{tenant: tenant, at: DateTime.utc_now()}
  end

  defp element(tenant, id, opts \\ []) do
    %{
      tenant: tenant,
      feature: Keyword.get(opts, :feature, :ai_generations),
      quantity: Keyword.get(opts, :quantity, 1),
      id: id,
      occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now())
    }
    |> Map.merge(Map.new(Keyword.take(opts, [:dimensions, :metadata])))
  end

  defp event_count(tenant) do
    TestRepo.aggregate(
      from(e in AuroraMeter.Schema.Event, where: e.tenant_key == ^tenant),
      :count
    )
  end

  defp totals(tenant) do
    TestRepo.all(
      from(t in EventTotal, where: t.tenant_key == ^tenant, select: map(t, [:quantity, :events]))
    )
  end

  test "record_batch preserves input order for a mix of inserted and duplicate results", ctx do
    assert {:ok, _event, :inserted} =
             AuroraMeter.record(ctx.tenant, :ai_generations, 3, id: "b", occurred_at: ctx.at)

    elements = [
      element(ctx.tenant, "a", quantity: 1, occurred_at: ctx.at),
      element(ctx.tenant, "b", quantity: 3, occurred_at: ctx.at),
      element(ctx.tenant, "c", quantity: 5, occurred_at: ctx.at)
    ]

    assert {:ok, results} = AuroraMeter.record_batch(elements)

    assert [
             {%Event{event_id: "a"}, :inserted},
             {%Event{event_id: "b"}, :duplicate},
             {%Event{event_id: "c"}, :inserted}
           ] = results

    assert event_count(ctx.tenant) == 3
    # 3 from the first call, then 1 + 5 from the batch. The duplicate adds
    # nothing, which is the whole of "no second projection effect".
    assert totals(ctx.tenant) == [%{quantity: 9, events: 3}]
  end

  test "record_batch rejects 501 elements before any I/O", ctx do
    TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
      elements = for n <- 1..501, do: element(ctx.tenant, "big-#{n}")

      assert {:error, {:invalid, [{500, :batch, :too_many_events}]}} =
               AuroraMeter.record_batch(elements)

      assert event_count(ctx.tenant) == 0
      assert RecordingOutbox.calls() == 0
    end)
  end

  test "record_batch rejects a payload over 1 MiB before any I/O", ctx do
    TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
      # 16 KiB of metadata each, which is the per-event limit, so 65 of them
      # crosses 1 MiB while every element on its own is legal.
      blob = String.duplicate("m", 16 * 1024 - 20)

      elements =
        for n <- 1..80, do: element(ctx.tenant, "heavy-#{n}", metadata: %{"blob" => blob})

      assert {:error, {:invalid, [{index, :batch, :too_large}]}} =
               AuroraMeter.record_batch(elements)

      assert index < 80
      assert event_count(ctx.tenant) == 0
      assert RecordingOutbox.calls() == 0
    end)
  end

  test "the batch size bound measures the bytes the caller sent, not the stored size", ctx do
    # open-findings.md X104: pg_column_size measures the stored size after TOAST
    # compression, so a compressible payload of any size passes a stored-size
    # test. This payload compresses to almost nothing and must still be refused.
    compressible = String.duplicate("a", 16 * 1024 - 20)

    assert byte_size(Canonical.canonical_json(%{"blob" => compressible})) > 16 * 1024 - 20

    elements =
      for n <- 1..80, do: element(ctx.tenant, "zip-#{n}", metadata: %{"blob" => compressible})

    assert {:error, {:invalid, [{_index, :batch, :too_large}]}} =
             AuroraMeter.record_batch(elements)

    assert event_count(ctx.tenant) == 0
  end

  test "I07 repeated ids with identical payloads collapse to one insert and two ordered results",
       ctx do
    TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
      same = [id: "same", quantity: 4, occurred_at: ctx.at, metadata: %{"a" => 1}]

      elements = [
        element(ctx.tenant, "same", same),
        element(ctx.tenant, "other", quantity: 1, occurred_at: ctx.at),
        # The same payload built with the keys in a different order.
        ctx.tenant
        |> element("same", same)
        |> Map.put(:metadata, %{"a" => 1})
      ]

      assert {:ok, results} = AuroraMeter.record_batch(elements)
      assert length(results) == 3

      assert [{first, :inserted}, {_other, :inserted}, {third, :inserted}] = results
      assert first.id == third.id
      assert first.seq == third.seq

      assert event_count(ctx.tenant) == 2
      assert totals(ctx.tenant) == [%{quantity: 5, events: 2}]
      assert length(RecordingOutbox.items()) == 2
    end)
  end

  test "I07 repeated ids with different payloads are rejected before any I/O", ctx do
    TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
      elements = [
        element(ctx.tenant, "clash", quantity: 1, occurred_at: ctx.at),
        element(ctx.tenant, "clash", quantity: 2, occurred_at: ctx.at)
      ]

      assert {:error, {:invalid, [{1, :id, :duplicate_id_in_batch}]}} =
               AuroraMeter.record_batch(elements)

      assert event_count(ctx.tenant) == 0
      assert RecordingOutbox.calls() == 0
    end)
  end

  test "I07 a conflicting element rolls back every new row in the batch", ctx do
    TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
      assert {:ok, _event, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 1, id: "e7", occurred_at: ctx.at)

      RecordingOutbox.reset!()
      before = totals(ctx.tenant)

      elements =
        for n <- 0..9 do
          if n == 7 do
            # Same id, different quantity.
            element(ctx.tenant, "e7", quantity: 99, occurred_at: ctx.at)
          else
            element(ctx.tenant, "e#{n}", quantity: 1, occurred_at: ctx.at)
          end
        end

      assert {:error, {:conflict, 7, existing}} = AuroraMeter.record_batch(elements)
      assert existing.event_id == "e7"
      assert existing.quantity == 1

      assert event_count(ctx.tenant) == 1
      assert totals(ctx.tenant) == before
      assert RecordingOutbox.items() == []
    end)
  end

  test "I06 a storage failure mid-batch rolls back every new row", ctx do
    TestConfig.with_config(
      [
        {:aurora_meter, :storage, FaultStorage},
        {:aurora_meter, :events_outbox, RecordingOutbox}
      ],
      fn ->
        Faults.arm(:before_commit, :raise,
          when: &(&1[:callback] == :record_events),
          label: :batch_rollback
        )

        elements = for n <- 1..5, do: element(ctx.tenant, "f#{n}", occurred_at: ctx.at)

        assert_raise Faults.Injected, fn ->
          AuroraMeter.record_batch(elements)
        end

        :ok = Faults.assert_fired!(:before_commit)
        assert event_count(ctx.tenant) == 0
        assert totals(ctx.tenant) == []
        assert RecordingOutbox.calls() == 0
      end
    )
  end

  test "a batch element that fails validation names its index", ctx do
    elements = [
      element(ctx.tenant, "ok-1", occurred_at: ctx.at),
      element(ctx.tenant, "ok-2", quantity: 0, occurred_at: ctx.at),
      Map.delete(element(ctx.tenant, "ok-3", occurred_at: ctx.at), :id)
    ]

    assert {:error, {:invalid, errors}} = AuroraMeter.record_batch(elements)
    assert {1, :quantity, :not_a_positive_integer} in errors
    assert {2, :id, :missing} in errors
    assert event_count(ctx.tenant) == 0
  end

  test "an empty batch is a no-op", _ctx do
    assert AuroraMeter.record_batch([]) == {:ok, []}
  end

  test "a batch spanning two tenants writes both", ctx do
    other = unique_tenant("batch")

    elements = [
      element(ctx.tenant, "shared", occurred_at: ctx.at),
      element(other, "shared", occurred_at: ctx.at)
    ]

    assert {:ok, [{a, :inserted}, {b, :inserted}]} = AuroraMeter.record_batch(elements)
    assert a.tenant_key == ctx.tenant
    assert b.tenant_key == other
    assert event_count(ctx.tenant) == 1
    assert event_count(other) == 1
  end
end
