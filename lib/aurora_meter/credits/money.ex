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

      iex> AuroraMeter.Credits.Money.format_compact(1_234_000_000)
      "$1.2k"

  """

  @micro_per_dollar 1_000_000
  @micro_per_cent 10_000
  @micro_per_thousand_dollars 1_000_000_000

  # 9e15 micro-dollars is 9 billion USD. The ledger's columns are `bigint`, so
  # the hard ceiling is 9.22e18; this limit sits three orders of magnitude below
  # it, and the headroom is the point rather than caution. `balance_after`, the
  # conservation aggregate and the sum over a wallet's lots are all *sums* of
  # amounts, so a limit close to the column's own would admit writes that are
  # individually legal and whose total is not. A guard that only refuses the
  # last straw is no guard.
  @max_micro 9_000_000_000_000_000

  # The magnitude at which a value *rounds up to* one of each unit, so
  # `format_compact/1` never emits "$1000k": $999.95 is already "$1k".
  @compact_units [
    {999_950_000_000_000, 1_000_000_000_000_000, "B"},
    {999_950_000_000, 1_000_000_000_000, "M"},
    {999_950_000, @micro_per_thousand_dollars, "k"}
  ]

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
  Returns `amount` when it is an integer the ledger can hold, and raises
  `ArgumentError` naming the limit when it is not.

  The limit is #{@max_micro} micro-dollars either side of zero, which is nine
  billion US dollars. `AuroraMeter.Credits`'s `grant/3`, `hold/4`, `debit/4`,
  `reverse/4`, `settle/3` and `set_low_balance_threshold/2` all call it **before
  any database work**, so an amount out of range is an `ArgumentError` from the
  function the host called rather than a `DBConnection.EncodeError` from the
  driver two layers down.

  It is deliberately not called by `from_cents/1`, `to_cents/2` or
  `from_decimal/1`: those are pure conversions, a host may legitimately convert
  a figure it is not about to write, and changing them would change the meaning
  of code that has nothing to do with the ledger.

  ## Examples

      iex> AuroraMeter.Credits.Money.assert_range!(20_000_000)
      20_000_000

      iex> AuroraMeter.Credits.Money.assert_range!(-20_000_000)
      -20_000_000

      iex> AuroraMeter.Credits.Money.assert_range!(9_000_000_000_000_001)
      ** (ArgumentError) amount 9000000000000001 is outside the range AuroraMeter.Credits can hold: at most 9000000000000000 micro-dollars (9,000,000,000 USD) either side of zero

      iex> AuroraMeter.Credits.Money.assert_range!(1.5)
      ** (ArgumentError) amount must be an integer number of micro-dollars, got: 1.5

  """
  @spec assert_range!(term()) :: micro()
  def assert_range!(amount)
      when is_integer(amount) and amount >= -@max_micro and amount <= @max_micro,
      do: amount

  def assert_range!(amount) when is_integer(amount) do
    raise ArgumentError,
          "amount #{amount} is outside the range AuroraMeter.Credits can hold: at most " <>
            "#{@max_micro} micro-dollars (9,000,000,000 USD) either side of zero"
  end

  def assert_range!(other) do
    raise ArgumentError,
          "amount must be an integer number of micro-dollars, got: #{inspect(other)}"
  end

  @doc """
  The largest magnitude `assert_range!/1` admits.

  ## Examples

      iex> AuroraMeter.Credits.Money.max_micro()
      9_000_000_000_000_000

  """
  @spec max_micro() :: pos_integer()
  def max_micro, do: @max_micro

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

  @doc """
  Formats micro-dollars as a short label for a chart axis or a stat tile:
  thousands, millions and billions collapse to one decimal (`"$1.2k"`, `"$3M"`),
  ordinary amounts render as dollars and cents (`"$0.07"`), and a sub-cent
  amount keeps just enough precision to stay non-zero (`"$0.000015"`) rather
  than rounding away to `"$0.00"`.

  Use `format/2` wherever the exact amount matters; this is for the places where
  space matters more than the last decimal.

  ## Examples

      iex> AuroraMeter.Credits.Money.format_compact(1_234_000_000)
      "$1.2k"

      iex> AuroraMeter.Credits.Money.format_compact(70_000)
      "$0.07"

      iex> AuroraMeter.Credits.Money.format_compact(0)
      "$0"

      iex> AuroraMeter.Credits.Money.format_compact(2_000_000_000)
      "$2k"

      iex> AuroraMeter.Credits.Money.format_compact(-4_500_000_000_000)
      "-$4.5M"

      iex> AuroraMeter.Credits.Money.format_compact(15)
      "$0.000015"

  """
  @spec format_compact(micro()) :: String.t()
  def format_compact(0), do: "$0"

  def format_compact(micro) when is_integer(micro) do
    sign = if micro < 0, do: "-", else: ""
    magnitude = abs(micro)

    case Enum.find(@compact_units, fn {threshold, _scale, _suffix} -> magnitude >= threshold end) do
      {_threshold, scale, suffix} -> sign <> scaled(magnitude, scale) <> suffix
      nil -> sign <> sub_thousand(magnitude)
    end
  end

  # One decimal place of `scale`, with a bare `.0` trimmed off.
  @spec scaled(non_neg_integer(), pos_integer()) :: String.t()
  defp scaled(magnitude, scale) do
    tenths = round_div(magnitude, div(scale, 10))
    whole = Integer.to_string(div(tenths, 10))

    case rem(tenths, 10) do
      0 -> "$" <> whole
      tenth -> "$" <> whole <> "." <> Integer.to_string(tenth)
    end
  end

  # Below a cent, two decimals would render every amount as "$0.00" — and
  # sub-cent prices are exactly what the micro-dollar unit exists for — so fall
  # back to full precision and trim the trailing zeros.
  @spec sub_thousand(pos_integer()) :: String.t()
  defp sub_thousand(magnitude) when magnitude < @micro_per_cent,
    do: magnitude |> format(precision: 6) |> String.replace(~r/0+$/, "")

  defp sub_thousand(magnitude), do: format(magnitude)

  # Integer division rounding half away from zero (`Kernel.round/1` semantics,
  # without going through a float).
  @spec round_div(integer(), pos_integer()) :: integer()
  defp round_div(value, divisor) when value >= 0, do: div(value + div(divisor, 2), divisor)
  defp round_div(value, divisor), do: -round_div(-value, divisor)
end
