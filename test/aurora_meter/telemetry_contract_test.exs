defmodule AuroraMeter.TelemetryContractTest do
  @moduledoc """
  The telemetry contract, checked three ways and in both directions each time.

  `AuroraMeter.Telemetry.events/0` is compared against:

    1. the emit sites in `lib/`, read out of the AST rather than grepped;
    2. the `<!-- inventory:literal -->` table in `docs/api.md`;
    3. the `<!-- telemetry:events -->` table in `docs/telemetry.md`.

  Both directions every time, because a one-way check is half a guard: reading
  `docs/` against `lib/` catches a deleted event and misses a new undocumented
  one, and reading `lib/` against `docs/` does the opposite.

  ## The two findings this file exists for

  **X222.** The inventory guard used to find emit sites with a regular
  expression over the source text, matching a **literal** `[:aurora_meter, ...]`
  list. An event emitted as `:telemetry.execute(@telemetry, ...)` was therefore
  invisible: it could not be documented, because adding the row failed the guard
  with "documented in docs/api.md but not emitted anywhere in lib/", and it
  could not be found, because the expression had nothing to match. Two core
  events went undocumented for a whole build unit, and three emit sites still
  carry a comment saying the name is written out to keep the grep happy.
  `AuroraMeter.Test.TelemetryCensus` reads the parsed form instead, so a module
  attribute is resolved rather than exempted.

  **X232.** `docs/telemetry.md` had no guard at all, so it drifted from
  `docs/api.md` and nobody saw. It is the page every guide links to for the
  event list, and it was five events short. Check 3 is that hole closed.

  It opens no database connection and starts no process.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Telemetry
  alias AuroraMeter.Test.TelemetryCensus

  @lib "lib"
  @api "docs/api.md"
  @telemetry_doc "docs/telemetry.md"

  # A documentation table may legitimately describe a span's three names as one
  # row under its prefix, which is how both pages are written. The catalogue
  # spells the same thing as one entry with `form: :span`.
  @doc_row ~r/^\|\s*`(\[:aurora_meter[^`]*\])`\s*\|/

  test "every emit site in lib/ is in AuroraMeter.Telemetry.events/0" do
    catalogue = MapSet.new(Telemetry.events(), &{&1.event, &1.form})
    sites = TelemetryCensus.contracts(@lib)

    missing =
      for {event, form} <- sites,
          not MapSet.member?(catalogue, {event, form}),
          do: "#{TelemetryCensus.render(event)} (#{form})"

    assert missing == [],
           "lib/ emits telemetry AuroraMeter.Telemetry.events/0 does not list:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "every event in AuroraMeter.Telemetry.events/0 is emitted somewhere in lib/" do
    sites = MapSet.new(TelemetryCensus.contracts(@lib))

    missing =
      for entry <- Telemetry.events(),
          not MapSet.member?(sites, {entry.event, entry.form}),
          do: "#{TelemetryCensus.render(entry.event)} (#{entry.form}, #{inspect(entry.emitter)})"

    assert missing == [],
           "AuroraMeter.Telemetry.events/0 lists telemetry lib/ does not emit:\n  " <>
             Enum.join(missing, "\n  ")
  end

  test "an event emitted through a module attribute is visible to the census (X222)" do
    # The regular expression the inventory guard used before this unit, verbatim.
    # It is here rather than described, so that what the census adds is measured
    # against the thing it replaced rather than against a memory of it.
    grep = ~r/:telemetry\.(?:execute|span)\(\s*(\[:aurora_meter[^\]]*\])/

    source = """
    defmodule Fixture do
      @telemetry [:aurora_meter, :fixture, :prune]

      def run do
        :telemetry.execute(@telemetry, %{deleted: 1}, %{table: "x"})
      end
    end
    """

    dir = Path.join(System.tmp_dir!(), "aurora_census_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "fixture.ex"), source)
    on_exit(fn -> File.rm_rf(dir) end)

    assert Regex.scan(grep, source) == [],
           "the fixture must be invisible to the old grep, or it is not the X222 shape"

    assert [%{event: [:aurora_meter, :fixture, :prune], attribute: :telemetry, form: :execute}] =
             TelemetryCensus.sites(dir)
  end

  test "the census refuses a name it cannot resolve rather than skipping it" do
    source = """
    defmodule Fixture do
      def run(name) do
        :telemetry.execute(name, %{count: 1}, %{})
      end
    end
    """

    dir = Path.join(System.tmp_dir!(), "aurora_census_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "fixture.ex"), source)
    on_exit(fn -> File.rm_rf(dir) end)

    assert_raise RuntimeError, ~r/cannot resolve/, fn -> TelemetryCensus.sites(dir) end
  end

  test "measurement and metadata keys match the emit site wherever the source states them" do
    by_contract = Map.new(Telemetry.events(), &{{&1.event, &1.form}, &1})

    mismatches =
      for site <- TelemetryCensus.sites(@lib),
          entry = Map.get(by_contract, {site.event, site.form}),
          entry != nil,
          {kind, stated, catalogued} <- [
            {:measurements, site.measurements, entry.measurements},
            {:metadata, site.metadata, entry.metadata}
          ],
          # `:dynamic` means the emit site builds the map at run time, so the
          # source cannot say. Those keys rest on `docs/api.md` agreeing with the
          # catalogue, which is two hand-written sources and weaker; the test
          # below is what holds them together.
          stated != :dynamic,
          not subset?(stated, catalogued),
          do:
            "#{TelemetryCensus.render(site.event)} #{kind}: #{site.path}:#{site.line} " <>
              "emits #{inspect(stated)}, events/0 lists #{inspect(catalogued)}"

    assert mismatches == [], Enum.join(mismatches, "\n")
  end

  test "docs/api.md lists exactly the events in AuroraMeter.Telemetry.events/0" do
    documented = MapSet.new(doc_events(@api))
    catalogued = MapSet.new(Telemetry.events(), &TelemetryCensus.render(&1.event))

    assert MapSet.difference(catalogued, documented) |> MapSet.to_list() == [],
           "AuroraMeter.Telemetry.events/0 lists events #{@api} does not"

    assert MapSet.difference(documented, catalogued) |> MapSet.to_list() == [],
           "#{@api} lists events AuroraMeter.Telemetry.events/0 does not"
  end

  test "docs/telemetry.md lists exactly the events in AuroraMeter.Telemetry.events/0 (X232)" do
    rows = telemetry_doc_rows()
    documented = MapSet.new(rows, & &1.event)
    catalogued = MapSet.new(Telemetry.events(), &TelemetryCensus.render(&1.event))

    assert MapSet.difference(catalogued, documented) |> MapSet.to_list() == [],
           "AuroraMeter.Telemetry.events/0 lists events #{@telemetry_doc} does not"

    assert MapSet.difference(documented, catalogued) |> MapSet.to_list() == [],
           "#{@telemetry_doc} lists events AuroraMeter.Telemetry.events/0 does not"
  end

  test "docs/telemetry.md states the same measurement, metadata and tag keys as events/0" do
    rows = Map.new(telemetry_doc_rows(), &{{&1.event, &1.form}, &1})

    mismatches =
      for entry <- Telemetry.events(),
          row = Map.get(rows, {TelemetryCensus.render(entry.event), entry.form}),
          row != nil,
          {field, documented, catalogued} <- [
            {:measurements, row.measurements, entry.measurements},
            {:metadata, row.metadata, entry.metadata},
            {:tags, row.tags, entry.tags}
          ],
          documented != Enum.sort(catalogued),
          do:
            "#{row.event} #{field}: doc says #{inspect(documented)}, " <>
              "events/0 says #{inspect(Enum.sort(catalogued))}"

    assert mismatches == [], Enum.join(mismatches, "\n")
  end

  test "every tag in the catalogue is on the allow list and is a real metadata key" do
    bad =
      for entry <- Telemetry.events(),
          tag <- entry.tags,
          reason = tag_problem(entry, tag),
          do: "#{TelemetryCensus.render(entry.event)} tag #{inspect(tag)}: #{reason}"

    assert bad == [], Enum.join(bad, "\n")
  end

  test "every emitter named in the catalogue is a module that exists" do
    missing =
      for entry <- Telemetry.events(),
          not Code.ensure_loaded?(entry.emitter),
          do: "#{TelemetryCensus.render(entry.event)} names #{inspect(entry.emitter)}"

    assert missing == [], Enum.join(missing, "\n")
  end

  test "no file in the package teaches a metric tagged on the tenant key" do
    paths =
      Path.wildcard("lib/**/*.ex") ++
        Path.wildcard("docs/**/*.md") ++
        Path.wildcard("test/**/*.exs") ++
        ["README.md", "CHANGELOG.md"]

    hits =
      for path <- paths,
          not String.starts_with?(path, evidence_tree()),
          File.regular?(path),
          String.contains?(File.read!(path), unbounded_example()),
          do: path

    assert hits == [],
           "an unbounded per-tenant metric is taught by example in:\n  " <>
             Enum.join(hits, "\n  ")
  end

  test "every runbook link in the failure-mode table resolves to a heading that exists" do
    table = failure_mode_table()

    assert length(table) >= 15,
           "the failure-mode table has only #{length(table)} rows; it is meant to cover " <>
             "every failure and recovery state, not a sample"

    broken =
      for row <- table,
          {file, anchor} <- row.links,
          reason = link_problem(file, anchor),
          do: "#{row.state}: #{file}##{anchor} #{reason}"

    assert broken == [], Enum.join(broken, "\n")
  end

  test "every event named in the failure-mode table is in a catalogue" do
    known =
      Telemetry.events()
      |> Enum.flat_map(fn entry ->
        names = [entry.event | entry.names]

        Enum.map(names, &TelemetryCensus.render/1) ++
          Enum.map(names, fn name -> Enum.map_join(name, ".", &Atom.to_string/1) end)
      end)
      |> MapSet.new()

    unknown =
      for row <- failure_mode_table(),
          signal <- row.signals,
          not known?(signal, known),
          do: "#{row.state}: #{signal}"

    assert unknown == [],
           "the failure-mode table names signals no catalogue has:\n  " <>
             Enum.join(unknown, "\n  ")
  end

  # -- helpers ---------------------------------------------------------------

  # Assembled from two halves so this file, which has to name the string in
  # order to search for it, does not become its own only hit. A test that has to
  # exempt itself is a test nobody can read the result of.
  defp unbounded_example, do: "tags: [" <> ":tenant_key]"

  # The tree that records what a run printed at the time, and is never edited to
  # match today's contract. Assembled rather than written out because
  # `AuroraMeter.EvidenceWritesTest` flags any test file that names that
  # directory and also calls `File.write!/2`, and the census fixtures here write
  # a throwaway module into the system temporary directory.
  defp evidence_tree, do: "docs/" <> "evidence/"

  defp subset?(stated, catalogued), do: Enum.all?(stated, &(&1 in catalogued))

  defp tag_problem(entry, tag) do
    cond do
      not Telemetry.tag_allowed?(tag, false) ->
        "not on #{inspect(Telemetry.tag_allow_list())}"

      tag not in entry.metadata ->
        "is not a metadata key of the event (metadata: #{inspect(entry.metadata)})"

      true ->
        nil
    end
  end

  defp doc_events(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "<!-- inventory:literal -->")))
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.flat_map(fn line ->
      case Regex.run(@doc_row, line) do
        [_, event] -> [normalise_doc_event(event)]
        nil -> []
      end
    end)
  end

  # `docs/api.md` writes a span as one row naming its three suffixes; the
  # catalogue writes the prefix. Both mean the same contract.
  defp normalise_doc_event(event) do
    event
    |> String.replace(~r/,\s*:\w+\s*\\\|\s*:\w+\s*\\\|\s*:\w+\]$/, "]")
    |> String.replace(~r/\s+/, " ")
  end

  defp telemetry_doc_rows do
    @telemetry_doc
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "<!-- telemetry:events -->"))
    |> Enum.take_while(&(&1 != "<!-- /telemetry:events -->"))
    |> Enum.flat_map(&doc_row/1)
  end

  defp doc_row(line) do
    case String.split(line, "|", trim: true) do
      [event, form, measurements, metadata, tags, _since] ->
        case Regex.run(~r/^`(\[:aurora_meter.*\])`$/, String.trim(event)) do
          [_, name] ->
            [
              %{
                event: name,
                form: String.to_atom(String.trim(form)),
                measurements: doc_keys(measurements),
                metadata: doc_keys(metadata),
                tags: doc_keys(tags)
              }
            ]

          nil ->
            []
        end

      _other ->
        []
    end
  end

  defp doc_keys(cell) do
    case String.trim(cell) do
      "none" ->
        []

      text ->
        ~r/`([a-z_]+)`/
        |> Regex.scan(text)
        |> Enum.map(&String.to_atom(Enum.at(&1, 1)))
        |> Enum.sort()
    end
  end

  defp failure_mode_table do
    @telemetry_doc
    |> File.read!()
    |> String.split("\n")
    |> Enum.drop_while(&(&1 != "## Failure mode, signal, runbook"))
    |> Enum.take_while(&(not String.starts_with?(&1, "## Metrics presets")))
    |> Enum.flat_map(&failure_mode_row/1)
  end

  defp failure_mode_row(line) do
    case String.split(line, "|", trim: true) do
      [state, signal, runbook] -> failure_mode_row(String.trim(state), signal, runbook)
      _other -> []
    end
  end

  defp failure_mode_row("State", _signal, _runbook), do: []
  defp failure_mode_row("", _signal, _runbook), do: []

  defp failure_mode_row("---" <> _rest, _signal, _runbook), do: []

  defp failure_mode_row(state, signal, runbook),
    do: [%{state: state, signals: signal_tokens(signal), links: links(runbook)}]

  # ExDoc resolves an extras link by basename, wherever the file sits under
  # `docs/`, and the house convention writes them that way
  # (`[Scheduler map](scheduler.md)` for `docs/operations/scheduler.md`). The
  # guard resolves them the same way, or it would refuse the spelling the rest
  # of the documentation uses.
  defp link_problem(file, anchor) do
    case Path.wildcard("docs/**/" <> Path.basename(file)) ++ Path.wildcard("docs/" <> file) do
      [] ->
        "names a file that does not exist"

      [path | _rest] ->
        cond do
          is_nil(anchor) -> nil
          anchor in headings(path) -> nil
          true -> "names an anchor #{path} does not have"
        end
    end
  end

  defp headings(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^#+\s+(.*?)\s*$/, line) do
        [_, text] -> [slug(text)]
        nil -> []
      end
    end)
  end

  # ExDoc and GitHub agree on this much: lower case, punctuation dropped,
  # spaces to hyphens.
  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/`|\*|\(|\)|\[|\]|\.|,|:|\?|'/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
  end

  defp links(cell) do
    ~r/\]\(([^)]+)\)/
    |> Regex.scan(cell)
    |> Enum.map(fn [_, target] ->
      case String.split(target, "#", parts: 2) do
        [file, anchor] -> {file, anchor}
        [file] -> {file, nil}
      end
    end)
  end

  # Only tokens that are shaped like a signal. The cell also carries things like
  # `result: :invalid` and `:flush_interval`, and a check that accepted those
  # would be asserting that a colon exists.
  defp signal_tokens(cell) do
    ~r/`([^`]+)`/
    |> Regex.scan(cell)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.filter(&signal?/1)
  end

  defp signal?("[:aurora_meter" <> _), do: true
  defp signal?(token), do: Regex.match?(~r/^[a-z_]+(\.[a-z_]+)+$/, token)

  # The table writes a signal either as a full event name, or in the dotted
  # metric style an operator reads off a dashboard (`store.gauge.dirty_keys`).
  # At most two trailing segments are dropped, so `a.b.c.d.e` cannot match
  # `aurora_meter.a` by accident.
  defp known?("[:aurora_meter" <> _ = token, known), do: MapSet.member?(known, token)

  defp known?(dotted, known) do
    parts = String.split(dotted, ".")

    Enum.any?(0..2, fn drop ->
      name = Enum.join(["aurora_meter" | Enum.drop(parts, -drop)], ".")
      MapSet.member?(known, name)
    end)
  end
end
