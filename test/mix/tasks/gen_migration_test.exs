defmodule Mix.Tasks.AuroraMeter.Gen.MigrationTest do
  @moduledoc """
  What `mix aurora_meter.gen.migration` writes into a host application.

  Two properties the rest of the V1 upgrade rests on, and both are about files
  a human then runs without reading closely:

    * a generated range is pinned at both ends, so the same file applied today
      and next release produces the same schema (`open-findings.md` S1);
    * a version that creates an index `CONCURRENTLY` lands in a file of its
      own, carrying the two attributes without which it cannot run at all
      (`open-findings.md` S2).
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Install.Plan
  alias AuroraMeter.Migration
  alias AuroraMeter.Test.Migrations

  setup do
    path = Path.join(System.tmp_dir!(), "aurora_v1_gen_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    %{path: path}
  end

  describe "pinned ranges" do
    test "an upgrade names both ends of every range it generates", %{path: path} do
      generate(path, from: 7)

      for source <- sources(path) do
        refute source =~ ~r/AuroraMeter\.Migration\.up\(from: \d+\)(?!,)/,
               "an unpinned `up(from: n)` runs to whatever the latest version is on the day " <>
                 "it first applies, so two databases built from the same file end up " <>
                 "different:\n#{source}"

        assert source =~ ~r/AuroraMeter\.Migration\.up\(from: \d+, version: \d+\)/
      end
    end

    test "a fresh install pins the whole range and builds the index in the transaction",
         %{path: path} do
      generate(path, [])

      [source] = sources(path)
      latest = Migration.latest_version()

      assert source =~
               "AuroraMeter.Migration.up(from: 1, version: #{latest}, concurrently: false)"

      assert source =~
               "AuroraMeter.Migration.down(version: #{latest}, to: 1, confirm_data_loss: true)"

      refute source =~ "@disable_ddl_transaction",
             "a fresh install has no rows, so it needs no concurrent index and no separate file"
    end

    test "the generated range covers every version from --from to the latest", %{path: path} do
      generate(path, from: 6)

      covered =
        path
        |> sources()
        |> Enum.flat_map(fn source ->
          ~r/AuroraMeter\.Migration\.up\(from: (\d+), version: (\d+)\)/
          |> Regex.scan(source)
          |> Enum.flat_map(fn [_, from, to] ->
            Enum.to_list(String.to_integer(from)..String.to_integer(to)//1)
          end)
        end)
        |> Enum.sort()

      assert covered == Enum.to_list(6..Migration.latest_version()//1)
    end
  end

  describe "concurrent versions" do
    test "each one gets a file of its own, carrying both attributes", %{path: path} do
      generate(path, from: 7)

      concurrent_files = Enum.filter(files(path), &(Path.basename(&1) =~ "_concurrent"))

      assert length(concurrent_files) == 1,
             "exactly one generated file may carry version 8: " <>
               inspect(Enum.map(files(path), &Path.basename/1))

      ordinary = read_named(path, "v7")
      concurrent = read_named(path, "v8_concurrent")

      assert ordinary =~ "AuroraMeter.Migration.up(from: 7, version: 7)"
      refute ordinary =~ "@disable_ddl_transaction"
      refute ordinary =~ "@disable_migration_lock"

      # The concurrent version is alone in its file. That is the claim, and it
      # is about this file's contents rather than about how many files the run
      # produced, so a later schema version does not falsify it.
      assert concurrent =~ "AuroraMeter.Migration.up(from: 8, version: 8)"
      refute concurrent =~ ~r/up\(from: (?!8)\d+/
      assert concurrent =~ "@disable_ddl_transaction true"
      assert concurrent =~ "@disable_migration_lock true"
    end

    test "the concurrent file's name says so, and it sorts after the one before it",
         %{path: path} do
      generate(path, from: 7)

      names = Enum.map(files(path), &Path.basename/1)

      v7 = Enum.find(names, &(&1 =~ ~r/_upgrade_aurora_meter_v7\.exs$/))
      v8 = Enum.find(names, &(&1 =~ ~r/_upgrade_aurora_meter_v8_concurrent\.exs$/))

      assert v7, "no version 7 file in #{inspect(names)}"
      assert v8, "no version 8 concurrent file in #{inspect(names)}"

      assert v7 < v8,
             "Ecto runs migrations in timestamp order, so version 7's file must sort first"

      # And every later version sorts after the concurrent one, for the same
      # reason: version 8 promotes columns to NOT NULL that a later version's
      # statements may depend on.
      for later <- names -- [v7, v8] do
        assert v8 < later,
               "#{later} must sort after the concurrent version 8 file"
      end
    end

    test "the generated concurrent file is accepted by AuroraMeter.Migration.up/1",
         %{path: path} do
      generate(path, from: 7)

      # The whole point of the separate file: the same call in one file raises.
      assert_raise Migration.ConcurrentVersionError, fn ->
        Migration.up(from: 7, version: 8)
      end

      concurrent = read_named(path, "v8_concurrent")

      assert concurrent =~ "up(from: 8, version: 8)",
             "the generated file must run exactly the version that needs its own transaction"
    end
  end

  describe "validate_checks" do
    test "I19 X428 --no-validate-checks emits the option on the version 8 file and nowhere else",
         %{path: path} do
      # `AuroraMeter.track/4` never rejected a non-positive quantity and never
      # bounded metadata, so a 0.4.x database can hold rows core schema version
      # 8's constraints refuse. `mix aurora_meter.events.backfill` counts them
      # and prints the remedy: run version 8 with `validate_checks: false`.
      # Until 11a the generated file had no way to carry it and the only route
      # from that advice to a working upgrade was to hand-edit a generated
      # migration. Measured in the phase 11 fixture: the upgrade stops at
      # version 8 with a raw Postgres check_violation.
      generate(path, from: 7, validate_checks: false)

      concurrent = read_named(path, "v8_concurrent")

      assert concurrent =~ "up(from: 8, version: 8, validate_checks: false)",
             "the file covering version 8 must be able to carry the remedy the backfill prints"

      for name <- ["v7", "v9_to_v10"] do
        refute read_named(path, name) =~ "validate_checks",
               "#{name} does not run version 8, so the option would name a version its body " <>
                 "never reaches: an option in a host's committed file that nothing reads"
      end
    end

    test "I19 X428 without the flag nothing is emitted, so the default stands", %{path: path} do
      generate(path, from: 7)

      for name <- ["v7", "v8_concurrent", "v9_to_v10"] do
        refute read_named(path, name) =~ "validate_checks",
               "a host that never needed the escape must not find it in its migration"
      end
    end

    test "I19 X428 the emitted option is one AuroraMeter.Migration.up/1 actually accepts" do
      # The option is only a remedy if the runtime reads it. Asserting the
      # string alone would pass just as well for a misspelling.
      [file] =
        Plan.files(package: :core, from: 8, validate_checks: false)
        |> Enum.filter(&(&1.range.from == 8))

      assert file.up =~ "validate_checks: false"

      {call, _bindings} = Code.eval_string("quote do: #{file.up}")
      {{:., _, [_module, :up]}, _, [options]} = call
      assert Keyword.fetch!(options, :validate_checks) == false
      assert Keyword.fetch!(options, :from) == 8
      assert Keyword.fetch!(options, :version) == 8
    end
  end

  describe "data loss" do
    test "a range holding a destructive version generates a down that confirms it",
         %{path: path} do
      generate(path, from: 7)

      ordinary = read_named(path, "v7")
      concurrent = read_named(path, "v8_concurrent")

      assert 7 in Migration.data_loss_versions()

      assert ordinary =~
               "AuroraMeter.Migration.down(version: 7, to: 7, confirm_data_loss: true)",
             "version 7's down removes caller identity, so a generated rollback must say so"

      # This assertion used to be its inverse, on the reading that version 8's
      # down "drops an index and loses no fact". `schema-migration-map.md`
      # section 3 is binding, names version 8, and gives the reason: the index
      # is the identity guarantee, so dropping it is losing the guarantee
      # (`open-findings.md` X362). The generated concurrent file is the one
      # place a host would ever see it.
      assert 8 in Migration.data_loss_versions()

      assert concurrent =~
               "AuroraMeter.Migration.down(version: 8, to: 8, confirm_data_loss: true)",
             "version 8's down drops the unique index on (tenant_key, event_id), after " <>
               "which two rows may claim to be the same fact"
    end

    test "the flag tracks data_loss_versions/0 on every range the generator can emit" do
      destructive = Migration.data_loss_versions()
      refute Enum.empty?(destructive), "an empty list makes this test vacuous"

      needed =
        for from <- 1..Migration.latest_version(),
            file <- Plan.files(package: :core, from: from) do
          needed? = Enum.any?(file.range.from..file.range.to//1, &(&1 in destructive))

          assert file.down =~ "confirm_data_loss: true" == needed?,
                 "--from #{from} produced #{file.suffix} covering " <>
                   "#{file.range.from}..#{file.range.to}, whose down is:\n  #{file.down}"

          needed?
        end

      # **`needed?` is constant here, and saying so is the point.** With the
      # corrected list (1, 3, 4, 7, 8, 9, 10) only versions 2, 5 and 6 are
      # non-destructive, and no contiguous range the splitter can produce
      # consists only of those: every `--from` reaches 7. So this test proves
      # the flag is never *missing* and proves nothing about it being wrongly
      # *present*; an implementation that emitted it unconditionally would pass.
      # The false branch is exercised where it can be: `migration_test.exs`
      # drives `down/1` over version 5 on its own and asserts no refusal.
      # X360's lesson, applied to a check rather than a generator: ask which
      # field is constant in every case, and write down the answer.
      assert Enum.uniq(needed) == [true],
             "a range with no destructive version is now reachable; give this test its " <>
               "negative case rather than leaving the comment above standing"
    end
  end

  test "it refuses a --from above the latest version", %{path: path} do
    assert_raise Mix.Error, ~r/above the latest/, fn ->
      generate(path, from: Migration.latest_version() + 1)
    end
  end

  # X432, closed by build unit 11b. `docs/upgrading-to-1.0.md` has told the
  # operator to run `--upgrade` since 03a wrote it, and until this unit the
  # flag did not exist: the documented first step of the V1 upgrade was
  # `** (Mix) Could not find migrations`. The marker it reads is core's
  # `"schema:core"`, written since version 7, and Pro's `"schema:pro"`, which
  # nothing wrote until this unit either.
  describe "I19 X432 --upgrade reads the installed version" do
    @describetag :migration

    test "it detects the version from the marker and starts at the next one" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        assert Plan.detect_from(:core, repo) == {:ok, 8}
      end)
    end

    test "it reports up to date when the database is on the latest version" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo,
          from: 1,
          version: Migration.latest_version(),
          concurrently: false
        )

        assert Plan.detect_from(:core, repo) == :up_to_date
      end)
    end

    test "it refuses rather than guessing when the checkpoints table is not there" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)

        error = assert_raise(Mix.Error, fn -> Plan.detect_from(:core, repo) end)

        assert error.message =~ "aurora_meter_checkpoints table does not exist"
        assert error.message =~ "--from"
        assert error.message =~ "`--from 7`"

        # The half that matters: "no marker" is not "version 0". A generator
        # that guessed low would re-run every version this database already has.
        refute error.message =~ "version 0"
      end)
    end

    test "it refuses rather than guessing when the table is there and the row is not" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        repo.query!("DELETE FROM aurora_meter_checkpoints WHERE name = 'schema:core'", [])

        error = assert_raise(Mix.Error, fn -> Plan.detect_from(:core, repo) end)

        assert error.message =~ "no \"schema:core\" row"
        assert error.message =~ "--from"
      end)
    end

    test "it refuses when a migration in the repository already covers the range" do
      error =
        assert_raise(Mix.Error, fn ->
          Plan.refuse_existing!(:core, "priv/test_repo/migrations", 7..10//1)
        end)

      assert error.message =~ "already runs Aurora Meter"
      assert error.message =~ ".exs"
    end

    test "it allows a range no migration in the repository covers" do
      # The negative control: a guard that refused every range would satisfy
      # the test above and make the flag unusable.
      assert Plan.refuse_existing!(:core, "priv/test_repo/migrations", 99..99//1) == :ok
    end

    test "--upgrade and --from together are refused", %{path: path} do
      error =
        assert_raise(Mix.Error, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            Mix.Tasks.AuroraMeter.Gen.Migration.run([
              "-r",
              "AuroraMeter.TestRepo",
              "--upgrade",
              "--from",
              "7"
            ])
          end)
        end)

      assert error.message =~ "--upgrade and --from"
      assert Path.wildcard(Path.join(path, "*.exs")) == []
    end

    test "the upgrade guide's own command is the one the task accepts" do
      # The documentation defect X432 is about, checked from the other end: the
      # guide tells the operator to run this exact line.
      guide = File.read!("docs/upgrading-to-1.0.md")

      assert guide =~ "mix aurora_meter.gen.migration --upgrade -r MyApp.Repo"

      {parsed, _rest, invalid} =
        OptionParser.parse(["--upgrade", "-r", "MyApp.Repo"],
          switches: [from: :integer, validate_checks: :boolean, upgrade: :boolean],
          aliases: [r: :repo]
        )

      assert invalid == []
      assert parsed[:upgrade] == true
    end
  end

  # The task writes into the repo's own migrations path, which here is the
  # repository's committed `priv/test_repo/migrations`. Whatever appears there
  # that was not there before is moved into this test's own directory, so the
  # generated files can be read and the committed ones are left untouched.
  # X97: the move is asserted, not assumed, so a test that failed to clean up
  # cannot quietly leave a migration behind for the next `mix test.setup`.
  defp generate(path, opts) do
    before = listing()

    try do
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.AuroraMeter.Gen.Migration.run(["-r", "AuroraMeter.TestRepo"] ++ switches(opts))
      end)
    after
      for file <- listing() -- before do
        File.rename!(file, Path.join(path, Path.basename(file)))
      end

      assert listing() == before,
             "the generator left files in priv/test_repo/migrations that this test did not " <>
               "move out: #{inspect(listing() -- before)}"
    end
  end

  defp listing, do: "priv/test_repo/migrations/*.exs" |> Path.wildcard() |> Enum.sort()

  defp switches(opts) do
    from =
      case Keyword.fetch(opts, :from) do
        {:ok, from} -> ["--from", to_string(from)]
        :error -> []
      end

    validate =
      case Keyword.fetch(opts, :validate_checks) do
        {:ok, false} -> ["--no-validate-checks"]
        {:ok, true} -> ["--validate-checks"]
        :error -> []
      end

    from ++ validate
  end

  defp files(path), do: path |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

  # Selects a generated file by the version its name carries rather than by its
  # position in the listing, so adding a schema version does not break a test
  # about a different one.
  defp read_named(path, suffix) do
    case Enum.filter(files(path), &(Path.basename(&1) =~ "_upgrade_aurora_meter_#{suffix}.exs")) do
      [file] ->
        File.read!(file)

      other ->
        flunk(
          "expected exactly one generated file for #{suffix}, got " <>
            inspect(Enum.map(other, &Path.basename/1)) <>
            " out of " <> inspect(Enum.map(files(path), &Path.basename/1))
        )
    end
  end

  defp sources(path), do: path |> files() |> Enum.map(&File.read!/1)
end
