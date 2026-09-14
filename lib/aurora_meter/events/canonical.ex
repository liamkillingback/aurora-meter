defmodule AuroraMeter.Events.Canonical do
  @moduledoc """
  **Internal.** The canonical encoding behind `payload_hash` (core ADR 0009,
  decision 2). Not part of the supported surface.

  Build unit 03a lands the part the legacy backfill needs and nothing more:
  `canonical_json/1`, `encode/1` and `legacy_payload_hash/1`. Build unit 03b
  owns this module and extends it with the facade's validation, the caller-id
  rules (the `legacy:` and `track:` prefixes are reserved) and the hash of a
  freshly recorded event. Extend it there; do not write a second canonical form
  somewhere else, because two encodings of "the same payload" is exactly the
  defect the hash exists to detect.

  The tuple is fixed by ADR 0009:

      {feature_string, quantity, occurred_at_iso8601_usec, kind,
       original_event_id, canonical_json(dimensions), canonical_json(metadata)}

  It is encoded as a canonical JSON array, so the bytes are the same whatever
  language computes them and a hash can be reproduced by hand from a row.

  Canonical JSON sorts object keys by their encoded bytes, recursively, and
  refuses any term JSON cannot carry: an atom other than `true`, `false` and
  `nil`, a tuple, a pid, a non-string object key. Floats need no check: the
  BEAM has no NaN and no infinity.
  """

  @doc false
  @spec legacy_payload_hash(%{
          required(:feature) => String.t(),
          required(:quantity) => integer(),
          required(:occurred_at) => DateTime.t(),
          required(:metadata) => map()
        }) :: binary()
  def legacy_payload_hash(row) do
    row
    |> legacy_tuple()
    |> encode()
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc false
  @spec legacy_tuple(map()) :: tuple()
  def legacy_tuple(row) do
    {
      to_string(row.feature),
      row.quantity,
      iso8601_usec(row.occurred_at),
      "usage",
      nil,
      "{}",
      canonical_json(row.metadata || %{})
    }
  end

  @doc false
  @spec encode(tuple()) :: String.t()
  def encode(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> canonical_json()
  end

  @doc false
  @spec iso8601_usec(DateTime.t()) :: String.t()
  def iso8601_usec(%DateTime{} = instant) do
    instant
    |> DateTime.truncate(:microsecond)
    |> then(&%{&1 | microsecond: pad(&1.microsecond)})
    |> DateTime.to_iso8601()
  end

  @doc false
  @spec canonical_json(term()) :: String.t()
  def canonical_json(term), do: IO.iodata_to_binary(json(term))

  # Object keys are sorted by their encoded bytes, recursively, so two maps
  # that differ only in insertion order encode identically.
  defp json(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {key, value} -> {key(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))

    ["{", pairs |> Enum.map(fn {key, value} -> [key, ":", json(value)] end) |> intersperse(), "}"]
  end

  defp json(list) when is_list(list) do
    ["[", list |> Enum.map(&json/1) |> intersperse(), "]"]
  end

  defp json(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: Jason.encode_to_iodata!(value)

  defp json(nil), do: "null"

  # No finiteness guard: the BEAM has no NaN and no infinity, because the
  # operations that would produce one raise instead. There is nothing here to
  # refuse.
  defp json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp json(value) do
    raise ArgumentError,
          "a canonical payload holds only JSON-safe terms (strings, integers, finite " <>
            "floats, booleans, null, lists and maps with string keys), got: " <>
            inspect(value)
  end

  # A binary, not iodata: the sort below is a byte comparison of the encoded
  # keys, and Erlang's term order over iodata lists is not that.
  defp key(key) when is_binary(key), do: Jason.encode!(key)
  defp key(key) when is_atom(key) and not is_nil(key), do: Jason.encode!(to_string(key))

  defp key(key) do
    raise ArgumentError,
          "a canonical payload's object keys must be strings, got: #{inspect(key)}"
  end

  defp intersperse([]), do: []
  defp intersperse(parts), do: Enum.intersperse(parts, ",")

  # `{0, 0}` renders as no fractional part at all, which would make the hash of
  # an event that happened exactly on a second differ in shape from every other
  # one. Six digits always.
  defp pad({value, _precision}), do: {value, 6}
end
