defmodule AuroraMeter.Bench.Modes.Flush do
  @moduledoc false

  # `flush_1k`, `flush_10k` and `flush_100k`: one `AuroraMeter.Flusher.flush/0`
  # with that many dirty keys, timed.
  #
  # Building the dirty set is **excluded** from the measurement: the runner sets
  # the flush interval high enough that the periodic timer cannot intervene, the
  # keys are made with `AuroraMeter.Counter.incr/4`, and only the synchronous
  # `flush/0` call is inside the clock. `--rounds` of them, so the percentiles
  # come from several samples rather than from one.
  #
  # History is off for these three and the record says so. A day bucket is a
  # second dirty key for the same increment, so with history on "1k dirty keys"
  # would be two thousand and the mode's own name would be wrong.
  #
  # A **failed** flush stops the mode rather than being carried into the next
  # round. `AuroraMeter.Flusher` retains a failed batch for an idempotent retry,
  # so a second round would build more dirty keys on top of a batch that already
  # could not be written, and every later figure would describe a system that is
  # permanently stuck. The run records the failure, `correct` is false, and the
  # task exits non-zero.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1, time: 1]

  alias AuroraMeter.Bench.Mode
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.Store

  @period ~U[2026-07-01 00:00:00Z]

  @doc "How many dirty keys the mode builds before each flush."
  @spec keys(atom()) :: pos_integer()
  def keys(:flush_1k), do: 1_000
  def keys(:flush_10k), do: 10_000
  def keys(:flush_100k), do: 100_000

  @impl AuroraMeter.Bench.Mode
  def prepare(ctx) do
    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{
      "dirty_keys" => keys(ctx.mode),
      "tenants" => keys(ctx.mode),
      "keys" => keys(ctx.mode),
      "rounds" => ctx.rounds
    })
    |> add_note(
      "each round makes #{keys(ctx.mode)} distinct dirty counter keys with Counter.incr/4 and " <>
        "then times one synchronous Flusher.flush/0. duration_ms is the sum of the flushes " <>
        "only; building the dirty set is outside the clock. History is off, because a day " <>
        "bucket would be a second dirty key per increment and the mode's name would be wrong."
    )
  end

  @impl AuroraMeter.Bench.Mode
  def custom(ctx) do
    count = keys(ctx.mode)
    samples = rounds(ctx, count, 1, [])
    durations = Enum.map(samples, & &1["duration_us"])
    failures = Enum.reject(samples, &(&1["result"] == "ok"))

    %{
      operations: Enum.sum(Enum.map(samples, & &1["persisted"])),
      duration_ms: Enum.sum(durations) / 1_000,
      samples: durations,
      sampled: false,
      sample_every: nil,
      errors: %{total: length(failures), by_tag: failure_tags(failures)},
      timeline: samples,
      notes: failure_notes(failures, count)
    }
  end

  @impl AuroraMeter.Bench.Mode
  def verify(ctx, tally) do
    merge([
      compare("persisted total", persisted_total(ctx), tally.operations),
      compare("dirty keys at the end", :ets.info(Store.dirty_table(), :size) || 0, 0),
      compare("pending batch items at the end", pending_items(), 0),
      receipts_check(ctx)
    ])
  end

  # -- rounds -----------------------------------------------------------------

  defp rounds(ctx, _count, round, acc) when round > ctx.rounds, do: Enum.reverse(acc)

  defp rounds(ctx, count, round, acc) do
    sample = round_of(ctx, count, round)

    if sample["result"] == "ok" do
      rounds(ctx, count, round + 1, [sample | acc])
    else
      Enum.reverse([sample | acc])
    end
  end

  defp round_of(ctx, count, round) do
    for n <- 1..count do
      Counter.incr("#{Modes.prefix(ctx)}k#{(round - 1) * count + n}", Modes.feature(), 1, @period)
    end

    {us, result} = time(fn -> Flusher.flush() end)
    sample(round, count, us, result)
  end

  defp sample(round, count, us, {:ok, persisted}) do
    %{
      "round" => round,
      "result" => "ok",
      "keys_built" => count,
      "persisted" => persisted,
      "duration_us" => Stats.round2(us),
      "rows_per_second" => Stats.throughput(persisted, us / 1_000)
    }
  end

  defp sample(round, count, us, {:error, reason}) do
    %{
      "round" => round,
      "result" => "error",
      "keys_built" => count,
      "persisted" => 0,
      "duration_us" => Stats.round2(us),
      "rows_per_second" => 0.0,
      "error" => inspect(reason)
    }
  end

  defp failure_tags([]), do: %{}

  # One bounded tag, with the message kept in the timeline rather than used as
  # the key: a tag built from a database error string would make
  # `errors.by_tag` an unbounded map, which is the cardinality mistake 08a
  # spent a unit removing from the metric labels.
  defp failure_tags(failures), do: %{"flush_failed" => length(failures)}

  defp failure_notes([], _count), do: []

  defp failure_notes(failures, count) do
    [
      "the flush of #{count} dirty keys FAILED, so this run measures nothing: " <>
        "#{inspect(Enum.map(failures, & &1["error"]))}. A failed flush retains its batch for " <>
        "an idempotent retry, so the remaining rounds were not run: they would have built more " <>
        "dirty keys on top of a batch that cannot be written."
    ]
  end

  # -- verification -----------------------------------------------------------

  # At most one receipt per round and at least one overall. Exactly one per
  # batch id is invariant I01; a round that failed wrote none, which is why this
  # is a range rather than an equality, and the failure itself is what makes the
  # run incorrect.
  defp receipts_check(ctx) do
    receipts = receipt_count(ctx)

    {receipts > 0 and receipts <= ctx.rounds,
     ["flush receipts: #{receipts} (one per successful round, #{ctx.rounds} rounds requested)"]}
  end

  defp pending_items do
    case :ets.lookup(Store.flush_batches_table(), :pending) do
      [{:pending, batch}] -> length(batch.taken)
      [] -> 0
    end
  end

  # One query rather than a read per key: at a hundred thousand keys the
  # verification would otherwise cost more than the thing it verifies.
  defp persisted_total(ctx) do
    %{rows: [[value]]} =
      ctx.repo.query!(
        "SELECT coalesce(sum(value), 0) FROM aurora_meter_counters WHERE tenant_key LIKE $1",
        [Modes.prefix(ctx) <> "%"]
      )

    Mode.to_integer(value)
  end

  defp receipt_count(ctx) do
    %{rows: [[value]]} = ctx.repo.query!("SELECT count(*) FROM aurora_meter_flush_receipts", [])
    Mode.to_integer(value)
  end

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
