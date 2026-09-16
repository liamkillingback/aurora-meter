# Credits

A prepaid balance per tenant for pay-as-you-go pricing: AI tokens, API calls,
storage, anything priced per unit rather than per plan. `AuroraMeter.Credits`
lives next to the plan counters, keyed by the same tenant term, and is the
free core of what Pro tops up from Stripe.

> Requires the Ecto storage (the ledger is a row lock plus an append inside one
> database transaction, which is not something the `AuroraMeter.Storage`
> behaviour abstracts) and schema version 3:
> `mix aurora_meter.gen.migration -r MyApp.Repo --from 3 && mix ecto.migrate`.

## Units

Every amount is an integer number of **micro-dollars** (µ$): `1_000_000` is
one dollar, `10_000` is one cent, and `15` is the price of a cheap token.
Integers keep the ledger exact under concurrency and make sub-cent prices
representable; convert at the edges with `AuroraMeter.Credits.Money`:

```elixir
alias AuroraMeter.Credits.Money

Money.from_cents(1_235)                       # 12_350_000
Money.to_cents(12_350_000)                    # 1_235   (rounding: :round | :floor | :ceil)
Money.from_decimal(Decimal.new("12.35"))      # 12_350_000
Money.format(12_350_000)                      # "$12.35" (precision: 2 by default)
Money.format(-1_000_000)                      # "-$1.00"
Money.format_compact(1_234_000_000)           # "$1.2k"  (short axis labels)
Money.format_compact(15)                      # "$0.000015" (never rounds to "$0.00")
```

## The balance

```elixir
AuroraMeter.Credits.balance(org)
# %{balance: 20_000_000, held: 500_000, available: 19_500_000, spendable: 19_500_000,
#   promotional: 0, promotional_spendable: 0, debt: 0, expired: 0,
#   currency: "usd", low_balance_threshold: nil}
```

- `balance` is everything granted minus everything settled, debited or
  expired. It is signed: a settlement can exceed its hold.
- `held` is the sum of pending holds. `available = balance - held` is what
  `available/1` returns.
- `promotional` is the part of the balance that came from promotional grants.
- `spendable` is what a new hold or debit would actually be allowed to take,
  and it is the figure `sufficient?/2` compares against. **It is never positive
  while `debt` is outstanding**, because nothing may spend then.
- `promotional_spendable` is the part of `spendable` that came from promotional
  lots, so it answers the same question and is zero in the same states. The
  promotional credit the wallet **holds** is `promotional`, which a debt does
  not reduce.
- `debt` is executed cost the wallet could not fund, or money handed back to a
  payment provider that the wallet had already spent. The next grant repays it
  before creating availability, and nothing may spend while it is outstanding.
  Credit the wallet already holds repays it too, unless that credit is
  promotional. See ["Debt"](#debt) for what puts a wallet there, what the
  figures read while it lasts and what clears it.
- `expired` is value destroyed by expiry, kept apart from value spent.

`sufficient?(org, amount)` is `spendable + overdraft_tolerance >= amount`, the
same test `hold/4` and `debit/4` apply under the row lock.

### Four figures, not one signed integer

Reserved, destroyed and owed value are three different things, and a reader
given one number has to guess which happened. `available` and `spendable` differ
on a wallet the lot engine owns by exactly two things:

- credit past its `expires_at` is **not** spendable, even before the expiry
  sweep reaches it. That is what makes expiry bookkeeping rather than a race.
- `debt` is subtracted. A wallet that owes money cannot spend until a grant has
  repaid it.

`spendable` is capped at what the ledger will accept and not clamped for
display. The two are different promises and the distinction matters:

- it may never be **positive** when a hold or debit would be refused. While
  `debt` is outstanding every hold and every debit is refused whatever the
  wallet holds, so `spendable` and `promotional_spendable` both read `0` there;
- it is not floored at zero either. Where the debt is bigger than what is left,
  `spendable` goes negative and says how deep the wallet is, which a reader
  watching it climb out needs to see.

`balance`, `promotional`, `held`, `debt` and `expired` are not claims about
spending. They report what the wallet holds, owes or has lost, and a debt does
not reduce them. `available` is the arithmetic `balance - held` and stays one:
it is what `runway_days` divides, and on a wallet in debt it can be positive
while nothing at all may be spent.

On a wallet that has **not** been cut over to lots, which is every wallet until
`mix aurora_meter.credits.migrate_lots` runs, `spendable == available`,
`promotional_spendable == promotional`, and `debt` and `expired` are both `0`.
So a dashboard can render all eight figures without asking which writer owns the
wallet.

## Grants

```elixir
AuroraMeter.Credits.grant(org, Money.from_cents(2_000), reference: "stripe:pi_123")
#=> {:ok, %AuroraMeter.Schema.CreditTransaction{kind: :grant, amount: 20_000_000, ...}}
```

`:reference` is required: it is the idempotency key. A retried grant with the
same reference for the same tenant returns the original entry as
`{:ok, existing}` and credits nothing, so a webhook delivered twice cannot
double-fund an account. `:category` is `:paid` (default), `:promotional` or
`:adjustment`; `:metadata` is a map stored on the entry.

`grant_with_status/3` returns `{:ok, txn, :new}` or `{:ok, txn, :duplicate}`
when you need to tell the two apart — to announce the payment to the customer
exactly once, say. Ask it rather than probing for the reference beforehand:
the status is decided inside the balance row's lock, and two concurrent
deliveries of one payment that both look first both find nothing.

## Refunds and chargebacks

```elixir
Credits.reverse(org, 2_000_000, "stripe:re_123", %{"source" => "refund"})
```

`reverse/4` takes credit back for money that has already left the payment
provider. Unlike `debit/3` it is **never refused for want of balance** —
refusing would only make the ledger disagree with reality — so the balance may
go negative, which is the honest record of a debt. It is still idempotent on
the reference.

Reversals are written with `category: :reversal`, which keeps them out of two
places a negative debit did not belong: they do not consume promotional
credit, and the money series counts them against `granted` rather than as
spend, so a refund does not appear in a customer's spend chart or inflate the
burn rate behind `runway_days`.

### A reversal has its own kind, and its own reference namespace

The entry is `kind: :reverse`. Until schema version 9 it was a `:debit` carrying
the reversal category, and the unique index is on `(kind, reference)`, so a host
debit referenced `"order:99"` and a refund referenced `"order:99"` collided:
whichever arrived second was told `:duplicate_reference` for a write it had never
made, and the refund was silently not applied. They no longer collide.

**Rows written before the change keep `kind: :debit, category: :reversal` for
ever**, because the log is append only, and every reader has to treat them as
reversals. Ask `AuroraMeter.Schema.CreditTransaction.reversal?/1` rather than
matching on either shape. The reporting functions score by `category`, so
`spend_history/2` and `spend_total/2` are unchanged across the change, and
`:reverse` is in `history/2`'s default kinds so the default view still shows
refunds.

If you query the table directly and look for `kind = 'debit'` to find reversals,
that query now misses new ones. Use `kind = 'reverse' OR category = 'reversal'`.

### Reversing the payment's own credit

`reverse/4` is wallet wide: on a wallet the allocator owns it takes the credit
back off the wallet's **non-promotional** lots, in spend order, draining
`available`, then `consumed`, then `reserved`, and records as `debt` whatever
those lots cannot give back. It never touches a promotional lot, so it is a safe
answer for a host with no payment provenance. What it does not have is a cap: it
will take credit off a lot some other payment funded, because nothing tells it
which payment this refund is for.

A host that stamps `:source` on its grants uses the source-scoped pair instead,
which takes the same lots in the same order but only the ones that payment
funded, and is capped by them:

```elixir
Credits.grant(org, 25_000_000,
  reference: "pi_123",
  category: :paid,
  source: %{payment_intent_id: "pi_123"}
)

Credits.reverse_lot(org, 10_000_000, "refund:pi_123:1000",
  source: %{payment_intent_id: "pi_123"}
)

Credits.restore_lot(org, 10_000_000, "restore:pi_123:1000",
  source: %{payment_intent_id: "pi_123"}
)
```

`reverse_lot/4` selects the tenant's lots whose `source.payment_intent_id`
matches, in spend order, and drains them **`available`, then `consumed`, then
`reserved`**:

  * `available` first, so the refund destroys as little as possible;
  * `consumed` next, which is money already spent, so `debt` rises by the same
    amount: the balance falls, and the wallet owes it;
  * `reserved` last, because an open hold is work the host believes is still
    running. Taking it also lowers `held`, and the hold that lost its
    reservation creates its own debt when it settles.

**A promotional lot is never touched, whatever order it sorts in and however
late it was granted.** Nor is the debt a reversal creates repaid out of one, by
this call or by any call after it: no debt is ever repaid out of promotional
credit the wallet already holds, so a payment's refund can never erase a
promotion. That is the whole point of the pair, and it is the rule
`AuroraMeter.Credits.Lots` exists to make checkable afterwards.

The "or by any call after it" is not decoration. Until 0.6.0 the exclusion held
for the refund's own transaction and no longer: the refund correctly left a
`debt` rather than taking the promotion, and then the next `release` or `settle`
repaid that debt in spend order, which takes promotional credit first. The
promotion paid for the refund one ordinary event later, and the allocation row
it left behind said `consume`, which is what an ordinary spend says.

`restore_lot/4` is the inverse, for a refund that failed or was cancelled and
for a dispute that was won. It moves `reversed` back to `available` on the same
lots and then applies the ledger's ordinary rule that incoming value repays
outstanding debt before any of it becomes spendable.

Both are capped by the payment's own lots: `reverse_lot/4` by what those lots
can still give back, `restore_lot/4` by `SUM(lot.reversed)`. Above the cap they
answer `{:error, :exceeds_source}` and `{:error, :exceeds_reversed}` and write
**nothing**, unless you pass `allow_partial: true`, which takes the cap and
records the difference as `"shortfall"` in the entry's metadata. Both are
idempotent on the reference, in their own kind's namespace.

A payment with no lots answers `{:error, :no_matching_lots}`: a wallet that has
not been cut over to lots, or one migrated before the provenance could be
derived. Take the money back with `reverse/4` in that case, which is what the
wallet-wide path is for, and mark the entry so the fallback is visible.

`:source` is matched on `payment_intent_id` alone in this release, and anything
else raises `ArgumentError`: a source key the matcher did not understand would
match every lot, and a refund against every lot is not a near miss.

## Hold, settle, release

Most metered work has an estimate up front and a real cost afterwards. A hold
reserves the estimate so concurrent jobs cannot overspend; the settlement
charges what it actually cost.

```elixir
{:ok, _} = Credits.hold(org, 500_000, "job:42")      # available drops by 0.50
# ... run the job, it cost $0.42 ...
{:ok, _} = Credits.settle("job:42", 420_000)          # balance -0.42, hold freed
```

| Step | Effect | Errors |
|---|---|---|
| `hold(org, amount, reference)` | `held += amount` | `:insufficient_credits` when `available + tolerance < amount`; `:duplicate_reference` |
| `settle(reference, actual)` | `balance -= actual`, `held -= hold` | `:not_found`, `:already_settled` |
| `release(reference)` | `held -= hold` | `:not_found`, `:already_settled` |
| `debit(org, amount, reference)` | `balance -= amount` (a hold and a settle in one) | as `hold` |

A settlement **never fails for lack of credit**: if the actual cost exceeds
the hold, the balance goes negative and the `[:aurora_meter, :credits,
:settle]` event carries `overrun: true`. The next hold or debit is then
refused until a grant brings the balance back above the tolerance.

`with_credits/4` does the whole dance and cleans up on failure:

```elixir
Credits.with_credits(org, estimate, "job:#{job.id}", fn ->
  case run(job) do
    {:ok, output, cost} -> {:ok, output, cost}   # settle for cost
    {:error, reason}    -> {:error, reason}      # release, return the error
  end
end)
#=> {:ok, output} | {:error, reason} | {:error, :insufficient_credits}
```

If the function raises, throws or exits the hold is released and the error
propagates.

### Holds nothing will ever close

A hold is taken before the row that remembers it exists, and those two cannot
be one write — the ledger is a different schema and often a different
database. A process killed in between leaves money reserved against a tenant
with nothing anywhere pointing at it.

Only the host can tell such a hold from one whose work is simply still
running, so the ledger's part is to list them:

```elixir
Credits.pending_holds(
  older_than: DateTime.add(DateTime.utc_now(), -3600, :second),
  reference_prefix: "job:"
)
#=> [%CreditTransaction{kind: :hold, status: :pending, reference: "job:42", ...}]
```

Oldest first, ordered by `(inserted_at, id)` so a `:limit`ed page can be
resumed with `:after` without skipping a hold that shares a microsecond with
another. `:older_than` is a `DateTime` and is required; `:reference_prefix`
narrows to one kind of work, `:tenant` to one customer, and `:limit` defaults to
200. Pick references you can find again.

### Recovering stale holds

`pending_holds/1` lists them. `reconcile_holds/1` asks you about each one and
applies your answer:

```elixir
defmodule MyApp.HoldPolicy do
  @behaviour AuroraMeter.Credits.HoldReconciler

  @impl true
  def decide(%{reference: "job:" <> id}) do
    # Your own records, not the clock.
    case MyApp.Jobs.get(id) do
      %{state: :running} -> :keep
      %{state: :failed} -> :release
      %{state: :done, cost_micro_usd: cost} -> {:settle, cost}
      nil -> :release
    end
  end

  def decide(_hold), do: :keep
end

# config/config.exs
config :aurora_meter, credits_hold_reconciler: MyApp.HoldPolicy
```

Then, from a scheduler:

```elixir
Credits.reconcile_holds(older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second))
#=> {:ok, %{examined: 12, kept: 9, released: 2, settled: 1,
#=>         already_closed: 0, failed: 0, cursor: nil}}
```

A module, a `{module, function}` pair or a one-argument function all work.
`:cursor` comes back as `{inserted_at, id}` when the page was full, so a caller
that pages passes it as `:after` on the next run.

**Age is not evidence, and this is the whole point of the callback.** A job that
legitimately runs for nine hours and a job whose process was killed nine hours
ago are the same row. `age_seconds` is there for your log line; the decision has
to come from something that actually knows whether the work is alive. Deciding
from the age releases money that is about to be spent, and the settle that
follows takes the balance negative.

There is a mechanical reason as well. A hold's `inserted_at` is stamped by the
node that took the hold, from a wall clock that is not monotonic and is not the
clock the reconciler reads. The age is accurate to within whatever those two
disagree by, which is fine for a metric and not fine for a decision about money.

**Nothing here can release money by accident.** Every one of these keeps the
hold:

* no `:credits_hold_reconciler` configured, which is the default;
* a callback that raises, exits or throws;
* a callback that does not answer within `:credits_hold_reconciler_timeout`
  (default 5000 ms), which is then killed;
* a callback that returns anything other than `:keep`, `:release` or
  `{:settle, n}` with `n` a non-negative integer.

The callback runs in a task under `AuroraMeter.TaskSupervisor`, outside any
transaction and while no ledger row is locked, so it cannot take the reconciler
down with it, cannot hold a lock open and cannot be the reason a hold is stuck.
Do not make a network call from it: the timeout is the only thing bounding it.
It may also be called **more than once for one hold**, because two nodes running
a sweep both list it, so make it side-effect free or idempotent.

This section is the contract: what the callback may return, what keeps a hold,
and what happens when the decision races the work. The runbook that uses it,
including how often to sweep and what to alert on, is section 3 of
[Operations](operations.md).

To see what a sweep would look at before configuring a policy, pass an explicit
one that decides nothing:

```elixir
Credits.reconcile_holds(
  older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second),
  tenant: one_customer,
  reconciler: fn _hold -> :keep end
)
```

### What happens when the race is lost

A decision is advisory until it is applied. Between your callback returning and
the ledger applying it, the hold's own worker may have finished. The application
re-reads the hold's status under its row lock, so exactly one terminal
transition happens and the reconciler reports `already_closed`. The same is true
of two nodes sweeping at the same instant: one release row, one run reporting
`released: 1`, and the other reporting that it lost.

The other side of that race is a hold your reconciler released while
`with_credits/4` was still running it. The work happened and it cost something,
so the cost is recorded rather than lost: `with_credits/4` writes a debit
referenced `settle_missed:<reference>`, which may take the balance negative,
because the alternative is a ledger that quietly forgets a charge. It is
idempotent on that reference. Telemetry carries both halves, so a policy that is
releasing work which then completes is visible as a stream of
`released_by_other` outcomes.

## Promotional credit and expiry

```elixir
Credits.grant(org, 5_000_000,
  reference: "signup:#{org.id}",
  category: :promotional,
  expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
)
```

Promotional credit is consumed before paid credit on every settlement, debit
and expiry, so a customer's own money is the last to go. `expire_due/1` — run
it from a cron (`Quantum`, an Oban cron job, a plain `Process.send_after`
loop) — expires every promotional grant whose `expires_at` has passed: it
removes `min(promotional balance, grant amount)`, never taking the balance
below zero, writes an `:expire` entry referenced `"expire:<grant id>"` and
stamps the grant's `expired_at` so it is never processed twice.

**Several live promotional grants are supported**, and promotional spending is
attributed **soonest expiry first**, so each grant's remainder is well defined
and the first to expire cannot reclaim credit a later one contributed. An
earlier version of this page said expiry assumed at most one live promotional
grant; the code never did, and the sentence was wrong rather than the behaviour.

**What is true on a wallet that has not been cut over to credit lots** is
narrower and worth knowing: the balance row keeps one `promotional` figure per
tenant rather than one per grant, and the attribution is reconstructed by
replaying the wallet's entries. It is correct for the cases the tests cover, and
it cannot say which grant a **hold** reserved, because the legacy figure has no
place to record that. Value a hold had reserved on an already expired grant also
becomes spendable again when the hold is released, until the next sweep.

On a wallet the lot engine owns, each grant is its own lot with its own five
quantities and both of those are gone. Read on.


## Credit lots

Every grant creates a **lot**: an immutable record of that grant's amount,
category, expiry and source, with five quantities that always add up to the
amount.

| Quantity | What it is |
|---|---|
| `available` | spendable now, unless the lot is past its `expires_at` |
| `reserved` | held by a pending hold, and spoken for |
| `consumed` | spent by a debit, a settlement, or a repayment of debt |
| `reversed` | taken back by a refund or a chargeback |
| `expired` | destroyed by expiry, and never spendable again |

The database refuses a lot row whose five do not add up, and refuses a negative
one, so "which grant paid for this" has an answer that cannot quietly drift.
Each movement between two buckets is one **allocation** row naming the lot and
the ledger entry that caused it, so a lot's quantities can be rebuilt by
folding its allocations rather than taken on trust.

### The spend order

Promotional before paid (an adjustment sorts with paid), then the earliest
non-null `expires_at`, then the oldest grant, then the ledger's own sequence.
Non-expiring lots sort last within their category. The key is total, so the
order the database happens to return lots in cannot change what a debit spends.

A 3 USD promotional grant expiring in October, a 5 USD promotional grant
expiring in November and a 10 USD paid top-up, debited 6 USD, leave the first
empty, 2 USD on the second and the paid lot untouched.

### Expiry

Expiry moves a due lot's `available` to `expired` and touches nothing else, so
it cannot reach into a later grant's remainder. What a hold has reserved stays
reserved; when that hold is released or settles, whatever it does not spend on
a lot that has since expired becomes `expired` too, rather than spendable
again.

**Two deliberate differences from 0.4.0**, both of which change what a tenant
can spend:

* credit whose `expires_at` has passed is **not spendable** even though the
  sweep has not reached it yet. In 0.4.0 it stayed spendable until the next
  pass, which made expiry a race rather than bookkeeping. If you funded a
  tenant with a promotion expiring at midnight, they see refusals from
  midnight rather than from the next sweep.
* value released from an expired lot is written off instead of being handed
  back.

### Debt

A settlement above its hold is executed cost: the work ran and it has to be
paid for. A refund of credit that was already spent is the other source: the
money has left the payment provider and cannot be taken out of a lot that has
nothing left in it. Either way what the wallet cannot fund becomes `debt`,
recorded on the balance row rather than hidden in a negative balance nobody can
explain. While `debt` is outstanding the wallet cannot hold or debit, and the
next grant repays it before any of the new money becomes available, writing a
`consume` allocation against the new lot so the repayment is as traceable as a
spend.

#### A wallet that owes money, in full

This is the whole state in one place, so a question about it can be answered
from this page rather than from the source.

**What puts a wallet there.** Any of:

- a `settle/3` above what its hold reserved, with not enough left in the wallet
  to cover the overrun;
- a `reverse/4` or `reverse_lot/4` (a refund or a chargeback) larger than the
  paid credit the wallet still has, which reaches credit already spent;
- a `debit/4` with `allow_negative: true`, which is how money that has already
  left the payment provider is recorded.

A wallet **holding a promotion** reaches it on any of those, because a
promotion is never consumed to repay a debt.

**What the figures read while it lasts.** For example, after a refund of `$5.00`
on a wallet that had `$1.00` of paid credit left, `$8.00` of promotional credit
and a `$3.00` hold against it:

```elixir
AuroraMeter.Credits.balance(org)
# %{balance: 4_000_000, held: 3_000_000, available: 1_000_000,
#   promotional: 8_000_000, debt: 4_000_000, expired: 0,
#   spendable: 0, promotional_spendable: 0, ...}
```

- `balance`, `available` and `promotional` are positive. The credit is really
  there and the promotion survives whole: a refund never takes it, and neither
  does the release or settlement that follows.
- `debt` says what is owed.
- `spendable` and `promotional_spendable` are `0`. **Nothing is spendable**,
  and those two figures are the ones that say so.

**What happens to a call.** Every `hold/4` and every `debit/4` returns
`{:error, :debt_outstanding}`, whatever the amount, and `sufficient?/2` returns
`false` for every amount. `:debt_outstanding` is a different reason from
`:insufficient_credits`, which means the wallet simply has nothing eligible
left; the split exists so a host can tell a customer which of the two happened.
`reverse/4`, `restore/4`, `settle/3` and `release/1` are unaffected: a refund
and the closing of a hold that is already open are never refused.

**What clears it.** A `grant/3` of **any** category, including a promotional
one. The repayment comes out of the lot the grant is creating, before any of it
becomes available, so a top-up of the amount owed clears the debt exactly and
one larger leaves the difference spendable. Nothing else clears it: no release,
no settlement below its estimate and no expiry sweep, because none of those may
touch credit the wallet already holds if it is promotional, and by the time a
wallet is in this state that is usually all it has.

**How to find them.** `debt` on `aurora_meter_credit_balances`:

```sql
SELECT tenant_key, balance, promotional, debt
  FROM aurora_meter_credit_balances
 WHERE debt > 0
 ORDER BY debt DESC;
```

**A promotion is never consumed to repay a debt.** Anything else the wallet
holds is: value a release hands back, and value a settlement below its estimate
does not use, both repay outstanding debt before becoming spendable again. A
promotional lot does not, because `reverse_lot/4` and `reverse/4` may not take a
promotion for a paid refund and a rule one later event defeats is not a rule.
The cost is worth knowing before you meet it:

- a wallet can hold promotional credit and owe money at the same time, and while
  it owes money it can spend neither. `balance/1` will report a positive
  `promotional` beside a positive `debt`, with `spendable` and
  `promotional_spendable` both `0`, and every hold and debit is refused with
  `{:error, :debt_outstanding}`;
- the way out is a grant of any kind. The repayment a grant makes comes out of
  the lot it is creating, whatever its category, so topping the wallet up (or
  granting it another promotion) clears the debt and the promotion it was
  standing beside becomes spendable, whole;
- a promotion left standing beside a debt until its `expires_at` is destroyed by
  the sweep like any other unspent promotion. If you grant promotional credit to
  wallets that may be in debt, watch `debt` on the balance row.

The rule is about repaying, not about spending. Spend order still takes
promotional credit first for real work, including the extra consumption a
settlement above its estimate makes: that is the tenant spending a promotion,
which is what a promotion is for.

### Conservation

After every write on a cut-over wallet, in the same transaction:

    balance     = sum(available) + sum(reserved) - debt
    held        = sum(reserved)
    promotional = sum(available + reserved) over promotional lots
    expired     = sum(expired)

The balance row is moved by the write's own deltas and then compared against a
`SUM` over the wallet's lots. If they disagree, `AuroraMeter.Credits`
**raises** `AuroraMeter.Credits.ConservationError` and the transaction rolls
back, so the wallet is left exactly as it was and refuses further writes until
a human has looked at it. That is the intended trade: a refused write is
recoverable and a wrong balance is not. Catching the error and carrying on is
never correct.

### Which wallets are on it

None, until you run the wallet migration. The balance row carries
`lots_enabled_at`, read under its own row lock; while it is null the ledger
uses exactly the 0.4.0 arithmetic and writes no lot, so an upgrade to schema
version 9 changes no behaviour at all.

To tell which path a wallet is on:

```sql
SELECT tenant_key, lots_enabled_at IS NOT NULL AS on_lots, debt, expired
  FROM aurora_meter_credit_balances
 WHERE tenant_key = 'org_42';
```

Both writers exist in one release and they never run together on one wallet:
the flag is read from the balance row the writer has already locked `FOR
UPDATE`, and the only thing that sets it takes the same lock. A wallet is
therefore owned by exactly one of them at every instant, and the legacy writer
keeps working indefinitely for any wallet that is not cut over.

### Moving a wallet onto lots

`mix aurora_meter.credits.migrate_lots` replays a wallet's whole ledger into
lots, reconciles the replay against that wallet's own `balance`, `held` and
`promotional`, and sets `lots_enabled_at` only when the two agree exactly. It
is shadow by default, resumable, and it refuses rather than guesses: a wallet
whose history cannot be reproduced exactly is reported with the reason and left
on the legacy writer. See [Upgrading to lots](upgrading-to-lots.md) for the
procedure and what each refusal means.


### Reading the lots

`AuroraMeter.Credits.Lots` is the public read side, and it is how you answer
"where did the money go" without reading the ledger table by hand.

```elixir
alias AuroraMeter.Credits.Lots

Lots.list(org)                                     # open lots, in spend order
Lots.list(org, states: :all)                       # including exhausted and reversed
Lots.get(org, "stripe:pi_123")                     # by grant reference, or by lot id
Lots.for_source(org, %{payment_intent_id: "pi_123"})
Lots.allocations(org, lot_id: lot.id)              # what moved, oldest first
```

`list/2` returns lots in the order the next debit will consume them, so a reader
sees what the next spend will take rather than merely what exists. The order is
fixed by the engine and no option changes it: a caller that could choose it
could choose which of two customers' money is spent first, which is not a
display concern. `order: :granted_at` re-sorts the same lots for a human reading
a history and changes nothing about what a debit does.

An **allocation** records a movement between two buckets of one lot, with
`from_bucket` and `to_bucket` as well as `kind`. The source matters: a `consume`
can come out of `available` (a debit) or out of `reserved` (a settlement against
its own hold), so folding a lot's allocations back into its five quantities needs
both ends of each movement. A settlement of 1 USD against a 4 USD hold reads:

```elixir
Lots.allocations(org, reference: "job:42")
# [%{kind: :reserve,   from_bucket: :available, to_bucket: :reserved, amount: 4_000_000, ...},
#  %{kind: :consume,   from_bucket: :reserved,  to_bucket: :consumed, amount: 1_000_000, ...},
#  %{kind: :unreserve, from_bucket: :reserved,  to_bucket: :available, amount: 3_000_000, ...}]
```

`for_source/2` matches the `source` map a grant was given, and in this release it
understands `:payment_intent_id` and `:recurrence_key` only. Any other key raises
`ArgumentError` rather than matching everything: its caller is a refund path, and
"return every lot" is not a near miss.

Everything here is read only, takes no lock and returns a snapshot. Never compute
an amount to write from a figure read here; the only read that is consistent with
a write is one made inside the transaction that writes, and the ledger makes its
own under the balance row's lock. A wallet with no lots answers `[]` or `nil`.

## Recurring allowances

A plan can grant credit on a schedule. The policy is a plan property, declared
with [`recurring_credits/2`](plans.md#recurring-credit-allowances), and a plan
that declares none grants nothing: recurring grants are off by default.

```elixir
# from Oban, on the schedule cron_entries/0 returns
{"7 * * * *", AuroraMeter.Oban.RecurringGrants}
```

```elixir
# or from anything else, including iex
AuroraMeter.Credits.Recurrences.run(limit: 5_000)
```

A run walks entitled subscriptions in keyset order, skips a tenant whose plan
declares no allowance, and works out which periods each allowance still owes.
Each period is its own transaction under the wallet's balance row lock, so a
twelve-period catch-up is twelve short transactions and a concurrent debit
interleaves between them.

Size the run so it visits every entitled tenant at least once per period. The
default limit of 500 tenants is a floor: hourly with `limit: 5_000` visits
120,000 tenants a day.

### One grant per period, however many schedulers run

Aurora Meter does not assume your scheduler runs a job a single time. Two guards
make a second run a no-op, and both are evaluated **inside the balance row's
lock**:

* `aurora_meter_credit_recurrences` is unique on `(tenant_key, key)`, and the
  period's row is inserted `ON CONFLICT DO NOTHING`. No row back means another
  node has this period.
* the grant carries the period's own reference, and
  `aurora_meter_credit_transactions` is unique on `(kind, reference)`.

They are deliberately redundant because this is money. Neither is a lease and
neither is a duration, so neither can be inverted by a clock that steps
backwards.

`recurring:` is the one **reserved reference prefix**. `grant/3`,
`grant_with_status/3`, `hold/4`, `debit/4` and `reverse/4` raise `ArgumentError`
for a caller-supplied reference beginning with it, because the engine mints its
own there and a collision would make one of your manual grants look like a
period that had already been issued. Nothing else is reserved: manual grants
keep using any string.

### What a period writes

For a live period, with a rollover configured and the previous period's lot
unspent:

| Order | Row | Effect |
|---|---|---|
| 1 | `expire` | The previous period's lots give up whatever they still had available. |
| 2 | `grant` | The period's allowance, as a lot expiring at the period end. |
| 3 | `grant` | The carry, as a lot of its own, referenced `...:rollover` and expiring with the period it was carried into. |

Each lot's `source` carries `recurrence_key`, `recurrence`, `plan_id` and
`plan_version`, so a rolled-over micro-dollar is as auditable as any other:

```elixir
AuroraMeter.Credits.Lots.for_source(org, %{
  recurrence_key: "recurring:monthly:pro:1:2026-09-01T00:00:00Z"
})
```

### Rollover is capped and does not accumulate

`rollover: n` carries at most `n` micro-dollars of one period's **unused**
allowance into the next. Unused means what that period's lots did not spend,
whether or not the expiry sweep has already destroyed it: `available + expired`
is the same number either way, which is what makes the carry independent of
whether the sweep or the engine reached the lot first.

Two idle periods with a cap of 1,000,000 leave the third holding its own
allowance plus 1,000,000, never 2,000,000. The cap applies to the previous
period as a whole rather than to each of its lots, which is what stops it
compounding.

The cap is read from the previous period's **stored policy snapshot**, never
from the compiled plan. Raising a plan's cap does not retroactively raise what
an already-issued period may carry out of itself; the new cap governs the
periods granted after the edit.

### Catch-up after downtime

A tenant whose job has not run for three periods gets those three periods in
chronological order, each granted **and expired in the same transaction** and
recorded `issued_and_expired`, then its live period. The history is complete and
nothing that was owed months ago arrives spendable today. The rollover chain
still runs, so the live period carries the capped remainder a timely run would
have carried, and the only difference is that no spending happened in between.

One run processes at most `:max_periods` periods per entitlement (12 by
default). A run that stops there leaves the rest for the next one, which
continues chronologically from where it stopped.

**A tenant is never back-paid.** A tenant seen for the first time gets its
current period only: Aurora Meter does not invent history it never recorded. A
host adopting an allowance mid-period gets the whole of that period rather than
a pro-rated part of it.

### What is skipped, and why

| Reason | When |
|---|---|
| `:no_subscription`, `:not_entitled` | No subscription, or a status outside `AuroraMeter.Schema.Subscription.entitled_statuses/0`. `past_due` is entitled; `canceled` is not. |
| `:no_recurring_credits`, `:unknown_plan` | The plan declares no allowance, or names a plan this build does not have. |
| `:lots_disabled` | The wallet is not on the lot engine. The allowance, the cap and the catch-up are all defined over lots, so a wallet the allocator does not own is skipped rather than granted through the legacy projection. See [Upgrading to lots](upgrading-to-lots.md). |
| `:plan_changed` | The subscription changed plan between the scan and the lock. The re-read happens under the lock, so a tenant cancelled or moved a moment ago is not owed the old plan's allowance. |
| `:period_source_error`, `:period_source_stalled` | A custom period source raised, or answered with a window that does not move forward. The tenant is skipped with a warning and the run continues to the next one. |

### Watching it

```elixir
AuroraMeter.Credits.Recurrences.status(tenant: org)
```

```elixir
AuroraMeter.Operations.pause("credits_recurrences:global")
AuroraMeter.Operations.resume("credits_recurrences:global")
```

A paused run returns `%{paused: true}` and writes nothing; the pause is read
before every batch. `run(dry_run: true)` reports what it would grant and writes
nothing at all.

Every period examined emits `[:aurora_meter, :credits, :recurrence]` with
measurements `%{amount, rollover_amount}` and metadata `%{tenant_key, name,
plan_id, plan_version, period_start, result, reason}`. `result` is `:granted`,
`:issued_and_expired`, `:duplicate`, `:skipped` or `:failed`; on a duplicate,
`reason` says whether the period was recognised from its own row
(`:up_to_date`) or refused by the unique index inside the balance row's lock
(`:conflict`), which is the only branch two schedulers racing take.


### Which version a period is granted under

The version is resolved per period, from
`AuroraMeter.Plans.effective_for/2` at the period's start, so a catch-up across
an upgrade grants each period at its own contract rather than all of them at
today's. It is in the recurrence key and in the stored policy snapshot:

```
recurring:<name>:<plan_id>:<plan_version>:<period_start>
```

Two consequences worth stating.

**Deploying a new version does not change what an existing tenant is paid.** The
engine resolves the tenant's **own** version rather than the version effective
now, so a tenant on version 1 keeps version 1's amount, cap and expiry when
version 2 ships.

**Keys written before 1.0 are not granted a second time.** A tenant on version 1
resolves to `"1"`, which is the literal the pre-1.0 engine wrote, so the key is
byte for byte the same string. And "already granted" is decided by the
**period**, not by the key: the newest recurrence row for the entitlement is
what says which periods are still owed, and the `UNIQUE (tenant_key, key)` index
is the racing-schedulers guard underneath that.

Two narrower limits follow from resolving per period. The entitlement names a
run considers are the ones the tenant's **current** version declares, so an
allowance that existed only in a retired version is not back-paid. And a version
that resolves to neither compiled code nor a stored snapshot keeps the current
version's policy, because withdrawing an allowance a live contract declares
would be a worse answer than paying it.

## Money series

Charting the ledger takes three reads, all of them keyed by the same tenant
term and all of them in micro-dollars.

```elixir
Credits.spend_history(org, days: 30)
# [%{date: ~D[2026-08-13], spent: 0, granted: 0, net: 0, balance_after: nil},
#  %{date: ~D[2026-08-14], spent: 420_000, granted: 0, net: -420_000, balance_after: 19_580_000},
#  ...]

Credits.spend_total(org, days: 30)
# %{spent: 1_260_000, granted: 20_000_000, net: 18_740_000,
#   from: ~D[2026-08-13], to: ~D[2026-09-11]}

Credits.summary(org)
# %{balance: 19_580_000, available: 19_580_000, held: 0, promotional: 0, currency: "usd",
#   spent_this_period: 420_000, granted_this_period: 20_000_000,
#   period: %{start: ..., end: ..., source: :calendar},
#   daily_burn: 14_000, runway_days: 1_398}
```

### What a point holds

| Key | |
|---|---|
| `date` | the bucket, a `Date`; a month bucket is dated its **first day** |
| `spent` | positive magnitude of the spend entries in the bucket |
| `granted` | positive magnitude of the grants in the bucket |
| `net` | `granted - spent`; negative on a spending day |
| `balance_after` | the ledger balance after the **last** entry in the bucket, `nil` when the bucket has no entries |

`spent` and `granted` are magnitudes, not signed deltas, so a chart never has
to think about which way a number points.

### Every bucket is present

`spend_history/2` is **zero-filled across the whole range and sorted oldest
first**. A day nothing happened on is `spent: 0, granted: 0, net: 0,
balance_after: nil` — it is never missing. A chart can render the list straight
through with no gap handling, and a quiet day draws a baseline rather than a
hole. Buckets are UTC days (or UTC months); no local time zone is applied
anywhere.

### What counts as spend

Spend is `[:settle, :debit, :expire]` and grants are `[:grant]`. **`:hold` and
`:release` are excluded**: they move `held`, not `balance`, so counting a hold
would double-count the money its settlement later charges, and a released hold
would appear as spend that never happened. Passing either in `:kinds` raises
rather than silently producing a wrong chart.

An `:expire` *is* spend — promotional credit that left the balance is money the
customer no longer has, and hiding it makes the balance line in the chart stop
matching the balance in the header.

### Options

| Option | |
|---|---|
| `:days` | how far back from `:to`, default `30` |
| `:from` / `:to` | explicit inclusive `Date` bounds, overriding `:days` |
| `:bucket` | `:day` (default) or `:month` |
| `:kinds` | which kinds count as spend, default `[:settle, :debit, :expire]` |

`:bucket` and the range are independent: `spend_history(org, bucket: :month,
days: 365)` gives roughly thirteen month buckets, of which the first and last
are partial because the range does not start or end on a month boundary.

### Burn and runway

`summary/1` derives two figures from the **trailing 30 days**:

- `daily_burn` — mean spend per day, by integer division. `nil` when the tenant
  has spent nothing at all; `0` when the spend is real but too small to average
  a micro-dollar a day.
- `runway_days` — `available / daily_burn`, floored, never negative. `nil`
  whenever `daily_burn` is `nil` **or zero**: there is no honest number of days
  to show for a tenant who is not spending, and a dashboard must render the
  absence rather than a large number or a `∞`.

`spent_this_period` and `granted_this_period` use the configured period source
(`AuroraMeter.Period`), the same window `AuroraMeter.quota/2` reports — a
calendar month in the core, the Stripe subscription period under Pro.

### Rendering it

With the LiveView optional deps installed, two components draw this without any
JavaScript (inline SVG, `<title>` tooltips, `currentColor` so they take your
own text colour):

```heex
<.spend_chart points={AuroraMeter.Credits.spend_history(@org, days: 30)} />
<.credit_summary summary={AuroraMeter.Credits.summary(@org)} />
```

`spend_chart/1` takes `:height` (default `120`), `:label` and `:show_grants`
(default `true`, marking the buckets credit was added in). Amounts render as
dollars through `Money.format/2`; a zero-spend bucket renders a baseline bar
carrying the class `aurora-spend-chart__bar--zero`, never a gap.

## History

```elixir
Credits.history(org)                                   # newest first, 50
Credits.history(org, kinds: [:hold, :release])         # bookkeeping entries

page = Credits.history(org, limit: 20)                 # page...
next = Credits.history(org, limit: 20, cursor: Credits.cursor(List.last(page)))
```

Holds and releases are hidden by default: a customer-facing statement wants
grants, settlements, debits, reversals and expiries. Every entry carries
`balance_after` and `held_after`, so the log alone reproduces every balance.

### Page with `:cursor`, filter with `:before`

The list is ordered by the ledger's own identity column, not by `inserted_at`: a
wall clock is not monotonic and steps backwards on an NTP correction, a leap
second or a VM pause, so it orders nothing.

`:cursor` pages on that ordering key, which is unique and total, so a cursor walk
never skips an entry and never returns one twice, whatever the timestamps say.
Take one from `Credits.cursor/1` and treat it as opaque.

`:before` compares `inserted_at`. It is a **filter**, and it is exactly right for
"what happened before lunchtime". It is not a cursor: two entries written in the
same microsecond have no order under it, so a page boundary that lands between
them skips one and repeats another. Passing both raises `ArgumentError`.

## Low balance

Set a threshold per tenant or globally:

```elixir
Credits.set_low_balance_threshold(org, Money.from_cents(500))

config :aurora_meter,
  credits_low_balance_threshold: 5_000_000,
  credits_low_balance_handler: &MyApp.Billing.on_low_credits/1
```

When an entry takes the **spendable** balance below the threshold, Aurora Meter
broadcasts
`{:aurora_meter, :low_balance, %{tenant_key, available, spendable, threshold, crossing_id}}`
on `Credits.topic/1`, calls the handler with that map, and emits
`[:aurora_meter, :credits, :low_balance]` carrying how the handler ended.

The trigger is `spendable` rather than `balance - held`, so a tenant whose only
remaining funds sit on an expired lot is correctly seen as low.

### One alert per crossing

The crossing is written to the balance row, in the **same transaction** as the
balance change that caused it, and it is what makes the alert exactly one:

- a wallet that stays below its threshold for five more debits alerts once;
- a redelivered webhook that produces a deduplicated ledger row moves nothing
  and is not evaluated at all;
- a write the host rolls back takes the crossing with it, so the next write
  decides afresh;
- recovering to or above the threshold clears it silently, and a second genuine
  fall alerts again with a **different** `crossing_id`.

`set_low_balance_threshold/2` recomputes it: lowering or clearing the threshold
clears a crossing the wallet is no longer below, so the next genuine fall alerts.
It never raises an alert by itself, because nothing about the wallet moved.

The flag means "this crossing has been decided", not "this alert has been
delivered", which makes the handler **at most once**. That is a deliberate
trade: clearing the flag when a handler fails would re-alert on every subsequent
write from a wallet whose handler is broken. To force a re-alert, lower and
restore the threshold. A host that needs at-least-once subscribes to PubSub or
polls `balance/1`.

### The handler cannot fail your write

It runs in a supervised task with a timeout
(`:credits_low_balance_handler_timeout`, 5 s). A handler that raises, exits or
never returns is logged once, reported in the telemetry event's `handler`
metadata as `:raised`, `:exit` or `:timeout`, and **changes nothing** about the
ledger call: the write is committed and the caller still gets `{:ok, txn}`.

**The caller does not wait for it at all.** The ledger broadcasts the PubSub
message, starts a watcher and returns; the watcher runs the handler, kills it at
the timeout and emits the telemetry. So a slow handler cannot slow a write, and
this matters beyond tidiness: a handler that reads the database needs its own
connection, and the caller may be holding one. If the caller waited, the two
would wait for each other until the connection pool gave up. Keep the handler
short anyway (send a message, enqueue a job), but the reason is your pool rather
than your latency.

Two consequences for anything that observes it.
`[:aurora_meter, :credits, :low_balance]` arrives **after** the ledger call has
returned, so a test waits for it rather than reading it back, and two crossings
in quick succession may emit their events in either order, which is why each
carries its own `crossing_id`. The PubSub broadcast is **not** affected: it is
sent synchronously by the writer, before the watcher starts, so a consumer that
wants an exact count of crossings counts those.

## Live updates

```elixir
AuroraMeter.Credits.subscribe(org)
# after every ledger entry:
{:aurora_meter, :credits,
 %{tenant_key: "org_42", balance: ..., held: ..., available: ...,
   spendable: ..., debt: ..., expired: ...}}
```

The payload carries the same figures `balance/1` reports, so a LiveView can
render the new state without a second query. It may gain keys in a later
release; match the ones you need rather than the whole map.

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurora_meter, :credits, kind]` | `%{amount, balance_after, available_after, spendable_after}` | `%{tenant_key, reference, category, duplicate, overrun, deferred}` |
| `[:aurora_meter, :credits, :low_balance]` | `%{available, spendable, threshold}` | `%{tenant_key, crossing_id, handler}` |
| `[:aurora_meter, :credits, :hold_reconciliation]` | `%{amount, age_seconds, duration}` | `%{tenant_key, reference, decision, outcome}` |

`kind` is `:grant`, `:hold`, `:settle`, `:release`, `:debit`, `:reverse` or
`:expire`; `amount` is the signed delta the entry applied to the balance (`0` for
holds, releases and idempotent grant replays, which set `duplicate: true`).
Events fire after the transaction commits, and `deferred: true` says the call
was made inside a host transaction and the event waited for
`Credits.after_commit/1`.

`handler` on the low-balance event is `:ok`, `:none` (none configured),
`:raised`, `:exit` or `:timeout`, so an operator can tell whether the alert was
delivered.

## Configuration

| Key | Default | |
|---|---|---|
| `:credits_currency` | `"usd"` | stamped on new balance rows |
| `:credits_overdraft_tolerance` | `0` | µ$ a hold or debit may go below zero |
| `:credits_low_balance_threshold` | `nil` | global threshold in µ$; a tenant's own overrides it |
| `:credits_low_balance_handler` | `nil` | `fun/1` receiving `%{tenant_key, available, spendable, threshold, crossing_id}` |
| `:credits_low_balance_handler_timeout` | `5_000` | ms one handler call may take before it is killed; the write stands either way |
| `:credits_hold_reconciler` | `nil` | module, `{module, function}` or `fun/1` deciding about a stale hold; `nil` keeps every one |
| `:credits_hold_reconciler_timeout` | `5_000` | ms one `decide/1` call may take before it is killed and the hold kept |

## Concurrency

Every write runs in one transaction: the tenant's balance row is locked with
`SELECT ... FOR UPDATE`, the sufficiency check and the new entry are computed
against that locked row, and the row is updated before commit. Twenty
concurrent $0.10 holds against $1.00 admit exactly ten (there is a test that
does exactly that). Two settlements of the same hold serialise on the hold
row; the second sees `:already_settled`. A settle and a release of one hold
serialise the same way, which is what makes a recovery sweep safe to run beside
the work it is recovering, and safe to run on two nodes at once. There is no
lease on a hold and no timestamp in that decision: it is the row lock and the
status re-read inside it.

### Calling from inside your own transaction

Safe, and intended: `config :aurora_meter, repo:` is your repo, so a ledger
call inside your own `Repo.transaction/1` joins it, and settling a job beside
the row that records its result is one atomic write.

Every refusal (`:insufficient_credits`, `:debt_outstanding`,
`:duplicate_reference`, `:already_settled`, a grant a hold has spoken for) is
decided **before** anything is written and comes back as `{:error, reason}`
with your transaction
still open and still yours to commit. None of them calls `Repo.rollback/1`,
deliberately: in a nested transaction a rollback marks the *whole* transaction
whatever `:mode` you passed, so a duplicate webhook delivery would take the
host's own writes down with it and fail its next statement on that
connection.

If you are testing this yourself, note that an `Ecto.Adapters.SQL.Sandbox`
DataCase cannot see that class of bug: the sandbox holds a transaction of its
own, so yours is nested inside it and an abort unwinds no further than its
savepoint. The regression test for it is deliberately unsandboxed.

**Call `Credits.after_commit/1` on the way out.** Inside your transaction the
ledger's own is nested, so what its inner transaction returning means is that a
savepoint was released, not that anything is durable. Telemetry, PubSub and the
low-balance handler all describe money, and a handler that fires for a balance
you then roll back is worse than one that fires a moment late, so they are queued
on your process and this runs them:

```elixir
Repo.transaction(fn ->
  {:ok, _txn} = AuroraMeter.Credits.settle("job:42", cost)
  {:ok, _job} = MyApp.Jobs.mark_billed(job)
end)
|> case do
  {:ok, result} -> AuroraMeter.Credits.after_commit(); {:ok, result}
  {:error, reason} -> AuroraMeter.Credits.after_commit(discard: true); {:error, reason}
end
```

`discard: true` drops the queue without running anything, which is what the
rollback branch wants: the writes are gone, so the effects describing them must
not fire. A ledger call that owns its transaction is unaffected and needs none of
this.

The queue lives in the calling process, which is exactly where Ecto's transaction
scope lives, so the two have the same lifetime. A process that dies between the
commit and the drain loses that round of effects: the money is committed and
correct, and one telemetry event, one PubSub message and possibly one low-balance
alert are not delivered. `Credits.deferred_effects?/0` answers whether anything
is waiting, so your own tests can assert that no path forgot the call.

## Testing

`AuroraMeter.Test` ships `fund!/3`, `drain!/1` and `credit_balance/1`; see the
[testing guide](testing.md).
