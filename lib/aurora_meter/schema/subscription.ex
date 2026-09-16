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

    # The contract this tenant is on. NULL only between core schema version 10
    # and the first `AuroraMeter.Plans.register!/0` after it; from then on every
    # row names its version explicitly, which is what stops a redeployed plan
    # definition from repricing anybody (D05, I17).
    field :plan_version, :string
    field :plan_fingerprint, :binary
    field :plan_effective_at, :utc_datetime

    # The pending transition, mirrored from `aurora_meter_plan_transitions` so a
    # worker can find due work with one indexed keyset query over this table.
    # **Written by build unit 07b and by nothing in this release.** They are
    # deliberately absent from `@syncable` below, so no provider sync can touch
    # them.
    field :scheduled_plan_id, :string
    field :scheduled_plan_version, :string
    field :scheduled_effective_at, :utc_datetime
    field :transition_ref, :string
    field :transition_state, :string
    field :transition_confirm, :string
    field :transition_applied_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(tenant_key plan_id status provider provider_customer_id
               provider_subscription_id current_period_start current_period_end
               plan_version plan_fingerprint plan_effective_at
               scheduled_plan_id scheduled_plan_version scheduled_effective_at
               transition_ref transition_state transition_confirm
               transition_applied_at)a

  # The columns a provider sync, or any other partial `put_subscription/1`
  # caller, is allowed to replace on conflict.
  #
  # **The transition columns are not on this list and that is the point**
  # (open finding S4, lower-level invariant L17.5). `put_subscription/1` used to
  # upsert with `{:replace_all_except, [:id, :tenant_key, :inserted_at]}`, which
  # writes NULL into every column the caller did not cast: the next
  # `AuroraMeter.Pro.Subscriptions.sync/1` would have erased `plan_version` and
  # a scheduled transition with it. The replace list is now computed from the
  # attributes actually supplied, intersected with this allow list, so a sync
  # cannot reach a column it has no opinion about.
  @syncable ~w(plan_id status provider provider_customer_id provider_subscription_id
               current_period_start current_period_end
               plan_version plan_fingerprint plan_effective_at)a

  @transition_states ~w(pending applied cancelled failed)
  @confirmations ~w(local provider)

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

  @doc """
  The columns a partial `AuroraMeter.Storage.put_subscription/1` may replace.

  ## Examples

      iex> :plan_version in AuroraMeter.Schema.Subscription.syncable()
      true

      iex> :transition_ref in AuroraMeter.Schema.Subscription.syncable()
      false

  """
  @spec syncable() :: [atom()]
  def syncable, do: @syncable

  @doc "The states `transition_state` may hold, beside NULL."
  @spec transition_states() :: [String.t()]
  def transition_states, do: @transition_states

  @doc "The values `transition_confirm` may hold, beside NULL."
  @spec confirmations() :: [String.t()]
  def confirmations, do: @confirmations

  @doc "Builds a changeset for a subscription."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :plan_id, :status])
    |> validate_inclusion(:transition_state, @transition_states)
    |> validate_inclusion(:transition_confirm, @confirmations)
    |> unique_constraint(:tenant_key)
  end
end
