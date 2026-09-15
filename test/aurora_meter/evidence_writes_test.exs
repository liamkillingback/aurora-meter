defmodule AuroraMeter.EvidenceWritesTest do
  @moduledoc """
  A test that writes a committed file on every run is a test that rewrites its
  own evidence.

  Two things go wrong when it does. The gate stops leaving the working tree byte
  identical, which is the property `mix docs --output` was added to protect
  (`open-findings.md` X21 and X27). And a reviewer can no longer tell whether a
  committed evidence file came from the run its report cites, which is most of
  what committed evidence is for. That is not hypothetical: build unit 03d
  reported one set of replay digests, the committed file held another, and the
  difference was the reviewer's own verification run silently overwriting them
  (X135).

  X135 was closed by gating one writer. X149 then found a second, missed because
  it names its path inline rather than through the `@evidence` module attribute
  the others use, so a grep for the constant did not see it. This file exists
  because a rule nothing enforces is one already being broken (X153).

  The rule: a test **asserts every time and records only when asked**.
  """
  use ExUnit.Case, async: true

  @test_root Path.expand("../..", __DIR__)

  # Every test file that writes into a committed evidence directory, and the
  # environment variable that gates it. A new entry here is a deliberate act:
  # the test below fails until the list matches what is on disk, so a writer
  # cannot be added by accident.
  @writers %{
    "test/aurora_meter/events_replay_large_test.exs" => "AURORA_EVIDENCE",
    "test/aurora_meter/events_replay_test.exs" => "AURORA_EVIDENCE",
    "test/aurora_meter/feature_source_evidence_test.exs" => "AURORA_EVIDENCE",
    "test/aurora_meter/correct_concurrency_test.exs" => "AURORA_BOUND_REPORT",
    "test/aurora_meter/record_concurrency_test.exs" => "AURORA_CONCURRENCY_REPORT"
  }

  defp test_files do
    Path.wildcard(Path.join(@test_root, "test/**/*.exs")) ++
      Path.wildcard(Path.join(@test_root, "test/**/*.ex"))
  end

  defp relative(path), do: Path.relative_to(path, @test_root)

  # This file names the path and the function in its own documentation, so it
  # matches its own scan. Excluding it by name is deliberate and is the only
  # exclusion: anything else that matches is a real writer.
  @self "test/aurora_meter/evidence_writes_test.exs"

  defp writes_evidence?(source) do
    String.contains?(source, "docs/evidence") and
      (String.contains?(source, "File.write!") or String.contains?(source, "File.write("))
  end

  test "every test that writes into docs/evidence is gated, and the list is exact" do
    found =
      test_files()
      |> Enum.filter(&writes_evidence?(File.read!(&1)))
      |> Enum.map(&relative/1)
      |> Enum.reject(&(&1 == @self))
      |> Enum.sort()

    expected = @writers |> Map.keys() |> Enum.sort()

    assert found == expected, """
    The set of tests writing into docs/evidence has changed.

    on disk : #{inspect(found)}
    expected: #{inspect(expected)}

    A test that writes a committed file on every run rewrites its own evidence
    (open-findings.md X135, X149). If this is a new writer, gate it behind an
    environment variable and add it to @writers with that variable's name. If a
    writer was removed, remove its entry.
    """
  end

  test "each writer checks its environment variable before writing" do
    for {file, var} <- @writers do
      source = File.read!(Path.join(@test_root, file))

      assert String.contains?(source, ~s|System.get_env("#{var}")|),
             "#{file} writes into docs/evidence but never reads #{var}. " <>
               "It must assert every time and record only when asked."
    end
  end

  test "no writer reaches outside its own package" do
    for {file, _var} <- @writers do
      source = File.read!(Path.join(@test_root, file))

      refute source =~ ~r{\.\./\.\./(?:product-workspaces|docs)},
             "#{file} writes outside this package. Evidence belongs to the " <>
               "repository that produced it."
    end
  end
end
