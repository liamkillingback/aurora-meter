defmodule AuroraMeter.OpenTelemetryTest do
  @moduledoc """
  Build unit 08b, task 08.04: the OpenTelemetry bridge.

  Every assertion here is about the **bridge**: which events become spans, how
  many handlers an attach leaves behind, what a span is called and what is in
  its attributes. None of them is a property of an OpenTelemetry SDK, which is
  why they are asserted against `AuroraMeter.Test.RecordingTracer` through the
  `:tracer` seam rather than against a tracer provider.

  What that leaves unproven is stated rather than implied away:
  `AuroraMeter.OpenTelemetry` itself, the four `:otel_*` calls that turn these
  three callbacks into real spans, is compiled only when `opentelemetry_api` is
  installed and **was not installed in this run**. See
  `docs/evidence/v1/phase-08/08b-optional-integrations.md`.

  `async: false`: `:telemetry` handlers are global to the node and the recording
  tracer routes through `:persistent_term`.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.OpenTelemetry.Bridge
  alias AuroraMeter.Test.RecordingTracer

  @flush [:aurora_meter, :flush]
  @replay [:aurora_meter, :replay, :batch]
  @provider [:aurora_meter, :pro, :provider]

  setup do
    RecordingTracer.install()

    on_exit(fn ->
      Bridge.detach(:default)
      Bridge.detach(:a)
      Bridge.detach(:b)
      RecordingTracer.uninstall()
    end)

    :ok
  end

  test "B3 attach five times leaves exactly one handler per instrumented event" do
    before = ours(:default)
    assert before == 0

    for _attempt <- 1..5, do: :ok = attach()

    expected = Enum.sum(Enum.map(Bridge.default_events(), &length(names(&1))))
    assert expected == 12
    assert ours(:default) == expected
  end

  test "B3 detach removes every handler under the name and leaves unrelated handlers alone" do
    :ok =
      :telemetry.attach(
        {__MODULE__, :unrelated},
        [:aurora_meter, :flush, :stop],
        fn _e, _m, _md, _c -> :ok end,
        nil
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, :unrelated}) end)

    :ok = attach()
    assert ours(:default) > 0

    :ok = Bridge.detach(:default)

    assert ours(:default) == 0
    assert Enum.any?(:telemetry.list_handlers([]), &(&1.id == {__MODULE__, :unrelated}))
  end

  test "B3 two names coexist and detach independently" do
    :ok = attach(name: :a)
    :ok = attach(name: :b)

    assert ours(:a) == 12
    assert ours(:b) == 12

    :ok = Bridge.detach(:a)

    assert ours(:a) == 0
    assert ours(:b) == 12
  end

  test "B4 no span is created for track, reserve, broadcast, cluster.apply or any gauge event" do
    :ok = attach()

    for event <- Bridge.never_by_default() do
      :telemetry.execute(event, %{count: 1, duration: 1_000_000}, %{
        tenant_key: "org_1",
        feature: :api_calls
      })
    end

    assert RecordingTracer.drain() == [],
           "a hot-path or gauge event produced a span, which is exactly what " <>
             "the bridge must never do by default"
  end

  test "B4 passing a hot event explicitly in :events does create a span" do
    :ok = attach(events: [[:aurora_meter, :track]])

    :telemetry.execute([:aurora_meter, :track], %{count: 1, duration: 7_000}, %{
      feature: :api_calls
    })

    assert [{RecordingTracer, :record_span, span}] = RecordingTracer.drain()
    assert span.name == "aurora_meter.track"
    assert span.duration == 7_000
  end

  test "a flush span pair produces exactly one span that brackets the operation and carries result" do
    :ok = attach()

    {_result, measurements} = timed_flush()

    assert [
             {RecordingTracer, :start_span, started},
             {RecordingTracer, :end_span, ended}
           ] = RecordingTracer.drain()

    assert started.name == "aurora_meter.flush"
    assert ended.span == started.span
    assert ended.status == :unset
    assert ended.attributes["aurora_meter.result"] == :ok
    assert ended.attributes["aurora_meter.count"] == 3

    # The span brackets the operation: the tracer's own elapsed time and the
    # duration :telemetry.span/3 measured agree. A pair that opened and closed
    # around nothing would pass a "one span" assertion and fail this one.
    {_name, started_at, _ref} = started.span
    elapsed_ms = System.convert_time_unit(ended.at - started_at, :native, :millisecond)
    measured_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    assert elapsed_ms >= 15
    assert abs(elapsed_ms - measured_ms) <= 10
  end

  test "a flat event with a duration produces exactly one completed span with that duration" do
    :ok = attach()

    :telemetry.execute(@replay, %{duration: 4_321, keys: 9, scanned: 20}, %{
      phase: :drain,
      generation: 7,
      cursor: %{"seq" => 12}
    })

    assert [{RecordingTracer, :record_span, span}] = RecordingTracer.drain()
    assert span.name == "aurora_meter.replay.batch"
    assert span.duration == 4_321
    assert span.end_time - span.start_time == 4_321
    assert span.attributes["aurora_meter.keys"] == 9
  end

  test "a flat event with no duration produces no span at all rather than a zero-length one" do
    :ok = attach()

    :telemetry.execute(@replay, %{keys: 9}, %{phase: :drain})

    assert RecordingTracer.drain() == []
  end

  test "B5 an exception event sets the span status to error and records error_class, not the message" do
    :ok = attach()

    try do
      :telemetry.span(@flush, %{}, fn -> raise "the password is hunter2" end)
    rescue
      RuntimeError -> :ok
    end

    assert [
             {RecordingTracer, :start_span, _started},
             {RecordingTracer, :end_span, ended}
           ] = RecordingTracer.drain()

    assert ended.status == :error
    assert ended.attributes["aurora_meter.kind"] == :error
    refute rendered(ended.attributes) =~ "hunter2"
  end

  test "B5 a stop carrying result: :error sets the span status to error" do
    :ok = attach()

    :telemetry.span(@flush, %{}, fn ->
      {:ok, %{result: :error, error: %RuntimeError{message: "boom"}}}
    end)

    assert [_started, {RecordingTracer, :end_span, ended}] = RecordingTracer.drain()
    assert ended.status == :error
    assert ended.attributes["aurora_meter.error_class"] == "RuntimeError"
    refute rendered(ended.attributes) =~ "boom"
  end

  test "B5 no span attribute contains the tenant key, a reference or an event id by default" do
    :ok = attach()

    emit_replay_with_identifiers()

    assert [{RecordingTracer, :record_span, span}] = RecordingTracer.drain()
    text = rendered(span.attributes)

    refute text =~ "org_secret_42"
    refute text =~ "ref_secret_99"
    refute text =~ "evt_secret_7"
    refute text =~ "provider_secret_3"
  end

  test "B5 tenant: :digest puts a digest on the span and tenant: :raw is required for the key" do
    :ok = attach(tenant: :digest)
    emit_replay_with_identifiers()
    assert [{RecordingTracer, :record_span, digested}] = RecordingTracer.drain()

    refute rendered(digested.attributes) =~ "org_secret_42"
    assert digested.attributes["aurora_meter.tenant_digest"] =~ ~r/^[0-9a-f]{16}$/

    :ok = attach(tenant: :raw)
    emit_replay_with_identifiers()
    assert [{RecordingTracer, :record_span, raw}] = RecordingTracer.drain()

    assert raw.attributes["aurora_meter.tenant_key"] == "org_secret_42"
  end

  test "the provider span name carries the bounded operation name" do
    :ok = attach()

    :telemetry.span(@provider, %{operation: :report_usage}, fn ->
      {:ok, %{operation: :report_usage, result: :ok}}
    end)

    assert [{RecordingTracer, :start_span, started}, _ended] = RecordingTracer.drain()
    assert started.name == "aurora_meter.pro.provider.report_usage"
  end

  test "a handler that raises is detached by telemetry and the other handlers keep producing spans" do
    :ok = attach(name: :a, tracer: AuroraMeter.Test.RaisingTracer)
    :ok = attach(name: :b)

    assert ours(:a) == 12

    :telemetry.execute(@replay, %{duration: 100}, %{phase: :drain})

    # :telemetry detaches the handler that raised, and only that one.
    assert ours(:a) == 11
    assert ours(:b) == 12

    assert [{RecordingTracer, :record_span, span}] = RecordingTracer.drain()
    assert span.name == "aurora_meter.replay.batch"

    :telemetry.execute(@replay, %{duration: 200}, %{phase: :compare})
    assert [{RecordingTracer, :record_span, second}] = RecordingTracer.drain()
    assert second.duration == 200
  end

  test "a stop with no matching start records nothing rather than inventing a start" do
    :ok = attach()

    :telemetry.execute(@flush ++ [:stop], %{duration: 10}, %{
      result: :ok,
      telemetry_span_context: make_ref()
    })

    assert RecordingTracer.drain() == []
  end

  # -- helpers ---------------------------------------------------------------

  defp attach(opts \\ []) do
    opts
    |> Keyword.put_new(:tracer, RecordingTracer)
    |> Bridge.attach()
  end

  defp ours(name) do
    []
    |> :telemetry.list_handlers()
    |> Enum.count(&match?({AuroraMeter.OpenTelemetry, ^name, _event}, &1.id))
  end

  defp names({base, :span}), do: [base ++ [:start], base ++ [:stop], base ++ [:exception]]
  defp names({base, :flat}), do: [base]

  defp timed_flush do
    parent = self()

    :telemetry.attach(
      {__MODULE__, :measure},
      @flush ++ [:stop],
      fn _event, measurements, _metadata, _config -> send(parent, {:measured, measurements}) end,
      nil
    )

    result =
      :telemetry.span(@flush, %{}, fn ->
        Process.sleep(20)
        {:ok, %{result: :ok, count: 3}}
      end)

    :telemetry.detach({__MODULE__, :measure})
    assert_receive {:measured, measurements}
    {result, measurements}
  end

  defp emit_replay_with_identifiers do
    :telemetry.execute(@replay, %{duration: 1_000}, %{
      tenant_key: "org_secret_42",
      reference: "ref_secret_99",
      event_id: "evt_secret_7",
      provider_ref: "provider_secret_3",
      phase: :drain
    })
  end

  defp rendered(attributes), do: inspect(attributes)
end
