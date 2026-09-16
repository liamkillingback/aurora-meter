defmodule AuroraMeter.Bench.Mode do
  @moduledoc false

  # What every `mix aurora_meter.bench` mode implements.
  #
  # A mode is either **count driven** (`operation/3`, run `procs x per` times by
  # `AuroraMeter.Bench.Runner`) or **self driving** (`custom/1`, which owns its
  # own measured phase because what it measures is not a loop: one flush, one
  # replay, or a fixed span of sustained load).
  #
  # `verify/2` is not optional and there is no default. Lower-level property P3:
  # every mode ends by asserting a correctness condition, and a run that fails
  # it is a failed run whatever its throughput was.

  alias AuroraMeter.Clock

  @type ctx :: map()
  @type tally :: map()

  @callback prepare(ctx()) :: ctx()
  @callback operation(ctx(), pos_integer(), pos_integer()) :: :ok | {:error, atom()}
  @callback custom(ctx()) :: map()
  @callback verify(ctx(), tally()) :: {boolean(), [String.t()]}

  @optional_callbacks operation: 3, custom: 1

  @doc "`{true | false, notes}` from a comparison, with both numbers in the note."
  @spec compare(String.t(), term(), term()) :: {boolean(), [String.t()]}
  def compare(label, actual, expected) do
    {actual == expected, ["#{label}: #{inspect(actual)} (expected #{inspect(expected)})"]}
  end

  @doc "Folds several checks into one verdict, keeping every note."
  @spec merge([{boolean(), [String.t()]}]) :: {boolean(), [String.t()]}
  def merge(checks) do
    {Enum.all?(checks, &elem(&1, 0)), Enum.flat_map(checks, &elem(&1, 1))}
  end

  @doc """
  An integer from a scalar SQL result.

  Postgres answers `sum()` as `numeric`, which Postgrex hands back as a
  `Decimal`, and `96 == Decimal.new("96")` is false. Every correctness check in
  this suite compares a database sum with an Elixir integer, so the conversion
  happens once, here, rather than being forgotten in one of five places.
  """
  @spec to_integer(term()) :: integer()
  def to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  def to_integer(value) when is_integer(value), do: value
  def to_integer(value) when is_float(value), do: round(value)
  def to_integer(nil), do: 0

  @doc """
  Times `fun` on the **monotonic** clock and answers `{microseconds, result}`.

  Monotonic and never a wall clock: the clock this host shares steps backwards
  by up to 439 ms on a 32.5 second cadence (`open-findings.md` X100), and a
  benchmark is exactly where that produces an absurd number rather than a
  slightly wrong one. Read in `:native` and converted through nanoseconds, so a
  sub-microsecond ETS write still has resolution.
  """
  @spec time((-> result)) :: {float(), result} when result: term()
  def time(fun) do
    started = Clock.monotonic_native()
    result = fun.()
    elapsed = Clock.monotonic_native() - started
    {:erlang.convert_time_unit(elapsed, :native, :nanosecond) / 1_000, result}
  end
end
