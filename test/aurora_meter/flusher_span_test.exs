defmodule AuroraMeter.FlusherSpanTest do
  @moduledoc """
  The flush span, and the two legacy events it sits beside.

  Flush latency is the single most useful operational number the buffered path
  has, and until this unit it could not be measured at all: `[:aurora_meter,
  :flush]` reported how much was written and never how long it took. The span
  adds that without touching either existing event, because a host attached to
  `[:aurora_meter, :flush]` or `[:aurora_meter, :flush, :error]` must see no
  change whatever.

  Every "is or is not emitted" claim here is asserted with a handler attached to
  the name in question, so an event that should not fire fails the test by
  firing rather than by being merely late (`open-findings.md` X211, X155).
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Flusher
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Faults
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.RefusingStorage

  @moduletag :fault

  @names [
    [:aurora_meter, :flush],
    [:aurora_meter, :flush, :error],
    [:aurora_meter, :flush, :start],
    [:aurora_meter, :flush, :stop],
    [:aurora_meter, :flush, :exception]
  ]

  setup do
    {:ok, _} = Flusher.flush()
    attach()
    :ok
  end

  test "I01 a committed flush emits start, stop with result ok, and the legacy event once each" do
    tenant = unique_tenant("span")

    Config.with_config([{:aurora_meter, :history, false}], fn ->
      AuroraMeter.track(tenant, :span_ok, 7)
      assert {:ok, 1} = Flusher.flush()
    end)

    events = collect()

    assert [{[:aurora_meter, :flush, :start], start_measurements, start_meta}] =
             only(events, [:aurora_meter, :flush, :start])

    assert is_integer(start_measurements.system_time)
    assert is_binary(start_meta.batch_id)
    assert start_meta.counter_rows == 1
    assert start_meta.history_rows == 0

    assert [{[:aurora_meter, :flush, :stop], stop_measurements, stop_meta}] =
             only(events, [:aurora_meter, :flush, :stop])

    assert stop_meta.result == :ok
    assert stop_meta.batch_id == start_meta.batch_id
    assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0
    assert stop_measurements.count == 1
    assert stop_measurements.delta_sum == 7

    # The legacy event is byte identical to what it always was.
    assert [{[:aurora_meter, :flush], %{count: 1, delta_sum: 7}, %{}}] =
             only(events, [:aurora_meter, :flush])

    assert only(events, [:aurora_meter, :flush, :error]) == []
    assert only(events, [:aurora_meter, :flush, :exception]) == []
  end

  test "I01 a flush that fails once and succeeds on retry emits stop result error, then stop result ok" do
    tenant = unique_tenant("spanretry")

    Config.with_config(
      [{:aurora_meter, :history, false}, {:aurora_meter, :storage, RefusingStorage}],
      fn ->
        AuroraMeter.track(tenant, :span_retry, 4)

        RefusingStorage.refuse(1)
        assert {:error, :refused_by_test} = Flusher.flush()
        assert {:ok, 1} = Flusher.flush()
      end
    )

    events = collect()

    assert [first, second] = Enum.map(only(events, [:aurora_meter, :flush, :stop]), &elem(&1, 2))
    assert first.result == :error
    assert second.result == :ok
    assert first.batch_id == second.batch_id, "a retry must carry the same immutable batch"

    assert length(only(events, [:aurora_meter, :flush, :start])) == 2

    assert [{_, %{count: 1}, %{error: :refused_by_test}}] =
             only(events, [:aurora_meter, :flush, :error])

    assert only(events, [:aurora_meter, :flush, :exception]) == []

    # The legacy success event fires once, for the attempt that committed.
    assert [{_, %{count: 1, delta_sum: 4}, %{}}] = only(events, [:aurora_meter, :flush])
  end

  test "I01 storage that raises emits exception and then the legacy error event" do
    tenant = unique_tenant("spanraise")
    flusher = Process.whereis(Flusher)
    :ok = Faults.forget(owner: flusher)

    Config.with_config(
      [{:aurora_meter, :history, false}, {:aurora_meter, :storage, FaultStorage}],
      fn ->
        AuroraMeter.track(tenant, :span_raise, 2)

        Faults.arm(:before_commit, :raise,
          owner: flusher,
          count: 1,
          label: :span_raise,
          when: fn context -> context[:callback] == :flush_batch end
        )

        assert {:error, _reason} = Flusher.flush()
      end
    )

    events = collect()

    assert [{_, exception_measurements, exception_meta}] =
             only(events, [:aurora_meter, :flush, :exception])

    assert exception_meta.kind == :error
    assert is_integer(exception_measurements.duration)
    assert Map.has_key?(exception_meta, :stacktrace)

    # A raise is not a `:stop`, and the legacy error event still fires, because
    # `:telemetry.span/3` re-raises into the Flusher's own rescue.
    assert only(events, [:aurora_meter, :flush, :stop]) == []
    assert length(only(events, [:aurora_meter, :flush, :error])) == 1
    assert only(events, [:aurora_meter, :flush]) == []

    # Clean up the retained batch so the next module does not inherit it.
    {:ok, _} = Flusher.flush()
  end

  test "an idle flush emits no span at all, because there was no storage call" do
    assert {:ok, 0} = Flusher.flush()

    events = collect()

    for name <- @names do
      assert only(events, name) == [], "#{inspect(name)} fired for a flush with nothing to write"
    end
  end

  defp attach do
    name = "flush-span-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach_many(
      name,
      @names,
      fn event, measurements, meta, _config ->
        send(test, {:flush_event, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  # Drains the mailbox rather than matching one message at a time: every
  # assertion here is about how many of each name fired, and a per-message
  # `assert_receive` cannot see a second one it did not ask for.
  defp collect(acc \\ []) do
    receive do
      {:flush_event, event, measurements, meta} -> collect([{event, measurements, meta} | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp only(events, name), do: Enum.filter(events, fn {event, _m, _meta} -> event == name end)
end
