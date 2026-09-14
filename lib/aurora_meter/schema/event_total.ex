defmodule AuroraMeter.Schema.EventTotal do
  @moduledoc """
  The projection of `aurora_meter_events` into one row per tenant, feature,
  period and generation.

  It is a **derived** table. Every row here can be rebuilt by summing the
  events it came from, which is what `AuroraMeter.Events.Replay` (build unit
  03d) does into a fresh `generation` while the active one keeps serving reads.
  Nothing bills from this table that could not be billed from the events
  themselves; it exists so that a dashboard, a quota and a report do not each
  have to aggregate the whole event history.

  The delta for an accepted event is written inside the same transaction as the
  event row, so the two cannot disagree (L-03b-1). Duplicates contribute
  nothing: a retry of an identity that is already recorded adds no quantity and
  no event count.

  `generation` is `0` until a replay builds a new one. `load_event_total/3`
  reads the generation named by the `events_projection` checkpoint row.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_event_totals" do
    field :tenant_key, :string
    field :feature, :string
    field :period_start, :utc_datetime
    field :generation, :integer, default: 0
    field :quantity, :integer, default: 0
    field :events, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
