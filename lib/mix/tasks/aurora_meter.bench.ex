defmodule Mix.Tasks.AuroraMeter.Bench do
  @shortdoc "Benchmarks raw metering (ETS increment) throughput"

  @moduledoc """
  Measures Aurora Meter's hot-path throughput: concurrent `AuroraMeter.Counter`
  increments against warm ETS counters (no database on the hot path). This is the
  evidence behind the BEAM-metering moat claim.

  Each worker increments its own counter key, matching real usage where load is
  spread across many tenant/feature counters rather than one hot row.

      mix aurora_meter.bench            # defaults: 8 procs x 500_000 incrs
      mix aurora_meter.bench 16 500000
  """

  use Mix.Task

  alias AuroraMeter.Counter
  alias AuroraMeter.Store

  @period ~U[2026-07-01 00:00:00Z]
  @feature :ops

  @impl Mix.Task
  def run(args) do
    {procs, per} = parse(args)
    # The store subscribes to the invalidation topic at boot, so give it a
    # PubSub; nothing else about the runtime is started (no repo, no flusher).
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: AuroraMeter.BenchPubSub)
    Application.put_env(:aurora_meter, :pubsub, AuroraMeter.BenchPubSub)
    # Measure the period-counter path only: day buckets would seed from the
    # (absent) database on first touch.
    Application.put_env(:aurora_meter, :history, false)
    {:ok, _} = Store.start_link([])

    # Warm one distinct key per worker so the seeding path never touches the
    # (absent) database and workers do not contend on a single ETS row.
    for i <- 1..procs,
        do: :ets.insert(Store.counters_table(), {{tenant(i), @feature, @period}, 0, 0, 0})

    {micros, :ok} = :timer.tc(fn -> hammer(procs, per) end)

    total = procs * per
    final = Enum.sum(for i <- 1..procs, do: Counter.value(tenant(i), @feature, @period))
    rate = round(total / (micros / 1_000_000))

    Mix.shell().info("""
    Aurora Meter bench (distinct key per worker)
      procs:        #{procs}
      per proc:     #{per}
      total incrs:  #{total}
      sum of keys:  #{final}  (correct: #{final == total})
      elapsed:      #{Float.round(micros / 1000, 1)} ms
      throughput:   #{rate} incr/s
    """)
  end

  defp hammer(procs, per) do
    1..procs
    |> Enum.map(fn i -> Task.async(fn -> worker(i, per) end) end)
    |> Enum.each(&Task.await(&1, :infinity))

    :ok
  end

  defp worker(index, per) do
    tenant = tenant(index)
    Enum.each(1..per, fn _ -> Counter.incr(tenant, @feature, 1, @period) end)
  end

  defp tenant(index), do: "bench_#{index}"

  defp parse([procs, per | _]), do: {String.to_integer(procs), String.to_integer(per)}
  defp parse(_args), do: {8, 500_000}
end
