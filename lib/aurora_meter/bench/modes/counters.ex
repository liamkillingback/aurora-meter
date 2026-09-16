defmodule AuroraMeter.Bench.Modes.Counters do
  @moduledoc false

  # `spread`, `hot` and `cluster_2_sim`: the pure ETS modes.
  #
  # No repo, no flusher, no broadcaster, no period resolution. The period is a
  # fixed instant rather than `AuroraMeter.period/1`, because resolving a period
  # consults the configured source and, for some sources, storage, and a mode
  # labelled `micro` must not have a database anywhere in its path.
  #
  # Rows are warmed through `AuroraMeter.Counter.warm/2`. Nothing here builds a
  # counter tuple: that duplication is what made the old task seed a four
  # element row against a six element read and crash at its own summary
  # (`open-findings.md` C7).

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3]

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Counter

  @period ~U[2026-07-01 00:00:00Z]

  @doc "The fixed period the pure ETS modes count into."
  @spec period() :: DateTime.t()
  def period, do: @period

  @impl AuroraMeter.Bench.Mode
  def prepare(%{mode: :hot} = ctx) do
    Counter.warm({Modes.shared_tenant(ctx), Modes.feature(), @period})

    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{"keys" => 1, "tenants" => 1, "contended" => true})
    |> add_note(
      "every worker increments one shared ETS row, which :ets.update_counter/3 serialises. " <>
        "The figure is contention, not aggregate throughput."
    )
  end

  def prepare(%{mode: :cluster_2_sim} = ctx) do
    warm_one_key_per_worker(ctx)

    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{"keys" => ctx.procs, "tenants" => ctx.procs, "peers" => 1})
    |> add_note(
      "cluster_2_sim is a single VM simulation of gossip apply cost through " <>
        "AuroraMeter.Test.simulate_node/3. It is kind: micro and it is NOT a cluster " <>
        "measurement; cluster_2 and cluster_4 are the only source of a cluster claim."
    )
  end

  def prepare(ctx) do
    warm_one_key_per_worker(ctx)

    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{"keys" => ctx.procs, "tenants" => ctx.procs})
  end

  @impl AuroraMeter.Bench.Mode
  def operation(%{mode: :hot} = ctx, _worker, _index) do
    Counter.incr(Modes.shared_tenant(ctx), Modes.feature(), 1, @period)
    :ok
  end

  def operation(%{mode: :cluster_2_sim} = ctx, worker, _index) do
    AuroraMeter.Test.simulate_node(
      :bench_peer@nowhere,
      [{Modes.tenant(ctx, worker), Modes.feature(), 1}],
      @period
    )
  end

  def operation(ctx, worker, _index) do
    Counter.incr(Modes.tenant(ctx, worker), Modes.feature(), 1, @period)
    :ok
  end

  @impl AuroraMeter.Bench.Mode
  def verify(%{mode: :hot} = ctx, tally) do
    value = Counter.value(Modes.shared_tenant(ctx), Modes.feature(), @period)
    compare("hot key value", value, issued(tally))
  end

  def verify(ctx, tally), do: compare("sum of keys", spread_total(ctx), issued(tally))

  defp spread_total(ctx) do
    Enum.sum(
      for worker <- 1..ctx.procs,
          do: Counter.value(Modes.tenant(ctx, worker), Modes.feature(), @period)
    )
  end

  defp warm_one_key_per_worker(ctx) do
    for worker <- 1..ctx.procs,
        do: Counter.warm({Modes.tenant(ctx, worker), Modes.feature(), @period})

    :ok
  end

  # Warm-up increments are discarded from the timing and are NOT discarded from
  # the counter: they really happened. A correctness check that compared only
  # the measured phase would fail on every run with a warm-up, which is every
  # run.
  defp issued(tally), do: tally.operations + tally.warmup_operations

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
