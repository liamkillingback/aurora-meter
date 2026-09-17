# Architecture

Where the state lives, which process may write it, and where the seams are. For
what the library promises about that state, read [Guarantees](guarantees.md);
for how each promise is enforced and what voids it, read
[Correctness](correctness.md). This page is the map, not the contract.

## 1. Three regions of state

Aurora Meter keeps state in three places and they have different rules.

| Region | Holds | Written by | Survives a crash? |
|---|---|---|---|
| ETS, in the VM | counters, day buckets, reservations, the pending flush batch | `AuroraMeter.Counter` (any caller's process) and `AuroraMeter.Store` | no |
| Postgres, through the `Storage` behaviour | `aurora_meter_counters`, `_history`, `_events`, `_event_totals`, `_flush_receipts`, `_subscriptions`, `_plan_versions`, `_plan_transitions` | `AuroraMeter.Flusher` and the facade's durable path | yes |
| Postgres, through the repo directly | `aurora_meter_credit_balances`, `_credit_transactions`, `_credit_lots`, `_credit_allocations`, `_credit_recurrences`, `_checkpoints` | `AuroraMeter.Credits` and `AuroraMeter.Operations` | yes |

The third region is deliberate and is recorded in
[ADR 0005](adr/0005-prepaid-credit-ledger.md): the credit ledger is not routed
through the storage behaviour, because its correctness rests on row locks and
check constraints that a general adapter interface cannot express. The
checkpoint table follows the same rule for a different reason: it is operational
bookkeeping for this library's own tasks, and a third-party adapter would have
no reason to implement six callbacks that exist only to serve them.

A host that supplies its own `AuroraMeter.Storage` adapter therefore gets
counters, history, events and plans, and does **not** get credits. That is
stated once, in [Credits](credits.md).

## 2. The process tree

`AuroraMeter` is a supervisor a host adds to its own tree. Reading
`lib/aurora_meter/supervisor.ex`, in start order:

```
AuroraMeter (Supervisor, :one_for_one)
├── Registry            AuroraMeter.Registry
├── Task.Supervisor     AuroraMeter.TaskSupervisor
│                       so a host callback runs in a process of its own: one
│                       that raises must not take its caller down
├── AuroraMeter.Store   owns every ETS table; nothing on the hot path calls it
├── AuroraMeter.Events.Gate
│                       admission for durable writes, before a connection is
│                       taken, so a refused caller is refused rather than queued
├── AuroraMeter.Cluster subscribes to the PubSub topic, applies remote deltas
├── AuroraMeter.Flusher one timer; the only writer of the flush transaction
├── AuroraMeter.Broadcaster
│                       one timer; announces local deltas and flushed totals
└── AuroraMeter.BootChecks
                        runs the post-start checks and returns :ignore, so
                        nothing is left running
```

Two things follow from that shape and are worth holding on to.

**The hot path has no GenServer in it.** `track/4`, `check/2`, `reserve/3` and
`with_quota/4` call `AuroraMeter.Counter`, which reads and writes the public ETS
tables directly from the caller's own process. `Store` creates and owns those
tables so that they survive a writer dying; it is not a bottleneck, because
nothing asks it for anything.

**When the supervisor gives up, the buffer is gone.** Every unflushed increment
lives in the Store's ETS tables, so the restart intensity is set high on purpose
(ten in sixty seconds) and the reasoning is written out in the source. A host
that cannot tolerate that loss uses `record/4`, which is transactional.

The host owns the repo, the PubSub server and (if present) Oban. Aurora Meter
starts none of them and supervises none of them.

## 3. The seams

Every one of these is a behaviour a host or Pro may implement. The contract of
each is one line here and a page of its own elsewhere.

| Behaviour | Answers | Default | Page |
|---|---|---|---|
| `AuroraMeter.Tenant` | what is the tenant key for this term | `Tenant.Default` (binaries through, `String.Chars` stringified) | [Getting started](getting-started.md) |
| `AuroraMeter.Period` | which half-open UTC window is this tenant in | `Period.Calendar` | [Periods](periods.md) |
| `AuroraMeter.Clock` | four readings of time, and which one a comparison takes | `Clock.System` | [Periods](periods.md) |
| `AuroraMeter.Storage` | where counters, history, events and plans are kept | `Storage.Ecto` | [Storage adapters](storage-adapters.md) |
| `AuroraMeter.Exporter` | how a batch of usage reaches a provider | `Exporter.Journal` (a reference implementation, not a provider) | [Exporters](exporters.md) |
| `AuroraMeter.Events.Outbox` | what happens, inside the record transaction, when a fact is committed | `Events.Outbox.Noop` | [Exporters](exporters.md) |
| `AuroraMeter.Billing.Provider` | who the customer is at the payment provider | `Billing.Noop` | [Plans](plans.md) |
| `AuroraMeter.Credits.HoldReconciler` | is this stale hold's work still running | none configured, so nothing is closed | [Credits](credits.md) |

The clock seam is the one most often got wrong, so it has a rule of its own:
**both sides of a time comparison come from the same clock, and which clock that
is follows from where the other side came from.** Persisted in your database,
`db_now/0`. Generated by a payment provider, `now/0`. Held in memory in this
process, `monotonic_ms/0`. Shown to a human, `now/0`. [Periods](periods.md) has
the measurements behind that rule, including why a monotone wall clock was
considered and does not exist here.

## 4. Transaction boundaries

Three operations open a transaction, and they behave differently inside one of
yours.

**The flush batch.** `Flusher` writes the counter deltas, the day-history deltas
and a flush receipt in one transaction. The receipt's primary key is what makes
a redelivered batch apply once. You never call this inside your own transaction;
it runs on a timer in its own process.

**The event record.** `record/4`, `record_batch/2` and `correct/4` write the
event, its projection delta and the outbox intent in one transaction. **You may
nest this inside your own transaction**, and if you do the adapter proceeds as a
savepoint: the event and the totals delta roll back with your work, and the ETS
hydration and the PubSub message are deferred to
`AuroraMeter.Events.after_commit/1`, which you call. Outside your transaction
both happen automatically after the commit.

**The credit operation.** Every wallet write takes that wallet's balance row
lock and checks sufficiency under it. Inside a host transaction the ledger's
side effects (PubSub, telemetry, the low-balance handler) are deferred rather
than fired on the inner return, because an inner return is a savepoint release
and not a commit. `AuroraMeter.Credits.after_commit/1` is how you run them.
[Credits](credits.md) states this; it is the one seam where nesting changes
observable behaviour rather than only timing.

The rule underneath all three: **a refusal writes nothing and never rolls back
your transaction.** A `{:error, :insufficient_credits}` leaves your work intact.

## 5. What crosses the core and Pro boundary, and in which direction

**Core never references a Pro module.** There is no conditional, no
`Code.ensure_loaded?(AuroraMeter.Pro...)`, and no configuration key in core that
names a Pro module by name. A host can read core's source and satisfy itself of
this.

Pro reaches core state only through core's public API: the facade, the `Storage`
callbacks, `AuroraMeter.Credits` and `Credits.Lots`, `Plans` and `Plan`,
`Subscriptions`, `Period`, `Clock`, `Operations` and `AuroraMeter.Test`. It
implements four core behaviours (`Billing.Provider`, `Exporter`, `Events.Outbox`
and `Period`) and owns its own tables, which core never reads.

The practical consequence, and the reason the boundary is drawn here: **nothing
that is free in this package requires Pro.** Counting, plans, quotas, events,
the credit ledger, the migrations, the telemetry, the components and the
installer are all in the MIT core. Pro adds Stripe settlement and commercial
automation on top. See [Free vs Pro](../README.md#free-vs-pro).

## 6. Which region answers which question

A recurring source of confusion, written once:

- **"How much has this tenant used?"** reads the ETS counter, which is seeded
  from Postgres when cold. It is up to date within the flush interval for
  buffered features, and hydrated at commit for event-source features.
- **"What will this tenant be invoiced for?"** reads whichever source the
  feature declares. A `:buffered` feature bills from the persisted counter; an
  `:events` feature bills from `aurora_meter_event_totals`. One feature has one
  source, and a cutover between them has a watermark.
  ([Correctness](correctness.md) I08.)
- **"What can this tenant spend?"** reads the wallet, which is neither of the
  above. Usage and money are separate systems that a plan connects.

## 7. Further reading

- [Guarantees](guarantees.md), the contract, with what voids each row.
- [Correctness](correctness.md), per invariant, with prerequisites and limits.
- [The mental model](mental-model.md), if this page arrived before that one.
- [Clustering](clustering.md), for what changes with more than one node.
- [Storage adapters](storage-adapters.md), for writing your own.
- [ADR 0005](adr/0005-prepaid-credit-ledger.md), for why the credit ledger is
  not behind the storage behaviour.
