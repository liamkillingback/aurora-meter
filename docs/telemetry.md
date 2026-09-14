# Telemetry

Aurora Meter emits `:telemetry` events you can attach to for metrics and logs.

| Event | Measurements | Metadata |
|---|---|---|
| `[:aurora_meter, :track]` | `%{count}` | `%{tenant_key, feature, declared}` |
| `[:aurora_meter, :reserve]` | `%{qty}` | `%{tenant_key, feature, result, declared}`. `result` is `:ok`, `:limit_exceeded` or `:not_entitled` |
| `[:aurora_meter, :flush]` | `%{count, delta_sum}` | `%{}` |
| `[:aurora_meter, :flush, :error]` | `%{count}` | `%{error}` — the database write failed; the deltas stay pending |
| `[:aurora_meter, :broadcast]` | `%{count, deltas}` | `%{}` |
| `[:aurora_meter, :cluster, :apply]` | `%{count}` | `%{kind, origin}` — deltas or totals applied from another node |
| `[:aurora_meter, :credits, kind]` | `%{amount, balance_after, available_after}` | `%{tenant_key, reference, category, duplicate, overrun}` — one per committed ledger entry; `kind` is `:grant`, `:hold`, `:settle`, `:release`, `:debit` or `:expire`. `duplicate: true` marks an idempotent grant replay (amount `0`), `overrun: true` a settlement above its hold |
| `[:aurora_meter, :credits, :low_balance]` | `%{available, threshold}` | `%{tenant_key}` — the available balance crossed below the threshold (once per crossing) |

`declared` is `false` when no plan declares the feature. It is metadata on
`track` and `reserve` from 0.5.0, and it is a report rather than a refusal:
`track/4` counts an undeclared feature under every `:undeclared_feature_policy`.

The full list, with a stability class and a `Since` version for every event,
is in the [API inventory](api.md). Aurora Meter Pro emits four events of its
own; they are catalogued in Pro's own inventory, because the core never
depends on Pro.

Count tracked usage with `Telemetry.Metrics`:

```elixir
def metrics do
  [
    Telemetry.Metrics.sum("aurora_meter.track.count", tags: [:feature]),
    Telemetry.Metrics.summary("aurora_meter.flush.count"),
    Telemetry.Metrics.sum("aurora_meter.credits.settle.amount", tags: [:tenant_key]),
    Telemetry.Metrics.counter("aurora_meter.credits.low_balance.available")
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
