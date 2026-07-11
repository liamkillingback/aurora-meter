# Changelog

All notable changes to Aurora Meter are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
