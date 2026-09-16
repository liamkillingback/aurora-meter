defmodule AuroraMeter.Plans.Snapshot do
  @moduledoc false

  # The canonical form of a plan's **commercial content**, its fingerprint, and
  # the jsonb shape that makes a version readable after its block has been
  # deleted from the host's plans module (build unit 07a, `v1-release.md` 07.01
  # and 07.02).
  #
  # ## Why not `:erlang.term_to_binary/1`
  #
  # Three of the four things L17.3 asks of a fingerprint are properties
  # `term_to_binary/1` does not have. It is not stable across OTP releases (the
  # external term format has a documented minor version and maps have changed
  # their encoding), it is not independent of map iteration order for maps
  # larger than 32 entries, and it encodes the whole struct including fields
  # that are not commercial content (`fingerprint` itself, for one). So the form
  # below is rendered explicitly, field by field, and nothing about it depends
  # on a runtime representation.
  #
  # ## The form
  #
  # Fields are separated by the ASCII record separator `0x1e` and the units
  # inside a field by the unit separator `0x1f`. Neither can appear in a plan
  # id, a version, a feature name or a recurring credit name: the version regex
  # rejects them, and `AuroraMeter.Plans.__build__/5` raises for a feature or
  # credit name whose `Atom.to_string/1` contains either. That check is what
  # makes the rendering unambiguous rather than merely unlikely to collide, and
  # it is enforced where the name is declared.
  #
  #     v1 RS id US pro RS version US 1 RS price US 2000 RS
  #     features RS f US ai_generations US limit US 1000 US hard RS
  #     recurring_credits RS
  #
  # **`effective_at` is deliberately not in it**, and the build document's draft
  # of this form had it (finding X290). Three reasons, and the third is the one
  # that decided it.
  #
  # It is not commercial content: it says when a version starts applying to
  # **new** subscriptions, and an existing subscription is pinned to its version
  # and is not moved by it. So changing it cannot reprice anybody, which is what
  # I17 is about.
  #
  # Including it would make a conflict out of something that is not one. A host
  # that dates version 2 for October and then brings it forward to September has
  # changed nothing about what version 2 sells.
  #
  # And including it would make `v1-release.md` 07.03 unreachable. Deleting a
  # retired version's block is the case the whole registry exists for, and when
  # the deleted version was the base version the one left behind **must** drop
  # its `effective_at`, or the module no longer compiles (every plan id needs a
  # base version). Fingerprinting the instant would turn every such deletion
  # into a refused boot for a plan whose price nobody had touched.
  #
  # The instant is still stored in `definition` and in its own column, so
  # `AuroraMeter.Plans.versions/1` can report it for a version that is no longer
  # in code.
  #
  # Features are sorted by name and recurring credits by name, so declaration
  # order and map iteration order are both invisible to the digest. Numbers are
  # rendered with a type tag (`i` for an integer, `f` for a float), so an
  # integer `2` and a float `2.0` unit price are different commercial content
  # and produce different fingerprints, which is deliberate: `AuroraMeter.Config`
  # already warns that a float unit price may lose precision, and a host that
  # switches one for the other has changed what it charges.
  #
  # ## `fingerprint_version`
  #
  # Stored beside the digest so a future change to this rendering is detectable
  # as a rendering change rather than read as a content conflict. A stored row
  # whose `fingerprint_version` differs from `fingerprint_version/0` is not a
  # conflict: `AuroraMeter.Plans.register!/0` logs it once and leaves the row
  # alone.

  alias AuroraMeter.Plan

  @fingerprint_version 1

  @rs "\x1e"
  @us "\x1f"

  @doc "The version of the canonical rendering below."
  @spec fingerprint_version() :: pos_integer()
  def fingerprint_version, do: @fingerprint_version

  @doc "The record separator between canonical fields."
  @spec record_separator() :: String.t()
  def record_separator, do: @rs

  @doc "The unit separator between the parts of one canonical field."
  @spec unit_separator() :: String.t()
  def unit_separator, do: @us

  @doc "Whether `string` can appear in the canonical form without making it ambiguous."
  @spec renderable?(String.t()) :: boolean()
  def renderable?(string) when is_binary(string),
    do: not String.contains?(string, [@rs, @us])

  @doc """
  The canonical binary a fingerprint is taken over.

  Returned rather than hashed in place so the evidence and the tests can show
  it with its separators visible.
  """
  @spec canonical(Plan.t()) :: binary()
  def canonical(%Plan{} = plan) do
    [
      "v#{@fingerprint_version}",
      field("id", Atom.to_string(plan.id)),
      field("version", plan.version),
      field("price", integer(plan.price)),
      "features",
      features(plan.features),
      "recurring_credits",
      credits(plan.recurring_credits)
    ]
    |> List.flatten()
    |> Enum.join(@rs)
  end

  @doc "The sha256 of `canonical/1`: 32 bytes."
  @spec fingerprint(Plan.t()) :: binary()
  def fingerprint(%Plan{} = plan), do: :crypto.hash(:sha256, canonical(plan))

  @doc "The first `n` hex characters of a fingerprint, for an operator-facing message."
  @spec short(binary() | nil) :: String.t()
  def short(nil), do: "(none)"

  def short(fingerprint) when is_binary(fingerprint),
    do: fingerprint |> Base.encode16(case: :lower) |> binary_part(0, 12)

  @doc """
  The `definition` jsonb map for a plan.

  Recurring credits are a **list**, not an object keyed by name: the order is
  declaration order, `AuroraMeter.Credits.Recurrences` reads it in that order,
  and a JSON object has no order. Names are unique, so the list loses nothing.
  """
  @spec encode(Plan.t()) :: map()
  def encode(%Plan{} = plan) do
    %{
      "fingerprint_version" => @fingerprint_version,
      "price" => plan.price,
      "effective_at" => encode_effective(plan.effective_at),
      "features" =>
        Map.new(plan.features, fn {name, config} ->
          {Atom.to_string(name), encode_config(config)}
        end),
      "recurring_credits" => Enum.map(plan.recurring_credits, &encode_credit/1)
    }
  end

  @doc """
  Rebuilds a `%Plan{}` from a stored row.

  Returns `{:ok, plan, dropped}` where `dropped` names the feature and credit
  names whose atom does not exist on this node, or `{:error, reason}` when the
  row cannot be read at all.

  **`String.to_existing_atom/1` only.** There is no `String.to_atom/1` in this
  package and none is added here: `definition` is written by `register!/0` from
  compiled code, but a row is still data read back out of a database and a
  decoder that creates atoms is an unbounded atom table away from a crash.

  A dropped feature is observationally invisible to `check/2`, `entitled?/2`,
  `quota/2` and `feature_value/3`, because every one of them takes an atom and
  no caller can hold an atom that does not exist. It is **not** invisible to
  code that enumerates `plan.features`, which Pro does when it decides what to
  bill, so the names are returned rather than swallowed and
  `AuroraMeter.Plans` logs them once per `(plan_id, version)` per node.
  """
  @spec decode(String.t(), String.t(), map(), DateTime.t() | nil, binary() | nil) ::
          {:ok, Plan.t(), [String.t()]} | {:error, term()}
  def decode(plan_id, version, definition, effective_at, fingerprint)
      when is_binary(plan_id) and is_binary(version) and is_map(definition) do
    with {:ok, id} <- existing_atom(plan_id) do
      {features, dropped_features} = decode_features(Map.get(definition, "features", %{}))

      {credits, dropped_credits} =
        decode_credits(Map.get(definition, "recurring_credits", []))

      plan = %Plan{
        id: id,
        version: version,
        price: Map.get(definition, "price", 0),
        features: features,
        recurring_credits: credits,
        effective_at: effective_at || decode_effective(Map.get(definition, "effective_at")),
        fingerprint: fingerprint
      }

      {:ok, plan, dropped_features ++ dropped_credits}
    end
  end

  @doc "The `fingerprint_version` a stored definition was written at, or `nil`."
  @spec definition_version(map()) :: integer() | nil
  def definition_version(definition) when is_map(definition),
    do: Map.get(definition, "fingerprint_version")

  # -- canonical rendering ----------------------------------------------------

  defp field(name, value), do: name <> @us <> value

  defp features(features) do
    features
    |> Enum.sort_by(fn {name, _config} -> Atom.to_string(name) end)
    |> Enum.map(fn {name, config} ->
      Enum.join(["f", Atom.to_string(name) | render_config(config)], @us)
    end)
  end

  defp credits(credits) do
    credits
    |> Enum.sort_by(fn credit -> Atom.to_string(credit.name) end)
    |> Enum.map(fn credit ->
      Enum.join(
        [
          "c",
          Atom.to_string(credit.name),
          "amount",
          integer(credit.amount),
          "category",
          Atom.to_string(credit.category),
          "rollover",
          integer(credit.rollover),
          "expires"
        ] ++ render_expires(credit.expires),
        @us
      )
    end)
  end

  defp render_config({:limit, n, :hard}), do: ["limit", integer(n), "hard"]

  defp render_config({:metered, included, unit_price}),
    do: ["metered", integer(included), number(unit_price)]

  defp render_config({:counter}), do: ["counter"]
  defp render_config({:feature, true}), do: ["feature", "bool", "true"]
  defp render_config({:feature, false}), do: ["feature", "bool", "false"]
  defp render_config({:feature, n}) when is_integer(n), do: ["feature", "int", integer(n)]

  defp render_expires(:period_end), do: ["period_end"]
  defp render_expires(:never), do: ["never"]
  defp render_expires({:seconds, n}), do: ["seconds", integer(n)]

  defp integer(n) when is_integer(n), do: "i" <> Integer.to_string(n)

  defp number(n) when is_integer(n), do: integer(n)
  defp number(f) when is_float(f), do: "f" <> :erlang.float_to_binary(f, [:short])

  # -- jsonb encoding ---------------------------------------------------------

  defp encode_effective(nil), do: nil
  defp encode_effective(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp encode_config({:limit, n, :hard}), do: ["limit", n, "hard"]
  defp encode_config({:metered, included, unit_price}), do: ["metered", included, unit_price]
  defp encode_config({:counter}), do: ["counter"]
  defp encode_config({:feature, value}) when is_boolean(value), do: ["feature", "bool", value]
  defp encode_config({:feature, value}) when is_integer(value), do: ["feature", "int", value]

  defp encode_credit(credit) do
    %{
      "name" => Atom.to_string(credit.name),
      "amount" => credit.amount,
      "category" => Atom.to_string(credit.category),
      "rollover" => credit.rollover,
      "expires" => encode_expires(credit.expires)
    }
  end

  defp encode_expires(:period_end), do: "period_end"
  defp encode_expires(:never), do: "never"
  defp encode_expires({:seconds, n}), do: ["seconds", n]

  # -- jsonb decoding ---------------------------------------------------------

  defp decode_features(features) when is_map(features) do
    Enum.reduce(Enum.sort(features), {%{}, []}, fn {name, config}, {kept, dropped} ->
      case {existing_atom(name), decode_config(config)} do
        {{:ok, atom}, {:ok, decoded}} -> {Map.put(kept, atom, decoded), dropped}
        _unreadable -> {kept, dropped ++ [name]}
      end
    end)
  end

  defp decode_features(_other), do: {%{}, []}

  defp decode_config(["limit", n, "hard"]) when is_integer(n), do: {:ok, {:limit, n, :hard}}

  defp decode_config(["metered", included, unit_price])
       when is_integer(included) and is_number(unit_price),
       do: {:ok, {:metered, included, unit_price}}

  defp decode_config(["counter"]), do: {:ok, {:counter}}

  defp decode_config(["feature", "bool", value]) when is_boolean(value),
    do: {:ok, {:feature, value}}

  defp decode_config(["feature", "int", value]) when is_integer(value),
    do: {:ok, {:feature, value}}

  defp decode_config(_other), do: :error

  defp decode_credits(credits) when is_list(credits) do
    Enum.reduce(credits, {[], []}, fn credit, {kept, dropped} ->
      with %{"name" => name} <- credit,
           {:ok, atom} <- existing_atom(name),
           {:ok, category} <- existing_atom(Map.get(credit, "category", "promotional")),
           {:ok, expires} <- decode_expires(Map.get(credit, "expires", "period_end")) do
        {kept ++
           [
             %{
               name: atom,
               amount: Map.get(credit, "amount", 0),
               category: category,
               rollover: Map.get(credit, "rollover", 0),
               expires: expires
             }
           ], dropped}
      else
        _unreadable -> {kept, dropped ++ [credit_name(credit)]}
      end
    end)
  end

  defp decode_credits(_other), do: {[], []}

  defp credit_name(%{"name" => name}) when is_binary(name), do: name
  defp credit_name(other), do: inspect(other)

  defp decode_expires("period_end"), do: {:ok, :period_end}
  defp decode_expires("never"), do: {:ok, :never}
  defp decode_expires(["seconds", n]) when is_integer(n), do: {:ok, {:seconds, n}}
  defp decode_expires(_other), do: :error

  defp decode_effective(nil), do: nil

  defp decode_effective(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _error -> nil
    end
  end

  defp decode_effective(_other), do: nil

  defp existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, string}}
  end

  defp existing_atom(atom) when is_atom(atom), do: {:ok, atom}
  defp existing_atom(other), do: {:error, {:unknown_atom, other}}
end
