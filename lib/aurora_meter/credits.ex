defmodule AuroraMeter.Credits do
  @moduledoc """
  A prepaid credit ledger per tenant: grant credit, hold an estimate while work
  runs, settle the actual cost, and read the balance back.

  Plans and counters answer "how many of X may this tenant use this period";
  credits answer "how much money does this tenant have on account". Both are
  keyed by the same tenant term (see `AuroraMeter.Tenant`), and every amount is
  an integer number of **micro-dollars** (1e-6 USD; `AuroraMeter.Credits.Money`
  converts to and from cents, `Decimal` dollars and display strings).

      alias AuroraMeter.Credits

      Credits.grant(org, Money.from_cents(2_000), reference: "stripe:pi_123")
      Credits.balance(org)
      #=> %{balance: 20_000_000, held: 0, available: 20_000_000, ...}

      Credits.with_credits(org, estimate, "job:42", fn ->
        {:ok, result, actual_cost} = run_job()
        {:ok, result, actual_cost}
      end)
      #=> {:ok, result}

  ## Lifecycle

  A `hold/4` reserves an estimate against the available balance (`balance -
  held`), refusing with `:insufficient_credits` when it would go below zero
  (minus `:credits_overdraft_tolerance`). `settle/3` then debits the actual
  cost — which may exceed the hold; the balance can go negative and the
  overrun is reported in telemetry — and releases the whole hold, while
  `release/1` drops the hold without charging. `debit/4` is a hold and a
  settle in one step. `with_credits/4` runs all of that around a function,
  releasing the hold if the function fails or raises.

  Every write takes a `reference`, the caller's idempotency key: a retried
  grant with the same reference returns the original entry instead of crediting
  twice, and a retried hold or debit is refused with `:duplicate_reference`.

  ## Promotional credit

  Grants are `:paid` by default; a `:promotional` grant (a sign-up bonus, a
  goodwill top-up) is consumed before paid credit and may carry an
  `:expires_at`. `expire_due/1` — run it from a scheduler — removes what is
  left of expired grants, never taking the balance below zero. It assumes at
  most one live promotional grant per tenant; see the credits guide.

  ## Storage and side effects

  The ledger uses the configured Ecto repo directly (a row lock plus an
  append inside one transaction), so it **requires the Ecto storage** and
  schema version 3 (`mix aurora_meter.gen.migration --from 3`). After each
  commit it emits `[:aurora_meter, :credits, kind]` telemetry, broadcasts
  `{:aurora_meter, :credits, %{tenant_key, balance, held, available}}` on
  `topic/1`, and when the available balance first crosses below the tenant's
  (or the configured) low-balance threshold fires
  `[:aurora_meter, :credits, :low_balance]`, broadcasts
  `{:aurora_meter, :low_balance, ...}` and calls `:credits_low_balance_handler`.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  import Ecto.Query, only: [from: 2]

  @typedoc "A ledger entry."
  @type txn :: CreditTransaction.t()

  @typedoc "A tenant's balance snapshot, in micro-dollars."
  @type balance :: %{
          balance: integer(),
          held: non_neg_integer(),
          available: integer(),
          promotional: non_neg_integer(),
          currency: String.t(),
          low_balance_threshold: integer() | nil
        }

  @default_history_kinds [:grant, :settle, :debit, :expire]

  @doc """
  Returns `tenant`'s balance snapshot; all zeros (and the configured currency)
  when the tenant has never been granted anything.

  ## Examples

      iex> AuroraMeter.Credits.balance("never_funded_#{System.unique_integer([:positive])}")
      %{balance: 0, held: 0, available: 0, promotional: 0, currency: "usd", low_balance_threshold: nil}

  """
  @spec balance(term()) :: balance()
  def balance(tenant) do
    case tenant |> Tenant.to_key() |> Ledger.fetch() do
      nil ->
        %{
          balance: 0,
          held: 0,
          available: 0,
          promotional: 0,
          currency: Config.credits_currency(),
          low_balance_threshold: nil
        }

      %CreditBalance{} = row ->
        %{
          balance: row.balance,
          held: row.held,
          available: row.balance - row.held,
          promotional: row.promotional,
          currency: row.currency,
          low_balance_threshold: row.low_balance_threshold
        }
    end
  end

  @doc """
  Returns `tenant`'s available balance (`balance - held`) in micro-dollars.

  ## Examples

      iex> AuroraMeter.Credits.available("never_funded_#{System.unique_integer([:positive])}")
      0

  """
  @spec available(term()) :: integer()
  def available(tenant), do: balance(tenant).available

  @doc """
  Whether a hold or debit of `amount` would currently be accepted: the
  available balance plus `:credits_overdraft_tolerance` covers it. Advisory —
  `hold/4` and `debit/4` re-check under the row lock.

  ## Examples

      iex> AuroraMeter.Credits.sufficient?("never_funded_#{System.unique_integer([:positive])}", 1)
      false

  """
  @spec sufficient?(term(), integer()) :: boolean()
  def sufficient?(tenant, amount) when is_integer(amount),
    do: available(tenant) + Config.credits_overdraft_tolerance() >= amount

  @doc """
  Credits `amount` micro-dollars to `tenant`.

  Options:

    * `:reference` — **required**; the idempotency key (a payment id, an
      invoice number). A second grant with the same reference for the same
      tenant returns the existing entry as `{:ok, existing}` without crediting
      again.
    * `:category` — `:paid` (default), `:promotional` or `:adjustment`.
    * `:expires_at` — `DateTime`; promotional grants only.
    * `:metadata` — a map stored on the entry.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.grant(org, 20_000_000, reference: "stripe:pi_123")
      txn.amount
      #=> 20_000_000

      {:ok, ^txn} = AuroraMeter.Credits.grant(org, 20_000_000, reference: "stripe:pi_123")

  """
  @spec grant(term(), pos_integer(), keyword()) :: {:ok, txn()} | {:error, Ecto.Changeset.t()}
  def grant(tenant, amount, opts) when is_integer(amount) and amount > 0 and is_list(opts) do
    Ledger.grant(Tenant.to_key(tenant), amount, opts)
  end

  @doc """
  Reserves `amount` micro-dollars of `tenant`'s available balance under
  `reference`, to be settled or released later.

  Returns `{:error, :insufficient_credits}` when the available balance (plus
  the overdraft tolerance) does not cover it, and `{:error,
  :duplicate_reference}` when a hold with that reference already exists.
  Options: `:metadata`.

  ## Examples

      {:ok, hold} = AuroraMeter.Credits.hold(org, 500_000, "job:42")
      hold.status
      #=> :pending

  """
  @spec hold(term(), pos_integer(), String.t(), keyword()) ::
          {:ok, txn()} | {:error, :insufficient_credits | :duplicate_reference}
  def hold(tenant, amount, reference, opts \\ [])
      when is_integer(amount) and amount > 0 and is_binary(reference) do
    Ledger.hold(Tenant.to_key(tenant), amount, reference, opts)
  end

  @doc """
  Settles the hold under `reference`: debits `actual_amount` and releases the
  whole hold. Never fails for lack of credit — an actual cost above the hold
  takes the balance negative and is flagged as `overrun: true` in the
  `[:aurora_meter, :credits, :settle]` telemetry metadata.

  Returns `{:error, :not_found}` for an unknown reference and
  `{:error, :already_settled}` when the hold was settled or released before.
  Options: `:metadata`.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.settle("job:42", 420_000)
      txn.amount
      #=> -420_000

  """
  @spec settle(String.t(), non_neg_integer(), keyword()) ::
          {:ok, txn()} | {:error, :not_found | :already_settled}
  def settle(reference, actual_amount, opts \\ [])
      when is_binary(reference) and is_integer(actual_amount) and actual_amount >= 0 do
    Ledger.settle(reference, actual_amount, opts)
  end

  @doc """
  Releases the hold under `reference` without charging anything.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.release("job:42")
      txn.kind
      #=> :release

  """
  @spec release(String.t()) :: {:ok, txn()} | {:error, :not_found | :already_settled}
  def release(reference) when is_binary(reference), do: Ledger.release(reference)

  @doc """
  Debits `amount` micro-dollars from `tenant` in one step (no hold), with the
  same sufficiency and duplicate-reference rules as `hold/4`.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.debit(org, 1_000, "req:abc", %{"model" => "small"})
      txn.metadata
      #=> %{"model" => "small"}

  """
  @spec debit(term(), pos_integer(), String.t(), map()) ::
          {:ok, txn()} | {:error, :insufficient_credits | :duplicate_reference}
  def debit(tenant, amount, reference, metadata \\ %{})
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_map(metadata) do
    Ledger.debit(Tenant.to_key(tenant), amount, reference, metadata)
  end

  @doc """
  Holds `estimate`, runs `fun`, and settles or releases depending on what it
  returns.

  `fun` must return `{:ok, result, actual_amount}` — the hold is settled for
  `actual_amount` and `{:ok, result}` is returned — or `{:error, reason}`,
  which releases the hold and is returned as-is. If `fun` raises, throws or
  exits, the hold is released and the error propagates. Any other return
  value releases the hold and raises `ArgumentError`.

  Returns `{:error, :insufficient_credits}` (or `:duplicate_reference`)
  without running `fun` when the hold is refused.

  ## Examples

      AuroraMeter.Credits.with_credits(org, 500_000, "job:42", fn ->
        {:ok, generate(), 420_000}
      end)
      #=> {:ok, result}

  """
  @spec with_credits(term(), pos_integer(), String.t(), (-> {:ok, result, non_neg_integer()}
                                                            | {:error, term()})) ::
          {:ok, result} | {:error, :insufficient_credits | :duplicate_reference | term()}
        when result: term()
  def with_credits(tenant, estimate, reference, fun) when is_function(fun, 0) do
    with {:ok, _hold} <- hold(tenant, estimate, reference) do
      run_held(reference, fun)
    end
  end

  @spec run_held(String.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp run_held(reference, fun) do
    case fun.() do
      {:ok, result, actual} when is_integer(actual) and actual >= 0 ->
        {:ok, _txn} = settle(reference, actual)
        {:ok, result}

      {:error, reason} ->
        {:ok, _txn} = release(reference)
        {:error, reason}

      other ->
        {:ok, _txn} = release(reference)

        raise ArgumentError,
              "with_credits/4 expects {:ok, result, actual_amount} or {:error, reason}, " <>
                "got: #{inspect(other)}"
    end
  catch
    kind, reason ->
      # Best effort: the hold may already be closed if the error came from
      # settle/release themselves; the caller's error is the one to surface.
      release(reference)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Returns `tenant`'s ledger entries, newest first.

  Options:

    * `:limit` — default 50.
    * `:before` — a `DateTime`; only entries inserted strictly before it (pass
      the last entry's `inserted_at` to page).
    * `:kinds` — which kinds to include; defaults to
      `#{inspect(@default_history_kinds)}`, i.e. holds and releases (the
      bookkeeping around a settlement) are hidden unless asked for.

  ## Examples

      AuroraMeter.Credits.history(org, limit: 2)
      #=> [%CreditTransaction{kind: :settle, ...}, %CreditTransaction{kind: :grant, ...}]

      AuroraMeter.Credits.history(org, kinds: [:hold, :release])

  """
  @spec history(term(), keyword()) :: [txn()]
  def history(tenant, opts \\ []) do
    tenant_key = Tenant.to_key(tenant)
    limit = Keyword.get(opts, :limit, 50)
    kinds = Keyword.get(opts, :kinds, @default_history_kinds)

    query =
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant_key and t.kind in ^kinds,
        order_by: [desc: t.inserted_at],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :before) do
        nil -> query
        %DateTime{} = before -> from(t in query, where: t.inserted_at < ^before)
      end

    Config.repo().all(query)
  end

  @doc """
  Sets (or with `nil` clears) `tenant`'s own low-balance threshold in
  micro-dollars, overriding `:credits_low_balance_threshold`.

  ## Examples

      {:ok, row} = AuroraMeter.Credits.set_low_balance_threshold(org, 5_000_000)
      row.low_balance_threshold
      #=> 5_000_000

  """
  @spec set_low_balance_threshold(term(), integer() | nil) :: {:ok, CreditBalance.t()}
  def set_low_balance_threshold(tenant, threshold)
      when is_integer(threshold) or is_nil(threshold) do
    Ledger.set_low_balance_threshold(Tenant.to_key(tenant), threshold)
  end

  @doc """
  Expires promotional grants whose `expires_at` is at or before `now`
  (default: now), removing what is left of each — `min(promotional balance,
  grant amount)`, never below zero — as an `:expire` entry referenced
  `"expire:<grant id>"`, and stamping the grant's `expired_at`. Returns the
  number of grants expired. Run it periodically (a `Quantum` job, an Oban
  cron, or a plain timer).

  Assumes at most one live promotional grant per tenant: with several, the
  balance's `promotional` part is their sum and the first to expire may take
  credit a later grant contributed.

  ## Examples

      iex> {:ok, n} = AuroraMeter.Credits.expire_due()
      iex> is_integer(n)
      true

  """
  @spec expire_due(DateTime.t()) :: {:ok, non_neg_integer()}
  def expire_due(now \\ DateTime.utc_now()), do: Ledger.expire_due(now)

  @doc """
  Subscribes the calling process to `tenant`'s credit updates:
  `{:aurora_meter, :credits, %{tenant_key, balance, held, available}}` after
  every ledger entry and `{:aurora_meter, :low_balance, %{tenant_key,
  available, threshold}}` on a low-balance crossing.

  ## Examples

      iex> AuroraMeter.Credits.subscribe("org_1")
      :ok

  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(tenant),
    do: PubSub.subscribe(Config.pubsub(), tenant |> Tenant.to_key() |> topic())

  @doc """
  The PubSub topic for a tenant key's credit updates.

  ## Examples

      iex> AuroraMeter.Credits.topic("org_1")
      "aurora_meter:credits:org_1"

  """
  @spec topic(String.t()) :: String.t()
  def topic(tenant_key) when is_binary(tenant_key), do: Ledger.topic(tenant_key)
end
