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
end
```

## Feature kinds

- `limit :f, n, :hard` — a hard cap. `check/2` blocks at `n`.
- `metered :f, included: i, unit_price: p` — allow overage beyond `i`; Pro bills
  it. `included`/`unit_price` are for local estimates and display — Stripe is the
  billing source of truth.
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
AuroraMeter.Plans.feature_value(:pro, :seats)             # 5
AuroraMeter.Plans.feature_value(:free, :seats, 1)         # 1 (default when undeclared)
```

Point config at your module: `config :aurora_meter, plans: MyApp.Plans`. Add the
DSL to your formatter's `import_deps` for paren-free definitions:

```elixir
# .formatter.exs
[import_deps: [:aurora_meter]]
```
