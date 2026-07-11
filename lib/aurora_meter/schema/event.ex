defmodule AuroraMeter.Schema.Event do
  @moduledoc """
  A raw usage event. Written only for features configured as `:durable` (and for
  audit), giving billing-grade exactness beyond the buffered ETS counters.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_events" do
    field :tenant_key, :string
    field :feature, :string
    field :quantity, :integer, default: 1
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
