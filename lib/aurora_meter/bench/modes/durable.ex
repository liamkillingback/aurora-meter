defmodule AuroraMeter.Bench.Modes.Durable do
  @moduledoc false

  # `record`, `record_batch`, `correct` and `replay`: the durable event path,
  # end to end through the real Ecto adapter into Postgres.
  #
  # These four run with `:ops` configured `feature_sources: %{ops: :events}`,
  # which is the deployment the durable API is for: the counter a dashboard
  # reads is maintained from committed events rather than from a buffered
  # increment. A record-mode figure measured against a buffered feature would be
  # measuring a different product.
  #
  # Every correctness check reads the fact twice, from two places that cannot
  # both be wrong in the same direction: the rows in `aurora_meter_events` and
  # the projected total `AuroraMeter.Events.total/3` serves. Comparing the
  # projection with itself would pass on a run that wrote nothing at all.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1, time: 1]

  alias AuroraMeter.Bench.Mode
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Events

  @batch_sizes [1, 10, 100, 500]

  @impl AuroraMeter.Bench.Mode
  def prepare(%{mode: :correct} = ctx) do
    ctx = base(ctx)
    originals = ctx.warmup + ctx.per
    seed(ctx, originals, &original_id/3, 2)

    ctx
    |> Map.put(:workload_extra, %{
      "tenants" => ctx.procs,
      "originals" => ctx.procs * originals,
      "original_quantity" => 2
    })
    |> add_note(
      "correct seeds procs x (warmup + per) originals of quantity 2 before the clock starts " <>
        "and reduces each by 1, so no correction can reach its original's cumulative bound " <>
        "and the measurement is the correction path rather than a refusal path."
    )
  end

  def prepare(%{mode: :replay} = ctx) do
    ctx = base(ctx)
    seed(ctx, ctx.per, &replay_id/3, 1)

    ctx
    |> Map.put(:workload_extra, %{"tenants" => ctx.procs, "events" => ctx.procs * ctx.per})
    |> add_note(
      "replay seeds procs x per events and then rebuilds the projection over them " <>
        "#{ctx.rounds} times with compare: :require_match, so a rebuilt generation that " <>
        "disagreed with the live one would refuse to activate and the run would be incorrect."
    )
  end

  def prepare(%{mode: :record_batch} = ctx) do
    ctx = base(ctx)

    ctx
    |> Map.put(:workload_extra, %{"tenants" => ctx.procs, "batch_sizes" => @batch_sizes})
    |> add_note(
      "record_batch cycles the batch sizes #{inspect(@batch_sizes)} across operation indices, " <>
        "500 being the documented maximum. One operation is one record_batch/2 call, so " <>
        "workload.operations counts calls and not events; workload.events counts events."
    )
  end

  def prepare(ctx) do
    ctx = base(ctx)
    Map.put(ctx, :workload_extra, %{"tenants" => ctx.procs, "batch_size" => 1})
  end

  @impl AuroraMeter.Bench.Mode
  def operation(%{mode: :correct} = ctx, worker, index) do
    tenant = Modes.tenant(ctx, worker)

    case AuroraMeter.correct(tenant, original_id(ctx, worker, index), 1,
           id: "#{ctx.short_id}-corr-#{worker}-#{index}"
         ) do
      {:ok, _event, :inserted} -> :ok
      {:ok, _event, :duplicate} -> {:error, :duplicate}
      {:error, reason} -> {:error, tag(reason)}
    end
  end

  def operation(%{mode: :record_batch} = ctx, worker, index) do
    size = Enum.at(@batch_sizes, rem(index, length(@batch_sizes)))

    events =
      for n <- 1..size do
        %{
          tenant: Modes.tenant(ctx, worker),
          feature: Modes.feature(),
          quantity: 2,
          id: "#{ctx.short_id}-#{worker}-#{index}-#{n}",
          occurred_at: ctx.occurred_at
        }
      end

    case AuroraMeter.record_batch(events) do
      {:ok, _results} -> :ok
      {:error, reason} -> {:error, tag(reason)}
    end
  end

  def operation(ctx, worker, index) do
    case AuroraMeter.record(Modes.tenant(ctx, worker), Modes.feature(), 2,
           id: "#{ctx.short_id}-#{worker}-#{index}",
           occurred_at: ctx.occurred_at
         ) do
      {:ok, _event, :inserted} -> :ok
      {:ok, _event, :duplicate} -> {:error, :duplicate}
      {:error, reason} -> {:error, tag(reason)}
    end
  end

  @impl AuroraMeter.Bench.Mode
  def custom(%{mode: :replay} = ctx) do
    samples =
      for _round <- 1..ctx.rounds do
        time(fn -> Events.Replay.run(compare: :require_match, batch_size: ctx.batch_size) end)
      end

    failures = Enum.reject(samples, fn {_us, result} -> match?({:ok, _report}, result) end)
    durations = Enum.map(samples, fn {us, _result} -> Stats.round2(us) end)

    %{
      operations: ctx.procs * ctx.per * ctx.rounds,
      duration_ms: Enum.sum(durations) / 1_000,
      samples: durations,
      sampled: false,
      sample_every: nil,
      errors: %{total: length(failures), by_tag: tags(failures)},
      timeline: [],
      notes: [
        "each sample is one AuroraMeter.Events.Replay.run/1 over the whole seeded population. " <>
          "operations counts events replayed across #{ctx.rounds} rounds, and the percentiles " <>
          "come from #{ctx.rounds} samples, which is stated here because #{ctx.rounds} is a " <>
          "small number to take a p99 from."
      ]
    }
  end

  @impl AuroraMeter.Bench.Mode
  def verify(%{mode: :correct} = ctx, tally) do
    originals = ctx.procs * (ctx.warmup + ctx.per)
    corrections = tally.operations + tally.warmup_operations
    compare("net quantity", projected(ctx), originals * 2 - corrections)
  end

  def verify(%{mode: :replay} = ctx, _tally) do
    merge([
      compare("projected total after replay", projected(ctx), ctx.procs * ctx.per),
      compare("rows in aurora_meter_events", rows(ctx), ctx.procs * ctx.per)
    ])
  end

  def verify(ctx, _tally) do
    quantity = scalar(ctx, "coalesce(sum(quantity), 0)")

    merge([
      compare("projected total", projected(ctx), quantity),
      {rows(ctx) > 0, ["rows in aurora_meter_events: #{rows(ctx)}"]}
    ])
  end

  # -- helpers ----------------------------------------------------------------

  defp base(ctx) do
    tenant = Modes.tenant(ctx, 1)
    occurred_at = DateTime.truncate(AuroraMeter.Clock.now(), :second)

    for worker <- 1..ctx.procs do
      {:ok, _subscription} = AuroraMeter.subscribe(Modes.tenant(ctx, worker), :bench_unlimited)
    end

    ctx
    |> Map.put(:period, AuroraMeter.period(tenant).start)
    |> Map.put(:occurred_at, occurred_at)
  end

  # Seeding is concurrent for the same reason the measured phase is: seeding
  # procs x per rows one at a time would take longer than the measurement.
  defp seed(ctx, count, id_fun, quantity) do
    1..ctx.procs
    |> Task.async_stream(
      fn worker ->
        for index <- 1..count do
          {:ok, _event, _outcome} =
            AuroraMeter.record(Modes.tenant(ctx, worker), Modes.feature(), quantity,
              id: id_fun.(ctx, worker, index),
              occurred_at: ctx.occurred_at
            )
        end
      end,
      max_concurrency: ctx.procs,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp original_id(ctx, worker, index), do: "#{ctx.short_id}-orig-#{worker}-#{index}"
  defp replay_id(ctx, worker, index), do: "#{ctx.short_id}-replay-#{worker}-#{index}"

  defp projected(ctx) do
    Enum.sum(
      for worker <- 1..ctx.procs,
          do: Events.total(Modes.tenant(ctx, worker), Modes.feature(), ctx.period)
    )
  end

  defp rows(ctx), do: scalar(ctx, "count(*)")

  defp scalar(ctx, expression) do
    %{rows: [[value]]} =
      ctx.repo.query!(
        "SELECT #{expression} FROM aurora_meter_events WHERE tenant_key LIKE $1",
        [Modes.prefix(ctx) <> "%"]
      )

    Mode.to_integer(value)
  end

  defp tags([]), do: %{}

  defp tags(failures) do
    Enum.frequencies_by(failures, fn {_us, result} -> to_string(tag(result)) end)
  end

  # `:unexpected` and not an atom built from the term. A tag is a bounded label
  # in the record's `errors.by_tag` map, and turning an arbitrary error term
  # into an atom would make the bench's own error accounting an unbounded atom
  # source, which is the cardinality mistake 08a spent a unit removing from the
  # metric labels.
  defp tag({:error, reason}), do: tag(reason)
  defp tag({name, _detail}) when is_atom(name), do: name
  defp tag({name, _index, _detail}) when is_atom(name), do: name
  defp tag(name) when is_atom(name), do: name
  defp tag(_other), do: :unexpected

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
