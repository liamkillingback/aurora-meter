defmodule AuroraMeter.Schema.Subscription do
  @moduledoc """
  A tenant's plan assignment. Created locally by `AuroraMeter.subscribe/2` (free)
  or synced from the billing provider (Pro). One row per tenant.

  `status` follows Stripe's vocabulary. Only `entitled_statuses/0` grant the
  subscription's plan; any other status (canceled, unpaid, incomplete, ...) falls
  back to the configured default plan.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @entitled_statuses ~w(active trialing past_due)

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

  @doc """
  Statuses under which the subscription's plan is granted.

  ## Examples

      iex> "active" in AuroraMeter.Schema.Subscription.entitled_statuses()
      true

  """
  @spec entitled_statuses() :: [String.t()]
  def entitled_statuses, do: @entitled_statuses

  @doc """
  Whether a subscription currently grants its plan.

  ## Examples

      iex> AuroraMeter.Schema.Subscription.entitled?(%AuroraMeter.Schema.Subscription{status: "canceled"})
      false

  """
  @spec entitled?(t()) :: boolean()
  def entitled?(%__MODULE__{status: status}), do: status in @entitled_statuses

  @doc "Builds a changeset for a subscription."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :plan_id, :status])
    |> unique_constraint(:tenant_key)
  end
end
