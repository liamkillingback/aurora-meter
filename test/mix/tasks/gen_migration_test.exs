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

  alias AuroraMeter.Migration

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

      files = files(path)

      assert length(files) == 2,
             "versions 7 and 8 cannot share a file: #{inspect(Enum.map(files, &Path.basename/1))}"

      [ordinary, concurrent] = Enum.map(files, &File.read!/1)

      assert ordinary =~ "AuroraMeter.Migration.up(from: 7, version: 7)"
      refute ordinary =~ "@disable_ddl_transaction"
      refute ordinary =~ "@disable_migration_lock"

      assert concurrent =~ "AuroraMeter.Migration.up(from: 8, version: 8)"
      assert concurrent =~ "@disable_ddl_transaction true"
      assert concurrent =~ "@disable_migration_lock true"
    end

    test "the concurrent file's name says so, and it sorts after the one before it",
         %{path: path} do
      generate(path, from: 7)

      names = Enum.map(files(path), &Path.basename/1)

      assert [v7, v8] = names
      assert v7 =~ ~r/_upgrade_aurora_meter_v7\.exs$/
      assert v8 =~ ~r/_upgrade_aurora_meter_v8_concurrent\.exs$/

      assert v7 < v8,
             "Ecto runs migrations in timestamp order, so version 7's file must sort first"
    end

    test "the generated concurrent file is accepted by AuroraMeter.Migration.up/1",
         %{path: path} do
      generate(path, from: 7)

      # The whole point of the separate file: the same call in one file raises.
      assert_raise Migration.ConcurrentVersionError, fn ->
        Migration.up(from: 7, version: 8)
      end

      [_v7, concurrent] = Enum.map(files(path), &File.read!/1)

      assert concurrent =~ "up(from: 8, version: 8)",
             "the generated file must run exactly the version that needs its own transaction"
    end
  end

  describe "data loss" do
    test "a range holding a destructive version generates a down that confirms it",
         %{path: path} do
      generate(path, from: 7)

      [ordinary, concurrent] = Enum.map(files(path), &File.read!/1)

      assert 7 in Migration.data_loss_versions()

      assert ordinary =~
               "AuroraMeter.Migration.down(version: 7, to: 7, confirm_data_loss: true)",
             "version 7's down removes caller identity, so a generated rollback must say so"

      refute concurrent =~ "confirm_data_loss",
             "version 8's down drops an index and loses no fact, so it needs no confirmation"
    end
  end

  test "it refuses a --from above the latest version", %{path: path} do
    assert_raise Mix.Error, ~r/above the latest/, fn ->
      generate(path, from: Migration.latest_version() + 1)
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
    case Keyword.fetch(opts, :from) do
      {:ok, from} -> ["--from", to_string(from)]
      :error -> []
    end
  end

  defp files(path), do: path |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort()

  defp sources(path), do: path |> files() |> Enum.map(&File.read!/1)
end
