defmodule AuroraMeter.Test.RecordingTracer do
  @moduledoc """
  An `AuroraMeter.OpenTelemetry.Tracer` that records what it was asked to do and
  sends it to the calling process.

  It is not a stand-in for an OpenTelemetry SDK and does not pretend to be one.
  It is the assertion surface for the properties that belong to the **bridge**:
  which events produce a span and which do not, how many spans one operation
  produces, what the span is called, and what is in its attributes. Those are
  the acceptance criteria, and none of them is a property of the SDK.

  Every call is sent to the process registered as `owner` at `install/0`, so a
  test asserts with `assert_receive` and, for the negative cases, with
  `refute_receive`.
  """

  @behaviour AuroraMeter.OpenTelemetry.Tracer

  @key {__MODULE__, :owner}

  @doc "Routes every recorded call to the calling process."
  @spec install() :: :ok
  def install do
    :persistent_term.put(@key, self())
    :ok
  end

  @doc "Stops routing. Calls after this are dropped rather than sent anywhere."
  @spec uninstall() :: :ok
  def uninstall do
    :persistent_term.erase(@key)
    :ok
  end

  @doc "Every span recorded so far, drained from the calling process's mailbox."
  @spec drain() :: [tuple()]
  def drain(acc \\ []) do
    receive do
      {__MODULE__, _kind, _payload} = message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @impl AuroraMeter.OpenTelemetry.Tracer
  def start_span(name, attributes) do
    span = {name, System.monotonic_time(), make_ref()}
    send_owner({:start_span, %{name: name, attributes: attributes, span: span}})
    span
  end

  @impl AuroraMeter.OpenTelemetry.Tracer
  def end_span(span, attributes, status) do
    send_owner(
      {:end_span,
       %{
         span: span,
         attributes: attributes,
         status: status,
         at: System.monotonic_time()
       }}
    )

    :ok
  end

  @impl AuroraMeter.OpenTelemetry.Tracer
  def record_span(name, start_time, end_time, attributes, status) do
    send_owner(
      {:record_span,
       %{
         name: name,
         start_time: start_time,
         end_time: end_time,
         duration: end_time - start_time,
         attributes: attributes,
         status: status
       }}
    )

    :ok
  end

  defp send_owner(payload) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      pid -> send(pid, {__MODULE__, elem(payload, 0), elem(payload, 1)})
    end
  end
end

defmodule AuroraMeter.Test.RaisingTracer do
  @moduledoc """
  An `AuroraMeter.OpenTelemetry.Tracer` whose `record_span/5` raises.

  For the failure mode in which a bridge handler raises: `:telemetry` detaches
  that one handler and the others keep working. A test that only attached one
  handler could not tell that apart from "the whole bridge stopped".
  """

  @behaviour AuroraMeter.OpenTelemetry.Tracer

  @impl AuroraMeter.OpenTelemetry.Tracer
  def start_span(_name, _attributes), do: :span

  @impl AuroraMeter.OpenTelemetry.Tracer
  def end_span(_span, _attributes, _status), do: :ok

  @impl AuroraMeter.OpenTelemetry.Tracer
  def record_span(name, _start_time, _end_time, _attributes, _status) do
    raise "AuroraMeter.Test.RaisingTracer refuses to record #{name}"
  end
end
