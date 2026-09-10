defmodule AuroraMeter.Schema.CreditBalance do
  @moduledoc """
  A tenant's prepaid credit balance, one row per tenant, in micro-dollars
  (1e-6 USD; see `AuroraMeter.Credits.Money`).

    * `balance` — everything granted minus everything settled, debited or
      expired; signed, because a settlement may exceed its hold.
    * `held` — the sum of pending holds; `balance - held` is what
      `AuroraMeter.Credits.available/1` returns.
    * `promotional` — the part of `balance` that came from promotional grants;
      consumed before paid credit and the only part that can expire.
    * `low_balance_threshold` — per-tenant override of
      `:credits_low_balance_threshold`.

  The row is only ever changed by the `AuroraMeter.Credits` ledger under a
  `FOR UPDATE` lock, alongside an `AuroraMeter.Schema.CreditTransaction`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_credit_balances" do
    field :tenant_key, :string
    field :balance, :integer, default: 0
    field :held, :integer, default: 0
    field :promotional, :integer, default: 0
    field :low_balance_threshold, :integer
    field :currency, :string, default: "usd"

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset for a balance row (used for the threshold setter)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, [:tenant_key, :balance, :held, :promotional, :low_balance_threshold, :currency])
    |> validate_required([:tenant_key, :balance, :held, :promotional, :currency])
    |> validate_number(:held, greater_than_or_equal_to: 0)
    |> validate_number(:promotional, greater_than_or_equal_to: 0)
    |> unique_constraint(:tenant_key)
  end
end
