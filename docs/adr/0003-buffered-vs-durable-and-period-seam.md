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
