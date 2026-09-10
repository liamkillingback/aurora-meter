defmodule AuroraMeter.Credits.Money do
  @moduledoc """
  Conversions between the ledger's integer micro-dollars and the units the rest
  of the world uses.

  `AuroraMeter.Credits` stores every amount as an integer number of
  micro-dollars (1 µ$ = 1e-6 USD, so `1_000_000` is one dollar and `10_000` is
  one cent). Integers keep the ledger exact under concurrency and let a price
  of a few thousandths of a cent — a token, a request, a byte — be charged
  without rounding. Convert at the edges:

      iex> AuroraMeter.Credits.Money.from_cents(1_235)
      12_350_000

      iex> AuroraMeter.Credits.Money.to_cents(12_350_000)
      1_235

      iex> AuroraMeter.Credits.Money.from_decimal(Decimal.new("12.35"))
      12_350_000

      iex> AuroraMeter.Credits.Money.format(12_350_000)
      "$12.35"

  """

  @micro_per_dollar 1_000_000
  @micro_per_cent 10_000

  @typedoc "An amount in micro-dollars."
  @type micro :: integer()

  @doc """
  Converts cents to micro-dollars.

  ## Examples

      iex> AuroraMeter.Credits.Money.from_cents(100)
      1_000_000

      iex> AuroraMeter.Credits.Money.from_cents(-50)
      -500_000

  """
  @spec from_cents(integer()) :: micro()
  def from_cents(cents) when is_integer(cents), do: cents * @micro_per_cent

  @doc """
  Converts micro-dollars to whole cents, rounding with `:round` (default, half
  away from zero), `:floor` or `:ceil`.

  ## Examples

      iex> AuroraMeter.Credits.Money.to_cents(1_234_999)
      123

      iex> AuroraMeter.Credits.Money.to_cents(1_235_000)
      124

      iex> AuroraMeter.Credits.Money.to_cents(1_230_001, rounding: :ceil)
      124

      iex> AuroraMeter.Credits.Money.to_cents(-1_235_000, rounding: :floor)
      -124

  """
  @spec to_cents(micro(), rounding: :round | :floor | :ceil) :: integer()
  def to_cents(micro, opts \\ []) when is_integer(micro) do
    case Keyword.get(opts, :rounding, :round) do
      :round -> round_div(micro, @micro_per_cent)
      :floor -> Integer.floor_div(micro, @micro_per_cent)
      :ceil -> -Integer.floor_div(-micro, @micro_per_cent)
    end
  end

  @doc """
  Converts a `Decimal` amount of dollars to micro-dollars, rounding half up at
  the sixth decimal place.

  ## Examples

      iex> AuroraMeter.Credits.Money.from_decimal(Decimal.new("0.000015"))
      15

      iex> AuroraMeter.Credits.Money.from_decimal(Decimal.new("-2.5"))
      -2_500_000

  """
  @spec from_decimal(Decimal.t()) :: micro()
  def from_decimal(%Decimal{} = dollars) do
    dollars
    |> Decimal.mult(@micro_per_dollar)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  @doc """
  Formats micro-dollars as a dollar string with `:precision` decimals
  (default 2), rounding half away from zero; negative amounts as `"-$1.00"`.

  ## Examples

      iex> AuroraMeter.Credits.Money.format(12_350_000)
      "$12.35"

      iex> AuroraMeter.Credits.Money.format(-1_000_000)
      "-$1.00"

      iex> AuroraMeter.Credits.Money.format(15, precision: 6)
      "$0.000015"

      iex> AuroraMeter.Credits.Money.format(1_999_999, precision: 0)
      "$2"

  """
  @spec format(micro(), precision: 0..6) :: String.t()
  def format(micro, opts \\ []) when is_integer(micro) do
    precision = Keyword.get(opts, :precision, 2)
    scale = Integer.pow(10, 6 - precision)
    units = round_div(abs(micro), scale)
    whole = Integer.pow(10, precision)
    sign = if micro < 0 and units > 0, do: "-", else: ""

    fraction =
      if precision == 0,
        do: "",
        else: "." <> String.pad_leading(Integer.to_string(rem(units, whole)), precision, "0")

    sign <> "$" <> Integer.to_string(div(units, whole)) <> fraction
  end

  # Integer division rounding half away from zero (`Kernel.round/1` semantics,
  # without going through a float).
  @spec round_div(integer(), pos_integer()) :: integer()
  defp round_div(value, divisor) when value >= 0, do: div(value + div(divisor, 2), divisor)
  defp round_div(value, divisor), do: -round_div(-value, divisor)
end
