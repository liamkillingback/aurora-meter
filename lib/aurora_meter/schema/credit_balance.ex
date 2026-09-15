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
    * `debt`: executed cost the wallet could not fund, recorded rather than
      hidden. Every incoming grant repays it before creating availability, and
      no hold or debit may spend while it is outstanding.
    * `expired`: value destroyed by expiry, kept apart from value spent so the
      two are never confused.
    * `lots_enabled_at`: `nil` means the legacy writer owns this wallet.
      Non-nil means `AuroraMeter.Credits.Allocator` does, and the balance row is
      a checked projection of the wallet's lots rather than an independent
      source of truth. It is read under the row's own `FOR UPDATE` lock, which
      is what stops the two writers ever running together on one wallet.
    * `projection_checked_at`: stamped by every successful conservation check.
    * `low_balance_crossing_id`: the persisted identity of the current
      low-balance crossing (written by build unit 06c).

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
    field :debt, :integer, default: 0
    field :expired, :integer, default: 0
    field :lots_enabled_at, :utc_datetime
    field :projection_checked_at, :utc_datetime_usec
    field :low_balance_crossing_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(tenant_key balance held promotional low_balance_threshold currency
               debt expired lots_enabled_at projection_checked_at low_balance_crossing_id)a

  @doc """
  Builds a changeset for a balance row.

  The four `>= 0` validations mirror the CHECK constraints schema version 9 put
  on the table. Until then the changeset was the only thing asserting them and
  nothing enforced them on a row the ledger wrote directly (finding X183), so a
  lost row lock would have been silent corruption rather than a refused write.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(balance, attrs) do
    balance
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :balance, :held, :promotional, :currency, :debt, :expired])
    |> validate_number(:held, greater_than_or_equal_to: 0)
    |> validate_number(:promotional, greater_than_or_equal_to: 0)
    |> validate_number(:debt, greater_than_or_equal_to: 0)
    |> validate_number(:expired, greater_than_or_equal_to: 0)
    |> unique_constraint(:tenant_key)
    |> check_constraint(:held,
      name: :aurora_meter_credit_balances_held_check,
      message: "must be greater than or equal to 0"
    )
    |> check_constraint(:promotional,
      name: :aurora_meter_credit_balances_promotional_check,
      message: "must be greater than or equal to 0"
    )
    |> check_constraint(:debt,
      name: :aurora_meter_credit_balances_debt_check,
      message: "must be greater than or equal to 0"
    )
    |> check_constraint(:expired,
      name: :aurora_meter_credit_balances_expired_check,
      message: "must be greater than or equal to 0"
    )
  end
end
