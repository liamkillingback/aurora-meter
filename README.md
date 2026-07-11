# Aurora Meter

Real-time usage metering, plan entitlements, and Stripe-ready billing primitives
for Phoenix — **count, gate, and bill on the BEAM**.

> **Status: pre-release scaffold.** The build is executed phase by phase per
> [`plan.md`](plan.md). Not yet published to Hex.

## What it is

A library you add to your Phoenix app (a dependency, not a hosted service — your
app keeps its data). It does three tightly-coupled jobs:

- **Meter** — record billable events at high throughput and aggregate them in
  real time. Increments hit an in-memory ETS counter; nothing touches the
  database on the hot path.
- **Entitle** — gate actions on `plan + live usage`. Hard limits block; metered
  overage is allowed and billed.
- **Bill** *(Pro)* — sync plans and usage to Stripe and render hosted usage
  dashboards.

## The developer surface

```elixir
AuroraMeter.track(tenant, :ai_generations, 1)
AuroraMeter.check(tenant, :ai_generations)                        # :ok | {:error, reason}
AuroraMeter.with_quota(tenant, :ai_generations, fn -> work() end) # gate + run + meter
AuroraMeter.usage(tenant, :ai_generations)                        # current-period integer
AuroraMeter.subscribe(tenant, :pro)
```

## Building it

Read [`AGENTS.md`](AGENTS.md) (the build contract) and execute [`plan.md`](plan.md)
phase by phase. Never skip a Verification Gate.

```bash
mix deps.get
mix check   # format + compile (warnings-as-errors) + credo + dialyzer + test + docs
```

## License

MIT — see [`LICENSE`](LICENSE). The commercial `aurora_meter_pro` package is
licensed separately.
