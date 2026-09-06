defmodule AuroraMeter.Schema.History do
  @moduledoc """
  A flushed snapshot of a usage history bucket (`bucket_kind` `"day"`, UTC) for
  one `{tenant_key, feature, bucket_start}`. Maintained by the flusher alongside
  the period counters when `:history` is enabled, and read by
  `AuroraMeter.history/3` for charts.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_history" do
    field :tenant_key, :string
    field :feature, :string
    field :bucket_kind, :string, default: "day"
    field :bucket_start, :date
    field :value, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
