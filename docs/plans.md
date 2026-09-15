# Plans

Plans are declared with a compile-time DSL and validated when your module
compiles (duplicate features, invalid modes, and negative numbers all raise).

```elixir
defmodule MyApp.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0                                   # minor units (cents) / month
    limit :ai_generations, 50, :hard          # hard cap: blocks at 50
    feature :api_access, false                # feature off
  end

  plan :pro do
    price 2_000                               # $20.00 / month
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5                         # a plan value, read with feature_value/3
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2  # allow overage, ~$0.02 each
    feature :api_access, true
  end

  plan :payg do
    price 0
    counter :requests                         # measured; never blocked, never billed
    feature :api_access, true
  end
end
```

## Feature kinds

- `limit :f, n, :hard` — a hard cap. `check/2` blocks at `n`.
- `metered :f, included: i, unit_price: p` — allow overage beyond `i`; Pro bills
  it. `included`/`unit_price` are for local estimates and display — Stripe is the
  billing source of truth.
- `counter :f` — measured, never blocked, never billed. `check/2` is always
  `:ok`, `remaining/2` is `:unlimited`, and `quota/2` reports
  `kind: :counter` with `limit`, `included` and `percent` all `nil`. Reach for
  it when the money lives somewhere else — a prepaid credit ledger, an invoice
  built outside Aurora Meter — and the plan only wants a number on the
  dashboard.
- `feature :f, boolean` — plain on/off access (no quota).
- `feature :f, n` (non-negative integer) — a value the plan carries for your
  code to read (seats, projects, retention days). Always entitled, never
  counted; `AuroraMeter.feature_value(tenant, :f, default)` returns `n`, and
  `quota/2` reports `kind: :feature, value: n`.

## Lookups

```elixir
AuroraMeter.Plans.all()                              # %{id => %AuroraMeter.Plan{}}
AuroraMeter.Plans.get(:pro)                           # %AuroraMeter.Plan{}
AuroraMeter.Plans.feature_config(:free, :ai_generations)  # {:limit, 50, :hard}
AuroraMeter.Plans.feature_config(:payg, :requests)        # {:counter}
AuroraMeter.Plans.feature_value(:pro, :seats)             # 5
AuroraMeter.Plans.feature_value(:free, :seats, 1)         # 1 (default when undeclared)
```

Point config at your module: `config :aurora_meter, plans: MyApp.Plans`. Add the
DSL to your formatter's `import_deps` for paren-free definitions:

```elixir
# .formatter.exs
[import_deps: [:aurora_meter]]
```

## Counter or metered?

They look similar — both count without blocking — but they say different things
to your customer, and the dashboard repeats whichever one you picked.

| | `metered :f, included: i, unit_price: p` | `counter :f` |
|---|---|---|
| Blocks? | no | no |
| Denominator | `included` | none |
| `quota/2` `percent` | `used / included` | `nil` |
| `quota/2` `overage` | `max(0, used - included)` | always `0` |
| Reads as | "1,200 of 1,000 · 200 over the included allowance" | "1,200 this period" |
| Bill it how? | subscription overage, at period end | it is already paid for |

If a request is paid for out of a prepaid balance the moment it runs, it has no
allowance and no overage: it is a counter. Writing it as
`metered(included: 0, unit_price: 0)` makes every single request read as
overage against an allowance of zero. See
[ADR 0006](adr/0006-counter-feature-kind.md), and chart the money itself with
[`AuroraMeter.Credits.spend_history/2`](credits.md#money-series).

## Recurring credit allowances

A plan can grant credit on a schedule: a monthly allowance, a weekly top-up, a
trial's starting balance. It is off unless the plan says otherwise.

```elixir
plan :pro do
  price 4_900
  metered :tokens, included: 1_000_000, unit_price: 1

  recurring_credits :monthly_allowance,
    amount: 5_000_000,        # micro-dollars, required, a positive integer
    category: :promotional,   # the default
    rollover: 1_000_000,      # micro-dollars carried into one following period
    expires: :period_end      # the default
end
```

Nothing happens until something calls the engine. With Oban, that is
`AuroraMeter.Oban.RecurringGrants` on the schedule
`AuroraMeter.Oban.cron_entries/0` returns; with any other scheduler, or none, it
is `AuroraMeter.Credits.Recurrences.run/1`. See
[Recurring allowances](credits.md#recurring-allowances) for what a run does and
[the scheduler map](operations/scheduler.md) for how to wire it.

### The options

| Option | Default | What it means |
|---|---|---|
| `:amount` | required | Micro-dollars granted per period. A positive **integer**; a float is a compile error, because money is an integer everywhere in this package. |
| `:category` | `:promotional` | `:promotional`, `:paid` or `:adjustment`, the lot categories. Promotional is spent before paid. |
| `:rollover` | `0` | At most this many micro-dollars of one period's **unused** allowance are carried into the next period, as a lot of their own. `0` is no rollover. |
| `:expires` | `:period_end` | `:period_end`, `:never`, or `{:seconds, n}` from the grant. |

### Three combinations that do not compile

They are refused at compile time, with the plan and the entitlement named,
because each one is arithmetic that cannot be honoured rather than a preference:

* **`rollover` above zero with anything but `expires: :period_end`.** A rollover
  is defined as what the previous period's lot did not spend *before it
  expired*. A lot that outlives the period boundary would be carried into the
  new period and still be spendable in the old one, and the tenant would hold
  the same micro-dollar twice.
* **An expiry on a non-promotional allowance.** Only promotional grants expire;
  `AuroraMeter.Schema.CreditTransaction` refuses an `expires_at` on any other
  category. A paid recurring top-up is money the customer keeps, so it takes
  `expires: :never`.
* **A name or a plan id that is not lower snake case.** Both become part of the
  recurrence key (`"recurring:<name>:<plan>:<version>:<period start>"`), which is
  read back by splitting on `:`, so neither may contain one.

`expires: :never` on a promotional allowance compiles and warns: every period's
grant stays spendable for ever and the tenant accumulates them, which is almost
always a mistake.

### Reading it back

```elixir
AuroraMeter.Plans.get(:pro).recurring_credits
#=> [%{name: :monthly_allowance, amount: 5_000_000, category: :promotional,
#      rollover: 1_000_000, expires: :period_end}]

AuroraMeter.Plans.get(:free).recurring_credits
#=> []
```

It is a list rather than a map, in declaration order, and a plan may declare
more than one allowance as long as the names differ. It is deliberately **not**
a feature kind: `t:AuroraMeter.Plan.feature_config/0` and everything that reads it
are untouched by this, so adding an allowance to a plan cannot change what
`check/2`, `quota/2` or `remaining/2` say about anything.
