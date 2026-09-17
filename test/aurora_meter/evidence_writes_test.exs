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

  ## Why it reads the AST

  The first version of this file asked whether the source **text** contained
  both `docs/evidence` and a `File.write` call, which is the trap X84 records in
  a different guard: a mention in a doc string satisfies a textual search. Build
  unit 10a's house style guard names both in its own moduledoc, while writing
  nothing anywhere, and was reported as a writer on the first full run after it
  landed.

  So the question is asked of the parsed module, and it is asked about the
  **destination** rather than the spelling: is there a **call** to
  `File.write!/2` or `File.write/2,3`, and does the module confine its writes to
  `System.tmp_dir!()`. Two of the five gated writers name no path at all (they
  take one from an environment variable) and were caught by the old check only
  because they mention the directory in a comment, and one unrelated test
  carries a comment saying it assembles a directory name from parts so that the
  old check would not see it. Both of those are the rule being in the wrong
  place. `the parser itself` below holds one file of each kind as a permanent
  control.
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
    "test/aurora_meter/record_concurrency_test.exs" => "AURORA_CONCURRENCY_REPORT",
    # Both of these were invisible to the textual version of this check: they
    # write committed files and name `docs/evidence` nowhere. Found when the
    # check moved onto the destination rather than the spelling (build unit
    # 10a). `ledger_commands.ex` has a second, deliberate writer beside the
    # gated one: a failing property saves its counterexample into
    # `test/regressions/seeds`, which is the mechanism build unit 01e's rule
    # protects, and it is gated by the property failing rather than by a
    # variable.
    "test/support/aurora_meter/test/connections.ex" => "AURORA_FAULT_REPORT",
    "test/support/aurora_meter/test/ledger_commands.ex" => "AURORA_LEAK_REPORT"
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

  @control "test/aurora_meter/house_style_test.exs"
  @scratch "test/aurora_meter/telemetry_contract_test.exs"

  defp writes_evidence?(source) do
    ast = Code.string_to_quoted!(source)
    calls_file_write?(ast) and not writes_to_scratch?(ast)
  end

  # A test that writes into `System.tmp_dir!()` cannot rewrite committed
  # evidence, so it needs no gate. Anything else that writes does.
  defp writes_to_scratch?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:System]}, :tmp_dir!]}, _, _} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp calls_file_write?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:File]}, name]}, _, _args} = node, _acc
        when name in [:write!, :write] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
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

  test "the parser itself: a file that names both and writes neither is not a writer" do
    # A permanent control rather than a remembered one. This file exists in the
    # suite, its moduledoc names `docs/evidence` and `File.write!` in the same
    # paragraph, and it writes nothing. A textual detector reports it; a parser
    # must not, and if somebody rewrites that moduledoc the assertions below
    # fail rather than quietly stopping to control anything.
    source = File.read!(Path.join(@test_root, @control))

    assert String.contains?(source, "docs/evidence"),
           "#{@control} no longer names docs/evidence, so it controls nothing"

    assert String.contains?(source, "File.write!"),
           "#{@control} no longer names File.write!, so it controls nothing"

    refute writes_evidence?(source),
           "#{@control} was reported as an evidence writer. It names both in prose " <>
             "and calls neither, which is precisely the case the parser exists for."
  end

  test "the parser itself: a real write is still found" do
    assert writes_evidence?("""
           defmodule X do
             def go, do: File.write!("docs/evidence/v1/x.md", "hi")
           end
           """)

    # The path may be assembled at run time and never appear as a literal, which
    # is what two of the five writers do. The destination is what is checked, not
    # the spelling.
    assert writes_evidence?("""
           defmodule X do
             def go, do: File.write!(System.get_env("REPORT"), "hi", [:append])
           end
           """)

    refute writes_evidence?("""
           defmodule X do
             @moduledoc "mentions docs/evidence and File.write! and does neither"
             def go, do: :ok
           end
           """)

    refute writes_evidence?("""
           defmodule X do
             def go do
               dir = Path.join(System.tmp_dir!(), "x")
               File.write!(Path.join(dir, "fixture.ex"), "hi")
             end
           end
           """)
  end

  test "the parser itself: a scratch writer is not a writer" do
    # The second permanent control, and the one that records why the rule moved.
    # This file writes a fixture on every run, into `System.tmp_dir!()`, and its
    # own comment says it assembles the directory name from parts so that this
    # check would not see it. A guard people route around is a guard in the
    # wrong place.
    source = File.read!(Path.join(@test_root, @scratch))

    assert String.contains?(source, "File.write!"),
           "#{@scratch} no longer writes anything, so it controls nothing"

    assert String.contains?(source, "System.tmp_dir!"),
           "#{@scratch} no longer writes to a scratch directory, so it controls nothing"

    refute writes_evidence?(source),
           "#{@scratch} writes only into System.tmp_dir!() and needs no gate"
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
