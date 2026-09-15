defmodule AuroraMeter.Schema.CreditAllocation do
  @moduledoc """
  One movement of value between two buckets of one
  `AuroraMeter.Schema.CreditLot`, naming the ledger entry that caused it.

  The allocation trail is what makes a lot's quantities reconstructible rather
  than merely asserted: folding a lot's allocations in `seq` order reproduces
  its `available`, `reserved`, `consumed`, `reversed` and `expired` exactly.

  | `kind` | Movement |
  |---|---|
  | `reserve` | `available` to `reserved` (a hold) |
  | `unreserve` | `reserved` to `available` (a release, or a settlement below its hold) |
  | `consume` | `available` or `reserved` to `consumed` (a debit, a settlement, a debt repayment) |
  | `expire` | `available` or `reserved` to `expired` |
  | `reverse` | `available`, `consumed` or `reserved` to `reversed` (a refund or a chargeback) |
  | `restore` | `reversed` back to `available` |

  `from_bucket` and `to_bucket` record the movement exactly, and they are not
  redundant with `kind`: a `consume` can come out of `available` (a debit) or
  out of `reserved` (a settlement against its own hold), an `expire` out of
  either, and a `reverse` out of any of three. Folding a lot's allocations back
  into its five quantities needs the source, and `kind` alone would leave it
  guessing.

  There is deliberately no uniqueness on `(transaction_id, lot_id, kind)`: one
  transaction legitimately produces several allocations of the same kind on
  different lots, and a settlement produces both a `consume` and an `unreserve`
  on the same lot. Idempotency lives on the ledger entry's
  `(kind, reference)`, which is decided before any allocation is written.

  `seq` is the order, not `inserted_at`: see `AuroraMeter.Schema.CreditLot`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type kind :: :reserve | :unreserve | :consume | :expire | :reverse | :restore
  @type bucket :: :available | :reserved | :consumed | :reversed | :expired
  @type t :: %__MODULE__{}

  @kinds [:reserve, :unreserve, :consume, :expire, :reverse, :restore]
  @buckets [:available, :reserved, :consumed, :reversed, :expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_credit_allocations" do
    field :tenant_key, :string
    field :lot_id, :binary_id
    field :transaction_id, :binary_id
    field :kind, Ecto.Enum, values: @kinds
    field :from_bucket, Ecto.Enum, values: @buckets
    field :to_bucket, Ecto.Enum, values: @buckets
    field :amount, :integer
    field :seq, :integer, read_after_writes: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @castable ~w(tenant_key lot_id transaction_id kind from_bucket to_bucket amount)a

  @doc """
  The allocation kinds.

  ## Examples

      iex> :unreserve in AuroraMeter.Schema.CreditAllocation.kinds()
      true

  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The buckets a movement can run between.

  ## Examples

      iex> AuroraMeter.Schema.CreditAllocation.buckets()
      [:available, :reserved, :consumed, :reversed, :expired]

  """
  @spec buckets() :: [bucket()]
  def buckets, do: @buckets

  @doc "Builds a changeset for an allocation."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, @castable)
    |> validate_required([
      :tenant_key,
      :lot_id,
      :transaction_id,
      :kind,
      :from_bucket,
      :to_bucket,
      :amount
    ])
    |> validate_movement()
    |> validate_number(:amount, greater_than: 0)
    |> check_constraint(:amount,
      name: :aurora_meter_credit_allocations_amount_check,
      message: "must be positive"
    )
    |> check_constraint(:to_bucket,
      name: :aurora_meter_credit_allocations_movement_check,
      message: "must differ from from_bucket"
    )
  end

  defp validate_movement(changeset) do
    case {get_field(changeset, :from_bucket), get_field(changeset, :to_bucket)} do
      {same, same} when not is_nil(same) ->
        add_error(changeset, :to_bucket, "must differ from from_bucket")

      _other ->
        changeset
    end
  end
end
