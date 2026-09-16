# 08a: failure mode, signal, runbook

Build unit **08a**, G08 bullet 1: *"every invariant failure and recovery state
has an observable signal and a runbook entry; no package sends data externally
on its own."*

The tables themselves live in the two packages' `docs/telemetry.md`, because a
table an operator has to find in an evidence tree is a table nobody reads. This
file records what is checked about them, and what is not.

## 1. What is checked, mechanically, on every `mix test`

`AuroraMeter.TelemetryContractTest` and `AuroraMeter.Pro.TelemetryContractTest`
parse the failure-mode table out of `docs/telemetry.md` and assert three things.

**Every signal names an event a catalogue has.** Signals are written two ways in
the table, as a full event name (`[:aurora_meter, :flush, :error]`) and in the
dotted metric style an operator reads off a dashboard
(`store.gauge.pending_batch_age_ms`). The check accepts both, resolving the
dotted form by dropping at most two trailing segments, so `a.b.c.d.e` cannot
match `aurora_meter.a` by accident. It ignores backticked text that is not
shaped like a signal, because the cells also carry `result: :invalid` and
`:flush_interval` and a check that accepted those would be asserting that a
colon exists.

**Every runbook link resolves to a heading that exists.** The anchor is
recomputed from the target file's own headings with the slug rule ExDoc and
GitHub share, so a heading renamed in `operations.md` fails this test rather
than leaving a dead link for an operator to find at three in the morning.
Extras links are resolved by basename anywhere under `docs/`, which is what
ExDoc does and what the rest of the documentation already assumes
(`[Scheduler map](scheduler.md)` for `docs/operations/scheduler.md`).

**The table is not a sample.** Core's must carry at least fifteen rows and Pro's
at least twelve. A table that had quietly shrunk to three would otherwise pass
both checks above. What that floor does **not** catch is a table that grows
while losing states, which is exactly what the rebuild after **X326** did on its
first pass: see the note at the end of section 2.

Negative control `c23-runbook-anchor-rots` renames one anchor in a link and the
test fails.

## 2. Core: state, signal, runbook

**36 rows**, in `core:docs/telemetry.md`. Every anchor below is checked
against the target file's own headings on every `mix test`, and every signal
against `AuroraMeter.Telemetry.events/0`.

This table is **not the one this unit first shipped.** The orchestrator's
control run reverted `core:docs/telemetry.md` to HEAD and the original 21-row
table was destroyed (**X326**); the page was rebuilt, and the rebuilt table is
longer and differently worded rather than a reconstruction of the old one. The
rows below are read out of the file that exists, not copied forward from the
file that does not. What survives unchanged is the checking: the guard, its
three assertions, and control `c23`, which renames one anchor and still fails
the suite.

| State | Signal | Runbook |
|---|---|---|
| Buffered counts are not reaching the database | `[:aurora_meter, :flush, :error]` arriving, `flush.stop.duration` absent | `operations.md#4-when-the-database-is-unavailable` |
| The buffer fills faster than it drains | `store.gauge.dirty_keys` climbing and `store.gauge.oldest_pending_age_ms` past the flush interval | `operations.md#2-queue-sizing` |
| A batch is retried and never commits | `flush.error.count` steady while `flush.count` stays at zero | `operations.md#4-when-the-database-is-unavailable` |
| A retained batch is stuck in the flusher | `store.gauge.pending_batch_age_ms` growing while `store.gauge.pending_batch_items` stays flat | `operations.md#4-when-the-database-is-unavailable` |
| The gauges went silent | no `[:aurora_meter, :store, :gauge]` for more than one `:metrics_interval` | `operations.md#9-a-health-check-worth-having` |
| The flusher stopped or the Store restarted | `store.gauge.oldest_pending_age_ms` above twice `:flush_interval` with no `flush.stop.duration` arriving, or `store.gauge.counter_keys` back at zero | `operations.md#4-when-the-database-is-unavailable` |
| Buffered usage was lost with the node | `store.gauge.dirty_keys` at the moment of loss; afterwards the counter total sits below the durable total | `metering.md#durability` |
| A node is not hearing its peers | `cluster.lag.peers` below the deployment size, `cluster.lag.since_last_message_ms` above the broadcast interval | `clustering.md#requirements` |
| Cluster state is not converging | `cluster.lag.unreconciled_keys` not returning to zero | `clustering.md#guarantees` |
| Gossip flows and nothing applies it | `broadcast.count` non-zero while `cluster.apply.count` sits at zero | `clustering.md#configuration` |
| A rolling deploy left one node behind | `cluster.apply.count` at zero on one node only | `clustering.md#rolling-upgrades` |
| Durable writes are being refused | `record.stop.duration` with `result: :unavailable` or `result: :conflict` | `metering.md#durability` |
| A durable write raised | `[:aurora_meter, :record, :exception]` | `metering.md#durability` |
| A durable event was refused by validation | `record.stop.duration` with `result: :invalid` | `metering.md#durability` |
| An event id was replayed with identical content | `record.stop.duration` with `result: :duplicate`. This is success, not an error, and alerting on it is usually wrong | `metering.md#durability` |
| Usage is metered for a feature no plan declares | `[:aurora_meter, :track]` with `declared: false` | `entitlements.md#features-the-plan-does-not-declare` |
| Entitlement checks are refusing | `reserve.qty` with `result: :not_entitled` | `entitlements.md#subscription-status` |
| Holds are not being closed | `credits.hold_reconciliation.age_seconds` rising, `outcome: :no_reconciler` | `operations.md#3-recovering-stale-holds` |
| Settlement above its hold created debt | `credits.settle.amount` above the reserved `amount` on the same event | `credits.md#hold-settle-release` |
| The host hold policy is not running | `credits.hold_reconciliation.duration` with `outcome: :callback_timeout` or `:callback_exit`, steady | `operations.md#3-recovering-stale-holds` |
| The policy released work that then completed | `credits.hold_reconciliation.duration` with `outcome: :released_by_other`, and a `settle_missed:` debit beside it | `credits.md#hold-settle-release` |
| The ledger cannot account for a movement | `[:aurora_meter, :credits, :conservation_error]` at all | `correctness.md#i10-every-ledger-amount-has-exact-provenance-and-conservation` |
| Promotional credit is not expiring | `credits.expire.amount` at zero while granted lots age past their expiry | `credits.md#promotional-credit-and-expiry` |
| A recurring allowance did not land | `credits.recurrence.amount` missing for a period | `credits.md#recurring-allowances` |
| Customers run dry without warning | `credits.low_balance.available` crossings clustered at zero | `credits.md#low-balance` |
| The lot migration refuses to proceed | `credits.lot_migration.blocked` above zero | `upgrading-to-lots.md#what-the-migration-will-not-do` |
| A plan transition was refused | `plans.transition.count` with a `result` other than applied | `plans.md#moving-a-tenant-between-plans` |
| A scheduled transition is stuck pending | no `plans.transition.count` past its effective time | `plans.md#moving-a-tenant-between-plans` |
| A plan definition changed under a live version | boot raises. There is no event and there deliberately is none: the process refuses to start rather than meter under terms nobody agreed | `plans.md#versions` |
| A replay is not progressing | `replay.batch.scanned` flat with a fixed `cursor` | `replay.md#watching-one` |
| A replay found differences | `replay.phase.duration` on the compare phase with `differences` above zero | `replay.md#if-the-rebuild-turns-out-to-be-wrong` |
| A replay was killed mid-flight | no `replay.phase.duration` after the announce phase | `replay.md#what-a-kill-leaves-behind` |
| Scheduled work is not running | `operations.batch.items` at zero for a whole window | `scheduler.md#without-oban` |
| The same operation runs twice | `operations.batch.items` doubling under one `name` | `scheduler.md#running-the-same-thing-twice` |
| Retention refused a table | `retention.prune.deleted` at zero with `blocked: true` | `retention.md#the-allow-list` |
| A backfill stalled | `events.backfill.batch.scanned` flat with a fixed `cursor` | `operations.md#6-replay` |

**How the rebuilt table was checked against the destroyed one.** The first pass
at the rewrite covered the buffered and cluster paths well and had silently lost
seven states the original carried, mostly on the durable-event and hold paths:
buffered usage lost with the node, a flusher that stopped, an event refused by
validation, an event id replayed with identical content, a hold policy that is
not running, a policy that released work which then completed, and a scheduled
transition stuck pending. A row count guard does not catch that, because the
rewrite was **longer** than the original. They were found by listing the old
table's states out of this evidence file, which had not been overwritten, and
checking each against the new one. All seven are back, and so is "a plan
definition changed under a live version", whose signal is a raised exception
rather than an event and which is the one row the guard cannot check.

Recorded as **X330**, and the rule is sharper than "check the rebuild": **once a
page is gone, the evidence file describing it is the only surviving
specification, and it must be read as one before the rebuild is called
finished**, not updated afterwards to match whatever was written. Updating the
evidence to match the rebuild is the failure mode, and it is the natural thing
to do, because that file is the one you are holding open while you rebuild.

The corollary belongs to every unit with a hand-written table: **a floor on the
row count is a guard against deletion, never against substitution.** This
rewrite had 28 rows against the original's 21 and still lost seven states. The
only real check is the enumerated list of what the table must cover, which is
why section 2 is now generated from the live table rather than maintained
beside it.

## 3. Pro: state, signal, runbook

Seventeen rows, in `pro:docs/telemetry.md`, covering the commercial half: export
backlog and age, uncertain provider outcomes, quarantine, stale-worker fencing,
provider differences, unresolved payments, guarded recovery, webhook failure,
unconfirmed paid transitions, plan-version fallback, the incomplete version 10
upgrade, retention refusal and a stopped worker.

## 4. Which invariants this covers, and which it does not

The build document lists 08a as the observability contributor to I01, I05, I06,
I07, I09, I11, I12, I15, I16, I17 and I18. Every one has a row above or in Pro's
table. Two are worth being precise about, because the signal is an **absence**:

- **I12** (expiry): the signal is the absence of `[:aurora_meter, :credits,
  :expire]`, not an error event. An expiry pass that cannot run emits nothing,
  and a dashboard that alerts only on values it receives cannot see it. The row
  says so; 08b's alert examples have to encode "no sample for N intervals"
  rather than a threshold.
- **I17** (scheduled transitions): the same shape. A transition stuck pending is
  an event that did not arrive.

This is the general limitation of a telemetry contract and it is stated rather
than smoothed over: **a signal that is an absence needs an alert on staleness,
and this unit ships the signal, not the alert.** 08b owns `docs/alerts.md` and
the thresholds.

## 5. "No package sends data externally on its own"

Asserted, not promised, by
`core:test/aurora_meter/telemetry/no_outbound_io_test.exs` and
`pro:test/aurora_meter/pro/telemetry/no_outbound_io_test.exs`. The scan, the
allow lists and their reasons are in `pro:docs/evidence/v1/phase-08/08a-no-outbound-io.md`.

The second half of the same claim, which is easy to miss: **the library attaches
no telemetry handler of its own, ever.** A handler attached at boot would be the
library deciding what leaves the node, and it would also be the handler leak G08
bullet 2 asks about. `lib/` contains no `:telemetry.attach` or
`:telemetry.attach_many` call in either package, and that is asserted.
