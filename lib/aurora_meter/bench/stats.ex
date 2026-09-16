defmodule AuroraMeter.Bench.Stats do
  @moduledoc false

  # Percentiles and medians for `mix aurora_meter.bench`.
  #
  # **Nearest rank**, stated here and in `priv/bench/report.schema.json` so
  # nobody has to guess which definition produced a number: sort ascending, take
  # the element at `ceil(p * n)`, one based. No interpolation, so every reported
  # percentile is a sample that was actually observed.
  #
  # Medians are the same function at p50, which is deliberate: the run summary
  # and the cross-run comparison must not disagree about what "the middle one"
  # means. For an even count `ceil(0.5 * n)` is the LOWER of the two middles and
  # no average is taken, so every reported median is a run that happened. The
  # runner takes five runs per mode for exactly this reason: at five the median
  # is unambiguous.

  @doc "The nearest-rank percentile of `samples` (`p` in 0..1). `nil` for an empty list."
  @spec percentile([number()], float()) :: number() | nil
  def percentile([], _p), do: nil

  def percentile(samples, p) when is_list(samples) and p >= 0 and p <= 1 do
    sorted = Enum.sort(samples)
    n = length(sorted)
    rank = max(min(ceil(p * n), n), 1)
    Enum.at(sorted, rank - 1)
  end

  @doc "The median of `samples` (p50, nearest rank). `nil` for an empty list."
  @spec median([number()]) :: number() | nil
  def median(samples), do: percentile(samples, 0.50)

  @doc """
  The latency block for a set of microsecond samples.

  Answers `nil` for every percentile when nothing was sampled, and never a
  zero: an unsampled percentile and a genuinely instant operation are different
  facts and a benchmark that reports them the same way is unreadable.
  """
  @spec summary([number()]) :: %{
          samples: non_neg_integer(),
          p50: number() | nil,
          p95: number() | nil,
          p99: number() | nil,
          max: number() | nil,
          method: String.t()
        }
  def summary(samples) when is_list(samples) do
    %{
      samples: length(samples),
      p50: percentile(samples, 0.50),
      p95: percentile(samples, 0.95),
      p99: percentile(samples, 0.99),
      max: if(samples == [], do: nil, else: Enum.max(samples)),
      method: "nearest_rank"
    }
  end

  @doc "Operations per second from an operation count and a measured duration in milliseconds."
  @spec throughput(non_neg_integer(), number()) :: float()
  def throughput(_operations, duration_ms) when duration_ms <= 0, do: 0.0

  def throughput(operations, duration_ms),
    do: Float.round(operations / (duration_ms / 1_000), 2)

  @doc "Rounds a float to two places, passing `nil` through."
  @spec round2(number() | nil) :: float() | nil
  def round2(nil), do: nil
  def round2(value) when is_integer(value), do: value / 1
  def round2(value) when is_float(value), do: Float.round(value, 2)
end
