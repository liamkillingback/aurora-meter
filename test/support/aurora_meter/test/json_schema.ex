defmodule AuroraMeter.Test.JsonSchema do
  @moduledoc """
  The subset of JSON Schema `priv/bench/report.schema.json` actually uses.

  A dependency was deliberately not added for this. The schema is a **test
  fixture**: it exists so a reviewer can read the contract of a bench record in
  one place and so a test can fail when a record stops matching it, and a
  runtime dependency for that would be shipped to every host of a metering
  library.

  Supported: `type` (including a list of types and `"null"`), `const`, `enum`,
  `required`, `properties`, `items`. Anything else in a schema document is
  **refused**, loudly, rather than ignored: a validator that silently skips the
  keyword you were relying on is worse than no validator, because it reports a
  pass (`open-findings.md` X325).
  """

  @known ~w(type const enum required properties items $schema title description)

  @doc """
  Validates `data` against `schema`. Answers `:ok` or `{:error, [message]}`.

  `path` is prefixed to every message so a failure names the field.
  """
  @spec validate(term(), map(), String.t()) :: :ok | {:error, [String.t()]}
  def validate(data, schema, path \\ "$") do
    unknown = Map.keys(schema) -- @known

    if unknown != [] do
      raise "AuroraMeter.Test.JsonSchema does not implement #{inspect(unknown)} at #{path}. " <>
              "Implement it or stop using it; a skipped keyword is a silent pass."
    end

    case Enum.flat_map(@known, &check(&1, Map.get(schema, &1, :absent), data, schema, path)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check(_keyword, :absent, _data, _schema, _path), do: []

  defp check(keyword, _value, _data, _schema, _path)
       when keyword in ~w($schema title description), do: []

  defp check("type", types, data, _schema, path) do
    types = List.wrap(types)
    if Enum.any?(types, &matches_type?(&1, data)), do: [], else: [type_error(path, types, data)]
  end

  defp check("const", value, data, _schema, path) do
    if data == value, do: [], else: ["#{path}: expected #{inspect(value)}, got #{inspect(data)}"]
  end

  defp check("enum", values, data, _schema, path) do
    if data in values,
      do: [],
      else: ["#{path}: expected one of #{inspect(values)}, got #{inspect(data)}"]
  end

  defp check("required", keys, data, _schema, path) when is_map(data) do
    Enum.flat_map(keys, fn key ->
      if Map.has_key?(data, key), do: [], else: ["#{path}: missing required key #{inspect(key)}"]
    end)
  end

  defp check("required", _keys, _data, _schema, _path), do: []

  defp check("properties", properties, data, _schema, path) when is_map(data) do
    Enum.flat_map(properties, fn {key, subschema} -> property(data, key, subschema, path) end)
  end

  defp check("properties", _properties, _data, _schema, _path), do: []

  defp check("items", subschema, data, _schema, path) when is_list(data) do
    data
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      errors(validate(item, subschema, "#{path}[#{index}]"))
    end)
  end

  defp check("items", _subschema, _data, _schema, _path), do: []

  # A property that is ABSENT is not checked here: `required` is what says a key
  # has to be there, and doubling that up would report one missing field twice
  # and with two different messages.
  defp property(data, key, subschema, path) do
    case Map.fetch(data, key) do
      {:ok, value} -> errors(validate(value, subschema, "#{path}.#{key}"))
      :error -> []
    end
  end

  defp errors(:ok), do: []
  defp errors({:error, errors}), do: errors

  defp matches_type?("null", data), do: is_nil(data)
  defp matches_type?("boolean", data), do: is_boolean(data)
  defp matches_type?("string", data), do: is_binary(data)
  defp matches_type?("integer", data), do: is_integer(data)
  defp matches_type?("number", data), do: is_number(data)
  defp matches_type?("array", data), do: is_list(data)
  defp matches_type?("object", data), do: is_map(data)

  defp type_error(path, types, data) do
    "#{path}: expected #{Enum.join(types, " or ")}, got #{inspect(data)}"
  end
end
