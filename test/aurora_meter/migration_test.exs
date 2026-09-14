defmodule AuroraMeter.MigrationTest do
  @moduledoc """
  The migration module's own bookkeeping: that every version it claims has a
  module, that the moduledoc lists them all, and that the test database is
  migrated through every one of them.

  All three have drifted before. The doctest beside `latest_version/0` said 3
  while `@latest` said 4 and nothing ran it; once that was fixed the version
  list two lines above it went stale the same way; and version 5 shipped with
  no migration for the test database, so the suite ran without the index it
  adds.
  """
  use ExUnit.Case, async: true

  # `mix v1.migrations` (an alias in mix.exs) runs every module tagged :migration,
  # and CI runs it as its own job. The tag is NOT excluded in
  # test/test_helper.exs, so this module also runs inside the ordinary `mix test`.
  @moduletag :migration

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Migration
  alias AuroraMeter.Test.Connections

  @sources "priv/test_repo/migrations/*.exs"

  defp latest, do: Migration.latest_version()

  test "every version up to the latest has a module, and none beyond it" do
    for version <- 1..latest() do
      assert Code.ensure_loaded?(Module.concat(Migration, "V#{version}")),
             "AuroraMeter.Migration.V#{version} is missing"
    end

    refute Code.ensure_loaded?(Module.concat(Migration, "V#{latest() + 1}"))
  end

  test "the moduledoc describes every version" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Migration)

    documented =
      ~r/^\s+\* \*\*(\d+)\*\*/m
      |> Regex.scan(doc)
      |> Enum.map(fn [_, number] -> String.to_integer(number) end)

    assert documented == Enum.to_list(1..latest())
  end

  test "the test database is migrated through every version" do
    sources = @sources |> Path.wildcard() |> Enum.map(&File.read!/1)
    assert sources != []

    for source <- sources do
      refute source =~ ~r/AuroraMeter\.Migration\.up\(from: \d+\)/,
             "an unpinned `up(from: n)` runs to whatever the latest version " <>
               "is on the day it first applies, so two databases built from " <>
               "the same migrations end up with different schemas"
    end

    covered =
      sources
      |> Enum.flat_map(&pinned_ranges/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert covered == Enum.to_list(1..latest())
  end

  test "a concurrent version is generated into a file of its own, with both attributes" do
    concurrent = Migration.concurrent_versions()

    refute Enum.empty?(concurrent),
           "no version is marked concurrent, so this guard has rotted away"

    for version <- concurrent do
      [path] = Path.wildcard("priv/test_repo/migrations/*_v#{version}_concurrent.exs")
      source = File.read!(path)

      assert source =~ "@disable_ddl_transaction true",
             "#{path} runs core schema version #{version}, which creates an index " <>
               "CONCURRENTLY, and Postgres refuses that inside a transaction block"

      assert source =~ "@disable_migration_lock true",
             "#{path} must also release the Ecto migration lock, which is itself held " <>
               "inside a transaction"

      assert source =~ "AuroraMeter.Migration.up(from: #{version}, version: #{version})",
             "#{path} must run exactly version #{version} and nothing else"

      others =
        Enum.reject(pinned_ranges(source), &(&1 == version))

      assert others == [],
             "#{path} also runs #{inspect(others)}. A concurrent version shares a file " <>
               "with nothing"
    end
  end

  describe "up/1 and down/1 guards" do
    test "up/1 refuses to run a concurrent version alongside another version" do
      assert_raise Migration.ConcurrentVersionError, fn ->
        Migration.up(from: 7, version: 8)
      end
    end

    # The negative control for the test above. `concurrently: false` must get
    # PAST the guard; it then fails for an unrelated reason (there is no
    # migration runner here), and the point is precisely that the reason is
    # different. Without this, a guard that raised unconditionally would pass.
    test "up/1 lets the same range through when concurrently: false" do
      error =
        try do
          Migration.up(from: 7, version: 8, concurrently: false)
          nil
        rescue
          error -> error
        end

      refute match?(%Migration.ConcurrentVersionError{}, error),
             "concurrently: false must not be refused by the concurrent-version guard"
    end

    test "up/1 allows a concurrent version on its own" do
      error =
        try do
          Migration.up(from: 8, version: 8)
          nil
        rescue
          error -> error
        end

      refute match?(%Migration.ConcurrentVersionError{}, error),
             "a range of exactly the concurrent version is what its own migration file runs"
    end

    test "down/1 refuses a version whose down destroys a commercial fact" do
      assert_raise Migration.DataLossError, ~r/confirm_data_loss/, fn ->
        Migration.down(version: 7, to: 7)
      end
    end

    test "down/1 lets it through with confirm_data_loss: true" do
      error =
        try do
          Migration.down(version: 7, to: 7, confirm_data_loss: true)
          nil
        rescue
          error -> error
        end

      refute match?(%Migration.DataLossError{}, error),
             "confirm_data_loss: true must not be refused by the data-loss guard"
    end

    test "down/1 of a version that destroys nothing needs no confirmation" do
      error =
        try do
          Migration.down(version: 8, to: 8)
          nil
        rescue
          error -> error
        end

      refute match?(%Migration.DataLossError{}, error),
             "version 8's down drops an index and promotes nothing; it loses no fact"
    end
  end

  # On a real connection, not the sandbox: the marker was written by
  # `mix ecto.migrate` and committed, which is the state 11a's detection reads.
  test "I19 up/1 records the reached version in the checkpoints table" do
    [checkpoint] =
      Connections.run(1, fn _index ->
        Checkpoints.get("schema:core")
      end)

    assert checkpoint, "the schema marker is missing; 11a's --upgrade detection reads it"

    assert checkpoint.cursor["version"] == latest(),
           "the marker says #{inspect(checkpoint.cursor["version"])} and the latest version " <>
             "is #{latest()}"
  end

  defp pinned_ranges(source) do
    ~r/AuroraMeter\.Migration\.up\(from: (\d+), version: (\d+)\)/
    |> Regex.scan(source)
    |> Enum.flat_map(fn [_, from, to] ->
      Enum.to_list(String.to_integer(from)..String.to_integer(to))
    end)
  end
end
