defmodule AuroraMeter.Period.InvalidPeriodError do
  @moduledoc """
  A period source returned something that is not a valid period.

  Raised by `AuroraMeter.Period.current!/2` and `AuroraMeter.Period.containing/2`.
  The message names the source module first, because the source is what the
  operator has to fix.

  `reason` is one of `:not_a_map`, `:missing_key`, `:not_datetime`, `:not_utc`,
  `:inverted` or `:not_containing`. Callers that must degrade rather than fail
  (legacy event backfill, event attribution) rescue this and record an
  unresolved attribution; see `AuroraMeter.Period.containing/2`.
  """

  defexception [:source, :tenant_key, :period, :instant, :reason, :message]

  @typedoc "Why the period was rejected."
  @type reason ::
          :not_a_map | :missing_key | :not_datetime | :not_utc | :inverted | :not_containing

  @type t :: %__MODULE__{
          source: module(),
          tenant_key: String.t(),
          period: term(),
          instant: DateTime.t(),
          reason: reason(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    source = Keyword.fetch!(opts, :source)
    tenant_key = Keyword.fetch!(opts, :tenant_key)
    period = Keyword.fetch!(opts, :period)
    instant = Keyword.fetch!(opts, :instant)

    message =
      "#{inspect(source)} #{explain(reason)}. An AuroraMeter period is a half-open UTC " <>
        "interval [start, end): start belongs to the period, end does not, and the interval " <>
        "must contain the instant it is resolved for. reason=#{inspect(reason)} " <>
        "tenant_key=#{inspect(tenant_key)} instant=#{inspect(instant)} period=#{inspect(period)}"

    %__MODULE__{
      source: source,
      tenant_key: tenant_key,
      period: period,
      instant: instant,
      reason: reason,
      message: message
    }
  end

  defp explain(:not_a_map), do: "did not return a map"
  defp explain(:missing_key), do: "returned a map without all of :start, :end and :source"
  defp explain(:not_datetime), do: "returned a period whose :start or :end is not a DateTime"
  defp explain(:not_utc), do: "returned a period whose :start or :end is not in Etc/UTC"
  defp explain(:inverted), do: "returned a period whose :end is not after its :start"

  defp explain(:not_containing),
    do: "returned a period that does not contain the instant asked about"
end

defmodule AuroraMeter.Period do
  @moduledoc """
  Resolves the billing period a usage counter belongs to.

  A period is a **half-open UTC interval** `[start, end)`: `start` belongs to the
  period, `end` does not. The `end` of period N is the `start` of period N+1, so
  no instant belongs to two periods and no instant belongs to none. See
  `docs/periods.md` for the full contract, the boundary rule and two custom
  source recipes.

  `current/2` delegates to the configured `:period_source` (ADR 0003), which
  defaults to `AuroraMeter.Period.Calendar` (calendar month, UTC). Pro overrides
  it with subscription-aligned bounds, without any change to core call sites.

  `current!/2` is the same read with the contract enforced, and it is what every
  core call site uses. `current/2` is kept unvalidated for compatibility with
  hosts that call it directly.

  Instants come from `AuroraMeter.Clock`, so a test can freeze time with
  `AuroraMeter.Test.with_clock/2`.
  """

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Period.InvalidPeriodError
  alias AuroraMeter.Tenant

  @typedoc "A resolved billing window: the half-open UTC interval `[start, end)`."
  @type t :: %{start: DateTime.t(), end: DateTime.t(), source: atom()}

  @doc "Returns the active period for `tenant` at `now`."
  @callback current(tenant :: term(), now :: DateTime.t()) :: t()

  @doc """
  Returns the period that held `instant`, which may be in the past.

  Optional. When a source does not export it, `AuroraMeter.Period.containing/2`
  falls back to `c:current/2` with the past instant, which is correct for any
  source that is a pure function of the instant (the calendar month is).
  """
  @callback containing(tenant :: term(), instant :: DateTime.t()) :: t()

  @optional_callbacks containing: 2

  @doc """
  Returns the active billing period for `tenant`, unvalidated.

  Kept for hosts that call it directly. Core call sites use `current!/2`; a
  source that breaks the contract is caught there rather than here.

  ## Examples

      iex> p = AuroraMeter.Period.current("org_1")
      iex> match?(%{start: %DateTime{}, end: %DateTime{}, source: _}, p)
      true

  """
  @spec current(term(), DateTime.t()) :: t()
  def current(tenant, now \\ Clock.now()) do
    Config.period_source().current(tenant, now)
  end

  @doc """
  Returns the active billing period for `tenant` and checks the contract.

  The returned map must have `:start`, `:end` and `:source`; `:start` and `:end`
  must be `DateTime` structs in `Etc/UTC`; `:start` must be before `:end`; and
  the interval must contain `now` (`start <= now < end`). Any violation raises
  `AuroraMeter.Period.InvalidPeriodError` naming the source module.

  ## Examples

      iex> p = AuroraMeter.Period.current!("org_1")
      iex> DateTime.compare(p.start, p.end)
      :lt

  """
  @spec current!(term(), DateTime.t()) :: t()
  def current!(tenant, now \\ Clock.now()) do
    source = Config.period_source()
    validate!(source, tenant, source.current(tenant, now), now)
  end

  @doc """
  Returns the period that held `instant`, which may be in the past.

  Uses the source's `c:containing/2` when it exports one and
  `c:current/2` with `instant` otherwise, then checks the same contract with
  `instant` in place of "now".

  Raises `AuroraMeter.Period.InvalidPeriodError` with `reason: :not_containing`
  when the source cannot place the instant. **That raise is the contract**: a
  caller that must degrade rather than fail (the legacy event backfill, event
  attribution for an old occurrence) rescues it and records the event with an
  unresolved attribution instead of guessing a period.

      try do
        AuroraMeter.Period.containing(tenant, occurred_at)
      rescue
        AuroraMeter.Period.InvalidPeriodError -> :unresolved
      end

  ## Examples

      iex> p = AuroraMeter.Period.containing("org_1", ~U[2026-02-10 12:00:00Z])
      iex> {p.start, p.end}
      {~U[2026-02-01 00:00:00Z], ~U[2026-03-01 00:00:00Z]}

  """
  @spec containing(term(), DateTime.t()) :: t()
  def containing(tenant, %DateTime{} = instant) do
    source = Config.period_source()

    period =
      if Code.ensure_loaded?(source) and function_exported?(source, :containing, 2) do
        source.containing(tenant, instant)
      else
        source.current(tenant, instant)
      end

    validate!(source, tenant, period, instant)
  end

  # The happy path is one pattern match plus three comparisons, with no
  # allocation: this runs on every AuroraMeter.track/4. The cost against the
  # unvalidated read is measured in
  # docs/evidence/v1/phase-02/02c-validation-cost.md.
  defp validate!(
         source,
         tenant,
         %{
           start: %DateTime{time_zone: "Etc/UTC"} = start,
           end: %DateTime{time_zone: "Etc/UTC"} = finish,
           source: _atom
         } = period,
         instant
       ) do
    cond do
      DateTime.compare(start, finish) != :lt ->
        invalid!(:inverted, source, tenant, period, instant)

      DateTime.compare(start, instant) == :gt ->
        invalid!(:not_containing, source, tenant, period, instant)

      DateTime.compare(instant, finish) != :lt ->
        invalid!(:not_containing, source, tenant, period, instant)

      true ->
        period
    end
  end

  defp validate!(source, tenant, period, instant),
    do: invalid!(shape_reason(period), source, tenant, period, instant)

  defp shape_reason(period) when not is_map(period), do: :not_a_map

  defp shape_reason(period) do
    cond do
      not (Map.has_key?(period, :start) and Map.has_key?(period, :end) and
               Map.has_key?(period, :source)) ->
        :missing_key

      not (match?(%DateTime{}, Map.get(period, :start)) and
               match?(%DateTime{}, Map.get(period, :end))) ->
        :not_datetime

      true ->
        :not_utc
    end
  end

  defp invalid!(reason, source, tenant, period, instant) do
    raise InvalidPeriodError,
      reason: reason,
      source: source,
      tenant_key: tenant_key(tenant),
      period: period,
      instant: instant
  end

  defp tenant_key(tenant) do
    Tenant.to_key(tenant)
  rescue
    _any -> inspect(tenant)
  end
end

defmodule AuroraMeter.Period.Calendar do
  @moduledoc """
  Default period source: calendar month in UTC.

  The interval is half-open by construction: the first of the month at
  `00:00:00Z` up to, and not including, the first of the next month at
  `00:00:00Z`. It is a pure function of the instant, so it answers a past
  instant correctly through `AuroraMeter.Period.containing/2`'s fallback and
  needs no `containing/2` of its own.
  """

  @behaviour AuroraMeter.Period

  @impl AuroraMeter.Period
  @spec current(term(), DateTime.t()) :: AuroraMeter.Period.t()
  def current(_tenant, now) do
    start_date = now |> DateTime.to_date() |> Date.beginning_of_month()
    next_date = start_date |> Date.end_of_month() |> Date.add(1)

    %{
      start: DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
      end: DateTime.new!(next_date, ~T[00:00:00], "Etc/UTC"),
      source: :calendar
    }
  end
end
