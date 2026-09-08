# Telemetry

Aurora Meter emits `:telemetry` events you can attach to for metrics and logs.

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurora_meter, :track]` | `%{count}` | `%{tenant_key, feature}` |
| `[:aurora_meter, :reserve]` | `%{qty}` | `%{tenant_key, feature, result}` — `result` is `:ok`, `:limit_exceeded` or `:not_entitled` |
| `[:aurora_meter, :flush]` | `%{count, delta_sum}` | `%{}` |
| `[:aurora_meter, :flush, :error]` | `%{count}` | `%{error}` — the database write failed; the deltas stay pending |
| `[:aurora_meter, :broadcast]` | `%{count, deltas}` | `%{}` |
| `[:aurora_meter, :cluster, :apply]` | `%{count}` | `%{kind, origin}` — deltas or totals applied from another node |

Example — count tracked usage with `Telemetry.Metrics`:

```elixir
def metrics do
  [
    Telemetry.Metrics.sum("aurora_meter.track.count", tags: [:feature]),
    Telemetry.Metrics.summary("aurora_meter.flush.count")
  ]
end
```

Attach a handler directly:

```elixir
:telemetry.attach(
  "log-aurora-flush",
  [:aurora_meter, :flush],
  fn _event, %{count: n}, _meta, _cfg -> Logger.info("flushed #{n} counters") end,
  nil
)
```
