defmodule AuroraMeter.Bench.ReportTest do
  @moduledoc """
  The bench record's contract: `priv/bench/report.schema.json`, and the three
  rules the schema cannot express.

  The records checked here are the real ones, produced by
  `tmp/v1/08c-smoke.sh` and committed under
  `docs/evidence/v1/phase-08/runs/smoke/`. They are read rather than re-run
  because ten of the eighteen modes need the separate `aurora_meter_bench`
  database and two need real peer nodes, neither of which this suite owns. What
  that costs is stated plainly: a change to an end-to-end mode's record shape is
  caught here only after somebody re-runs the smoke script. What it buys is that
  the set is checked against `AuroraMeter.Bench.Modes.all/0`, so a mode that
  stops producing a record at all is a failure rather than an absence.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Stats
  alias AuroraMeter.Test.JsonSchema

  @smoke "docs/evidence/v1/phase-08/runs/smoke"

  setup_all do
    schema = "priv/bench/report.schema.json" |> File.read!() |> Jason.decode!()

    records =
      @smoke
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Map.new(fn path ->
        {Path.basename(path, ".json"), path |> File.read!() |> Jason.decode!()}
      end)

    {:ok, schema: schema, records: records}
  end

  describe "P2: every record matches the schema" do
    test "P2 a smoke record exists for every mode in the table", %{records: records} do
      missing = Enum.map(Modes.all(), &to_string/1) -- Map.keys(records)

      assert missing == [],
             "no smoke record under #{@smoke} for #{inspect(missing)}. A mode with no record " <>
               "is a mode nobody has run, and an empty selection is a failure and not a pass " <>
               "(open-findings.md X324, X325)."

      assert map_size(records) >= length(Modes.all())
    end

    test "P2 every mode's JSON record validates against priv/bench/report.schema.json", %{
      schema: schema,
      records: records
    } do
      for {mode, record} <- records do
        assert JsonSchema.validate(record, schema) == :ok, "#{mode} does not match the schema"
      end
    end

    test "P2 kind is exactly micro or end_to_end and matches the documented table", %{
      records: records
    } do
      for mode <- Modes.all() do
        record = Map.fetch!(records, to_string(mode))

        assert record["kind"] in ["micro", "end_to_end"]

        assert record["kind"] == to_string(Modes.kind(mode)),
               "#{mode} recorded kind #{inspect(record["kind"])} and the table says " <>
                 "#{inspect(Modes.kind(mode))}. The label is what stops an in-memory figure " <>
                 "being read as a durable one."
      end
    end

    test "cluster_2_sim is micro, so a single VM number can never be a cluster result" do
      assert Modes.kind(:cluster_2_sim) == :micro
      assert Modes.kind(:cluster_2) == :end_to_end
      assert Modes.kind(:cluster_4) == :end_to_end
    end
  end

  describe "task 08.07: every field, and a null that says why" do
    @required ~w(schema_version run_id label mode kind started_at finished_at package runtime
                 machine database command config workload warmup latency_us
                 throughput_ops_per_sec duration_ms memory backlog errors correct notes)

    test "every record carries every field 08.07 names", %{records: records} do
      for {mode, record} <- records, field <- @required do
        assert Map.has_key?(record, field), "#{mode} has no #{field}"
      end
    end

    test "every record carries machine, runtime, database and workload detail", %{
      records: records
    } do
      for {mode, record} <- records do
        for field <- ~w(os distribution cpu_model logical_cpus total_memory_bytes) do
          assert Map.has_key?(record["machine"], field), "#{mode}: machine.#{field} missing"
        end

        for field <- ~w(elixir otp erts schedulers_online) do
          assert record["runtime"][field], "#{mode}: runtime.#{field} missing or nil"
        end

        for field <- ~w(used server_version host port database container pool_size) do
          assert Map.has_key?(record["database"], field), "#{mode}: database.#{field} missing"
        end

        for field <- ~w(p50 p95 p99 max sampled sample_every samples method) do
          assert Map.has_key?(record["latency_us"], field), "#{mode}: latency_us.#{field} missing"
        end

        for field <- ~w(dirty_keys_at_end pending_batch_items_at_end timeline drain cluster) do
          assert Map.has_key?(record["backlog"], field), "#{mode}: backlog.#{field} missing"
        end

        for field <- ~w(rate total by_tag) do
          assert Map.has_key?(record["errors"], field), "#{mode}: errors.#{field} missing"
        end
      end
    end

    test "a field that is null is named in notes, never left as an unexplained blank", %{
      records: records
    } do
      # The branch this exercises today is `database.container`, which is null
      # on every micro record because a library has no business knowing about
      # Docker and the runner supplies the name. It is written as a rule over
      # every nullable field rather than as one assertion about that one, so it
      # keeps meaning something when a different source goes missing.
      nullable = [
        {"machine", ~w(os distribution cpu_model total_memory_bytes)},
        {"package", ~w(git_sha)}
      ]

      checked =
        for {mode, record} <- records,
            {block, fields} <- nullable,
            field <- fields,
            is_nil(record[block][field]) do
          assert Enum.any?(record["notes"], &String.contains?(&1, "#{block}.#{field}")),
                 "#{mode}: #{block}.#{field} is null and no note says why. A null with no " <>
                   "explanation is indistinguishable from a field somebody forgot."

          {mode, block, field}
        end

      # Not an assertion that something was null: on this host every /proc
      # source resolves. This prints what the rule covered, so a reader can see
      # whether it examined anything.
      assert is_list(checked)
    end

    test "a micro record's database block is null throughout and says why", %{records: records} do
      micro =
        for mode <- Modes.all(),
            Modes.kind(mode) == :micro,
            do: Map.fetch!(records, to_string(mode))

      assert length(micro) == 5,
             "five modes are micro in the table and #{length(micro)} micro records were found"

      for record <- micro do
        assert record["database"]["used"] == false

        for field <- ~w(server_version host port database container pool_size) do
          assert record["database"][field] == nil, "database.#{field} is not null on a micro run"
        end

        assert Enum.any?(record["notes"], &String.contains?(&1, "database.used is false")),
               "a micro record must say why its whole database block is null"
      end
    end

    test "an end-to-end record names its database, its server version and its container", %{
      records: records
    } do
      durable =
        for mode <- Modes.all(),
            Modes.kind(mode) == :end_to_end,
            record = Map.fetch!(records, to_string(mode)),
            record["database"]["used"],
            do: {mode, record}

      assert durable != [], "no end-to-end record opened a database"

      for {mode, record} <- durable do
        assert String.ends_with?(record["database"]["database"], "_bench"), "#{mode}"
        assert record["database"]["server_version"] =~ "PostgreSQL", "#{mode}"
        assert is_integer(record["database"]["port"]), "#{mode}"
        assert is_integer(record["database"]["pool_size"]), "#{mode}"

        if is_nil(record["database"]["container"]) do
          assert Enum.any?(record["notes"], &String.contains?(&1, "database.container is null")),
                 "#{mode}: the container is null and nothing says why"
        end
      end
    end
  end

  describe "latency" do
    test "micro modes record sampled: true and the rate; end-to-end modes record sampled: false",
         %{records: records} do
      for mode <- Modes.all() do
        record = Map.fetch!(records, to_string(mode))
        sampled = record["latency_us"]["sampled"]

        case Modes.kind(mode) do
          :micro ->
            assert sampled == true, "#{mode} is micro and must record sampled: true"
            assert is_integer(record["latency_us"]["sample_every"])

          :end_to_end ->
            assert sampled == false, "#{mode} is end_to_end and must time every operation"
        end
      end
    end

    test "a record with no latency samples says so in notes", %{records: records} do
      for {mode, record} <- records, record["latency_us"]["samples"] == 0 do
        assert record["latency_us"]["p50"] == nil, "#{mode}: no samples but a p50"

        assert Enum.any?(record["notes"], &String.contains?(&1, "latency_us.p50")),
               "#{mode}: the percentiles are null and nothing says why"
      end
    end

    test "percentiles use the nearest-rank method" do
      # Nearest rank on a known vector: sort ascending, take ceil(p * n), one
      # based. p95 of 1..100 is the 95th element, which is 95, and not the
      # 94.05th interpolated value a different definition would give.
      vector = Enum.shuffle(1..100)

      assert Stats.percentile(vector, 0.50) == 50
      assert Stats.percentile(vector, 0.95) == 95
      assert Stats.percentile(vector, 0.99) == 99
      assert Stats.percentile(vector, 1.0) == 100
      assert Stats.percentile(vector, 0.0) == 1

      assert Stats.percentile([], 0.5) == nil
      assert Stats.summary([])[:p50] == nil
      assert Stats.summary([])[:method] == "nearest_rank"
      assert Stats.summary(vector)[:method] == "nearest_rank"
    end

    test "the median is the same function as p50, so a run and a comparison agree" do
      assert Stats.median([3, 1, 2]) == Stats.percentile([3, 1, 2], 0.50)
      assert Stats.median([3, 1, 2]) == 2

      # An even count takes the lower of the two middles and averages nothing,
      # so a reported median is always a run that happened. Five runs per mode
      # is what makes this unambiguous in practice.
      assert Stats.median([4, 1, 3, 2]) == 2
    end

    test "every record's stated method is the one the schema names", %{records: records} do
      for {mode, record} <- records do
        assert record["latency_us"]["method"] == "nearest_rank", "#{mode}"
      end
    end
  end

  describe "P3: a correctness assertion that does not hold is a failed run" do
    test "P3 verify/2 answers false when the tally disagrees with what the counters hold" do
      ctx = %{
        mode: :spread,
        short_id: "p3test#{System.unique_integer([:positive])}",
        procs: 2,
        per: 10,
        period: ~U[2026-07-01 00:00:00Z]
      }

      for worker <- 1..2 do
        AuroraMeter.Counter.warm({Modes.tenant(ctx, worker), Modes.feature(), ctx.period})
      end

      honest = %{operations: 0, warmup_operations: 0, errors: %{total: 0, by_tag: %{}}}
      inflated = %{honest | operations: 1_000}

      assert {true, _notes} = Modes.verify(ctx, honest)
      assert {false, notes} = Modes.verify(ctx, inflated)

      assert Enum.any?(notes, &String.contains?(&1, "expected 1000")),
             "a failed check has to say what it compared, or the JSON cannot be diagnosed " <>
               "without re-running: #{inspect(notes)}"
    end

    # `flush_10k` and `flush_100k` cannot pass on this code, and the reason is a
    # defect in the library rather than in the bench: one flush builds a single
    # `insert_all` with SEVEN bind parameters per counter row, and Postgres's
    # wire protocol takes 65,535, so a batch of more than **9,362** dirty
    # counter keys cannot be sent at all. The flusher then retains it for an
    # idempotent retry for ever. Measured to the key in
    # `docs/evidence/v1/phase-08/08c-flush-limit.md`; filed as **X338**; owned by
    # a later unit, because 08c must not change `Storage.flush_batch/3` (it is
    # what `db_recovery` measures).
    #
    # When X338 is fixed this list is emptied and the rule below covers all
    # eighteen modes. A test that fails the day a bug is fixed is the point:
    # nobody has to remember to come back.
    @expected_failures ~w(flush_10k flush_100k)

    test "P3 every record carries a correct flag, and only the modes X338 explains are false", %{
      records: records
    } do
      for {mode, record} <- records do
        assert is_boolean(record["correct"]), "#{mode}"

        if mode in @expected_failures do
          assert record["correct"] == false,
                 "#{mode} now passes. X338 (a flush of more than 9,362 dirty counter keys " <>
                   "cannot be sent to Postgres) must have been fixed. Remove #{mode} from " <>
                   "@expected_failures so the general rule covers it."

          assert record["errors"]["by_tag"]["flush_failed"] >= 1, "#{mode}"

          assert Enum.any?(record["notes"], &String.contains?(&1, "FAILED")),
                 "#{mode}: a run that could not flush must say so in its notes"
        else
          assert record["correct"] == true,
                 "#{mode}'s committed smoke record says correct: false. Its numbers are not " <>
                   "evidence of anything and it must not be published as a measurement."
        end
      end
    end
  end
end
