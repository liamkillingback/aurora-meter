defmodule AuroraMeter.Event do
  @moduledoc """
  A recorded usage fact, as Aurora Meter hands it back.

  This is a **read** struct. Hosts pattern match on it and read its fields;
  nothing outside the library builds one. It is the return shape of
  `AuroraMeter.record/4`, `record_batch/2` and `correct/4`, and of
  `AuroraMeter.Events.get/2` and `stream/2`.

  ## Fields

    * `id`: the row's internal UUID, assigned by the database. Useful in a
      support conversation and nowhere else. It is **not** the identity of the
      fact; `event_id` is.
    * `event_id`: the caller's identity for this fact, unique per tenant, at
      most 128 bytes. Recording twice with the same `event_id` and the same
      payload is a duplicate, not a second fact.
    * `tenant_key`: the resolved tenant key.
    * `feature`: the feature atom.
    * `quantity`: a positive integer.
    * `kind`: `:usage` or `:correction`.
    * `original_event_id`: for a correction, the `event_id` of the fact it
      corrects, in the same tenant. `nil` for a usage event.
    * `occurred_at`: when the usage happened, as the caller stated it.
    * `recorded_at`: when Aurora Meter wrote the row. The same column the Ecto
      schema calls `inserted_at`.
    * `period_start`: the start of the billing window the fact is charged to.
    * `period_source`: the period source module that resolved it, as a string.
    * `dimensions`: the caller's breakdown keys, string keys and scalar values.
    * `metadata`: the caller's free-form map.
    * `plan_id`, `plan_version`: the plan in force when the usage occurred.
      Recorded for attribution, never used to reprice (decision D05).
    * `attribution`: how much to trust the period and plan on this row.
    * `durability`: `:durable` when the row is committed, `:conditional` when
      it was written inside a transaction the host still owns.
    * `seq`: the row's insertion order, assigned by a database sequence.

  ## The `attribution` vocabulary

    * `:resolved`: the period source placed `occurred_at` in a window without
      ambiguity. The period on this row is a fact.
    * `:unresolved`: the source could not place the instant, so the calendar
      month containing it was used instead. The period on this row is an
      **approximation**, and this value is how you tell.
    * `:legacy_track`: the row was written by `AuroraMeter.track/4` before the
      durable path existed, and given an identity afterwards by
      `mix aurora_meter.events.backfill`. Its `occurred_at` is the instant the
      row was written, not the instant the usage happened, and it was never
      billed.

  The vocabulary is a list, not a database constraint, so a later release can
  add a kind of attribution without a migration. Match on the values you know
  and treat an unknown one as untrusted.
  """

  alias AuroraMeter.Schema

  @typedoc "How much to trust the period and plan recorded on an event."
  @type attribution :: :resolved | :unresolved | :legacy_track | String.t()

  @typedoc "Whether the row is committed, or still inside a transaction the host owns."
  @type durability :: :durable | :conditional

  @type t :: %__MODULE__{
          id: String.t(),
          event_id: String.t() | nil,
          tenant_key: String.t(),
          feature: atom(),
          quantity: integer(),
          kind: :usage | :correction,
          original_event_id: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          recorded_at: DateTime.t(),
          period_start: DateTime.t() | nil,
          period_source: String.t() | nil,
          dimensions: map(),
          metadata: map(),
          plan_id: String.t() | nil,
          plan_version: String.t() | nil,
          attribution: attribution() | nil,
          durability: durability(),
          seq: integer() | nil
        }

  defstruct [
    :id,
    :event_id,
    :tenant_key,
    :feature,
    :quantity,
    :kind,
    :original_event_id,
    :occurred_at,
    :recorded_at,
    :period_start,
    :period_source,
    :plan_id,
    :plan_version,
    :attribution,
    :seq,
    dimensions: %{},
    metadata: %{},
    durability: :durable
  ]

  @doc false
  @spec from_row(Schema.Event.t(), durability()) :: t()
  def from_row(%Schema.Event{} = row, durability \\ :durable) do
    %__MODULE__{
      id: row.id,
      event_id: row.event_id,
      tenant_key: row.tenant_key,
      feature: feature(row.feature),
      quantity: row.quantity,
      kind: kind(row.kind),
      original_event_id: row.original_event_id,
      occurred_at: row.occurred_at,
      recorded_at: row.inserted_at,
      period_start: row.period_start,
      period_source: row.period_source,
      dimensions: row.dimensions || %{},
      metadata: row.metadata || %{},
      plan_id: row.plan_id,
      plan_version: row.plan_version,
      attribution: attribution(row.attribution),
      durability: durability,
      seq: row.seq
    }
  end

  # Features reach the database as strings and come back as the atom the plan
  # declared. `to_existing_atom` rather than `to_atom`: a feature that no plan
  # and no call site has ever named is not a feature, and creating an atom for
  # it from a database row is how an atom table fills up.
  defp feature(nil), do: nil

  defp feature(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp kind("correction"), do: :correction
  defp kind(_usage), do: :usage

  defp attribution(nil), do: nil
  defp attribution("resolved"), do: :resolved
  defp attribution("unresolved"), do: :unresolved
  defp attribution("legacy_track"), do: :legacy_track
  defp attribution(other), do: other
end
