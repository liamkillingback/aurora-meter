defmodule AuroraMeter.Bench.Runner do
  @moduledoc false

  # Sets a mode up, warms it, measures it, checks it and assembles its record.
  #
  # The split from `Mix.Tasks.AuroraMeter.Bench` is deliberate: the task parses
  # arguments, applies the environment guards and prints, and everything that
  # decides a number lives here, where a test can call it without a Mix
  # invocation.
  #
  # **Warm-up is excluded from the clock and not from the state.** Its
  # operations really happened, so every correctness check compares against
  # `warmup + measured`, and its own duration is recorded separately so a
  # reviewer can see whether the system was still warming when the measurement
  # began.

  alias AuroraMeter.Bench.DelayStorage
  alias AuroraMeter.Bench.MemoryStorage
  alias AuroraMeter.Bench.Mode
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Modes.Cluster
  alias AuroraMeter.Bench.Plans
  alias AuroraMeter.Bench.Report
  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Store

  @pubsub AuroraMeter.BenchPubSub

  @doc """
  Runs one mode. Answers `{:ok, report}` or `{:error, reason}`.

  `{:ok, report}` does not mean the run passed: `report["correct"]` is the
  verdict and the caller exits non-zero when it is false.
  """
  @spec run(atom(), map()) :: {:ok, map()} | {:error, String.t()}
  def run(mode, opts) do
    case distribution_guard(mode) do
      :ok -> run_guarded(mode, opts)
      {:unavailable, reason} -> {:ok, unavailable_record(mode, opts, reason)}
    end
  end

  defp run_guarded(mode, opts) do
    with :ok <- guard(mode, opts) do
      ctx = context(mode, opts)
      setup(ctx)
      measure(Modes.prepare(ctx))
    end
  end

  # Distribution is checked BEFORE the database, and the order is the claim: a
  # cluster mode that cannot start peer nodes cannot be a cluster measurement
  # whatever the database is doing, so it refuses first and records why. Asking
  # about the database first meant the refusal a host without distribution would
  # actually meet was the database guard's message, which says nothing about
  # distribution and leaves no record at all.
  defp distribution_guard(mode) do
    if mode in Modes.distributed() do
      case Cluster.ensure_distribution() do
        :ok -> :ok
        {:error, reason} -> {:unavailable, reason}
      end
    else
      :ok
    end
  end

  # A complete record, with `correct: false` and the reason named. The caller
  # exits non-zero on it. It never substitutes `cluster_2_sim`, which is a
  # single-VM simulation and is not a cluster result.
  defp unavailable_record(mode, opts, reason) do
    ctx =
      mode
      |> context(%{opts | repo: nil})
      |> Map.put(:period, nil)
      |> Map.put(:workload_extra, %{"nodes" => Modes.cluster_size(mode)})

    measurement = Cluster.unavailable(reason)
    tally = %{operations: 0, warmup_operations: 0, errors: measurement.errors}

    fields =
      ctx
      |> assemble(measurement, tally, measurement.cluster_verdict, Report.stamp(), 0.0)
      |> Keyword.put(:memory, memory(Report.memory_sample(), Report.memory_sample()))
      |> Map.new()

    Report.build(fields)
  end

  # -- guards -----------------------------------------------------------------

  # Every one of these refuses before anything is written, and each exists
  # because the alternative is a number that looks fine and measures something
  # else.
  defp guard(mode, opts) do
    cond do
      Mix.env() == :prod ->
        {:error, "aurora_meter.bench never runs in MIX_ENV=prod"}

      not Modes.needs_repo?(mode) ->
        :ok

      is_nil(opts.repo) ->
        {:error, "#{mode} is an end-to-end mode and needs --repo MODULE (or a configured repo)"}

      not Code.ensure_loaded?(opts.repo) ->
        {:error, "--repo #{inspect(opts.repo)} is not a loaded module"}

      true ->
        repo_guard(opts)
    end
  end

  defp repo_guard(opts) do
    config = opts.repo.config()

    cond do
      config[:pool] == Ecto.Adapters.SQL.Sandbox ->
        {:error, sandbox_message(opts.repo)}

      not opts.allow_any_database and not String.ends_with?("#{config[:database]}", "_bench") ->
        {:error, database_message(config[:database])}

      true ->
        :ok
    end
  end

  defp sandbox_message(repo) do
    "#{inspect(repo)} is configured with Ecto.Adapters.SQL.Sandbox. The sandbox serialises " <>
      "every worker onto one owned connection, so the run would measure the sandbox rather " <>
      "than the database. Set AURORA_BENCH=1 so the repo resolves to the pooled bench " <>
      "configuration, or point --repo at a pooled repo."
  end

  defp database_message(database) do
    "the configured database is #{inspect(database)} and a bench run writes millions of rows. " <>
      "It runs against its own database, whose name must end in _bench: set AURORA_BENCH=1 " <>
      "and run mix bench.setup, or pass --allow-any-database if you really mean this one."
  end

  # -- context ----------------------------------------------------------------

  defp context(mode, opts) do
    run_id = Ecto.UUID.generate()

    %{
      mode: mode,
      kind: Modes.kind(mode),
      run_id: run_id,
      short_id: String.slice(run_id, 0, 8),
      label: opts.label || to_string(mode),
      procs: opts.procs,
      per: opts.per,
      warmup: opts.warmup,
      rounds: opts.rounds,
      seed: opts.seed,
      sample_every: sample_every(mode, opts),
      repo: if(Modes.needs_repo?(mode), do: opts.repo),
      history: opts.history,
      command: opts.command,
      batch_size: opts.batch_size,
      delay_us: opts.delay_us,
      duration_ms: opts.duration_ms,
      drain_timeout_ms: opts.drain_timeout_ms,
      backlog_keys: opts.backlog_keys,
      converge_ms: opts.converge_ms,
      broadcast_interval: opts.broadcast_interval,
      flush_interval: opts.flush_interval,
      cluster_limit: Plans.cluster_limit(),
      json: opts.json,
      notes: [],
      workload_extra: %{},
      period: nil,
      occurred_at: nil
    }
  end

  # Timing a sub-microsecond ETS write individually costs more than the write,
  # so micro modes time one operation in `sample_every`. The rate is recorded
  # and `latency_us.sampled` is true, so nobody can read those percentiles as
  # if every operation had been timed.
  defp sample_every(mode, opts) do
    if Modes.kind(mode) == :micro, do: opts.sample_every
  end

  # -- environment ------------------------------------------------------------

  defp setup(ctx) do
    # The library's own log level, not the caller's. A bench run that printed a
    # line per query would be timing its logger.
    Logger.configure(level: :warning)
    :rand.seed(:exsss, {ctx.seed, ctx.seed, ctx.seed})
    {:ok, _started} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _started} = Application.ensure_all_started(:telemetry)
    put_common_env(ctx)
    if Modes.needs_repo?(ctx.mode), do: setup_end_to_end(ctx), else: setup_micro(ctx)
  end

  defp put_common_env(ctx) do
    Application.put_env(:aurora_meter, :pubsub, @pubsub)
    Application.put_env(:aurora_meter, :plans, AuroraMeter.Bench.Plans)
    Application.put_env(:aurora_meter, :default_plan, :bench_unlimited)
    Application.put_env(:aurora_meter, :history, ctx.history)
    Application.put_env(:aurora_meter, :flush_interval, flush_interval(ctx))
    Application.put_env(:aurora_meter, :broadcast_interval, broadcast_interval(ctx))
    Application.put_env(:aurora_meter, :metrics_interval, 0)
    Application.put_env(:aurora_meter, :feature_sources, feature_sources(ctx))
  end

  defp setup_micro(ctx) do
    # Storage is the memory double for every micro mode, not only the two that
    # read a subscription. It is a guarantee rather than a convenience: if a
    # mode labelled `micro` ever reaches a durable callback, the double raises
    # and the run fails, instead of quietly measuring a database.
    Application.put_env(:aurora_meter, :storage, MemoryStorage)
    Application.delete_env(:aurora_meter, :repo)
    {:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: @pubsub)
    {:ok, _pid} = Store.start_link([])

    # `cluster_2_sim` measures `AuroraMeter.Cluster.apply/3`, so the Cluster
    # process has to be there. Nothing else in a micro mode needs it, and
    # starting it everywhere would put a second subscriber on the gossip topic
    # in modes whose whole point is that nothing else is running.
    if ctx.mode == :cluster_2_sim, do: {:ok, _pid} = AuroraMeter.Cluster.start_link([])

    if ctx.mode in [:reserve, :with_quota], do: :ok, else: MemoryStorage.clear()
    :ok
  end

  defp setup_end_to_end(ctx) do
    for app <- [:ecto_sql, :postgrex], do: {:ok, _started} = Application.ensure_all_started(app)
    Application.put_env(:aurora_meter, :repo, ctx.repo)
    Application.put_env(:aurora_meter, :storage, storage(ctx))
    if ctx.mode == :db_delay, do: DelayStorage.delay(ctx.delay_us)
    DelayStorage.resume()

    # `log: false`, and it is not tidiness. Finding X248's allocator figures were
    # taken with Ecto's debug logging on and only their SHAPE was usable,
    # because formatting and writing a query line per statement is a
    # measurable cost inside the span being measured. A bench that logs its own
    # queries is measuring its logger.
    {:ok, _pid} = ctx.repo.start_link(repo_config(ctx))
    {:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: @pubsub)
    clean!(ctx)
    {:ok, _pid} = AuroraMeter.start_link([])
    :ok
  end

  # The bench database is the bench's, so it starts empty: a run whose totals
  # had to be read as a delta against whatever a previous run left behind would
  # be one subtraction away from an unexplainable number. The name guard is
  # repeated here rather than trusted from the caller, because this statement
  # is destructive and a guard that runs once is a guard somebody can route
  # around.
  # Every tenant-keyed table and the flush receipts, so a run starts from
  # nothing: a total that had to be read as a delta against whatever a previous
  # run left behind is one subtraction away from an unexplainable number.
  #
  # `aurora_meter_checkpoints` and `aurora_meter_plan_versions` are deliberately
  # NOT in the list. The checkpoints table carries the events projection's
  # generation cursor, which the migration seeds and `Storage.Ecto` locks on
  # every durable write; truncating it made `record/4` raise a `MatchError` on a
  # missing row. Plan versions are installation-wide facts that
  # `AuroraMeter.Plans.register!/0` rewrites idempotently on the next boot.
  @tenant_tables ~w(
    aurora_meter_credit_allocations aurora_meter_credit_lots
    aurora_meter_credit_recurrences aurora_meter_credit_transactions
    aurora_meter_credit_balances aurora_meter_counters aurora_meter_history
    aurora_meter_events aurora_meter_event_totals aurora_meter_subscriptions
    aurora_meter_plan_transitions aurora_meter_flush_receipts
  )

  # The name guard is repeated here rather than trusted from the caller, because
  # this statement is destructive and a guard that runs once is a guard somebody
  # can route around.
  defp clean!(ctx) do
    database = "#{ctx.repo.config()[:database]}"

    if String.ends_with?(database, "_bench") do
      ctx.repo.query!("TRUNCATE #{Enum.join(@tenant_tables, ", ")} RESTART IDENTITY CASCADE")
    end

    :ok
  end

  # Four nodes at the configured pool size opened 120 connections against a
  # server whose `max_connections` is 100, and the peers reported
  # `too_many_connections` while the run carried on measuring whatever got
  # through. The cluster modes take a small pool each; every other mode keeps
  # the configured one, because pool size is part of what an end-to-end figure
  # means and the record carries it.
  @cluster_pool_size 8

  @doc "The pool size a cluster peer opens. Small, because four of them share one server."
  @spec cluster_pool_size() :: pos_integer()
  def cluster_pool_size, do: @cluster_pool_size

  defp repo_config(ctx) do
    config = Keyword.put(ctx.repo.config(), :log, false)

    if ctx.mode in Modes.distributed() do
      Keyword.put(config, :pool_size, @cluster_pool_size)
    else
      config
    end
  end

  defp storage(%{mode: :db_delay}), do: DelayStorage
  defp storage(_ctx), do: AuroraMeter.Storage.Ecto

  # `:ops` is maintained from committed events for the four durable modes,
  # which is the deployment the durable API is for. Everywhere else it is
  # buffered, which is what `track/4` and `reserve/3` are for. Measuring one
  # under the other's configuration would be measuring a different product.
  defp feature_sources(ctx) do
    if ctx.mode in Modes.events_source(), do: %{Modes.feature() => :events}, else: %{}
  end

  # The flusher's timer is a measurement hazard everywhere except the two modes
  # whose subject is the flusher's own behaviour under load.
  defp flush_interval(%{flush_interval: ms}) when is_integer(ms), do: ms
  defp flush_interval(%{mode: mode}) when mode in [:db_delay, :db_recovery], do: 1_000
  defp flush_interval(_ctx), do: 3_600_000

  defp broadcast_interval(%{broadcast_interval: ms}) when is_integer(ms), do: ms
  defp broadcast_interval(%{mode: mode}) when mode in [:cluster_2, :cluster_4], do: 1_000
  defp broadcast_interval(_ctx), do: 3_600_000

  # -- measurement ------------------------------------------------------------

  defp measure(ctx) do
    before = Report.memory_sample()
    started_at = Report.stamp()
    {warmup_us, _discarded} = Mode.time(fn -> warm_up(ctx) end)
    after_warmup = Report.memory_sample()

    measurement = run_measured(ctx)
    tally = tally(ctx, measurement)
    verdict = Modes.verify(ctx, tally)

    fields =
      ctx
      |> assemble(measurement, tally, verdict, started_at, warmup_us)
      |> Keyword.put(:memory, memory(before, after_warmup))
      |> Map.new()

    {:ok, Report.build(fields)}
  end

  defp warm_up(%{warmup: 0}), do: :ok

  defp warm_up(ctx) do
    if Modes.custom?(ctx.mode) do
      :ok
    else
      drive(ctx, 1, ctx.warmup)
      :ok
    end
  end

  defp run_measured(ctx) do
    if Modes.custom?(ctx.mode) do
      Modes.custom(ctx)
    else
      count_driven(ctx)
    end
  end

  defp count_driven(ctx) do
    {us, results} = Mode.time(fn -> drive(ctx, ctx.warmup + 1, ctx.warmup + ctx.per) end)
    samples = Enum.flat_map(results, &elem(&1, 0))

    errors =
      Enum.reduce(results, %{}, fn {_s, e}, acc -> Map.merge(acc, e, fn _k, a, b -> a + b end) end)

    %{
      operations: ctx.procs * ctx.per,
      duration_ms: us / 1_000,
      samples: samples,
      sampled: not is_nil(ctx.sample_every),
      sample_every: ctx.sample_every,
      errors: %{total: Enum.sum(Map.values(errors)), by_tag: errors},
      timeline: [],
      notes: []
    }
  end

  defp drive(ctx, from, to) do
    1..ctx.procs
    |> Task.async_stream(fn worker -> worker(ctx, worker, from, to) end,
      max_concurrency: ctx.procs,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp worker(ctx, worker, from, to) do
    Enum.reduce(from..to, {[], %{}}, &step(ctx, worker, &1, &2))
  end

  defp step(ctx, worker, index, {samples, errors}) do
    if sample?(ctx, index) do
      {us, result} = Mode.time(fn -> Modes.operation(ctx, worker, index) end)
      {[Stats.round2(us) | samples], tally_error(errors, result)}
    else
      {samples, tally_error(errors, Modes.operation(ctx, worker, index))}
    end
  end

  defp sample?(%{sample_every: nil}, _index), do: true
  defp sample?(%{sample_every: every}, index), do: rem(index, every) == 0

  defp tally_error(errors, :ok), do: errors
  defp tally_error(errors, {:error, tag}), do: Map.update(errors, to_string(tag), 1, &(&1 + 1))

  defp tally(ctx, measurement) do
    %{
      operations: measurement.operations,
      warmup_operations: warmup_operations(ctx),
      errors: measurement.errors,
      cluster_verdict: Map.get(measurement, :cluster_verdict)
    }
  end

  defp warmup_operations(ctx) do
    if Modes.custom?(ctx.mode), do: 0, else: ctx.procs * ctx.warmup
  end

  # -- assembling the record --------------------------------------------------

  defp assemble(ctx, measurement, tally, {correct, check_notes}, started_at, warmup_us) do
    [
      run_id: ctx.run_id,
      label: ctx.label,
      mode: ctx.mode,
      kind: ctx.kind,
      started_at: started_at,
      finished_at: Report.stamp(),
      repo: ctx.repo,
      command: ctx.command,
      config: config_block(ctx),
      workload: workload_block(ctx, measurement),
      warmup: %{
        "operations" => tally.warmup_operations,
        "duration_ms" => Stats.round2(warmup_us / 1_000)
      },
      samples: measurement.samples,
      sampled: measurement.sampled,
      sample_every: measurement.sample_every,
      throughput_ops_per_sec: Stats.throughput(measurement.operations, measurement.duration_ms),
      duration_ms: Stats.round2(measurement.duration_ms),
      backlog: backlog_block(measurement),
      errors: errors_block(measurement),
      correct: correct,
      notes: ctx.notes ++ measurement.notes ++ check_notes ++ latency_note(measurement)
    ]
  end

  # Criterion 6 in one function: a percentile that is `null` says so and says
  # why, rather than being an empty field a reader has to guess at.
  defp latency_note(%{samples: []}) do
    [
      "latency_us.p50, p95, p99 and max are null: this mode took no per-operation timing " <>
        "sample. Its unit of work is not an operation in a loop, so a percentile over " <>
        "operations would be a number with no referent."
    ]
  end

  defp latency_note(_measurement), do: []

  defp config_block(ctx) do
    %{
      "history" => ctx.history,
      "flush_interval" => flush_interval(ctx),
      "broadcast_interval" => broadcast_interval(ctx),
      "storage" => inspect(storage_for(ctx)),
      "feature_sources" => inspect(feature_sources(ctx)),
      "seed" => ctx.seed
    }
  end

  defp storage_for(ctx) do
    if Modes.needs_repo?(ctx.mode), do: storage(ctx), else: MemoryStorage
  end

  defp workload_block(ctx, measurement) do
    base = %{
      "procs" => ctx.procs,
      "per_proc" => ctx.per,
      "operations" => measurement.operations,
      "rounds" => ctx.rounds,
      "seed" => ctx.seed,
      "batch_size" => ctx.batch_size,
      "keys" => nil,
      "tenants" => nil
    }

    Map.merge(base, ctx.workload_extra)
  end

  defp backlog_block(measurement) do
    %{
      "dirty_keys_at_end" => table_size(Store.dirty_table()),
      "pending_batch_items_at_end" => pending_items(),
      "timeline" => measurement.timeline,
      "drain" => Map.get(measurement, :backlog_extra),
      "cluster" => Map.get(measurement, :cluster)
    }
  end

  defp errors_block(measurement) do
    %{
      "rate" => rate(measurement.errors.total, measurement.operations),
      "total" => measurement.errors.total,
      # A tag with a count of zero is dropped: `%{"limit_exceeded" => 0}` reads
      # as a category that was measured at zero when what it means is that the
      # branch never ran, and those are different facts.
      "by_tag" => Map.reject(measurement.errors.by_tag, fn {_tag, count} -> count == 0 end)
    }
  end

  defp rate(_total, 0), do: 0.0
  defp rate(total, operations), do: Float.round(total / operations, 6)

  defp memory(before, after_warmup) do
    %{
      "before" => before,
      "after_warmup" => after_warmup,
      "after" => Report.memory_sample(),
      "counters_table_bytes" => Report.counters_table_bytes()
    }
  end

  defp table_size(table) do
    case :ets.info(table, :size) do
      :undefined -> nil
      size -> size
    end
  end

  defp pending_items do
    case :ets.whereis(Store.flush_batches_table()) do
      :undefined ->
        nil

      _ref ->
        case :ets.lookup(Store.flush_batches_table(), :pending) do
          [{:pending, batch}] -> length(batch.taken)
          [] -> 0
        end
    end
  end

  @doc "Whether this host can run the distributed modes, and why not when it cannot."
  @spec distribution_available?() :: :ok | {:error, term()}
  def distribution_available?, do: Cluster.ensure_distribution()
end
