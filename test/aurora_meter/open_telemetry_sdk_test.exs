# Runs only where the OpenTelemetry API and a real SDK are both installed. The
# rest of the bridge's behaviour is asserted through the
# `AuroraMeter.OpenTelemetry.Tracer` seam in `open_telemetry_test.exs`, which
# runs on every leg; this file is the one place the seam is not trusted.
if Code.ensure_loaded?(:otel_tracer) and Code.ensure_loaded?(:otel_simple_processor) do
  defmodule AuroraMeter.OpenTelemetrySdkTest do
    @moduledoc """
    Build unit 08b, task 08.04: the bridge against a **real tracer provider and a
    real exporter**, not against this package's own seam.

    The seam is our code. A span shape asserted only through it is a statement
    about `AuroraMeter.OpenTelemetry.Tracer`, and what actually leaves the
    process is the `#span{}` record the SDK hands an exporter. Criterion 13 (no
    span attribute carries a tenant key, a reference, an event id, a provider
    ref or an error message body) is asserted here **on that record**.

    The exporter is `:otel_exporter_pid`, which ships in the SDK for exactly
    this and sends each finished span to a pid as `{:span, record}`. Nothing
    leaves the node: the SDK is an `only: :test` dependency of this repository
    and no host gets it from us.

    `async: false`: the tracer provider, its processor and `:telemetry`'s handler
    table are all global to the node.
    """
    use ExUnit.Case, async: false

    require Record

    alias AuroraMeter.OpenTelemetry
    alias AuroraMeter.OpenTelemetry.Bridge

    Record.defrecordp(
      :span,
      Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    @flush [:aurora_meter, :flush]
    @replay [:aurora_meter, :replay, :batch]
    @provider [:aurora_meter, :pro, :provider]

    setup do
      # `set_exporter/2` is deprecated in favour of configuring the provider at
      # start, and it is what the SDK's own tests use to redirect one run. The
      # alternative is stopping and restarting the :opentelemetry application per
      # test, which is a great deal of machinery for one assertion.
      :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

      on_exit(fn ->
        OpenTelemetry.detach()
        :otel_simple_processor.set_exporter(:otel_exporter_stdout, [])
      end)

      :ok
    end

    test "the public attach/1 attaches, and a flush span pair reaches a real exporter" do
      # The PUBLIC function, not the bridge: this is the only test that runs the
      # four lines of delegation a host actually calls.
      :ok = OpenTelemetry.attach()

      assert ours(:default) == 12

      :telemetry.span(@flush, %{batch_id: "batch_secret_1"}, fn ->
        {:ok, %{result: :ok, count: 3, counter_rows: 2}}
      end)

      assert [recorded] = drain()
      assert span(recorded, :name) == "aurora_meter.flush"
      assert span(recorded, :kind) == :internal
      assert span(recorded, :end_time) >= span(recorded, :start_time)

      attributes = attributes(recorded)
      assert attributes["aurora_meter.result"] == :ok
      assert attributes["aurora_meter.count"] == 3
      assert attributes["aurora_meter.counter_rows"] == 2
    end

    test "a flat event's completed span carries the measured duration exactly" do
      :ok = OpenTelemetry.attach()

      duration = System.convert_time_unit(37, :millisecond, :native)
      :telemetry.execute(@replay, %{duration: duration, keys: 9}, %{phase: :drain})

      assert [recorded] = drain()
      assert span(recorded, :name) == "aurora_meter.replay.batch"

      assert span(recorded, :end_time) - span(recorded, :start_time) == duration,
             "the SDK recorded a duration the measurement did not give it, which means " <>
               "the native/millisecond units the bridge computes with and " <>
               ":opentelemetry.timestamp/0 disagree"

      assert attributes(recorded)["aurora_meter.keys"] == 9
    end

    test "B5 no attribute on a real span carries a tenant key, a reference, an event id or a provider ref" do
      :ok = OpenTelemetry.attach()

      :telemetry.execute(@replay, %{duration: 1_000}, %{
        tenant_key: "org_secret_42",
        reference: "ref_secret_99",
        event_id: "evt_secret_7",
        provider_ref: "provider_secret_3",
        batch_id: "batch_secret_1",
        phase: :drain
      })

      assert [recorded] = drain()
      rendered = inspect(attributes(recorded))

      for secret <- ~w(org_secret_42 ref_secret_99 evt_secret_7 provider_secret_3 batch_secret_1) do
        refute rendered =~ secret,
               "#{secret} reached a real exporter on the span's attribute map"
      end

      # And the span is not empty, so the refutations above are about redaction
      # and not about an attribute map that never arrived.
      assert attributes(recorded)["aurora_meter.phase"] == :drain
    end

    test "B5 an exception sets the status to error with no message, and carries error_class" do
      :ok = OpenTelemetry.attach()

      try do
        :telemetry.span(@flush, %{}, fn -> raise "the password is hunter2" end)
      rescue
        RuntimeError -> :ok
      end

      assert [recorded] = drain()
      assert {:status, :error, message} = span(recorded, :status)

      assert message == "",
             "the span status carries a message, which is free-form text and is exactly " <>
               "where a query or a key ends up"

      rendered = inspect({attributes(recorded), span(recorded, :status)})
      refute rendered =~ "hunter2"
      assert attributes(recorded)["aurora_meter.kind"] == :error
    end

    test "a span pair leaves the caller's current span where it found it" do
      # The defect this is here for: `start_span` makes the new span current, and
      # a handler that does not put the previous one back leaves the EMITTING
      # process pointing at a span that has ended. These handlers run inside
      # `AuroraMeter.Flusher`, which flushes for ever, so the next span would be
      # parented to a finished one and the one after that to a finished one
      # again.
      :ok = OpenTelemetry.attach()

      before = :otel_tracer.current_span_ctx()

      :telemetry.span(@flush, %{}, fn -> {:ok, %{result: :ok}} end)

      assert :otel_tracer.current_span_ctx() == before

      # And a second span is a sibling rather than a child of the first.
      :telemetry.span(@flush, %{}, fn -> {:ok, %{result: :ok}} end)

      assert [first, second] = drain()
      assert span(first, :parent_span_id) == span(second, :parent_span_id)
      assert span(second, :parent_span_id) != span(first, :span_id)
    end

    test "the provider span name carries the operation, against a real tracer" do
      :ok = OpenTelemetry.attach()

      :telemetry.span(@provider, %{operation: :report_usage}, fn ->
        {:ok, %{operation: :report_usage, result: :ok}}
      end)

      assert [recorded] = drain()
      assert span(recorded, :name) == "aurora_meter.pro.provider.report_usage"
    end

    test "attaching five times still produces one span per operation against a real tracer" do
      for _attempt <- 1..5, do: :ok = OpenTelemetry.attach()

      :telemetry.execute(@replay, %{duration: 1_000}, %{phase: :drain})

      assert length(drain()) == 1,
             "five attaches produced more than one span, so the handler set multiplied"
    end

    test "detach/0 stops the spans and leaves handlers attached by anything else alone" do
      :telemetry.attach(
        {__MODULE__, :unrelated},
        [:aurora_meter, :flush, :stop],
        fn _e, _m, _md, _c -> :ok end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :unrelated}) end)

      :ok = OpenTelemetry.attach()
      :ok = OpenTelemetry.detach()

      :telemetry.execute(@replay, %{duration: 1_000}, %{phase: :drain})

      assert drain() == []
      assert ours(:default) == 0
      assert Enum.any?(:telemetry.list_handlers([]), &(&1.id == {__MODULE__, :unrelated}))
    end

    test "B4 the hot path produces no span against a real tracer either" do
      :ok = OpenTelemetry.attach()

      for event <- Bridge.never_by_default() do
        :telemetry.execute(event, %{count: 1, duration: 1_000_000}, %{
          tenant_key: "org_1",
          feature: :api_calls
        })
      end

      assert drain() == []
    end

    # -- helpers -------------------------------------------------------------

    defp ours(name) do
      []
      |> :telemetry.list_handlers()
      |> Enum.count(&match?({AuroraMeter.OpenTelemetry, ^name, _event}, &1.id))
    end

    defp attributes(recorded), do: :otel_attributes.map(span(recorded, :attributes))

    # The simple processor exports on `on_end`, in the emitting process, so a
    # short receive is a wait for a message that has already been sent rather
    # than a race.
    defp drain(acc \\ []) do
      receive do
        {:span, recorded} -> drain([recorded | acc])
      after
        200 -> Enum.reverse(acc)
      end
    end
  end
end
