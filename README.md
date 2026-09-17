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
per tenant. A single flusher persists idempotent delta batches to Postgres on an
interval and once more on shutdown, and a broadcaster fans live values out over
`Phoenix.PubSub`. The database is touched by the flusher and by a one-time seed
when a counter is first read, never on the write path.

Measured with the bundled benchmark (`mix aurora_meter.bench <mode>`) on
2026-09-16 on WSL Ubuntu 24.04.4, AMD Ryzen 9 7900X, 24 logical CPUs, 19.5 GiB,
Elixir 1.20.1 / OTP 29 (ERTS 17.0.1), Postgres 16.13. Each figure is the
**median of five runs**, each in a fresh BEAM. The flush row was re-measured on
2026-09-17 on the same machine, after a fix to the flusher's write path.

**micro** means the measurement isolates an in-memory path with no database
anywhere in it. **end-to-end** means every write reaches Postgres through the
real adapter. They differ by three orders of magnitude, so read the kind before
the number.

| Load shape | Kind | Median throughput | Median p95 |
|---|---|---|---|
| 8 processes, distinct counters | micro | 3,418,407 increments/s | 3.38 us |
| 8 processes, one hot counter | micro | 70,513 increments/s | 198.72 us |
| 8 processes, `with_quota/4` | micro | 423,658 ops/s | 27.14 us |
| 8 processes, durable `record/4` | end-to-end | 1,804 events/s | 6,035.22 us |
| 8 processes, `Credits.debit/4` | end-to-end | 1,091 ops/s | 9,241.27 us |
| 1 process, flush of 1,000 dirty keys | end-to-end | 22,619 rows/s | 59,192.45 us |

Every mode, its workload, its run-to-run spread and its raw records are in
[docs/evidence/v1/phase-08/08c-results.md](https://github.com/liamkillingback/aurora-meter/blob/main/docs/evidence/v1/phase-08/08c-results.md),
which is the only artifact any claim about performance cites. The figures this
table used to carry were measured against a counter row 0.4.0 replaced, and the
spread-key number is **lower** now on this machine, not higher; the measurement
and the reason are in that file.

Plan lookups are cached in ETS and evicted on every subscription write, on every
node, so the entitlement check is also database-free per request.

## A complete application you can run

[`examples/aurora_meter_example_ai/`](examples/aurora_meter_example_ai/README.md)
is the reference application: Phoenix and LiveView, an organisation tenant, a
hard quota, prepaid credit held and settled per request, a durable event for
every unit of work, and a host-owned outbox draining to the reference exporter.
It is MIT, it needs Elixir and Postgres and nothing else, and there is no AI and
no payment in it: the workload is a deterministic simulation and the credit is
seeded.

```bash
cd examples/aurora_meter_example_ai && mix setup && mix sample.seed && PORT=4021 mix phx.server
```

It is not part of the published package.

## Quick start

**1. Add the dependency**

```elixir
def deps do
  [{:aurora_meter, "~> 1.0"}]
end
```

While 1.0.0 is still a release candidate, that requirement resolves nothing: a
`~>` requirement never admits a pre-release. Pin the candidate to try it:

```elixir
def deps do
  [{:aurora_meter, "1.0.0-rc.1"}]
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
    feature :seats, 5
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2
    feature :api_access, true
    feature :seats, 25
  end

  plan :payg do
    price 0
    counter :requests               # measured; never blocked, never billed
    feature :api_access, true
  end
end
```

That is the whole setup. `mix aurora_meter.install` generates the migration and
prints the config to add, and the [getting started guide](docs/getting-started.md)
covers the rest.

## What `org` is

Every call takes a tenant first. `org` is whatever identifies the customer you
are metering: usually the organisation or account that owns the subscription,
not the individual user. It must be stable (the same customer always resolves
to the same value) and unique per customer, because it becomes the key for the
ETS counters, the `aurora_meter_counters` rows and the PubSub topics.

Out of the box `AuroraMeter.Tenant.Default` accepts:

```elixir
AuroraMeter.track("org_42", :ai_generations)     # a string, used as-is
AuroraMeter.track(42, :ai_generations)           # an integer, stored as "42"
AuroraMeter.track(:acme, :ai_generations)        # anything with String.Chars
```

Pass an Ecto struct or any other term and tell Aurora Meter how to read the key:

```elixir
defmodule MyApp.Tenant do
  @behaviour AuroraMeter.Tenant

  @impl true
  def to_key(%MyApp.Accounts.Org{id: id}), do: "org_#{id}"
  def to_key(%MyApp.Accounts.Scope{org_id: id}), do: "org_#{id}"
  def to_key(key) when is_binary(key), do: key
end

# config/config.exs
config :aurora_meter, tenant: MyApp.Tenant
```

Then `AuroraMeter.track(current_org, :ai_generations)` and
`<.usage_meter tenant={@current_org} ... />` work with the struct you already
have in your assigns. Plans are attached to the same key with
`AuroraMeter.subscribe(org, :pro)`, so subscribe with exactly the term you
meter with.

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
AuroraMeter.feature_value(org, :seats, 1)         # a plan value: 5 on :pro
AuroraMeter.with_quota(org, :ai_generations, fn -> run_generation() end)

# Dashboard-ready snapshot
AuroraMeter.quota(org, :ai_generations)
# => %{kind: :hard, used: 6, limit: 1_000, remaining: 994, percent: 0, period: %{...}}

# A counter is measured, never blocked, never billed, and has no denominator
AuroraMeter.quota(org, :requests)
# => %{kind: :counter, used: 6, limit: nil, included: nil, percent: nil, overage: 0, ...}
```

`with_quota/4` reserves first (increment, compare, roll back on breach), runs the
function, and rolls the reservation back if the function raises. The
reservation is the usage, so two concurrent calls cannot both squeeze through
the last unit of a hard limit.

### Prepaid credits

For pay-as-you-go pricing (AI tokens, API calls, anything priced per unit
rather than per plan), `AuroraMeter.Credits` keeps a prepaid balance per
tenant next to the plan counters. Amounts are integer micro-dollars
(`AuroraMeter.Credits.Money` converts), every write is a row lock plus an
append-only ledger entry, and `with_credits/4` holds an estimate, runs your
function and settles the actual cost:

```elixir
alias AuroraMeter.Credits
alias AuroraMeter.Credits.Money

Credits.grant(org, Money.from_cents(2_000), reference: "stripe:pi_123")   # idempotent

Credits.with_credits(org, estimate, "job:#{job.id}", fn ->
  {:ok, output, cost} = run_completion(job)
  {:ok, output, cost}                                   # settles cost, frees the hold
end)
# => {:ok, output} | {:error, :insufficient_credits}

Credits.balance(org)
# => %{balance: 19_580_000, held: 0, available: 19_580_000, promotional: 0, ...}
Money.format(Credits.available(org))                    # => "$19.58"
```

Promotional grants are consumed first and can expire; a low-balance threshold
fires telemetry, a PubSub message and an optional handler once per crossing.
See the [credits guide](docs/credits.md). Stripe top-ups and auto-recharge are
part of Pro.

Chart the ledger with three reads. Every bucket in the range is present, so a
chart never has to paper over a gap:

```elixir
Credits.spend_history(org, days: 30)
# => [%{date: ~D[2026-08-13], spent: 0, granted: 0, net: 0, balance_after: nil},
#     %{date: ~D[2026-08-14], spent: 420_000, granted: 0, net: -420_000, balance_after: 19_580_000}, ...]

Credits.spend_total(org, days: 30)     # %{spent:, granted:, net:, from:, to:}
Credits.summary(org)                   # balance, spend this period, daily_burn, runway_days
```

Holds and releases are excluded (they move `held`, not `balance`), buckets are
UTC, and `bucket: :month` rolls the same series up by month.

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

<.spend_chart points={AuroraMeter.Credits.spend_history(@org, days: 30)} />
<.credit_summary summary={AuroraMeter.Credits.summary(@org)} />
```

The money components are inline SVG with `<title>` tooltips and no JavaScript,
and they paint with `currentColor`, so they take the colours your design system
already set.

### Telemetry

`[:aurora_meter, :track]`, `[:aurora_meter, :reserve]`, `[:aurora_meter, :flush]`
and `[:aurora_meter, :credits, kind]` events carry quantities and outcomes,
ready for `Telemetry.Metrics` and LiveDashboard. See the
[telemetry guide](docs/telemetry.md).

## Guarantees and limits

**[The guarantee page](docs/guarantees.md) is the contract.** Fifteen rows, each
with the condition that makes it true, the thing that takes it away, the
invariant it rests on and the test that proves it. Read it before you rely on
any of this. The design choices behind it are recorded as
[ADRs](docs/adr/0001-resolved-decisions.md), and every invariant with its tests
is in [the correctness index](docs/correctness.md).

The short version:

- **Buffered by default.** Counters live in ETS and flush to Postgres on the
  `:flush_interval` and on clean shutdown. Losing the Store or the VM loses
  everything not yet in an acknowledged flush batch, which is more than one
  interval whenever the database has been away. A Flusher restart retains its
  pending batch; a Store restart does not.
- **Durable when it has to be.** Mark a feature durable
  (`config :aurora_meter, durable_features: [:ai_generations]` or
  `track(..., durable: true)`) and every increment also writes a raw event row
  synchronously. That row is an audit record; usage reporting still reads the
  persisted counters.
- **Quotas are strict on one node and convergent across nodes.** `check/2` is
  advisory and holds nothing; `reserve/2,3` and `with_quota/3,4` hold capacity
  atomically. On a cluster a hard cap is enforced against the local view, so a
  burst across N nodes can exceed it by what the other nodes admitted in one
  `:broadcast_interval`. See the [clustering guide](docs/clustering.md).
- **Cluster-wide counters.** Every node meters into its own ETS table and
  flushes *deltas* (`value = value + Δ`), so nodes add up instead of
  overwriting each other: the Postgres row is the cluster total. Needs a
  distributed `Phoenix.PubSub` (the one you already run for LiveView); on one
  node nothing changes.
- **Periods are half-open UTC intervals** `[start, end)`, calendar months in the
  free core. A new period starts a fresh counter with no reset job. Pro aligns
  periods to the Stripe subscription.
- **Usage export and scheduled work are at-least-once** with idempotent effects,
  never anything stronger.
- **Postgres only** through Ecto. See the supported versions below.
- **Restart-safe reads.** A cold counter is seeded once from the last flushed
  value, so `usage/2` is correct after a deploy.

### Supported versions

Every pair below is exercised by CI on every push, at the exact patch shown, and
the whole test suite runs on each of them.

| | Elixir | Erlang/OTP |
|---|---|---|
| Floor | 1.15.8 | 25.3.2.21 |
| Supported | 1.18.5 | 27.3.4.17 |
| Current | 1.20.4 | 29.0.6 |

Postgres: **16.13** is the tested version and **13** is the floor
(`gen_random_uuid()` needs Postgres 13 or the `pgcrypto` extension). A second CI
lane runs the suite on **15.6** as well.

Two things worth knowing before you pick the floor. Elixir 1.15.8 is the last
release of the 1.15 line, so it will not receive further security patches; a
host that needs a patched Elixir wants 1.20.4 or newer. And Erlang/OTP 25 is no
longer maintained upstream. The floor is a compatibility guarantee, not a
recommendation.

Optional integrations stay optional: a CI lane builds and tests this library
with no `phoenix_live_view`, no `phoenix_html` and no `igniter` present.

## Free vs Pro

The MIT core is the entire metering and entitlements engine. Aurora Meter Pro is
a separate commercial package for when Stripe should start charging.

| Capability | Core (MIT) | Pro |
|---|:-:|:-:|
| ETS real-time counters | ✓ | ✓ |
| Plan DSL and atomic `with_quota` gate | ✓ | ✓ |
| Hard caps, metered overage and never-billed counters | ✓ | ✓ |
| LiveView usage components | ✓ | ✓ |
| Postgres persistence, daily history, telemetry | ✓ | ✓ |
| Prepaid credit ledger (holds, settlements, promotional credit) | ✓ | ✓ |
| Spend charts from the ledger (`spend_history`, `summary`, components) | ✓ | ✓ |
| Stripe top-ups and auto-recharge | | ✓ |
| Stripe Checkout and webhook sync | | ✓ |
| Metered usage reported to Stripe Billing Meters | | ✓ |
| Subscription-aligned billing periods | | ✓ |
| Historical rollups and CSV export | | ✓ |
| Hosted real-time dashboards | | ✓ |
| Quota alerts and reconciliation | | ✓ |

Pro plugs into the same config (`provider: AuroraMeter.Pro.Stripe`) and adds no
runtime dependency to the core. Details, docs and pricing live at
[aurorameter.com](https://aurorameter.com) ([pricing](https://aurorameter.com/pricing),
[Pro preview](https://aurorameter.com/pro)). Aurora Meter is built by the team behind
[PhxTemplates](https://www.phxtemplates.com), whose
[Aurora API Starter](https://www.phxtemplates.com/templates/phx_api) ships a complete
metered-API SaaS on this core.

## How it compares

- **OpenMeter** is a hosted metering service with SDKs for Node, Python and Go,
  and none for Elixir. Aurora Meter is in-process, keeps your data in your
  Postgres, and needs no sidecar.
- **Laravel Cashier** covers subscriptions and metered billing but not
  real-time counting or plan gating. Aurora Meter does the counting and gating
  in the core, and Pro covers the Cashier part.
- **Hand-rolled** `UPDATE usage SET count = count + 1` works until it is on the
  hot path of every request. Moving the increment to ETS is the whole point.

## Upgrading

**0.4.0 requires schema version 6.** Coming from 0.3.x, add a migration for
versions 3 through 6 (credit ledger, promotional snapshots, open-hold index,
and idempotent flush receipts):

```bash
mix aurora_meter.gen.migration -r MyApp.Repo --from 3
mix ecto.migrate
```

An 0.1 install also needs the history table from 0.2: use `--from 2`. An
unreleased checkout already on schema 5 needs `--from 6`. Apply migrations
before starting the updated application.

Custom storage adapters must implement `flush_batch/3`: commit the batch ID,
counter deltas and history deltas atomically, and return current totals on
repeat delivery without applying the deltas again. Keep flush receipts while
any node could retry them; this release does not automatically prune receipts.
See [ADR 0007](docs/adr/0007-idempotent-flush-batches.md).

For features that should be measured without billing, use `counter(:f)` instead
of `metered(:f, included: 0, unit_price: 0)`; see
[ADR 0006](docs/adr/0006-counter-feature-kind.md).

See the [changelog](CHANGELOG.md) for everything else that changed.

## Documentation

**Worked examples.** A whole product each, from nothing:

- [Concepts](docs/examples/concepts.md): every term defined, and the table of
  the five feature kinds. Start here.
- [A team SaaS](docs/examples/team-saas.md): switches, seats and hard caps
- [Allowance and overage](docs/examples/allowance-and-overage.md): a monthly
  allowance customers may exceed, billed through Stripe
- [Prepaid credits](docs/examples/prepaid-credits.md): pay-as-you-go on a
  credit ledger, with holds for work of unknown cost
- [Showing usage](docs/examples/showing-usage.md): dashboards, live updates,
  charts and the metrics worth alerting on

Every code block in those is executed by `test/aurora_meter/examples_test.exs`,
so a guide that stops being true stops the suite.

**Before you depend on it.** Four pages, in the order they answer the
questions a reader actually has:

- [The mental model](docs/mental-model.md): the five things this library does,
  what each costs, what happens when the machine dies, and five things a reader
  would reasonably assume that are not true.
- [Guarantees](docs/guarantees.md): the contract, one row per guarantee, each
  with the conditions that make it hold, what voids it, and the named test that
  proves it.
- [Correctness](docs/correctness.md): the same ground per invariant, with the
  prerequisites, the known limits and a link to the evidence.
- [Architecture](docs/architecture.md): which process writes which table, where
  the seams are, and which direction the core and Pro dependency runs.

[Troubleshooting](docs/troubleshooting.md) is symptom first, for when something
is already wrong. [SECURITY.md](SECURITY.md) says what is stored, what is sent
(nothing) and how to report a vulnerability.

**Reference.** What is supported, and for how long:

- [API inventory](docs/api.md): every supported function, behaviour, struct,
  configuration key, telemetry event, PubSub message and Mix task, each with a
  stability class. If it is not on that page, it is not supported, even where
  the code happens to be public.
- [Support policy](docs/support-policy.md): what SemVer covers here, how
  schema changes work in 1.x, how long a deprecated API lives, and which
  Elixir and Erlang/OTP pairs are tested.

Guides: [Getting started](docs/getting-started.md) ·
[Configuration](docs/configuration.md) · [Metering](docs/metering.md) ·
[Entitlements](docs/entitlements.md) · [Plans](docs/plans.md) ·
[Credits](docs/credits.md) · [Telemetry](docs/telemetry.md) ·
[Testing](docs/testing.md)

API reference on [HexDocs](https://hexdocs.pm/aurora_meter).

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the
test-database setup, what `mix check` runs, the invariant-id naming convention,
and the rule that a change touching money or quotas needs a test against
independent database connections.

## License

MIT, see [LICENSE](LICENSE). The `aurora_meter_pro` package is licensed
separately under a commercial licence.
