defmodule AuroraMeter.Schema.CreditRecurrence do
  @moduledoc """
  One period of one recurring allowance, for one tenant.

  A row is the record that a promise was kept: "for this tenant, this
  entitlement, this plan version and this period, the allowance was issued".
  `UNIQUE (tenant_key, key)` is what keeps that to one row however many
  schedulers run, and it is evaluated inside the wallet's balance row lock, so
  the row and the grant it names commit together or not at all.

  ## The key and the reference are not the same string

  `key` is `"recurring:<name>:<plan_id>:<plan_version>:<period_start>"` and is
  unique **per tenant**, because the index carries `tenant_key`. The ledger's
  own idempotency key is not: `aurora_meter_credit_transactions` is unique on
  `(kind, reference)` across every tenant in the installation, so the grant this
  row names is referenced
  `"recurring:<tenant_key>:<name>:<plan_id>:<plan_version>:<period_start>"`
  instead. Two tenants on one plan reach the same period on the same day, and
  with one string for both the second tenant's grant would be refused as a
  duplicate of the first tenant's (`open-findings.md` X273).

  ## policy is written once and never updated

  It is the entitlement as it stood when the period was first processed: amount,
  category, rollover cap and expiry. Every later decision about that period
  reads it rather than the compiled plan, so editing the plan cannot change what
  a period already promised. The cap is where that matters most: what a period
  carries forward is capped by **its own** stored policy, not by whatever the
  plan says when the next period is processed.

  ## state

    * `granted`: the period was live when it was processed, and its allowance
      is spendable.
    * `issued_and_expired`: the period had already ended when it was processed
      (downtime catch-up). The grant and its expiry are both written, in one
      transaction, so the period appears in history without ever adding
      spendable funds.

  Rows are written only by `AuroraMeter.Credits.Recurrences`, through
  `AuroraMeter.Credits.Ledger`, inside the wallet's balance row lock.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type state :: :granted | :issued_and_expired
  @type t :: %__MODULE__{}

  @states [:granted, :issued_and_expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "aurora_meter_credit_recurrences" do
    field :tenant_key, :string
    field :key, :string
    field :policy, :map, default: %{}
    field :granted_transaction_id, :binary_id
    field :rollover_from_id, :binary_id
    field :period_start, :utc_datetime
    field :state, Ecto.Enum, values: @states, default: :granted

    field :inserted_at, :utc_datetime_usec
  end

  @castable ~w(tenant_key key policy granted_transaction_id rollover_from_id period_start
               state inserted_at)a

  @doc """
  The states a recurrence row can be in.

  ## Examples

      iex> AuroraMeter.Schema.CreditRecurrence.states()
      [:granted, :issued_and_expired]

  """
  @spec states() :: [state()]
  def states, do: @states

  @doc """
  Builds a changeset for a recurrence row.

  There is no public promise about this changeset: the engine is the only
  writer, and the struct is public so support tooling can read a row back.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(recurrence, attrs) do
    recurrence
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :key, :policy, :period_start, :state, :inserted_at])
    |> unique_constraint([:tenant_key, :key],
      name: :aurora_meter_credit_recurrences_key_index,
      message: "has already been granted for this tenant"
    )
    |> check_constraint(:state,
      name: :aurora_meter_credit_recurrences_state_check,
      message: "is not a recurrence state"
    )
  end
end
