# The mental model

Five things a host can ask Aurora Meter to do. They look similar and they are
not, and picking the wrong one is the most expensive mistake this library lets
you make. This page separates them, says what each costs, and says what happens
when the machine dies in the middle.

Nothing here is new behaviour. Every row links to the page that states the
guarantee and, through it, to the named test that proves it.

## The table

| You want to | Use | It is | Cost on the call | If the VM dies now |
|---|---|---|---|---|
| count something cheap and approximate | `AuroraMeter.track/4` | a buffered ETS increment | no database write | everything since the last acknowledged flush is gone |
| stop someone at a limit | `AuroraMeter.with_quota/4` or `reserve/3` | local admission, atomic in ETS | ETS only | the reservation stays occupied on that node until the period ends or the Store restarts |
| record a fact you will invoice | `AuroraMeter.record/4` | one database transaction | one round trip | either nothing happened, or it happened once and a retry of the same `id` says so |
| take or hold money | `AuroraMeter.Credits.with_credits/4`, `hold/4`, `settle/3` | one transaction under the wallet's row lock | one round trip plus lock wait | the hold survives and `Credits.reconcile_holds/1` closes it, if you have configured a reconciler |
| do periodic work | an Oban worker | at least once, with idempotent effects | host scheduled | the job runs again and the effect happens once |

Everything in the first two rows lives in memory. Everything in the next two
lives in Postgres. That is the whole distinction, and the rest of this page is
why it matters.

## Why a quota is not a fact

A quota answers **"may I?"**. A fact answers **"what happened?"**.

`with_quota/4` reserves against a counter in ETS, runs your function, and
commits the reservation on a normal return or releases it on a raise, a throw or
an exit. It is atomic on one node: under any concurrency, a hard limit of `n`
admits exactly `n`. It is not atomic across a cluster, and it does not write
anything you can invoice from. See
[Guarantees](guarantees.md) G1 to G5.

`record/4` writes one row in one transaction, keyed on an id **you** supply.
A retry of the same id is reported as a duplicate rather than applied again,
and a different payload under an id already used is reported as a conflict
rather than accepted quietly. That is what an invoice can be built from. See
[Guarantees](guarantees.md) G10 and [Correctness](correctness.md) I06 and I07.

The consequence people trip over: `with_quota/4` on a feature whose reporting
source is `:events` gates the work in ETS while the billable fact is the
separately committed event. Both are correct and they are not the same number
at the same instant. [Metering](metering.md) and
[Correctness](correctness.md) I08 set out which source answers which question.

## Why a fact is not money

A fact is free to write: one insert, one projection delta, no contention beyond
the row it creates.

Money is not. Every credit operation serialises on that wallet's balance row,
because conservation is a per-wallet property: the balance equals the sum of
that wallet's transactions, and there is no way to check sufficiency and spend
in one step without holding the row. That is a lock wait under load, and it is
the price of not spending the same micro-dollar twice. See
[Credits](credits.md) and [Correctness](correctness.md) I10 and I11.

So: count usage with `track/4`, gate it with `with_quota/4`, record the
invoiceable fact with `record/4`, and move money with `Credits`. Four different
questions, four different costs.

## Where Aurora Meter Pro joins

Pro exports facts to Stripe and settles payments. **It never counts.** The
counting, the plans, the quotas, the events and the credit ledger are all in the
free core and stay there; Pro is the settlement layer on top.

A host with no Pro keeps every one of the five operations above. What it does
not get is the Stripe exporter, the delivery outbox, reconciliation against the
provider, the payment rail for top-ups, and the Pro dashboards. See
[Free vs Pro](../README.md#free-vs-pro).

## Choosing

```
Do you need the number to survive a crash?
├─ No  ──────────────────────────────►  track/4        (buffered, ETS)
└─ Yes
   │
   Is it money leaving or entering a balance?
   ├─ Yes ──────────────────────────►  Credits          (row lock, transaction)
   └─ No
      │
      Will something bill from it, or must it be auditable?
      ├─ Yes ───────────────────────►  record/4         (one fact per id)
      └─ No  ───────────────────────►  track/4 with history

Separately, and at any point:
Do you have to refuse the work at a cap?
└─ Yes ──────────────────────────────►  with_quota/4    (atomic on one node)
```

## Five things a reader would reasonably assume, that are not true

This programme found each of these the hard way. They are here because a mental
model that omits them is marketing.

**1. Buffered loss is not one flush interval.** It is everything not yet in an
acknowledged flush batch. While the database is unreachable the pending set
grows without bound, and a hard crash loses all of it. If the number must
survive, it is a `record/4` fact, not a `track/4` counter.
([Guarantees](guarantees.md) G6.)

**2. A hard cap can be exceeded in a cluster.** Enforcement is against the local
view. Nodes exchange deltas every `:broadcast_interval` and re-base on the
persisted total every `:flush_interval`, so a burst across N nodes can overshoot
by what the other nodes admitted between announcements. This is a design
decision, not a defect: the alternative is a synchronous round trip on the hot
path. ([Guarantees](guarantees.md) G4, [Clustering](clustering.md).)

**3. A killed caller leaks its reservation.** `Process.exit(pid, :kill)` inside a
`with_quota/4` callback cannot run the release, so the reserved units keep
occupying the cap on that node until the period ends or the Store's ETS table is
rebuilt. No monitor is added on purpose: releasing on a monitor would release
work that is still running. ([Guarantees](guarantees.md) G5.)

**4. Credit lots are not retroactive.** A wallet created by this release is born
on the lot engine and gets the allocation trail, the documented spend order,
`debt` and `expired`. A wallet that predates the release keeps the legacy
balance until you run the migration, so **one installation can hold two kinds of
wallet and answer the same API differently for two tenants**. The nine
differences are tabulated in [Credits](credits.md) under "Which wallets are on
lots", and the migration is [Upgrading to lots](upgrading-to-lots.md).

**5. A wallet in debt is not simply negative.** When a settle exceeds its hold
the balance can go below zero, and that debt is recorded rather than hidden. In
that state the wallet reports **zero** spendable rather than a negative number,
and a further hold or debit is refused with `{:error, :debt_outstanding}` until
the debt is cleared. A dashboard that renders `available` without checking
`debt` will show a customer something that is not what they can spend.
([Credits](credits.md) under "Debt".)

## What the free core needs from you, and what it does not

It needs a Postgres repo, a `Phoenix.PubSub` server, and a plans module. That is
all. Oban, LiveView, LiveDashboard, `telemetry_metrics`, OpenTelemetry, Plug and
Igniter are optional, and "optional" here means a CI lane builds and tests this
library with them removed rather than meaning nobody checked. See
[Support policy](support-policy.md) section 5.

It makes **no outbound network request of its own**, reports nothing to us, and
stores only what you hand it: tenant keys, feature atoms, integer quantities and
your own metadata. See [SECURITY.md](../SECURITY.md).

## Where to go next

- [Getting started](getting-started.md): install and the first counter.
- [Guarantees](guarantees.md): the contract, one row per guarantee, each with
  what voids it and the test that proves it.
- [Correctness](correctness.md): the same ground per invariant, with the
  prerequisites, the known limits and the evidence.
- [Concepts](examples/concepts.md): tenant, feature, period, plan, and the two
  shapes money takes.
- [Architecture](architecture.md): which process writes which table, and where
  the seams are.
