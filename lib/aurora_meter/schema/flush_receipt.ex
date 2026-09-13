defmodule AuroraMeter.Schema.FlushReceipt do
  @moduledoc false
  use Ecto.Schema
  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "aurora_meter_flush_receipts" do
    field :inserted_at, :utc_datetime_usec
  end
end
