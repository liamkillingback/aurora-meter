# ADR 0007: Idempotent database flush batches

Status: accepted for the 0.4.0 release candidate, 2026-09-12.

## Problem

A counter delta may commit even when its caller observes a timeout. Comparing
the database total to an ETS snapshot cannot establish whether that delta
committed: other writers and gossip can move either total. Restoring and
resending the delta can overbill; discarding it can lose real usage.

## Decision

Store captures an immutable batch with a UUID and retains it in its ETS table.
The Ecto adapter inserts a receipt, period deltas and day deltas in one database
transaction. A receipt conflict reads current totals without applying deltas.
Flusher acknowledges the batch only after rebasing from successful results.
New usage stays pending for the next batch. Snapshot creation runs in Store so
killing Flusher cannot interrupt the transfer from pending counters to a batch.

Schema version 6 adds `aurora_meter_flush_receipts`. Custom adapters implement
the same atomic `Storage.flush_batch/3` contract. Errors retain the batch and
return `{:error, reason}`; telemetry includes the number of retained keys.

## Limits and operations

Receipts persist indefinitely, one small row per nonempty flush. Monitor table
growth. Safe deletion requires proving that no running or recovering node can
retry the deleted IDs; this release intentionally supplies no age-based pruning.
Never truncate receipts while applications are running with pending batches.

This protects retries, not loss of the Store or VM: unflushed buffered usage
can still be lost, including a backlog during database outages. Durable event
tracking remains a separate option. This does not turn clustered soft quotas
into a globally serialized hard limit.

## Verification

Regression tests cover commit-then-timeout followed by another writer, gossip,
new usage during recovery, Store-owned snapshot reuse, and counter/history
deduplication. Tests with independent database connections prove simultaneous
delivery applies one batch once and failure after the counter write rolls back
the counter and receipt together.
