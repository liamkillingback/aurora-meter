# Example: pay-as-you-go on prepaid credit

**The product.** Parsely is a document-parsing API. There is no monthly fee.
Customers buy credit — $25 at a time — and each document spends some of it.
A small PDF costs a fraction of a cent; a 900-page contract costs several
dollars. New accounts get $5 free, which expires after 30 days.

This example is the credit ledger: the part of Aurora Meter that holds actual
money. It is the longest of the four because money has more ways to go wrong
than counting does.

## 1. The plan has no limits in it

```elixir
defmodule Parsely.Plans do
  use AuroraMeter.Plans

  plan :payg do
    price 0
    counter :pages_parsed
    counter :api_requests
    feature :webhooks, true
  end
end
```

Every quantity here is a `counter`: measured, never blocked, never billed.

That is not laziness. **The money is in the ledger, not in the plan.** A
customer with credit may parse as much as they like; a customer without credit
is stopped by the balance, not by a quota. Modelling these as
`metered … included: 0` would make your dashboard announce that every single
request is overage awaiting an invoice, which is false in both halves — see
["Why `counter` exists"](concepts.md#why-counter-exists).

## 2. Money is micro-dollars

One dollar is 1,000,000 µ$. Use the helpers rather than writing zeroes:

```elixir
alias AuroraMeter.Credits
alias AuroraMeter.Credits.Money

Money.from_cents(2_500)            # => 25_000_000   ($25.00)
Money.format(25_000_000)           # => "$25.00"
Money.format_compact(1_500)        # => "$0.0015"
Money.format(1_500)                # => "$0.00"      <- rounds at 2dp
Money.format(1_500, precision: 6)  # => "$0.001500"
```

Sub-cent amounts are the whole reason for the unit. Parsely charges $0.0015 per
page; in cents that rounds to zero, and a million pages would be free.

Which is also why `format/2` needs care: its default precision is 2, so a
per-page price rendered with it reads `"$0.00"` — the very misreading the unit
exists to prevent. Use `format_compact/1` for unit prices and `format/2` for
balances.

## 3. Putting money in

Every grant needs a `:reference`, and the reference is the idempotency key:

```elixir
Credits.grant(org, Money.from_cents(2_500), reference: "stripe:pi_3abc")
# {:ok, %CreditTransaction{kind: :grant, amount: 25_000_000}}

# The same webhook, delivered twice
Credits.grant(org, Money.from_cents(2_500), reference: "stripe:pi_3abc")
# {:ok, %CreditTransaction{...}}   <- the original entry; nothing was added
```

This matters more than any other line in this guide. Stripe delivers each event
at least once and retries for days. Without a stable reference, one $25 payment
funds an account $50, or $75. Key it on something Stripe gives you and will
repeat — the PaymentIntent id — never on a timestamp or a random value.

When you need to know which of the two happened — to email a receipt exactly
once, say — ask for the status:

```elixir
Credits.grant_with_status(org, amount, reference: "stripe:pi_3abc")
# {:ok, txn, :new} | {:ok, txn, :duplicate}
```

Ask the ledger; do not look the reference up first and decide yourself. Two
deliveries arriving together both find nothing, both call themselves new, and
the customer gets two receipts. `grant_with_status/3` decides inside the row
lock, where the race cannot happen.

## 4. Taking money out

### When you know the cost up front

```elixir
Credits.debit(org, 1_500, "req:#{request_id}")
# {:ok, %CreditTransaction{}}
# {:error, :insufficient_credits}
# {:error, :duplicate_reference}
```

### When you do not

This is the normal case for real work. You know a document is about 200 pages,
so it will cost about $0.30 — but you find out the true page count only after
the parser has run.

Charging afterwards lets two large jobs start against one small balance and
both overdraw. Charging up front overcharges. So: **hold the estimate, then
settle the truth.**

```elixir
{:ok, _} = Credits.hold(org, 300_000, "doc:#{doc.id}")   # reserve $0.30
# ... parse; it was really 214 pages, $0.321 ...
{:ok, _} = Credits.settle("doc:#{doc.id}", 321_000)      # charge the real cost
```

| Step | What moves | Fails with |
|---|---|---|
| `hold/4` | `held` goes up; `available` goes down | `:insufficient_credits`, `:duplicate_reference` |
| `settle/3` | `balance` goes down by the real cost; the hold is freed | `:not_found`, `:already_settled` |
| `release/1` | the hold is freed; nothing is charged | `:not_found`, `:already_settled` |

While the hold is open, `available` already reflects it, so a second job cannot
spend the same money.

**A settlement never fails for want of credit.** If the document turned out to
be 3,000 pages and cost more than the hold, the balance goes negative. That is
deliberate: the work is done and the provider has already invoiced you, so a
negative balance is the honest record of a debt. The next `hold` or `debit` is
refused until a grant brings them back above zero.

### The one call that does it properly

```elixir
Credits.with_credits(org, 300_000, "doc:#{doc.id}", fn ->
  case Parsely.Parser.run(doc) do
    {:ok, text, pages} -> {:ok, text, pages * 1_500}   # settle for the real cost
    {:error, reason} -> {:error, reason}               # release, charge nothing
  end
end)
# {:ok, text} | {:error, reason} | {:error, :insufficient_credits}
```

The function returns `{:ok, result, cost_in_micros}` to settle, or
`{:error, reason}` to release and charge nothing. If it raises, throws or
exits, the hold is released and the error propagates.

Use this rather than hand-rolling hold/settle. It is the same three calls, with
the failure paths already right.

## 5. Calling it from inside your own transaction

Parsely records the parsed text and settles the charge together — either both
land or neither does:

```elixir
Parsely.Repo.transaction(fn ->
  {:ok, _} = Parsely.Documents.store_result(doc, text)
  {:ok, _} = Credits.settle("doc:#{doc.id}", cost)
end)
```

This is supported and intended: `config :aurora_meter, repo:` is *your* repo, so
the ledger call joins your transaction.

Every refusal — `:insufficient_credits`, `:duplicate_reference`,
`:already_settled` — is decided **before** anything is written and comes back as
`{:error, reason}` with your transaction still open. None of them calls
`Repo.rollback/1`, deliberately: in a nested transaction a rollback marks the
*whole* transaction whatever `:mode` you pass, so a duplicate webhook delivery
would take your own writes down with it.

> **If you write a test for this, do not use a sandboxed `DataCase`.** The Ecto
> SQL sandbox holds a transaction of its own, so yours is nested inside it and
> an abort unwinds no further than the sandbox's savepoint. This class of bug is
> invisible there — it survived an audit round in this very library behind a
> passing test.

## 6. Holds that nothing will ever close

A hold is taken before the row that remembers it exists, and those two cannot be
one write — the ledger is a different schema and often a different database. Kill
the process in between and money is reserved against a customer with nothing
pointing at it. `available` stays low for ever and nobody knows why.

Only you can tell such a hold from one whose work is still running, so the
ledger's job is to list them:

```elixir
defmodule Parsely.Workers.HoldSweeper do
  use Oban.Worker, queue: :maintenance

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    for hold <- AuroraMeter.Credits.pending_holds(older_than: cutoff, reference_prefix: "doc:") do
      "doc:" <> id = hold.reference

      unless Parsely.Documents.running?(id) do
        {:ok, _} = AuroraMeter.Credits.release(hold.reference)
        Logger.warning("released orphan hold #{hold.reference}")
      end
    end

    :ok
  end
end
```

`:older_than` is a `DateTime` and is required. `:reference_prefix` narrows to
one kind of work and `:limit` defaults to 200.

Give your holds references you can look up again — the document id, the job id —
and run this on a schedule. Every prefix you use needs covering; a sweeper that
only knows about `"doc:"` will not free a stranded `"query:"`.

## 7. The free trial, and making it expire

```elixir
Credits.grant(org, Money.from_cents(500),
  reference: "signup:#{org.id}",
  category: :promotional,
  expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
)
```

Categories are `:paid` (the default), `:promotional` and `:adjustment`.
Promotional credit is spent **first**, so a customer who tops up before their
trial runs out burns the free money before their own.

Expiry is a scheduled sweep:

```elixir
{:ok, expired_count} = Credits.expire_due(DateTime.utc_now())
```

With Pro, `AuroraMeter.Pro.Credits.Expirer` is an Oban worker that does this for
you every half hour.

Two behaviours worth knowing, because both were bugs once:

- **Expiry will not take back money a hold has reserved.** A hold promises the
  money will be there when the work settles. The grant keeps its expiry unset
  and a later pass finishes the job once the hold closes.
- **A grant expires only its own remainder.** With two promotional grants live,
  the first to expire cannot reclaim money the second put in. Promotional spend
  is attributed soonest-expiring-first.

## 8. Refunds and chargebacks

A refund is not a debit. Use `reverse/4`:

```elixir
Credits.reverse(org, Money.from_cents(2_500), "stripe:re_3xyz", %{"source" => "refund"})
```

It is never refused for want of balance — the money has already left Stripe, so
refusing would only make the ledger disagree with reality — and it is idempotent
on the reference like everything else.

Reversals are written with `category: :reversal`, which keeps them out of two
places a plain negative debit did not belong:

- they do not eat promotional credit, so refunding a top-up no longer silently
  consumes the sign-up bonus;
- they count against `granted` rather than as spend, so a refunded customer does
  not see the money in their spend chart or in the burn rate behind their runway
  estimate.

With Pro, you do not call this yourself — the Stripe webhook does, for
`charge.refunded` and for disputes, including putting the credit back if you win
one.

## 9. Telling them before they run out

```elixir
# A default for everyone
config :aurora_meter,
  credits_low_balance_threshold: 5_000_000,        # $5.00
  credits_low_balance_handler: &Parsely.Billing.low_balance/1

# Or per customer, overriding the default
Credits.set_low_balance_threshold(org, 20_000_000) # $20.00
```

```elixir
defmodule Parsely.Billing do
  def low_balance(%{tenant_key: key, available: available, threshold: _threshold}) do
    org = Parsely.Orgs.get_by_key!(key)
    Parsely.Mailer.low_balance(org, Money.format(available))
  end
end
```

The handler runs **after the crossing commits**, and only on a crossing — going
from $6 to $4 fires once; going from $4 to $3 does not fire again. That is what
you want for an email and is worth knowing before you write one that assumes
otherwise.

## 10. Showing the money

```elixir
Credits.summary(org)
# %{balance: 24_998_500, held: 300_000, promotional: 5_000_000, currency: "usd",
#   spent_this_period: 1_501_500, granted_this_period: 25_000_000,
#   daily_burn: 210_000, runway_days: 118}

Credits.spend_history(org, days: 30)
# [%{date: ~D[2026-03-01], spent: 210_000, granted: 0, net: -210_000,
#    balance_after: 24_998_500}, ...]
```

`daily_burn` and `runway_days` are `nil` when there is nothing honest to report
— a brand new account, or one that has spent nothing. Render the `nil`; do not
turn it into a zero and tell a customer they have no runway left.

`spend_history/2` is zero-filled across the whole range and sorted oldest
first, so a chart needs no gap handling. Holds and releases are excluded
(they move `held`, not `balance`) and are rejected if you pass them in `:kinds`.

## 11. Letting them buy more (Pro)

The core never touches a card. Pro sells credit through Stripe Checkout and
credits the ledger from the webhook:

```elixir
{:ok, url} =
  AuroraMeter.Pro.Credits.checkout(org, 2_500,
    success_url: url(~p"/billing?topped_up=1"),
    cancel_url: url(~p"/billing")
  )

redirect(conn, external: url)
```

And auto top-up charges the card saved by the last purchase, off-session, when
the balance crosses the threshold:

```elixir
AuroraMeter.Pro.Credits.update_auto_top_up(org, %{
  auto_top_up_enabled: true,
  threshold_micro: 5_000_000,    # below $5.00
  amount_cents: 2_500            # charge $25.00
})
```

The details — how a charge that times out is not charged twice, what happens
after three declines, and how a refund switches auto top-up off — are in the Pro
package's **Top-ups** guide.

## The whole thing, end to end

```elixir
# New customer: $5 free, expiring in a month
Credits.grant(org, Money.from_cents(500),
  reference: "signup:#{org.id}", category: :promotional,
  expires_at: DateTime.add(DateTime.utc_now(), 30, :day))

# They parse a document of unknown size
Credits.with_credits(org, 300_000, "doc:#{doc.id}", fn ->
  {:ok, text, pages} = Parsely.Parser.run(doc)
  {:ok, text, pages * 1_500}
end)

# ...and it is counted, for the dashboard, without pretending to be billable
AuroraMeter.track(org, :pages_parsed, pages)

# They are running low; the handler emails them
# They top up through Stripe; the webhook grants, keyed on the PaymentIntent
# A month later the unused trial credit expires, but not what a hold reserved
```

Next: [Showing usage](showing-usage.md) to put the balance, the burn and the
counters on screen.
