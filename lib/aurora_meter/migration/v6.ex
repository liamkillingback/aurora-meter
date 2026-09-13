defmodule AuroraMeter.Migration.V6 do
  @moduledoc false
  import Ecto.Migration

  @spec up() :: :ok
  def up do
    create_if_not_exists table(:aurora_meter_flush_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    :ok
  end

  @spec down() :: :ok
  def down do
    drop_if_exists table(:aurora_meter_flush_receipts)
    :ok
  end
end
