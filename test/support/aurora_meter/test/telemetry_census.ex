defmodule AuroraMeter.Test.TelemetryCensus do
  @moduledoc """
  Every `:telemetry` emit site in a `lib/` tree, read out of the AST.

  ## Why not a regular expression

  The inventory guard used to find emit sites by grepping `lib/` for
  `:telemetry.execute(` followed by a **literal** `[:aurora_meter, ...]` list.
  That works until somebody writes `:telemetry.execute(@telemetry, ...)`, at
  which point the event becomes invisible: it cannot be documented, because
  adding the row makes the guard fail with "documented in docs/api.md but not
  emitted anywhere in lib/", and it cannot be found, because the regular
  expression has nothing to match. Two core events were undocumented for exactly
  that reason (`open-findings.md` X222), and the fix at the time was to contort
  three emit sites into literals, with a comment at each saying why.

  A guard that reads source **text** turns every abstraction it cannot see into
  a silent exemption. This one reads the parsed form instead: a module attribute
  is resolved to its value, a computed last segment is reported as a family, and
  a `:telemetry.span/3` is reported as a span. An emit site inside a `@moduledoc`
  is not an emit site, and the parser knows that natively rather than by
  stripping heredocs with another regular expression.

  It is deliberately a *source* census and not a runtime one. A runtime census
  can only see events something in the suite happened to emit, which is the
  wrong direction: the question is whether every site in the tree is documented,
  including the ones no test reaches.
  """

  @typedoc "One emit site."
  @type site :: %{
          path: String.t(),
          line: pos_integer(),
          event: [atom()],
          form: :execute | :span | :family,
          attribute: atom() | nil,
          measurements: [atom()] | :dynamic,
          metadata: [atom()] | :dynamic
        }

  @doc """
  Every emit site under `root`, sorted by path and line.
  """
  @spec sites(String.t()) :: [site()]
  def sites(root) do
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&sites_in/1)
  end

  @doc """
  The distinct `{event, form}` pairs under `root`.

  This is what a documentation guard compares against: two sites emitting the
  same event under the same form are one contract, not two.
  """
  @spec contracts(String.t()) :: [{[atom()], :execute | :span | :family}]
  def contracts(root) do
    root
    |> sites()
    |> Enum.map(&{&1.event, &1.form})
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Renders an event name the way `docs/api.md` and the catalogue spell it.

  A family's computed segment is written `:"<kind>"` in the catalogue and `kind`
  at the emit site; both render to the same string so the two can be compared.
  """
  @spec render([atom()]) :: String.t()
  def render(event) do
    "[" <> Enum.map_join(event, ", ", &render_segment/1) <> "]"
  end

  defp render_segment(segment) do
    name = Atom.to_string(segment)

    if String.starts_with?(name, "<") and String.ends_with?(name, ">") do
      String.slice(name, 1..-2//1)
    else
      inspect(segment)
    end
  end

  defp sites_in(path) do
    source = File.read!(path)

    case Code.string_to_quoted(source, columns: true) do
      {:ok, tree} ->
        attributes = attributes(tree)

        {_tree, sites} =
          Macro.prewalk(tree, [], fn
            {{:., _, [:telemetry, fun]}, meta, [name | rest]} = node, acc
            when fun in [:execute, :span] ->
              {node, [site(path, meta[:line], fun, name, rest, attributes) | acc]}

            node, acc ->
              {node, acc}
          end)

        sites |> Enum.reverse() |> Enum.reject(&is_nil/1)

      {:error, {meta, message, token}} ->
        raise "#{path}:#{meta[:line]} could not be parsed for the telemetry census: " <>
                "#{inspect(message)} #{inspect(token)}"
    end
  end

  # Only `@name value` forms, which is what a module attribute holding an event
  # name is. An accumulating attribute or one built by a function is reported
  # unresolved rather than guessed at.
  defp attributes(tree) do
    {_tree, acc} =
      Macro.prewalk(tree, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp site(path, line, fun, name, rest, attributes) do
    case resolve(name, attributes) do
      {:ok, event, form, attribute} ->
        %{
          path: path,
          line: line,
          event: event,
          form: form(fun, form),
          attribute: attribute,
          measurements: keys(Enum.at(rest, 0)),
          metadata: keys(Enum.at(rest, 1))
        }

      :error ->
        raise "#{path}:#{line} emits telemetry under a name this census cannot resolve. " <>
                "Use a literal list, or a module attribute assigned one in the same file: " <>
                "an event nothing can name is an event nothing can document."
    end
  end

  defp form(:span, _form), do: :span
  defp form(:execute, form), do: form

  defp resolve(list, _attributes) when is_list(list) do
    if Enum.all?(list, &is_atom/1) do
      {:ok, list, :execute, nil}
    else
      family(Enum.split(list, length(list) - 1))
    end
  end

  defp resolve({:@, _, [{name, _, context}]}, attributes)
       when is_atom(context) or is_nil(context) do
    case Map.fetch(attributes, name) do
      {:ok, value} ->
        case resolve(value, attributes) do
          {:ok, event, form, _} -> {:ok, event, form, name}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp resolve(_other, _attributes), do: :error

  # `[:aurora_meter, :credits, kind]`: every segment but the last is fixed, and
  # the last is computed. Anything else is a name nothing can write down.
  defp family({fixed, [computed]}) do
    if Enum.all?(fixed, &is_atom/1) do
      {:ok, fixed ++ [family_segment(computed)], :family, nil}
    else
      :error
    end
  end

  defp family(_other), do: :error

  # `[:aurora_meter, :credits, kind]` and `[:aurora_meter, :credits, txn.kind]`
  # are the same family; both become `:"<kind>"`.
  defp family_segment({var, _, context})
       when is_atom(var) and (is_atom(context) or is_nil(context)),
       do: :"<#{var}>"

  defp family_segment({{:., _, [_target, field]}, _, _}) when is_atom(field), do: :"<#{field}>"
  defp family_segment(other), do: :"<#{Macro.to_string(other)}>"

  # A literal map's keys. Anything else is `:dynamic`: the source cannot say,
  # and a guard that guessed would be asserting its guess.
  defp keys({:%{}, _, pairs}) when is_list(pairs) do
    if Enum.all?(pairs, &match?({key, _} when is_atom(key), &1)) do
      pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    else
      :dynamic
    end
  end

  defp keys(nil), do: []
  defp keys(_other), do: :dynamic
end
