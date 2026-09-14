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

  alias AuroraMeter.Migration

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

  defp pinned_ranges(source) do
    ~r/AuroraMeter\.Migration\.up\(from: (\d+), version: (\d+)\)/
    |> Regex.scan(source)
    |> Enum.flat_map(fn [_, from, to] ->
      Enum.to_list(String.to_integer(from)..String.to_integer(to))
    end)
  end
end
