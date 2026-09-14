# 0003 — Buffered vs durable metering, and the period seam

- Status: Accepted
- Date: 2026-07-11

## Context

Some usage (dashboards, soft quotas) tolerates a tiny loss window; billing-grade
usage does not. Billing periods differ between the free core (calendar month) and
Pro (subscription-aligned).

## Decision

- Metering mode is per-feature: `:buffered` (default — ETS-first, flushed on an
  interval) or `:durable` (also writes an event row synchronously on `track`).
- `AuroraMeter.Period.current/2` resolves the active window through a configurable
  `:period_source` seam, defaulting to `AuroraMeter.Period.Calendar` (monthly,
  UTC). Pro sets `:period_source` to subscription-aligned bounds.

## Consequences

- Phase 3 MUST ship the `:period_source` seam even though only the calendar
  implementation exists at that point, so Pro can override it without editing
  core call sites.
- Absolute-value upserts make the flusher idempotent and reset-free: a new
  `period_start` in the counter key starts a fresh window automatically; old rows
  are retained as history.

## Note, 2026-09-15

The original text above is the decision as it was taken and is left as written.
Two of its statements no longer describe the code, and are corrected here rather
than in place, because an ADR records what was decided and when.

- The flusher does not write absolute values. It applies deltas
  (`value = value + EXCLUDED.value`, in the Ecto storage adapter's
  `flush_batch/3`),
  which is what lets several nodes add up into one row instead of overwriting one
  another. That change was made for cluster-wide counters, ADR 0004.
- Idempotence therefore does not come from the upsert being absolute. It comes
  from the flush receipt: its primary key is inserted inside the same transaction
  as the counter and history deltas, so a batch redelivered after a lost response
  applies once. See ADR 0007.

What survives unchanged is the reset-free part: a new `period_start` in the
counter key starts a fresh window with no reset job, and old rows stay as
history. The current contract is in
[the guarantee page](../guarantees.md).
