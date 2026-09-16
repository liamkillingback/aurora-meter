# Telemetry

Aurora Meter emits `:telemetry` events and does nothing else with them. It
starts no exporter, opens no socket and sends nothing anywhere: attaching a
handler, running a reporter and deciding what leaves your network are all yours.
`AuroraMeter.NoOutboundIoTest` asserts that rather than promising it, by reading
`lib/` for outbound call sites and failing on any it does not know about.

`AuroraMeter.Telemetry.events/0` is this page in machine-readable form. Every
table below is checked against it on each `mix test`, in both directions: an
event emitted and not listed here fails the suite, and so does one listed here
and not emitted. The check reads the parsed form of `lib/` rather than grepping
it, so an event emitted through a module attribute is found like any other
(`open-findings.md` X222), and `docs/telemetry.md` is checked as well as
`docs/api.md`, because for five releases only the latter was (X232).

## The rules for a metric tag

A tag is a dimension, and a dimension multiplies. One metric tagged on
`tenant_key` is one time series per tenant; one tagged on any `_id` is one per
object. Both are unbounded, and the cost lands on your monitoring bill and your
reporter's memory rather than on Aurora Meter, which is exactly why this library
must not teach it by example.

`AuroraMeter.Telemetry.tag_allow_list/0` is closed. Every tag the shipped
presets use is one of these, and behind each is a value set bounded by something
you can name in the source:

| Tag | Bounded by |
|---|---|
| `result` | the documented outcome set of the operation that emits it |
| `kind` | `AuroraMeter.Schema.CreditTransaction.kinds/0`, the retention allow list, the cluster batch kinds, the span exception kinds |
| `state` | the state machine that owns the event |
| `exporter` | the exporter modules you configure |
| `worker` | the `AuroraMeter.Oban.*` module list |
| `feature` | your own compiled plan definitions, which is why it is opt-in |

`feature` is off by default and arrives with `metrics_feature_label: true` or
`AuroraMeter.Telemetry.Metrics.metrics(feature_label: true)`. It is bounded by
your plans rather than by your customers, so it is usually safe and it is still
your call.

`AuroraMeter.Telemetry.forbidden_tags/0` is the other half, written out by name
rather than derived as "everything else", because a denial list that cannot say
why is a list nobody maintains. It holds `tenant_key`, `reference`, `origin`,
`node`, `error`, `reason`, `stacktrace`, `cursor`, `generation`, `period_start`,
`table`, `decision`, `outcome` and the rest.
`AuroraMeter.Telemetry.forbidden_tag_suffixes/0` closes the family: `_key`,
`_id`, `_secret`, `_token` and `_ref` are refused whatever they are called.

Where an event's metadata name is bounded but is not an allow-listed name, the
shipped preset **maps** it rather than tagging on it raw: `outcome` and
`decision` become `result` and `kind`, `phase` and `table` become `kind`. The
name of a dimension is a contract with a reporter, and keeping that contract
closed is what lets a dashboard built against one Aurora Meter deployment read
the same against another.

There is a real limit here and it is worth stating plainly rather than implying
it away. Aurora Meter polices its own presets. It can do nothing about a handler
you attach, and it does not try. `AuroraMeter.Telemetry.redact/2` exists so you
do not have to invent the rule yourself: it drops `tenant_key` by default,
digests it on request, removes every identifier, and turns `error` into
`error_class` so an exception message never travels into a log line.

```elixir
:telemetry.attach(
  "aurora-meter-record-errors",
  [:aurora_meter, :record, :exception],
  fn _event, _measurements, metadata, _config ->
    Logger.error("aurora_meter: #{inspect(AuroraMeter.Telemetry.redact(metadata))}")
  end,
  nil
)
```

`redact(metadata, tenant: :digest)` swaps the tenant key for a stable short
digest instead of dropping it, which is enough to correlate two log lines
without carrying the identifier. `tenant: :raw` keeps it, for a single-tenant
deployment where the value is a constant.

## The events

`Form` is how the event is emitted. An `execute` entry is one name. A `span`
entry emits `:start`, `:stop` and `:exception` under the name shown. A `family`
entry computes its last segment at the emit site, so the kind is in the name and
a preset needs no tag for it.

`Tags` is the subset of `Metadata` that is safe to tag a metric on. Everything
else in `Metadata` is correlation: useful on a log line or a span attribute,
ruinous on a counter.

<!-- telemetry:events -->

| Event | Form | Measurements | Metadata | Tags | Since |
|---|---|---|---|---|---|
| `[:aurora_meter, :track]` | execute | `count` | `declared`, `feature`, `tenant_key` | none | 0.1.0 |
| `[:aurora_meter, :reserve]` | execute | `qty` | `declared`, `feature`, `result`, `tenant_key` | `result` | 0.2.0 |
| `[:aurora_meter, :flush]` | execute | `count`, `delta_sum` | none | none | 0.1.0 |
| `[:aurora_meter, :flush, :error]` | execute | `count` | `error` | none | 0.3.0 |
| `[:aurora_meter, :flush]` | span | `count`, `delta_sum`, `duration`, `monotonic_time`, `system_time` | `batch_id`, `counter_rows`, `history_rows`, `kind`, `reason`, `result`, `stacktrace` | `kind`, `result` | 1.0.0 |
| `[:aurora_meter, :broadcast]` | execute | `count`, `deltas` | none | none | 0.1.0 |
| `[:aurora_meter, :cluster, :apply]` | execute | `count` | `kind`, `origin` | `kind` | 0.3.0 |
| `[:aurora_meter, :cluster, :lag]` | execute | `peers`, `since_last_message_ms`, `unreconciled_keys` | `node` | none | 1.0.0 |
| `[:aurora_meter, :store, :gauge]` | execute | `counter_keys`, `dirty_keys`, `oldest_pending_age_ms`, `pending_batch_age_ms`, `pending_batch_items` | `node` | none | 1.0.0 |
| `[:aurora_meter, :credits, kind]` | family | `amount`, `available_after`, `balance_after`, `spendable_after` | `category`, `deferred`, `duplicate`, `overrun`, `reference`, `tenant_key` | none | 0.4.0 |
| `[:aurora_meter, :credits, :low_balance]` | execute | `available`, `spendable`, `threshold` | `crossing_id`, `handler`, `tenant_key` | none | 0.4.0 |
| `[:aurora_meter, :credits, :hold_reconciliation]` | execute | `age_seconds`, `amount`, `duration` | `decision`, `outcome`, `reference`, `tenant_key` | none | 0.6.0 |
| `[:aurora_meter, :credits, :conservation_error]` | execute | `balance_delta`, `expired_delta`, `held_delta`, `promotional_delta` | `operation`, `reference`, `tenant_key` | none | 0.6.0 |
| `[:aurora_meter, :credits, :lot_migration]` | execute | `blocked`, `deferred`, `duration_ms`, `migrated`, `rows`, `wallets` | `shadow`, `state` | `state` | 0.6.0 |
| `[:aurora_meter, :credits, :recurrence]` | execute | `amount`, `rollover_amount` | `name`, `period_start`, `plan_id`, `plan_version`, `reason`, `result`, `tenant_key` | `result` | 0.6.0 |
| `[:aurora_meter, :plans, :transition]` | execute | `count` | `from_plan_id`, `from_version`, `ref`, `result`, `tenant_key`, `to_plan_id`, `to_version` | `result` | 1.0.0 |
| `[:aurora_meter, :events, :backfill, :batch]` | execute | `batches`, `scanned`, `updated` | `cursor` | none | 1.0.0 |
| `[:aurora_meter, :record]` | span | `count`, `duration`, `monotonic_time`, `system_time` | `batch_size`, `durability`, `feature`, `kind`, `projection`, `result`, `tenant_key` | `kind`, `result` | 1.0.0 |
| `[:aurora_meter, :replay, :batch]` | execute | `duration`, `keys`, `scanned` | `cursor`, `generation`, `phase` | none | 1.0.0 |
| `[:aurora_meter, :replay, :phase]` | execute | `duration` | `differences`, `drained`, `generation`, `phase`, `resumed`, `seeded` | none | 1.0.0 |
| `[:aurora_meter, :operations, :batch]` | execute | `duration_ms`, `items` | `name`, `result` | `result` | 1.0.0 |
| `[:aurora_meter, :retention, :prune]` | execute | `deleted`, `duration` | `blocked`, `table` | none | 1.0.0 |

<!-- /telemetry:events -->

`[:aurora_meter, :flush]` appears twice on purpose. The flat event has been the
flush signal since 0.1.0 and every handler already attached to it keeps working
byte for byte; the span is new in 1.0.0 and wraps the same storage write, so a
tracing bridge can open it before the database work starts and Ecto's own spans
nest inside. Neither is derived from the other, and removing the flat one would
silently detach every existing handler, which is a worse outcome than two events
that overlap.

`record` is a span for the same reason. Attach to `[:aurora_meter, :record,
:stop]` for metrics: `result` is `:inserted`, `:duplicate`, `:conflict`,
`:invalid`, `:unavailable` or `:unsupported`, and `projection` says whether the
in-memory view was updated (`:ok`), skipped because the counter was cold
(`:cold`) or failed (`:projection_failed`). A failed projection never turns a
committed event into an error; the durable total stays authoritative.

`kind` is `:usage` or `:correction`, so corrections need no event of their own
and every preset built on `[:aurora_meter, :record]` covers them. Split on it to
see how much of the recorded quantity is credit: `count` is the magnitude, and
for a `:correction` it is what was taken away. A `replace/4` is one span with
`kind: :correction` and `batch_size: 2`, whose `count` is the reversal plus the
replacement.

A replay emits nothing else. It writes projection totals and its own checkpoint
rows and touches no other seam, so `[:aurora_meter, :flush]`,
`[:aurora_meter, :record, :stop]` and the credits events stay silent for the
whole of a rebuild. That silence is asserted, not assumed: see
`AuroraMeter.EventsReplayTest`.

`declared` is `false` when no plan declares the feature. It is metadata on
`track` and `reserve` from 0.5.0, and it is a report rather than a refusal:
`track/4` counts an undeclared feature under every `:undeclared_feature_policy`.

Aurora Meter Pro emits events of its own. They are catalogued in Pro's own
inventory, because the core never depends on Pro and does not know it exists.

## The gauges

Three things have no natural event, because nothing happens when they change:
how much is buffered, how old the oldest buffered thing is, and how far behind
the cluster is. They are sampled on a timer inside processes that already exist,
every `:metrics_interval` milliseconds (default `10_000`).

`[:aurora_meter, :store, :gauge]`, from `AuroraMeter.Store`:

| Measurement | Exactly what it counts |
|---|---|
| `counter_keys` | rows in the counter table: every tenant and feature the node has seen this period, flushed or not |
| `dirty_keys` | keys with an unflushed delta right now. This is the buffer depth, and it is the number to alert on |
| `oldest_pending_age_ms` | milliseconds since the dirty set was last observed **empty**. Zero on a tick that finds nothing pending |
| `pending_batch_age_ms` | milliseconds since the flusher took the batch it is still holding, or `0` when it holds none |
| `pending_batch_items` | keys in that retained batch |

`oldest_pending_age_ms` is time since the set was last seen empty rather than
the age of the oldest individual delta. Per-key insertion times would need a
timestamp written on the hot increment path, and the increment path is one
`:ets.update_counter/3` call: adding a write to it to improve a gauge is the
wrong trade. What the measurement reports is the thing an operator actually
wants, which is how long the buffer has been continuously non-empty.

`[:aurora_meter, :cluster, :lag]`, from `AuroraMeter.Cluster`:

| Measurement | Exactly what it counts |
|---|---|
| `peers` | distinct nodes heard from within `10 x :broadcast_interval`. Older entries are pruned out of the process state, not merely out of the report |
| `since_last_message_ms` | milliseconds since the last message from any peer, and `-1` when none has ever arrived |
| `unreconciled_keys` | keys holding a remote delta not yet folded into a total. **Omitted entirely** above `:metrics_scan_ceiling` (default `50_000`) |

`-1` rather than `0` for "never heard a peer" is deliberate. Zero means "heard
one just now", which is the healthiest possible reading, and a single-node
deployment that has never gossiped would report perfect health for ever.

`unreconciled_keys` is omitted rather than zeroed when the table is larger than
the scan ceiling, for the same reason: a measurement that is absent breaks a
chart and gets investigated, and a measurement that is wrongly zero does not.
The scan itself is a bounded `:ets.select_count/2`, so the cost is paid on the
gauge tick and never on the apply path.

### Which clock each age uses, and why

This matters enough to be written down, because getting it wrong is the failure
`open-findings.md` X100 records: a duration measured against a wall clock goes
negative across an NTP step, and a negative duration in a histogram is worse
than no duration at all.

| Measurement | Clock | Why |
|---|---|---|
| `store.gauge.oldest_pending_age_ms` | `AuroraMeter.Clock.monotonic_ms/0` | a span between two instants inside one process. Never crosses a node, never compared with a stored value |
| `store.gauge.pending_batch_age_ms` | `AuroraMeter.Clock.monotonic_ms/0` | the batch carries `taken_at_ms` read with the same clock in the same process, so the subtraction is monotonic at both ends |
| `cluster.lag.since_last_message_ms` | `AuroraMeter.Clock.monotonic_ms/0` | the receive instant is stamped locally when the message lands. Peer clocks never enter the arithmetic, which is what makes it meaningful across a cluster that is not synchronised |
| `flush` and `record` span `duration` | `:telemetry.span/3`, which uses `System.monotonic_time/0` | the library's own convention, and the reason to use `span/3` rather than hand-rolling start and stop |
| `credits.hold_reconciliation.age_seconds` | `AuroraMeter.Clock.now/0` against the row's `inserted_at` | the other end of this subtraction is a stored database timestamp, so it has to be a wall clock. Monotonic time has no meaning outside the process that read it, and none at all in a table |

The rule in one line: monotonic for a span measured inside one process, wall
clock only when one end of the subtraction came out of the database, and never
a mixture.

### Driving the gauges yourself

Set `metrics_interval: 0` to switch the timers off, then call
`AuroraMeter.Telemetry.emit_gauges/0` from `telemetry_poller` or your own
scheduler:

```elixir
config :aurora_meter, metrics_interval: 0
```

```elixir
{:telemetry_poller,
 measurements: [{AuroraMeter.Telemetry, :emit_gauges, []}],
 period: :timer.seconds(10),
 name: :aurora_meter_poller}
```

The test environment ships with `metrics_interval: 0`, so a suite never has a
background timer emitting into an assertion it did not expect.

Two things to know before you attach anything to a gauge. Handlers run **inside
the emitting process**, so a slow handler on `[:aurora_meter, :store, :gauge]`
delays flush batch snapshots: do no I/O in one. And a process that is not
running contributes no sample rather than a zero, because a gauge that reports
zero when nothing is watching looks healthy, which is the one thing it must
never do. Alert on the **age** of the last sample as well as on its value.

## Failure mode, signal, runbook

Every state Aurora Meter can be in that an operator would want to know about,
the signal that shows it, and the page that says what to do. The links are
checked on every `mix test`, so a heading that gets renamed fails the build
rather than rotting quietly.

| State | Signal | Runbook |
|---|---|---|
| Buffered counts are not reaching the database | `[:aurora_meter, :flush, :error]` arriving, `flush.stop.duration` absent | [operations.md section 4](operations.md#4-when-the-database-is-unavailable) |
| The buffer fills faster than it drains | `store.gauge.dirty_keys` climbing and `store.gauge.oldest_pending_age_ms` past the flush interval | [operations.md section 2](operations.md#2-queue-sizing) |
| A batch is retried and never commits | `flush.error.count` steady while `flush.count` stays at zero | [operations.md section 4](operations.md#4-when-the-database-is-unavailable) |
| A retained batch is stuck in the flusher | `store.gauge.pending_batch_age_ms` growing while `store.gauge.pending_batch_items` stays flat | [operations.md section 4](operations.md#4-when-the-database-is-unavailable) |
| The gauges went silent | no `[:aurora_meter, :store, :gauge]` for more than one `:metrics_interval` | [operations.md section 9](operations.md#9-a-health-check-worth-having) |
| The flusher stopped or the Store restarted | `store.gauge.oldest_pending_age_ms` above twice `:flush_interval` with no `flush.stop.duration` arriving, or `store.gauge.counter_keys` back at zero | [operations.md section 4](operations.md#4-when-the-database-is-unavailable) |
| Buffered usage was lost with the node | `store.gauge.dirty_keys` at the moment of loss; afterwards the counter total sits below the durable total | [metering.md](metering.md#durability) |
| A node is not hearing its peers | `cluster.lag.peers` below the deployment size, `cluster.lag.since_last_message_ms` above the broadcast interval | [clustering.md](clustering.md#requirements) |
| Cluster state is not converging | `cluster.lag.unreconciled_keys` not returning to zero | [clustering.md](clustering.md#guarantees) |
| Gossip flows and nothing applies it | `broadcast.count` non-zero while `cluster.apply.count` sits at zero | [clustering.md](clustering.md#configuration) |
| A rolling deploy left one node behind | `cluster.apply.count` at zero on one node only | [clustering.md](clustering.md#rolling-upgrades) |
| Durable writes are being refused | `record.stop.duration` with `result: :unavailable` or `result: :conflict` | [metering.md](metering.md#durability) |
| A durable write raised | `[:aurora_meter, :record, :exception]` | [metering.md](metering.md#durability) |
| A durable event was refused by validation | `record.stop.duration` with `result: :invalid` | [metering.md](metering.md#durability) |
| An event id was replayed with identical content | `record.stop.duration` with `result: :duplicate`. This is success, not an error, and alerting on it is usually wrong | [metering.md](metering.md#durability) |
| Usage is metered for a feature no plan declares | `[:aurora_meter, :track]` with `declared: false` | [entitlements.md](entitlements.md#features-the-plan-does-not-declare) |
| Entitlement checks are refusing | `reserve.qty` with `result: :not_entitled` | [entitlements.md](entitlements.md#subscription-status) |
| Holds are not being closed | `credits.hold_reconciliation.age_seconds` rising, `outcome: :no_reconciler` | [operations.md section 3](operations.md#3-recovering-stale-holds) |
| Settlement above its hold created debt | `credits.settle.amount` above the reserved `amount` on the same event | [credits.md](credits.md#hold-settle-release) |
| The host hold policy is not running | `credits.hold_reconciliation.duration` with `outcome: :callback_timeout` or `:callback_exit`, steady | [operations.md section 3](operations.md#3-recovering-stale-holds) |
| The policy released work that then completed | `credits.hold_reconciliation.duration` with `outcome: :released_by_other`, and a `settle_missed:` debit beside it | [credits.md](credits.md#hold-settle-release) |
| The ledger cannot account for a movement | `[:aurora_meter, :credits, :conservation_error]` at all | [correctness.md](correctness.md#i10-every-ledger-amount-has-exact-provenance-and-conservation) |
| Promotional credit is not expiring | `credits.expire.amount` at zero while granted lots age past their expiry | [credits.md](credits.md#promotional-credit-and-expiry) |
| A recurring allowance did not land | `credits.recurrence.amount` missing for a period | [credits.md](credits.md#recurring-allowances) |
| Customers run dry without warning | `credits.low_balance.available` crossings clustered at zero | [credits.md](credits.md#low-balance) |
| The lot migration refuses to proceed | `credits.lot_migration.blocked` above zero | [upgrading-to-lots.md](upgrading-to-lots.md#what-the-migration-will-not-do) |
| A plan transition was refused | `plans.transition.count` with a `result` other than applied | [plans.md](plans.md#moving-a-tenant-between-plans) |
| A scheduled transition is stuck pending | no `plans.transition.count` past its effective time | [plans.md](plans.md#moving-a-tenant-between-plans) |
| A plan definition changed under a live version | boot raises. There is no event and there deliberately is none: the process refuses to start rather than meter under terms nobody agreed | [plans.md](plans.md#versions) |
| A replay is not progressing | `replay.batch.scanned` flat with a fixed `cursor` | [replay.md](replay.md#watching-one) |
| A replay found differences | `replay.phase.duration` on the compare phase with `differences` above zero | [replay.md](replay.md#if-the-rebuild-turns-out-to-be-wrong) |
| A replay was killed mid-flight | no `replay.phase.duration` after the announce phase | [replay.md](replay.md#what-a-kill-leaves-behind) |
| Scheduled work is not running | `operations.batch.items` at zero for a whole window | [scheduler.md](scheduler.md#without-oban) |
| The same operation runs twice | `operations.batch.items` doubling under one `name` | [scheduler.md](scheduler.md#running-the-same-thing-twice) |
| Retention refused a table | `retention.prune.deleted` at zero with `blocked: true` | [retention.md](retention.md#the-allow-list) |
| A backfill stalled | `events.backfill.batch.scanned` flat with a fixed `cursor` | [operations.md section 6](operations.md#6-replay) |

## Metrics presets

Aurora Meter ships `Telemetry.Metrics` definitions for every event above, with
the tag rules already applied. They are compiled only when `telemetry_metrics`
is installed, which is optional in both packages: without it the module is not
defined, every event is still emitted, and nothing in `lib/` names it.

```elixir
# mix.exs
{:telemetry_metrics, "~> 1.0"}
```

```elixir
defmodule MyApp.Telemetry do
  def metrics do
    AuroraMeter.Telemetry.Metrics.metrics(feature_label: true) ++ my_own_metrics()
  end

  defp my_own_metrics, do: []
end
```

Narrow it with `:include`. The groups are `:metering`, `:quotas`, `:flush`,
`:cluster`, `:events`, `:credits` and `:workers`, and
`AuroraMeter.Telemetry.Metrics.groups/0` is the authoritative list:

```elixir
AuroraMeter.Telemetry.Metrics.metrics(include: [:metering, :flush])
```

Or write your own. Nothing here is privileged, and the names are the ones in the
table above:

```elixir
def metrics do
  [
    Telemetry.Metrics.sum("aurora_meter.track.count", tags: [:feature]),
    Telemetry.Metrics.summary("aurora_meter.flush.count"),
    Telemetry.Metrics.sum("aurora_meter.credits.settle.amount"),
    Telemetry.Metrics.counter("aurora_meter.credits.low_balance.available")
  ]
end
```

Note what is not there. `aurora_meter.credits.settle.amount` carries no tag,
because the only dimension the event offers is `tenant_key`, and tagging on it
would create one time series per customer for ever. The kind of the ledger entry
is already the last segment of the event name, so splitting grants from
settlements needs no tag at all. If you want a per-tenant figure, query the
ledger; that is what it is for.

## Trace context

`[:aurora_meter, :record]` and `[:aurora_meter, :flush]` are `:telemetry.span/3`
spans, which is what an OpenTelemetry bridge needs: `:start` fires before the
database work begins, so Ecto's own spans nest inside rather than beside.

Attach the bridge to the span names and `AuroraMeter.Telemetry.redact/2` to the
metadata, and you get a trace with `result`, `kind` and `durability` on it and
no customer identifiers in your tracing vendor. `batch_id` is correlation
metadata and is deliberately not a tag: it is exactly the shape of thing that is
useful on one span and catastrophic on a counter.

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

`decision` and `outcome` are both metadata rather than tags: `{:settle, amount}`
is unbounded, so the shipped preset collapses it to `:settle` and tags the
result on `kind`, and `outcome` maps onto `result`.

## Alerting, and the OpenTelemetry bridge

Two pages take these events somewhere.

[Alerts](alerts.md) is five worked alert examples, each with the metric name, the
derivation of its threshold from a configuration value you control, a severity
and a runbook link, plus a "do not alert on this" section for the four signals
that look like incidents and are not. They are examples and not service level
objectives: the thresholds depend on your load and your intervals, which is why
the arithmetic is shown rather than a number.

`AuroraMeter.OpenTelemetry` turns the slow half of this catalogue into spans in
**your** SDK. It is compiled only when `opentelemetry_api` is installed, it uses
the API and only the API, and it starts no tracer provider, no exporter and no
connection. `attach/1` is idempotent: calling it five times leaves the handler
set one call leaves.

The hot path gets no span and there is no friendly switch that turns it on:
`[:aurora_meter, :track]`, `[:aurora_meter, :reserve]`,
`[:aurora_meter, :broadcast]`, `[:aurora_meter, :cluster, :apply]` and every
gauge are left alone, because one span per increment would dominate both the hot
path and your trace budget. A caller who wants one anyway passes the event name
in `:events` and owns the cost.

Span attributes go through `redact/2`, so no tenant key, reference, object id or
provider reference reaches a tracer, and an error is carried as `error_class`
rather than as its message.

## Attaching a handler directly

```elixir
:telemetry.attach(
  "log-aurora-flush",
  [:aurora_meter, :flush],
  fn _event, %{count: n}, _meta, _cfg -> Logger.info("flushed #{n} counters") end,
  nil
)
```

## Where next

- [API inventory](api.md): every event with a stability class and a `Since`, plus
  the rest of the public surface.
- [Alerts](alerts.md): five worked alert examples with their derivations.
- [Operations](operations.md): what runs, how often, and what to alert on.
- [Clustering](clustering.md): what the cluster guarantees and what it does not.
- [Correctness](correctness.md): the invariants these signals are evidence for.
