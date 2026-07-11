defmodule AuroraMeter.Migration do
  @moduledoc """
  Creates and drops the Aurora Meter core tables.

  The host's generated migration delegates here (`AuroraMeter.Migration.up/0` /
  `down/0`), so future schema changes ship as new versions of this module rather
  than as edits to the host's migration file.
  """

  import Ecto.Migration

  @doc "Creates the Aurora Meter core tables."
  @spec up() :: :ok
  def up do
    create table(:aurora_meter_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false
      add :plan_id, :string, null: false
      add :status, :string, null: false, default: "active"
      add :provider, :string
      add :provider_customer_id, :string
      add :provider_subscription_id, :string
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:aurora_meter_subscriptions, [:tenant_key])

    create table(:aurora_meter_counters, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false
      add :feature, :string, null: false
      add :period_start, :utc_datetime, null: false
      add :value, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:aurora_meter_counters, [:tenant_key, :feature, :period_start])

    create table(:aurora_meter_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false
      add :feature, :string, null: false
      add :quantity, :integer, null: false, default: 1
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:aurora_meter_events, [:tenant_key, :feature, :inserted_at])

    :ok
  end

  @doc "Drops the Aurora Meter core tables."
  @spec down() :: :ok
  def down do
    drop table(:aurora_meter_events)
    drop table(:aurora_meter_counters)
    drop table(:aurora_meter_subscriptions)
    :ok
  end
end
