# 0002 — ETS counter substrate (not GenServer-per-tenant)

- Status: Accepted
- Date: 2026-07-11

## Context

The metering hot path must sustain high write throughput with correct concurrent
increments, and must never become a per-tenant bottleneck.

## Decision

Counters live in a shared, public ETS `:set` table and are incremented with
`:ets.update_counter/4` (atomic, lock-free). A single `Flusher` process persists
snapshots to Postgres on an interval; a `Broadcaster` process fans live values
out over `Phoenix.PubSub`. There is no GenServer per tenant.

## Consequences

- Increments are microsecond-scale and concurrency-safe without serialization
  through a process mailbox.
- Durability is eventual (≤ the flush interval). Billing-grade exactness is
  opt-in via `:durable` features that also append to the events table (ADR 0003).
- Hard-limit enforcement uses an atomic reserve (increment → compare → roll back
  on breach or on a raised function).
