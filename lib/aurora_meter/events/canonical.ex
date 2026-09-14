defmodule AuroraMeter.Events.Canonical do
  @moduledoc """
  **Internal.** The canonical encoding behind `payload_hash` (core ADR 0009,
  decision 2), and the validation every durable write passes before it is
  allowed near a connection. Not part of the supported surface.

  Build unit 03a landed the part the legacy backfill needs:
  `canonical_json/1`, `encode/1` and `legacy_payload_hash/1`. Build unit 03b
  owns this module and added the facade's validation, the caller-id rules and
  `payload_hash/1` for a freshly recorded event. There is one canonical form
  and it lives here; two encodings of "the same payload" is exactly the defect
  the hash exists to detect.

  The tuple is fixed by ADR 0009:

      {feature_string, quantity, occurred_at_iso8601_usec, kind,
       original_event_id, canonical_json(dimensions), canonical_json(metadata)}

  It is encoded as a canonical JSON array, so the bytes are the same whatever
  language computes them and a hash can be reproduced by hand from a row. JSON
  is self-delimiting: every element is quoted and escaped, so no field value
  can impersonate the separator between two elements. `encode/1` is fixed by
  the hashes 03a's backfill has already written; it cannot be changed without
  invalidating every `payload_hash` in every database that has run the V7
  backfill.

  Canonical JSON sorts object keys by their encoded bytes, recursively, and
  refuses any term JSON cannot carry: an atom other than `true`, `false` and
  `nil`, a tuple, a pid, a non-string object key. Floats need no check: the
  BEAM has no NaN and no infinity.

  ## Validation

  `validate/1` runs before the gate and before a connection is checked out, so
  a malformed request costs nothing but CPU. It accumulates every failure it
  finds rather than stopping at the first, because a caller fixing a payload
  wants the whole list. Sizes are measured on the **JSON text** the caller is
  sending, with `byte_size/1`, never on what Postgres would store: a
  compressible payload of any size passes a stored-size test
  (`open-findings.md` X104), and the limit is a promise about the request.
  """

  alias AuroraMeter.Clock

  @id_limit 128
  @reserved_id_prefixes ["legacy:", "track:", "recurring:"]
  @dimension_count_limit 32
  @dimension_key_limit 64
  @dimension_value_limit 256
  @metadata_limit 16 * 1024
  @quantity_max 9_223_372_036_854_775_807
  @batch_limit 500
  @batch_bytes_limit 1024 * 1024

  @typedoc "One validation failure: the field that failed and why."
  @type error :: {atom(), atom()}

  @typedoc "One validation failure inside a batch, with the element's index."
  @type indexed_error :: {non_neg_integer(), atom(), atom()}

  @typedoc """
  What `validate_correction/1` accepts.

  A correction states three things and inherits the rest: its own caller id,
  the id of the event it reduces, and the magnitude of the reduction. `:metadata`
  is the reason, a ticket reference or an operator id. `:quantity` is
  `:remaining` for `AuroraMeter.replace/4`, whose magnitude is not known until
  the original is read under lock.

  `:dimensions` and `:occurred_at` appear here only so that a caller who sends
  one is told to use `AuroraMeter.replace/4` rather than silently ignored.
  """
  @type correction_draft :: %{
          required(:tenant_key) => term(),
          required(:id) => term(),
          required(:original_event_id) => term(),
          required(:quantity) => term(),
          optional(:metadata) => term(),
          optional(:dimensions) => term(),
          optional(:occurred_at) => term()
        }

  @typedoc "What `validate/1` accepts."
  @type draft :: %{
          required(:tenant_key) => term(),
          required(:feature) => atom(),
          required(:quantity) => term(),
          required(:id) => term(),
          required(:occurred_at) => term(),
          optional(:dimensions) => term(),
          optional(:metadata) => term(),
          optional(:kind) => :usage | :correction,
          optional(:original_event_id) => String.t() | nil,
          optional(:future_tolerance) => non_neg_integer(),
          optional(:now) => DateTime.t()
        }

  @doc "The largest caller `event_id`, in bytes."
  @spec id_limit() :: pos_integer()
  def id_limit, do: @id_limit

  @doc "Caller-id prefixes the library reserves for rows it writes itself."
  @spec reserved_id_prefixes() :: [String.t()]
  def reserved_id_prefixes, do: @reserved_id_prefixes

  @doc "The largest `metadata` a caller may send, measured as JSON text in bytes."
  @spec metadata_limit() :: pos_integer()
  def metadata_limit, do: @metadata_limit

  @doc "The most elements one `AuroraMeter.record_batch/2` call may carry."
  @spec batch_limit() :: pos_integer()
  def batch_limit, do: @batch_limit

  @doc "The largest total encoded payload one batch may carry, in bytes."
  @spec batch_bytes_limit() :: pos_integer()
  def batch_bytes_limit, do: @batch_bytes_limit

  @doc "The largest `quantity` a single event may carry."
  @spec quantity_max() :: pos_integer()
  def quantity_max, do: @quantity_max

  @doc """
  Validates one draft event and returns the canonical form of it.

  The returned map carries the exact values that will be hashed and stored:
  `occurred_at` truncated to the microsecond the column holds, `dimensions` and
  `metadata` as given, their canonical JSON, the byte size of that JSON, and
  the `payload_hash` over the whole tuple.

  Every failure is `{field, reason}`, in validation order.
  """
  @spec validate(draft()) :: {:ok, map()} | {:error, [error()]}
  def validate(draft) when is_map(draft) do
    case Enum.reverse(collect_errors(draft)) do
      [] -> {:ok, canonicalise(draft)}
      errors -> {:error, errors}
    end
  end

  @doc """
  Validates a list of drafts, then collapses repeated ids.

  Returns `{:ok, entries, plan}` where `entries` are the distinct events to
  insert, in input order of first appearance, and `plan` maps every input index
  to the index in `entries` whose outcome it takes. Repeated ids with equal
  payload hashes collapse; repeated ids with different hashes are an error, and
  so is a batch that is too long or too large. Nothing here touches a
  connection.
  """
  @spec validate_batch([draft()]) ::
          {:ok, [map()], [non_neg_integer()]} | {:error, [indexed_error()]}
  def validate_batch(drafts) when is_list(drafts) do
    with :ok <- check_batch_length(drafts),
         {:ok, validated} <- validate_each(drafts),
         :ok <- check_batch_bytes(validated) do
      collapse(validated)
    end
  end

  @doc """
  Validates one correction draft and returns the part of it a correction states.

  A correction is **not** a payload in its own right: its feature, its
  occurrence instant and its dimensions are the original's, and they are not
  known until the original row has been read. So this returns only what the
  caller supplied, and `correction_hash/3` computes the hash afterwards, inside
  the transaction that holds the original under lock.

  Passing `:dimensions` or `:occurred_at` is refused rather than ignored:
  changing either is what `AuroraMeter.replace/4` exists for, and accepting them
  here would be a second way to do it with weaker guarantees.

  ## Examples

      iex> AuroraMeter.Events.Canonical.validate_correction(%{
      ...>   tenant_key: "org_1", id: "c1", original_event_id: "e1", quantity: 0
      ...> })
      {:error, [quantity: :not_a_positive_integer]}

  """
  @spec validate_correction(correction_draft()) :: {:ok, map()} | {:error, [error()]}
  def validate_correction(draft) when is_map(draft) do
    case Enum.reverse(collect_correction_errors(draft)) do
      [] ->
        {:ok,
         %{
           tenant_key: draft.tenant_key,
           event_id: draft.id,
           original_event_id: draft.original_event_id,
           quantity: draft.quantity,
           metadata: Map.get(draft, :metadata) || %{}
         }}

      errors ->
        {:error, errors}
    end
  end

  @doc """
  The sha256 of a correction's canonical payload.

  It is the **same** tuple `payload_hash/1` computes for a usage event, with
  the two fields a correction fills: `kind` is `"correction"` and
  `original_event_id` names the fact being reduced. `feature`, `occurred_at`
  and `dimensions` come from the original, which is why this takes the original
  rather than a draft (`architecture-map.md` 4.2, and `open-findings.md` X110:
  the encoding a shipped migration has already written is immutable, so a
  correction reuses it and never re-encodes it).

  `original` is any map carrying `:feature`, `:event_id`, `:occurred_at` and
  `:dimensions`, which both a `t:AuroraMeter.Schema.Event.t/0` row and an
  `t:AuroraMeter.Event.t/0` struct are.
  """
  @spec correction_hash(map(), pos_integer(), map()) :: binary()
  def correction_hash(original, quantity, metadata) do
    payload_hash(%{
      feature: original.feature,
      quantity: quantity,
      occurred_at: original.occurred_at,
      kind: :correction,
      original_event_id: original.event_id,
      dimensions: original.dimensions || %{},
      metadata: metadata || %{}
    })
  end

  @doc """
  The sha256 of the canonical tuple for one validated (or read back) event.

  Accepts a map carrying `feature`, `quantity`, `occurred_at`, `kind`,
  `original_event_id`, `dimensions` and `metadata`. `feature` may be an atom or
  a string and `kind` an atom or a string, so the same function hashes a
  request and a row read back out of Postgres.
  """
  @spec payload_hash(map()) :: binary()
  def payload_hash(attrs) when is_map(attrs) do
    attrs |> tuple() |> encode() |> then(&:crypto.hash(:sha256, &1))
  end

  @doc "The canonical tuple for one event, as ADR 0009 fixes it."
  @spec tuple(map()) :: tuple()
  def tuple(attrs) when is_map(attrs) do
    {
      to_string(attrs.feature),
      attrs.quantity,
      iso8601_usec(attrs.occurred_at),
      kind_string(Map.get(attrs, :kind, :usage)),
      Map.get(attrs, :original_event_id),
      canonical_json(Map.get(attrs, :dimensions) || %{}),
      canonical_json(Map.get(attrs, :metadata) || %{})
    }
  end

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

  @doc """
  `canonical_json/1` without the raise: `{:error, reason}` for a term JSON
  cannot carry.
  """
  @spec safe_canonical_json(term()) ::
          {:ok, String.t()} | {:error, :non_string_key | :not_json_safe}
  def safe_canonical_json(term) do
    if string_keys?(term) do
      {:ok, canonical_json(term)}
    else
      {:error, :non_string_key}
    end
  rescue
    # Any term JSON cannot carry: an atom, a tuple, a pid, a reference, a
    # function (`ArgumentError` from `json/1`), or a binary that is not valid
    # UTF-8 (`Jason.EncodeError`). Both are the same answer to the caller.
    _error -> {:error, :not_json_safe}
  end

  @doc """
  Whether every object key in `term`, at every depth, is a binary.

  Atom keys are refused rather than stringified: `%{"a" => 1}` and `%{a: 1}`
  would otherwise be the same payload, and a caller who changed one into the
  other would never learn that the identity they retried under now means
  something else.
  """
  @spec string_keys?(term()) :: boolean()
  def string_keys?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and string_keys?(value) end)
  end

  def string_keys?(list) when is_list(list), do: Enum.all?(list, &string_keys?/1)
  def string_keys?(_other), do: true

  # -- validation ------------------------------------------------------------

  defp collect_errors(draft) do
    []
    |> check_tenant(draft)
    |> check_feature(draft)
    |> check_quantity(draft)
    |> check_id(draft)
    |> check_occurred_at(draft)
    |> check_dimensions(draft)
    |> check_metadata(draft)
  end

  defp collect_correction_errors(draft) do
    []
    |> check_tenant(draft)
    |> check_correction_quantity(draft)
    |> check_id(draft)
    |> check_original(draft)
    |> check_metadata(draft)
    |> refuse_option(draft, :dimensions)
    |> refuse_option(draft, :occurred_at)
  end

  # `:remaining` is `AuroraMeter.replace/4`'s magnitude and is resolved inside
  # the transaction. It is not reachable from `AuroraMeter.correct/4`:
  # `AuroraMeter.Events.correct/4` turns anything that is not an integer into
  # `nil` before it gets here, so a caller who passes the atom is told
  # `:not_a_positive_integer` like any other non-integer.
  defp check_correction_quantity(errors, %{quantity: :remaining}), do: errors
  defp check_correction_quantity(errors, draft), do: check_quantity(errors, draft)

  defp check_original(errors, draft) do
    case Map.get(draft, :original_event_id) do
      nil -> [{:original, :missing} | errors]
      id when not is_binary(id) -> [{:original, :not_a_binary} | errors]
      "" -> [{:original, :empty} | errors]
      id when byte_size(id) > @id_limit -> [{:original, :too_long} | errors]
      _id -> errors
    end
  end

  # Refused, not ignored. A caller who sends `dimensions:` to `correct/4` means
  # to change them, and silently keeping the original's would record something
  # the caller did not ask for under an identity they chose.
  defp refuse_option(errors, draft, field) do
    if Map.has_key?(draft, field) and not is_nil(Map.get(draft, field)) do
      [{field, :not_supported_on_correction} | errors]
    else
      errors
    end
  end

  defp check_tenant(errors, %{tenant_key: key}) when is_binary(key) and key != "", do: errors
  defp check_tenant(errors, _draft), do: [{:tenant, :empty} | errors]

  # A binary feature is an `ArgumentError` from `AuroraMeter.feature!/1` before
  # this is reached (02b's rule); what is left to refuse here is a missing one.
  defp check_feature(errors, %{feature: feature}) when is_atom(feature) and not is_nil(feature),
    do: errors

  defp check_feature(errors, _draft), do: [{:feature, :missing} | errors]

  defp check_quantity(errors, %{quantity: quantity}) when is_integer(quantity) do
    cond do
      quantity < 1 -> [{:quantity, :not_a_positive_integer} | errors]
      quantity > @quantity_max -> [{:quantity, :out_of_range} | errors]
      true -> errors
    end
  end

  defp check_quantity(errors, _draft), do: [{:quantity, :not_a_positive_integer} | errors]

  defp check_id(errors, draft) do
    case Map.get(draft, :id) do
      nil ->
        [{:id, :missing} | errors]

      id when not is_binary(id) ->
        [{:id, :not_a_binary} | errors]

      "" ->
        [{:id, :empty} | errors]

      id ->
        cond do
          not String.valid?(id) -> [{:id, :not_utf8} | errors]
          byte_size(id) > @id_limit -> [{:id, :too_long} | errors]
          reserved_prefix?(id) -> [{:id, :reserved_prefix} | errors]
          true -> errors
        end
    end
  end

  defp reserved_prefix?(id), do: Enum.any?(@reserved_id_prefixes, &String.starts_with?(id, &1))

  defp check_occurred_at(errors, draft) do
    case Map.get(draft, :occurred_at) do
      nil ->
        [{:occurred_at, :missing} | errors]

      %DateTime{time_zone: "Etc/UTC"} = instant ->
        check_future(errors, draft, instant)

      %DateTime{} ->
        [{:occurred_at, :not_utc} | errors]

      _other ->
        [{:occurred_at, :not_a_datetime} | errors]
    end
  end

  # `occurred_at` is a value the CALLER supplied, so the other side of this
  # comparison is the node clock and not `Clock.db_now/0`: both sides come from
  # the same clock, and which one follows from where the other side came from
  # (`architecture-map.md` section 3). The tolerance is 300 seconds by default,
  # which is minutes rather than seconds, so a bounded backwards step in the
  # node clock cannot invert it (finding X100).
  defp check_future(errors, draft, instant) do
    now = Map.get_lazy(draft, :now, &Clock.now/0)
    tolerance = Map.get(draft, :future_tolerance, 300)

    if DateTime.diff(instant, now) > tolerance do
      [{:occurred_at, :future} | errors]
    else
      errors
    end
  end

  defp check_dimensions(errors, draft) do
    case Map.get(draft, :dimensions) || %{} do
      map when is_map(map) and not is_struct(map) -> dimension_errors(errors, map)
      _other -> [{:dimensions, :not_a_map} | errors]
    end
  end

  defp dimension_errors(errors, map) do
    errors
    |> then(fn acc ->
      if map_size(map) > @dimension_count_limit,
        do: [{:dimensions, :too_many_keys} | acc],
        else: acc
    end)
    |> then(&Enum.reduce(map, &1, fn pair, acc -> dimension_pair(pair, acc) end))
  end

  defp dimension_pair({key, _value}, errors) when not is_binary(key) do
    add_once(errors, {:dimensions, :non_string_key})
  end

  defp dimension_pair({key, value}, errors) do
    errors
    |> then(fn acc ->
      if byte_size(key) > @dimension_key_limit,
        do: add_once(acc, {:dimensions, :key_too_long}),
        else: acc
    end)
    |> dimension_value(value)
  end

  defp dimension_value(errors, value) when is_binary(value) do
    if byte_size(value) > @dimension_value_limit,
      do: add_once(errors, {:dimensions, :value_too_long}),
      else: errors
  end

  defp dimension_value(errors, value)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) do
    case safe_canonical_json(value) do
      {:ok, json} when byte_size(json) <= @dimension_value_limit -> errors
      {:ok, _json} -> add_once(errors, {:dimensions, :value_too_long})
      {:error, reason} -> add_once(errors, {:dimensions, reason})
    end
  end

  defp dimension_value(errors, _value), do: add_once(errors, {:dimensions, :non_scalar_value})

  defp check_metadata(errors, draft) do
    case Map.get(draft, :metadata) || %{} do
      map when is_map(map) and not is_struct(map) -> metadata_errors(errors, map)
      _other -> [{:metadata, :not_a_map} | errors]
    end
  end

  defp metadata_errors(errors, map) do
    case safe_canonical_json(map) do
      {:ok, json} when byte_size(json) <= @metadata_limit ->
        errors

      {:ok, _json} ->
        [{:metadata, :too_large} | errors]

      {:error, :non_string_key} ->
        [{:metadata, :non_string_key} | errors]

      {:error, :not_json_safe} ->
        [{:metadata, :not_json_encodable} | errors]
    end
  end

  defp add_once(errors, error), do: if(error in errors, do: errors, else: [error | errors])

  # -- canonical form --------------------------------------------------------

  # `occurred_at` is stored in a `timestamp(6)` column and hashed at six
  # digits, so the canonical value carries six digits whatever the caller sent.
  # Truncating alone is not enough: `~U[2026-08-31 00:00:00Z]` has precision 0,
  # which Ecto refuses for a `:utc_datetime_usec` field, and `{0, 0}` renders
  # with no fractional part at all, which would give an event that happened
  # exactly on a second a differently shaped hash from every other one.
  defp canonicalise(draft) do
    occurred_at =
      draft.occurred_at
      |> DateTime.truncate(:microsecond)
      |> then(&%{&1 | microsecond: pad(&1.microsecond)})

    dimensions = Map.get(draft, :dimensions) || %{}
    metadata = Map.get(draft, :metadata) || %{}
    kind = Map.get(draft, :kind, :usage)

    attrs = %{
      tenant_key: draft.tenant_key,
      feature: draft.feature,
      quantity: draft.quantity,
      event_id: draft.id,
      occurred_at: occurred_at,
      kind: kind,
      original_event_id: Map.get(draft, :original_event_id),
      dimensions: dimensions,
      metadata: metadata
    }

    dimensions_json = canonical_json(dimensions)
    metadata_json = canonical_json(metadata)

    Map.merge(attrs, %{
      payload_hash: payload_hash(attrs),
      payload_bytes: byte_size(dimensions_json) + byte_size(metadata_json)
    })
  end

  # -- batches ---------------------------------------------------------------

  defp check_batch_length(drafts) do
    if length(drafts) > @batch_limit do
      {:error, [{@batch_limit, :batch, :too_many_events}]}
    else
      :ok
    end
  end

  defp validate_each(drafts) do
    {validated, errors} =
      drafts
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {draft, index}, {oks, errors} ->
        case validate(draft) do
          {:ok, entry} ->
            {[Map.put(entry, :index, index) | oks], errors}

          {:error, list} ->
            {oks, Enum.reduce(list, errors, &[{index, elem(&1, 0), elem(&1, 1)} | &2])}
        end
      end)

    case errors do
      [] -> {:ok, Enum.reverse(validated)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  # The bound is on what the caller sent, measured as the JSON text of every
  # element's dimensions and metadata. The index reported is the element at
  # which the running total crossed the limit, which is the first one the
  # caller can usefully drop.
  defp check_batch_bytes(entries) do
    entries
    |> Enum.reduce_while(0, fn entry, total ->
      total = total + entry.payload_bytes

      if total > @batch_bytes_limit do
        {:halt, {:error, [{entry.index, :batch, :too_large}]}}
      else
        {:cont, total}
      end
    end)
    |> case do
      {:error, _errors} = error -> error
      total when is_integer(total) -> :ok
    end
  end

  defp collapse(entries) do
    {kept, plan, errors, _seen} = Enum.reduce(entries, {[], [], [], %{}}, &collapse_one/2)

    case Enum.reverse(errors) do
      [] -> {:ok, Enum.reverse(kept), Enum.reverse(plan)}
      errors -> {:error, errors}
    end
  end

  # Repeated ids with an equal payload hash collapse to one insert whose result
  # every position takes; repeated ids with a different hash are an error, and
  # the caller learns it before a connection is checked out rather than from a
  # conflict half way through the batch.
  defp collapse_one(entry, {kept, plan, errors, seen}) do
    key = {entry.tenant_key, entry.event_id}

    case Map.fetch(seen, key) do
      :error ->
        position = length(kept)
        {[entry | kept], [position | plan], errors, Map.put(seen, key, {position, entry})}

      {:ok, {position, first}} ->
        collapse_repeat(entry, position, first.payload_hash == entry.payload_hash, {
          kept,
          plan,
          errors,
          seen
        })
    end
  end

  defp collapse_repeat(_entry, position, true, {kept, plan, errors, seen}),
    do: {kept, [position | plan], errors, seen}

  defp collapse_repeat(entry, position, false, {kept, plan, errors, seen}),
    do: {kept, [position | plan], [{entry.index, :id, :duplicate_id_in_batch} | errors], seen}

  # -- canonical JSON --------------------------------------------------------

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

  defp kind_string(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp kind_string(kind) when is_binary(kind), do: kind

  # `{0, 0}` renders as no fractional part at all, which would make the hash of
  # an event that happened exactly on a second differ in shape from every other
  # one. Six digits always.
  defp pad({value, _precision}), do: {value, 6}
end
