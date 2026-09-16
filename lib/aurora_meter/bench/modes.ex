defmodule AuroraMeter.Bench.Modes do
  @moduledoc false

  # The mode table: every mode `mix aurora_meter.bench` knows, its `kind`,
  # whether it reaches Postgres, and which module implements it.
  #
  # **`kind` is the load-bearing column.** `:micro` means the measurement
  # isolates an in-memory path with stubbed or absent persistence; `:end_to_end`
  # means every write reaches Postgres through the real adapter. The two differ
  # by three orders of magnitude on this hardware, and a throughput quoted
  # without its kind says almost nothing, which is how an ETS increment rate
  # ended up on a README beside a sentence about billing.
  #
  # `cluster_2_sim` exists so that a single-VM gossip number can be measured
  # without any possibility of its being quoted as a cluster result: it is
  # `:micro`, its name says `_sim`, and the real `cluster_2` and `cluster_4`
  # modes are the only source of a cluster claim. Where Erlang distribution
  # cannot start they exit non-zero with `distribution_unavailable` recorded.
  # They never fall back to the simulation.

  alias AuroraMeter.Bench.Modes.Cluster
  alias AuroraMeter.Bench.Modes.Counters
  alias AuroraMeter.Bench.Modes.Durable
  alias AuroraMeter.Bench.Modes.Faults
  alias AuroraMeter.Bench.Modes.Flush
  alias AuroraMeter.Bench.Modes.Quota
  alias AuroraMeter.Bench.Modes.Wallet

  # {name, kind, needs_repo?, implementation}
  @table [
    {:spread, :micro, false, Counters},
    {:hot, :micro, false, Counters},
    {:reserve, :micro, false, Quota},
    {:with_quota, :micro, false, Quota},
    {:cluster_2_sim, :micro, false, Counters},
    {:record, :end_to_end, true, Durable},
    {:record_batch, :end_to_end, true, Durable},
    {:correct, :end_to_end, true, Durable},
    {:replay, :end_to_end, true, Durable},
    {:credits_debit, :end_to_end, true, Wallet},
    {:credits_hot_wallet, :end_to_end, true, Wallet},
    {:flush_1k, :end_to_end, true, Flush},
    {:flush_10k, :end_to_end, true, Flush},
    {:flush_100k, :end_to_end, true, Flush},
    {:db_delay, :end_to_end, true, Faults},
    {:db_recovery, :end_to_end, true, Faults},
    {:cluster_2, :end_to_end, true, Cluster},
    {:cluster_4, :end_to_end, true, Cluster}
  ]

  @custom [:replay, :flush_1k, :flush_10k, :flush_100k, :db_delay, :db_recovery] ++
            [:cluster_2, :cluster_4]

  # The feature every mode meters. One name, so a record is comparable across
  # modes and a reader never has to ask whether two figures counted the same
  # thing.
  @feature :ops

  @doc "Every mode name, in the order the documentation lists them."
  @spec all() :: [atom()]
  def all, do: Enum.map(@table, &elem(&1, 0))

  @doc "Whether `name` is a mode."
  @spec mode?(atom()) :: boolean()
  def mode?(name), do: name in all()

  @doc "`:micro` or `:end_to_end`."
  @spec kind(atom()) :: :micro | :end_to_end
  def kind(name), do: elem(entry(name), 1)

  @doc "Whether the mode writes to Postgres through the real adapter."
  @spec needs_repo?(atom()) :: boolean()
  def needs_repo?(name), do: elem(entry(name), 2)

  @doc "The module implementing the mode."
  @spec implementation(atom()) :: module()
  def implementation(name), do: elem(entry(name), 3)

  @doc "Whether the mode drives its own measured phase rather than running `procs x per` operations."
  @spec custom?(atom()) :: boolean()
  def custom?(name), do: name in @custom

  @doc "The modes that need real peer nodes."
  @spec distributed() :: [atom()]
  def distributed, do: [:cluster_2, :cluster_4]

  @doc "The modes whose counter is maintained from durable events rather than buffered."
  @spec events_source() :: [atom()]
  def events_source, do: [:record, :record_batch, :correct, :replay]

  @doc "The feature every mode meters."
  @spec feature() :: atom()
  def feature, do: @feature

  @doc "How many nodes a cluster mode needs, this one included."
  @spec cluster_size(atom()) :: pos_integer()
  def cluster_size(:cluster_2), do: 2
  def cluster_size(:cluster_4), do: 4

  # -- tenants ----------------------------------------------------------------

  @doc "This worker's tenant key. Synthetic, always `bench_*`, never a real tenant."
  @spec tenant(map(), pos_integer()) :: String.t()
  def tenant(ctx, worker), do: "#{prefix(ctx)}#{worker}"

  @doc "The one shared tenant key the contention modes use."
  @spec shared_tenant(map()) :: String.t()
  def shared_tenant(ctx), do: "#{prefix(ctx)}shared"

  @doc "The `LIKE` prefix that names exactly this run's rows and nothing else."
  @spec prefix(map()) :: String.t()
  def prefix(ctx), do: "bench_#{ctx.mode}_#{ctx.short_id}_"

  # -- dispatch ---------------------------------------------------------------

  @doc "Prepares a mode: seeds whatever the measured phase assumes. Answers the context."
  @spec prepare(map()) :: map()
  def prepare(ctx), do: implementation(ctx.mode).prepare(ctx)

  @doc "One operation. Answers `:ok` or `{:error, tag}`; a raise fails the run."
  @spec operation(map(), pos_integer(), pos_integer()) :: :ok | {:error, atom()}
  def operation(ctx, worker, index),
    do: implementation(ctx.mode).operation(ctx, worker, index)

  @doc "A self-driving mode's whole measured phase."
  @spec custom(map()) :: map()
  def custom(ctx), do: implementation(ctx.mode).custom(ctx)

  @doc "The correctness assertion. Answers `{correct?, notes}`."
  @spec verify(map(), map()) :: {boolean(), [String.t()]}
  def verify(ctx, tally), do: implementation(ctx.mode).verify(ctx, tally)

  defp entry(name) do
    case Enum.find(@table, &(elem(&1, 0) == name)) do
      nil -> raise ArgumentError, "unknown bench mode #{inspect(name)}"
      found -> found
    end
  end
end
