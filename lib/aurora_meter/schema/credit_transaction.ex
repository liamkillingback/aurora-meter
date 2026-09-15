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
  `:adjustment`) and, on a reversal, marks `:reversal`, which is a refund or chargeback
  taking a paid grant back. A reversal never consumes promotional credit and is
  reported against grants rather than as spend.

  A reversal is `kind: :reverse` from schema version 9 on, and was `kind:
  :debit, category: :reversal` before it. Both shapes are permanent, because
  the log is append only. Ask `reversal?/1` rather than matching on either.

  `seq` is the order. It is a Postgres identity column, assigned in commit
  order, and it is what every query that reconstructs what happened first sorts
  by. `inserted_at` is a wall-clock stamp and is not monotonic, so it orders
  nothing (findings L20, X213). `hold_transaction_id` names the hold a `settle`
  or `release` row closes, and `updated_at` is stamped by the database the
  first time the row is updated in place.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type kind :: :grant | :hold | :settle | :release | :debit | :expire | :reverse
  @type category :: :paid | :promotional | :adjustment | :reversal
  @type status :: :pending | :settled | :released
  @type t :: %__MODULE__{}

  @kinds [:grant, :hold, :settle, :release, :debit, :expire, :reverse]
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

    # The ordering key. Assigned by a Postgres identity column, so for any two
    # committed rows A and B, if A committed before B started then
    # `A.seq < B.seq`. `inserted_at` is a wall-clock value and cannot promise
    # that: it steps backwards on an NTP correction, a leap second or a VM
    # pause, and the ledger used to order its own account of the past by it
    # (findings L20, X213). Nothing orders by `inserted_at` any more.
    field :seq, :integer, read_after_writes: true

    # The hold a `settle` or `release` row closes. Nullable, because every row
    # written before schema version 9 has none and because no other kind has a
    # hold to name (backfilled for historical rows by build unit 06b).
    field :hold_transaction_id, :binary_id

    # Null until the row is updated in place, and then stamped by the database
    # with `clock_timestamp()` rather than by the node. A row that is never
    # touched again keeps a null here, which is the honest answer and is what
    # `schema-migration-map.md` S4 specifies.
    field :updated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(tenant_key kind category amount held_delta balance_after held_after
               promotional_after reference hold_transaction_id
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

  @doc """
  Whether this entry is a reversal: a refund or a chargeback taking paid credit
  back.

  **Two row shapes mean it, and both are permanent.** From schema version 9 a
  reversal is written with `kind: :reverse` and `category: :reversal`. Before
  that it was written with `kind: :debit` and `category: :reversal`, and those
  rows are in the append-only log for ever, so every reader has to accept both.
  This is the one predicate that knows that; no other module may re-derive it,
  because a second copy is the one that gets the older shape wrong.

  ## Examples

      iex> AuroraMeter.Schema.CreditTransaction.reversal?(%{kind: :reverse, category: :reversal})
      true

      iex> AuroraMeter.Schema.CreditTransaction.reversal?(%{kind: :debit, category: :reversal})
      true

      iex> AuroraMeter.Schema.CreditTransaction.reversal?(%{kind: :debit, category: nil})
      false

      iex> AuroraMeter.Schema.CreditTransaction.reversal?(%{kind: :grant, category: :paid})
      false

  """
  @spec reversal?(t() | map()) :: boolean()
  def reversal?(%{kind: :reverse}), do: true
  def reversal?(%{category: :reversal}), do: true
  def reversal?(entry) when is_map(entry), do: false

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
