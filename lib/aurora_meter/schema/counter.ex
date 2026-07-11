defmodule AuroraMeter.Schema.Counter do
  @moduledoc """
  A flushed snapshot of a usage counter for one `{tenant_key, feature,
  period_start}`. The live value lives in ETS; this row is the durable copy the
  flusher upserts on an interval.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_counters" do
    field :tenant_key, :string
    field :feature, :string
    field :period_start, :utc_datetime
    field :value, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
