defmodule AuroraMeter.Bench.ClaimsTest do
  @moduledoc """
  Lower-level property **P4**: no document this project publishes quotes a
  throughput figure that this suite did not produce.

  Until build unit 08c, `README.md` carried a figure measured against the 0.3
  four-column counter row, which 0.4.0 replaced, and the task that produced it
  had crashed at its own summary line ever since (`open-findings.md` C7). It was
  on the page a prospective customer reads, and on Hex with every release,
  because `README.md` is inside `package.files`. Nothing could have caught it,
  so this is what catches the next one.

  Scope: **everything**, minus two files. `docs/evidence/phase-03/` is where the
  superseded figures live and stay, because superseding evidence is right and
  deleting it is not, and that page is the clearest surviving explanation of why
  the old number existed. This file is the other exclusion, because it has to
  hold the strings in order to forbid them.

  The scope was narrower once, "the documents that make claims", and the
  narrowing was wrong: this unit's own evidence then quoted two of the figures
  while explaining that they were being retired, which is the most sympathetic
  possible reason to break the rule and still breaks it. The rule is that those
  strings appear nowhere else at all.
  """
  use ExUnit.Case, async: true

  # Every form the superseded figures were quoted in, from
  # docs/evidence/phase-03/bench.md and the documents that copied them.
  @superseded ["5.5M", "5505759", "5,505,759", "7.9M", "7935406", "7,935,406", "53k"]

  @results "docs/evidence/v1/phase-08/08c-results.md"

  # This file names every forbidden string in order to forbid it, so it is
  # excluded by name. It is the only exclusion besides the historical page, and
  # naming it here is deliberate: an exclusion list that grows is a rule on its
  # way out.
  @self "test/aurora_meter/bench/claims_test.exs"

  describe "P4: the superseded figures are gone from every claim" do
    test "P4 the superseded throughput figures appear nowhere outside docs/evidence/phase-03" do
      offenders =
        for path <- claim_documents(),
            figure <- @superseded,
            String.contains?(File.read!(path), figure),
            do: {path, figure}

      assert offenders == [],
             "a superseded throughput figure is still being published: #{inspect(offenders)}. " <>
               "Those numbers were measured against the 0.3 four-column counter row that " <>
               "0.4.0 replaced, by a task that then crashed printing them. Every published " <>
               "figure must come from #{@results}."
    end

    test "the claim scan examined the files it was meant to examine" do
      # A guard that silently examined nothing would pass for ever. The count is
      # asserted before it is used (open-findings.md X324, X325).
      documents = claim_documents()

      assert length(documents) > 200,
             "the claim scan found only #{length(documents)} files, which is fewer than " <>
               "this repository has. An empty or shrunken selection is a failure, not a pass."

      assert "README.md" in documents
      assert "docs/launch/gtm.md" in documents
      assert "lib/aurora_meter/counter.ex" in documents
      assert "docs/evidence/v1/phase-08/08c-results.md" in documents

      refute Enum.any?(documents, &String.starts_with?(&1, "docs/evidence/phase-03/"))
      refute @self in documents
    end
  end

  describe "P4: every published figure links its evidence" do
    test "P4 the README throughput table links a docs/evidence/v1/phase-08 artifact" do
      readme = File.read!("README.md")

      assert readme =~ "docs/evidence/v1/phase-08/08c-results.md",
             "README.md's throughput table must link #{@results}, which is the single " <>
               "artifact every public claim cites."

      refute readme =~ "docs/evidence/phase-03/bench.md",
             "README.md still links the historical bench evidence as if it were current."
    end

    test "P4 every README throughput row is labelled micro or end-to-end" do
      rows =
        "README.md"
        |> File.read!()
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r{increments/s|ops/s|events/s|rows/s}))
        |> Enum.reject(&(&1 =~ ~r/^\s*\|\s*-+/))

      assert rows != [], "no throughput row found in README.md; has the table moved?"

      for row <- rows do
        assert row =~ ~r/\bmicro\b|\bend-to-end\b/,
               "a README throughput row carries no kind label: #{inspect(row)}. A figure " <>
                 "without micro or end-to-end beside it invites the reader to take an " <>
                 "in-memory rate for a durable one."
      end
    end

    test "P4 the README states the toolchain and the date the figures were measured on" do
      readme = File.read!("README.md")

      assert readme =~ ~r/Elixir 1\.\d+\.\d+/
      assert readme =~ ~r/OTP \d+/
      assert readme =~ ~r/20\d\d-\d\d-\d\d/
    end

    test "P4 docs/launch/gtm.md quotes no throughput figure without that link" do
      gtm = File.read!("docs/launch/gtm.md")

      quoted =
        Regex.scan(~r/~?[\d.,]+\s*(?:M|k)?\s*(?:increments?|incr|ops|events)\s*\/\s*sec/i, gtm)

      if quoted != [] do
        assert gtm =~ "docs/evidence/v1/phase-08/08c-results.md",
               "docs/launch/gtm.md quotes #{inspect(quoted)} and links no evidence artifact."
      end

      for figure <- @superseded do
        refute String.contains?(gtm, figure), "gtm.md still quotes #{figure}"
      end
    end
  end

  describe "the historical evidence is superseded, not deleted" do
    test "docs/evidence/phase-03/bench.md is still there and carries the header note" do
      path = "docs/evidence/phase-03/bench.md"

      assert File.exists?(path),
             "the historical bench evidence was deleted. Superseding evidence is right; " <>
               "deleting it removes the only explanation of why the old figure existed."

      contents = File.read!(path)

      assert contents =~ "Historical",
             "#{path} has no header note marking it historical, so a reader arriving at it " <>
               "from a search engine reads a current claim."

      assert contents =~ "docs/evidence/v1/phase-08",
             "#{path} does not point at what superseded it."
    end
  end

  # Everything: the shipped README and changelog, every document, every module
  # and every test. Minus the historical evidence page and this file.
  @roots ["README.md", "CHANGELOG.md", "NOTICE.md"]
  @globs ["docs/**/*.md", "lib/**/*.ex", "test/**/*.exs", "test/**/*.ex"]

  defp claim_documents do
    @globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.concat(Enum.filter(@roots, &File.exists?/1))
    |> Enum.reject(&excluded?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp excluded?(path), do: String.starts_with?(path, "docs/evidence/phase-03/") or path == @self
end
