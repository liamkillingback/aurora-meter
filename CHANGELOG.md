# Changelog

All notable changes to Aurora Meter are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.2] - 2026-09-08

Documentation and package metadata only; no code or schema changes.

### Changed

- Aurora Meter now has its own home at https://aurorameter.com. The package
  links, README, NOTICE and description point there for the product, pricing
  and Pro, and keep the PhxTemplates links for the templates built on the core.

## [0.3.1] - 2026-09-08

Documentation only; no code or schema changes.

### Changed

- Explained what the tenant argument (`org` in every example) is and what a
  good key looks like: in the README ("What `org` is"), the `AuroraMeter`
  and `AuroraMeter.Tenant` module docs, the metering and entitlements guides,
  the getting-started guide and the installer's quickstart output.

## [0.3.0] - 2026-09-07

**No migration required** (schema version stays 2).

### Added

- **Cluster-wide counters.** Every node still meters into its own ETS table,
  but the flusher now writes *deltas* (`value = value + Δ`) and re-bases on the
  total Postgres returns, so nodes add up instead of overwriting each other.
  Nodes exchange deltas over PubSub every `:broadcast_interval` and announce
  flushed totals every `:flush_interval`; a value read on any node is the true
  total minus at most the other nodes' last tick of increments. See
  [docs/clustering.md](docs/clustering.md) and ADR 0004.
- `AuroraMeter.Cluster` — the supervised process behind it; config
  `cluster_sync: true` (default).
- `AuroraMeter.Storage.add_counters/1` and `add_history/1` (new required
  callbacks on the behaviour) alongside the absolute `upsert_*`.
- `AuroraMeter.Test` — `reset!/0`, `flush!/0`, `broadcast!/0`,
  `unique_tenant/1`, `checkout/1`, `simulate_node/3`, `simulate_flush/2` and a
  `use AuroraMeter.Test` macro, replacing the boilerplate the testing guide
  used to ask hosts to copy.
- **One-step installer.** With `igniter` in your deps, `mix igniter.install
  aurora_meter` (or `mix aurora_meter.install`) writes the config, adds
  `AuroraMeter` to your supervision tree after the repo and PubSub, creates a
  starter plans module and generates the migration. Without Igniter the task
  keeps printing the steps.
- Telemetry: `[:aurora_meter, :cluster, :apply]` and
  `[:aurora_meter, :flush, :error]`; `[:aurora_meter, :flush]` gains
  `delta_sum`, `[:aurora_meter, :broadcast]` gains `deltas`.

### Changed

- ETS counter rows are now `{key, value, pending_flush, pending_gossip}`
  (anyone reading `:aurora_meter_counters` directly needs the new shape).
- With `cluster_sync` on, tenant usage broadcasts are node-local: each node
  informs its own LiveViews from its own converged view.
- A failed flush no longer crashes the flusher: taken deltas are restored and
  re-marked dirty, the error is logged and reported via telemetry.
- `AuroraMeter.check/2` is documented as advisory (a read then a compare); use
  `reserve/3` or `with_quota/4` to enforce a hard limit atomically.

## [0.2.0] - 2026-09-07

Schema version 2. Existing installs add one migration:

```elixir
def up, do: AuroraMeter.Migration.up(from: 2)
def down, do: AuroraMeter.Migration.down(to: 2)
```

(`mix aurora_meter.gen.migration -r MyApp.Repo --from 2` generates it.)

### Added

- **Usage history** — UTC day buckets are maintained next to the period counter
  (same ETS hot path, flushed to the new `aurora_meter_history` table) and read
  back with `AuroraMeter.history/3`, giving charts without durable events.
  Off with `config :aurora_meter, history: false`.
- **`AuroraMeter.quota/2`** — one dashboard-ready map per feature: kind, used,
  limit / included, remaining, overage, percent and the current period.
- **`AuroraMeter.period/1`** — the tenant's current billing window.
- **Subscription cache** — `AuroraMeter.Subscriptions` memoises the plan lookup
  in ETS (`:subscription_cache_ttl`, default 5 s) and evicts on every
  `Storage.put_subscription/1`, locally and across nodes via PubSub. `check/2`,
  `reserve/3` and `with_quota/4` no longer touch the database per call.
- **Versioned migrations** — `AuroraMeter.Migration.up/1` and `down/1` take
  `:version`, `:from` and `:to`; every version is idempotent.
- **Telemetry** — `[:aurora_meter, :reserve]` with `%{qty}` and the outcome
  (`:ok`, `:limit_exceeded`, `:not_entitled`) in metadata.
- `AuroraMeter.Schema.Subscription.entitled_statuses/0` and `entitled?/1`.

### Fixed

- The flusher now traps exits, so the final flush actually runs on shutdown; a
  deploy no longer drops up to one flush interval of usage.
- Live updates could be lost when a flush landed between a `track` and the next
  broadcast tick; the broadcaster now keeps its own touched set.
- A subscription in a non-entitled status (`canceled`, `unpaid`, `incomplete`,
  ...) kept granting its plan; it now falls back to the default plan.
- `mix aurora_meter.gen.migration` failed in a host app because the repo was
  never loaded; it now calls `Mix.Ecto.ensure_repo/2` first.
- `usage_meter/1` shows the included allowance and overage for metered features
  and the enabled state for boolean features instead of a bare count.

## [0.1.0] - 2026-07-11

Initial release of the free core.

### Added

- **Metering** — `AuroraMeter.track/4`, `usage/2`, `usage_all/1`. ETS-backed
  atomic counters (`:ets.update_counter`), never touching the database on the hot
  path; ~8M increments/sec aggregate. Interval `Flusher` persists absolute-value
  snapshots (idempotent); interval `Broadcaster` fans live values over PubSub.
  Per-feature `:durable` mode also writes a raw event row.
- **Entitlements** — `check/2`, `allowed?/2`, `entitled?/2`, `remaining/2`,
  `reserve/2,3`, and `with_quota/3,4` (atomic reserve + release-on-raise; correct
  hard-limit enforcement under concurrency). Hard limits block; metered features
  allow overage; undeclared features are permissive.
- **Plans** — a compile-time DSL (`use AuroraMeter.Plans`) with `plan`, `price`,
  `limit`, `metered`, and `feature`, validated at compile time.
- **Subscriptions** — local `subscribe/2` and `plan/1`, with a configurable
  default plan.
- **Billing seam** — `AuroraMeter.Billing.Provider` behaviour + `Noop` default +
  a `Billing` facade, so the core works standalone and Pro plugs in.
- **LiveView** — `usage_meter/1` and `usage_summary/1` components (behind the
  optional LiveView deps) and `AuroraMeter.LiveView.subscribe/1`.
- **Storage** — `AuroraMeter.Storage` behaviour + Ecto/Postgres adapter;
  `AuroraMeter.Migration` and `mix aurora_meter.gen.migration` / `install`.
- **Config** — `NimbleOptions`-validated configuration (fail fast at boot).
- **Telemetry** — `[:aurora_meter, :track | :flush | :broadcast]`.
- **Bench** — `mix aurora_meter.bench`.
