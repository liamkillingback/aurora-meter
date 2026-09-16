defmodule AuroraMeterExampleAi.SampleOutbox.Item do
  @moduledoc """
  One export intent, staged in the same transaction as the event it describes.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "sample_outbox_items" do
    field :event_id, :string
    field :tenant_key, :string
    field :feature, :string
    field :quantity, :integer
    # See the migration: second precision, because that is what
    # `AuroraMeter.Event.period_start` carries.
    field :period_start, :utc_datetime
    field :payload, :map, default: %{}
    field :state, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :last_outcome, :string
    field :provider_ref, :string
    field :next_attempt_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :event_id,
      :tenant_key,
      :feature,
      :quantity,
      :period_start,
      :payload,
      :state,
      :attempts,
      :last_outcome,
      :provider_ref,
      :next_attempt_at
    ])
    |> validate_required([:event_id, :tenant_key, :feature, :quantity, :period_start, :state])
    |> validate_inclusion(:state, ~w(pending claimed delivered uncertain rejected skipped))
    |> unique_constraint([:tenant_key, :event_id])
  end
end
