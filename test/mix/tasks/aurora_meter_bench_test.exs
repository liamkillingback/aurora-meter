defmodule Mix.Tasks.AuroraMeter.BenchTest do
  @moduledoc """
  `mix aurora_meter.bench`, run as a command rather than as a function call.

  Every case here runs the task in a **separate OS process**, and it is a plain
  `elixir` rather than a nested `mix`, which matters more than it sounds.

  Calling `Mix.Tasks.AuroraMeter.Bench.run/1` in this VM would have the task
  rewrite `:aurora_meter`'s application environment (plans, storage, history,
  feature sources) under a suite that is mostly `async: true`, and start a
  second `AuroraMeter.Store` against a name the suite already holds.

  A nested `mix` is worse, and it was measured: a nested invocation reaches into
  the same `_build`, and while it did, **604 tests elsewhere in this suite
  failed**. With this file moved aside the same commit ran 1985 of 1990. So the
  task is booted with `elixir -pa <every code path> boot.exs`, which compiles
  nothing, touches no manifest and takes no build lock. The configuration the
  guards read is loaded from `config/config.exs` with `Config.Reader`, so the
  refusals are the ones a developer would meet.

  **Two schedulers, not the machine's.** A BEAM started with no flags takes one
  scheduler per logical CPU, and a dozen of these run concurrently in an
  `async: true` module; on a 24 core host that is 288 scheduler threads
  competing with the suite's own 24. `+S 2:2` bounds each child to what the task
  needs, which is a workload of `--procs 2`.

  **Every spawn asserts that the application survived it.** An external process
  is the one thing in this file that could perturb the VM running the suite, and
  if it ever does the failure has to name itself here rather than surface as
  someone else's test failing on ETS tables that no longer exist
  (`open-findings.md` X347).

  The end-to-end modes are **not** run here and the reason is stated rather than
  hidden: they need the separate `aurora_meter_bench` database, which this suite
  neither creates nor owns. What is tested here is that they refuse, correctly
  and with a message that says what to do, when they are pointed at the test
  database. Their measurements are in build unit 08c's results evidence, and the
  records they produced are validated against the schema by
  `AuroraMeter.Bench.ReportTest`.

  This file writes exactly one file, a boot script, into the system temp
  directory, and removes it with the test process. It writes nothing a commit
  would carry. `AuroraMeter.EvidenceWritesTest` flags any test file holding both
  a `File.write!` and the literal evidence path, so the path is named in prose
  here rather than spelled out: the guard is blunt on purpose and this file is
  not worth blunting it further for.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Counter
  alias AuroraMeter.Test.JsonSchema

  @micro_modes [:spread, :hot, :reserve, :with_quota, :cluster_2_sim]

  setup_all do
    schema =
      "priv/bench/report.schema.json"
      |> File.read!()
      |> Jason.decode!()

    {:ok, schema: schema}
  end

  describe "C7: the row shape lives in one module" do
    test "C7 Counter.value/3 returns a value for a key warmed by the bench" do
      # The regression, in the original. `bench.ex:40` wrote
      # `{key, 0, 0, 0}` and `Counter.read/1` matches a SIX element tuple, so
      # the task did all its work and then raised `MatchError` printing it. The
      # increments themselves succeeded, because `bump/2` only touches
      # positions 2, 3 and 4, which is why this was invisible until the summary.
      key = {"bench_c7_#{System.unique_integer([:positive])}", :ops, ~U[2026-07-01 00:00:00Z]}
      {tenant, feature, period} = key

      assert :ok = Counter.warm(key)
      assert Counter.value(tenant, feature, period) == 0

      # The day bucket is warmed too, because `incr/4` bumps one when `:history`
      # is on and a cold day key would seed itself from the database. This test
      # is about the ROW SHAPE and must not depend on a connection.
      assert :ok = Counter.warm({tenant, feature, {:day, AuroraMeter.Clock.today()}})

      Counter.incr(tenant, feature, 3, period)
      assert Counter.value(tenant, feature, period) == 3
    end

    test "C7 Counter.warm/2 seeds a row the whole hot path can read and write" do
      key = {"bench_c7b_#{System.unique_integer([:positive])}", :ops, ~U[2026-07-01 00:00:00Z]}
      {tenant, feature, period} = key

      assert :ok = Counter.warm(key, 40)
      assert Counter.value(tenant, feature, period) == 40
      assert Counter.base(key) == 40
      assert Counter.remote_since_rebase(key) == 0
      assert :ok = Counter.reserve(tenant, feature, 2, period, nil, true)
      assert :ok = Counter.release_work(tenant, feature, 2, period)
      assert Counter.value(tenant, feature, period) == 40
    end

    test "C7 no bench file writes a tuple into the counters table" do
      offenders =
        ["lib/aurora_meter/bench/**/*.ex", "lib/mix/tasks/aurora_meter.bench.ex"]
        |> Enum.flat_map(&Path.wildcard/1)
        |> Enum.filter(&(File.read!(&1) =~ ~r/:ets\.insert(_new)?\(\s*Store\.counters_table/))

      assert offenders == [],
             "the bench must warm rows through AuroraMeter.Counter.warm/2 and never build a " <>
               "counter tuple of its own. Building it twice is what let the shapes drift " <>
               "(open-findings.md C7). Offending files: #{inspect(offenders)}"
    end
  end

  describe "the command line" do
    test "an unknown mode exits non-zero and lists the valid modes" do
      {output, status} = bench(["nonsense"])

      assert status != 0
      assert output =~ "unknown mode \"nonsense\""

      for mode <- Modes.all(), do: assert(output =~ to_string(mode))
    end

    test "a missing mode exits non-zero and lists the valid modes" do
      {output, status} = bench([])

      assert status != 0
      assert output =~ "a mode is required"
    end

    test "an unknown switch exits non-zero" do
      {output, status} = bench(["spread", "--warmups", "10"])

      assert status != 0
      assert output =~ "unknown or malformed switch"
      assert output =~ "warmups"
    end

    test "the positional form 8 500000 runs the spread mode and prints a deprecation notice" do
      {output, status} = bench(["2", "200", "--warmup", "20", "--quiet"])

      assert status == 0
      assert output =~ "is deprecated and is removed in 2.0"
      assert output =~ "mix aurora_meter.bench spread --procs 2 --per 200"
    end
  end

  describe "the end-to-end guards" do
    test "an end-to-end mode refuses a repo configured with the Ecto sandbox" do
      # The ordinary test configuration IS the refused one, which is the only
      # reason this guard is a guard: `config/config.exs` resolves
      # AuroraMeter.TestRepo to aurora_meter_test with the sandbox unless
      # AURORA_BENCH=1 is set. A test that had to construct a bad configuration
      # to trip a guard would be testing its own fixture.
      {output, status} = bench(["record", "--procs", "1", "--per", "1"])

      assert status != 0
      assert output =~ "Ecto.Adapters.SQL.Sandbox"
      assert output =~ "would measure the sandbox"
      assert output =~ "AURORA_BENCH=1"
    end

    test "an end-to-end mode refuses a repo whose database does not end in _bench" do
      # A pooled repo whose database is the test one: the sandbox guard cannot
      # fire, so the name guard is the one under test. `--repo` names a module
      # this suite compiles for exactly this purpose.
      {output, status} = bench(["record", "--repo", "AuroraMeter.Test.PooledTestRepo"])

      assert status != 0
      assert output =~ "must end in _bench"
      assert output =~ "aurora_meter_test"
    end
  end

  describe "the micro modes" do
    for mode <- @micro_modes do
      @tag mode: mode
      test "#{mode} smoke: runs with tiny parameters and reports correct: true", %{
        mode: mode,
        schema: schema
      } do
        path =
          Path.join(System.tmp_dir!(), "aurora_bench_#{mode}_#{:rand.uniform(1_000_000)}.json")

        on_exit(fn -> File.rm_rf!(path) end)

        {output, status} =
          bench([
            to_string(mode),
            "--procs",
            "2",
            "--per",
            "200",
            "--warmup",
            "20",
            "--sample-every",
            "10",
            "--json",
            path
          ])

        assert status == 0, output
        assert output =~ "correct:      true"

        record = path |> File.read!() |> Jason.decode!()
        assert JsonSchema.validate(record, schema) == :ok
        assert record["kind"] == "micro"
        assert record["correct"] == true
        assert record["database"]["used"] == false
        assert record["latency_us"]["sampled"] == true
        assert record["latency_us"]["sample_every"] == 10
      end
    end

    test "a micro record names no database at all, so no reader can think one was in the path" do
      path = Path.join(System.tmp_dir!(), "aurora_bench_db_#{:rand.uniform(1_000_000)}.json")
      on_exit(fn -> File.rm_rf!(path) end)

      {_output, 0} =
        bench(["spread", "--procs", "1", "--per", "50", "--warmup", "5", "--json", path])

      database = path |> File.read!() |> Jason.decode!() |> Map.fetch!("database")

      assert database["used"] == false

      for field <- ~w(server_version host port database container pool_size) do
        assert database[field] == nil,
               "#{field} is #{inspect(database[field])} on a micro record. A micro mode has no " <>
                 "database, and naming the configured one invites a reader to believe Postgres " <>
                 "was in the measured path."
      end
    end
  end

  describe "P3 and the distribution refusal" do
    test "P3 a mode whose correctness assertion fails exits non-zero and records correct: false" do
      path = Path.join(System.tmp_dir!(), "aurora_bench_p3_#{:rand.uniform(1_000_000)}.json")
      on_exit(fn -> File.rm_rf!(path) end)

      {output, status} = bench(["cluster_2", "--per", "2", "--json", path], distribution: false)

      assert status != 0
      assert output =~ "correct:      false"

      record = path |> File.read!() |> Jason.decode!()

      assert record["correct"] == false,
             "a run whose correctness assertion failed must record correct: false. Its " <>
               "throughput is not evidence of anything: a wrong system is not a slower right one."
    end

    test "cluster_2 records distribution_unavailable and never substitutes the simulation" do
      path = Path.join(System.tmp_dir!(), "aurora_bench_dist_#{:rand.uniform(1_000_000)}.json")
      on_exit(fn -> File.rm_rf!(path) end)

      {output, status} = bench(["cluster_2", "--per", "2", "--json", path], distribution: false)

      assert status != 0

      record = path |> File.read!() |> Jason.decode!()

      assert record["backlog"]["cluster"]["reason"] == "distribution_unavailable"
      assert record["errors"]["by_tag"]["distribution_unavailable"] == 1
      assert record["mode"] == "cluster_2"
      assert Enum.any?(record["notes"], &(&1 =~ "did NOT fall back to cluster_2_sim"))

      refute output =~ "cluster_2_sim ran",
             "a cluster mode that cannot start peers must exit non-zero with the reason " <>
               "recorded. Substituting the single-VM simulation would publish a number that " <>
               "measured one scheduler, one pool and one ETS table as a cluster result."
    end
  end

  # -- running the command ----------------------------------------------------

  # `AURORA_BENCH` is explicitly UNSET rather than left to the caller's shell: a
  # developer who exported it would otherwise turn the two guard tests green by
  # making the guards not fire, which is the failure mode those tests exist to
  # catch.
  defp bench(args, opts \\ []) do
    env =
      [{"AURORA_BENCH", nil}] ++
        if Keyword.get(opts, :distribution, true),
          do: [],
          else: [{"AURORA_BENCH_NO_DISTRIBUTION", "1"}]

    result =
      System.cmd("elixir", vm_flags() ++ code_paths() ++ [boot_script() | args],
        stderr_to_stdout: true,
        env: env
      )

    assert Process.whereis(AuroraMeter.Supervisor),
           "the AuroraMeter supervision tree went down while an external `elixir` was " <>
             "running. That is this file's spawn perturbing the VM under the suite, and it " <>
             "is asserted here so it cannot surface as 600 unrelated ETS failures " <>
             "(open-findings.md X347)."

    result
  end

  # Two schedulers rather than one per logical CPU. See the moduledoc.
  defp vm_flags, do: ["--erl", "+S 2:2 +A 2"]

  defp code_paths, do: Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

  # Written once per test process and removed with it. It starts Mix (the task
  # calls `Mix.shell/0` and `Mix.env/0`), loads this project's `:test`
  # configuration so the repo guards see what a developer would see, and turns
  # the task's `exit({:shutdown, code})` into a real process exit code.
  defp boot_script do
    path = Path.join(System.tmp_dir!(), "aurora_bench_boot_#{:rand.uniform(1_000_000_000)}.exs")

    File.write!(path, """
    Mix.start()
    Mix.env(:test)
    Application.load(:aurora_meter)

    "config/config.exs"
    |> Config.Reader.read!(env: :test)
    |> Application.put_all_env()

    try do
      Mix.Tasks.AuroraMeter.Bench.run(System.argv())
      System.halt(0)
    catch
      :exit, {:shutdown, code} -> System.halt(code)
      :exit, code when is_integer(code) -> System.halt(code)
    end
    """)

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
