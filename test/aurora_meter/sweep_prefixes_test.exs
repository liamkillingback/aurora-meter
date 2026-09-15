defmodule AuroraMeter.SweepPrefixesTest do
  @moduledoc """
  The start-of-suite sweep must name every prefix a non-sandbox test uses.

  A non-sandbox test commits real rows on a real connection, and an interrupted
  run reaches no `on_exit`, so the rows survive into the next run
  (`open-findings.md` X109). `test_helper.exs` sweeps them by prefix before
  `ExUnit.start/0`, and the sweep deletes only what those prefixes name, because
  a sweep that reaches further deletes rows a concurrent run created (X38).

  That list was maintained by hand and drifted: build unit 05a added its own
  prefix and correctly did not touch anyone else's, which left **05b's
  `reconcile` and 03d's `replaybig` unswept** and nothing said so (X191). Pro has
  had a test of this shape since 04a; core did not, which is why core is the one
  that drifted. A rule nothing enforces is one already being broken (X153).

  This asserts the direction that matters for contamination: **every prefix a
  non-sandbox test uses is swept.** The reverse is deliberately not asserted,
  because a prefix may be swept for something that is not a test module: `probe`
  belongs to a script 03b left behind (X130), and removing it would let those
  rows accumulate again.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @helper "test/test_helper.exs"

  defp non_sandbox_files do
    @root
    |> Path.join("test/aurora_meter/*.exs")
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ "Test.Connections"))
  end

  defp prefixes_in(source) do
    ~r/(?:unique_tenant|register_prefix)\("([a-z_]+)"\)/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp swept do
    source = File.read!(Path.join(@root, @helper))

    [[_, body]] = Regex.scan(~r/sweep!\(~w\(([^)]*)\)\)/s, source)

    body |> String.split() |> MapSet.new()
  end

  test "every prefix a non-sandbox test uses is swept at suite start" do
    swept = swept()

    used =
      non_sandbox_files()
      |> Enum.flat_map(fn file ->
        file |> File.read!() |> prefixes_in() |> Enum.map(&{&1, Path.basename(file)})
      end)

    missing =
      used
      |> Enum.reject(fn {prefix, _file} -> MapSet.member?(swept, prefix) end)
      |> Enum.uniq()

    assert missing == [], """
    These prefixes are used by a non-sandbox test and are not swept at suite start:

    #{Enum.map_join(missing, "\n", fn {p, f} -> "  #{p}  (#{f})" end)}

    A non-sandbox test commits real rows, and an interrupted run reaches no
    on_exit, so they survive into the next run and can be read as this run's
    (open-findings.md X109, X167). Add the prefix to the sweep! list in
    #{@helper}.
    """
  end

  test "the sweep list is not empty and every entry is long enough to be distinctive" do
    swept = swept()

    refute Enum.empty?(swept), "the sweep list is empty, so nothing is cleaned"

    short = Enum.filter(swept, &(String.length(&1) < 4))

    assert short == [],
           "these swept prefixes are shorter than four characters and would " <>
             "match rows a concurrent run created (X38): #{inspect(short)}"
  end

  test "at least one non-sandbox file was found, so this test cannot pass vacuously" do
    files = non_sandbox_files()

    assert length(files) >= 10,
           "only #{length(files)} non-sandbox files were found, which suggests the " <>
             "detection is wrong rather than that the suite shrank"
  end
end
