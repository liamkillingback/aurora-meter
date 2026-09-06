# Aurora Meter

Real-time usage metering, plan entitlements, and Stripe-ready billing primitives
for Phoenix — **count, gate, and bill on the BEAM**.

Aurora Meter is a library you add to your Phoenix app (a dependency, not a hosted
service — your app keeps its data). It does three tightly-coupled jobs:

- **Meter** — record billable events at high throughput and aggregate them in
  real time. Increments hit an in-memory ETS counter (~8M incr/s on a laptop);
  nothing touches the database on the hot path.
- **Entitle** — gate actions on `plan + live usage`. Hard limits block; metered
  overage is allowed and billed.
- **Bill** *(Pro)* — sync plans and usage to Stripe and render hosted usage
  dashboards.

## Install

```elixir
def deps do
  [{:aurora_meter, "~> 0.2"}]
end
```

Generate the migration and run it:

```bash
mix aurora_meter.gen.migration -r MyApp.Repo
mix ecto.migrate
```

Configure it and add it to your supervision tree, after the repo and PubSub:

```elixir
# config/config.exs
config :aurora_meter,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  plans: MyApp.Plans

# application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  AuroraMeter,
  MyAppWeb.Endpoint
]
```

## Define plans

```elixir
defmodule MyApp.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :ai_generations, 50, :hard
    feature :api_access, false
  end

  plan :pro do
    price 2_000
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2
    feature :api_access, true
  end
end
```

## Use it — the three jobs

```elixir
AuroraMeter.subscribe(org, :pro)                     # assign a plan (local)

AuroraMeter.track(org, :ai_generations, 1)           # meter
AuroraMeter.usage(org, :ai_generations)              # => 1
AuroraMeter.remaining(org, :ai_generations)          # => 999

case AuroraMeter.check(org, :ai_generations) do      # gate
  :ok -> run_generation()
  {:error, :limit_exceeded} -> prompt_upgrade()
  {:error, :not_entitled} -> prompt_upgrade()
end

# gate + run + meter, atomically (correct under concurrency):
AuroraMeter.with_quota(org, :ai_generations, fn -> run_generation() end)
# => {:ok, result} | {:error, :limit_exceeded | :not_entitled}

AuroraMeter.quota(org, :ai_generations)          # dashboard-ready snapshot
# => %{kind: :hard, used: 1, limit: 1_000, remaining: 999, percent: 0, period: %{...}, ...}

AuroraMeter.history(org, :ai_generations, days: 30)   # daily points for a chart
# => [%{date: ~D[2026-08-08], value: 0}, ..., %{date: ~D[2026-09-06], value: 1}]
```

Plan lookups are cached in ETS and invalidated on every subscription write (on
every node), so the whole gate is database-free per request. The flusher
persists counters on an interval and once more on shutdown.

Live usage in a LiveView:

```elixir
# in mount/3
if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)

# in the template
<.usage_meter tenant={@org} feature={:ai_generations} />
```

## Upgrading from 0.1

0.2 adds the `aurora_meter_history` table (schema version 2). Generate and run
the upgrade migration:

```bash
mix aurora_meter.gen.migration -r MyApp.Repo --from 2
mix ecto.migrate
```

## Free vs Pro

The free MIT core does everything above. The commercial `aurora_meter_pro`
package adds Stripe checkout + webhook sync, metered-overage reporting, hosted
usage dashboards, quota alerts, and historical rollups.

## Docs

Guides: [Getting started](docs/getting-started.md) ·
[Configuration](docs/configuration.md) · [Metering](docs/metering.md) ·
[Entitlements](docs/entitlements.md) · [Plans](docs/plans.md) ·
[Telemetry](docs/telemetry.md) · [Testing](docs/testing.md). Architecture
decisions start at [ADR 0001](docs/adr/0001-resolved-decisions.md).

## License

MIT — see [`LICENSE`](LICENSE). The `aurora_meter_pro` package is licensed
separately.
