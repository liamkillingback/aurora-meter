# Alerts

**These are worked deployment examples, not service level objectives, not
defaults, and not thresholds this project can set for your load.** Every number
below is derived from a configuration value you control, and the derivation is
shown so you can recompute it for your own settings. Nothing here is enforced by
the library, and nothing here is a promise about behaviour: the promises are in
[Guarantees](guarantees.md).

Two things to read first. [Telemetry](telemetry.md) is the event catalogue every
signal below comes from, and section 10 of [Operations](operations.md) is the
shorter list of what an operator watches day to day. This page is the version
with the arithmetic in it.

The defaults the derivations assume, all from
[Configuration](configuration.md):

| Key | Default | What it means here |
|---|---|---|
| `flush_interval` | 5,000 ms | how often a healthy node empties its dirty set |
| `broadcast_interval` | 1,000 ms | how often touched counters are gossiped |
| `metrics_interval` | 10,000 ms | how often the gauges are sampled, so the resolution of every gauge-derived number |

Change one of those and the threshold beside it changes with it. That is the
point of showing the derivation rather than a number.

## 1. Flush backlog age

**Signal.** `aurora_meter.store.gauge.oldest_pending_age_ms` above
`2 x flush_interval`, sustained for three sampling intervals.

**Derivation.** A healthy node empties its dirty set every `flush_interval`, so
twice that is the smallest bound a single slow flush cannot cross. The gauge is
sampled every `metrics_interval`, so a threshold that has to be true for three
consecutive samples cannot fire on one unlucky reading. With the defaults:
above 10,000 ms for 30 seconds.

**Severity.** Warning.

**Runbook.** [Operations, section 4](operations.md#4-when-the-database-is-unavailable).

**What it means.** Counts are sitting in memory rather than in the database.
They are not lost yet, and they are not durable either: see
[Metering](metering.md).

## 2. Persistent flush errors

**Signal.** `[:aurora_meter, :flush, :error]` in each of three consecutive
`flush_interval` windows, or `aurora_meter.store.gauge.pending_batch_age_ms`
above 60,000 ms.

**Derivation.** One failure during a database restart is normal, and the same
batch is retried under the same receipt, so a single error is not an incident.
The same batch still retained a minute later means the retry is not converging.
Sixty seconds is twelve `flush_interval`s with the defaults: pick a multiple of
your own interval rather than the literal minute.

**Severity.** Page.

**Runbook.** [Operations, section 4](operations.md#4-when-the-database-is-unavailable).

## 3. Aged holds

**Signal.** A rising count of pending holds older than 24 hours. The dashboard
page reports it directly; from telemetry, count
`[:aurora_meter, :credits, :hold_reconciliation]` with an `age_seconds` above
86,400.

**Derivation.** A hold is money reserved against work that should have settled.
Twenty four hours is the age at which the reconciler's default policy still says
`:keep`, so a non-zero count means nobody has decided what the work was.

**The correct threshold is your longest legitimate unit of work.** A host whose
jobs run for days must raise it, or this alert will fire every day and stop
being read. That is not a caveat on the example: it is the reason the example
cannot be a default.

**Severity.** Warning.

**Runbook.** [Operations, section 3](operations.md#3-recovering-stale-holds).

## 4. Cluster divergence

**Signal.** `aurora_meter.cluster.lag.since_last_message_ms` above
`10 x broadcast_interval` while `peers` is above zero.

**Derivation.** Gossip converges in one `broadcast_interval` and heals through
totals in one `flush_interval`. Ten intervals with no message from any peer, on
a node that has peers, means PubSub is not delivering rather than that the
cluster is quiet. With the defaults: 10,000 ms.

`peers > 0` is part of the signal, not decoration. A single-node deployment has
nobody to hear from and would otherwise alert for ever.

**Severity.** Warning.

**Runbook.** [Clustering](clustering.md#guarantees).

## 5. Event rejections

**Signal.** Any non-zero rate of `[:aurora_meter, :record, :stop]` with
`result: :conflict`.

**Derivation.** A conflict means two different payloads claimed one event id.
That is always a caller defect and it never heals itself, so the threshold is
zero and there is nothing to tune.

**Severity.** Warning.

**Runbook.** [Operations, section 9](operations.md#9-a-health-check-worth-having).

## Do not alert on this

Four signals that look like incidents and are not.

- **Buffered usage lost with a node.** Counts held in ETS and not yet in an
  acknowledged flush batch go with the VM. That is a documented property of the
  buffered path, stated in [Guarantees](guarantees.md), and the reason the
  dashboard page labels the buffer a loss window rather than pending work. Alert
  on the backlog age above, which is the thing you can act on.
- **A single flush error.** The batch is retained and retried under the same
  receipt. Alert on three in a row, which is rule 2.
- **Throughput on one hot key.** Increments to one counter row serialise in ETS
  by design. A key that is slower than the others is the design working, not a
  fault.
- **`[:aurora_meter, :record, :stop]` with `result: :duplicate`.** An idempotent
  replay of an event id that was already recorded is the feature working. It is
  worth charting and it is not worth waking anybody.

## Where next

* [Telemetry](telemetry.md): every event, its measurements, its metadata and the
  tag rules.
* [Operations](operations.md): the runbooks each rule above links to.
* `AuroraMeter.LiveDashboard.Page`: the same figures on a page, with the runbook
  link beside each one.
