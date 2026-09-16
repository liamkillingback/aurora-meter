defmodule AuroraMeter.Bench.Modes.Faults do
  @moduledoc false

  # `db_delay` and `db_recovery`: what buffered metering does when the database
  # is slow, and what it does when the database is gone.
  #
  # Both are duration driven. Every worker increments for `--duration`
  # milliseconds over a rotating set of keys, a sampler records the dirty set
  # and the pending batch once a second, and then the load stops and the **drain
  # is measured**: how long until the dirty set is empty and the persisted
  # totals equal the increments issued.
  #
  # The outage in `db_recovery` is a **real** one. `scripts/v1/bench.sh` stops
  # the Postgres container while this runs and starts it again; nothing in the
  # shipped task shells out to Docker, and nothing here simulates a refusal.
  # `AuroraMeter.Bench.DelayStorage`'s outage switch exists for the negative
  # control of this measurement, not for the measurement: a storage adapter
  # that returns `{:error, _}` proves the flusher retries and proves nothing at
  # all about what Postgres does when it comes back.
  #
  # G08 bullet 3 is the pair this mode exists for: **the persisted totals equal
  # exactly the increments issued, and the drain rate exceeds the arrival
  # rate.** Both are computed here and both are in the JSON.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1, time: 1]

  alias AuroraMeter.Bench.Mode
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Clock
  alias AuroraMeter.Counter
  alias AuroraMeter.Store

  @period ~U[2026-07-01 00:00:00Z]

  @impl AuroraMeter.Bench.Mode
  def prepare(ctx) do
    # BOTH keys per tenant, and the day bucket is the one that matters. The
    # first version warmed only the period counter, and with `:history` on (the
    # end-to-end default) every increment's day bucket was still cold, so the
    # first touch of each went through `Storage.load_history/3` and paid the
    # configured delay. `db_delay` then measured a cold-seed storm against a
    # slow database, 3,364 increments in twenty seconds, rather than backlog
    # growth under one. A warm-up exists to put exactly that outside the clock.
    for n <- 1..ctx.backlog_keys do
      Counter.warm({key_name(ctx, n), Modes.feature(), @period})
      Counter.warm({key_name(ctx, n), Modes.feature(), {:day, Clock.today()}})
    end

    ctx
    |> Map.put(:period, @period)
    |> Map.put(:workload_extra, %{
      "tenants" => ctx.backlog_keys,
      "keys" => ctx.backlog_keys,
      "duration_ms" => ctx.duration_ms,
      # Zero for `db_recovery`, and not `--delay-us`: the switch has a default
      # and only `db_delay` installs the delaying storage, so recording the
      # default here said 50,000 us on a run that had none.
      "storage_delay_us" => if(ctx.mode == :db_delay, do: ctx.delay_us, else: 0),
      "history" => ctx.history,
      "warmed_keys" => ctx.backlog_keys * 2
    })
    |> add_note(note(ctx))
  end

  @impl AuroraMeter.Bench.Mode
  def custom(ctx) do
    parent = self()
    ctx = Map.put(ctx, :started_ms, Clock.monotonic_ms())
    deadline = ctx.started_ms + ctx.duration_ms
    sampler = spawn_link(fn -> sample_loop(parent, ctx, []) end)

    {load_us, counts} = time(fn -> load(ctx, deadline) end)
    issued = Enum.sum(counts)
    stopped_at = Clock.monotonic_ms()
    persisted_at_stop = safe_persisted(ctx)

    {drain_us, _drained} = time(fn -> drain(ctx) end)
    send(sampler, {:stop, self()})
    timeline = collect(sampler)

    measurement(ctx, issued, load_us, drain_us, persisted_at_stop, stopped_at, timeline)
  end

  @impl AuroraMeter.Bench.Mode
  def verify(ctx, tally) do
    merge([
      compare("persisted total after the drain", persisted(ctx), tally.operations),
      compare("dirty keys after the drain", :ets.info(Store.dirty_table(), :size) || 0, 0),
      compare("pending batch items after the drain", pending_items(), 0)
    ])
  end

  # -- the measured phase -----------------------------------------------------

  defp load(ctx, deadline) do
    1..ctx.procs
    |> Task.async_stream(fn worker -> worker_loop(ctx, worker, deadline, 0) end,
      max_concurrency: ctx.procs,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, count} -> count end)
  end

  defp worker_loop(ctx, worker, deadline, count) do
    if Clock.monotonic_ms() >= deadline do
      count
    else
      name = key_name(ctx, rem(worker * 7 + count, ctx.backlog_keys) + 1)
      Counter.incr(name, Modes.feature(), 1, @period)
      worker_loop(ctx, worker, deadline, count + 1)
    end
  end

  # The flusher's own timer is running throughout: what is being measured is its
  # retry of a retained batch, so driving it by hand would measure something
  # else. This only waits, and fails the run if the wait exceeds its bound.
  defp drain(ctx), do: drain_until(ctx, Clock.monotonic_ms() + ctx.drain_timeout_ms, 0)

  defp drain_until(ctx, deadline, polls) do
    cond do
      drained?() ->
        polls

      Clock.monotonic_ms() >= deadline ->
        raise "the bench waited #{ctx.drain_timeout_ms} ms and the dirty set never emptied: " <>
                "#{:ets.info(Store.dirty_table(), :size)} dirty keys, #{pending_items()} " <>
                "items in the pending batch. Either the database did not come back, or the " <>
                "retained batch cannot be sent at all: one flush uses seven bind parameters " <>
                "per counter row and Postgres takes 65,535, so a batch of more than 9,362 " <>
                "counter keys is retried for ever (open-findings.md X338). The flusher's log " <>
                "lines above say which."

      true ->
        Process.sleep(100)
        drain_until(ctx, deadline, polls + 1)
    end
  end

  defp drained?, do: (:ets.info(Store.dirty_table(), :size) || 0) == 0 and pending_items() == 0

  defp measurement(ctx, issued, load_us, drain_us, persisted_at_stop, stopped_at, timeline) do
    arrival = Stats.throughput(issued, load_us / 1_000)
    buffered = issued - (persisted_at_stop || 0)
    drain_ms = drain_us / 1_000
    drain_rate = if persisted_at_stop, do: Stats.throughput(buffered, drain_ms)
    recovery = recovery_rate(timeline)

    %{
      operations: issued,
      duration_ms: load_us / 1_000,
      samples: [],
      sampled: false,
      sample_every: nil,
      errors: %{total: 0, by_tag: %{}},
      timeline: timeline,
      backlog_extra: %{
        "arrival_rate_per_sec" => arrival,
        "increments_issued" => issued,
        "persisted_when_load_stopped" => persisted_at_stop,
        "buffered_when_load_stopped" => if(persisted_at_stop, do: buffered),
        "drain_ms" => Stats.round2(drain_ms),
        "drain_rate_per_sec" => drain_rate,
        "drain_faster_than_arrival" => drain_rate && drain_rate > arrival,
        "recovery_rate_per_sec" => recovery,
        "recovery_faster_than_arrival" => recovery && recovery > arrival,
        "load_stopped_monotonic_ms" => stopped_at
      },
      notes: drain_notes(persisted_at_stop) ++ [duration_note(ctx, load_us, drain_ms)]
    }
  end

  # The rate the backlog ACTUALLY cleared at, taken from the timeline rather
  # than from the drain window.
  #
  # `drain_rate_per_sec` measures only what was left when the load stopped, and
  # that is whatever the flush cycle happened to be holding at that instant: a
  # small remainder divided by the fixed cost of one flush reads as a slow
  # drain on a system that is not slow. What the guarantee is about is the
  # catch-up after the database returns, and that is the largest one-second
  # increase in the persisted total anywhere in the run. Both are recorded,
  # because they answer different questions and only one of them is G08's.
  defp recovery_rate(timeline) do
    timeline
    |> Enum.filter(&is_integer(&1["persisted"]))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] ->
      seconds = (b["monotonic_ms"] - a["monotonic_ms"]) / 1_000
      if seconds > 0, do: (b["persisted"] - a["persisted"]) / seconds, else: 0
    end)
    |> case do
      [] -> nil
      rates -> Stats.round2(Enum.max(rates))
    end
  end

  defp drain_notes(nil) do
    [
      "backlog.drain.persisted_when_load_stopped is null: the sum query could not run at the " <>
        "moment the load stopped, so the drain rate is null rather than guessed."
    ]
  end

  defp drain_notes(_persisted), do: []

  defp duration_note(ctx, load_us, drain_ms) do
    "duration driven: #{ctx.procs} workers incremented #{ctx.backlog_keys} rotating keys for " <>
      "#{Stats.round2(load_us / 1_000)} ms, then the load stopped and the drain took " <>
      "#{Stats.round2(drain_ms)} ms. latency_us is null throughout, because this mode " <>
      "measures backlog and drain and not per-operation latency."
  end

  defp note(%{mode: :db_recovery} = ctx) do
    "db_recovery expects a REAL outage, orchestrated by scripts/v1/bench.sh, inside its " <>
      "#{ctx.duration_ms} ms load window. Run without one it is a plain sustained-load " <>
      "measurement, which is what its smoke run is, and the evidence says which it was."
  end

  defp note(ctx) do
    "db_delay puts #{ctx.delay_us} us in front of every storage callback through " <>
      "AuroraMeter.Bench.DelayStorage. A slow database is not an absent one: the flusher " <>
      "keeps succeeding and the dirty set grows because it cannot keep up."
  end

  # -- the sampler ------------------------------------------------------------

  defp sample_loop(parent, ctx, points) do
    receive do
      {:stop, from} -> send(from, {:timeline, Enum.reverse([point(ctx) | points])})
    after
      1_000 -> sample_loop(parent, ctx, [point(ctx) | points])
    end
  end

  defp collect(sampler) do
    receive do
      {:timeline, points} -> points
    after
      5_000 ->
        Process.unlink(sampler)
        []
    end
  end

  # `persisted` is the curve an outage actually draws: the dirty-key count is
  # bounded by `--backlog-keys` and flattens as soon as every key is dirty,
  # while the persisted total stops moving the instant the database goes and
  # climbs again when it comes back. It is `null` while the query cannot run,
  # which is itself the outage window, and never a zero.
  defp point(ctx) do
    %{
      # Through the seam (P07). The wall reading is a label; the elapsed_ms
      # beside it is the monotonic one and is what any arithmetic uses.
      "at" => Clock.now() |> DateTime.to_iso8601(),
      "monotonic_ms" => Clock.monotonic_ms(),
      "elapsed_ms" => Clock.monotonic_ms() - ctx.started_ms,
      "dirty_keys" => :ets.info(Store.dirty_table(), :size) || 0,
      "pending_batch_items" => pending_items(),
      "persisted" => safe_persisted(ctx)
    }
  end

  # -- reading the database ---------------------------------------------------

  defp pending_items do
    case :ets.lookup(Store.flush_batches_table(), :pending) do
      [{:pending, batch}] -> length(batch.taken)
      [] -> 0
    end
  end

  defp persisted(ctx) do
    %{rows: [[value]]} =
      ctx.repo.query!(
        "SELECT coalesce(sum(value), 0) FROM aurora_meter_counters WHERE tenant_key LIKE $1",
        [Modes.prefix(ctx) <> "%"]
      )

    Mode.to_integer(value)
  end

  # `nil` and a note, never a zero: this read happens the instant the load
  # stops, which in `db_recovery` may be seconds after the database came back
  # or, if the outage ran long, while it is still gone. A zero would read as
  # "nothing had been persisted", which is a measurement, and this is its
  # absence.
  defp safe_persisted(ctx) do
    persisted(ctx)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp key_name(ctx, n), do: "#{Modes.prefix(ctx)}k#{n}"

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
