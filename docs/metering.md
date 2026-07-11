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

## Durability

By default metering is **buffered**: counters live in ETS and are flushed to
Postgres every `:flush_interval` ms, so a hard crash can lose at most one interval
of increments — fine for dashboards and soft quotas. For billing-grade exactness,
mark a feature **durable** and `track/4` also writes a raw event row synchronously:

```elixir
config :aurora_meter, durable_features: [:ai_generations]
# or per call:
AuroraMeter.track(tenant, :ai_generations, 1, durable: true, metadata: %{req: id})
```
