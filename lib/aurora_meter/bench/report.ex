defmodule AuroraMeter.Bench.Report do
  @moduledoc false

  # The machine-readable record one bench run produces.
  #
  # Task 08.07 asks for the machine, the CPU, the memory, the OS, the runtime
  # and database versions, the exact script, the warm-up, the workload, p50, p95
  # and p99, the throughput, the memory, the backlog and the error rate. Every
  # one of those is a field here, and **a field whose source this host could not
  # supply is `null` with a note** rather than a zero, a guess or an omission. A
  # zero reads as a measurement; an omitted key reads as a schema that changed.
  #
  # The shape is checked by `priv/bench/report.schema.json`, which is a test
  # fixture and not a runtime dependency: nothing in `lib/` reads it.

  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Clock

  @schema_version 1

  @type t :: map()

  @doc """
  Assembles one run's record.

  `fields` carries what the run measured; everything else is collected from the
  host here so that no mode can forget a field.
  """
  @spec build(map()) :: t()
  def build(fields) do
    {machine, machine_notes} = machine()
    {database, database_notes} = database(fields[:repo])
    {package, package_notes} = package()

    notes = Enum.uniq(machine_notes ++ database_notes ++ package_notes ++ (fields[:notes] || []))

    %{
      "schema_version" => @schema_version,
      "run_id" => fields.run_id,
      "label" => fields.label,
      "mode" => to_string(fields.mode),
      "kind" => to_string(fields.kind),
      "started_at" => fields.started_at,
      "finished_at" => fields.finished_at,
      "package" => package,
      "runtime" => runtime(),
      "machine" => machine,
      "database" => database,
      "command" => fields.command,
      "config" => fields.config,
      "workload" => fields.workload,
      "warmup" => fields.warmup,
      "latency_us" => latency(fields),
      "throughput_ops_per_sec" => fields.throughput_ops_per_sec,
      "duration_ms" => fields.duration_ms,
      "memory" => fields.memory,
      "backlog" => fields.backlog,
      "errors" => fields.errors,
      "correct" => fields.correct,
      "notes" => notes
    }
  end

  @doc "Writes a record to `path` as pretty JSON, creating the directory."
  @spec write!(t(), Path.t()) :: :ok
  def write!(report, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true) <> "\n")
    :ok
  end

  @doc """
  An ISO 8601 UTC stamp, for a point in time and never for a duration.

  Through `AuroraMeter.Clock` and not `DateTime.utc_now/0`: P07 says no module
  under `lib/` reads a clock outside the seam, and the bench is not exempt from
  the seam it exists to measure. Every duration in this suite comes from
  `AuroraMeter.Bench.Mode.time/1`, which reads the monotonic clock through
  `AuroraMeter.Clock`; this is only ever a label on a record.
  """
  @spec stamp() :: String.t()
  def stamp, do: Clock.now() |> DateTime.to_iso8601()

  @doc "A memory sample: the four `:erlang.memory/0` figures this record carries."
  @spec memory_sample() :: map()
  def memory_sample do
    memory = :erlang.memory()

    %{
      "total" => memory[:total],
      "processes" => memory[:processes],
      "ets" => memory[:ets],
      "binary" => memory[:binary]
    }
  end

  @doc "The counters table's memory in bytes, or `nil` when the table is not there."
  @spec counters_table_bytes() :: non_neg_integer() | nil
  def counters_table_bytes do
    case :ets.info(AuroraMeter.Store.counters_table(), :memory) do
      :undefined -> nil
      words -> words * :erlang.system_info(:wordsize)
    end
  end

  # -- the collected blocks ---------------------------------------------------

  defp latency(fields) do
    samples = fields.samples

    Stats.summary(samples)
    |> Map.new(fn {key, value} -> {to_string(key), maybe_round(key, value)} end)
    |> Map.put("sampled", fields.sampled)
    |> Map.put("sample_every", fields.sample_every)
  end

  defp maybe_round(:method, value), do: value
  defp maybe_round(:samples, value), do: value
  defp maybe_round(_key, value), do: Stats.round2(value)

  defp runtime do
    %{
      "elixir" => System.version(),
      "otp" => List.to_string(:erlang.system_info(:otp_release)),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "schedulers_online" => :erlang.system_info(:schedulers_online)
    }
  end

  # Every one of these can be absent, and each absence is its own note. On this
  # host they all resolve; on a Mac `/proc` does not exist at all, and a record
  # taken there has to say so rather than report a zero-core machine.
  defp machine do
    {os, os_note} = read_os()
    {distribution, dist_note} = read_distribution()
    {cpu_model, cpu_note} = read_cpu_model()
    {total_memory, mem_note} = read_total_memory()

    machine = %{
      "os" => os,
      "distribution" => distribution,
      "cpu_model" => cpu_model,
      "logical_cpus" => :erlang.system_info(:logical_processors_available),
      "total_memory_bytes" => total_memory
    }

    {machine, Enum.reject([os_note, dist_note, cpu_note, mem_note], &is_nil/1)}
  end

  defp read_os do
    {family, name} = :os.type()

    case :os.version() do
      {major, minor, patch} ->
        {"#{family}/#{name} #{major}.#{minor}.#{patch}", nil}

      version when is_list(version) ->
        {"#{family}/#{name} #{List.to_string(version)}", nil}
    end
  end

  defp read_distribution do
    case File.read("/etc/os-release") do
      {:ok, contents} ->
        case Regex.run(~r/^PRETTY_NAME="?([^"\n]+)"?/m, contents) do
          [_, name] -> {name, nil}
          nil -> {nil, "machine.distribution is null: /etc/os-release has no PRETTY_NAME"}
        end

      {:error, reason} ->
        {nil, "machine.distribution is null: /etc/os-release unreadable (#{inspect(reason)})"}
    end
  end

  defp read_cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, contents} ->
        case Regex.run(~r/^model name\s*:\s*(.+)$/m, contents) do
          [_, model] -> {String.trim(model), nil}
          nil -> {nil, "machine.cpu_model is null: /proc/cpuinfo has no model name line"}
        end

      {:error, reason} ->
        {nil, "machine.cpu_model is null: /proc/cpuinfo unreadable (#{inspect(reason)})"}
    end
  end

  defp read_total_memory do
    case File.read("/proc/meminfo") do
      {:ok, contents} ->
        case Regex.run(~r/^MemTotal:\s+(\d+) kB$/m, contents) do
          [_, kb] -> {String.to_integer(kb) * 1024, nil}
          nil -> {nil, "machine.total_memory_bytes is null: /proc/meminfo has no MemTotal"}
        end

      {:error, reason} ->
        {nil, "machine.total_memory_bytes is null: /proc/meminfo unreadable (#{inspect(reason)})"}
    end
  end

  # `used: false` for a micro mode, and then every other field is `null`: a
  # micro run has no database, and reporting the configured one would invite a
  # reader to believe Postgres was in the measured path.
  defp database(nil) do
    {%{
       "used" => false,
       "server_version" => nil,
       "host" => nil,
       "port" => nil,
       "database" => nil,
       "container" => nil,
       "pool_size" => nil
     },
     [
       "database.used is false, and database.server_version, host, port, database, container " <>
         "and pool_size are all null for that reason: this is a micro mode and no database " <>
         "was opened. Naming the configured one would invite a reader to believe Postgres was " <>
         "in the measured path."
     ]}
  end

  defp database(repo) do
    config = repo.config()
    {version, version_note} = server_version(repo)
    {container, container_note} = container()

    database = %{
      "used" => true,
      "server_version" => version,
      "host" => to_string(config[:hostname] || "unknown"),
      "port" => config[:port],
      "database" => config[:database],
      "container" => container,
      "pool_size" => config[:pool_size]
    }

    {database, Enum.reject([version_note, container_note], &is_nil/1)}
  end

  defp server_version(repo) do
    case repo.query("SELECT version()", []) do
      {:ok, %{rows: [[version]]}} ->
        {version, nil}

      other ->
        {nil, "database.server_version is null: SELECT version() answered #{inspect(other)}"}
    end
  rescue
    error ->
      {nil, "database.server_version is null: #{Exception.message(error)}"}
  end

  # The container name is the runner's to supply: the library has no business
  # knowing about Docker, and `docs/evidence/v1/phase-00/inventory.json` (which
  # records which container holds the package test port) lives in another
  # repository. Absent, it is null with a note, never the default guessed.
  defp container do
    case System.get_env("AURORA_BENCH_CONTAINER") do
      nil ->
        {nil,
         "database.container is null: AURORA_BENCH_CONTAINER was not set, so the run " <>
           "cannot name the container holding this database"}

      "" ->
        {nil, "database.container is null: AURORA_BENCH_CONTAINER was set to an empty string"}

      name ->
        {name, nil}
    end
  end

  defp package do
    version = to_string(Application.spec(:aurora_meter, :vsn) || Mix.Project.config()[:version])
    {sha, dirty, notes} = git()

    {%{
       "name" => "aurora_meter",
       "version" => version,
       "git_sha" => sha,
       "git_dirty" => dirty
     }, notes}
  end

  # **Files only.** `AuroraMeter.NoOutboundIoTest` forbids `System.cmd` anywhere
  # under `lib/`, and decision D11 is why: the free core is documented as
  # sending nothing anywhere on its own, and a benchmark that shells out to git
  # is the first step away from that, however harmless the command. The SHA is
  # read out of `.git` with `File.read/1`; a packed ref is followed.
  #
  # `git_dirty` cannot be answered without running git, so it is **not guessed**:
  # the runner, which may run git, passes `AURORA_BENCH_GIT_DIRTY`, and without
  # it the field is `null` with a note.
  defp git do
    {sha, sha_note} = git_sha()
    {dirty, dirty_note} = git_dirty()
    {sha, dirty, Enum.reject([sha_note, dirty_note], &is_nil/1)}
  end

  defp git_sha do
    case File.read(".git/HEAD") do
      {:ok, "ref: " <> ref} -> resolve_ref(String.trim(ref))
      {:ok, sha} -> {String.trim(sha), nil}
      {:error, reason} -> {nil, "package.git_sha is null: .git/HEAD (#{inspect(reason)})"}
    end
  end

  defp resolve_ref(ref) do
    case File.read(Path.join(".git", ref)) do
      {:ok, sha} -> {String.trim(sha), nil}
      {:error, _loose} -> packed_ref(ref)
    end
  end

  defp packed_ref(ref) do
    with {:ok, contents} <- File.read(".git/packed-refs"),
         [_, sha] <- Regex.run(~r/^([0-9a-f]{40}) #{Regex.escape(ref)}$/m, contents) do
      {sha, nil}
    else
      _unresolved -> {nil, "package.git_sha is null: #{ref} resolves to no object file"}
    end
  end

  defp git_dirty do
    case System.get_env("AURORA_BENCH_GIT_DIRTY") do
      "true" ->
        {true, nil}

      "false" ->
        {false, nil}

      _absent ->
        {nil,
         "package.git_dirty is null: answering it needs git, which this library never runs " <>
           "(decision D11). scripts/v1/bench.sh sets AURORA_BENCH_GIT_DIRTY."}
    end
  end
end
