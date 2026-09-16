defmodule AuroraMeter.OpenTelemetry.Bridge do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch. Hosts call
  `AuroraMeter.OpenTelemetry.attach/1`.

  Everything the OpenTelemetry bridge does, with the tracer as a parameter.

  `AuroraMeter.OpenTelemetry` is compiled only when `opentelemetry_api` is
  installed, and it is four lines of delegation into this module plus the
  implementation of `AuroraMeter.OpenTelemetry.Tracer` that calls the real API.
  All of the behaviour lives here so that it is compiled, and tested, in a build
  with no OpenTelemetry at all.

  ## What gets a span, and what deliberately does not

  Slow work: the durable write, the flush, a replay batch, a hold
  reconciliation, an outbox delivery, a provider round trip. Every one of them
  is database-bound or network-bound and is worth a trace.

  The hot path gets nothing. `[:aurora_meter, :track]`,
  `[:aurora_meter, :reserve]`, `[:aurora_meter, :broadcast]`,
  `[:aurora_meter, :cluster, :apply]` and every gauge are **not** instrumented,
  and there is no friendly switch to turn them on. `track/4` runs at the rate a
  metering library is built for; one span per increment would dominate the hot
  path and the host's trace budget alike. A caller who really wants one passes
  the event name in `:events` and owns the consequence.

  ## Attributes carry no identifier

  Every attribute goes through `AuroraMeter.Telemetry.redact/2`, so a tenant
  key, a reference, an object id, a provider reference and an exception's
  message are all dropped before anything reaches a tracer. An error is reported
  as `error_class` (the exception module or the outcome tag), never as its
  message, which is where a query, a key or a customer's data ends up.

  `tenant: :digest` puts a stable pseudonym on the span instead, and
  `tenant: :raw` puts the key itself there. Both are spelled out at the call
  site so that carrying an identifier into a tracing pipeline is a decision
  somebody wrote down.

  ## Idempotency

  `attach/2` detaches its own handler ids before attaching, so calling it five
  times leaves exactly the same handler set as calling it once. Two different
  `:name` values are independent by construction, because the name is part of
  every handler id.
  """

  alias AuroraMeter.Clock
  alias AuroraMeter.Telemetry

  @default_name :default
  @default_prefix "aurora_meter"

  # Every event with a `duration` measurement whose work is slow enough to be
  # worth a trace. `:span` entries are the `:start`/`:stop`/`:exception` triple;
  # `:flat` entries carry `duration` on one event.
  @core_spans [
    {[:aurora_meter, :record], :span},
    {[:aurora_meter, :flush], :span},
    {[:aurora_meter, :replay, :batch], :flat},
    {[:aurora_meter, :credits, :hold_reconciliation], :flat}
  ]

  @pro_spans [
    {[:aurora_meter, :pro, :provider], :span},
    {[:aurora_meter, :pro, :outbox, :deliver], :flat}
  ]

  # Named one by one rather than derived, so the list a reader checks is the list
  # the code uses. These are the events a bridge must never instrument by
  # default; `instrumented?/1` is what the "no hot-path span" test asserts on.
  @never_by_default [
    [:aurora_meter, :track],
    [:aurora_meter, :reserve],
    [:aurora_meter, :broadcast],
    [:aurora_meter, :cluster, :apply],
    [:aurora_meter, :store, :gauge],
    [:aurora_meter, :cluster, :lag],
    [:aurora_meter, :pro, :outbox, :gauge],
    [:aurora_meter, :pro, :credits, :gauge]
  ]

  # Measurements that are span TIMES rather than facts about the operation. They
  # are what the span is built from, so repeating them as attributes would be
  # noise on every span.
  @time_measurements [:duration, :monotonic_time, :system_time]

  @typedoc "One instrumented event: its base name and whether it is a span triple."
  @type instrumented :: {[atom()], :span | :flat}

  @doc """
  The events instrumented by default, as `{base_event, :span | :flat}`.

  `:include` selects halves of the catalogue: `[:core, :pro]` by default.

  ## Examples

      iex> AuroraMeter.OpenTelemetry.Bridge.default_events(include: [:core])
      ...> |> Enum.map(&elem(&1, 0))
      ...> |> Enum.member?([:aurora_meter, :flush])
      true

      iex> AuroraMeter.OpenTelemetry.Bridge.default_events(include: [:core])
      ...> |> Enum.map(&elem(&1, 0))
      ...> |> Enum.member?([:aurora_meter, :track])
      false

  """
  @spec default_events(keyword()) :: [instrumented()]
  def default_events(opts \\ []) do
    include = Keyword.get(opts, :include, [:core, :pro])

    core = if :core in include, do: @core_spans, else: []
    pro = if :pro in include, do: @pro_spans, else: []
    core ++ pro
  end

  @doc """
  Event names this bridge never instruments unless the caller lists them.

  ## Examples

      iex> [:aurora_meter, :track] in AuroraMeter.OpenTelemetry.Bridge.never_by_default()
      true

  """
  @spec never_by_default() :: [[atom()]]
  def never_by_default, do: @never_by_default

  @doc """
  Attaches one `:telemetry` handler per instrumented event name.

  Options are `AuroraMeter.OpenTelemetry.attach/1`'s, plus `:tracer`, the module
  implementing `AuroraMeter.OpenTelemetry.Tracer`.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts) do
    tracer = Keyword.fetch!(opts, :tracer)
    name = Keyword.get(opts, :name, @default_name)
    events = Keyword.get_lazy(opts, :events, fn -> default_events(opts) end)

    config = %{
      tracer: tracer,
      name: name,
      tenant: Keyword.get(opts, :tenant, :drop),
      prefix: Keyword.get(opts, :span_prefix, @default_prefix)
    }

    # Detaching first is what makes a second attach a no-op rather than a second
    # handler set. `:telemetry` refuses a duplicate id, so without this an
    # honest caller would get {:error, :already_exists} and a careless one would
    # get two spans per operation.
    detach(name)

    Enum.each(normalise(events), fn {base, form} ->
      Enum.each(names(base, form), fn event ->
        :telemetry.attach(
          handler_id(name, event),
          event,
          &__MODULE__.handle/4,
          Map.merge(config, %{base: base, form: form})
        )
      end)
    end)

    :ok
  end

  @doc "Removes every handler attached under `name`, and nothing else."
  @spec detach(atom()) :: :ok
  def detach(name) do
    []
    |> :telemetry.list_handlers()
    |> Enum.filter(&match?({AuroraMeter.OpenTelemetry, ^name, _event}, &1.id))
    |> Enum.each(&:telemetry.detach(&1.id))

    :ok
  end

  @doc "The handler id this bridge uses for `name` and `event`."
  @spec handler_id(atom(), [atom()]) :: {module(), atom(), [atom()]}
  def handler_id(name, event), do: {AuroraMeter.OpenTelemetry, name, event}

  @doc false
  @spec handle([atom()], map(), map(), map()) :: :ok
  def handle(event, measurements, metadata, config) do
    case {config.form, List.last(event)} do
      {:span, :start} -> on_start(event, metadata, config)
      {:span, :stop} -> on_finish(event, measurements, metadata, config, status(metadata))
      {:span, :exception} -> on_finish(event, measurements, metadata, config, :error)
      {:flat, _last} -> on_flat(event, measurements, metadata, config)
    end
  end

  # -- span pairs ------------------------------------------------------------

  defp on_start(event, metadata, config) do
    span = config.tracer.start_span(span_name(event, metadata, config), %{})
    Process.put(context_key(config, metadata), span)
    :ok
  end

  defp on_finish(_event, measurements, metadata, config, status) do
    case Process.delete(context_key(config, metadata)) do
      nil ->
        # A `:stop` with no `:start` means the bridge was attached in the middle
        # of an operation. Recording a span with an invented start would put a
        # made-up duration on a trace, so nothing is recorded.
        :ok

      span ->
        config.tracer.end_span(span, attributes(measurements, metadata, config), status)
        :ok
    end
  end

  # -- flat events with a duration -------------------------------------------

  defp on_flat(event, measurements, metadata, config) do
    case Map.get(measurements, :duration) do
      duration when is_integer(duration) and duration >= 0 ->
        # Through the clock seam, and monotonic: a span's start and end are an
        # in-memory elapsed pair, and a wall clock that steps backwards would put
        # a negative duration on a trace (`open-findings.md` X100). The reading
        # is milliseconds and `duration` is native, so the end instant is
        # converted rather than the duration: `end_time - duration` is then
        # exactly the measurement, and only the absolute instant is rounded to
        # the millisecond.
        end_time = System.convert_time_unit(Clock.monotonic_ms(), :millisecond, :native)

        config.tracer.record_span(
          span_name(event, metadata, config),
          end_time - duration,
          end_time,
          attributes(measurements, metadata, config),
          status(metadata)
        )

        :ok

      _other ->
        # No duration, no span. A zero-length span at the instant the handler
        # happened to run is a fabricated measurement, and a trace is read as
        # though its durations were measured.
        :ok
    end
  end

  # -- shared ----------------------------------------------------------------

  defp status(metadata) do
    case Map.get(metadata, :result) do
      :error -> :error
      {:error, _reason} -> :error
      _other -> :unset
    end
  end

  # `telemetry_span_context` is unique per span and `:telemetry.span/3` runs its
  # handlers in the emitting process, so this key cannot collide across
  # processes or across two spans in one process.
  defp context_key(config, metadata) do
    {AuroraMeter.OpenTelemetry, config.name, Map.get(metadata, :telemetry_span_context)}
  end

  defp span_name(event, metadata, config) do
    segments =
      event
      |> Enum.drop(1)
      |> Enum.reject(&(&1 in [:start, :stop, :exception]))

    segments =
      case {config.base, Map.get(metadata, :operation)} do
        {[:aurora_meter, :pro, :provider], operation}
        when is_atom(operation) and operation != nil ->
          segments ++ [operation]

        _other ->
          segments
      end

    Enum.join([config.prefix | segments], ".")
  end

  defp attributes(measurements, metadata, config) do
    numeric =
      for {key, value} <- measurements,
          key not in @time_measurements,
          is_number(value),
          into: %{},
          do: {"#{config.prefix}.#{key}", value}

    metadata
    |> Telemetry.redact(tenant: config.tenant)
    |> Map.drop([:telemetry_span_context])
    |> Enum.reduce(numeric, fn {key, value}, acc ->
      Map.put(acc, "#{config.prefix}.#{key}", value)
    end)
  end

  # A caller may pass `:events` as a plain list of event names, in which case
  # each one is treated as a flat event unless the bridge knows it as a span
  # triple. That is what makes the escape hatch usable: `events: [[:aurora_meter,
  # :track]]` is the whole opt-in.
  defp normalise(events) do
    Enum.map(events, fn
      {base, form} when form in [:span, :flat] -> {base, form}
      base when is_list(base) -> {base, known_form(base)}
    end)
  end

  defp known_form(base) do
    case Enum.find(@core_spans ++ @pro_spans, fn {known, _form} -> known == base end) do
      {_known, form} -> form
      nil -> :flat
    end
  end

  defp names(base, :span),
    do: [base ++ [:start], base ++ [:stop], base ++ [:exception]]

  defp names(base, :flat), do: [base]
end
