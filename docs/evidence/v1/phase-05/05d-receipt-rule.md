# 05d: the receipt rule, and the double count it prevents

Build unit **05d**, tasks 05.06 and 03.09. Invariant **I01**.

Core `0b3df43d7e6e425177f2f926df98a8aeb004d512`, Pro
`f08561bf19d7449523e934e8a0926b6a8dc575d3`, storefront
`c916b9b131382534898f141e35bac000c898ebb4`. Core schema 8, Pro schema 10, no DDL.
Elixir 1.20.1, OTP 29 (erts 17.0.1), Postgres 16 on port 5490. 2026-09-15.

`mix test test/aurora_meter/retention_test.exs`, exit 0, 31 passed
(4 doctests, 27 tests). Every row below is one named test in
`AuroraMeter.RetentionTest`, indexed under I01 in `docs/correctness.md`.

## Why this file exists

`AuroraMeter.Storage.Ecto.flush_batch/3` inserts a batch's receipt with
`on_conflict: :nothing` and applies the counter deltas only when that insert
reported one new row. `inserted == 1` is the whole of I01. A deleted receipt
reopens the window, and the consequence is a double count of real usage.

The rule that prevents it could be decorative: it would pass its own tests
whether or not deleting a receipt actually causes harm. So the first thing this
file records is the harm, demonstrated.

## The demonstration, and its control

`test I01 a retry of a batch whose receipt was pruned would double count`.

Written as a demonstration rather than as a regression, with the receipt removed
**directly** rather than through `prune/1`, because `prune/1` correctly refuses
to remove it.

| Step | Counter after |
|---|---|
| `flush_batch(id, [+5])` | **5** |
| `flush_batch(id, [+5])` again, receipt in place | **5** (the receipt is what refused it) |
| `DELETE FROM aurora_meter_flush_receipts WHERE id = <id>` (1 row) | 5 |
| `flush_batch(id, [+5])` again | **10** |

Five, five, ten. The middle row is the control inside the demonstration: without
it, the last line would be consistent with "a retry always adds", which would
prove nothing about the receipt.

`test I01 a retry of a batch whose receipt was protected does not double count`
is the same scenario with the rule doing its job: the receipt is aged past the
window, a `"flush:node_b"` heartbeat reports a pending batch older than the
cutoff, `prune(only: [:flush_receipts])` returns
`{:blocked, %{flush_receipts: 0}, _}`, the receipt is still there, and the retry
reads **5**.

## The rule, case by case

Every case asserts the returned reason and the surviving row count, not only the
tuple shape.

| Test | Fleet | Outcome |
|---|---|---|
| `I01 a receipt is not pruned while a node's heartbeat reports an older pending batch` | `node_a` idle and current; `node_b` `"pending"`, `pending_since` 61 days ago | `{:blocked, %{flush_receipts: 0}, [%{reason: :node_liveness_unknown, detail: %{nodes: [%{node: "node_b", why: :pending_batch_older_than_cutoff}]}}]}`; 5 receipts survive |
| `I01 a receipt is not pruned while a node's heartbeat is itself older than the cutoff` | `node_b` `"idle"` with `updated_at` 61 days ago | blocked, `why: :heartbeat_stale`; 5 receipts survive |
| `I01 receipts are pruned when every node is idle and current` | `node_a`, `node_b` both idle and current | `{:ok, %{flush_receipts: 5}}`; the 5 older receipts go, the 2 inside the window stay, asserted by id |
| `I01 receipts are pruned when a node has a pending batch newer than the cutoff` | `node_b` `"pending"`, `pending_since` 10 minutes ago | `{:ok, %{flush_receipts: 5}}` |
| `I01 a node with no heartbeat row does not block` | only `node_a` has a row | `{:ok, %{flush_receipts: 5}}`; `all_checkpoint_names() == ["flush:node_a"]` is asserted first, so the case really is "a node with no row" |
| `I01 no heartbeat anywhere blocks a prune that would delete something` | no rows at all, 5 eligible receipts | `{:blocked, _, [%{reason: :no_heartbeats, detail: %{eligible: 5}}]}`; then with the receipts removed, `{:ok, %{flush_receipts: 0}}`, so a fresh install is not reported as a problem |
| `I01 an unreadable pending_since blocks rather than being ignored` | `node_b` `"pending"` with `"not a timestamp"` | blocked, `why: :pending_since_unreadable` |
| `I01 a heartbeat state this release does not write blocks` | `node_b` state `"gathering"` | blocked, `why: :unknown_state` |
| `I01 forget_node/1 removes the block for exactly one node and leaves the others` | `node_a` idle, `node_b` and `node_c` both pending and old | blocked naming **both**; `forget_node("node_b")` returns the deleted row; blocked naming **only `node_c`**; rows are now `["flush:node_a", "flush:node_c"]`; `forget_node("node_c")` then `{:ok, %{flush_receipts: 5}}` |
| `I01 forget_node/1 refuses a node it has never heard of` | | `{:error, :not_found}` |

The last two are the "exactly one node" half of the acceptance criterion: the
untouched node's row is asserted present by name after the forget, not inferred.

`forget_node/1`'s log line, from the run:

```
[warning] AuroraMeter.Retention.forget_node/1 removed the flush heartbeat for "node_b".

It read: state="pending" updated_at=~U[2026-09-15 09:37:41.489603Z] cursor=%{"batch_id" => "54858824-...", "pending_since" => "2026-07-16T09:37:41.489352Z", "version" => "0.5.0"}

That node no longer blocks a flush-receipt prune. If it is still alive and still
holding a pending batch, and it later retries that batch after its receipt has
been pruned, the batch's usage is counted twice (invariant I01).
```

## The heartbeat the rule reads

`mix test test/aurora_meter/flusher_test.exs`, exit 0, 10 passed.

| Test | What it asserts |
|---|---|
| `the batch carries snapshot_at` | `%DateTime{}`, within 60 s of now, and **stable across re-reads of the same pending batch** |
| `the Flusher writes an idle heartbeat after a successful persist` | `state: "idle"`, `cursor["version"] == package_version()`, and **no** `pending_since` key |
| `the Flusher writes a pending heartbeat naming the batch after a failed persist` | `state: "pending"`, `cursor["batch_id"] == batch.id`, `cursor["pending_since"]` parses and equals `batch.snapshot_at` exactly; and the next successful flush returns it to `"idle"`, so a transient failure does not block retention for ever |
| `a failing heartbeat write does not fail the flush` | `aurora_meter_checkpoints` is **renamed away** for the duration, which is exactly what a pre-V7 database looks like. `Flusher.flush()` still returns `{:ok, n}` with `n > 0`, the counter is persisted, the pending ETS entry is gone, and the log carries "could not write its flush heartbeat" |
| `the Flusher writes at most one heartbeat per minute on idle ticks` | 20 consecutive idle ticks write one row; 20 more leave `updated_at` **byte for byte the same** |

The fault in the pending case is injected at `:before_commit` on the
`flush_batch` callback through the 01b fault harness, so the flush really fails
rather than being simulated.

## The worker's rows, which X215 left open

`mix test test/aurora_meter/retention_controls_test.exs`, exit 0, 5 passed.
Non-sandbox, real connections, killed processes.

### Kill and resume

`I16 the retention worker resumes at its checkpoint after a kill`. 50 eligible
receipts, `batch_size: 10`, killed from inside the
`[:aurora_meter, :operations, :batch]` telemetry handler at the end of batch 2,
which runs in the worker's own process and is therefore exactly the batch
boundary.

| | |
|---|---|
| The kill | `{:exit, :killed}` |
| Committed before it | **20** rows gone, 30 left |
| The checkpoint | `%{"deleted" => 20, "examined" => 20}` |
| The next run | `{:ok, %{flush_receipts: 30}}`, exactly the complement |
| After it | 0 left, and every one of the 50 planted ids is gone |

A delete sweep has no positional cursor: it advances by doing the work. "Resumed
without skipping" therefore means the remaining set is exactly the complement of
what committed, which is what those two numbers say together, and the file says
so rather than claiming a cursor it does not have.

### Two jobs on independent connections

`I16 two retention jobs on independent connections delete every eligible row and
none twice`. Five races of 20 eligible receipts, two prunes on two independent
connections, both blocked on one receipt row a third connection holds
`FOR UPDATE` until Postgres reports two waiters, then released.

The waiter query does **not** filter on `database` (X186): a row-lock waiter
blocks on the holder's `transactionid`, and a `transactionid` row in `pg_locks`
carries no database, so the obvious query returns nothing and the rendezvous
silently never fires. This reads `pg_stat_activity.wait_event_type = 'Lock'`.

Measured, `AURORA_RACE_REPORT=1 ... --seed 1`:

```
[05d retention] %{of: 5, test: :retention_forced_race, contended: 5,
                  unassisted_contended: 0,
                  deleted_per_race: [[20, 0], [0, 20], [20, 0], [20, 0], [20, 0]]}
```

* **Contended 5 of 5.** `assert contended == races` runs on an **ordinary** run,
  not behind the environment variable (X214): the variable gates the `IO.puts`
  only, and the assertion is the control.
* **The negative control for the rendezvous** (X125): the same race with the
  holder removed and nothing else changed contended **0 of 5**. The rendezvous is
  what produces the contention, so the assertion above measures what it claims.
* `Enum.sum(deleted) == 20` in every race, and 0 rows left. One worker takes all
  20 and the other takes 0, which is `READ COMMITTED` doing what it should: the
  loser re-evaluates its candidate set after the winner commits and finds the
  rows gone. A delete cannot remove a row twice, so the sum is the assertion that
  nothing was skipped.

### The rest

| Test | |
|---|---|
| `I16 the retention worker cancels nothing and reports a paused table` | paused: `{:ok, {:blocked, %{flush_receipts: 0}, [%{reason: :paused}]}}`, 5 rows intact; resumed: `{:ok, %{flush_receipts: 5}}` |
| `the retention worker's job args are table names and bounded integers` | `"batch_size" => "all of them"` and `"max_items" => -1` fall back to the defaults and the prune still removes all 6; `"only" => ["aurora_meter_events"]` raises `ArgumentError` rather than silently pruning nothing |
| `the retention worker maps an unexpected return rather than matching on it` | `map_result(:surprise) == {:error, {:unexpected_return, :surprise}}` (L05a-1) |
