defmodule AuroraMeter.Schema.Subscription do
  @moduledoc """
  A tenant's plan assignment. Created locally by `AuroraMeter.subscribe/2` (free)
  or synced from the billing provider (Pro). One row per tenant.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "aurora_meter_subscriptions" do
    field :tenant_key, :string
    field :plan_id, :string
    field :status, :string, default: "active"
    field :provider, :string
    field :provider_customer_id, :string
    field :provider_subscription_id, :string
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(tenant_key plan_id status provider provider_customer_id
               provider_subscription_id current_period_start current_period_end)a

  @doc "Builds a changeset for a subscription."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :plan_id, :status])
    |> unique_constraint(:tenant_key)
  end
end
