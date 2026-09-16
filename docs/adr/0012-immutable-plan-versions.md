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

## Implementation notes (build unit 07a, 2026-09-16)

Five things the implementation settled differently from, or more precisely than,
the decision above. Each is recorded here rather than in a new ADR, because none
of them repeals the decision and an ADR per implementation detail would make the
series unreadable.

**The fingerprint does not cover `effective_at`.** The decision says "a
fingerprint of the compiled definition" without saying what is in it. The
canonical form covers the plan id, the version, the price, every feature and
every recurring credit, and deliberately not the effective instant. That instant
says when a version starts applying to **new** subscriptions; a tenant already
pinned to a version is not moved by it, so changing it cannot reprice anybody,
which is what this ADR is about. Including it would also have made the third
half of the decision unreachable: deleting a retired base version's block forces
the version left behind to drop its own instant, or the plans module no longer
compiles, so every retirement would have been a refused boot for a plan whose
price nobody had touched.

**The legacy assignment writes the plan's base version, not the literal `"1"`.**
The decision and `schema-migration-map.md` S6 both say `"1"`, and for every
plans module that never names a version those are the same string, because `"1"`
is the DSL default. For a host whose first version is called `"2024-01"` the
literal would name a version that has never existed and every one of their
tenants would fall back to the default plan. The base version, the one declaring
no `effective_at`, is by definition the contract in force before any other
version of that id was written. `"1"` remains the fallback for a plan id that
has no registered version at all.

**The DSL's versioned form is `plan/3`, not `plan/2`.** Elixir parses
`plan :pro, version: "2" do ... end` as three arguments: the id, the keyword
list and the `do` block. The unversioned `plan :pro do ... end` is still
`plan/2`, so no existing plans module changes, and `__using__/1` imports both.

**`AuroraMeter.Storage` gained three callbacks, not two.**
`api-change-map.md` 1.2 lists `put_plan_version/1` and `list_plan_versions/1`.
The batched legacy assignment is `assign_legacy_plan_versions/1` beside them,
under the same `:plan_versions` capability, rather than raw SQL issued from
`AuroraMeter.Plans`: an adapter that cannot store snapshots must not be asked to
run a statement against a table it does not have, and the degraded mode this ADR
requires is expressed once, as a capability.

**Version 10 also carries `open-findings.md` X220**, the `clock_timestamp()`
default on `aurora_meter_flush_receipts.inserted_at`. It has nothing to do with
plans; it is here because it is one line of DDL that needed a core schema
version, and the orchestrator assigned it to S6 rather than to the version that
was rewriting the credit ledger's ordering.
