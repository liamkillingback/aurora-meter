# ADR 0012: Immutable plan versions

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADR: 0001 (resolved decisions), which fixed the code first plans DSL
as decision D5. This ADR extends D5 with an identity and a history table; it does
not repeal it and it does not edit `plan.md`.

## Context

A plan today is a `%AuroraMeter.Plan{id, price, features}` compiled from the DSL,
and a subscription row stores only `plan_id`. Nothing links a subscription to the
definition that was in force when the customer bought it. Editing a plan block and
deploying therefore reprices and re-entitles every tenant on that plan at the next
boot, with no record that anything changed and no way to answer "what was this
customer entitled to last March".

V1 decision D05 forbids that: an existing subscription keeps its plan version
until an explicit migration. Since the change alters what a customer is charged,
it is recorded here before unit 07a writes the migration.

## Decision

Plan identity becomes `(plan_id, version)`, with a fingerprint of the compiled
definition. `version` defaults to `"1"`, so an unchanged plan block keeps working.

`AuroraMeter.Plans.register!/0` runs at boot from `AuroraMeter.start_link/1`. It
snapshots unseen `(id, version)` pairs into `aurora_meter_plan_versions` and raises
`AuroraMeter.PlanVersionConflictError` when a stored fingerprint differs from the
compiled one. The setting `plan_version_conflict` is `:warn` in the 0.5.x
transition release and `:raise` in 1.0, so a host gets one release in which a
changed definition is a warning rather than a failed boot.

Subscriptions pin `plan_version`. Existing rows are backfilled to version `"1"` at
the first boot after the upgrade, so nothing is repriced. A subscription whose
`plan_id` is no longer in the compiled plans module has no snapshot to point at:
it gets version `"1"` with a null fingerprint and is counted as `orphan_plans` in
the registration report. Registration must not raise for it, because retiring a
plan id from code is ordinary and failing the upgrade for every install that still
holds one would make the V1 upgrade unrunnable for exactly the oldest customers.

Changing entitlements means publishing a new version and scheduling a transition.
`schedule_transition/3` is idempotent by a caller supplied `ref` and defaults to
the next period boundary from the tenant's period source.
`apply_due_transitions/1` moves `pending` to `applied` under the subscription row
lock with a conditional update, so two nodes running the same schedule produce one
transition and the loser's write affects zero rows.

Precedence is fixed rather than left to whichever code path runs first: a
cancellation at period end supersedes a scheduled change effective after it; a
scheduled change effective before the cancellation date applies first; and a
provider driven immediate change applies immediately and cancels a pending local
transition, recorded with `state: cancelled` and `detail.reason: provider_override`.

## Consequences

Plans remain code first. The non goal at `plan.md:96` ("DB-editable plans / a plans
admin UI") is unchanged: `aurora_meter_plan_versions` is a history table that
interprets the past, it is never an authoring surface, and there is no
`Plans.put/1`. Code stays authoritative; the table only records what code said.

A deploy that edits a plan without bumping the version fails fast in 1.0 instead of
silently repricing. That is a real operational cost: a host used to editing a price
in place now has to add a version and schedule transitions, which is more work by
design. The alternative is a repricing that nobody authorised and nobody can see.

Historical attribution becomes answerable. A recorded event stamps the plan id and
version effective at `occurred_at`, and an instant that predates recorded history
is stored with `attribution = 'unresolved'` rather than attributed to a guess.

## Migration impact

S6 (core version 10: `aurora_meter_plan_versions`, `aurora_meter_plan_transitions`
and the subscription columns, additive), plus a `register!/0` backfill that is not
part of the DDL because computing a fingerprint needs the compiled definitions.
S6 and the explicit replace list in `put_subscription/1` must ship in the same
release, or a stale node's `sync/1` would null the new columns, and old nodes must
be gone before any transition is scheduled. Rollback position: yes after S6, until
the first transition is scheduled.

## Verification

Unit 07a (I17: a changed definition raises, a tenant stays on version 1 after a
version 2 deploy), 07b (transition races and precedence) and 07c (Pro price mapping
and provider confirmed ordering). None of these tests exists yet.
