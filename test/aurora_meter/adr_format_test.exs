defmodule AuroraMeter.ADRFormatTest do
  # Build unit 00c. Mechanical guards for the decision records: numbering,
  # the heading and status convention, the five V1 sections, and the
  # repository style rule that forbids the long and short dash characters.
  # No database, no network: these read files from the package root.
  use ExUnit.Case, async: true

  @adr_dir "docs/adr"
  @v1_first 9
  @v1_last 16
  @template "docs/evidence/v1/TEMPLATE.md"
  @evidence_readme "docs/evidence/README.md"
  # Built from codepoints so this file stays free of the characters it forbids.
  @long_dash <<0x2014::utf8>>
  @short_dash <<0x2013::utf8>>
  @sections ["Context", "Decision", "Consequences", "Migration impact", "Verification"]

  defp adr_files do
    @adr_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp number(path) do
    path
    |> Path.basename()
    |> String.slice(0, 4)
    |> String.to_integer()
  end

  defp v1_files, do: Enum.filter(adr_files(), &(number(&1) >= @v1_first))

  defp section(body, name) do
    regex = ~r/^## #{Regex.escape(name)}\s*\n(.*?)(?=\n## |\z)/ms

    case Regex.run(regex, body, capture: :all_but_first) do
      [text] -> text
      nil -> nil
    end
  end

  test "00c ADR numbers are unique and contiguous from 0001" do
    numbers = Enum.map(adr_files(), &number/1)
    duplicates = numbers -- Enum.uniq(numbers)

    assert duplicates == [], "duplicate ADR number #{inspect(duplicates)}"
    assert Enum.sort(numbers) == Enum.to_list(1..Enum.max(numbers))
  end

  test "00c every ADR from 0007 onward uses the ADR heading and status convention" do
    for path <- adr_files(), number(path) >= 7 do
      [first | rest] = path |> File.read!() |> String.split("\n")

      assert first =~ ~r/^# ADR \d{4}: \S/,
             "#{path}: line 1 must read '# ADR NNNN: <title>'"

      assert Enum.any?(Enum.take(rest, 4), &(&1 =~ ~r/^Status: /)),
             "#{path}: no 'Status: ' line within the first five lines"
    end
  end

  test "00c every V1 ADR (0009 to 0016) has Context, Decision, Consequences, Migration impact and Verification sections" do
    files = v1_files()

    assert Enum.map(files, &number/1) == Enum.to_list(@v1_first..@v1_last)

    for path <- files, name <- @sections do
      assert section(File.read!(path), name), "#{path}: missing '## #{name}'"
    end
  end

  test "00c every V1 ADR names a schema step or None under Migration impact" do
    for path <- v1_files() do
      body = section(File.read!(path), "Migration impact")

      assert body =~ ~r/\bS[1-8]\b|\bNone\b/,
             "#{path}: 'Migration impact' names no schema step S1 to S8 and does not say None"
    end
  end

  test "00c every V1 ADR names at least one build unit under Verification" do
    for path <- v1_files() do
      body = section(File.read!(path), "Verification")

      assert body =~ ~r/\b\d{2}[a-f]\b/,
             "#{path}: 'Verification' names no build unit id"
    end
  end

  test "00c V1 ADRs and the V1 evidence template contain no long or short dash" do
    for path <- v1_files() ++ [@template, @evidence_readme], dash <- [@long_dash, @short_dash] do
      refute String.contains?(File.read!(path), dash),
             "#{path}: contains #{inspect(dash)}; use a comma, colon, parentheses or a full stop"
    end
  end

  test "00c the evidence template carries all seven sections from the plan" do
    content = File.read!(@template)

    for n <- 1..7 do
      assert content =~ ~r/^## #{n}\. /m, "#{@template}: missing section #{n}"
    end
  end

  test "00c plan.md points at the V1 programme" do
    plan = File.read!("plan.md")

    assert plan =~ "docs/v1/build-plans"
    assert plan =~ "Current programme"
  end
end
