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

    test "G05 the not-yet-proven form is still recognised and still constrained" do
      # This test used to require that at least one row said "not yet proven".
      # That was a property of the tree on the day it was written (G10 said it)
      # rather than an invariant, and closing `open-findings.md` X233 made the
      # guard against the column flattering the code demand that the column
      # under-claim somewhere. Both halves of what it was for survive: the form
      # still has to parse, because the next unshipped guarantee will use it,
      # and G07 below is what stops it being used by a guarantee that is proven.
      planned = %{
        id: "G99",
        guarantee: "x",
        conditions: "x",
        voids: "x",
        invariant: "I99",
        proof: "not yet proven (phase 03)"
      }

      assert proof_problem(planned, MapSet.new()) == nil,
             "the not-yet-proven form no longer parses, so an unshipped guarantee has " <>
               "nowhere honest to say so"

      refute Regex.match?(@planned_proof, "proven later"),
             "the not-yet-proven pattern matches free text, so it exempts anything"

      # And every row on today's page resolves, which is the state X233 left.
      known = MapSet.new(test_names(), &{&1.module, &1.full_name})

      unresolved =
        for row <- guarantee_rows(), problem = proof_problem(row, known), do: "  " <> problem

      assert unresolved == [], Enum.join(unresolved, "\n")
    end
  end

  @lib_glob "lib/**/*.ex"
  @claims_fixture "test/support/claims_fixtures/docstring_only.exs"

  # The doc-string half of the allow-list, keyed on the text of the permitted
  # occurrence exactly as `@allowed` is. Empty is the right starting state: an
  # entry is added only when a claim in a doc string is true for a written
  # reason, and the test below fails an entry whose text has gone.
  @allowed_docs [
    {"lib/aurora_meter/exporter.ex",
     "`:uncertain` is the only non-terminal state that cannot lose money",
     "the sentence is about the outbox state machine, not about buffered counters: " <>
       "it says which state the four rules err towards, and the reason is that an " <>
       "uncertain item is retried or resolved by a person rather than dropped. It " <>
       "withholds a promise rather than making one."},
    {"lib/aurora_meter/credits.ex",
     "returns every hold exactly once even when several were written in the same",
     "a statement about a keyset cursor over rows, not about delivery. Ordering by " <>
       "`(inserted_at, id)` is what makes paging unable to skip or repeat a row, and " <>
       "`AuroraMeter.CreditsHistoryTest` is where it is proved."}
  ]

  describe "G06 the sweep reads lib/ doc strings" do
    # `open-findings.md` X98. The sweep above reads `README.md` and `docs/`, and
    # that is half the published surface: a `@moduledoc` renders on hexdocs
    # exactly as a guide does, and a customer reading `AuroraMeter.Credits` on
    # hex.pm cannot tell which of the two they are looking at. Two "exactly
    # once" claims were found in Pro's doc strings during 02d, both legitimate,
    # and the point of the row is that nothing was looking.
    #
    # Read as AST, never as text: a `#` comment is not a doc string, and a
    # forbidden phrase quoted inside one is not a claim.
    test "G06 no doc string in lib/ claims a bounded loss window" do
      assert_no_doc_hits(@bounded_loss)
    end

    test "G06 no doc string in lib/ claims exactly-once delivery" do
      assert_no_doc_hits(@exactly_once)
    end

    test "G06 no doc string in lib/ claims a global or globally serialized quota" do
      assert_no_doc_hits(@global_quota)
    end

    test "G06 the doc-string sweep read the modules it was meant to read" do
      strings = doc_strings()

      assert length(strings) >= 100,
             "the doc-string sweep found only #{length(strings)} doc strings under lib/. " <>
               "An empty or shrunken selection is a failure, not a pass."

      files = strings |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      assert length(files) >= 30,
             "only #{length(files)} files under lib/ carried a doc string"

      assert "lib/aurora_meter/credits.ex" in files
    end

    test "G06 every doc-string exemption still exists and carries a reason" do
      # The same three questions `@allowed` is asked: the text is still there,
      # the reason is written, and the entry exempts something. An exemption
      # that outlives its sentence is a standing hole.
      absent =
        for {path, snippet, _reason} <- @allowed_docs,
            not (File.exists?(path) and String.contains?(File.read!(path), snippet)),
            do: "  #{path}: #{inspect(snippet)}"

      assert absent == [],
             "doc-string exemptions that are no longer in the file:\n" <> Enum.join(absent, "\n")

      unreasoned =
        for {path, snippet, reason} <- @allowed_docs,
            String.length(String.trim(reason)) < 40,
            do: "  #{path}: #{inspect(snippet)}"

      assert unreasoned == [],
             "doc-string exemptions without a written reason:\n" <> Enum.join(unreasoned, "\n")

      toothless =
        for {path, snippet, _reason} <- @allowed_docs,
            not Enum.any?(@forbidden, &String.contains?(String.downcase(snippet), &1)),
            do: "  #{path}: #{inspect(snippet)}"

      assert toothless == [],
             "doc-string exemptions whose snippet carries no forbidden phrase, so they " <>
               "exempt nothing and only hide the list's real size:\n" <>
               Enum.join(toothless, "\n")
    end

    test "G06 a forbidden phrase in a comment is not a doc string" do
      # The fixture defines one moduledoc and mentions the same phrase in a
      # comment beside it. A grep finds both; the parser must find one.
      strings = doc_strings_in(@claims_fixture)

      assert Enum.any?(strings, fn {_path, _line, text} ->
               String.contains?(text, "named only in the moduledoc")
             end)

      refute Enum.any?(strings, fn {_path, _line, text} ->
               String.contains?(text, "named only in a comment")
             end)
    end
  end

  describe "G07 a guarantee is not allowed to stay pessimistic" do
    # `open-findings.md` X233. G05 above catches a row that claims a proof it
    # does not have. The opposite direction had nothing: `docs/guarantees.md`
    # G10 read "not yet proven (phase 03)" while `docs/correctness.md` named
    # fourteen tests for I06, phase 03 having landed months earlier. Under
    # claiming is the safe direction and is still wrong, because the page a
    # customer reads as the contract told them a shipped guarantee was unproven.
    test "G07 no row says not yet proven while correctness.md names a test for its invariants" do
      proven = invariants_with_tests()

      wrong =
        for row <- guarantee_rows(),
            Regex.match?(@planned_proof, row.proof),
            ids = invariant_ids(row),
            ids != [],
            Enum.all?(ids, &MapSet.member?(proven, &1)),
            do: "  #{row.id} (#{Enum.join(ids, ", ")}) says #{inspect(row.proof)}"

      assert wrong == [],
             "#{@guarantees} rows that claim less than the suite proves. Every invariant " <>
               "these rows name has at least one test in docs/correctness.md that exists, " <>
               "so the Proven by cell must name one:\n" <> Enum.join(wrong, "\n")
    end

    test "G07 the invariant index it reads is not empty" do
      proven = invariants_with_tests()

      assert MapSet.size(proven) >= 10,
             "docs/correctness.md names tests for only #{MapSet.size(proven)} invariants, " <>
               "so the check above cannot fail"

      assert MapSet.member?(proven, "I06")

      rows = Enum.filter(guarantee_rows(), &(invariant_ids(&1) != []))

      assert length(rows) >= 10,
             "only #{length(rows)} guarantee rows name an invariant at all"
    end

    test "G07 a row that under-claims is reported" do
      # The negative control: the same question, asked of a row built here.
      proven = invariants_with_tests()

      row = %{
        id: "G99",
        guarantee: "x",
        conditions: "x",
        voids: "x",
        invariant: "I06",
        proof: "not yet proven (phase 03)"
      }

      assert Regex.match?(@planned_proof, row.proof)
      assert Enum.all?(invariant_ids(row), &MapSet.member?(proven, &1))

      # and a row naming an invariant nothing proves is left alone
      absent = %{row | invariant: "I99"}
      refute Enum.all?(invariant_ids(absent), &MapSet.member?(proven, &1))
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

  # -- G06: lib/ doc strings (open-findings.md X98) ---------------------------

  defp assert_no_doc_hits(phrases) do
    hits =
      for {path, line, text} <- doc_strings(),
          phrase <- phrases,
          String.contains?(String.downcase(text), phrase),
          not doc_allowed?(path, text),
          do: {path, line, phrase}

    assert hits == [],
           "forbidden claims in doc strings under lib/. They render on hexdocs exactly as " <>
             "the guides do, which is why X98 asked for this half of the sweep. Reword to " <>
             "the matching row of #{@guarantees}, or add an allow-list entry to " <>
             "test/aurora_meter/docs_claims_test.exs with a written reason:\n" <>
             Enum.map_join(hits, "\n", fn {path, line, phrase} ->
               "  #{path}:#{line}: #{inspect(phrase)}"
             end)
  end

  defp doc_allowed?(path, text) do
    Enum.any?(@allowed_docs, fn {allow_path, snippet, _reason} ->
      allow_path == path and String.contains?(text, snippet)
    end)
  end

  defp doc_strings do
    @lib_glob |> Path.wildcard() |> Enum.sort() |> Enum.flat_map(&doc_strings_in/1)
  end

  # Every `@moduledoc`, `@doc`, `@typedoc` and `@shortdoc` string, from the AST.
  # Reading the source as text would find the same words in a comment and in
  # ordinary code, which is X84's trap and the reason the test-name parser above
  # exists.
  defp doc_strings_in(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(
      literal_encoder: &{:ok, {:__block__, &2, [&1]}},
      token_metadata: true,
      unescape: false,
      file: path
    )
    |> Macro.prewalk([], fn
      {:@, _meta, [{attr, _, [argument]}]} = node, acc
      when attr in [:moduledoc, :doc, :typedoc, :shortdoc] ->
        {node, doc_binaries(path, argument) ++ acc}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp doc_binaries(path, {:__block__, meta, [text]}) when is_binary(text),
    do: [{path, meta[:line], text}]

  defp doc_binaries(path, {:<<>>, _meta, parts}) do
    for {:__block__, meta, [text]} <- parts, is_binary(text), do: {path, meta[:line], text}
  end

  defp doc_binaries(path, {:<>, _meta, arguments}),
    do: Enum.flat_map(arguments, &doc_binaries(path, &1))

  defp doc_binaries(_path, _other), do: []

  # -- G07: a guarantee that under-claims (open-findings.md X233) -------------

  @correctness "docs/correctness.md"
  @correctness_heading ~r/^## (I\d\d) /
  @correctness_test ~r/^- `([^`]+)` \/ `(.*)`$/

  # The invariant ids a guarantee row names, from its Invariant cell. A cell may
  # carry prose beside the ids ("I04 (by contrast: ...)"), so the ids are
  # extracted rather than the cell split.
  defp invariant_ids(row) do
    ~r/\bI\d\d\b/ |> Regex.scan(row.invariant) |> Enum.map(&hd/1) |> Enum.uniq()
  end

  # Invariants whose section in docs/correctness.md names at least one test that
  # is not PLANNED. A PLANNED bullet is a promise, and a guarantee row is
  # entitled to say "not yet proven" while its tests are promises.
  defp invariants_with_tests do
    @correctness
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({nil, MapSet.new()}, fn line, {current, found} ->
      cond do
        match = Regex.run(@correctness_heading, line) ->
          {Enum.at(match, 1), found}

        current != nil and Regex.match?(@correctness_test, line) ->
          {current, MapSet.put(found, current)}

        true ->
          {current, found}
      end
    end)
    |> elem(1)
  end
end
