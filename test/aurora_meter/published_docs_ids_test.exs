defmodule AuroraMeter.PublishedDocsIdsTest do
  @moduledoc """
  The text a reader sees on HexDocs carries no internal programme references.

  The 1.0 build was organised as a programme with finding ids (`X123`), decision
  ids (`D11`), review ids (`CORE-05`), unit ids (`02d`) and evidence files that
  live outside the package. None of them means anything to a reader of the
  published documentation, and a dead `docs/evidence/...` path reads as a broken
  promise. This scans every HexDocs extra, `usage-rules.md` and every published
  `@moduledoc`, `@doc` and `@typedoc`, and fails naming each file and match.

  Invariant ids (`I17`) and guarantee rows (`G4`) are public vocabulary,
  defined on the published pages, and are not matched.
  """
  use ExUnit.Case, async: true

  @pattern ~r/\bX\d{2,3}\b|\b[A-Z]{2,5}-\d{2}\b|\bD\d{2}\b|\b(?:0\d|1[0-3])[a-f]\b|V1 programme|[Bb]uild units?\b|[Rr]epair units?\b|open-findings|docs\/evidence|v1-release|\bR\d{1,2}\b|\bL\d{2}(?:\.\d+|[a-z]-\d+)|\bL-\d{2}[a-z]-\d+/

  test "no HexDocs extra or usage-rules.md names an internal programme id or evidence path" do
    files = Mix.Project.config()[:docs][:extras] ++ ["usage-rules.md"]

    assert length(files) > 20, "the extras list could not be read, so this scan is vacuous"

    hits =
      for file <- files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          [match | _] <- Regex.scan(@pattern, without_tagged_source_links(line)),
          do: "#{file}:#{number}: #{match}"

    assert hits == [], "internal references in published docs:\n" <> Enum.join(hits, "\n")
  end

  test "no published doc string names an internal programme id or evidence path" do
    {:ok, modules} = :application.get_key(:aurora_meter, :modules)

    published = Enum.filter(modules, &from_lib?/1)
    assert length(published) > 50, "too few modules were read, so this scan is vacuous"

    hits =
      for module <- published,
          {where, text} <- published_docs(module),
          [match | _] <- Regex.scan(@pattern, text),
          do: "#{inspect(module)} #{where}: #{match}"

    assert hits == [], "internal references in published doc strings:\n" <> Enum.join(hits, "\n")
  end

  test "the pattern matches each kind of reference it is meant to block, and not the public ids" do
    for sample <- [
          "finding X384",
          "decision D11",
          "review CORE-05",
          "fresh install FI-03",
          "unit 02d",
          "phase 11e",
          "the V1 programme",
          "build unit 06c",
          "repair unit R5",
          "`open-findings.md`",
          "docs/evidence/v1/phase-01/i01.md",
          "v1-release.md",
          "L17.4",
          "L09a-2",
          "L-03a-3"
        ] do
      assert Regex.match?(@pattern, sample), "the scan misses #{inspect(sample)}"
    end

    for public <- ["invariant I17", "guarantee G14", "SHA-256", "UTF-8", "ISO 4217", "1.0.1"] do
      refute Regex.match?(@pattern, public), "the scan would block #{inspect(public)}"
    end
  end

  # A link into the source repository at a release tag is a reader's way to the
  # raw record, and it resolves; only a bare path that leads nowhere is blocked.
  defp without_tagged_source_links(line) do
    String.replace(line, ~r{https://github\.com/liamkillingback/aurora-meter/blob/v[^\s)]*}, "")
  end

  defp from_lib?(module) do
    source = module.module_info(:compile)[:source]
    is_list(source) and String.contains?(List.to_string(source), "/lib/")
  end

  defp published_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, module_doc, _, docs} when module_doc != :hidden ->
        moduledoc = if is_map(module_doc), do: [{"moduledoc", module_doc["en"]}], else: []

        moduledoc ++
          for {{kind, name, arity}, _, _, doc, _} <- docs,
              is_map(doc),
              do: {"#{kind} #{name}/#{arity}", doc["en"]}

      _hidden_or_none ->
        []
    end
  end
end
