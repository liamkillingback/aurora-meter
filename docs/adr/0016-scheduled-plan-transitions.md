# ADR 0016: Scheduled plan transitions and provider precedence

Status: accepted (Aurora Meter 1.0.0-rc.1, build unit 07b)

## Context

ADR 0012 made a plan version immutable and pinned every subscription to one, so
redeploying a definition can no longer move a tenant. That left the other half
of the question open: when a tenant is **meant** to move, how does it happen,
and who decides when.

Before this unit every plan change in Aurora Meter was immediate and unrecorded.
`AuroraMeter.subscribe/2` overwrote `plan_id` in place; a Stripe portal change
reached core as a `put_subscription/1` with a new plan id and nothing recorded
what the tenant had been on, when they moved, or why. There was no way to
express "move this tenant at the next boundary", no idempotency for a plan
change (two clicks on an upgrade button wrote the same thing twice with no way
to tell them apart), no cancel, no preview, and no defined ordering when a local
schedule and a provider change targeted one tenant.

Three constraints shaped the answer.

**A plan change is money.** Applying one early, twice, or when the customer has
cancelled changes what they are entitled to and, through the billing provider,
what they are billed.

**Core has no scheduler and will not grow one.** Optional Oban integration is an
optional module (ADR 0014), so the thing that applies a transition has to be a
public function a host can call from anything.

**Core cannot see provider concepts.** There is no `cancel_at_period_end`
column on `aurora_meter_subscriptions` and there will not be one, so any
precedence rule core enforces has to be expressible in what core observes: a
status, a plan id, a version, a period.

## Decision

**A transition is a row, not an action.** `schedule_transition/3` writes an
audit row in `aurora_meter_plan_transitions` and mirrors it onto the
subscription; `apply_due_transitions/1` moves it. The caller supplies a
reference and the pair `(tenant_key, ref)` is unique, so a retry is idempotent
and a different intention under the same name is a conflict naming both sides.

**Every effect is a conditional update.** Not one is predicated on a read taken
a moment earlier: each `UPDATE` carries `transition_state = 'pending'` and the
reference in its `WHERE`. Two nodes, an Oban retry and a duplicated cron tick
therefore produce one applied transition and a skip for everybody else, with no
lease, no fence and no clock anywhere in the exclusion.

**A row lock, not an advisory lock.** Every operation takes
`SELECT ... FOR UPDATE` on the tenant's single subscription row. The row exists,
it is unique per tenant, and a row lock does not pin a connection across a
network call the way an advisory lock on a pinned connection does.

**One transaction per tenant, not one per batch.** A batch-wide transaction
would hold hundreds of row locks for the length of a run and one poisoned row
would discard the others' work.

**Ordering takes a keyset, not a clock.** The due scan is a keyset over
`(scheduled_effective_at, tenant_key)`, which is the partial index core schema
version 10 creates, so the filter and the cursor sit on one key.

**Both sides of every time comparison come from the database.**
`plan_effective_at` is stamped with `clock_timestamp()` rather than by whichever
node ran `subscribe/3`, and "is this due" takes `AuroraMeter.Clock.db_now/0`. A
node stamp compared against the shared clock is the defect, whatever the size of
either clock's error.

**Core never prorates.** A preview reports each plan's declared list price and
nothing else. The billing provider is authoritative for the invoice, and the
only place a price id or a proration mode appears is the opaque map the optional
`describe_plan_change/3` callback returns.

**The precedence rules core owns are the ones core can observe**, and they live
in `put_subscription/1`, where every provider path already passes, so a provider
integration cannot forget to invoke them. A write naming exactly the scheduled
`(plan_id, plan_version)` applies the transition early; a write naming any other
plan cancels it as an override; a write whose status is not entitled cancels it
whatever the plan says. The advance-notice half, a cancellation known before it
takes effect, belongs to Aurora Meter Pro.

## Consequences

A transition is visible, cancellable and auditable before it happens, and the
history of what a tenant was on and when is a table rather than an inference.

`AuroraMeter.Storage.put_subscription/1` gains a side effect. A host calling it
directly with a changed plan while a transition is pending will see that
transition settled. It costs one uncached read per call and opens no transaction
when nothing is pending, which is every call on an ordinary installation.

The default `*/5` schedule means a tenant can use the old plan's allowance for
up to five minutes after a boundary. That is a deliberate, documented and
measured bound, not a defect, and a host that cannot accept it schedules the
worker more often or calls the operation directly.

A `failed` transition is terminal and needs a person. An automatic retry of a
target version that does not exist would loop for ever.

`AuroraMeter.Billing.Provider` gains its first optional callbacks. A provider
module that happens to define a function named `describe_plan_change/3` for its
own purposes would now be treated as implementing the callback; the names are
specific enough that this is unlikely, and `AuroraMeter.Config.validate!/0`
checks only the required set, so a provider written before these existed still
boots.

## Migration impact

None. This decision adds no DDL: every column and index it writes is created by
schema step S6 in core schema version 10, which ADR 0012 landed.

A subscription row written before version 10 has NULL in every transition
column, which is the "no transition" state throughout, so there is nothing to
backfill. `schedule_transition/3` refuses a row whose `plan_version` is still
NULL rather than moving a tenant whose current contract is unnamed.

## Verification

Build unit 07b. `AuroraMeter.PlanTransitionsTest`,
`AuroraMeter.PlanTransitionsConcurrencyTest` (twelve independent connections
behind a held row lock, and three kills),
`AuroraMeter.PlanTransitionPrecedenceTest` and `AuroraMeter.PlanPreviewTest`.
Invariants I16 and I17 in `docs/correctness.md`; evidence under
`docs/evidence/v1/phase-07/`.
