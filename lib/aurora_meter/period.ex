defmodule AuroraMeter.Period do
  @moduledoc """
  Resolves the billing period a usage counter belongs to.

  `current/2` delegates to the configured `:period_source` (ADR 0003), which
  defaults to `AuroraMeter.Period.Calendar` (calendar month, UTC). Pro overrides
  it with subscription-aligned bounds — without any change to core call sites.
  """

  @typedoc "A resolved billing window."
  @type t :: %{start: DateTime.t(), end: DateTime.t(), source: atom()}

  @doc "Returns the active period for `tenant` at `now`."
  @callback current(tenant :: term(), now :: DateTime.t()) :: t()

  @doc """
  Returns the active billing period for `tenant`.

  ## Examples

      iex> p = AuroraMeter.Period.current("org_1")
      iex> match?(%{start: %DateTime{}, end: %DateTime{}, source: _}, p)
      true

  """
  @spec current(term(), DateTime.t()) :: t()
  def current(tenant, now \\ DateTime.utc_now()) do
    AuroraMeter.Config.period_source().current(tenant, now)
  end
end

defmodule AuroraMeter.Period.Calendar do
  @moduledoc "Default period source: calendar month in UTC."

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
