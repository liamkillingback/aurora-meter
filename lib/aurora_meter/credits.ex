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
  alias AuroraMeter.Credits.Series
  alias AuroraMeter.Period
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

  @typedoc """
  One bucket of a money series. `spent` and `granted` are positive magnitudes
  (a chart never has to think about signs), `net` is `granted - spent`, and
  `balance_after` is the ledger balance after the last entry in the bucket —
  `nil` when the bucket has no entries at all.
  """
  @type money_point :: %{
          date: Date.t(),
          spent: non_neg_integer(),
          granted: non_neg_integer(),
          net: integer(),
          balance_after: integer() | nil
        }

  @typedoc "Totals over a date range, with the range that produced them."
  @type money_total :: %{
          spent: non_neg_integer(),
          granted: non_neg_integer(),
          net: integer(),
          from: Date.t(),
          to: Date.t()
        }

  @typedoc """
  Everything a credit-billed dashboard needs in one read: the balance, this
  period's movement, and the burn/runway derived from the trailing 30 days.
  """
  @type summary :: %{
          balance: integer(),
          available: integer(),
          held: non_neg_integer(),
          promotional: non_neg_integer(),
          currency: String.t(),
          spent_this_period: non_neg_integer(),
          granted_this_period: non_neg_integer(),
          period: Period.t(),
          daily_burn: non_neg_integer() | nil,
          runway_days: non_neg_integer() | nil
        }

  @default_history_kinds [:grant, :settle, :debit, :expire]

  # The window `daily_burn` averages over. Long enough to survive a quiet
  # weekend, short enough that a change in usage shows up within a month.
  @burn_days 30

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
  Like `grant/3`, but says whether the entry was new or a reference that had
  already been granted.

  Decided under the balance row's lock, so two concurrent deliveries of the
  same payment cannot both be told they are the new one — which is what
  decides whether the host announces the payment.
  """
  @spec grant_with_status(term(), pos_integer(), keyword()) ::
          {:ok, txn(), :new | :duplicate} | {:error, Ecto.Changeset.t()}
  def grant_with_status(tenant, amount, opts)
      when is_integer(amount) and amount > 0 and is_list(opts) do
    Ledger.grant_with_status(Tenant.to_key(tenant), amount, opts)
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
  Takes `amount` back off `tenant` for money that has already left the payment
  provider — a refund, a chargeback.

  Unlike `debit/4` this is never refused for want of balance. The money is
  gone whatever the ledger says, so refusing would only make the two disagree;
  the balance may go negative, which is the honest record of a debt. Still
  idempotent on `reference`.
  """
  @spec reverse(term(), pos_integer(), String.t(), map()) ::
          {:ok, txn()} | {:error, :duplicate_reference}
  def reverse(tenant, amount, reference, metadata \\ %{})
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_map(metadata) do
    Ledger.debit(Tenant.to_key(tenant), amount, reference, metadata, allow_negative: true)
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
        # Do not assert on the release. A hold that was closed concurrently is
        # a benign outcome — the same one the `catch` below already treats as
        # such — and matching on {:ok, _} turned the caller's error into a
        # MatchError that buried it.
        _ = release(reference)
        {:error, reason}

      other ->
        _ = release(reference)

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
  Returns `tenant`'s money movement as zero-filled buckets, oldest first.

  Every bucket in the range is present — a bucket the ledger never touched is
  `spent: 0, granted: 0, net: 0, balance_after: nil` — so a chart can render
  the list straight through with no gap handling. Buckets are UTC.

  Options:

    * `:days` — how many days back from `:to`, default 30.
    * `:from` / `:to` — explicit `Date` bounds (inclusive), overriding `:days`.
    * `:bucket` — `:day` (default) or `:month`. A month bucket is dated its
      first day; the first and last month of a range that does not start and
      end on month boundaries are partial.
    * `:kinds` — which kinds count as spend, default
      `[:settle, :debit, :expire]`. `:hold` and `:release` move `held` rather
      than `balance`, so they are never spend and are rejected.

  ## Examples

      AuroraMeter.Credits.spend_history(org, days: 3)
      #=> [%{date: ~D[2026-09-09], spent: 0, granted: 0, net: 0, balance_after: nil},
      #=>  %{date: ~D[2026-09-10], spent: 420_000, granted: 0, net: -420_000,
      #=>    balance_after: 19_580_000},
      #=>  %{date: ~D[2026-09-11], spent: 0, granted: 0, net: 0, balance_after: nil}]

      AuroraMeter.Credits.spend_history(org, bucket: :month, days: 365)

  """
  @spec spend_history(term(), keyword()) :: [money_point()]
  def spend_history(tenant, opts \\ []) do
    {from, to} = Series.range(opts)

    tenant
    |> Tenant.to_key()
    |> Series.history(from, to, Series.bucket(opts), Series.kinds(opts))
  end

  @doc """
  Returns `tenant`'s totals over the same range `spend_history/2` covers, plus
  the resolved range itself.

  ## Examples

      AuroraMeter.Credits.spend_total(org, days: 7)
      #=> %{spent: 1_260_000, granted: 20_000_000, net: 18_740_000,
      #=>   from: ~D[2026-09-05], to: ~D[2026-09-11]}

  """
  @spec spend_total(term(), keyword()) :: money_total()
  def spend_total(tenant, opts \\ []) do
    {from, to} = Series.range(opts)

    totals =
      tenant
      |> Tenant.to_key()
      |> Series.total(from, to, Series.kinds(opts))

    Map.merge(totals, %{from: from, to: to})
  end

  @doc """
  Returns everything a credit-billed dashboard needs about `tenant` in one map:
  the balance snapshot, what moved this billing period, and the burn and runway
  derived from the trailing #{@burn_days} days.

  `daily_burn` is the mean spend per day over those #{@burn_days} days
  (integer division, so a tenant spending a few micro-dollars a month burns
  `0`), and is `nil` when the tenant has spent nothing at all. `runway_days` is
  `available / daily_burn`, and is `nil` whenever `daily_burn` is `nil` or
  zero — there is no honest number of days to show when nothing is being spent.
  The period comes from the configured period source, the same one `quota/2`
  reports.

  ## Examples

      AuroraMeter.Credits.summary(org)
      #=> %{balance: 19_580_000, available: 19_580_000, held: 0, promotional: 0,
      #=>   currency: "usd", spent_this_period: 420_000, granted_this_period: 20_000_000,
      #=>   period: %{start: ~U[2026-09-01 00:00:00Z], end: ~U[2026-10-01 00:00:00Z],
      #=>             source: :calendar},
      #=>   daily_burn: 14_000, runway_days: 1_398}

  """
  @spec summary(term()) :: summary()
  def summary(tenant) do
    tenant_key = Tenant.to_key(tenant)
    snapshot = balance(tenant)
    period = Period.current(tenant)
    this_period = Series.sum_between(tenant_key, period.start, period.end, Series.spend_kinds())
    burn = daily_burn(tenant_key)

    %{
      balance: snapshot.balance,
      available: snapshot.available,
      held: snapshot.held,
      promotional: snapshot.promotional,
      currency: snapshot.currency,
      spent_this_period: this_period.spent,
      granted_this_period: this_period.granted,
      period: period,
      daily_burn: burn,
      runway_days: runway_days(snapshot.available, burn)
    }
  end

  @spec daily_burn(String.t()) :: non_neg_integer() | nil
  defp daily_burn(tenant_key) do
    to = Date.utc_today()
    from = Date.add(to, -(@burn_days - 1))

    case Series.total(tenant_key, from, to, Series.spend_kinds()) do
      %{spent: 0} -> nil
      %{spent: spent} -> div(spent, @burn_days)
    end
  end

  # `nil` burn (nothing spent) and zero burn (spend too small to average to a
  # micro-dollar a day) both mean "no honest runway"; so does an empty or
  # overdrawn balance, which is `0` days rather than a negative number.
  @spec runway_days(integer(), non_neg_integer() | nil) :: non_neg_integer() | nil
  defp runway_days(_available, nil), do: nil
  defp runway_days(_available, 0), do: nil
  defp runway_days(available, burn), do: max(0, div(available, burn))

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
