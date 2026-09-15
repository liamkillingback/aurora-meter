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
| `[:aurora_meter, :credits, :hold_reconciliation]` | `%{amount, age_seconds, duration}` | `%{tenant_key, reference, decision, outcome}` — one per hold examined by `AuroraMeter.Credits.reconcile_holds/1` |
| `[:aurora_meter, :record, :start]`, `[..., :stop]`, `[..., :exception]` | `%{duration, count}` on `:stop` | `%{result, kind, feature, batch_size, tenant_key, durability, projection}`: one span per `AuroraMeter.record/4`, `record_batch/2`, `correct/4` or `replace/4`, covering validation, admission, the transaction and the post-commit effects |
| `[:aurora_meter, :replay, :batch]` | `%{scanned, keys, duration}` | `%{generation, cursor, phase}` — one per committed batch of `AuroraMeter.Events.Replay.run/1`; `phase` is `:scan` and `cursor` is the `seq` an interrupted run resumes from |
| `[:aurora_meter, :replay, :phase]` | `%{duration}` | `%{generation, phase}` plus `seeded` and `resumed` on `:announce`, `drained` on `:drain`, `differences` on `:compare` and `:activate` |
| `[:aurora_meter, :operations, :batch]` | `%{items, duration_ms}` | `%{name, result}` - one per committed batch of any operation that runs through `AuroraMeter.Operations.run_batches/3`; `name` is the operation name (`"credit_expiry:global"`) and `result` says how the batch ended |
| `[:aurora_meter, :retention, :prune]` | `%{deleted, duration}` | `%{table, blocked}` - one per table `AuroraMeter.Retention.prune/1` examined; `blocked: true` means it was refused, and the reason is in the return value rather than in the event |

`record` is a span rather than a flat event so that an OpenTelemetry bridge can
open it before the database work starts and Ecto's own spans nest inside it.
Attach to `[:aurora_meter, :record, :stop]` for metrics: `result` is `:inserted`,
`:duplicate` or the error tag, and `projection` says whether the in-memory view
was updated (`:ok`), skipped because the counter was cold (`:cold`) or failed
(`:projection_failed`). A failed projection never turns a committed event into
an error; the durable total stays authoritative.

`kind` is `:usage` or `:correction`, so corrections need no event of their own
and every preset built on `[:aurora_meter, :record]` covers them. Split on it to
see how much of the recorded quantity is credit: `count` is the magnitude, and
for a `:correction` it is what was taken away. A `replace/4` is one span with
`kind: :correction` and `batch_size: 2`, whose `count` is the reversal plus the
replacement.

A replay emits nothing else. It writes projection totals and its own
checkpoint rows and touches no other seam, so `[:aurora_meter, :flush]`,
`[:aurora_meter, :record, :stop]` and the credits events stay silent for the
whole of a rebuild. That silence is asserted, not assumed: see
`AuroraMeter.EventsReplayTest`.

## Hold reconciliation

`[:aurora_meter, :credits, :hold_reconciliation]` fires once for every hold
`AuroraMeter.Credits.reconcile_holds/1` examines, whether or not anything was
written.

`amount` is the micro-USD the hold has reserved, `age_seconds` how long it has
been open (measured once per run, never negative), and `duration` how long the
host's `decide/1` callback took, in **milliseconds**, and `0` when no callback
ran.

`decision` is what the callback said: `:keep`, `:release`, `{:settle, amount}`,
or `:none` for the two events `AuroraMeter.Credits.with_credits/4` emits when it
discovers somebody else closed its hold. `outcome` is what became of it:

| `outcome` | Meaning | Anything written? |
|---|---|---|
| `:no_reconciler` | No `:credits_hold_reconciler` is configured | No |
| `:kept` | The callback said `:keep` | No |
| `:callback_exit` | The callback raised, exited or threw | No |
| `:callback_timeout` | The callback did not answer within `:credits_hold_reconciler_timeout` and was killed | No |
| `:callback_invalid` | The callback returned something that is not a decision | No |
| `:released` | The reservation was handed back | One `:release` entry |
| `:settled` | The hold was charged the callback's amount | One `:settle` entry |
| `:already_closed` | The hold's own worker, or another node's sweep, closed it first | No |
| `:failed` | Applying the decision failed; the run continued | No |
| `:settled_by_other` | `with_credits/4` found its hold already settled | No |
| `:released_by_other` | `with_credits/4` found its hold released, and recorded the executed cost as a `settle_missed:` debit | One `:debit` entry |

Two of these are worth an alert. A steady `:callback_timeout` or
`:callback_exit` means the host's policy is not running, so holds accumulate
silently. And `amount` beside a `{:settle, n}` decision is the reserved figure,
so a policy that settles for the wrong amount shows as a drift between the two
numbers rather than as nothing at all.

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
