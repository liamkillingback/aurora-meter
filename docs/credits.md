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
# %{balance: 20_000_000, held: 500_000, available: 19_500_000,
#   promotional: 0, currency: "usd", low_balance_threshold: nil}
```

- `balance` is everything granted minus everything settled, debited or
  expired. It is signed: a settlement can exceed its hold.
- `held` is the sum of pending holds. `available = balance - held` is what
  `available/1` returns and what new holds are checked against.
- `promotional` is the part of the balance that came from promotional grants.

`sufficient?(org, amount)` is `available + overdraft_tolerance >= amount`, the
same test `hold/4` and `debit/4` apply under the row lock.

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

**Limitation:** the balance keeps one `promotional` figure per tenant, not one
per grant. With several live promotional grants, the first to expire can take
credit a later grant contributed. If you issue overlapping promotions, make the
later one paid or an adjustment, or expire the earlier one first.


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
Credits.history(org, limit: 20, before: last.inserted_at)   # page
Credits.history(org, kinds: [:hold, :release])         # bookkeeping entries
```

Holds and releases are hidden by default: a customer-facing statement wants
grants, settlements, debits and expiries. Every entry carries `balance_after`
and `held_after`, so the log alone reproduces every balance.

## Low balance

Set a threshold per tenant or globally:

```elixir
Credits.set_low_balance_threshold(org, Money.from_cents(500))

config :aurora_meter,
  credits_low_balance_threshold: 5_000_000,
  credits_low_balance_handler: &MyApp.Billing.on_low_credits/1
```

When an entry takes the available balance from at or above the threshold to
below it — once per crossing, not on every debit while it stays low — Aurora
Meter emits `[:aurora_meter, :credits, :low_balance]`, broadcasts
`{:aurora_meter, :low_balance, %{tenant_key, available, threshold}}` on
`Credits.topic/1`, and calls the handler with that map. The handler runs in
the calling process after the transaction committed; keep it short (send a
message, enqueue a job).

## Live updates

```elixir
AuroraMeter.Credits.subscribe(org)
# after every ledger entry:
{:aurora_meter, :credits, %{tenant_key: "org_42", balance: ..., held: ..., available: ...}}
```

## Telemetry

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurora_meter, :credits, kind]` | `%{amount, balance_after, available_after}` | `%{tenant_key, reference, category, duplicate, overrun}` |
| `[:aurora_meter, :credits, :low_balance]` | `%{available, threshold}` | `%{tenant_key}` |
| `[:aurora_meter, :credits, :hold_reconciliation]` | `%{amount, age_seconds, duration}` | `%{tenant_key, reference, decision, outcome}` |

`kind` is `:grant`, `:hold`, `:settle`, `:release`, `:debit` or `:expire`;
`amount` is the signed delta the entry applied to the balance (`0` for holds,
releases and idempotent grant replays, which set `duplicate: true`). Events
fire after the transaction commits.

## Configuration

| Key | Default | |
|---|---|---|
| `:credits_currency` | `"usd"` | stamped on new balance rows |
| `:credits_overdraft_tolerance` | `0` | µ$ a hold or debit may go below zero |
| `:credits_low_balance_threshold` | `nil` | global threshold in µ$; a tenant's own overrides it |
| `:credits_low_balance_handler` | `nil` | `fun/1` receiving `%{tenant_key, available, threshold}` |
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

Every refusal — `:insufficient_credits`, `:duplicate_reference`,
`:already_settled`, a grant a hold has spoken for — is decided **before**
anything is written and comes back as `{:error, reason}` with your transaction
still open and still yours to commit. None of them calls `Repo.rollback/1`,
deliberately: in a nested transaction a rollback marks the *whole* transaction
whatever `:mode` you passed, so a duplicate webhook delivery would take the
host's own writes down with it and fail its next statement on that
connection.

If you are testing this yourself, note that an `Ecto.Adapters.SQL.Sandbox`
DataCase cannot see that class of bug: the sandbox holds a transaction of its
own, so yours is nested inside it and an abort unwinds no further than its
savepoint. The regression test for it is deliberately unsandboxed.

## Testing

`AuroraMeter.Test` ships `fund!/3`, `drain!/1` and `credit_balance/1`; see the
[testing guide](testing.md).
