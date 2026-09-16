if Code.ensure_loaded?(:otel_tracer) do
  defmodule AuroraMeter.OpenTelemetry do
    @moduledoc """
    Turns Aurora Meter's slow operations into OpenTelemetry spans, in the host's
    own SDK.

        # application.ex, after your OpenTelemetry SDK is configured
        AuroraMeter.OpenTelemetry.attach()

    Compiled only when `opentelemetry_api` is installed. Without it this module
    does not exist and `attach/1` raises `UndefinedFunctionError`, which is the
    documented behaviour rather than a silent no-op.

    ## It starts nothing and sends nothing

    The bridge uses the OpenTelemetry **API** and only the API. It starts no
    tracer provider, no exporter and no batch processor, and it opens no socket:
    what a host does with these spans is entirely the host's decision. With the
    API present and no SDK configured, `:otel_tracer.start_span/3` returns the
    no-op tracer's span context, every call on it is a no-op and nothing is
    recorded. That is the documented headless behaviour and not an error.

    ## What is instrumented

    | Event | Span |
    |---|---|
    | `[:aurora_meter, :record, :start\\|:stop\\|:exception]` | `aurora_meter.record` |
    | `[:aurora_meter, :flush, :start\\|:stop\\|:exception]` | `aurora_meter.flush` |
    | `[:aurora_meter, :replay, :batch]` | `aurora_meter.replay.batch` |
    | `[:aurora_meter, :credits, :hold_reconciliation]` | `aurora_meter.credits.hold_reconciliation` |
    | `[:aurora_meter, :pro, :provider, :start\\|:stop\\|:exception]` | `aurora_meter.pro.provider.<operation>` |
    | `[:aurora_meter, :pro, :outbox, :deliver]` | `aurora_meter.pro.outbox.deliver` |

    The Pro rows are attached by name. Attaching a handler to an event that
    never fires costs nothing and needs no reference to a Pro module, so a core
    build with no Pro installed behaves the same.

    The hot path is **not** instrumented and there is no switch that turns it on
    kindly: `[:aurora_meter, :track]`, `[:aurora_meter, :reserve]`,
    `[:aurora_meter, :broadcast]`, `[:aurora_meter, :cluster, :apply]` and every
    gauge are left alone. One span per increment would dominate both the hot
    path and your trace budget. A caller who wants one anyway passes the event
    name in `:events` and owns the consequence.

    ## Options

    | Option | Default | Meaning |
    |---|---|---|
    | `:name` | `:default` | handler id namespace, so two attachments can coexist |
    | `:events` | the table above | explicit override; event names or `{name, :span \\| :flat}` |
    | `:tenant` | `:drop` | `:drop`, `:digest` or `:raw`, passed to `AuroraMeter.Telemetry.redact/2` |
    | `:span_prefix` | `"aurora_meter"` | span name and attribute prefix |
    | `:include` | `[:core, :pro]` | which halves of the catalogue to instrument |

    Attributes are redacted: no tenant key, no reference, no object id, no
    provider reference, and an error is `error_class` rather than its message.
    The span status on a failure is set with an **empty** message for the same
    reason: a status message is free-form text and there is nothing safe to put
    in it.

    ## Attaching twice is attaching once

    `attach/1` removes its own handlers before installing them, so five calls
    leave the handler set one call leaves. `detach/0` removes them and leaves
    every handler attached by anything else alone.

    ## A flat event's span is exact for duration and cannot carry sub-events

    `[:aurora_meter, :replay, :batch]` and the other flat rows carry a
    `duration` measurement rather than a `:start`/`:stop` pair, so their span is
    recorded after the fact with `start_time = end_time - duration`. Both are
    native monotonic readings, which is what `:opentelemetry.timestamp/0` is,
    so the arithmetic and the API agree on units. The timing is exact and the
    parent is right; what it cannot do is hold an event recorded inside the
    operation, because the bridge hears about the operation only once it is
    over.
    """

    @behaviour AuroraMeter.OpenTelemetry.Tracer

    alias AuroraMeter.OpenTelemetry.Bridge

    @tracer_name :aurora_meter

    @doc """
    Attaches the bridge. See the module documentation for the options.
    """
    @spec attach(keyword()) :: :ok
    def attach(opts \\ []) when is_list(opts) do
      opts
      |> Keyword.put_new(:tracer, __MODULE__)
      |> Bridge.attach()
    end

    @doc "Removes every handler this bridge attached under the default name."
    @spec detach() :: :ok
    def detach, do: Bridge.detach(:default)

    @doc "Removes every handler this bridge attached under `name`."
    @spec detach(atom()) :: :ok
    def detach(name) when is_atom(name), do: Bridge.detach(name)

    # -- AuroraMeter.OpenTelemetry.Tracer --------------------------------------
    #
    # The only OpenTelemetry API functions this package calls, listed here and in
    # docs/evidence/v1/phase-08/08b-optional-integrations.md so an upgrade of
    # `opentelemetry_api` can be checked mechanically:
    #
    #   :opentelemetry.get_tracer/1
    #   :otel_tracer.start_span/3
    #   :otel_tracer.current_span_ctx/0
    #   :otel_tracer.set_current_span/1
    #   :otel_span.set_attributes/2
    #   :otel_span.set_status/3
    #   :otel_span.end_span/1, :otel_span.end_span/2
    #
    # None of them starts a provider, an exporter or a connection.

    @doc false
    @impl AuroraMeter.OpenTelemetry.Tracer
    def start_span(name, attributes) do
      # The parent is captured BEFORE the new span becomes current, and restored
      # in `end_span/3`. Without that the caller's process is left with an ended
      # span as its current one for the rest of its life, and the next span it
      # opens is parented to a span that has already finished. It matters here
      # more than in an ordinary `with_span`: these handlers run inside
      # long-lived processes (`AuroraMeter.Flusher` flushes for ever), so the
      # damage accumulates rather than ending with a request.
      parent = :otel_tracer.current_span_ctx()

      span =
        :otel_tracer.start_span(tracer(), name, %{attributes: attributes, kind: :internal})

      :otel_tracer.set_current_span(span)
      {span, parent}
    end

    @doc false
    @impl AuroraMeter.OpenTelemetry.Tracer
    def end_span({span, parent}, attributes, status) do
      :otel_span.set_attributes(span, attributes)
      if status == :error, do: :otel_span.set_status(span, :error, "")
      :otel_span.end_span(span)
      :otel_tracer.set_current_span(parent)
      :ok
    end

    @doc false
    @impl AuroraMeter.OpenTelemetry.Tracer
    def record_span(name, start_time, end_time, attributes, status) do
      # Never made current: a completed span is parented to whatever the caller's
      # context already is, and nothing after this call should be inside it.
      span =
        :otel_tracer.start_span(tracer(), name, %{
          attributes: attributes,
          kind: :internal,
          start_time: start_time
        })

      if status == :error, do: :otel_span.set_status(span, :error, "")
      :otel_span.end_span(span, end_time)
      :ok
    end

    defp tracer, do: :opentelemetry.get_tracer(@tracer_name)
  end
end
