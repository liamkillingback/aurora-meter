# Aurora Meter

**Real-time usage metering, plan entitlements and Stripe-ready billing for Phoenix. Count, gate and bill on the BEAM.**

[![Hex.pm](https://img.shields.io/hexpm/v/aurora_meter.svg)](https://hex.pm/packages/aurora_meter)
[![HexDocs](https://img.shields.io/badge/docs-hexdocs-blueviolet.svg)](https://hexdocs.pm/aurora_meter)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.15-4e2a8e.svg)](mix.exs)

![Live usage climbing from 62% to 96% of the included quota in a LiveView dashboard, updated over PubSub](https://raw.githubusercontent.com/liamkillingback/aurora-meter/main/docs/assets/usage-meter.gif)

*A LiveView dashboard reading Aurora Meter's ETS counters. Every increment on
the server shows up in the browser within a second, with no polling and no
database read.*

Every SaaS does the same three jobs: count what each customer uses, stop them at
their plan's limit, and bill for the rest. On Phoenix you hand-roll all three.
Aurora Meter is a library that does them with a few function calls:

```elixir
# count: an ETS increment, nothing touches the database
AuroraMeter.track(org, :ai_generations)

# gate, run and meter atomically, so hard limits hold under concurrency
AuroraMeter.with_quota(org, :ai_generations, fn ->
  generate_report()
end)
# => {:ok, result} | {:error, :limit_exceeded} | {:error, :not_entitled}
```

```heex
<.usage_meter tenant={@org} feature={:ai_generations} />
```

It is a dependency, not a hosted service. Your app keeps its data, and the free
core is MIT with no email gate, no trial and no expiry.

## Why it is fast

Increments hit a shared ETS table with `:ets.update_counter/4`: atomic,
lock-free, and never serialised through a process mailbox. There is no GenServer
per tenant. A single flusher persists absolute-value snapshots to Postgres on an
interval and once more on shutdown, and a broadcaster fans live values out over
`Phoenix.PubSub`. The database is touched by the flusher and by a one-time seed
when a counter is first read, never on the write path.

Measured with the bundled benchmark (`mix aurora_meter.bench 8 500000`, dev
laptop, Elixir 1.20 / OTP 29):

| Load shape | Throughput |
|---|---|
| 8 processes, distinct counters (realistic) | ~7.9M increments/s |
| 8 processes, one hot counter (worst case) | ~53k increments/s |

The full run is in [docs/evidence/phase-03/bench.md](docs/evidence/phase-03/bench.md).
Plan lookups are cached in ETS and evicted on every subscription write, on every
node, so the entitlement check is also database-free per request.

## Quick start

**1. Add the dependency**

```elixir
def deps do
  [{:aurora_meter, "~> 0.2"}]
end
```

**2. Generate and run the migration**

```bash
mix aurora_meter.gen.migration -r MyApp.Repo
mix ecto.migrate
```

**3. Configure it and add it to your supervision tree**, after the repo and PubSub:

```elixir
# config/config.exs
config :aurora_meter,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  plans: MyApp.Plans

# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Phoenix.PubSub, name: MyApp.PubSub},
  AuroraMeter,
  MyAppWeb.Endpoint
]
```

**4. Declare your plans.** A small DSL, validated at compile time. Hard caps,
metered overage and feature flags live in one place:

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

That is the whole setup. `mix aurora_meter.install` generates the migration and
prints the config to add, and the [getting started guide](docs/getting-started.md)
covers the rest.

## The three jobs

```elixir
AuroraMeter.subscribe(org, :pro)                  # assign a plan (local)

# Meter
AuroraMeter.track(org, :ai_generations)           # +1
AuroraMeter.track(org, :ai_generations, 5)        # +5
AuroraMeter.usage(org, :ai_generations)           # => 6
AuroraMeter.remaining(org, :ai_generations)       # => 994
AuroraMeter.history(org, :ai_generations, days: 30)
# => [%{date: ~D[2026-08-08], value: 0}, ..., %{date: ~D[2026-09-06], value: 6}]

# Entitle
AuroraMeter.check(org, :ai_generations)           # :ok | {:error, :limit_exceeded | :not_entitled}
AuroraMeter.entitled?(org, :api_access)           # plan grants the feature, ignores quota
AuroraMeter.with_quota(org, :ai_generations, fn -> run_generation() end)

# Dashboard-ready snapshot
AuroraMeter.quota(org, :ai_generations)
# => %{kind: :hard, used: 6, limit: 1_000, remaining: 994, percent: 0, period: %{...}}
```

`with_quota/4` reserves first (increment, compare, roll back on breach), runs the
function, and rolls the reservation back if the function raises. The
reservation is the usage, so two concurrent calls cannot both squeeze through
the last unit of a hard limit.

### Live usage in LiveView

Two drop-in components read the live ETS counters over PubSub. LiveView and
Phoenix.HTML are optional dependencies; the core runs headless without them.

```elixir
# mount/3
if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)
```

```heex
<.usage_meter tenant={@org} feature={:ai_generations} />
<.usage_summary tenant={@org} />
```

### Telemetry

`[:aurora_meter, :track]`, `[:aurora_meter, :reserve]` and `[:aurora_meter, :flush]`
events carry quantities and outcomes, ready for `Telemetry.Metrics` and
LiveDashboard. See the [telemetry guide](docs/telemetry.md).

## Guarantees and limits

Read this before you rely on it. The design choices are recorded as
[ADRs](docs/adr/0001-resolved-decisions.md).

- **Buffered by default.** Counters live in ETS and flush to Postgres every
  `:flush_interval` ms and on clean shutdown. A hard crash can lose at most one
  interval of increments. That is fine for dashboards and soft quotas.
- **Durable when it has to be.** Mark a feature durable
  (`config :aurora_meter, durable_features: [:ai_generations]` or
  `track(..., durable: true)`) and every increment also writes a raw event row
  synchronously. Use this for anything you invoice.
- **Counters are per node.** The ETS table is local to the VM and flushes are
  absolute-value upserts. Run the meter on one node, or use durable features
  for exact cross-node totals. Subscription cache invalidation is already
  cluster-wide; multi-node counter merging is on the roadmap.
- **Periods are UTC calendar months** in the free core. A new period starts a
  fresh counter with no reset job. Pro aligns periods to the Stripe
  subscription.
- **Postgres only** through Ecto. Elixir 1.15+.
- **Restart-safe reads.** A cold counter is seeded once from the last flushed
  value, so `usage/2` is correct after a deploy.

## Free vs Pro

The MIT core is the entire metering and entitlements engine. Aurora Meter Pro is
a separate commercial package for when Stripe should start charging.

| Capability | Core (MIT) | Pro |
|---|:-:|:-:|
| ETS real-time counters | ✓ | ✓ |
| Plan DSL and atomic `with_quota` gate | ✓ | ✓ |
| LiveView usage components | ✓ | ✓ |
| Postgres persistence, daily history, telemetry | ✓ | ✓ |
| Stripe Checkout and webhook sync | | ✓ |
| Metered usage reported to Stripe Billing Meters | | ✓ |
| Subscription-aligned billing periods | | ✓ |
| Historical rollups and CSV export | | ✓ |
| Hosted real-time dashboards | | ✓ |
| Quota alerts and reconciliation | | ✓ |

Pro plugs into the same config (`provider: AuroraMeter.Pro.Stripe`) and adds no
runtime dependency to the core. Details and pricing:
[phxtemplates.com/aurora-meter](https://phxtemplates.com/aurora-meter).

## How it compares

- **OpenMeter** is a hosted metering service with SDKs for Node, Python and Go,
  and none for Elixir. Aurora Meter is in-process, keeps your data in your
  Postgres, and needs no sidecar.
- **Laravel Cashier** covers subscriptions and metered billing but not
  real-time counting or plan gating. Aurora Meter does the counting and gating
  in the core, and Pro covers the Cashier part.
- **Hand-rolled** `UPDATE usage SET count = count + 1` works until it is on the
  hot path of every request. Moving the increment to ETS is the whole point.

## Upgrading from 0.1

0.2 adds the `aurora_meter_history` table (schema version 2):

```bash
mix aurora_meter.gen.migration -r MyApp.Repo --from 2
mix ecto.migrate
```

See the [changelog](CHANGELOG.md) for everything else that changed.

## Documentation

Guides: [Getting started](docs/getting-started.md) ·
[Configuration](docs/configuration.md) · [Metering](docs/metering.md) ·
[Entitlements](docs/entitlements.md) · [Plans](docs/plans.md) ·
[Telemetry](docs/telemetry.md) · [Testing](docs/testing.md)

API reference on [HexDocs](https://hexdocs.pm/aurora_meter).

## Contributing

Issues and pull requests are welcome. `mix check` runs the formatter, compiler
warnings as errors, Credo, Dialyzer, the test suite and the docs build. Tests
need a local Postgres; `mix test.setup` creates the database.

## License

MIT, see [LICENSE](LICENSE). The `aurora_meter_pro` package is licensed
separately under a commercial licence.
