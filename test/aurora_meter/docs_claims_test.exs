defmodule AuroraMeter.DocsClaimsTest do
  @moduledoc """
  Build unit 02d. Two mechanical guards over what the package documentation
  claims.

  **G01: no package documentation file claims a bounded loss window,
  exactly-once delivery, or a global quota guarantee**, except at an
  allow-listed location that carries a written reason. The rule `docs/guarantees.md`
  states and this test enforces is that a guarantee is written with the
  condition that makes it true, or it is not written. Three families of phrase
  break that rule whatever sentence they appear in:

    * a fixed loss window ("at most one interval", "up to five seconds"),
      because buffered loss is everything not in an acknowledged flush batch and
      is unbounded while the database is away;
    * a delivery promise stronger than at-least-once, because export is
      at-least-once with provider-side idempotency (I15) and worker scheduling
      is not an assumption of running a single time (I16);
    * a cluster-wide serialized quota, because quotas are strict on one node and
      convergent across nodes and nothing stronger (D09).

  Scope: `README.md` and every `*.md` under `docs/`, except `docs/adr/` and
  `docs/evidence/`. An ADR records a decision at the time it was taken and the
  evidence tree records what a run printed; neither is edited to match today's
  contract, and ADR 0003 carries an appended dated note for exactly that reason.
  `CHANGELOG.md` is excluded on the same grounds (`open-findings.md` W12 sets
  that rule for the dash sweep and it holds here).

  The allow-list keys on the **text** of the permitted occurrence, never on a
  line number: a line number is wrong as soon as anything above it is edited,
  which `open-findings.md` X67 and X90 record happening twice inside a day. An
  allow-listed snippet that no longer appears in its file fails, so an exemption
  cannot outlive the sentence it was written for.

  **G05: every "Proven by" cell of the guarantee table resolves.** The table's
  whole value is that column, and a column nobody checks rots on the first
  rename. A cell either names a test that exists, or says "not yet proven
  (phase NN)", or defers to Pro.

  The test set is read by parsing test sources into AST, not by grepping them
  and not by reflection. Grepping is the trap `open-findings.md` X84 records: a
  name that survives only in a moduledoc satisfies a textual search, so the
  check validates the documentation against itself and its negative control
  passes. A `test "..."` call is a call; a heredoc is a string. The parser sees
  the difference, and `the parser itself` below proves it does. Reflection is no
  use either, because ExUnit loads only the files in the current run set, so
  `Code.ensure_loaded?/1` would make this file pass when it is run on its own,
  which is exactly how somebody checks it.

  It reads files and starts nothing, so it is `async: true` and runs on the
  headless CI leg.
  """
  use ExUnit.Case, async: true

  @readme "README.md"
  @docs_glob "docs/**/*.md"
  @excluded_dirs ["docs/adr/", "docs/evidence/"]

  @guarantees "docs/guarantees.md"
  @test_glob "test/**/*_test.exs"
  @fixture "test/support/claims_fixtures/docstring_only.exs"

  @bounded_loss ["at most one interval", "up to five seconds", "never lose", "cannot lose"]
  @exactly_once ["exactly once", "exactly-once", "guaranteed delivery"]
  @global_quota ["globally serialized", "globally serialised", "global quota"]

  @forbidden @bounded_loss ++ @exactly_once ++ @global_quota

  # `{path, snippet, reason}`. `snippet` is the text as it appears on one line of
  # the file, which is what makes the entry survive an edit above it and die
  # with the sentence it exempts.
  @allowed [
    {"docs/correctness.md",
     "claim a strict global quota. A `:metered` feature is never refused by design, and",
     "the sentence begins on the line above with \"Aurora Meter does not\": it is the " <>
       "denial this check exists to protect, and I05's known limits are the one place " <>
       "the programme requires it to be written out."},
    {"docs/correctness.md",
     "invariant, that an accepted event is recorded exactly once across a kill before",
     "I06's statement of what phase 03 will prove and what today's code does not do. " <>
       "The paragraph ends \"is not guaranteed by the current code\", so it withholds " <>
       "the claim rather than making it."},
    {"docs/correctness.md", "## I16 Worker scheduling is not an exactly-once assumption",
     "the invariant's own title, and the title is a denial. It is fixed by " <>
       "`invariant-map.md` and by the section parser in correctness_index_test."},
    {"docs/correctness.md",
     "writes nothing. Aurora Meter does not claim exactly-once host job execution",
     "the explicit refusal of the claim, in the invariant whose whole subject is that " <>
       "scheduling cannot be assumed to run a single time."},
    {"docs/correctness.md",
     "- `AuroraMeter.StatementsTest` / `test I02 a retry after a failed statement applies the deltas exactly once`",
     "a test name, quoted so the index and the suite agree; correctness_index_test " <>
       "fails if it is reworded. The test is about one flush batch having one durable " <>
       "effect (G7), which a receipt primary key inside the transaction gives, and is " <>
       "not a claim about delivery."},
    {"docs/credits.md",
     "exactly once, say. Ask it rather than probing for the reference beforehand:",
     "the sentence is about the host announcing a payment to its customer once. That " <>
       "is decided by `grant_with_status/3` inside the balance row's lock (I14), which " <>
       "is a ledger idempotency contract, not a delivery guarantee."}
  ]

  @planned_proof ~r/^not yet proven \(phase \d\d\)$/
  @proof ~r/^`([A-Za-z0-9_.]+)` \/ `(test [^`]*)`/
  @pro_proof ~r/^`pro:` `(AuroraMeter\.Pro\.[A-Za-z0-9_.]+)`/
  @row ~r/^\| G\d+ \|/

  describe "G01 forbidden claims" do
    test "G01 no package document claims a bounded loss window" do
      assert_no_hits(@bounded_loss)
    end

    test "G01 no package document claims exactly-once delivery" do
      assert_no_hits(@exactly_once)
    end

    test "G01 no package document claims a global or globally serialized quota" do
      assert_no_hits(@global_quota)
    end
  end

  describe "G01 the allow-list" do
    test "G01 every allow-listed occurrence still exists and carries a reason" do
      absent =
        for {path, snippet, _reason} <- @allowed,
            not (File.exists?(path) and String.contains?(File.read!(path), snippet)),
            do: "  #{path}: #{inspect(snippet)}"

      assert absent == [],
             "allow-listed occurrences that are no longer in the file. Delete the entry " <>
               "rather than leaving a standing exemption for text that is gone:\n" <>
               Enum.join(absent, "\n")

      unreasoned =
        for {path, snippet, reason} <- @allowed,
            String.length(String.trim(reason)) < 40,
            do: "  #{path}: #{inspect(snippet)}"

      assert unreasoned == [],
             "allow-list entries without a written reason:\n" <> Enum.join(unreasoned, "\n")

      toothless =
        for {path, snippet, _reason} <- @allowed,
            not Enum.any?(@forbidden, &String.contains?(String.downcase(snippet), &1)),
            do: "  #{path}: #{inspect(snippet)}"

      assert toothless == [],
             "allow-list entries whose snippet carries no forbidden phrase, so they " <>
               "exempt nothing and only hide the list's real size:\n" <>
               Enum.join(toothless, "\n")
    end
  end

  describe "G01 the scan itself" do
    test "G01 the scan covers README.md and every file under docs/ except adr/ and evidence/" do
      scanned = MapSet.new(scanned_paths())

      expected =
        @docs_glob
        |> Path.wildcard()
        |> Enum.reject(&excluded?/1)
        |> MapSet.new()
        |> MapSet.put(@readme)

      assert expected == scanned

      for required <- [
            @readme,
            @guarantees,
            "docs/metering.md",
            "docs/clustering.md",
            "docs/examples/concepts.md",
            "docs/examples/allowance-and-overage.md"
          ] do
        assert required in scanned, "#{required} is not in the scan"
      end

      refute Enum.any?(scanned, &String.starts_with?(&1, "docs/adr/"))
      refute Enum.any?(scanned, &String.starts_with?(&1, "docs/evidence/"))
      refute "CHANGELOG.md" in scanned

      # A scan of nothing passes every phrase test, so the size is asserted too.
      assert MapSet.size(scanned) >= 18
    end
  end

  describe "G05 the guarantee table" do
    test "G05 every row carries conditions, what voids it, an invariant and a proof" do
      rows = guarantee_rows()

      assert length(rows) >= 15,
             "#{@guarantees} has only #{length(rows)} guarantee rows"

      # An invariant cell is legitimately three characters ("I04"), so it has its
      # own floor. Everything else is a sentence or it is not saying anything.
      thin =
        for row <- rows,
            {name, value, floor} <- [
              {"guarantee", row.guarantee, 8},
              {"conditions", row.conditions, 60},
              {"voids", row.voids, 20},
              {"invariant", row.invariant, 3},
              {"proof", row.proof, 20}
            ],
            String.length(String.trim(value)) < floor,
            do: "  #{row.id}: #{name} is empty or too short to be saying anything"

      assert thin == [], "#{@guarantees} rows with an unfilled column:\n" <> Enum.join(thin, "\n")

      ids = Enum.map(rows, & &1.id)
      assert ids == Enum.uniq(ids), "a guarantee id is used twice: #{inspect(ids)}"
    end

    test "G05 every Proven by cell names a real test, defers to Pro, or says not yet proven" do
      known = MapSet.new(test_names(), &{&1.module, &1.full_name})

      problems =
        for row <- guarantee_rows(), problem = proof_problem(row, known), do: "  " <> problem

      assert problems == [],
             "#{@guarantees} rows whose Proven by column does not resolve. Name the test " <>
               "as `Module` / `test name`, prefix it `pro:` when aurora_meter_pro proves " <>
               "it, or write \"not yet proven (phase NN)\":\n" <> Enum.join(problems, "\n")
    end

    test "G05 at least one row is honest about not being proven yet" do
      planned = Enum.filter(guarantee_rows(), &Regex.match?(@planned_proof, &1.proof))

      refute planned == [],
             "no row of #{@guarantees} says \"not yet proven\". Either every V1 guarantee " <>
               "has shipped, which it has not, or the column has started flattering the code"
    end
  end

  describe "the parser itself" do
    # open-findings.md X84: the obvious implementation of "the documented thing
    # exists in the source" validates the documentation against itself. This
    # fixture defines no test and mentions two test names in its moduledoc and
    # in a comment. A grep would find them. The parser must not.
    test "a test name that exists only in a doc string or a comment is not a test" do
      assert fixture_names() == ["test a group this one is genuinely defined"]

      refute Enum.any?(fixture_names(), &String.contains?(&1, "moduledoc"))
      refute Enum.any?(fixture_names(), &String.contains?(&1, "comment"))

      # The same fixture read as text: a grep would have found both.
      source = File.read!(@fixture)
      assert source =~ "named only in the moduledoc"
      assert source =~ "named only in a comment"
    end

    test "a describe-wrapped test is matched by its full ExUnit name, not its bare description" do
      assert "test a group this one is genuinely defined" in fixture_names()
      refute "test this one is genuinely defined" in fixture_names()
    end

    test "a Proven by cell naming a test that does not exist is reported" do
      row = %{
        id: "G99",
        guarantee: "x",
        conditions: "x",
        voids: "x",
        invariant: "x",
        proof: "`AuroraMeter.NoSuchTest` / `test that was never written`"
      }

      assert proof_problem(row, MapSet.new()) =~ "AuroraMeter.NoSuchTest"
    end

    test "a Proven by cell in no recognised form is reported" do
      row = %{
        id: "G98",
        guarantee: "x",
        conditions: "x",
        voids: "x",
        invariant: "x",
        proof: "trust me"
      }

      assert proof_problem(row, MapSet.new()) =~ "unrecognised"
    end
  end

  # -- the sweep -------------------------------------------------------------

  defp assert_no_hits(phrases) do
    hits = for path <- scanned_paths(), hit <- hits(path, phrases), do: hit

    assert hits == [],
           "forbidden claims in package documentation. Reword to the matching row of " <>
             "#{@guarantees}, or add an allow-list entry to " <>
             "test/aurora_meter/docs_claims_test.exs with a written reason:\n" <>
             Enum.map_join(hits, "\n", fn {path, line, phrase, text} ->
               "  #{path}:#{line}: #{inspect(phrase)} in #{inspect(text)}"
             end)
  end

  defp hits(path, phrases) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {text, line} ->
      downcased = String.downcase(text)

      for phrase <- phrases,
          String.contains?(downcased, phrase),
          not allowed?(path, text),
          do: {path, line, phrase, String.trim(text)}
    end)
  end

  defp allowed?(path, text) do
    Enum.any?(@allowed, fn {allow_path, snippet, _reason} ->
      allow_path == path and String.contains?(text, snippet)
    end)
  end

  defp scanned_paths do
    [@readme | @docs_glob |> Path.wildcard() |> Enum.reject(&excluded?/1)]
    |> Enum.sort()
  end

  defp excluded?(path), do: Enum.any?(@excluded_dirs, &String.starts_with?(path, &1))

  # -- the guarantee table ---------------------------------------------------

  defp guarantee_rows do
    @guarantees
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(@row, &1))
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    cells =
      line
      |> String.split("|")
      |> Enum.slice(1..-2//1)
      |> Enum.map(&String.trim/1)

    if length(cells) != 6 do
      flunk(
        "#{@guarantees}: a guarantee row must have six columns and this one has " <>
          "#{length(cells)}. A literal \"|\" inside a cell splits the row, so write it as " <>
          "\"or\":\n  #{line}"
      )
    end

    [id, guarantee, conditions, voids, invariant, proof] = cells

    %{
      id: id,
      guarantee: guarantee,
      conditions: conditions,
      voids: voids,
      invariant: invariant,
      proof: proof
    }
  end

  defp proof_problem(row, known) do
    cond do
      Regex.match?(@planned_proof, row.proof) ->
        nil

      match = Regex.run(@pro_proof, row.proof) ->
        [_, module] = match
        if String.contains?(row.proof, "correctness.md"), do: nil, else: pro_problem(row, module)

      match = Regex.run(@proof, row.proof) ->
        [_, module, name] = match

        if MapSet.member?(known, {module, name}),
          do: nil,
          else: "#{row.id}: #{module} / #{name} does not exist in test/"

      true ->
        "#{row.id}: unrecognised Proven by cell #{inspect(row.proof)}"
    end
  end

  defp pro_problem(row, module) do
    "#{row.id}: #{module} is proven in aurora_meter_pro, so the cell must also name " <>
      "the index that holds it (Pro's correctness.md)"
  end

  # -- test source parsing ---------------------------------------------------

  defp test_names do
    @test_glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&parse_source/1)
  end

  defp fixture_names, do: @fixture |> parse_source() |> Enum.map(& &1.full_name)

  defp parse_source(path) do
    path
    |> quoted()
    |> walk(%{module: nil, describe: nil}, [])
    |> Enum.reverse()
  end

  defp quoted(path) do
    case Code.string_to_quoted(File.read!(path), file: path) do
      {:ok, ast} ->
        ast

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: meta[:line], else: meta

        flunk(
          "#{@guarantees} cannot be checked while #{path}:#{line} does not parse: " <>
            "#{inspect(message)} #{inspect(token)}. Fix the test file first."
        )
    end
  end

  defp walk({:defmodule, _, [{:__aliases__, _, parts}, body]}, ctx, acc) when is_list(body) do
    module = Enum.map_join(parts, ".", &Atom.to_string/1)
    walk(body[:do], %{ctx | module: module}, acc)
  end

  defp walk({:describe, _, [name, body]}, ctx, acc) when is_binary(name) and is_list(body) do
    walk(body[:do], %{ctx | describe: name}, acc)
  end

  defp walk({kind, _meta, [name | _]}, ctx, acc)
       when kind in [:test, :property] and is_binary(name) do
    [%{module: ctx.module, full_name: full_name(kind, ctx.describe, name)} | acc]
  end

  defp walk({_, _, args}, ctx, acc) when is_list(args),
    do: Enum.reduce(args, acc, &walk(&1, ctx, &2))

  defp walk({a, b}, ctx, acc), do: walk(b, ctx, walk(a, ctx, acc))
  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_other, _ctx, acc), do: acc

  defp full_name(kind, nil, description), do: "#{kind} #{description}"
  defp full_name(kind, describe, description), do: "#{kind} #{describe} #{description}"
end
