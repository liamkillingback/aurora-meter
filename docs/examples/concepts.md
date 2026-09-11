# Concepts, from nothing

This page assumes you know Elixir and nothing else. Every word that matters is
defined here, and every later example uses these words in exactly this sense.

## The problem, in one picture

You run a shop. Customers come in and take things. At some point you need to
answer three questions, and they are genuinely different questions:

1. **How much did this customer take?** — *metering*
2. **Are they allowed to take this?** — *entitlements*
3. **Who pays, and how much?** — *billing*

Most billing libraries answer 3 and leave you to invent 1 and 2. Aurora Meter
answers all three, and keeps them separate so you can use only the parts you
need.

## The four nouns

Everything in the library is about these four things.

### Tenant — *who*

The customer being metered. Usually an organisation or an account, not a
person: five people in one company share one allowance.

A tenant can be any Elixir term. It gets turned into a stable string key:

```elixir
AuroraMeter.track("org_42", :api_calls)   # a string
AuroraMeter.track(42, :api_calls)         # an integer
AuroraMeter.track(org, :api_calls)        # your own struct, see below
```

For your own struct, tell the library how to make a key from it:

```elixir
defmodule MyApp.MeterTenant do
  @behaviour AuroraMeter.Tenant
  @impl true
  def to_key(%MyApp.Org{id: id}), do: "org:#{id}"
end

config :aurora_meter, tenant: MyApp.MeterTenant
```

**The key must be stable.** If it changes, that customer looks like a brand new
customer with a fresh, empty allowance. Use the database id, never the name.

### Feature — *what*

The thing being counted or gated, named by an atom: `:api_calls`,
`:ai_generations`, `:seats`, `:export_to_pdf`.

You choose these names. They are yours. The library never invents one.

### Period — *when*

Allowances reset. A period is the window they reset in.

By default a period is a calendar month: 1 March to 31 March, then the counter
starts again at zero. With the Pro package it becomes the customer's own
billing cycle instead, so someone who subscribed on the 20th gets their reset
on the 20th.

```elixir
AuroraMeter.period(org)
# %{start: ~U[2026-03-01 00:00:00Z], end: ~U[2026-04-01 00:00:00Z], source: :calendar}
```

### Plan — *the rules*

What a tenant is allowed, written once in a module and checked at compile time.

```elixir
defmodule MyApp.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
  end
end
```

A tenant is put on a plan with `AuroraMeter.subscribe/2`:

```elixir
AuroraMeter.subscribe(org, :free)
```

## The five kinds of feature

This is the most important table in the documentation. Every metering surface
in the library is one of these five, and picking the wrong one is the single
most common mistake.

| You write | It means | `check/2` says | Money |
|---|---|---|---|
| `feature :pdf_export, true` | a switch that is on | `:ok` | — |
| `feature :pdf_export, false` | a switch that is off | `{:error, :not_entitled}` | — |
| `feature :seats, 5` | a number the plan carries | `:ok` | — |
| `limit :runs, 50, :hard` | a wall | `:ok` until 50, then `{:error, :limit_exceeded}` | — |
| `metered :runs, included: 1_000, unit_price: 2` | an allowance you may exceed | always `:ok` | billed after 1,000 |
| `counter :runs` | just counting | always `:ok` | never |

Read that as six rows and five kinds, because `feature` does two jobs: a
`true`/`false` switch, and an integer the plan carries (`:seats`) which you read
yourself rather than counting against.

### Choosing between them

- Does using it cost you money per use? If no → `feature` or `limit`.
- Should the customer be *stopped* at a line? → `limit … :hard`.
- Should they be *allowed past* the line and charged? → `metered`.
- Is the money already handled elsewhere (prepaid credits)? → `counter`.

The last one catches people out, so it has its own rule below.

### Why `counter` exists

If your product is prepaid — customers buy credit up front and each request
spends some — then nothing is billed at the end of the month, because the money
already left when the request ran.

If you model that with `metered … included: 0`, every single request reads as
*overage against an allowance of zero*, and your dashboard tells the customer
they are 6 over their limit and will be invoiced. Both halves of that sentence
are false.

`counter` measures and says nothing about money. Its `quota/2` reports
`limit: nil`, `included: nil`, `percent: nil` — deliberately, because there is
no denominator. **Anything drawing a progress bar must treat `nil` as "no bar",
never as `0`.** "0% of 0" is precisely the reading this kind exists to prevent.

## The two questions, in code

### "How much have they used?"

```elixir
AuroraMeter.track(org, :api_calls)        # add 1
AuroraMeter.track(org, :api_calls, 10)    # add 10
AuroraMeter.usage(org, :api_calls)        # => 37
AuroraMeter.usage_all(org)                # => %{api_calls: 37, ai_generations: 4}
```

`track/3` writes to an in-memory ETS counter and returns immediately. A
background flusher writes the totals to Postgres every five seconds. That is
why it is fast enough to call on every request, and also why a hard crash can
lose up to five seconds of counts. If a particular feature must never lose a
count, list it in `:durable_features` and it is written straight through.

### "Are they allowed?"

```elixir
AuroraMeter.check(org, :ai_generations)
# :ok | {:error, :limit_exceeded} | {:error, :not_entitled}
```

**Do not use `check/2` followed by `track/3` to enforce a hard limit.** Two
requests arriving together both read 49 of 50, both pass, and both write — 51.
Use `with_quota/4`, which reserves the count and the permission in one atomic
step:

```elixir
case AuroraMeter.with_quota(org, :ai_generations, fn -> generate() end) do
  {:ok, result} -> result
  {:error, :limit_exceeded} -> upgrade_prompt()
  {:error, :not_entitled} -> upgrade_prompt()
end
```

Under load, a hard limit of 50 admits exactly 50. If your function raises, the
reservation is given back before the error is re-raised.

## Money: the two shapes

There are exactly two ways money works here, and you can use either or both.

### Shape one — subscription with overage

The customer pays $20 a month, which includes 1,000 generations. The 1,001st
still works and costs 2¢, invoiced at the end of the month by Stripe.

```elixir
metered :ai_generations, included: 1_000, unit_price: 2
```

The core counts. The **Pro** package reports the overage to Stripe. See
[Allowance and overage](allowance-and-overage.md).

### Shape two — prepaid credits

The customer buys $25 of credit up front. Each request spends some. When the
balance runs low, they top up — or their card is charged automatically.

```elixir
AuroraMeter.Credits.debit(org, 1_500, "req:abc")   # spend $0.0015
AuroraMeter.Credits.available(org)                 # => 24_998_500
```

The core holds the ledger. The **Pro** package fills it from Stripe. See
[Prepaid credits](prepaid-credits.md).

### Micro-dollars

Credit amounts are integers called micro-dollars (µ$). One dollar is 1,000,000.

```
        $1.00  = 1_000_000
        $0.01  =    10_000
     $0.000001 =         1
```

Why not floats? Because `0.1 + 0.2` is not `0.3`, and a ledger that drifts is
worse than useless. Why not cents? Because an API call that costs a fortieth of
a cent rounds to zero, and then a million of them are free.

Never write the number yourself if you can help it:

```elixir
alias AuroraMeter.Credits.Money

Money.from_cents(2_500)            # => 25_000_000    ($25.00)
Money.to_cents(1_500_000)          # => 150           ($1.50)
Money.format(1_500_000)            # => "$1.50"
Money.format(1_500)                # => "$0.00"       <- careful
Money.format(1_500, precision: 6)  # => "$0.001500"
Money.format_compact(1_500)        # => "$0.0015"
```

**`format/2` rounds to two decimal places unless you ask for more.** That is
right for a balance and wrong for a unit price: a page that costs 1,500 µ$
renders as `"$0.00"`, which is the same misreading the unit was chosen to
avoid. For sub-cent amounts use `format_compact/1`, which keeps significant
digits, or pass `precision: 6`.

## Where things live

| You want | Call |
|---|---|
| count something | `AuroraMeter.track/4` |
| read a count | `AuroraMeter.usage/2`, `usage_all/1`, `history/3` |
| gate an action | `AuroraMeter.check/2`, `with_quota/4` |
| everything for a dashboard card | `AuroraMeter.quota/2` |
| put a tenant on a plan | `AuroraMeter.subscribe/2` |
| prepaid money | `AuroraMeter.Credits` |
| take money from a card | `AuroraMeter.Pro.Credits` (Pro) |
| bill overage to Stripe | `AuroraMeter.Pro.UsageReporter` (Pro) |

## Which example to read next

- Selling plan tiers with switches, seats and caps →
  [A team SaaS](team-saas.md)
- Selling a monthly allowance and charging for what goes over →
  [Allowance and overage](allowance-and-overage.md)
- Selling credit up front and spending it per request →
  [Prepaid credits](prepaid-credits.md)
- Putting any of it on screen → [Showing usage](showing-usage.md)

Every code block in those four pages is exercised by
`test/aurora_meter/examples_test.exs`, so if one of them stops being true, the
suite fails.
