defmodule AuroraMeter.Schema.CreditLot do
  @moduledoc """
  One grant's worth of credit, with the five buckets its value can be in.

  A lot is created by a grant and never merged with another, so "which grant
  paid for this" and "which payment funded this grant" both have an answer. The
  five quantities always add up to `amount`, and the database refuses a row
  where they do not:

    * `available`: spendable now, unless the lot is past `expires_at`
    * `reserved`: held by a pending hold, and spoken for
    * `consumed`: spent by a debit, a settlement or a repayment of debt
    * `reversed`: taken back by a refund or a chargeback
    * `expired`: destroyed by expiry, and never spendable again

  `state` is a total function of the quantities (`reversed` when
  `reversed = amount`, else `expired` when nothing is available or reserved and
  something expired, else `exhausted` when nothing is available or reserved,
  else `open`), and a CHECK constraint keeps every writer honest about it.

  ## Ordering

  `seq` is the order, not `granted_at` and not `inserted_at`. The clock that
  produces a timestamp is not monotonic and steps backwards on an NTP
  correction, a leap second or a VM pause; a Postgres identity column cannot.
  `granted_at` is for display and reporting.

  ## Spend order

  Promotional before paid (adjustment sorts with paid), then the earliest
  non-null `expires_at`, then the oldest grant, then `seq`. Non-expiring lots
  sort last within their category. The key is total, so the order a query
  happens to return lots in cannot change what a debit spends.

  Rows are written only by `AuroraMeter.Credits`, inside one transaction, under
  the wallet's balance row lock.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type category :: :paid | :promotional | :adjustment
  @type state :: :open | :exhausted | :expired | :reversed
  @type t :: %__MODULE__{}

  @categories [:paid, :promotional, :adjustment]
  @states [:open, :exhausted, :expired, :reversed]
  @quantities [:available, :reserved, :consumed, :reversed, :expired]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "aurora_meter_credit_lots" do
    field :tenant_key, :string
    field :grant_transaction_id, :binary_id
    field :reference, :string
    field :category, Ecto.Enum, values: @categories
    field :amount, :integer
    field :available, :integer, default: 0
    field :reserved, :integer, default: 0
    field :consumed, :integer, default: 0
    field :reversed, :integer, default: 0
    field :expired, :integer, default: 0
    field :granted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime
    field :source, :map, default: %{}
    field :state, Ecto.Enum, values: @states, default: :open
    field :seq, :integer, read_after_writes: true

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(tenant_key grant_transaction_id reference category amount available reserved
               consumed reversed expired granted_at expires_at source state)a

  @doc """
  The lot categories.

  ## Examples

      iex> AuroraMeter.Schema.CreditLot.categories()
      [:paid, :promotional, :adjustment]

  """
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  The lot states.

  ## Examples

      iex> :exhausted in AuroraMeter.Schema.CreditLot.states()
      true

  """
  @spec states() :: [state()]
  def states, do: @states

  @doc """
  The five buckets a lot's value can be in, in the order the conservation check
  adds them up.

  ## Examples

      iex> AuroraMeter.Schema.CreditLot.quantities()
      [:available, :reserved, :consumed, :reversed, :expired]

  """
  @spec quantities() :: [atom()]
  def quantities, do: @quantities

  @doc """
  The state a lot with these quantities must be in.

  It is a function of the quantities alone, so it is order free: a writer
  cannot leave a stale state behind, and two writers that computed it at
  different moments cannot disagree. The database holds the same expression as
  a CHECK constraint.

  ## Examples

      iex> AuroraMeter.Schema.CreditLot.state_for(%{amount: 10, available: 10, reserved: 0, consumed: 0, reversed: 0, expired: 0})
      :open

      iex> AuroraMeter.Schema.CreditLot.state_for(%{amount: 10, available: 0, reserved: 0, consumed: 10, reversed: 0, expired: 0})
      :exhausted

      iex> AuroraMeter.Schema.CreditLot.state_for(%{amount: 10, available: 0, reserved: 0, consumed: 4, reversed: 0, expired: 6})
      :expired

      iex> AuroraMeter.Schema.CreditLot.state_for(%{amount: 10, available: 0, reserved: 0, consumed: 0, reversed: 10, expired: 0})
      :reversed

  """
  @spec state_for(map()) :: state()
  def state_for(%{amount: amount, reversed: reversed}) when reversed == amount, do: :reversed

  def state_for(%{available: 0, reserved: 0, expired: expired}) when expired > 0, do: :expired

  def state_for(%{available: 0, reserved: 0}), do: :exhausted

  def state_for(_quantities), do: :open

  @doc """
  Builds a changeset for a lot.

  The validations mirror every CHECK constraint the table carries, so a bug in
  a writer surfaces as a changeset error in a test and as a constraint error in
  production, and neither can be reached without the other firing.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lot, attrs) do
    lot
    |> cast(attrs, @castable)
    |> validate_required([
      :tenant_key,
      :grant_transaction_id,
      :reference,
      :category,
      :amount,
      :granted_at
    ])
    |> validate_number(:amount, greater_than: 0)
    |> validate_quantities()
    |> validate_conservation()
    |> validate_state()
    |> unique_constraint([:tenant_key, :grant_transaction_id],
      name: :aurora_meter_credit_lots_grant_index,
      message: "already has a lot"
    )
    |> check_constraint(:amount,
      name: :aurora_meter_credit_lots_conservation_check,
      message: "the five quantities must add up to the lot amount"
    )
    |> check_constraint(:state,
      name: :aurora_meter_credit_lots_state_check,
      message: "does not match the quantities"
    )
  end

  defp validate_quantities(changeset) do
    Enum.reduce(@quantities, changeset, fn quantity, acc ->
      validate_number(acc, quantity, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_conservation(changeset) do
    amount = get_field(changeset, :amount)
    total = Enum.reduce(@quantities, 0, &((get_field(changeset, &1) || 0) + &2))

    if is_integer(amount) and total != amount do
      add_error(
        changeset,
        :amount,
        "must equal available + reserved + consumed + reversed + expired",
        total: total
      )
    else
      changeset
    end
  end

  defp validate_state(changeset) do
    quantities =
      Map.new([:amount | @quantities], fn field -> {field, get_field(changeset, field) || 0} end)

    expected = state_for(quantities)

    if get_field(changeset, :state) == expected do
      changeset
    else
      add_error(changeset, :state, "must be #{expected} for these quantities")
    end
  end
end
