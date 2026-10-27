defmodule AuroraMeter.Schema.PlanTransition do
  @moduledoc """
  The audit row for one scheduled, applied or cancelled plan change.

  The table ships with core schema version 10 and is written by
  `AuroraMeter.Subscriptions.schedule_transition/3` and the transitions it
  applies or cancels.

  `ref` is the caller's idempotency reference, unique per tenant. `confirm` says
  whether the transition may be applied locally (`"local"`) or must wait for the
  billing provider to confirm the price change (`"provider"`); it is mirrored
  onto `aurora_meter_subscriptions.transition_confirm` so Pro can find due
  provider work with one indexed keyset query over the subscriptions table
  instead of a jsonb predicate over this one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(pending applied cancelled failed)
  @confirmations ~w(local provider)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "aurora_meter_plan_transitions" do
    field :tenant_key, :string
    field :ref, :string
    field :from_plan_id, :string
    field :from_version, :string
    field :to_plan_id, :string
    field :to_version, :string
    field :effective_at, :utc_datetime
    field :state, :string, default: "pending"
    field :confirm, :string, default: "local"
    field :provider_ref, :string
    field :applied_at, :utc_datetime_usec
    field :detail, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(tenant_key ref from_plan_id from_version to_plan_id to_version
               effective_at state confirm provider_ref applied_at detail)a

  @doc "The states a transition row may be in."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The confirmation modes a transition row may be in."
  @spec confirmations() :: [String.t()]
  def confirmations, do: @confirmations

  @doc "Builds a changeset for a plan transition."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transition, attrs) do
    transition
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :ref, :to_plan_id, :to_version, :effective_at, :state])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:confirm, @confirmations)
    |> validate_length(:ref, min: 1, max: 128, count: :bytes)
    |> unique_constraint([:tenant_key, :ref],
      name: :aurora_meter_plan_transitions_tenant_ref_index
    )
  end
end
