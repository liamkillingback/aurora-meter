defmodule AuroraMeter.OpenTelemetry.Tracer do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  The three calls `AuroraMeter.OpenTelemetry.Bridge` makes on a tracer.

  It is a behaviour rather than a direct call into `:otel_tracer` for one
  reason: `opentelemetry_api` is an optional dependency, and every rule the
  bridge is judged on (one handler per event however many times you attach, no
  span for a hot-path event, no tenant key in an attribute) is a property of the
  **bridge**, not of the SDK. With the tracer behind a seam those rules are
  asserted against a tracer that records what it was asked to do, in a build
  that has no OpenTelemetry at all.

  `AuroraMeter.OpenTelemetry` supplies the implementation that calls the real
  API. It is the only module in the package that names `:otel_tracer`, and it
  exists only when the dependency does.
  """

  @typedoc """
  Whatever the implementation needs to close a span it opened.

  Opaque to the bridge, which only stores it and hands it back. The real
  implementation puts the **parent** in it as well as the span, because a span
  that is made current has to put the previous one back when it ends, and these
  handlers run inside processes that live for ever.
  """
  @type span :: term()

  @typedoc """
  Span attributes. Keys are already prefixed and redacted by the bridge; an
  implementation must not add any of its own.
  """
  @type attributes :: %{optional(String.t()) => term()}

  @typedoc "`:unset` or `:error`; the bridge never reports a span as explicitly ok."
  @type status :: :unset | :error

  @doc """
  Opens a span and makes it current, so work inside it nests underneath.

  Called from the `:start` handler, which `:telemetry.span/3` runs in the
  emitting process, so the parent is the caller's own current span.
  """
  @callback start_span(name :: String.t(), attributes()) :: span()

  @doc "Closes a span opened by `c:start_span/2`, adding attributes and a status."
  @callback end_span(span(), attributes(), status()) :: :ok

  @doc """
  Records an already-finished span from its native monotonic start and end.

  This is how a flat event that carries a `duration` measurement becomes a span:
  the times are exact, and the span is parented to the caller's current context.
  What it cannot do is carry an event recorded *inside* the operation, because
  by the time the bridge hears about it the operation is over.
  """
  @callback record_span(
              name :: String.t(),
              start_time :: integer(),
              end_time :: integer(),
              attributes(),
              status()
            ) :: :ok
end
