defmodule AuroraMeter.Schema.Event do
  @moduledoc """
  One recorded usage fact.

  Two kinds of row live here, and they are not the same thing.

  A row written by `AuroraMeter.track/4` for a feature listed in the legacy
  `durable_features` carries no caller identity: a retry after an uncertain
  write inserts a second row, and nothing reads the table for billing. Those
  rows are given a derived `event_id` of `"legacy:" <> id` by
  `mix aurora_meter.events.backfill`, so the schema can require an identity
  without discarding history.

  A row written by the V1 durable path carries the caller's own `event_id`,
  unique per tenant, and a `payload_hash` that separates a retry of the same
  fact from a different fact reusing the identity.

  ## The field named `inserted_at`

  It is the instant this node wrote the row, not the instant the usage
  happened. The usage instant is `occurred_at`, which the caller supplies. The
  Ecto field keeps the name `inserted_at` because a query written against 0.4.x
  (`where: e.inserted_at >= ^since`) must keep compiling; the public read
  struct `AuroraMeter.Event` exposes the same column as `recorded_at`, which is
  what it is.

  ## `seq`

  An identity column assigned by a Postgres sequence at insert time. It is the
  only sound scan order this table has: `id` is a random v4 UUID, so a forward
  keyset scan ordered by it can miss a row committed by a transaction that
  started earlier, and `inserted_at` is an application clock reading rather
  than a commit order. Never write it; Ecto is told not to.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_events" do
    field :tenant_key, :string
    field :feature, :string
    field :quantity, :integer, default: 1
    field :metadata, :map, default: %{}

    # Caller identity and the canonical payload digest (core schema version 7;
    # `NOT NULL` from version 8).
    field :event_id, :string
    field :payload_hash, :binary

    # When the usage happened, against when this row was written.
    field :occurred_at, :utc_datetime_usec

    # The billing window the fact is charged to, and the source that resolved
    # it. `attribution` says how much to trust that resolution: "resolved",
    # "unresolved" or "legacy_track". It is deliberately unconstrained in the
    # database so a later attribution kind needs no migration.
    field :period_start, :utc_datetime
    field :period_source, :string
    field :attribution, :string

    # "usage" or "correction". A correction points at the event it corrects
    # through `original_event_id`, which is that event's caller `event_id` in
    # the same tenant, never this table's `id`.
    field :kind, :string, default: "usage"
    field :original_event_id, :string

    field :dimensions, :map, default: %{}

    # Plan attribution at the moment of occurrence. Recorded, never used to
    # reprice (decision D05).
    field :plan_id, :string
    field :plan_version, :string

    # Assigned by the database. `read_after_writes` keeps Ecto from ever
    # sending a value for it, which is what makes the insertion order it
    # carries trustworthy.
    field :seq, :integer, read_after_writes: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
