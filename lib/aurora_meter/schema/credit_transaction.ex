defmodule AuroraMeter.Schema.CreditTransaction do
  @moduledoc """
  One append-only entry in a tenant's credit ledger, in micro-dollars.

  `kind` says what happened and `amount` is the signed delta it applied to the
  balance (`grant` positive; `settle`, `debit` and `expire` negative or zero;
  `hold` and `release` zero, moving `held_delta` instead). `balance_after` and
  `held_after` snapshot the row after the entry, so the log alone reproduces
  every balance.

  `balance_after`, `held_after` and `promotional_after` snapshot the row after
  the entry, so the log alone reproduces every figure.

  `reference` is the caller's idempotency key: unique per `kind`, so a retried
  grant is returned instead of credited twice and a retried hold or debit is
  refused. A `hold` carries `status` (`:pending`, `:settled`, `:released`) and,
  once settled, `settled_amount`; a promotional `grant` may carry `expires_at`
  and gets `expired_at` when `AuroraMeter.Credits.expire_due/1` consumes it.

  `category` names where a grant's money came from (`:paid`, `:promotional`,
  `:adjustment`) and, on a debit, marks `:reversal` — a refund or chargeback
  taking a paid grant back. A reversal never consumes promotional credit and is
  reported against grants rather than as spend.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type kind :: :grant | :hold | :settle | :release | :debit | :expire
  @type category :: :paid | :promotional | :adjustment | :reversal
  @type status :: :pending | :settled | :released
  @type t :: %__MODULE__{}

  @kinds [:grant, :hold, :settle, :release, :debit, :expire]
  @grant_categories [:paid, :promotional, :adjustment]
  # `:reversal` is not a grant category: it marks the debit a refund or
  # chargeback writes, so the ledger can tell money being handed back from
  # money being spent.
  @categories @grant_categories ++ [:reversal]
  @statuses [:pending, :settled, :released]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_credit_transactions" do
    field :tenant_key, :string
    field :kind, Ecto.Enum, values: @kinds
    field :category, Ecto.Enum, values: @categories
    field :amount, :integer
    field :held_delta, :integer, default: 0
    field :balance_after, :integer
    field :held_after, :integer
    # The promotional figure after this entry. Not derivable from `amount`:
    # promotional credit is consumed before paid credit and clamped to the
    # balance after every entry, so it moves for reasons an amount does not
    # explain. Snapshotted like `balance_after` so the log stands on its own.
    field :promotional_after, :integer
    field :reference, :string
    field :status, Ecto.Enum, values: @statuses
    field :settled_amount, :integer
    field :expires_at, :utc_datetime
    field :expired_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(tenant_key kind category amount held_delta balance_after held_after
               promotional_after reference
               status settled_amount expires_at expired_at metadata)a

  @doc """
  The transaction kinds.

  ## Examples

      iex> :hold in AuroraMeter.Schema.CreditTransaction.kinds()
      true

  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The grant categories.

  ## Examples

      iex> AuroraMeter.Schema.CreditTransaction.categories()
      [:paid, :promotional, :adjustment]

  """
  @spec categories() :: [category()]
  def categories, do: @grant_categories

  @doc "Builds a changeset for a ledger entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, @castable)
    |> validate_required([:tenant_key, :kind, :amount, :held_delta, :balance_after, :held_after])
    |> validate_expiry()
    |> unique_constraint([:kind, :reference],
      name: :aurora_meter_credit_transactions_kind_reference_index,
      error_key: :reference,
      message: "has already been used for this kind of transaction"
    )
  end

  # Only promotional grants expire: an `expires_at` on anything else is a caller
  # mistake we would rather reject than silently ignore.
  @spec validate_expiry(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_expiry(changeset) do
    case {get_field(changeset, :expires_at), get_field(changeset, :category)} do
      {nil, _category} -> changeset
      {_expires_at, :promotional} -> changeset
      {_expires_at, _other} -> add_error(changeset, :expires_at, "only promotional grants expire")
    end
  end
end
