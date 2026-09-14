# Clustering

Aurora Meter counts in ETS on every node and still gives you one cluster-wide
number. This guide explains how, what it guarantees, and what to configure.

## How it works

Every counter row on a node is
`{key, value, pending_flush, pending_gossip, remote, reserved}`:

- `value` is this node's view of the **cluster-wide** total
- `pending_flush` is what this node has added since its last database flush
- `pending_gossip` is what this node has added since its last PubSub tick
- `remote` is how much of `value` arrived from other nodes since the last
  rebase, so anything reasoning about what the *database* holds can tell that
  this node's view moved for a reason the database has not seen
- `reserved` occupies quota for unfinished `with_quota` work and is neither
  flushed nor gossiped, because it is not completed usage

Two loops keep the nodes in agreement.

**Delta gossip (fast).** Every `:broadcast_interval` (1 s by default) the
broadcaster takes each touched counter's `pending_gossip` and publishes one
`{:aurora_meter, :deltas, node, [{key, delta}]}` message on the
`"aurora_meter:cluster"` topic. Every other node adds those deltas to its own
`value`. A LiveView on node B therefore sees node A's increments within about a
second.

**Delta flush and total announcement (durable).** Every `:flush_interval` (5 s
by default) the flusher takes each dirty counter's `pending_flush` and writes it
to Postgres as a delta (`value = value + Δ`, `AuroraMeter.Storage.add_counters/1`).
Because every node writes only what it added, the row is the true cluster total
no matter how many nodes flush it. Postgres returns that total; the flushing node
re-bases its `value` on it (`total + pending_flush`) and publishes
`{:aurora_meter, :totals, node, [{key, total}]}` so every other node re-bases
too. Anything gossip missed (a dropped message, a node that seeded from the
database while another had unflushed increments) heals on the next announcement.

Announced totals are only ever applied *forward*: if a late announcement carries
a smaller total than a node's current base, it is ignored, and the node's own
next flush re-bases it unconditionally.

## Guarantees

- **Correct totals in the database.** After every node has flushed, the row
  equals the sum of every increment on every node. Losing a Store or VM can
  lose that node's usage since its last successful flush; an outage can make
  this longer than one interval.
- **Convergent reads.** `AuroraMeter.usage/2` on any node is the true total
  minus, at most, what the other nodes added in the last `:broadcast_interval`
  (one `:flush_interval` if PubSub dropped a message).
- **Bounded overshoot on hard limits.** `reserve/3` and `with_quota/4` enforce
  against the local view, so a burst spread across N nodes can exceed a hard cap
  by what the other N−1 nodes admitted within one `:broadcast_interval`. Lower
  the interval to tighten it (cost: one PubSub message per node per tick), or
  mark the feature durable and reconcile invoices from the event log.
- **Idempotent flushes.** A flush with nothing pending writes nothing. Re-basing
  never double counts: it is an absolute correction against a snapshot, so a
  bump that lands mid-rebase is preserved exactly.
- **Retryable batches.** Counter and history deltas commit with a unique
  receipt. If the response is uncertain, the Flusher retains and retries the
  identical batch. A committed receipt prevents a second addition. The pending
  batch belongs to Store, so a Flusher restart does not lose it. Errors emit
  `[:aurora_meter, :flush, :error]` and surface from `Flusher.flush/0`.
  Receipts are retained indefinitely; do not remove them while a node could
  still retry. See [ADR 0007](adr/0007-idempotent-flush-batches.md).

## Requirements

- A **distributed** `Phoenix.PubSub` (the default `Phoenix.PubSub.PG2` adapter
  with Distributed Erlang, or the Redis adapter). This is the same PubSub you
  already configure for LiveView; nothing extra is needed. On a single node, or
  with a non-distributed PubSub, every message is local and dropped, and
  behaviour is exactly what it was.
- The schema version this release requires, which is
  `AuroraMeter.Migration.latest_version()`. Clustering itself adds no columns:
  the gossip and the announcements are PubSub messages and the flush is the
  ordinary counter write. Run `mix aurora_meter.gen.migration` after any upgrade
  and it is a no-op when there is nothing to apply.

## Configuration

```elixir
config :aurora_meter,
  cluster_sync: true,          # default; false = per-node counters, cluster-wide tenant broadcasts
  broadcast_interval: 1_000,   # gossip and LiveView update cadence
  flush_interval: 5_000        # durable write and total-announcement cadence
```

With `cluster_sync: true`, tenant usage broadcasts
(`{:aurora_meter, :usage, ...}`) are **node-local**: each node informs its own
LiveViews from its own converged view, so a browser never receives two slightly
different numbers from two nodes. With `cluster_sync: false` they fan out
cluster-wide as in 0.2.

## Rolling upgrades

**0.4.x to 0.5.0.** No schema change, and no change to the gossip or
announcement messages, so a cluster part way through the deploy is a cluster of
nodes that agree. 0.5.0 adds warnings, not behaviour: see
[Upgrading to 1.0](upgrading-to-1.0.md) for what each one is telling you.

**0.5.x to 1.0.0.** Read the upgrade note first. 1.0 turns the 0.5.x warnings
into failures, which is a boot-time decision on each node rather than anything
the cluster negotiates, so a node that starts is a node that agrees with the
others. Any schema version 1.0 needs is applied before the deploy, as always.

**Before 0.3.** Those releases wrote absolute counter values rather than deltas,
so a node on one of them can overwrite a newer node's work while both are
running. They are outside the
[support policy](support-policy.md); upgrade to a supported version with a full
restart rather than a rolling one.

The counter row tuple above is described so the guide can explain itself. It is
not part of the compatibility promise, and the support policy says so.

## Testing it

`AuroraMeter.Test.simulate_node/3` applies deltas as if another node had
gossiped them; `AuroraMeter.Test.simulate_flush/2` applies totals as if another
node had flushed. See the [testing guide](testing.md).

## Telemetry

`[:aurora_meter, :cluster, :apply]` fires for every batch applied from another
node with `%{count}` and `%{kind: :deltas | :totals, origin: node}`.
`[:aurora_meter, :flush]` now also carries `delta_sum`, and
`[:aurora_meter, :broadcast]` carries `deltas` (how many were gossiped).
