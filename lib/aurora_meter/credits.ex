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
  cost (which may exceed the hold; the balance can go negative and the
  overrun is reported in telemetry) and releases the whole hold, while
  `release/1` drops the hold without charging. `debit/4` is a hold and a
  settle in one step. `with_credits/4` runs all of that around a function,
  releasing the hold if the function fails or raises.

  Every write takes a `reference`, the caller's idempotency key: a retried
  grant with the same reference returns the original entry instead of crediting
  twice, and a retried hold or debit is refused with `:duplicate_reference`.

  ## Promotional credit

  Grants are `:paid` by default; a `:promotional` grant (a sign-up bonus, a
  goodwill top-up) is consumed before paid credit and may carry an
  `:expires_at`. `reverse/4` (a refund or chargeback) is exempt: it takes a
  paid grant back and leaves the promotional figure alone. `expire_due/1`, which
  you run from a scheduler, removes what is left of expired grants, never taking
  the balance below zero.

  Several live promotional grants are supported, and were before this paragraph
  said so. Spending is attributed **soonest expiry first**, so each grant's
  remainder is well defined and the first grant to expire cannot reclaim credit
  a later one contributed. On a wallet cut over to credit lots the same rule is
  the lots' own spend order. See the credits guide.

  ## Storage and side effects

  The ledger uses the configured Ecto repo directly (a row lock plus an
  append inside one transaction), so it **requires the Ecto storage** and
  schema version 3 (`mix aurora_meter.gen.migration --from 3`). After each
  commit it emits `[:aurora_meter, :credits, kind]` telemetry, broadcasts
  `{:aurora_meter, :credits, %{tenant_key, balance, held, available, spendable,
  debt, expired}}` on `topic/1`, and when the **spendable** balance first
  crosses below the tenant's (or the configured) low-balance threshold fires
  `{:aurora_meter, :low_balance, ...}`, calls `:credits_low_balance_handler`
  once per crossing in a supervised watcher the caller does not wait for, and
  emits `[:aurora_meter, :credits, :low_balance]` when that watcher knows how
  the handler ended.

  **"After each commit" means after the outermost one.** A ledger call made
  inside a host's own `Repo.transaction/1` queues its effects instead of running
  them, because what its inner transaction returning means there is a savepoint
  release rather than a commit. `after_commit/1` runs them; see that function.
  """

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.CurrencyMismatchError
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Credits.Reconciliation
  alias AuroraMeter.Credits.Recurrences
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

  @typedoc """
  A tenant's balance snapshot, in micro-dollars.

  Six of the figures are the ones this map has always carried and none of them
  changed meaning: `balance` is signed, `held` is the sum of pending holds,
  `available` is `balance - held`, `promotional` is the promotional part of
  `balance`.

  Four are new, and they exist because after credit lots `balance - held` is no
  longer the whole story:

    * `spendable`: what a hold or a debit would actually be allowed to take,
      and exactly the figure `sufficient?/2` compares against. It differs from
      `available` on a cut-over wallet by three things: credit whose
      `expires_at` has passed is excluded even before the sweep reaches it,
      `debt` is subtracted, and **it is never positive while `debt` is
      outstanding**, because `hold/4` and `debit/4` refuse outright there
      (`:debt_outstanding`) however much credit the wallet is holding. Where
      the debt is larger than what is left it stays negative rather than being
      clamped, so a reader can see how deep the wallet is.
    * `debt`: executed cost the wallet could not fund, or money handed back to
      a payment provider that the wallet had already spent. Recorded rather
      than hidden; the next grant of any category repays it out of the lot it
      creates, before any of that lot becomes available. Credit the wallet
      **already holds** repays it too, unless that credit is promotional: a
      promotion is never consumed to pay off a debt. So a wallet can report a
      positive `balance` and a positive `promotional` beside a positive `debt`,
      and spend none of it until a grant clears the debt, which is why
      `spendable` and `promotional_spendable` both read zero there.
    * `expired`: value destroyed by expiry, kept apart from value spent so a
      reader is never left inferring which of the two happened.
    * `promotional_spendable`: the part of `spendable` that came from
      promotional lots, so it answers the same question about the same planner
      and is zero in the same states. The promotional credit the wallet
      **holds** is `promotional`, which is not reduced by `debt` and does not
      move when a debt freezes the wallet.

  **Which of these are claims about spending and which are totals.**
  `spendable` and `promotional_spendable` report what `hold/4` and `debit/4`
  would accept, and are the two the planner's own refusal is mirrored into
  (repair unit R3, findings X357 and X361). `balance`, `promotional`, `held`,
  `debt` and `expired` report what the wallet holds, owes or has lost, and are
  not reduced by a refusal. `available` is the arithmetic identity
  `balance - held` and stays one: it is what `runway_days` divides and what
  `available/1` returns, and it can be positive on a wallet that may not spend.

  On a wallet that has not been cut over to lots (`lots_enabled_at IS NULL`,
  which is every wallet until `mix aurora_meter.credits.migrate_lots` runs)
  `spendable == available`, `promotional_spendable == promotional`, and `debt`
  and `expired` are both `0`.
  """
  @type balance :: %{
          balance: integer(),
          held: non_neg_integer(),
          available: integer(),
          spendable: integer(),
          promotional: non_neg_integer(),
          promotional_spendable: non_neg_integer(),
          debt: non_neg_integer(),
          expired: non_neg_integer(),
          currency: String.t(),
          low_balance_threshold: integer() | nil
        }

  @typedoc """
  One bucket of a money series. `spent` and `granted` are positive magnitudes
  (a chart never has to think about signs), `net` is `granted - spent`, and
  `balance_after` is the ledger balance after the last entry in the bucket, and
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
          spendable: integer(),
          held: non_neg_integer(),
          promotional: non_neg_integer(),
          promotional_spendable: non_neg_integer(),
          debt: non_neg_integer(),
          expired: non_neg_integer(),
          currency: String.t(),
          spent_this_period: non_neg_integer(),
          granted_this_period: non_neg_integer(),
          period: Period.t(),
          daily_burn: non_neg_integer() | nil,
          runway_days: non_neg_integer() | nil
        }

  @typedoc """
  An opaque `history/2` cursor. Get one from `cursor/1` and pass it back as
  `:cursor`; it is the ledger's own ordering key and nothing else should be read
  into it.
  """
  @opaque cursor :: integer()

  # `:reverse` is here so that the default view is unchanged **in content** by
  # schema version 9's new kind. Before it, a reversal was a `:debit` and
  # appeared; naming the new kind is what keeps it appearing.
  @default_history_kinds [:grant, :settle, :debit, :reverse, :expire]

  # The window `daily_burn` averages over. Long enough to survive a quiet
  # weekend, short enough that a change in usage shows up within a month.
  @burn_days 30

  @doc """
  Returns `tenant`'s balance snapshot; all zeros (and the configured currency)
  when the tenant has never been granted anything.

  See `t:balance/0` for what each of the ten figures means, and in particular
  for the difference between `available` and `spendable`.

  ## Examples

      iex> AuroraMeter.Credits.balance("never_funded_#{System.unique_integer([:positive])}")
      %{balance: 0, held: 0, available: 0, spendable: 0, promotional: 0,
        promotional_spendable: 0, debt: 0, expired: 0, currency: "usd",
        low_balance_threshold: nil}

  """
  @spec balance(term()) :: balance()
  def balance(tenant) do
    case tenant |> Tenant.to_key() |> Ledger.fetch() do
      nil ->
        %{
          balance: 0,
          held: 0,
          available: 0,
          spendable: 0,
          promotional: 0,
          promotional_spendable: 0,
          debt: 0,
          expired: 0,
          currency: Config.credits_currency(),
          low_balance_threshold: nil
        }

      %CreditBalance{} = row ->
        figures = Ledger.figures(row)

        %{
          balance: row.balance,
          held: row.held,
          available: row.balance - row.held,
          spendable: figures.spendable,
          promotional: row.promotional,
          promotional_spendable: figures.promotional_spendable,
          debt: row.debt,
          expired: row.expired,
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
      the debt. `hold/4` and `debit/4` refuse with `:debt_outstanding` while
      `debt` is outstanding, whatever credit the wallet is holding, and this
      function answers `false` for every amount in that state, because
      `spendable` is never positive there (repair unit R3, findings X357 and
      X361).

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

    * `:reference`: **required**; the idempotency key (a payment id, an
      invoice number). A second grant with the same reference for the same
      tenant returns the existing entry as `{:ok, existing}` without crediting
      again.
    * `:category`: `:paid` (default), `:promotional` or `:adjustment`.
    * `:expires_at`: `DateTime`; promotional grants only.
    * `:metadata`: a map stored on the entry.
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
  @spec grant(term(), pos_integer(), keyword()) ::
          {:ok, txn()} | {:error, :duplicate_reference | Ecto.Changeset.t()}
  def grant(tenant, amount, opts) when is_integer(amount) and amount > 0 and is_list(opts) do
    Money.assert_range!(amount)
    assert_unreserved!(Keyword.get(opts, :reference), "grant/3")
    Ledger.grant(Tenant.to_key(tenant), amount, opts)
  end

  @doc """
  Like `grant/3`, but says whether the entry was new or a reference that had
  already been granted.

  Decided under the balance row's lock, so two concurrent deliveries of the
  same payment cannot both be told they are the new one, which is what
  decides whether the host announces the payment.
  """
  @spec grant_with_status(term(), pos_integer(), keyword()) ::
          {:ok, txn(), :new | :duplicate} | {:error, :duplicate_reference | Ecto.Changeset.t()}
  def grant_with_status(tenant, amount, opts)
      when is_integer(amount) and amount > 0 and is_list(opts) do
    Money.assert_range!(amount)
    assert_unreserved!(Keyword.get(opts, :reference), "grant_with_status/3")
    Ledger.grant_with_status(Tenant.to_key(tenant), amount, opts)
  end

  @doc """
  Reserves `amount` micro-dollars of `tenant`'s available balance under
  `reference`, to be settled or released later.

  Returns `{:error, :insufficient_credits}` when the available balance (plus
  the overdraft tolerance) does not cover it, `{:error, :debt_outstanding}`
  when the wallet owes money (see `t:balance/0` and the "Debt" section of
  `docs/credits.md`: nothing may be held or debited until a grant clears the
  debt, whatever credit the wallet is holding), and
  `{:error, :duplicate_reference}` when a hold with that reference already
  exists. Options: `:metadata`.

  ## Examples

      {:ok, hold} = AuroraMeter.Credits.hold(org, 500_000, "job:42")
      hold.status
      #=> :pending

  """
  @spec hold(term(), pos_integer(), String.t(), keyword()) ::
          {:ok, txn()}
          | {:error, :insufficient_credits | :debt_outstanding | :duplicate_reference}
  def hold(tenant, amount, reference, opts \\ [])
      when is_integer(amount) and amount > 0 and is_binary(reference) do
    Money.assert_range!(amount)
    assert_unreserved!(reference, "hold/4")
    Ledger.hold(Tenant.to_key(tenant), amount, reference, opts)
  end

  @doc """
  Settles the hold under `reference`: debits `actual_amount` and releases the
  whole hold. Never fails for lack of credit: an actual cost above the hold
  takes the balance negative and is flagged as `overrun: true` in the
  `[:aurora_meter, :credits, :settle]` telemetry metadata.

  Returns `{:error, :not_found}` for an unknown reference and
  `{:error, :already_settled}` when the hold was settled or released before.

  Options:

    * `:metadata`: stored on the settle entry.
    * `:tenant`: assert the hold belongs to this tenant. A hold whose
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
    Money.assert_range!(actual_amount)
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
  same sufficiency, debt and duplicate-reference rules as `hold/4`, so it
  refuses with `:insufficient_credits`, `:debt_outstanding` or
  `:duplicate_reference` for the same reasons.

  ## Examples

      {:ok, txn} = AuroraMeter.Credits.debit(org, 1_000, "req:abc", %{"model" => "small"})
      txn.metadata
      #=> %{"model" => "small"}

  """
  @spec debit(term(), pos_integer(), String.t(), map()) ::
          {:ok, txn()}
          | {:error, :insufficient_credits | :debt_outstanding | :duplicate_reference}
  def debit(tenant, amount, reference, metadata \\ %{})
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_map(metadata) do
    Money.assert_range!(amount)
    assert_unreserved!(reference, "debit/4")
    Ledger.debit(Tenant.to_key(tenant), amount, reference, metadata)
  end

  @doc """
  Takes `amount` back off `tenant` for money that has already left the payment
  provider: a refund, or a chargeback.

  Unlike `debit/4` this is never refused for want of balance. The money is
  gone whatever the ledger says, so refusing would only make the two disagree;
  the balance may go negative, which is the honest record of a debt. Still
  idempotent on `reference`.

  The entry is categorised `:reversal`, which keeps it out of two places it
  does not belong: it never consumes promotional credit (a refunded top-up
  must not quietly spend a sign-up bonus, leaving nothing to expire), and
  `spend_history/2` reports it against grants rather than as spend.

  ## Which credit it takes back

  This is the **wallet-wide** reversal, for a caller with no record of which
  payment funded what. A caller that has the payment should use
  `reverse_lot/4`, which is scoped to that payment's own lots and capped by
  them.

  On a legacy wallet the entry moves `balance` and leaves `promotional` alone,
  as it always has. On a wallet the allocator owns it takes the credit back off
  the wallet's **non-promotional** lots, in spend order, draining `available`
  first, then `consumed`, then `reserved`, and writing `reversed` on each lot it
  touches:

    * `available` first, so the refund destroys as little as possible;
    * `consumed` next, which is money already spent and therefore raises `debt`
      by the same amount;
    * `reserved` last, because an open hold is work the host believes is still
      running.

  **A promotional lot is never touched**, however late it was granted and
  however early it sorts. Where the wallet's paid and adjustment lots cannot
  cover the amount, the difference becomes `debt`: the call is still never
  refused, and the balance still falls by the full amount.

  **Nor is that debt repaid out of a promotion afterwards**, which is repair
  unit R2 and finding X355. The exclusion above used to hold for exactly one
  transaction: the next `release` or `settle` repaid the debt in spend order,
  which takes promotional credit first, so the promotion paid for the refund one
  ordinary event later. A debt is now never repaid out of credit the wallet
  already holds when that credit is promotional, whatever created the debt. The
  one repayment that may consume promotional value is the one an incoming
  **grant** makes out of its own new lot, which is how a wallet left owing money
  beside a live promotion is unfrozen.

  Until repair unit R1 the lot path did not do this. A reversal on a cut-over
  wallet was planned as a debit, which drains lots in spend order and so takes
  **promotional credit first**, and it wrote nothing into `reversed`
  (`open-findings.md` X250). The sentence above about not consuming promotional
  credit was true of the legacy writer and false of the allocator; it is now
  true of both.

  ## Its own kind, and its own reference namespace

  The entry is written with `kind: :reverse`. Until schema version 9 it was a
  `:debit` carrying the reversal category, which meant a reversal and an
  ordinary debit shared one reference namespace: the unique index is on
  `(kind, reference)`, so a host debit referenced `"order:99"` and a refund
  referenced `"order:99"` collided, and whichever arrived second was told
  `:duplicate_reference` for a write it had never made. They no longer collide.

  Rows written before the change keep `kind: :debit, category: :reversal` for
  ever, and every reader must treat them as reversals.
  `AuroraMeter.Schema.CreditTransaction.reversal?/1` is the one predicate that
  knows both shapes; `spend_history/2` and `spend_total/2` score by `category`,
  so their output is unchanged across the change.
  """
  @spec reverse(term(), pos_integer(), String.t(), map()) ::
          {:ok, txn()} | {:error, :duplicate_reference}
  def reverse(tenant, amount, reference, metadata \\ %{})
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_map(metadata) do
    Money.assert_range!(amount)
    assert_unreserved!(reference, "reverse/4")
    Ledger.reverse(Tenant.to_key(tenant), amount, reference, metadata)
  end

  @doc """
  Takes `amount` back off **the lots one payment funded**, and nothing else.

  The source-scoped reversal. Where `reverse/4` reaches every non-promotional
  lot in the wallet, this one selects the tenant's lots whose
  `source.payment_intent_id` matches `opts[:source]`, and is capped by what
  those lots can give back. Both take the same lots in the same spend order and
  drain them `available`, then `consumed`, then `reserved`:

    * `available` first, so a refund destroys as little as possible;
    * `consumed` next, which is money already spent and therefore raises
      `debt` by the same amount;
    * `reserved` last, because an open hold is work the host believes is still
      running.

  **A promotional lot is never touched**, whatever order it sorts in and
  however late it was granted, and the debt this call creates is not repaid out
  of one afterwards either (repair unit R2, finding X355). A promotion did not
  come from that payment and cannot be handed back to it, which is the rule
  `v1-release.md` 10.1 states. Since repair unit R1 the wallet-wide `reverse/4`
  keeps that rule too, so the difference between the two functions is the cap
  and the provenance rather than whether a promotion survives.

  Options:

    * `:source`: **required**, a map. This release matches on
      `payment_intent_id` and nothing else; any other shape raises
      `ArgumentError`, because a `source` the matcher does not understand would
      match every lot and a refund against every lot is not a near miss.
    * `:metadata`: a map stored on the entry.
    * `:allow_partial`: default `false`. An amount above what the payment's
      lots can still give back is refused with `{:error, :exceeds_source}` and
      **nothing is written**. With `true`, the cap is reversed and the
      difference is recorded as `"shortfall"` in the entry's metadata. A caller
      that has already capped against the provider's own numbers should pass
      `false`, so the error is a bug signal rather than a control-flow path.

  Returns `{:error, :no_matching_lots}` when the tenant has no lot carrying
  that payment: a wallet that has not been cut over to lots, or one migrated
  before the provenance could be derived. Take the money back with `reverse/4`
  in that case; it is what the wallet-wide path is for.

  Idempotent on `reference`, in the `:reverse` kind's own namespace, exactly as
  `reverse/4` is.

  ## Examples

      AuroraMeter.Credits.reverse_lot(org, 10_000_000, "refund:pi_123:1000",
        source: %{payment_intent_id: "pi_123"})

  """
  @spec reverse_lot(term(), pos_integer(), String.t(), keyword()) ::
          {:ok, txn()} | {:error, :duplicate_reference | :no_matching_lots | :exceeds_source}
  def reverse_lot(tenant, amount, reference, opts)
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_list(opts) do
    Money.assert_range!(amount)
    assert_unreserved!(reference, "reverse_lot/4")

    Ledger.reverse_lot(
      Tenant.to_key(tenant),
      amount,
      reference,
      payment_intent!(opts, "reverse_lot/4"),
      opts
    )
  end

  @doc """
  Puts `amount` back onto the lots one payment funded, out of what an earlier
  reversal took off them.

  The inverse of `reverse_lot/4`, for a refund that failed or was cancelled and
  for a dispute that was won. It moves `reversed` back to `available` on the
  same lots and then applies the ledger's standard rule that incoming value
  repays outstanding debt before any of it becomes spendable.

  Capped by `SUM(lot.reversed)` over those lots, so a restoration can never
  hand back more than the reversal took. Options are `:source` (required,
  matched exactly as `reverse_lot/4` matches it), `:metadata` and
  `:allow_partial` (default `false`, refusing with `{:error, :exceeds_reversed}`
  and writing nothing).

  The entry is written as `kind: :grant, category: :adjustment`, so it reads as
  credit arriving in `history/2` and in `spend_history/2`, which is what it is.
  Idempotent on `reference` in the grant namespace.
  """
  @spec restore_lot(term(), pos_integer(), String.t(), keyword()) ::
          {:ok, txn()} | {:error, :duplicate_reference | :no_matching_lots | :exceeds_reversed}
  def restore_lot(tenant, amount, reference, opts)
      when is_integer(amount) and amount > 0 and is_binary(reference) and is_list(opts) do
    Money.assert_range!(amount)
    assert_unreserved!(reference, "restore_lot/4")

    Ledger.restore_lot(
      Tenant.to_key(tenant),
      amount,
      reference,
      payment_intent!(opts, "restore_lot/4"),
      opts
    )
  end

  # The same refusal `Credits.Lots.for_source/2` makes, for the same reason and
  # in the same words: a key the matcher does not understand would match every
  # lot. Here it is stricter still, because the allocator scopes a reversal by
  # `payment_intent_id` alone, so accepting a second key would silently widen
  # what a refund may take.
  @spec payment_intent!(keyword(), String.t()) :: String.t()
  defp payment_intent!(opts, function) do
    source = Keyword.get(opts, :source)

    normalised =
      if is_map(source), do: Map.new(source, fn {key, value} -> {to_string(key), value} end)

    case normalised do
      %{"payment_intent_id" => id} = map when is_binary(id) and map_size(map) == 1 ->
        id

      _other ->
        raise ArgumentError,
              "AuroraMeter.Credits.#{function}: :source is required and this release scopes a " <>
                "reversal by the payment alone, so it must be exactly " <>
                "%{payment_intent_id: \"...\"}. Got: #{inspect(source)}. A source key the " <>
                "matcher does not understand would match every lot, and a refund against " <>
                "every lot is not a near miss."
    end
  end

  # **One reserved namespace, and only one.** `AuroraMeter.Credits.Recurrences`
  # mints `"recurring:<tenant>:<name>:<plan>:<version>:<period>"` as the grant
  # reference for a period, and the ledger's `(kind, reference)` index is what
  # makes that period happen once. A host that granted under the same string
  # would either be refused for a write it never made or, worse, make a period
  # look already issued. Manual grants are **not** forced into a namespace of
  # their own: `architecture-map.md` 7.5 reserves `recurring:` and nothing else.
  @spec assert_unreserved!(term(), String.t()) :: :ok
  defp assert_unreserved!(reference, function) when is_binary(reference) do
    if String.starts_with?(reference, Recurrences.namespace()) do
      raise ArgumentError,
            "AuroraMeter.Credits.#{function}: references beginning " <>
              "#{inspect(Recurrences.namespace())} are reserved by the recurring-grant " <>
              "engine (AuroraMeter.Credits.Recurrences), which mints them per tenant, " <>
              "entitlement, plan version and period. Got: #{inspect(reference)}. Use any " <>
              "other string; manual grants are not namespaced."
    end

    :ok
  end

  defp assert_unreserved!(_reference, _function), do: :ok

  @doc """
  Holds that are still open and were taken before `:older_than`, oldest first.

  For a host that has to find reservations nothing will ever close. A hold is
  taken before the row that remembers it exists (there is no way to make those
  two one write, since they are in different databases as often as not), so a
  process killed in between leaves money reserved against a tenant with nothing
  left pointing at it. Only the host can tell such a hold from one whose work
  is simply still running, so the ledger's part is to list them.

  `reconcile_holds/1` is the other half: this lists them, that asks the host
  what to do about each one and applies the answer.

  Options:

    * `:older_than`: required, a `DateTime`. Build it from
      `AuroraMeter.Clock.now/0`, which is the clock the hold's `inserted_at` was
      stamped by.
    * `:limit`: default 200.
    * `:reference_prefix`: narrow to one kind of work; a prefix match.
    * `:tenant`: only this tenant's holds.
    * `:after`: a `{inserted_at, id}` pair from the last row of the previous
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

    * `:older_than`: required, a `DateTime`. Omitting it raises `KeyError`.
    * `:limit`: default 200, the most holds one run examines.
    * `:tenant`: sweep one tenant.
    * `:reference_prefix`: sweep one kind of work.
    * `:after`: a cursor from a previous report, to page.
    * `:reconciler`: use this instead of the configured one. A module, a
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

  `fun` must return `{:ok, result, actual_amount}` (the hold is settled for
  `actual_amount` and `{:ok, result}` is returned) or `{:error, reason}`,
  which releases the hold and is returned as-is. If `fun` raises, throws or
  exits, the hold is released and the error propagates. Any other return
  value releases the hold and raises `ArgumentError`.

  Returns whatever `hold/4` refused with (`:insufficient_credits`,
  `:debt_outstanding` or `:duplicate_reference`) without running `fun`.

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
          {:ok, result}
          | {:error, :insufficient_credits | :debt_outstanding | :duplicate_reference | term()}
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

    * `:limit`: default 50.
    * `:cursor`: page from here. Take it from `cursor/1` on the last entry of
      the previous page; only entries strictly older than it are returned.
    * `:before`: a `DateTime`; only entries whose `inserted_at` is strictly
      before it. A **filter**, not a cursor: see below.
    * `:kinds`: which kinds to include; defaults to
      `#{inspect(@default_history_kinds)}`, i.e. holds and releases (the
      bookkeeping around a settlement) are hidden unless asked for.
    * `:reference_prefix`: only entries whose `reference` begins with this
      string. For a host that mints references in namespaces of its own
      (`"refund:<payment>:"`, `"reinstated:<payment>:<dispute>:"`) and needs to
      total one of them. It is a filter on the ledger's **reference
      namespace**, which is the host's own naming, and never a substitute for
      provenance: which grant a spend came out of is a question for
      `AuroraMeter.Credits.Lots`, not for a string prefix.

  `:before` and `:cursor` together raise `ArgumentError`. They answer different
  questions and combining them silently would look like paging while filtering.

  ## Paging, and why `:before` cannot do it

  The list is ordered by the ledger's own ordering key, which is a Postgres
  identity column and not a timestamp (findings L20, X213). `:before` compares
  `inserted_at`, so paging with it compares a different column from the one that
  ordered the page: **two entries written in the same microsecond have no order
  under it, so one can be skipped and another repeated** (finding L8). It is
  kept because it is the documented way to ask "what happened before lunchtime",
  which is a filter and is exactly what it is good at.

  `:cursor` pages on the ordering key itself, which is unique and total, so a
  cursor walk returns every matching entry exactly once whatever the timestamps
  say.

  ## Examples

      AuroraMeter.Credits.history(org, limit: 2)
      #=> [%CreditTransaction{kind: :settle, ...}, %CreditTransaction{kind: :grant, ...}]

      AuroraMeter.Credits.history(org, kinds: [:hold, :release])

      page = AuroraMeter.Credits.history(org, limit: 100)
      next = AuroraMeter.Credits.history(org, limit: 100, cursor: AuroraMeter.Credits.cursor(List.last(page)))

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
        order_by: [desc: t.seq],
        limit: ^limit
      )

    query
    |> history_before(Keyword.get(opts, :before), Keyword.get(opts, :cursor))
    |> history_cursor(Keyword.get(opts, :cursor))
    |> history_prefix(Keyword.get(opts, :reference_prefix))
    |> Config.repo().all()
  end

  @spec history_prefix(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  defp history_prefix(query, nil), do: query

  defp history_prefix(query, prefix) when is_binary(prefix) and prefix != "",
    do: from(t in query, where: fragment("starts_with(?, ?)", t.reference, ^prefix))

  defp history_prefix(_query, prefix) do
    raise ArgumentError,
          "history/2's :reference_prefix must be a non-empty string, got: #{inspect(prefix)}. " <>
            "An empty prefix matches every entry, which is what omitting the option does and " <>
            "is never what a caller filtering on a reference namespace meant."
  end

  @spec history_before(Ecto.Query.t(), DateTime.t() | nil, cursor() | nil) :: Ecto.Query.t()
  defp history_before(query, nil, _cursor), do: query

  defp history_before(_query, %DateTime{}, cursor) when not is_nil(cursor) do
    raise ArgumentError,
          "history/2 takes :before or :cursor, not both. :before filters on `inserted_at`, " <>
            "which is a wall-clock stamp and orders nothing; :cursor pages on the ledger's " <>
            "ordering key. Combining them would look like paging while filtering."
  end

  defp history_before(query, %DateTime{} = before, nil),
    do: from(t in query, where: t.inserted_at < ^before)

  @spec history_cursor(Ecto.Query.t(), cursor() | nil) :: Ecto.Query.t()
  defp history_cursor(query, nil), do: query

  defp history_cursor(query, seq) when is_integer(seq),
    do: from(t in query, where: t.seq < ^seq)

  defp history_cursor(_query, other) do
    raise ArgumentError,
          "history/2's :cursor must come from AuroraMeter.Credits.cursor/1, got: #{inspect(other)}"
  end

  @doc """
  The `history/2` cursor for an entry: pass it back as `:cursor` to page from
  just after it.

  It is the ledger's ordering key and it is opaque. Do not compare two cursors,
  store one across a release, or build one by hand; the only thing promised is
  that `history/2` resumes exactly after the entry it came from.

  ## Examples

      page = AuroraMeter.Credits.history(org, limit: 100)
      AuroraMeter.Credits.history(org, limit: 100, cursor: AuroraMeter.Credits.cursor(List.last(page)))

  """
  @spec cursor(txn()) :: cursor()
  def cursor(%CreditTransaction{seq: seq}) when is_integer(seq), do: seq

  @doc """
  Returns `tenant`'s money movement as zero-filled buckets, oldest first.

  Every bucket in the range is present (a bucket the ledger never touched is
  `spent: 0, granted: 0, net: 0, balance_after: nil`), so a chart can render
  the list straight through with no gap handling. Buckets are UTC.

  Options:

    * `:days`: how many days back from `:to`, default 30.
    * `:from` / `:to`: explicit `Date` bounds (inclusive), overriding `:days`.
    * `:bucket`: `:day` (default) or `:month`. A month bucket is dated its
      first day; the first and last month of a range that does not start and
      end on month boundaries are partial.
    * `:kinds`: which kinds count as spend, default
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
  zero: there is no honest number of days to show when nothing is being spent.
  The period comes from the configured period source, the same one `quota/2`
  reports.

  ## Examples

      AuroraMeter.Credits.summary(org)
      #=> %{balance: 19_580_000, available: 19_580_000, spendable: 19_580_000, held: 0,
      #=>   promotional: 0, promotional_spendable: 0, debt: 0, expired: 0,
      #=>   currency: "usd", spent_this_period: 420_000, granted_this_period: 20_000_000,
      #=>   period: %{start: ~U[2026-09-01 00:00:00Z], end: ~U[2026-10-01 00:00:00Z],
      #=>             source: :calendar},
      #=>   daily_burn: 14_000, runway_days: 1_398}

  `runway_days` is still derived from `available` rather than from `spendable`,
  deliberately: it is a published figure with a published meaning, and changing
  what it divides would move every dashboard's number without anything saying
  so. A host that wants the stricter runway divides `spendable` by `daily_burn`
  itself.

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
      spendable: snapshot.spendable,
      held: snapshot.held,
      promotional: snapshot.promotional,
      promotional_spendable: snapshot.promotional_spendable,
      debt: snapshot.debt,
      expired: snapshot.expired,
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

  A standing low-balance crossing is recomputed under the balance row's lock:
  lowering the threshold below where the wallet already sits, or clearing it,
  clears the crossing, so the next genuine fall below the new line alerts. It
  never raises an alert by itself, because nothing about the wallet moved.

  ## Examples

      {:ok, row} = AuroraMeter.Credits.set_low_balance_threshold(org, 5_000_000)
      row.low_balance_threshold
      #=> 5_000_000

  """
  @spec set_low_balance_threshold(term(), integer() | nil) :: {:ok, CreditBalance.t()}
  def set_low_balance_threshold(tenant, threshold)
      when is_integer(threshold) or is_nil(threshold) do
    if is_integer(threshold), do: Money.assert_range!(threshold)
    Ledger.set_low_balance_threshold(Tenant.to_key(tenant), threshold)
  end

  @doc """
  Expires promotional grants whose `expires_at` is at or before `now`
  (default: now), removing what is left of each (`min(promotional balance,
  grant amount)`, never below zero) as an `:expire` entry referenced
  `"expire:<grant id>"`, and stamping the grant's `expired_at`. Returns the
  number of grants expired. Run it periodically (a `Quantum` job, an Oban
  cron, or a plain timer).

  Several live promotional grants per tenant are supported. Promotional spending
  is attributed **soonest expiry first** on a legacy wallet, and follows the
  lots' own spend order on a cut-over one, so each grant's remainder is well
  defined and expiring one never reclaims credit a later grant contributed.

  The count is grants on a legacy wallet and lots on a cut-over one. They are
  the same thing counted under two names: the migration writes one lot per
  grant.

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
  Runs the side effects of every ledger call this process made inside its own
  transaction, and empties the queue.

  ## Why a host has to call it

  A ledger call decides for itself whether its side effects may run, and it
  decides by asking whether the caller already had a transaction open. When it
  did, `Repo.transaction/1` opens a **savepoint**, not a transaction: the ledger
  sees its own work return successfully and the host can still roll all of it
  back. Telemetry, PubSub and the low-balance handler all describe money, and a
  Pro auto top-up fired for a balance that never existed buys credit against a
  payment the host abandoned. So inside a host transaction they are queued
  rather than run, and this is what runs them.

  A call that owns its transaction is unaffected: its effects fire on commit as
  they always have, the queue stays empty, and a host that never wraps a ledger
  call never needs this function.

      Repo.transaction(fn ->
        {:ok, _txn} = AuroraMeter.Credits.settle("job:42", cost)
        {:ok, _job} = MyApp.Jobs.mark_billed(job)
      end)
      |> case do
        {:ok, result} -> AuroraMeter.Credits.after_commit(); result
        {:error, reason} -> AuroraMeter.Credits.after_commit(discard: true); {:error, reason}
      end

  Options:

    * `:discard`: `true` drops the queue without running anything. This is what
      the rollback branch calls: the writes are gone, so the effects describing
      them must not fire.

  ## What it is not

  It is **not** durable. The queue lives in the calling process, which is
  exactly where Ecto's transaction scope lives, so the two have the same
  lifetime and neither can outlive the other. A process that dies between the
  commit and this call loses the effects: the money is committed and correct,
  and one round of telemetry, one PubSub message and possibly one low-balance
  alert are not delivered. A host that needs those to be at-least-once
  subscribes to PubSub or polls `balance/1` rather than relying on a callback.

  `deferred_effects?/0` answers whether anything is queued, which is how a test
  asserts that a code path has not forgotten this call.

  ## Examples

      iex> AuroraMeter.Credits.after_commit()
      :ok

  """
  @spec after_commit(keyword()) :: :ok
  def after_commit(opts \\ []) when is_list(opts), do: Ledger.drain(opts)

  @doc """
  Whether this process has ledger side effects waiting for `after_commit/1`.

  True only between a ledger call made inside a host transaction and the
  `after_commit/1` that drains it. Assert `false` after your transaction
  handling to prove no path forgot the call.

  ## Examples

      iex> AuroraMeter.Credits.deferred_effects?()
      false

  """
  @spec deferred_effects?() :: boolean()
  def deferred_effects?, do: Ledger.deferred() != []

  @doc """
  Subscribes the calling process to `tenant`'s credit updates:
  `{:aurora_meter, :credits, %{tenant_key, balance, held, available, spendable,
  debt, expired}}` after every ledger entry and `{:aurora_meter, :low_balance,
  %{tenant_key, available, spendable, threshold, crossing_id}}` on a low-balance
  crossing. Both payloads may gain keys in a later release, so match the ones
  you need rather than the whole map.

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
