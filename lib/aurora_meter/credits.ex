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
  `:expires_at`. `reverse/4` — a refund or chargeback — is exempt: it takes a
  paid grant back and leaves the promotional figure alone. `expire_due/1` — run it from a scheduler — removes what is
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

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.CurrencyMismatchError
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Reconciliation
  alias AuroraMeter.Credits.Series
  alias AuroraMeter.Period
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  import Ecto.Query, only: [from: 2]

  @typedoc "A ledger entry."
  @type txn :: CreditTransaction.t()

  @typedoc """
  What one `reconcile_holds/1` run examined and what it did.

  `kept` counts every hold the run left exactly as it found it, whatever the
  reason: the callback said `:keep`, it failed, it timed out, or none was
  configured. The telemetry event carries the reason per hold.

  `cursor` is `{inserted_at, id}` of the last hold examined when the page was
  full, and `nil` when it was not, so a caller that pages knows whether more
  work is waiting. The map may gain keys in a later release.
  """
  @type reconciliation_report :: %{
          examined: non_neg_integer(),
          kept: non_neg_integer(),
          released: non_neg_integer(),
          settled: non_neg_integer(),
          already_closed: non_neg_integer(),
          failed: non_neg_integer(),
          cursor: {DateTime.t(), Ecto.UUID.t()} | nil
        }

  @typedoc """
  What one page of `expire_due/2` examined.

  `skipped` counts a grant the ledger refused: it was expired by another run
  first, or a pending hold covers the whole of what is left of it and taking it
  now would push the balance below what the hold reserved. `failed` counts one
  whose transaction ended badly, which is logged with the grant id and left for
  the next run; one grant failing never fails the sweep, because a database
  that cannot be reached for one tenant must not starve the grants behind it.

  `cursor` is `{expires_at, id}` of the last grant examined when the page came
  back full, and `nil` when it did not, so a caller that pages knows whether
  more work is waiting. The map may gain keys in a later release.
  """
  @type expiry_report :: %{
          examined: non_neg_integer(),
          expired: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          cursor: {DateTime.t(), Ecto.UUID.t()} | nil
        }

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
  spendable balance plus `:credits_overdraft_tolerance` covers it. Advisory:
  `hold/4` and `debit/4` re-check under the row lock.

  Spendable is `balance - held` on a wallet that has not been cut over to
  credit lots. On one that has, it is the sum of the lots that are still
  eligible to be spent, less any `debt`, and the two differences are
  deliberate:

    * credit whose `expires_at` has passed is not spendable, even though the
      expiry sweep has not reached it yet. In 0.4.0 it stayed spendable until
      the next sweep, which made expiry a race rather than bookkeeping.
    * a wallet that owes money cannot spend until an incoming grant has repaid
      the debt. `hold/4` and `debit/4` follow, so both refuse with
      `:insufficient_credits` while `debt` is outstanding.

  ## Examples

      iex> AuroraMeter.Credits.sufficient?("never_funded_#{System.unique_integer([:positive])}", 1)
      false

  """
  @spec sufficient?(term(), integer()) :: boolean()
  def sufficient?(tenant, amount) when is_integer(amount),
    do:
      tenant
      |> Tenant.to_key()
      |> Ledger.spendable()
      |> Kernel.+(Config.credits_overdraft_tolerance()) >= amount

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
    * `:source`: a map naming where the money came from, stored on the credit
      lot this grant creates. Ignored on a wallet that has not been cut over to
      lots. The keys Aurora Meter reads are `"payment_intent_id"` (what a refund
      finds the lots it may reverse by), `"checkout_session_id"`, `"promotion"`,
      `"recurrence_key"`, `"plan_id"` and `"plan_version"`; anything else is
      carried and not interpreted.

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

  Options:

    * `:metadata` — stored on the settle entry.
    * `:tenant` — assert the hold belongs to this tenant. A hold whose
      `tenant_key` is anything else answers `{:error, :not_found}` and nothing
      is written. Without it the reference alone identifies the hold, which is
      what it has always done and is safe because `(kind, reference)` is unique
      across the table. Pass it when the reference came from a listing rather
      than from the caller that took the hold: it is the assertion that the row
      being closed is the row that was read.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.settle("job:42", 420_000)
      txn.amount
      #=> -420_000

  """
  @spec settle(String.t(), non_neg_integer(), keyword()) ::
          {:ok, txn()} | {:error, :not_found | :already_settled}
  def settle(reference, actual_amount, opts \\ [])
      when is_binary(reference) and is_integer(actual_amount) and actual_amount >= 0 do
    Ledger.settle(reference, actual_amount, tenant_opt(opts))
  end

  @doc """
  Releases the hold under `reference` without charging anything.

  Options: `:tenant`, exactly as `settle/3` documents it.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.release("job:42")
      txn.kind
      #=> :release

  """
  @spec release(String.t(), keyword()) :: {:ok, txn()} | {:error, :not_found | :already_settled}
  def release(reference, opts \\ []) when is_binary(reference) and is_list(opts),
    do: Ledger.release(reference, tenant_opt(opts))

  # `:tenant` is the host's own term at the facade and a key at the ledger, the
  # same translation every other function here makes. Absent stays absent: the
  # ledger checks nothing when it is not told what to check, which is what keeps
  # every existing caller's behaviour identical.
  @spec tenant_opt(keyword()) :: keyword()
  defp tenant_opt(opts) do
    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant} -> Keyword.put(opts, :tenant_key, Tenant.to_key(tenant))
      :error -> opts
    end
  end

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

  The entry is categorised `:reversal`, which keeps it out of two places it
  does not belong: it never consumes promotional credit (a refunded top-up
  must not quietly spend a sign-up bonus, leaving nothing to expire), and
  `spend_history/2` reports it against grants rather than as spend.
  """
  @spec reverse(term(), pos_integer(), String.t(), map()) ::
          {:ok, txn()} | {:error, :duplicate_reference}
  def reverse(tenant, amount, reference, metadata \\ %{})
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_map(metadata) do
    Ledger.debit(Tenant.to_key(tenant), amount, reference, metadata,
      allow_negative: true,
      category: :reversal
    )
  end

  @doc """
  Holds that are still open and were taken before `:older_than`, oldest first.

  For a host that has to find reservations nothing will ever close. A hold is
  taken before the row that remembers it exists — there is no way to make those
  two one write, since they are in different databases as often as not — so a
  process killed in between leaves money reserved against a tenant with nothing
  left pointing at it. Only the host can tell such a hold from one whose work
  is simply still running, so the ledger's part is to list them.

  `reconcile_holds/1` is the other half: this lists them, that asks the host
  what to do about each one and applies the answer.

  Options:

    * `:older_than` — required, a `DateTime`. Build it from
      `AuroraMeter.Clock.now/0`, which is the clock the hold's `inserted_at` was
      stamped by.
    * `:limit` — default 200.
    * `:reference_prefix` — narrow to one kind of work; a prefix match.
    * `:tenant` — only this tenant's holds.
    * `:after` — a `{inserted_at, id}` pair from the last row of the previous
      page. Results are ordered by `(inserted_at, id)`, so paging with this
      returns every hold exactly once even when several were written in the same
      microsecond. Ordering by `inserted_at` alone, which is what releases
      before 0.6.0 did, could skip one and repeat another.

  ## Examples

      AuroraMeter.Credits.pending_holds(
        older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second),
        reference_prefix: "doc:"
      )

  """
  @spec pending_holds(keyword()) :: [txn()]
  def pending_holds(opts), do: Ledger.pending_holds(tenant_key_opt(opts))

  @spec tenant_key_opt(keyword()) :: keyword()
  defp tenant_key_opt(opts) do
    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant} -> Keyword.put(opts, :tenant_key, Tenant.to_key(tenant))
      :error -> opts
    end
  end

  @doc """
  Asks the configured `AuroraMeter.Credits.HoldReconciler` about every hold
  older than `:older_than`, and applies what it says.

  This is the recovery half of `pending_holds/1`. A hold is taken before the row
  that remembers it exists, so a process killed in between leaves money reserved
  with nothing left pointing at it; only the host can tell such a hold from one
  whose work is still running, and this is how it says which.

  Run it from a scheduler. It holds no state between holds, takes no global
  lock, and two nodes running it at the same instant produce at most one
  terminal transition per hold: the loser is told `:already_closed`.

  **Nothing here releases money by itself.** With no `:credits_hold_reconciler`
  configured every hold is kept. A callback that raises, hangs, exits or returns
  something that is not a decision also keeps the hold. Age makes a hold a
  candidate to be asked about, never a candidate to be released.

  Options:

    * `:older_than` — required, a `DateTime`. Omitting it raises `KeyError`.
    * `:limit` — default 200, the most holds one run examines.
    * `:tenant` — sweep one tenant.
    * `:reference_prefix` — sweep one kind of work.
    * `:after` — a cursor from a previous report, to page.
    * `:reconciler` — use this instead of the configured one. A module, a
      `{module, function}` pair or a one-argument function. Passing
      `fn _ -> :keep end` is a dry run: it reports what a sweep would look at
      and writes nothing.

  The report is a map that may gain keys in a later release; match on the keys
  you need rather than on the whole map. `:cursor` is `{inserted_at, id}` when
  the page was full and `nil` when it was not, so a caller knows whether more
  work is waiting. Every examined hold emits
  `[:aurora_meter, :credits, :hold_reconciliation]`; see
  [Telemetry](telemetry.md).

  ## Examples

      {:ok, report} =
        AuroraMeter.Credits.reconcile_holds(
          older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second),
          reconciler: fn
            %{reference: "job:" <> id} -> MyApp.Jobs.decide(id)
            _hold -> :keep
          end
        )

      report.released
      #=> 0

  """
  @spec reconcile_holds(keyword()) :: {:ok, reconciliation_report()} | {:error, term()}
  def reconcile_holds(opts) when is_list(opts), do: Reconciliation.run(opts)

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
  @spec with_credits(
          term(),
          pos_integer(),
          String.t(),
          (-> {:ok, result, non_neg_integer()}
              | {:error, term()})
        ) ::
          {:ok, result} | {:error, :insufficient_credits | :duplicate_reference | term()}
        when result: term()
  def with_credits(tenant, estimate, reference, fun) when is_function(fun, 0) do
    with {:ok, _hold} <- hold(tenant, estimate, reference) do
      run_held(Tenant.to_key(tenant), reference, fun)
    end
  end

  @spec run_held(String.t(), String.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp run_held(tenant_key, reference, fun) do
    case fun.() do
      {:ok, result, actual} when is_integer(actual) and actual >= 0 ->
        settled(tenant_key, reference, actual, result)

      {:error, reason} ->
        # Do not assert on the release. A hold that was closed concurrently is
        # a benign outcome — the same one the `catch` below already treats as
        # such — and matching on {:ok, _} turned the caller's error into a
        # MatchError that buried it.
        _ = release(reference, tenant: tenant_key)
        {:error, reason}

      other ->
        _ = release(reference, tenant: tenant_key)

        raise ArgumentError,
              "with_credits/4 expects {:ok, result, actual_amount} or {:error, reason}, " <>
                "got: #{inspect(other)}"
    end
  catch
    kind, reason ->
      # Best effort: the hold may already be closed if the error came from
      # settle/release themselves; the caller's error is the one to surface.
      release(reference, tenant: tenant_key)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # The work ran. Charging for it is the only acceptable outcome, and until
  # build unit 05b this line was `{:ok, _txn} = settle(reference, actual)`
  # (open finding L4). Nothing could close a hold behind a running
  # `with_credits/4` then, so the match never failed; `reconcile_holds/1` makes
  # it possible, and the match would have raised a `MatchError` inside the
  # caller's process, been caught below, released the hold a second time and
  # re-raised. The caller would have seen a `MatchError` instead of its result
  # and the executed cost would have been lost.
  @spec settled(String.t(), String.t(), non_neg_integer(), term()) ::
          {:ok, term()} | {:error, term()}
  defp settled(tenant_key, reference, actual, result) do
    case settle(reference, actual, tenant: tenant_key) do
      {:ok, _txn} ->
        {:ok, result}

      {:error, reason} when reason in [:already_settled, :not_found] ->
        closed_by_other(tenant_key, reference, actual, result)

      # Not a concurrent close: a storage failure, say. The caller asked for the
      # work to be charged and it was not, so it is told, rather than being
      # handed an {:ok, result} whose cost silently vanished.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec closed_by_other(String.t(), String.t(), non_neg_integer(), term()) :: {:ok, term()}
  defp closed_by_other(tenant_key, reference, actual, result) do
    hold = Ledger.fetch_hold(reference)
    now = Clock.now()

    case hold do
      %CreditTransaction{status: :settled} ->
        # Somebody already took the cost: a reconciler's {:settle, n} decision,
        # or a duplicate delivery of this same job. One settle per hold is the
        # contract, so this one stands and the caller gets its result.
        Reconciliation.emit_external(hold, :settled_by_other, now)
        {:ok, result}

      _released_or_gone ->
        # The reservation went back to the tenant and the work ran anyway. Never
        # hide executed cost by pretending settlement was not owed: record it as
        # its own debit, idempotent on its reference, and let the balance go
        # negative if that is the truth.
        if hold, do: Reconciliation.emit_external(hold, :released_by_other, now)
        record_missed_settle(tenant_key, reference, actual)
        {:ok, result}
    end
  end

  @spec record_missed_settle(String.t(), String.t(), non_neg_integer()) :: :ok
  defp record_missed_settle(_tenant_key, _reference, 0), do: :ok

  defp record_missed_settle(tenant_key, reference, actual) do
    _ =
      Ledger.debit(
        tenant_key,
        actual,
        "settle_missed:" <> reference,
        %{"reason" => "hold_released_before_settle", "hold_reference" => reference},
        allow_negative: true
      )

    :ok
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
        # `seq` and not `inserted_at`: the ledger's account of its own order
        # cannot rest on a wall clock that steps backwards (L20, X59, X100).
        # `:before` still filters on `inserted_at`, which is the documented
        # option and is a filter rather than a keyset cursor; 06c owns the
        # keyset form (L8).
        order_by: [desc: t.seq],
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
    period = Period.current!(tenant)
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
    to = Clock.today()
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
  # `db_now/0`, not `now/0`: this compares against `expires_at`, a persisted
  # timestamp, and decides whether a tenant's money is still theirs. Every node
  # running expiry must agree on "now", and the database is the one clock they
  # share (`AuroraMeter.Clock`). It is already a database operation, so the
  # round trip costs nothing worth counting.
  def expire_due(now \\ Clock.db_now()), do: Ledger.expire_due(now)

  @doc """
  One bounded page of the expiry sweep, from a keyset cursor.

  `expire_due/1` examines every due grant in one pass, which is fine for a small
  installation and is unbounded work for a large one. This is the same sweep,
  paged.

  Options:

    * `:limit` - the most grants to examine in this page. Unbounded when absent,
      which makes `expire_due(now, [])` exactly `expire_due(now)` with a report
      instead of a count.
    * `:after` - `{expires_at, id}`, the cursor a previous page returned.

  Returns `{:ok, report}`. `report.cursor` is `{expires_at, id}` when the page
  came back full and `nil` when the scan reached its end.

  **Pin `now` across the pages of one scan.** The candidate set is
  `expires_at <= now`, which moves, so recomputing `now` between pages would
  resume a cursor into a different set. `AuroraMeter.Oban.CreditExpiry` stores
  the instant in its checkpoint beside the cursor and hands the same one back
  until the scan finishes.

  ## Examples

      {:ok, report} = AuroraMeter.Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 200)
      report.cursor
      #=> nil

  """
  @spec expire_due(DateTime.t(), keyword()) :: {:ok, expiry_report()}
  def expire_due(now, opts) when is_list(opts), do: Ledger.expire_due(now, opts)

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

  @doc """
  Raises unless every stored credit balance carries `:credits_currency`.

  The currency is stamped once, when a balance row is created, and nothing
  re-reads it. Changing `:credits_currency` on a wallet set that already has
  rows therefore leaves two currencies side by side and every total across them
  is meaningless. Aurora Meter's own boot checks call this once per node when the
  supervision tree starts; a host may also call it from its own health check.

  The check is **skipped**, with one `:info` line, when the repo is not
  started, the credit tables are absent, or the query fails for any other
  reason: a host that has not run the credit migration, or that starts Aurora
  Meter before its repo, must still boot.
  """
  @spec assert_currency!() :: :ok
  def assert_currency! do
    configured = Config.credits_currency()

    case stored_currencies() do
      {:ok, rows} -> compare_currencies!(configured, rows)
      {:skipped, reason} -> skip_currency_check(reason)
    end
  end

  @spec compare_currencies!(String.t(), [{String.t(), non_neg_integer()}]) :: :ok
  defp compare_currencies!(configured, rows) do
    case Enum.reject(rows, fn {currency, _count} -> currency == configured end) do
      [] -> :ok
      mismatched -> raise CurrencyMismatchError, configured: configured, stored: mismatched
    end
  end

  @spec skip_currency_check(String.t()) :: :ok
  defp skip_currency_check(reason) do
    Logger.info("AuroraMeter: credit currency check skipped: #{reason}")
  end

  # `limit: 5` because the message only has to show the operator that there is a
  # problem and roughly how big it is, not enumerate a corrupted wallet set.
  @spec stored_currencies() :: {:ok, [{String.t(), non_neg_integer()}]} | {:skipped, String.t()}
  defp stored_currencies do
    query =
      from(b in CreditBalance,
        group_by: b.currency,
        select: {b.currency, count(b.id)},
        limit: 5
      )

    {:ok, Config.repo().all(query)}
  rescue
    error -> {:skipped, Exception.message(error)}
  catch
    :exit, reason -> {:skipped, "the repo is not available (#{inspect(reason)})"}
  end
end
