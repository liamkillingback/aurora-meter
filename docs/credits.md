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
propagates. A hold that is never settled or released stays pending: pick
references you can find again (the job id) and release stragglers from the
code path that abandons the work.

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

## Concurrency

Every write runs in one transaction: the tenant's balance row is locked with
`SELECT ... FOR UPDATE`, the sufficiency check and the new entry are computed
against that locked row, and the row is updated before commit. Twenty
concurrent $0.10 holds against $1.00 admit exactly ten (there is a test that
does exactly that). Two settlements of the same hold serialise on the hold
row; the second sees `:already_settled`.

## Testing

`AuroraMeter.Test` ships `fund!/3`, `drain!/1` and `credit_balance/1`; see the
[testing guide](testing.md).
