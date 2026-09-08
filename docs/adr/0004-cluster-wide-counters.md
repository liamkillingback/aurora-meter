# 0004 — Cluster-wide counters: delta flush, delta gossip, total announcements

- Status: Accepted
- Date: 2026-09-07

## Context

Through 0.2 every node kept its own ETS counter and flushed **absolute values**
with an upsert, so two nodes overwrote each other and the README had to say
"counters are per node". That is a hard stop for anyone on Fly, Kubernetes or
any deployment with two machines, which is most of the audience. The fix must
keep the hot path a single local ETS call and keep the database off it.

## Options considered

1. **Delta flush** (`value = value + Δ`, `RETURNING` the total) with per-node
   `pending_flush`. Correct persistence; cross-node visibility only every flush,
   and only for keys the node itself touched.
2. **Per-node rows** (`node` column, `SUM` on read). Correct, but N× rows, a
   `SUM` on every cold seed and every Pro query, unbounded churn under
   Kubernetes pod names, and reads still miss other nodes' unflushed
   increments.
3. **Delta gossip over PubSub** every broadcast tick, so views converge in ~1 s;
   combined with (1) for durability, plus **total announcements** after each
   flush so anything gossip missed heals.
4. **A global process per key** (`:pg` / `:global`). Correct and immediate, but
   an RPC on the hot path, which is the one thing the design forbids.

## Decision

Option 3: (1) + gossip + announcements.

- ETS rows become `{key, value, pending_flush, pending_gossip}`; `bump/2` is one
  `:ets.update_counter/3` over three positions.
- The flusher takes `pending_flush`, writes deltas via
  `Storage.add_counters/1` / `add_history/1` (new behaviour callbacks), re-bases
  on the returned totals and publishes them. Absolute `upsert_*` stays for
  backfills and fixtures.
- The broadcaster takes `pending_gossip` and publishes one deltas message per
  tick; tenant usage broadcasts become node-local when sync is on.
- `AuroraMeter.Cluster` (new supervised process) subscribes to the cluster
  topic, applies remote deltas to warm keys, and applies remote totals only
  forward (never below the node's current base).
- `cluster_sync: true` by default; no schema migration.

## Consequences

- A read on any node is the true total minus at most the other nodes' last
  `:broadcast_interval` of increments. Hard limits can be overshot across N
  nodes by what the other N−1 admitted in one tick; documented, tunable.
- Flushes are still idempotent (nothing pending writes nothing) and now safe
  under failure (taken deltas are restored and re-marked dirty).
- `AuroraMeter.Storage` gains two required callbacks; no third-party adapters
  are known.
- Rolling 0.2 → 0.3 keeps 0.2's overwrite semantics until the last 0.2 node is
  gone. Documented in the clustering guide.
- Pro reads through the same public API and needs no change; Pro's
  reconciliation should compare its ledger against the flushed total rather
  than the local view to avoid false drift on a rebase dip.
