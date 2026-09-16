defmodule Mix.Tasks.AuroraMeter.Bench do
  @shortdoc "Benchmarks metering, quota, durable and ledger paths, and records the result"

  @moduledoc """
  Measures Aurora Meter and writes a machine-readable record of what it
  measured.

      mix aurora_meter.bench <mode> [options]

  ## Modes

  `kind` is the column to read first. A **micro** mode isolates an in-memory
  path with stubbed or absent persistence; an **end-to-end** mode reaches
  Postgres through the real adapter on every write. The two differ by orders of
  magnitude, so a figure quoted without its kind says very little.

  | Mode | Kind | What it measures |
  |---|---|---|
  | `spread` | micro | `Counter.incr/4` on one distinct key per worker |
  | `hot` | micro | `Counter.incr/4` on a single shared key |
  | `reserve` | micro | `AuroraMeter.reserve/3`, admitting and denying |
  | `with_quota` | micro | `AuroraMeter.with_quota/4` with a no-op callback |
  | `cluster_2_sim` | micro | gossip apply cost in one VM (**not** a cluster result) |
  | `record` | end_to_end | `AuroraMeter.record/4`, one event per call |
  | `record_batch` | end_to_end | `AuroraMeter.record_batch/2` at 1, 10, 100 and 500 |
  | `correct` | end_to_end | `AuroraMeter.correct/4` against pre-recorded originals |
  | `replay` | end_to_end | `AuroraMeter.Events.Replay.run/1` over a seeded population |
  | `credits_debit` | end_to_end | `AuroraMeter.Credits.debit/4` across distinct wallets |
  | `credits_hot_wallet` | end_to_end | the same debit against one shared wallet |
  | `flush_1k`, `flush_10k`, `flush_100k` | end_to_end | one `Flusher.flush/0` with that many dirty keys |
  | `db_delay` | end_to_end | sustained load with a delay in front of every storage call |
  | `db_recovery` | end_to_end | sustained load across a real database outage, and the drain |
  | `cluster_2`, `cluster_4` | end_to_end | convergence and overshoot on real peer nodes |

  ## Options

    * `--procs N` workers, default 8
    * `--per N` operations per worker, default 500,000 micro and 2,000 end-to-end
    * `--warmup N` discarded operations per worker, default a tenth of `--per`
    * `--rounds N` repetitions for the modes whose unit is a whole operation
      (`replay`, `flush_*`), default 5
    * `--duration MS` the load window for `db_delay` and `db_recovery`
    * `--json PATH` write the record here
    * `--label TEXT` a name for this run, default the mode
    * `--repo MODULE` the end-to-end repo
    * `--history` / `--no-history` whether day buckets are maintained
    * `--seed N` recorded in the record; random when not given
    * `--sample-every N` micro latency sampling rate, default 1,000
    * `--delay-us N` the per-callback delay for `db_delay`
    * `--broadcast-interval MS`, `--flush-interval MS` override the mode's own
      defaults. The cluster overshoot guarantee is stated in terms of one
      `broadcast_interval`, so being able to vary it is how that guarantee is
      measured rather than assumed
    * `--allow-any-database` run against a database whose name does not end in `_bench`
    * `--quiet` print nothing but the verdict

  ## The database

  End-to-end modes run against **their own** database, whose name must end in
  `_bench`, with an ordinary pooled connection. Set `AURORA_BENCH=1` so this
  repository's test repo resolves to `aurora_meter_bench`, and create it with
  `mix bench.setup`. A repo configured with `Ecto.Adapters.SQL.Sandbox` is
  refused outright: the sandbox serialises every worker onto one owned
  connection, so the run would measure the sandbox.

  ## The deprecated positional form

  `mix aurora_meter.bench 8 500000` still runs, as `spread --procs 8 --per
  500000`, and prints a deprecation notice. It is removed in 2.0.
  """

  use Mix.Task

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Report
  alias AuroraMeter.Bench.Runner

  @switches [
    procs: :integer,
    per: :integer,
    warmup: :integer,
    rounds: :integer,
    duration: :integer,
    json: :string,
    label: :string,
    repo: :string,
    history: :boolean,
    seed: :integer,
    sample_every: :integer,
    batch_size: :integer,
    delay_us: :integer,
    drain_timeout: :integer,
    backlog_keys: :integer,
    converge_ms: :integer,
    broadcast_interval: :integer,
    flush_interval: :integer,
    allow_any_database: :boolean,
    quiet: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case parse(argv) do
      {:ok, mode, opts} -> execute(mode, opts)
      {:error, message} -> abort(message)
    end
  end

  # -- parsing ----------------------------------------------------------------

  # The positional form is recognised before `OptionParser` sees it, so the
  # exact command printed in README.md and in this module's own doc since 0.2
  # keeps working. It is a deprecation and not a silent alias: a reader of the
  # output is told what to run instead.
  defp parse([procs, per | rest]) do
    if numeric?(procs) and numeric?(per) do
      Mix.shell().info([
        :yellow,
        "mix aurora_meter.bench #{procs} #{per} is deprecated and is removed in 2.0. Run " <>
          "`mix aurora_meter.bench spread --procs #{procs} --per #{per}` instead.",
        :reset
      ])

      parse(["spread", "--procs", procs, "--per", per | rest])
    else
      parse_mode([procs, per | rest])
    end
  end

  defp parse(argv), do: parse_mode(argv)

  defp parse_mode([]), do: {:error, "a mode is required.\n\n#{mode_list()}"}

  defp parse_mode([name | rest]) do
    with {:ok, mode} <- mode(name),
         {:ok, parsed} <- switches(rest) do
      {:ok, mode, options(mode, parsed, [name | rest])}
    end
  end

  # Matched against the table by STRING rather than by
  # `String.to_existing_atom/1`. Two reasons: the atom for a mode exists only
  # once `AuroraMeter.Bench.Modes` has been loaded, so the conversion refused
  # every valid mode on a cold start; and turning user input into an atom is a
  # habit worth not having in a shipped task.
  defp mode(name) do
    case Enum.find(Modes.all(), &(to_string(&1) == name)) do
      nil -> {:error, unknown_mode(name)}
      found -> {:ok, found}
    end
  end

  defp unknown_mode(name), do: "unknown mode #{inspect(name)}.\n\n#{mode_list()}"

  defp mode_list do
    rows = Enum.map_join(Modes.all(), "\n", &"  #{&1} (#{Modes.kind(&1)})")
    "Valid modes:\n#{rows}"
  end

  # Strict, and an unknown switch is an error rather than a silent default: a
  # bench invoked with `--warmups 10` and no complaint would run with the
  # default warm-up and record a command line that says otherwise.
  defp switches(rest) do
    case OptionParser.parse(rest, strict: @switches) do
      {parsed, [], []} ->
        {:ok, parsed}

      {_parsed, extra, []} ->
        {:error, "unexpected arguments: #{inspect(extra)}"}

      {_parsed, _extra, invalid} ->
        {:error, "unknown or malformed switch: #{inspect(Enum.map(invalid, &elem(&1, 0)))}"}
    end
  end

  defp numeric?(value), do: Regex.match?(~r/^\d+$/, value)

  defp options(mode, parsed, argv) do
    micro? = Modes.kind(mode) == :micro
    per = Keyword.get(parsed, :per, default_per(mode, micro?))

    %{
      procs: Keyword.get(parsed, :procs, 8),
      per: per,
      warmup: Keyword.get(parsed, :warmup, max(div(per, 10), 1)),
      rounds: Keyword.get(parsed, :rounds, 5),
      duration_ms: Keyword.get(parsed, :duration, 20_000),
      json: Keyword.get(parsed, :json),
      label: Keyword.get(parsed, :label),
      repo: repo(parsed, mode),
      history: Keyword.get(parsed, :history, not micro? and mode not in flushless()),
      seed: Keyword.get(parsed, :seed, :erlang.unique_integer([:positive])),
      sample_every: Keyword.get(parsed, :sample_every, 1_000),
      batch_size: Keyword.get(parsed, :batch_size, 500),
      delay_us: Keyword.get(parsed, :delay_us, 50_000),
      drain_timeout_ms: Keyword.get(parsed, :drain_timeout, 300_000),
      backlog_keys: Keyword.get(parsed, :backlog_keys, 2_000),
      converge_ms: Keyword.get(parsed, :converge_ms, 3_000),
      broadcast_interval: Keyword.get(parsed, :broadcast_interval),
      flush_interval: Keyword.get(parsed, :flush_interval),
      allow_any_database: Keyword.get(parsed, :allow_any_database, false),
      quiet: Keyword.get(parsed, :quiet, false),
      command: Enum.join(["mix aurora_meter.bench" | argv], " ")
    }
  end

  defp flushless, do: [:flush_1k, :flush_10k, :flush_100k]

  # The default workload per mode, chosen so that every mode's five runs take a
  # comparable wall time on this hardware rather than so that every mode runs
  # the same NUMBER of operations. An ETS increment and a `record_batch/2` of
  # five hundred events differ by five orders of magnitude, and a single default
  # would make one mode instant and another take an hour. Every record carries
  # the workload it actually ran, so no figure is ambiguous about what it
  # measured.
  defp default_per(mode, true) when mode in [:reserve, :with_quota], do: 50_000
  defp default_per(_mode, true), do: 500_000
  defp default_per(:replay, false), do: 500
  defp default_per(:correct, false), do: 1_000
  defp default_per(:record_batch, false), do: 200
  defp default_per(mode, false) when mode in [:cluster_2, :cluster_4], do: 20_000
  defp default_per(_mode, false), do: 2_000

  defp repo(parsed, mode) do
    cond do
      not Modes.needs_repo?(mode) -> nil
      name = Keyword.get(parsed, :repo) -> Module.concat([name])
      true -> Application.get_env(:aurora_meter, :repo)
    end
  end

  # -- running ----------------------------------------------------------------

  defp execute(mode, opts) do
    case Runner.run(mode, opts) do
      {:ok, report} -> finish(report, opts)
      {:error, message} -> abort(message)
    end
  end

  defp finish(report, opts) do
    if opts.json, do: Report.write!(report, opts.json)
    unless opts.quiet, do: Mix.shell().info(summary(report))

    if report["correct"] do
      :ok
    else
      abort(
        "the run's correctness check failed, so its numbers are not evidence of anything:\n" <>
          Enum.map_join(report["notes"], "\n", &"  #{&1}")
      )
    end
  end

  defp summary(report) do
    """

    Aurora Meter bench: #{report["label"]} (#{report["mode"]}, kind: #{report["kind"]})
      operations:   #{report["workload"]["operations"]} over #{report["workload"]["procs"]} procs
      warm-up:      #{report["warmup"]["operations"]} ops in #{report["warmup"]["duration_ms"]} ms (discarded)
      elapsed:      #{report["duration_ms"]} ms
      throughput:   #{report["throughput_ops_per_sec"]} ops/s
      latency (us): p50 #{report["latency_us"]["p50"]}  p95 #{report["latency_us"]["p95"]}  \
    p99 #{report["latency_us"]["p99"]}  (sampled: #{report["latency_us"]["sampled"]}, \
    n=#{report["latency_us"]["samples"]})
      errors:       #{report["errors"]["total"]} (#{inspect(report["errors"]["by_tag"])})
      correct:      #{report["correct"]}
      toolchain:    Elixir #{report["runtime"]["elixir"]} / OTP #{report["runtime"]["otp"]}
      database:     #{database_line(report["database"])}
    #{Enum.map_join(report["notes"], "\n", &"  note: #{&1}")}
    """
  end

  defp database_line(%{"used" => false}), do: "none (micro)"

  defp database_line(database) do
    "#{database["database"]} on #{database["host"]}:#{database["port"]} " <>
      "(#{database["server_version"] || "version unavailable"})"
  end

  defp abort(message) do
    Mix.shell().error("aurora_meter.bench: " <> message)
    exit({:shutdown, 1})
  end
end
