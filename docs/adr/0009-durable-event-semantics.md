# ADR 0009: Durable event semantics

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADRs: 0003 (buffered versus durable and the period seam) and 0015
(period contract and clock seam), which fixes the period a recorded fact is
charged to. Mechanism detail lives in `PhxTemplates/docs/v1/build-plans/architecture-map.md`
section 4; this file records the decision only.

## Context

`aurora_meter_events` is written today by `AuroraMeter.track/4` when the feature
is listed in `durable_features`. The insert happens after the ETS bump, outside
any transaction, with no rescue, no caller-supplied identity and no uniqueness
(`aurora_meter.ex:85-86,210`). Three consequences follow. A caller that retries
after a timeout creates a second row. A host that wraps the call in its own
transaction and then rolls back loses the row while the ETS count survives. And
the table is never read for billing, so a row that is wrong is invisible until a
customer disputes an invoice. `quantity` is also 32 bit (`migration.ex:125`).

The V1 contract requires a durable path a host can retry safely, whose stored
facts are the billable ones. That changes financial semantics, so it is recorded
here before unit 03a writes any migration.

## Decision

Six points, numbered so later units can cite them.

1. **Identity.** A durable event is `(tenant_key, event_id)`, where `event_id` is
   supplied by the caller and is at most 128 bytes. Uniqueness is enforced by a
   database unique index, never by an application read followed by a write.
2. **Canonical payload and hash.** `payload_hash` is the sha256 of
   `{feature_string, quantity, occurred_at_iso8601_usec, kind, original_event_id,
   canonical_json(dimensions), canonical_json(metadata)}`. Canonical JSON sorts
   object keys recursively and rejects terms that are not JSON safe.
3. **Duplicate versus conflict.** The same identity with an equal hash returns the
   persisted event tagged `:duplicate`, with no second projection effect and no
   second outbox item. The same identity with a different hash returns
   `{:error, {:conflict, existing}}`. First write never silently wins.
4. **Corrections.** A correction is an immutable additional row of
   `kind: 'correction'` pointing at `original_event_id`, with positive magnitude,
   in the original's tenant, feature and period. Cumulative corrections may not
   exceed the original quantity, checked under a row lock on the original.
   Corrections to corrections are rejected. There is no update and no delete of
   an accepted event.
5. **Projection generation.** Totals live in `aurora_meter_event_totals` keyed by
   `(tenant_key, feature, period_start, generation)`. Rebuilding writes a new
   generation and activates it atomically only after verification. The active
   generation is a field of the `aurora_meter_checkpoints` row named
   `"events_projection"`; there is no separate projection state table.
6. **Outbox seam.** Core defines `AuroraMeter.Events.Outbox.enqueue/2` and ships
   only `Noop`. When an implementation is configured it runs inside the record
   transaction, so a failed enqueue rolls the event back. Core delivers nothing.

Replay is safe on a table under write because of two rules that come with the
generation model: the announcing transaction takes `FOR UPDATE` on the
`events_projection` checkpoint row while every record transaction takes
`FOR SHARE` on it, which fixes a watermark; and between announcement and
activation a record transaction writes its delta to both generations.

## Consequences

A host that wraps `record/4` in its own transaction gets a savepoint and an event
marked `durability: :conditional`; PubSub and ETS hydration are deferred to an
explicit `AuroraMeter.Events.after_commit/1` call the host must make. The totals
delta is inside the host transaction, so an outer rollback leaves no effect.

Legacy `durable: true` tracking keeps its current, weaker behaviour and is never
read for billing. Backpressure is a refusal, `{:error, {:unavailable, :overloaded}}`,
never a silent fall back to buffered counting, because a silent fallback turns a
durable promise into a best effort one at exactly the moment load makes it matter.

The guarantee is stated as "at most one persisted fact per identity, and a retry
of the same identity is reported as a duplicate". It is never stated as "exactly
once": the software cannot know whether a commit whose acknowledgement was lost
reached the database, which is why an unknown outcome surfaces as
`{:error, {:unavailable, reason}}` and the caller retries with the same id.
Records are commercial facts. They are not authorisation checks, and they are not
durable execution of the host's own callback.

## Migration impact

S1 (core version 7, additive DDL, transactional), S2 (`mix aurora_meter.events.backfill`,
resumable and idempotent, `event_id = 'legacy:' <> id`) and S3 (core version 8, a
concurrent unique index then `NOT NULL`, in its own host migration with
`@disable_ddl_transaction true` and `@disable_migration_lock true`). Rollback
position: application rollback is supported after S1 and after S3, because the
schema stays additive and old code ignores both the columns and the index.

## Verification

Unit 03b (I06, I07), 03c (I08), 03d (replay), 03e (I09) and 11a (I19 fixtures
`core1` and `core2`). No claim is made here that any of those tests pass today;
none of them exists yet.
