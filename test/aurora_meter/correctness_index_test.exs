defmodule AuroraMeter.CorrectnessIndexTest do
  @moduledoc """
  The two-way check that keeps `docs/correctness.md` honest.

  An invariant may not be listed without a test, and a test may not claim an
  invariant without being listed. Both directions are needed: the first catches a
  rename or a deletion, the second catches an invariant test that is written and
  never indexed.

  The test set is read by parsing the sources under `test/`, not by module
  reflection. ExUnit only loads the files in the current run set, so
  `Code.ensure_loaded?/1` would make this file pass when it is run on its own,
  which is exactly how a developer checks it. Parsing is independent of the run
  set and of compilation order.

  It opens no database connection and starts no process, so it runs on the
  headless CI leg where no optional dependency is installed.
  """
  use ExUnit.Case, async: true

  @index_path "docs/correctness.md"
  @test_glob "test/**/*_test.exs"

  # Invariants this package owns, per docs/v1/build-plans/invariant-map.md.
  # I13, I14 and I15 are Pro's; I22 is the storefront's.
  @owned ~w(I01 I02 I03 I04 I05 I06 I07 I08 I09 I10 I11 I12 I16 I17 I18 I19 I20 I21)

  @fields ["Guarantee", "Prerequisites", "Known limits", "Tests", "Evidence"]

  @invariant_prefix ~r/^I\d\d /
  @heading ~r/^## (I\d\d) (.+)$/
  @field_line ~r/^\*\*([A-Za-z ]+)\.\*\*\s*(.*)$/
  @existing_bullet ~r/^- `([^`]+)` \/ `(.*)`$/
  @planned_bullet ~r/^- PLANNED \(([0-9]{2}[a-z])\): `([^`]+)` \/ `(.*)`$/
  @evidence ~r/^`(?:(?:core|pro|storefront):)?docs\/evidence\/v1\/[A-Za-z0-9._\/-]+\.md`$/

  describe "the index against the test tree" do
    test "every test named in docs/correctness.md exists exactly once in test/" do
      names = MapSet.new(tests().literal, &{&1.module, &1.full_name})

      missing =
        for section <- sections(),
            {:existing, module, name} <- section.bullets,
            not MapSet.member?(names, {module, name}),
            do: {section.id, module, name}

      assert missing == [], missing_message(missing, names)
    end

    test "every test whose description starts with an invariant id is named in the index" do
      indexed = MapSet.new(indexed_existing())

      orphans =
        for t <- tests().literal,
            Regex.match?(@invariant_prefix, t.description),
            not MapSet.member?(indexed, {t.module, t.full_name}),
            do: "#{t.module} / #{t.full_name}  (#{t.file}:#{t.line})"

      assert orphans == [],
             "these tests claim an invariant but are not listed in #{@index_path}:\n" <>
               Enum.map_join(orphans, "\n", &("  " <> &1))
    end

    test "a planned test bullet does not yet exist, and is promoted when it does" do
      names = MapSet.new(tests().literal, &{&1.module, &1.full_name})

      written =
        for section <- sections(),
            {{:planned, unit}, module, name} <- section.bullets,
            MapSet.member?(names, {module, name}),
            do: "#{section.id} (#{unit}): #{module} / #{name}"

      assert written == [],
             "these tests exist but are still marked PLANNED in #{@index_path}. Promote the " <>
               "bullet to the plain form in the same change that writes the test:\n" <>
               Enum.map_join(written, "\n", &("  " <> &1))
    end

    test "no invariant test description is interpolated" do
      offenders =
        for t <- tests().interpolated,
            Regex.match?(@invariant_prefix, t.description),
            do: "#{t.module}: #{t.description}... (#{t.file}:#{t.line})"

      assert offenders == [],
             "invariant test names must be literals, so the index can name them:\n" <>
               Enum.map_join(offenders, "\n", &("  " <> &1))
    end
  end

  describe "the shape of the index" do
    test "every invariant this package owns has a section with all five fields in order" do
      by_id = Map.new(sections(), &{&1.id, &1})

      for id <- @owned do
        section = Map.get(by_id, id)
        assert section, "#{@index_path} has no section for #{id}"
        assert section.field_order == @fields, "#{id} fields: #{inspect(section.field_order)}"
        assert field_problems(section) == []
      end
    end

    test "every invariant section names at least one test" do
      for section <- sections() do
        refute section.bullets == [], "#{section.id} has no test bullet"
      end
    end

    test "an invariant this package does not own has no section" do
      unowned = Enum.map(sections(), & &1.id) -- @owned

      assert unowned == [],
             "sections for invariants this package does not own: #{inspect(unowned)}"
    end

    test "the section order is ascending by invariant id and no id repeats" do
      ids = Enum.map(sections(), & &1.id)
      assert ids == Enum.sort(ids), "sections are out of order: #{inspect(ids)}"

      assert ids == Enum.uniq(ids),
             "an invariant has two sections: #{inspect(ids -- Enum.uniq(ids))}"
    end

    test "evidence paths are unique, repo-relative and under docs/evidence/v1/" do
      paths =
        for section <- sections() do
          value = String.trim(section.fields["Evidence"])
          assert Regex.match?(@evidence, value), "#{section.id}: bad evidence path #{value}"
          value
        end

      assert paths == Enum.uniq(paths), "two invariants claim the same evidence file"
    end
  end

  describe "the parser itself" do
    test "a section missing Known limits fails with the id and the missing field" do
      section = hd(parse_index(fixture("missing_field.md")))

      assert section.id == "I01"
      refute "Known limits" in section.field_order
      assert field_problems(section) == ["I01: Known limits is missing or empty"]
    end

    test "a test bullet whose module does not exist fails with the nearest match" do
      names = MapSet.new([{"AuroraMeter.FlusherTest", "test a lost response"}])

      message =
        missing_message([{"I01", "AuroraMeter.FlushrTest", "test a lost response"}], names)

      assert message =~ "AuroraMeter.FlushrTest"
      assert message =~ "nearest: AuroraMeter.FlusherTest / test a lost response"
    end

    test "a describe-wrapped test is matched by its full ExUnit name, not its bare description" do
      parsed = parse_source(fixture_path("describe_source.exs"))
      names = Enum.map(parsed.literal, & &1.full_name)

      assert "test grouped behaviour it holds" in names
      refute "test it holds" in names
      assert "test it stands alone" in names
      assert Enum.map(parsed.interpolated, & &1.description) == ["I09 "]
    end
  end

  # Every field except Tests carries its text on the field's own line, so an
  # empty or absent one is visible without reading the paragraph beneath it.
  defp field_problems(section) do
    for name <- @fields -- ["Tests"],
        String.trim(section.fields[name] || "") == "",
        do: "#{section.id}: #{name} is missing or empty"
  end

  # -- index parsing ---------------------------------------------------------

  defp sections, do: @index_path |> File.read!() |> parse_index()

  defp indexed_existing do
    for section <- sections(), {:existing, module, name} <- section.bullets, do: {module, name}
  end

  defp parse_index(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.reduce([], &collect_line/2)
    |> Enum.reverse()
    |> Enum.map(&finish_section/1)
  end

  defp collect_line(line, acc) do
    case {Regex.run(@heading, line), acc} do
      {[_, id, title], _} -> [%{id: id, title: title, lines: []} | acc]
      {nil, []} -> []
      {nil, [current | rest]} -> [%{current | lines: [line | current.lines]} | rest]
    end
  end

  defp finish_section(section) do
    lines = Enum.reverse(section.lines)
    declared = Enum.flat_map(lines, &field/1)

    %{
      id: section.id,
      title: section.title,
      field_order: Enum.map(declared, &elem(&1, 0)),
      fields: Map.new(declared),
      bullets: Enum.flat_map(lines, &bullet/1)
    }
  end

  defp field(line) do
    case Regex.run(@field_line, line) do
      [_, name, rest] when name in @fields -> [{name, rest}]
      _ -> []
    end
  end

  defp bullet(line) do
    cond do
      match = Regex.run(@planned_bullet, line) ->
        [_, unit, module, name] = match
        [{{:planned, unit}, module, name}]

      match = Regex.run(@existing_bullet, line) ->
        [_, module, name] = match
        [{:existing, module, name}]

      true ->
        []
    end
  end

  # -- test source parsing ---------------------------------------------------

  defp tests do
    @test_glob
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&parse_source/1)
    |> Enum.reduce(%{literal: [], interpolated: []}, fn parsed, acc ->
      %{
        literal: acc.literal ++ parsed.literal,
        interpolated: acc.interpolated ++ parsed.interpolated
      }
    end)
  end

  defp parse_source(path) do
    found =
      path
      |> quoted()
      |> walk(%{module: nil, describe: nil, file: path}, [])
      |> Enum.reverse()

    %{literal: Enum.filter(found, & &1.literal?), interpolated: Enum.reject(found, & &1.literal?)}
  end

  # A half-written test file would otherwise surface as a bare SyntaxError
  # pointing at this file's own line, which reads as a fault in the index.
  defp quoted(path) do
    case Code.string_to_quoted(File.read!(path), file: path) do
      {:ok, ast} ->
        ast

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: meta[:line], else: meta

        flunk(
          "#{@index_path} cannot be checked while #{path}:#{line} does not parse: " <>
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

  defp walk({kind, meta, [name | _]}, ctx, acc) when kind in [:test, :property] do
    [entry(kind, name, meta, ctx) | acc]
  end

  defp walk({_, _, args}, ctx, acc) when is_list(args) do
    Enum.reduce(args, acc, &walk(&1, ctx, &2))
  end

  defp walk({a, b}, ctx, acc), do: walk(b, ctx, walk(a, ctx, acc))
  defp walk(list, ctx, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, ctx, &2))
  defp walk(_other, _ctx, acc), do: acc

  defp entry(kind, name, meta, ctx) do
    literal? = is_binary(name)
    description = if literal?, do: name, else: leading_literal(name)

    %{
      module: ctx.module,
      describe: ctx.describe,
      description: description,
      full_name: full_name(kind, ctx.describe, description),
      literal?: literal?,
      file: ctx.file,
      line: meta[:line]
    }
  end

  defp full_name(kind, nil, description), do: "#{kind} #{description}"
  defp full_name(kind, describe, description), do: "#{kind} #{describe} #{description}"

  defp leading_literal({:<<>>, _, [head | _]}) when is_binary(head), do: head
  defp leading_literal(_other), do: ""

  # -- failure messages ------------------------------------------------------

  defp missing_message([], _names), do: ""

  defp missing_message(missing, names) do
    candidates = MapSet.to_list(names)

    body =
      Enum.map_join(missing, "\n", fn {id, module, name} ->
        "  #{id}: #{module} / #{name}\n" <>
          Enum.map_join(nearest(module, name, candidates), "\n", &("       nearest: " <> &1))
      end)

    "these tests are named in #{@index_path} but do not exist in test/:\n" <> body
  end

  defp nearest(module, name, candidates) do
    target = module <> " / " <> name

    candidates
    |> Enum.map(fn {m, n} -> m <> " / " <> n end)
    |> Enum.sort_by(&String.jaro_distance(target, &1), :desc)
    |> Enum.take(3)
  end

  # -- fixtures --------------------------------------------------------------

  defp fixture_path(name), do: Path.join("test/support/correctness_fixtures", name)
  defp fixture(name), do: name |> fixture_path() |> File.read!()
end
