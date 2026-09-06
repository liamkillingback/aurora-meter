# Metering

## Recording usage

```elixir
AuroraMeter.track(tenant, :ai_generations)        # +1
AuroraMeter.track(tenant, :ai_generations, 5)     # +5
```

`track/4` runs on the ETS hot path — no database round-trip. It increments an
in-memory counter keyed by `{tenant, feature, period}` and marks it dirty for the
flusher. Aggregate throughput is millions of increments/second because load
spreads across many counter keys.

## Reading usage

```elixir
AuroraMeter.usage(tenant, :ai_generations)   # current-period integer
AuroraMeter.usage_all(tenant)                # %{feature => value}
```

A cold counter is seeded once from the last flushed database value, so reads are
always correct even after a restart.

## Periods

Usage is bucketed by billing period. The free core uses the calendar month (UTC);
a new period starts a fresh counter automatically (no reset job). With the Pro
package, periods align to the tenant's subscription.

## History

Alongside the period counter, `track/4`, `reserve/3` and `with_quota/4` also
bump a UTC **day bucket** for the same feature (still ETS, still no database on
the hot path). The flusher persists it to `aurora_meter_history`, and

```elixir
AuroraMeter.history(tenant, :ai_generations, days: 30)
# => [%{date: ~D[2026-08-08], value: 0}, ..., %{date: ~D[2026-09-06], value: 12}]
```

returns one point per day, oldest first, with today's live value merged in.
This is what usage charts read. Disable with `config :aurora_meter, history: false`
if you truly never chart usage.

## Durability

By default metering is **buffered**: counters live in ETS and are flushed to
Postgres every `:flush_interval` ms and once more on a clean shutdown, so only a
hard crash can lose increments (at most one interval's worth) — fine for
dashboards and soft quotas. For billing-grade exactness,
mark a feature **durable** and `track/4` also writes a raw event row synchronously:

```elixir
config :aurora_meter, durable_features: [:ai_generations]
# or per call:
AuroraMeter.track(tenant, :ai_generations, 1, durable: true, metadata: %{req: id})
```
