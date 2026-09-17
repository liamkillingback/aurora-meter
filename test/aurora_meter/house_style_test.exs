defmodule AuroraMeter.HouseStyleTest do
  @moduledoc """
  Build unit 10a. **H1: no em dash and no en dash in copy that ships.**

  The owner's standing rule is that neither character appears in user-facing
  copy or documentation. `open-findings.md` X88 counted 475 across the two
  packages and classified none of them, which is why the row had to be swept by
  hand: the rule is about **prose**, and a dash inside a code sample, a URL, a
  test assertion or a third-party quotation is not prose. A regular expression
  over whole files cannot tell those apart, so this test does not use one.

  ## What is scanned, and why that is the shipped surface

    * `README.md` and `NOTICE.md`, because `mix.exs`'s `package.files` puts them
      **inside the Hex tarball**. The README renders on the package page and is
      the first thing a prospective user reads, which is why X88 names it the
      highest priority file in the sweep even though it held only nine.
    * `CHANGELOG.md` **above the first dated release heading**. The published
      entries below it are history and are never edited (X88, and build unit
      10a's scope); the unreleased section is copy that has not shipped yet and
      is still ours to write.
    * every `*.md` under `docs/`, because those render on hexdocs, minus
      `docs/adr/` (a decision as it was taken), `docs/evidence/` (what a run
      printed) and `docs/launch/` (a superseded draft kept as history).
    * every `lib/**/*.ex`: the doc strings, because hexdocs renders them exactly
      as it renders the guides, and **every other string literal**, because that
      is where the dashes a customer actually sees live. X271 found one in
      `runway_text/1` in Pro's rendered money section and 09b found three the
      free core rendered into a host's dashboard, one of which reached an
      `aria-label`. A doc string is read; a rendered string is seen.

  ## What is not scanned, and why the omissions are deliberate

  `test/` is not copy. `docs/adr/`, `docs/evidence/`, `docs/launch/`,
  `plan.md` and the published `CHANGELOG.md` entries are history, and history is
  not rewritten to match today's style. A `#` comment is not copy either, in
  `lib/` or anywhere else, and **this test must not be trippable by one**:
  `AuroraMeter.EvidenceWritesTest` matched on prose and was tripped by a comment
  beside an unrelated `File.write!`, and a guard that fires on a comment is a
  guard people learn to work around.

  ## How the classification is done

  Markdown is read with a fence-aware scanner: a line inside a ``` or ~~~ block
  is code, text inside a `` ` `` span or an `http(s)://` run is code, a line
  beginning `>` is a quotation, everything else is prose.

  Elixir is read as **AST**, never as text. `Code.string_to_quoted!/2` with a
  literal encoder gives every binary literal with its line, so a `#` comment is
  invisible to this test by construction rather than by a pattern that tries to
  skip one. Inside a doc string the same markdown classification runs again, so
  a fenced sample or an `iex>` line inside a `@moduledoc` is code, exactly as it
  is in a guide.

  ## Why the fixtures exist

  A guard that can pass by matching nothing will (X325, X350). Two fixtures
  under `test/support/style_fixtures/` carry one dash of every kind, and the
  scanner is asserted to report **exactly** the prose ones and **none** of the
  code ones. They are read as data and are outside every scanned path, so they
  discriminate on every run rather than only on the day the guard was written.

  Reads files and starts nothing, so `async: true`.
  """
  use ExUnit.Case, async: true

  @em "—"
  @en "–"

  @md_roots ["README.md", "NOTICE.md"]
  @md_glob "docs/**/*.md"
  @md_excluded ["docs/adr/", "docs/evidence/", "docs/launch/"]
  @ex_glob "lib/**/*.ex"
  @changelog "CHANGELOG.md"

  @md_fixture "test/support/style_fixtures/dashes.md"
  @ex_fixture "test/support/style_fixtures/dashes.exs"

  describe "H1 the shipped surface carries no em or en dash" do
    test "H1 no dash in README.md or NOTICE.md, which ship inside the Hex tarball" do
      assert_clean(Enum.filter(@md_roots, &File.exists?/1))
    end

    test "H1 no dash in the unreleased section of CHANGELOG.md" do
      hits = markdown_hits(@changelog, unreleased_lines())

      assert hits == [],
             "an em or en dash in the part of #{@changelog} that has not shipped yet. " <>
               "The released entries below the first dated heading are history and are " <>
               "left alone; this section is not:\n" <> render(hits)
    end

    test "H1 no dash in any guide under docs/" do
      assert_clean(doc_paths())
    end

    test "H1 no dash in a doc string or a rendered string under lib/" do
      hits = Enum.flat_map(source_paths(), &elixir_hits/1)

      assert hits == [],
             "an em or en dash in copy that ships. A doc string renders on hexdocs and a " <>
               "string literal can reach a customer's screen (X271, and the aria-label 09b " <>
               "found). Use a comma, a colon, parentheses or a full stop:\n" <> render(hits)
    end
  end

  describe "H1 the scan itself" do
    # Every one of these exists because a scan that silently selected nothing
    # would pass for ever and report a clean sweep (X324, X325).
    test "H1 the scan selects the files it is meant to select" do
      docs = doc_paths()

      assert length(docs) >= 20,
             "the guide scan found only #{length(docs)} files, which is fewer than docs/ " <>
               "holds. A shrunken selection is a failure, not a pass."

      assert "docs/correctness.md" in docs
      assert "docs/guarantees.md" in docs
      assert "docs/credits.md" in docs
      refute Enum.any?(docs, &String.starts_with?(&1, "docs/adr/"))
      refute Enum.any?(docs, &String.starts_with?(&1, "docs/evidence/"))
      refute Enum.any?(docs, &String.starts_with?(&1, "docs/launch/"))

      sources = source_paths()

      assert length(sources) >= 50,
             "the source scan found only #{length(sources)} files under lib/"

      assert "lib/aurora_meter.ex" in sources

      assert "README.md" in @md_roots
      refute Enum.empty?(unreleased_lines())
    end

    test "H1 the unreleased window stops at the first dated release heading" do
      lines = unreleased_lines()
      last = lines |> Enum.map(&elem(&1, 1)) |> Enum.max()
      all = @changelog |> File.read!() |> String.split("\n")

      assert length(all) > last + 10,
             "the unreleased window covers the whole changelog, so the released entries " <>
               "are being swept as if they were not history"

      assert Enum.any?(all, &Regex.match?(~r/^## \[\d+\.\d+\.\d+\]/, &1)),
             "#{@changelog} has no dated release heading, so the window has no end"
    end
  end

  describe "the scanner itself" do
    # The fixtures are the permanent control. Without them "no hits" means
    # either a clean tree or a scanner that looks at nothing, and those are the
    # same result.
    test "a markdown fixture reports its prose dashes and none of its code dashes" do
      hits = markdown_hits(@md_fixture, numbered(File.read!(@md_fixture)))
      reported = MapSet.new(hits, fn {_p, line, _ch, _kind, _t} -> line end)

      # Lines are named in the fixture itself, so an edit there fails here.
      assert MapSet.member?(reported, line_of(@md_fixture, "REPORT-prose")),
             "the scanner did not report an em dash in plain markdown prose"

      assert MapSet.member?(reported, line_of(@md_fixture, "REPORT-en")),
             "the scanner did not report an en dash in plain markdown prose"

      for marker <- ~w(SILENT-fence SILENT-span SILENT-url) do
        refute MapSet.member?(reported, line_of(@md_fixture, marker)),
               "the scanner reported #{marker}, which is code or a URL and is not prose"
      end

      assert MapSet.size(reported) == 2,
             "the markdown fixture must produce exactly the two prose hits, and produced " <>
               "#{MapSet.size(reported)}: #{inspect(MapSet.to_list(reported))}"
    end

    test "an Elixir fixture reports doc prose and rendered strings, and never a comment" do
      hits = elixir_hits(@ex_fixture)
      reported = MapSet.new(hits, fn {_p, line, _ch, _kind, _t} -> line end)

      assert MapSet.member?(reported, line_of(@ex_fixture, "REPORT-moduledoc")),
             "the scanner did not report an em dash in @moduledoc prose"

      assert MapSet.member?(reported, line_of(@ex_fixture, "REPORT-string")),
             "the scanner did not report an en dash in a rendered string literal"

      for marker <- ~w(SILENT-comment SILENT-docfence SILENT-docspan) do
        refute MapSet.member?(reported, line_of(@ex_fixture, marker)),
               "the scanner reported #{marker}. A comment is not copy and a fenced sample " <>
                 "inside a doc string is not prose; a guard that fires on either is one " <>
                 "people route around"
      end

      assert MapSet.size(reported) == 2,
             "the Elixir fixture must produce exactly the two copy hits, and produced " <>
               "#{MapSet.size(reported)}: #{inspect(MapSet.to_list(reported))}"
    end

    test "the fixtures really do contain a dash of every kind the test names" do
      # Otherwise "the scanner stayed silent" is satisfied by a fixture that has
      # nothing to be silent about.
      for path <- [@md_fixture, @ex_fixture] do
        body = File.read!(path)
        assert String.contains?(body, @em), "#{path} carries no em dash"
        assert String.contains?(body, @en), "#{path} carries no en dash"

        for marker <- markers(path) do
          assert dash_on?(path, marker),
                 "#{path}: the line marked #{marker} carries no dash, so asserting " <>
                   "anything about it proves nothing"
        end
      end
    end

    test "the fixtures are outside every scanned path" do
      scanned = doc_paths() ++ source_paths() ++ @md_roots
      refute @md_fixture in scanned
      refute @ex_fixture in scanned
    end
  end

  # -- selection -------------------------------------------------------------

  defp doc_paths do
    @md_glob
    |> Path.wildcard()
    |> Enum.reject(fn p -> Enum.any?(@md_excluded, &String.starts_with?(p, &1)) end)
    |> Enum.sort()
  end

  defp source_paths, do: @ex_glob |> Path.wildcard() |> Enum.sort()

  defp unreleased_lines do
    @changelog
    |> File.read!()
    |> numbered()
    |> Enum.take_while(fn {text, _line} -> not Regex.match?(~r/^## \[\d+\.\d+\.\d+\]/, text) end)
  end

  defp numbered(body) do
    body |> String.split("\n") |> Enum.with_index(1)
  end

  defp assert_clean(paths) do
    hits = Enum.flat_map(paths, fn p -> markdown_hits(p, numbered(File.read!(p))) end)

    assert hits == [],
           "an em or en dash in copy that ships to hexdocs and to the package page. " <>
             "Use a comma, a colon, parentheses or a full stop. A dash inside a fenced " <>
             "sample, a code span or a URL is not reported and does not need changing:\n" <>
             render(hits)
  end

  defp render(hits) do
    Enum.map_join(hits, "\n", fn {path, line, ch, kind, text} ->
      "  #{path}:#{line} [#{kind}] #{name(ch)}: #{String.slice(text, 0, 120)}"
    end)
  end

  defp name(@em), do: "em dash"
  defp name(@en), do: "en dash"

  # -- markdown --------------------------------------------------------------

  @doc false
  def markdown_hits(path, numbered_lines, opts \\ []) do
    # A doc string writes a code block by indenting it, which is why the
    # indented rule is on for `lib/` and off for a guide: in a guide four spaces
    # is as likely to be a wrapped list item, and a rule that swallowed those
    # would hide real prose.
    indented_code? = Keyword.get(opts, :indented_code, false)

    {hits, _fence} =
      Enum.reduce(numbered_lines, {[], nil}, fn {text, line}, {acc, fence} ->
        case classify_line(path, text, line, fence, indented_code?) do
          {:code, next_fence} -> {acc, next_fence}
          {:prose, found} -> {found ++ acc, nil}
        end
      end)

    Enum.reverse(hits)
  end

  # One line, five cases, in order: inside a fence, opening a fence, a
  # quotation, a sample, prose.
  defp classify_line(path, text, line, fence, indented_code?) do
    trimmed = String.trim_leading(text)

    cond do
      fence != nil -> {:code, if(String.starts_with?(trimmed, fence), do: nil, else: fence)}
      String.starts_with?(trimmed, "```") -> {:code, "```"}
      String.starts_with?(trimmed, "~~~") -> {:code, "~~~"}
      not_prose?(trimmed, text, indented_code?) -> {:code, nil}
      true -> {:prose, prose_hits(path, line, text)}
    end
  end

  defp not_prose?(trimmed, text, indented_code?) do
    String.starts_with?(trimmed, ">") or String.starts_with?(trimmed, "iex>") or
      String.starts_with?(trimmed, "...>") or
      (indented_code? and Regex.match?(~r/^\s{4,}\S/, text))
  end

  # A dash is prose unless it sits inside an inline code span or a URL.
  defp prose_hits(path, line, text) do
    if String.contains?(text, @em) or String.contains?(text, @en) do
      masked = mask(text)

      for {ch, index} <- Enum.with_index(String.graphemes(text)),
          ch in [@em, @en],
          Enum.at(masked, index) == ch,
          do: {path, line, ch, "prose", String.trim(text)}
    else
      []
    end
  end

  defp mask(text) do
    graphemes = String.graphemes(text)

    ~r/`[^`]*`|https?:\/\/\S+/
    |> Regex.scan(text, return: :index)
    |> Enum.reduce(graphemes, fn [{start, len}], acc ->
      # Regex indexes are byte offsets; convert to grapheme positions.
      before = text |> binary_part(0, start) |> String.length()
      width = text |> binary_part(start, len) |> String.length()
      Enum.reduce(before..(before + width - 1)//1, acc, &List.replace_at(&2, &1, " "))
    end)
  end

  # -- elixir ----------------------------------------------------------------

  @doc false
  def elixir_hits(path) do
    source = File.read!(path)

    if String.contains?(source, @em) or String.contains?(source, @en) do
      ast =
        Code.string_to_quoted!(source,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}},
          token_metadata: true,
          unescape: false,
          file: path
        )

      {docs, others} = binaries(ast)
      doc_lines = MapSet.new(docs, fn {_bin, line} -> line end)

      doc_hits =
        Enum.flat_map(docs, fn {bin, line} ->
          markdown_hits(path, doc_numbered(bin, line), indented_code: true)
        end)

      string_hits =
        for {bin, line} <- others,
            not MapSet.member?(doc_lines, line),
            {ch, _i} <- Enum.with_index(String.graphemes(bin)),
            ch in [@em, @en],
            do: {path, line, ch, "rendered string", String.trim(one_line(bin))}

      Enum.sort_by(doc_hits ++ string_hits, fn {_p, line, _c, _k, _t} -> line end)
    else
      []
    end
  end

  # A heredoc's metadata line is the line of the opening delimiter, so the body
  # starts on the next one. Close enough to point a reader at the right place,
  # and exact for a single-line string.
  defp doc_numbered(bin, line) do
    bin
    |> String.split("\n")
    |> Enum.with_index(line + 1)
  end

  defp one_line(bin), do: bin |> String.split("\n") |> Enum.find(&dash?/1) |> Kernel.||(bin)

  defp dash?(text), do: String.contains?(text, @em) or String.contains?(text, @en)

  # Every binary literal in the module, split into the ones that are doc strings
  # and the ones that are not. Reading the AST is what makes a `#` comment
  # invisible here: the parser drops it, so nothing this test does can fire on
  # one.
  defp binaries(ast) do
    {_ast, {docs, others}} =
      Macro.prewalk(ast, {[], []}, fn
        {:@, _, [{attr, _, [arg]}]} = node, {docs, others}
        when attr in [:moduledoc, :doc, :typedoc, :shortdoc] ->
          {node, {collect(arg) ++ docs, others}}

        {:__block__, meta, [bin]} = node, {docs, others} when is_binary(bin) ->
          {node, {docs, [{bin, meta[:line]} | others]}}

        node, acc ->
          {node, acc}
      end)

    {Enum.reverse(docs), Enum.reverse(others)}
  end

  defp collect({:__block__, meta, [bin]}) when is_binary(bin), do: [{bin, meta[:line]}]

  defp collect({:<<>>, _, parts}) do
    for {:__block__, meta, [bin]} <- parts, is_binary(bin), do: {bin, meta[:line]}
  end

  defp collect({:<>, _, args}), do: Enum.flat_map(args, &collect/1)
  defp collect(_), do: []

  # -- fixtures --------------------------------------------------------------

  defp markers(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\b((?:REPORT|SILENT)-[a-z]+)\b/, line) do
        [_, marker] -> [marker]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp line_of(path, marker) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {text, line} -> if String.contains?(text, marker), do: line end)
    |> case do
      nil -> flunk("#{path} has no line marked #{marker}")
      line -> line
    end
  end

  defp dash_on?(path, marker) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(fn text -> String.contains?(text, marker) and dash?(text) end)
  end
end
