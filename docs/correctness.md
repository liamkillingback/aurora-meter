# Correctness index

This is the engineering index of Aurora Meter's correctness invariants. For each
invariant it records four things that are usually left implicit: what is
**guaranteed**, what must be true for that guarantee to hold (**prerequisites**),
what is deliberately **not** guaranteed (**known limits**), and the **tests** that
prove it.

It is not the customer-facing contract. `docs/guarantees.md` (written later in the
V1 programme) is the prose contract and links back to this file; where the two
disagree, this file is the one derived from the source.

## How to read and maintain this file

Every section is one invariant, in ascending id order, with exactly these fields
in this order: `Guarantee`, `Prerequisites`, `Known limits`, `Tests`, `Evidence`.
Every field except `Tests` begins its text on the field's own line.

Test bullets come in two forms:

- `` - `Module` / `test <full ExUnit name>` `` names a test that exists **now**.
  The full ExUnit name is what `mix test` prints and what `--only` matches:
  `test <describe> <description>` inside a `describe` block, `test <description>`
  outside one.
- `` - PLANNED (<unit>): `Module` / `test <full ExUnit name>` `` names a test that
  the given build unit must create. It must **not** exist yet; when the unit
  writes it, the unit promotes the bullet to the first form in the same change.

`test/aurora_meter/correctness_index_test.exs` enforces all of that mechanically:

- every existing-form bullet resolves to exactly one `test`/`property` macro in
  `test/`, so renaming or deleting a test fails the suite;
- every planned-form bullet resolves to none, so writing the test without
  promoting the bullet fails the suite;
- every test whose **description** begins with an invariant id (`I01 ` through
  `I22 `) is listed here, so an invariant test that is never indexed fails the
  suite;
- every invariant this package owns has a section, all five fields, and at least
  one test bullet.

A test that does not carry an invariant id in its description is not indexed. That
is the rule from the V1 invariant map, and it is the reason the id prefix exists.

Invariants owned by this package: I01 to I12 and I16 to I21. I13, I14 and I15 are
Pro's and live in `aurora_meter_pro/docs/correctness.md`. I22 is the storefront's
and is indexed in the storefront release manifest. Where an invariant is shared,
this file states the core half only and names the other half without depending on
it.

An `Evidence` path is repo relative and lives under `docs/evidence/v1/`. A path
that belongs to another repository carries that repository as a prefix
(`core:`, `pro:`, `storefront:`). The index test checks the shape of the path and
that no two invariants claim the same one; it does not require the file to exist,
because evidence is written when the phase runs, not when the index is parsed.

## I01 One flush batch has at most one durable effect

**Guarantee.** A flush batch carries a UUID. The `flush_batch/3` callback of
`AuroraMeter.Storage.Ecto` opens one transaction, inserts the batch receipt with
`on_conflict: :nothing` on
the receipt id, and applies the counter and history deltas only when that insert
reported one new row. A redelivery of the same batch, from the same node after an
uncertain response or from any other connection, finds the receipt already
committed, applies nothing and returns the current persisted totals instead. The
Flusher keeps an unacknowledged batch in Store owned ETS, so a Flusher restart
retries the identical batch rather than rebuilding a new one from whatever is
pending at that moment.

**Prerequisites.** The Ecto storage adapter on PostgreSQL, schema version 5 or
later (the `aurora_meter_flush_receipts` table), and receipts that are never
deleted while any node could still retry. The receipt id must be generated once
per batch and reused across retries; a caller that generates a fresh id per
attempt gets no protection.

`AuroraMeter.Retention` is the only thing in this package that deletes a receipt,
and it is what turns "never deleted while any node could still retry" from an
instruction into a mechanism: it refuses unless every node's `"flush:<node>"`
heartbeat proves no node holds a batch from before the cutoff, refuses when no
node is reporting at all, and offers exactly one override (`forget_node/1`) for a
node an operator has confirmed is gone. The consequence of removing a receipt
anyway is demonstrated rather than assumed, in
`test I01 a retry of a batch whose receipt was pruned would double count`.

**Known limits.** The receipt deduplicates a batch, not a unit of usage. Usage
that was never handed to a batch, because the Store or the VM was lost before the
flush, is gone and is not recoverable from the receipt table. The guarantee says
nothing about how long a retry may take: a failing database keeps the same batch
pending across many flush intervals.

Killing the two processes has two different outcomes and both are observed
rather than asserted. Killing the Flusher loses nothing: the pending batch and
every buffered delta live in tables the Store owns, so the restarted Flusher
re-sends the identical batch id. Killing the Store discards every unflushed
delta *and* the retained batch, because it owns those tables and `one_for_one`
restarts it with new, empty ones. That second case is the documented
buffered-loss boundary, not a defect; a host that cannot accept it must use a
durable feature.

**Tests.**

- `AuroraMeter.FlushBatchConcurrencyTest` / `test I01 twelve independent connections deliver one batch once`
- `AuroraMeter.FlushBatchConcurrencyTest` / `test I01 new deltas arriving during a retry are not lost and are not applied twice`
- `AuroraMeter.FlusherTest` / `test I01 a commit whose response was lost, then a foreign writer, cannot apply a delta twice`
- `AuroraMeter.FlusherTest` / `test I01 a batch belongs to Store until acknowledged, while later usage stays pending`
- `AuroraMeter.FlusherTest` / `test I01 a graceful shutdown persists pending counters`
- `AuroraMeter.KillTest` / `test I01 a Flusher killed between the snapshot and the persist keeps the batch in Store`
- `AuroraMeter.KillTest` / `test I01 a Store killed before the flush loses the buffered deltas, as documented`
- `AuroraMeter.StorageTest` / `test a batch receipt deduplicates counters and history after unrelated writes`
- `AuroraMeter.ClusterTest` / `test when the database write commits and then reports failure a node that has heard gossip retries its batch without duplicating usage`
- `AuroraMeter.RetentionTest` / `test I01 a receipt is not pruned while a node's heartbeat reports an older pending batch`
- `AuroraMeter.RetentionTest` / `test I01 a receipt is not pruned while a node's heartbeat is itself older than the cutoff`
- `AuroraMeter.RetentionTest` / `test I01 receipts are pruned when every node is idle and current`
- `AuroraMeter.RetentionTest` / `test I01 receipts are pruned when a node has a pending batch newer than the cutoff`
- `AuroraMeter.RetentionTest` / `test I01 a node with no heartbeat row does not block`
- `AuroraMeter.RetentionTest` / `test I01 no heartbeat anywhere blocks a prune that would delete something`
- `AuroraMeter.RetentionTest` / `test I01 an unreadable pending_since blocks rather than being ignored`
- `AuroraMeter.RetentionTest` / `test I01 a heartbeat state this release does not write blocks`
- `AuroraMeter.RetentionTest` / `test I01 forget_node/1 removes the block for exactly one node and leaves the others`
- `AuroraMeter.RetentionTest` / `test I01 a node id containing an @ is handled, which is what every real node id looks like`
- `AuroraMeter.RetentionTest` / `test I01 forget_node/1 refuses a node it has never heard of`
- `AuroraMeter.RetentionTest` / `test I01 a retry of a batch whose receipt was pruned would double count`
- `AuroraMeter.RetentionTest` / `test I01 a retry of a batch whose receipt was protected does not double count`
- `AuroraMeter.StoreGaugeTest` / `test I01 store.gauge reports dirty_keys equal to the dirty table size, and 0 with none`
- `AuroraMeter.StoreGaugeTest` / `test I01 oldest_pending_age_ms is zero while the dirty set is empty and grows once it is not`
- `AuroraMeter.StoreGaugeTest` / `test I01 pending_batch_age_ms grows while a batch is retained and returns to zero on commit`
- `AuroraMeter.StoreGaugeTest` / `test I01 pending_batch_age_ms is zero for a batch map carried across a release with no taken_at_ms`
- `AuroraMeter.FlusherSpanTest` / `test I01 a committed flush emits start, stop with result ok, and the legacy event once each`
- `AuroraMeter.FlusherSpanTest` / `test I01 a flush that fails once and succeeds on retry emits stop result error, then stop result ok`
- `AuroraMeter.FlusherSpanTest` / `test I01 storage that raises emits exception and then the legacy error event`

**Evidence.** `docs/evidence/v1/phase-01/i01.md`

## I02 Counter, day history and receipt update atomically

**Guarantee.** The receipt insert, the counter upsert and the day history upsert
happen inside one repo transaction in the `flush_batch/3` callback of
`AuroraMeter.Storage.Ecto`.
If any statement fails, the whole transaction rolls back, which includes the
receipt, so the batch stays retryable and no partial commercial state is left
behind. There is no state in which a counter moved and its receipt did not, or in
which a period counter moved and its day bucket did not.

**Prerequisites.** The Ecto storage adapter on a transactional database. A host
that calls the Flusher from inside its own transaction inherits that transaction's
fate, which is the documented behaviour rather than a second guarantee.

**Known limits.** Atomicity is per batch, not per track call. The ETS increment
that produced the delta is not part of the transaction and is not rolled back by a
failed flush; it stays pending and is retried. Nothing here promises that the
in-memory view and the database agree between flushes.

**Tests.**

- `AuroraMeter.StatementsTest` / `test I02 a failing receipt insert writes nothing and reaches no later statement`
- `AuroraMeter.StatementsTest` / `test I02 a failing counter upsert rolls back the receipt`
- `AuroraMeter.StatementsTest` / `test I02 a failing history upsert rolls back the counter and the receipt`
- `AuroraMeter.StatementsTest` / `test I02 a retry after a failed statement applies the deltas exactly once`
- `AuroraMeter.FlushBatchConcurrencyTest` / `test I02 an invalid history row rolls back the counter and the receipt`
- `AuroraMeter.ClusterTest` / `test when the database write fails the deltas are kept pending and flushed on the next attempt`

**Evidence.** `docs/evidence/v1/phase-01/i02.md`

## I03 Failed tentative quota work is never billed

**Guarantee.** `AuroraMeter.Entitlements.with_quota/4` reserves quantity as
*reserved* rather than as completed usage: `Counter.reserve/6` with `deferred:
true` raises `value` and `reserved` together, and reserved quantity is excluded
from `pending_flush` and `pending_gossip`, so it is never written to the database
and never gossiped as usage. The wrapped function runs inside a `try/catch` that
catches all three exit kinds (raise, throw and exit), calls
`Counter.release_work/4` and re-raises with the original stacktrace. Only a
function that returns normally reaches `Counter.commit_work/5`, which is the one
place that converts reserved quantity into flushable, billable usage. The period
and the day are captured once, before the callback runs, and both the release and
the commit use those captured values.

**Prerequisites.** Failure must be catchable: a raise, a throw or an exit in the
calling process. The Store must still be alive when the callback finishes, because
`commit_work/5` and `release_work/4` operate on its ETS tables.

**Known limits.** A caller killed with `Process.exit(pid, :kill)` runs no `catch`
clause. The reservation stays in that node's ETS until the Store restarts or the
period rolls over. That leaked reservation occupies local quota, which can refuse
later work, but it is never billed, because reserved quantity is never flushed.
This is a documented local-quota effect, not a billing effect, and the
documentation must not promise cleanup after untrappable termination. The size of
the leak is now measured rather than described: one killed caller leaves exactly
the quantity it reserved in `reserved`, with `pending_flush` at zero, and
`remaining/2` falls by that same quantity (`docs/evidence/v1/phase-01/i03.md`).

A Store restart during the callback is a second known gap: `commit_work/5` and
`release_work/4` do not re-seed a cold key (open finding C6), so a `with_quota`
whose callback outlives a Store crash raises `ArgumentError` at commit instead of
releasing; 03b seeds the row first. The asymmetry is the defect: a deferred
`Counter.reserve/6` on the same cold key does not raise, because
`reserve_pending/2` seeds. `AuroraMeter.KillTest` asserts the current behaviour
so 03b has a before and after.

The period-crossing half of this invariant is partial until 02c. Core has no
clock seam, so the test reserves and commits against an explicitly chosen
`period_start` and day rather than letting the callback run across a real
midnight; 02c introduces the seam and owns the full `with_quota` crossing test.

**Tests.**

- `AuroraMeter.EntitlementsTest` / `test I03 a callback that flushed and then raises is not billed`
- `AuroraMeter.EntitlementsTest` / `test I03 a callback that flushed and then throws is not billed`
- `AuroraMeter.EntitlementsTest` / `test I03 a callback that flushed and then exits is not billed`
- `AuroraMeter.EntitlementsTest` / `test I03 a reservation is never in a flush batch`
- `AuroraMeter.EntitlementsTest` / `test I03 a reservation committed against a captured day lands in that day's bucket (partial until 02c)`
- `AuroraMeter.KillTest` / `test I03 a with_quota caller killed with :kill is never billed and leaves a documented reservation`
- `AuroraMeter.KillTest` / `test I03 Counter.commit_work after a Store restart seeds rather than raising (C6, fixed in 03b)`
- `AuroraMeter.ExamplesTest` / `test team-saas.md with_quota/3 gives the reservation back when the work raises`
- `AuroraMeter.FeatureSourceTest` / `test with_quota over an events-source feature I03 with_quota releases its reservation on success and leaves the recorded quantity`
- `AuroraMeter.FeatureSourceTest` / `test with_quota over an events-source feature I03 with_quota over an events-source feature bills nothing when the callback records nothing`
- `AuroraMeter.FeatureSourceTest` / `test with_quota over an events-source feature I03 with_quota over an events-source feature releases on a raise, a throw and an exit`
- `AuroraMeter.FeatureSourceTest` / `test with_quota over an events-source feature I03 a killed with_quota caller over an events-source feature bills nothing`

The three catchable-failure cases that give the capacity back (a raise, a throw
and an exit) are named under I04, whose guarantee is the one they measure.

The last four are build unit 03c's contribution. For a feature whose reporting
source is `:events` the success path releases the reservation instead of
committing it, so "failed tentative work is never billed" is joined by
"successful tentative work is not billed either": the charge is the event the
callback recorded, and the reservation was only ever the gate in front of it.
The killed-caller case is the same documented leak as above, asserted again on
this path because releasing rather than committing is the change that could have
introduced a new one.

**Evidence.** `docs/evidence/v1/phase-01/i03.md`

## I04 A local hard quota cannot oversubscribe completed plus pending work

**Guarantee.** `Counter.reserve/6` performs a single `:ets.update_counter/3`, which
is atomic and lock free, and compares the resulting value against the limit. The
value it compares includes both completed usage and outstanding reservations,
because a deferred reserve raises `value` as well as `reserved`. When the result
exceeds the limit the increment is undone on the same path (a plain bump is
reversed with `bump(key, -qty)`, a deferred one with `release_work/4`) and the
caller gets `{:error, :limit_exceeded}`. Concurrent callers racing for the last
unit therefore admit exactly the number of units the cap allows on that node, and
a refused reserve leaves the counter exactly where it was.

**Prerequisites.** A `:hard` limit declared for the feature in the resolved plan.
The guarantee is per node and is evaluated against that node's view of the
cluster-wide total.

**Known limits.** The cap is enforced against the local view, not a global lock.
On a cluster, a burst spread over N nodes can exceed the cap by what the other
N minus 1 nodes admitted within one `:broadcast_interval`. Aurora Meter does not
claim a strict global quota. A `:metered` feature is never refused by design, and
a `:counter` feature has no denominator at all, so neither participates in this
invariant.

A caller killed with `:kill` keeps its reservation, so the cap it was counted
against stays that much smaller on that node until the Store restarts or the
period rolls. That is a real cost of the D09 trade and it is measured, not
estimated: see I03's known limits and
`docs/evidence/v1/phase-01/i04.md`.

**Tests.**

- `AuroraMeter.EntitlementsTest` / `test I04 sixty concurrent with_quota calls against a limit of fifty admit exactly fifty on one node`
- `AuroraMeter.EntitlementsTest` / `test I04 a raising callback releases its capacity`
- `AuroraMeter.EntitlementsTest` / `test I04 a throwing callback releases its capacity`
- `AuroraMeter.EntitlementsTest` / `test I04 an exiting callback releases its capacity`
- `AuroraMeter.MeteringTest` / `test I04 Counter.reserve blocks at the hard limit and rolls the increment back`
- `AuroraMeter.KillTest` / `test I04 a killed caller's reservation continues to occupy the limit on that node`
- `AuroraMeter.ExamplesTest` / `test team-saas.md with_quota/3 admits exactly the cap under concurrency`
- `AuroraMeter.EntitlementsTest` / `test check/2 blocks a hard cap at the limit`
- `AuroraMeter.FeaturePolicyTest` / `test I04 denial under :deny never reserves`
- `AuroraMeter.FeaturePolicyTest` / `test I04 declared-feature reservation is policy-invariant`
- `AuroraMeter.FeatureSourceTest` / `test with_quota over an events-source feature I04 with_quota over an events-source feature admits exactly the limit of concurrent callers`

The last one is build unit 03c's, and it measures a different quantity from the
others, which is why it is worth stating rather than assuming. For a buffered
feature the cap counts calls, because an admitted call keeps its unit for the
period. For an events-source feature the reservation is released on success, so
the cap counts what is **in flight at once** plus whatever has been durably
recorded. Fifty-five callers held inside their callbacks admit exactly fifty; the
same fifty-five run to completion recording nothing consume nothing, and that is
correct rather than a hole, because nothing was used.

The two before it are build unit 02b's contribution: `:undeclared_feature_policy` adds
a branch in front of the reservation, so the guarantee above now also has to say
that a denied call takes no capacity and that a declared feature's reservation
behaves the same under all four policy values.

**Evidence.** `docs/evidence/v1/phase-01/i04.md`

## I05 Cluster guarantees match documented limitations

**Guarantee.** Two loops converge the nodes and both are bounded.
`AuroraMeter.Broadcaster` publishes each node's `pending_gossip` on the
`aurora_meter:cluster` topic every `:broadcast_interval`, and receiving nodes add
those deltas to their own view; a node's own messages are ignored. Every flush
writes deltas (not absolute values) and re-bases on the totals the database
returns, then announces them, so anything gossip dropped heals within one
`:flush_interval`. `Counter.rebase/3` applies an announcement only upward, so a
late announcement never drags a fresher view backwards, while a node's own flush
re-bases unconditionally. Because flushes add deltas rather than overwrite, the
persisted row after every node has flushed equals the sum of every increment on
every node.

**Prerequisites.** A distributed `Phoenix.PubSub` and `cluster_sync: true` (the
default). With `cluster_sync: false`, or a non-distributed PubSub, every node
keeps its own counters and the convergence claims do not apply; a single node is
unaffected either way.

**Known limits.** Reads are eventually consistent: `AuroraMeter.usage/2` on any
node can be short by what the other nodes added in the last `:broadcast_interval`,
or one `:flush_interval` if a PubSub message was dropped. Hard limits are enforced
locally, so overshoot is bounded but not zero (see I04). Losing a Store or a VM
loses that node's usage since its last successful flush, and an outage makes that
window longer than one interval. Aurora Meter does not claim no buffered loss.

The overshoot bound is measured rather than reasoned about: with a hard limit of
50 and one peer's admissions in flight, the local node admits up to its own view,
so the total admitted across the cluster exceeds the limit by at most what the
other nodes admitted since the announcement this node last applied. The scripted
interleaving and the number it produced are in
`docs/evidence/v1/phase-01/i05.md`; 08c re-measures it under load.

The simulations are single-VM: `AuroraMeter.Cluster.apply/3` is driven directly,
which exercises `handle_batch/3`, `Counter.apply_remote/2` and `Counter.rebase/3`
exactly as a received PubSub message would, and delay and loss are scripted by
withholding or dropping a call. It does not exercise `Phoenix.PubSub` itself, a
netsplit or a real rejoin; a multi-node harness is 11d's.

**Tests.**

- `AuroraMeter.ClusterTest` / `property two writers I05 final database total equals the sum of all deltas and the local view matches it`
- `AuroraMeter.ClusterTest` / `test total announcements from another node I05 a totals announcement never moves a view backwards`
- `AuroraMeter.ClusterConvergenceTest` / `test I05 two nodes with delayed gossip converge after a flush`
- `AuroraMeter.ClusterConvergenceTest` / `test I05 two nodes with lost gossip converge after a flush`
- `AuroraMeter.ClusterConvergenceTest` / `test I05 four nodes with mixed delayed and lost gossip converge after every node has flushed`
- `AuroraMeter.ClusterConvergenceTest` / `test I05 overshoot is bounded by what other nodes admitted between announcements`
- `AuroraMeter.ClusterTest` / `test two writers flushes add up in the database instead of overwriting`
- `AuroraMeter.ClusterTest` / `test two writers a seed that races another node's flush heals on the announcement`
- `AuroraMeter.ClusterTest` / `test gossip from another node moves this node's view without making the delta ours to flush`
- `AuroraMeter.ClusterTest` / `test configuration publishing with sync off is a no-op`
- `AuroraMeter.FeatureSourceTest` / `test projection, seeding and the cluster I05 a peer's projected delta moves this node's value and a cold reseed corrects it`
- `AuroraMeter.FeatureSourceTest` / `test projection, seeding and the cluster I05 a peer's totals announcement never rebases an events-source key`
- `AuroraMeter.ClusterLagTest` / `test I05 cluster.lag reports peers seen and since_last_message_ms after remote batches`
- `AuroraMeter.ClusterLagTest` / `test I05 a peer not heard from for ten broadcast intervals leaves the peer map`
- `AuroraMeter.ClusterLagTest` / `test I05 a pruned peer is removed from the state and not merely from the report`
- `AuroraMeter.ClusterLagTest` / `test I05 unreconciled_keys counts keys carrying peer value and falls to zero after a rebase`
- `AuroraMeter.ClusterLagTest` / `test I05 unreconciled_keys is omitted above the scan ceiling, never reported as zero`
- `AuroraMeter.ClusterLagTest` / `test I05 no lag event is emitted at all when cluster_sync is false`

The last two are build unit 03c's contribution, and the convergence story for an
events-source feature is the easier one: the durable total is shared state, so a
node that is cold for the key reads every node's events in one query rather than
waiting for gossip. A projected delta still gossips, so warm peers move within a
`:broadcast_interval`, and nothing ever rebases the key, because no node puts it
in a flush batch and `Cluster`'s totals branch refuses an announcement that would
move a key backwards.

**Evidence.** `docs/evidence/v1/phase-01/i05.md`

## I06 Durable accepted events survive process loss without duplication

**Guarantee.** Today the core writes a durable event row on `track/4` when the
feature is marked `:durable` or listed in `:durable_features`, through
`AuroraMeter.Storage.insert_events/1`. A committed event row is on disk and
survives the loss of the process that wrote it. The stronger half of this
invariant, that an accepted event is recorded exactly once across a kill before
commit, a kill after commit before reply, and a same identity retry, is the
subject of the durable events work in phase 03 and is not guaranteed by the
current code.

**Prerequisites.** The Ecto storage adapter and schema version 4 or later (the
`aurora_meter_events` table). The feature must be durable, per call or by
configuration.

**Known limits.** The current durable insert happens after the ETS bump, outside a
transaction and without a rescue, so inside a host transaction the row can roll
back while the ETS increment stays (open finding C14). The `track/4` path still
has no caller identity and therefore no deduplication on retry: build unit 03a
gives each of its rows a freshly generated `track:` identity so the column can be
`NOT NULL`, which satisfies the database and changes nothing about retries, and a
caller that retries a durable `track/4` still writes a second row.
`AuroraMeter.record/4` (03b) is the path that deduplicates. Event quantity is no
longer a 32 bit column: core schema version 7 widened it to `bigint` (open
finding C13, closed by 03a). The rest are named so that a reader cannot mistake
the current behaviour for the phase 03 guarantee.

**Tests.**

- `AuroraMeter.MeteringTest` / `test a durable feature writes an event row on track`
- `AuroraMeter.StorageTest` / `test insert_events/1 appends rows`
- `AuroraMeter.MigrationV8Test` / `test one identity, one fact I06 two inserts of the same (tenant_key, event_id) leave exactly one row`
- `AuroraMeter.MigrationV8Test` / `test one identity, one fact I06 the same event_id under two tenants is two facts`
- `AuroraMeter.RecordTest` / `test identity I06 a retry with the same id and payload is a duplicate with no second effect`
- `AuroraMeter.RecordTest` / `test identity I06 the same id in two tenants creates two events`
- `AuroraMeter.RecordBatchTest` / `test I06 a storage failure mid-batch rolls back every new row`
- `AuroraMeter.RecordConcurrencyTest` / `test one identity, twelve connections I06 12 independent connections submitting one identity create one fact, one totals delta and one outbox item`
- `AuroraMeter.RecordConcurrencyTest` / `test one identity, twelve connections I06 concurrent distinct ids in one tenant and period produce one totals row with the exact sum`
- `AuroraMeter.RecordConcurrencyTest` / `test process death I06 killing the caller before commit leaves no row, no delta, no outbox item and no ETS delta`
- `AuroraMeter.RecordConcurrencyTest` / `test process death I06 killing the caller after commit before the reply leaves exactly one row, and the same-id retry returns duplicate without a second delta or outbox item`
- `AuroraMeter.RecordConcurrencyTest` / `test generations I06 a record transaction in flight blocks generation activation and completes against the generation it read`
- `AuroraMeter.RecordProjectionTest` / `test a host's own transaction I06 an outer host transaction rollback leaves no event, no totals delta, no outbox item and no ETS delta`
- `AuroraMeter.RecordProjectionTest` / `test a host's own transaction I06 an outer host transaction commit plus after_commit/1 hydrates ETS and publishes one message`
- `AuroraMeter.CorrectConcurrencyTest` / `test process death I06 killing a corrector before commit leaves no row, no delta and no outbox item`
- `AuroraMeter.CorrectConcurrencyTest` / `test process death I06 killing a corrector after commit before the reply leaves exactly one of each and the retry is a duplicate`
- `AuroraMeter.EventsReplayTest` / `test I06 restart and replay reproduce the same totals`
- `AuroraMeter.EventsReplayTest` / `test the announcement I06 the announcement waits for an in-flight record transaction`
- `AuroraMeter.EventsReplayTest` / `test the scan I06 a rebuilt generation reproduces the live totals for usage events`
- `AuroraMeter.EventsReplayTest` / `test the scan I06 the scan is bounded by the watermark and the tail arrives by the dual write`
- `AuroraMeter.EventsReplayTest` / `test the comparison I06 require_match refuses to activate when a difference exists`
- `AuroraMeter.EventsReplayLargeTest` / `test I06 100,000 facts and corrections replay to exact totals after a kill and a restart`
- `AuroraMeter.EventsReplayLargeTest` / `test I06 a replay interleaved with 12 concurrent recorders reproduces exact totals`
- `AuroraMeter.EventsReplayLargeTest` / `test I06 a replay interrupted at the activation leaves a consistent state either way`
- `AuroraMeter.PlanAttributionTest` / `test I06 a retry of one event_id across a plan change is a duplicate and keeps the first stamp`

**Evidence.** `docs/evidence/v1/phase-03/i06.md`

## I07 Conflicting reuse of event identity is rejected

**Guarantee.** Not yet guaranteed end to end. The *mechanism* ships in core
schema version 8 (build unit 03a): a unique index on `(tenant_key, event_id)`
with `event_id`, `payload_hash` and `occurred_at` `NOT NULL`, so a second row
under one identity is refused by the database rather than by application code,
on any connection and in any order. What does not ship yet is the facade that
turns that refusal into a result a caller can act on and that tells a duplicate
from a conflict by comparing the payload hash. Phase 03b adds it, after which
reusing an identity with a changed quantity, timestamp, feature, dimension set
or metadata is rejected rather than silently accepted or silently ignored,
including under same tenant races and inside batches, where a single conflict
rolls the batch back.

**Prerequisites.** The phase 03 durable event path, the Ecto storage adapter and
the schema version that adds the event identity constraint.

**Known limits.** The database now refuses a duplicate identity, but nothing in
the facade yet turns that refusal into a result a caller can act on, and
`AuroraMeter.track/4` generates a fresh identity per call, so on that path there
is still no identity to conflict with. Until 03b lands, a host that needs this
must deduplicate before calling `track/4`. A guarantee statement must not be
copied from this section into customer-facing documentation before its tests
exist.

**Tests.**

- `AuroraMeter.MigrationV8Test` / `test it refuses rather than guess I07 it refuses while any event_id is null, and names the count`
- `AuroraMeter.MigrationV8Test` / `test it refuses rather than guess I07 it runs once the backfill has filled them`
- `AuroraMeter.MigrationV8Test` / `test it refuses rather than guess I07 it promotes event_id, payload_hash and occurred_at to NOT NULL`
- `AuroraMeter.RecordTest` / `test validation, before any database call I07 record rejects a missing id, an oversized id and a reserved prefix`
- `AuroraMeter.RecordTest` / `test validation, before any database call I07 record rejects a non-UTF-8 id`
- `AuroraMeter.RecordTest` / `test the canonical payload I07 canonical json sorts keys recursively`
- `AuroraMeter.RecordTest` / `test the canonical payload I07 map key ordering does not change the payload hash`
- `AuroraMeter.RecordTest` / `test identity I07 a changed quantity, occurred_at, feature, dimension or metadata value each conflict`
- `AuroraMeter.RecordTest` / `test identity I07 the same id for two features in one tenant conflicts`
- `AuroraMeter.RecordBatchTest` / `test I07 repeated ids with identical payloads collapse to one insert and two ordered results`
- `AuroraMeter.RecordBatchTest` / `test I07 repeated ids with different payloads are rejected before any I/O`
- `AuroraMeter.RecordBatchTest` / `test I07 a conflicting element rolls back every new row in the batch`
- `AuroraMeter.RecordConcurrencyTest` / `test one identity, twelve connections I07 12 independent connections submitting one identity with two different payloads never produce two rows`
- `AuroraMeter.CorrectTest` / `test identity I07 a correction id reused with a different magnitude conflicts`
- `AuroraMeter.CorrectTest` / `test identity I07 a correction id reused with different metadata conflicts`
- `AuroraMeter.RecordTest` / `property the canonical encoder, as a property I07 two different payloads never share an encoding, and key order never changes one`

**Evidence.** `docs/evidence/v1/phase-03/i07.md`

## I08 One input source yields one commercial usage effect

**Guarantee.** Every feature has exactly one reporting source, declared as
`feature_sources: %{name => :buffered | :events}` and defaulting to `:buffered`.
The guarantee is negative and is discharged by closing every route from a durable
event into `aurora_meter_counters`, which is the only table a Pro reporter bills
from (`AuroraMeter.Pro.UsageReporter.report_one/5` reads it through
`AuroraMeter.Storage.load_counter/3`).

Three writers can put a quantity into that table, and each is closed for an
events-source feature. `AuroraMeter.track/4` raises before resolving the tenant
key, so nothing partial is left. `AuroraMeter.reserve/2,3` raises for the same
reason one function deeper: it takes the non-deferred path, which bumps
`pending_flush` immediately. `AuroraMeter.Entitlements.with_quota/4` releases its
reservation on success instead of committing it, so the reservation stays
admission control and the recorded event stays the charge. What remains is
`Counter.apply_projection/2`, which writes `value` and `pending_gossip` and
neither `pending_flush` nor the dirty table, so a projected quantity cannot enter
`AuroraMeter.Store`'s flush-batch snapshot and therefore cannot reach
`AuroraMeter.Storage.flush_batch/3`.

A declaration that would make the question ambiguous is refused at boot: a
feature listed in both `:durable_features` and `:feature_sources` as `:events`
raises from `AuroraMeter.Config.validate!/0`, and therefore from
`AuroraMeter.start_link/1`.

**Prerequisites.** A single configured source per feature, decided at a period
boundary and applied by a deploy: the source is read from a cache that
`AuroraMeter.Config.validate!/0` fills, so changing it at runtime changes nothing until the
node is validated again. While both paths exist, the host must not also bill from
the event log by hand.

**Known limits.** Nothing prevents a host from reading `aurora_meter_events` and
billing it in addition to the counters; the invariant covers what this library
writes, not what a host does with the rows afterwards. Pro rollups do read
durable events directly when `history: false` (open finding C15), which is a
reporting read rather than a billing read.

An events-source feature has no day history at all, and
`AuroraMeter.history/3` returns zeros for one. That is deliberate: a projected
quantity in `aurora_meter_history` would feed the Pro day rollup from the same
units the outbox exports. `AuroraMeter.Events.stream/1` is the durable series.

The migration from `:buffered` to `:events` is the half core cannot make safe on
its own. Core refuses a dual declaration but has no way to know whether a
feature's existing counter rows were ever reported to a provider, so nothing here
stops a host flipping a source mid-period and leaving that period's usage split
across a counter row and an event total. The watermark, the boot refusal when
`usage_reports` rows exist without a cutover, and the tests for both are Pro's
(build unit 04c) and are evidenced in Pro; there is deliberately no planned core
test for them, because core has no `usage_reports` table to refuse against.

**Tests.**

- `AuroraMeter.MeteringTest` / `test a durable feature writes an event row on track`
- `AuroraMeter.RecordProjectionTest` / `test I08 the projection never reaches the flush path I08 a projected event never appears in a flush batch`
- `AuroraMeter.RecordProjectionTest` / `test I08 the projection never reaches the flush path I08 apply_projection writes value and gossip but never pending_flush or dirty`
- `AuroraMeter.FeatureSourceTest` / `test configuration I08 declaring a feature in durable_features and as an events source fails at boot`
- `AuroraMeter.FeatureSourceTest` / `test the track and reserve guards I08 track/4 raises for an events-source feature and writes nothing`
- `AuroraMeter.FeatureSourceTest` / `test the track and reserve guards I08 track/4 with durable: true raises for an events-source feature and writes no row`
- `AuroraMeter.FeatureSourceTest` / `test the track and reserve guards I08 reserve/2 and reserve/3 raise for an events-source feature and write nothing`
- `AuroraMeter.FeatureSourceTest` / `test flush isolation I08 a thousand recorded events reach no flush batch, no counter row and no reporter read`
- `AuroraMeter.FeatureSourceTest` / `test flush isolation I08 one flush writes the buffered feature and not the events-source one`
- `AuroraMeter.EventsReplayTest` / `test side effects I08 a replay enqueues nothing, grants nothing, notifies nothing and flushes nothing`

**Evidence.** `docs/evidence/v1/phase-03/i08.md`

## I09 Corrections preserve immutable history and bounded net quantity

**Guarantee.** `AuroraMeter.correct/4` appends a new immutable event that reduces
an earlier one; no historical row is ever updated or deleted. The cumulative
magnitude of the corrections of one original can never exceed that original's
quantity, checked while the original row is held under `SELECT ... FOR UPDATE`,
so concurrent correctors of one fact cannot between them credit more than was
charged. A repeated correction id is a duplicate rather than a second credit,
including when the original is by then fully corrected, because the duplicate
check precedes the bound check both before and under the lock. A correction
inherits the original's feature, period, period source, plan attribution and
dimensions, so it changes the invoice the original was on. A correction of a
correction is refused. Every correction is handed to the export seam with an
explicit eligibility reason and none is dropped. `AuroraMeter.replace/4` writes
a full reversal and a replacement in one transaction, idempotent under one
caller id.

**Prerequisites.** Core schema version 7 or later (`kind`, `original_event_id`,
the pairing check constraint and the corrections partial index) and a storage
adapter declaring the `:corrections` capability. The in-memory view of a
corrected key is advisory as always; `AuroraMeter.Events.total/3` is
authoritative.

**Known limits.** Core records a correction it cannot know is deliverable.
Whether a meter event can still be adjusted at a payment provider is Aurora
Meter Pro's decision (build unit 04d), which quarantines the ones that cannot
with a `manual_adjustment` reconciliation item; core's contribution is that the
item always exists and carries a reason. The legacy negative `track/4` still
exists for buffered features, mutates the counter in place and is bounded by
nothing; hosts using it keep their own audit trail. Corrections of corrections
are not supported in 1.0.

**Tests.**

- `AuroraMeter.ExamplesTest` / `test allowance-and-overage.md a negative track/3 corrects an overcount`
- `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a correction reduces the projected total by its magnitude`
- `AuroraMeter.CorrectTest` / `test the cumulative bound I09 cumulative corrections cannot exceed the original`
- `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a full reversal then a further correction is rejected`
- `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a duplicate correction id is idempotent`
- `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a duplicate correction id is idempotent even when the original is already fully corrected`
- `AuroraMeter.CorrectTest` / `test identity I09 a correction to a correction is rejected`
- `AuroraMeter.CorrectTest` / `test inside a host transaction I09 a refusal does not roll back the host's transaction`
- `AuroraMeter.CorrectTest` / `test the in-memory projection I09 the ETS projection subtracts and never shows a negative value`
- `AuroraMeter.CorrectTest` / `test the in-memory projection I09 a correction whose magnitude exceeds this node's view re-seats it from the durable total`
- `AuroraMeter.CorrectTest` / `test replay arithmetic I09 recomputing every total from the event rows reproduces the projection exactly`
- `AuroraMeter.CorrectConcurrencyTest` / `test twelve correctors of one original I09 12 concurrent partial corrections of one 10-unit original never exceed it`
- `AuroraMeter.CorrectConcurrencyTest` / `test twelve correctors of one original I09 12 concurrent submissions of one correction identity produce one row, one delta and one outbox item`
- `AuroraMeter.CorrectConcurrencyTest` / `test twelve correctors of one original I09 concurrent corrections of two different originals in one key both commit`
- `AuroraMeter.CorrectConcurrencyTest` / `test twelve correctors of one original I09 the lock that serialises correctors is the one on the original row`
- `AuroraMeter.EventsReplayTest` / `test the scan I09 a correction contributes a negative quantity and a positive event count`
- `AuroraMeter.EventsReplayTest` / `test a correction while a generation is building I09 a correction for an unscanned original commits and lands in both generations`
- `AuroraMeter.PlanAttributionTest` / `test I09 a correction copies the original's plan_id, plan_version and attribution`

The provider half of I09, "a correction after the provider window opens a
reconciliation item instead of silently diverging", is Aurora Meter Pro's and is
evidenced in Pro (build unit 04d). It is deliberately not a planned bullet here:
core has no provider window and no reconciliation table to refuse against, so no
core test could ever resolve one, and a bullet that can never be promoted is a
guard that can never fire. **04d must read this paragraph.**

**Evidence.** `docs/evidence/v1/phase-03/i09.md`

## I10 Every ledger amount has exact provenance and conservation

**Guarantee.** Every credit movement is an append to `aurora_meter_credit_transactions`
inside the same transaction that updates the balance row, and every entry records
what the promotional figure became, so any balance can be reconstructed by
replaying its entries. Amounts are integer micro-dollars throughout, so no
rounding happens inside the ledger; conversion to and from cents and decimal
dollars is explicit in `AuroraMeter.Credits.Money`. A refusal is returned rather
than rolled back, so a host that wraps a ledger call in its own transaction keeps
its own writes when the ledger says no. The ledger re-establishes
`0 <= promotional <= max(balance, 0)` after every entry, which is what lets
`expire_due/1` never push a balance below zero. Side effects (telemetry, PubSub,
the low balance hook) run only after the transaction commits, so a handler never
sees a balance that later rolled back. Each of those figures is checked against an
independent pure model after **every** command of a generated history, not only at
the end, together with six conservation aggregates read straight from SQL: balance
against the sum of every entry's amount, held against both the sum of every
`held_delta` and the reservations of the holds still open, the promotional bound,
the newest entry's three snapshot columns against the balance row, reference
uniqueness per kind, and hold closure.

**Prerequisites.** The Ecto storage adapter on PostgreSQL and schema version 3 or
later. Credits do not work through a non-Ecto storage adapter, because the ledger
needs a row lock plus an append in one transaction. The property tests below rest
on a second prerequisite of their own: `AuroraMeter.Test.LedgerModel` is an
independent reimplementation of the ledger's arithmetic, and it is only an oracle
while it is right. Thirteen self-tests in `AuroraMeter.CreditsModelTest` (the
describe blocks `the model itself` and `the dormant lot view`, all of which run
without a database) pin it against cases whose answer is obvious without reading
either implementation. They deliberately do **not** claim an invariant id: they
prove the model, not the ledger.

**Known limits.** Conservation is behavioural today: it is re-established by the
allocator after each entry rather than refused by a database constraint. Phase 06
adds lot rows with check constraints, after which the database itself rejects a
violating row. The index must state both strengths, because the guarantee before
the lot cutover is weaker than the guarantee after it: today's form is "the
ledger's arithmetic matches an independent model", and the stronger form, "a
write that breaks conservation is rolled back", only exists after 06a. The
Evidence path below names the proof that exists today; 06a's will be
`docs/evidence/v1/phase-06/i10.md`. `expire_due/1` assumes at most one live
promotional grant per tenant.

"After the transaction commits" means after the **outermost** transaction
commits, and from build unit 06c that is enforced rather than assumed. A ledger
call made inside a host's own transaction sees a savepoint release, not a commit,
so its telemetry, PubSub and low-balance effects are queued on the calling
process and run by `AuroraMeter.Credits.after_commit/1`; the rollback branch calls
`after_commit(discard: true)` and nothing fires at all (finding L18, closed).

The queue is process bound, which is where Ecto's transaction scope lives, so the
two have the same lifetime and neither can outlive the other. The limit that
follows is stated rather than hidden: a process that dies between the commit and
the drain loses that round of effects. The money is committed and correct; one
telemetry event, one PubSub message and possibly one low-balance alert are not
delivered. `AuroraMeter.Credits.deferred_effects?/0` is how a host asserts in its
own tests that no path forgot the call.

Three further limits the generated histories exposed, each with a test that
asserts today's behaviour so its fixing unit has a before and an after:

- **L17**: closed by build unit 06c. `AuroraMeter.Credits.Money.assert_range!/1`
  refuses an amount beyond 9e15 micro-dollars, and `grant/3`, `hold/4`,
  `debit/4`, `reverse/4`, `settle/3` and `set_low_balance_threshold/2` all call it
  before any database work, so the caller gets an `ArgumentError` naming the limit
  rather than a `DBConnection.EncodeError` from the driver two layers down. The
  limit is three orders of magnitude below the `bigint` ceiling because
  `balance_after` and the conservation aggregate are sums of amounts.
- **L19**: `expire_due/1` selects the due grant ids with no `order_by`
  (`ledger.ex:251-259`) while `expire_locked/3` clamps each grant by the wallet as
  it stands when its turn comes, so two grants due in one pass can expire
  different amounts on two runs of the same history. The property generator
  therefore never produces more than one due grant; one named test records the
  ambiguity and asserts only the total. 06a adds the D07 order.
- **L20**: the ledger stamps `inserted_at` from the host wall clock
  (`ledger.ex:452`) and then orders its own account of what happened first by that
  column, in `remaining_on_grant/3` (`:345`), `pending_holds/1` (`:63`) and
  `history/2`. A wall clock is not monotonic. Backwards steps were observed
  unprompted on 2026-09-14, three times in one 500-history run and five in
  another, and each leaves a promotional grant the expirer believes is untouched
  and can then never finish. 06a must order by something the database controls
  rather than by a stamp.

`expire_due/1`'s own documentation used to say expiry assumes at most one live
promotional grant, which contradicted `AuroraMeter.Credits.Promotions`'s
soonest-expiry-first attribution. The model implemented the code and the doc was
wrong; build unit 06c corrected the doc (finding L15, closed). Several live
promotional grants are supported, each grant's remainder is well defined, and the
first to expire cannot reclaim credit a later one contributed.

**Tests.**

- `AuroraMeter.CreditsTest` / `test the ledger as a record every entry says what the promotional figure became`
- `AuroraMeter.CreditsTest` / `test promotional credit is consumed before paid credit`
- `AuroraMeter.CreditsTest` / `property Money cents round-trip through micro-dollars`
- `AuroraMeter.CreditsTest` / `test Money rounding modes and precision`
- `AuroraMeter.CreditsTest` / `test history/2 is newest first, hides holds and releases by default, filters by kind and pages`
- `AuroraMeter.CreditsConcurrencyTest` / `test I10 a refusal does not destroy the caller's own transaction`
- `AuroraMeter.CreditsConcurrencyTest` / `test I10 a host transaction that rolls back emits nothing, because the side effects were deferred (L18)`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 a generated history of grants, holds, settles, releases, debits and reversals matches the pure model`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 a generated history including expiry matches the pure model`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 balance equals the sum of every transaction amount after every step`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 held equals the sum of open holds after every step`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 the newest row's snapshot columns equal the balance row`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 no two rows of one kind share a reference`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 cents round-trip through micro-dollars at the boundaries`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 to_cents rounds half away from zero at the boundaries`
- `AuroraMeter.CreditsRegressionsTest` / `test every saved seed file parses and names an invariant`

The first three of the five below were the "before" halves of findings L17 and
L18 and are now the "after" halves: build unit 06c added `Money.assert_range!/1`
at the facade and deferred the side effects of a ledger call made inside a host
transaction. The last two still assert a defect rather than a guarantee, and each
names the unit that replaces it:

- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 a grant above the documented limit is refused at the facade, not by the driver (L17)`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 a reversal above the documented limit is refused at the facade, not by the driver (L17)`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 the range guard refuses before any database work (L17)`
- `AuroraMeter.CreditsModelTest` / `test ordering the query does not fix I10 two grants due in one pass expire in an order the query does not fix (L19, fixed in 06a)`
- `AuroraMeter.CreditsModelTest` / `test the clock the ledger orders itself by I10 a backwards step in the wall clock changes nothing, because the ledger orders by seq (L20, fixed in 06a)`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 the spend order is promotional, then earliest expiry, then oldest grant, then seq`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 a 6 USD debit against promotional A=3, promotional B=5 and paid P=10 takes A=3 and B=3`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 a lot past its expires_at is not eligible for a debit and is not consumed`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 a grant while debt is outstanding repays the debt before creating availability`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 settle below the reservation consumes the reserved subset and unreserves the rest`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 settle above the reservation consumes remaining availability then records debt`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 reverse takes available, then consumed, then reserved, and only consumed creates debt`
- `AuroraMeter.Credits.AllocatorTest` / `test I10 restore is capped by the lot's reversed amount and repays debt first`
- `AuroraMeter.Credits.AllocatorTest` / `property I10 every planned movement conserves: each lot's five buckets still sum to its amount`
- `AuroraMeter.CreditsLotsTest` / `test I10 a grant writes one lot whose quantities, state and reference match the ledger row`
- `AuroraMeter.CreditsLotsTest` / `test I10 a 6 USD debit against promotional A=3, promotional B=5 and paid P=10 takes A=3 and B=3`
- `AuroraMeter.CreditsLotsTest` / `test I10 every lot quantity is reproduced by folding that lot's allocations`
- `AuroraMeter.CreditsLotsTest` / `test I10 a settle stamps hold_transaction_id and updated_at on both rows`
- `AuroraMeter.CreditsLotsTest` / `test I10 a lot edited by hand is refused by aurora_meter_credit_lots_conservation_check`
- `AuroraMeter.CreditsLotsTest` / `test I10 a balance row edited by hand raises ConservationError and the write is rolled back`
- `AuroraMeter.CreditsLotsTest` / `test I10 a settle above its hold records debt, which blocks a new hold until a grant repays it`
- `AuroraMeter.CreditsLotsTest` / `test I10 credit past its expires_at is not spendable before the sweep reaches it`
- `AuroraMeter.CreditsLotsTest` / `test I10 a wallet with lots_enabled_at null uses the legacy arithmetic and writes no lot`
- `AuroraMeter.CreditsLotsTest` / `test I10 enable_lots! refuses a wallet that has a ledger row rather than cutting it over`
- `AuroraMeter.CreditsLotsTest` / `test I10 the balance row refuses a negative held, which nothing enforced before version 9`
- `AuroraMeter.CreditsLotsTest` / `test I10 a grant's :source lands on the lot, which is how a refund finds the payment`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot takes only the lots matching the source`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot above the cap returns exceeds_source and writes nothing`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot of a spent lot raises debt by the unrecoverable amount`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 restore_lot is capped by the lots' reversed total`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 restore_lot repays outstanding debt before any of it becomes spendable`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot and restore_lot are idempotent on the reference`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot with no matching lots returns no_matching_lots`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 reverse_lot writes one reverse allocation per lot touched`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 the :source option is validated rather than widened`
- `AuroraMeter.CreditsLotReversalTest` / `test I10 a reversal that reaches a reservation takes it last and leaves held consistent`
- `AuroraMeter.CreditsLotsTest` / `property I10 a generated history on a lot wallet reconstructs the balance row, the debt, the held amount and every lot's allocations`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 a writer killed before the ledger row is inserted leaves the wallet untouched`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 a writer killed after the ledger row and before the allocations leaves the wallet untouched`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 a writer killed after the allocations and before the lot update leaves the wallet untouched`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 a writer killed after the lot update and before the balance update leaves the wallet untouched`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 a writer killed after commit, before its reply, leaves exactly one effect and no second one on retry`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 the control: with no fault armed the same writer completes and the wallet moves`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 forcing the allocation insert to fail leaves the lot and the balance untouched`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 forcing the lot update to fail leaves the ledger row uncommitted`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 forcing the balance update to fail rolls back the allocations`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 forcing the new lot's insert to fail leaves the grant uncommitted`
- `AuroraMeter.CreditsLotsFaultsTest` / `test I10 the fault control: the same three statements without a fault all commit together`
- `AuroraMeter.CreditsModelTest` / `property I10 a generated history on a cut-over wallet agrees with 01e's independent lot model, lot for lot`
- `AuroraMeter.CreditsModelTest` / `test I10 the cross-oracle comparison can fail: a lot bucket moved by hand is caught`
- `AuroraMeter.CreditsLotsConcurrencyTest` / `test I10 concurrent grants and debits on one wallet leave the projection exact`
- `AuroraMeter.CreditsLotMigrationTest` / `test I10 the cutover stamps projection_checked_at, which only the conservation check writes`

- `AuroraMeter.CreditsTest` / `test I10 a reverse and a debit may share one reference (L2)`
- `AuroraMeter.CreditsTest` / `test I10 a reversal written before V9 still reads as a reversal`
- `AuroraMeter.CreditsTest` / `test I10 a grant whose reference belongs to another tenant returns duplicate_reference (L3)`
- `AuroraMeter.CreditsTest` / `test I10 a grant whose changeset fails for another reason still returns the changeset`
- `AuroraMeter.CreditsTest` / `test I10 spend_history rejects :reverse as a spend kind`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.list returns lots in the documented spend order`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.list with states: :all includes exhausted, expired and reversed lots`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.get accepts a lot id and a grant reference`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.allocations reconstructs a settlement: consume then unreserve on the same lot`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.for_source returns exactly the lots funded by one payment intent`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.for_source with an unsupported key raises`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots.list paginates by cursor without skipping or repeating a lot`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 a wallet that has not been cut over has no lots to read`
- `AuroraMeter.CreditsLotsApiTest` / `test I10 Lots refuses an option it does not understand rather than ignoring it`
- `AuroraMeter.CreditsFiguresTest` / `test I10 a legacy wallet reports spendable equal to available, debt zero and expired zero`
- `AuroraMeter.CreditsFiguresTest` / `test I10 balance stays signed and spendable is the figure the ledger refuses on`
- `AuroraMeter.CreditsFiguresTest` / `test I10 Money.assert_range! refuses an amount above the documented limit before any write`
- `AuroraMeter.CreditsFiguresTest` / `property I10 for any generated operation sequence, summary/1's figures agree with the lot tables`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 a ledger call inside a host transaction emits nothing until after_commit is called`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 a host transaction that rolls back and calls after_commit(discard: true) emits nothing`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 after_commit runs the deferred effects in order`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 deferred_effects? reports an undrained queue`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 a ledger call that owns its transaction is unaffected`
- `AuroraMeter.CreditsAfterCommitTest` / `test I10 a low-balance crossing inside a host transaction does not invoke the handler before commit`
- `AuroraMeter.CreditsHistoryTest` / `test I10 history paginates by cursor across rows sharing one microsecond`
- `AuroraMeter.CreditsHistoryTest` / `test I10 history with :before is documented as lossy and still works`
- `AuroraMeter.CreditsHistoryTest` / `test I10 history includes reversals by default`
- `AuroraMeter.CreditsHistoryTest` / `test I10 history rejects :before together with :cursor`
- `AuroraMeter.CreditsRecurrencesTest` / `test I10 a recurring lot carries recurrence_key, plan_id and plan_version in its source`

**Evidence.** `docs/evidence/v1/phase-01/i10.md`

## I11 Holds cannot spend the same available funds twice

**Guarantee.** A hold, a settle, a release and a debit each run in one transaction
that takes the tenant's balance row lock first, so concurrent callers serialise on
that row. A hold is refused with `:insufficient_credits` when it would take
`balance - held` below zero (less `:credits_overdraft_tolerance`), and the refusal
returns rather than raising, so it does not destroy the caller's own transaction.
A hold's terminal transition is taken once: exactly one of a concurrent settle and
release wins, and the loser is told it lost. Twenty concurrent holds of ten cents
against one dollar admit exactly ten.

**Prerequisites.** The Ecto storage adapter on PostgreSQL and schema version 3 or
later. Every write carries a `reference` as its idempotency key.

**Known limits.** A settle may exceed its hold, which takes the balance negative on
purpose and reports the overrun rather than failing the work that already
happened. `:credits_overdraft_tolerance` widens the refusal threshold by design.
The lock is per tenant balance row, so throughput on one hot wallet is bounded by
that row.

The fifty-connection proof runs in two waves of twenty-five, because
`AuroraMeter.Test.Connections.run/3` refuses more tasks than the pool can serve
(the pool is 30 and four connections are reserved). Fifty holds are still
attempted against one wallet and the admitted count is asserted cumulatively; the
arithmetic is in `docs/evidence/v1/phase-05/i11.md`.

A hold's terminal transition is protected by application code and a row lock, and
by nothing in the schema. `Ledger.pending_hold/3` locks the hold row `FOR UPDATE`
and re-reads `status = 'pending'` inside that lock, which is what makes a settle
and a release of one hold serialise. The `(kind, reference)` unique index refuses
a second `:settle` row, but a `:settle` and a `:release` for one reference differ
in `kind`, so the index permits both; there is no check constraint on
`aurora_meter_credit_balances.held` either. Remove the lock or the status re-read
and `held` goes negative with nothing to stop it. Both halves are asserted
directly in `AuroraMeter.CreditsReconcileHoldsTest`, under "what stops a hold
being closed twice".

**Tests.**

- `AuroraMeter.CreditsConcurrencyTest` / `test I11 twenty concurrent $0.10 holds against $1.00 admit exactly ten`
- `AuroraMeter.CreditsConcurrencyTest` / `test I11 concurrent settle and release of one hold: exactly one wins`
- `AuroraMeter.CreditsConcurrencyTest` / `test I11 fifty independent connections holding against one hot wallet admit exactly the funded count`
- `AuroraMeter.CreditsTest` / `test hold/4, settle/3, release/1 a hold is refused when the available balance does not cover it`
- `AuroraMeter.CreditsTest` / `test with_credits/4 releases when the function raises, throws or exits, then propagates`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I11 a reconciler release and a caller settle produce exactly one terminal transition`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I11 a reconciler decision applied after a concurrent settle is refused by the hold row lock`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I11 a with_credits caller whose hold the reconciler released records the executed cost`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I11 twenty-four concurrent reconciler runs over one hot wallet conserve the balance`
- `AuroraMeter.CreditsTest` / `test with_credits/4 I11 returns its result when the hold was settled by someone else`
- `AuroraMeter.CreditsTest` / `test with_credits/4 I11 records the executed cost when the hold was released by someone else`

- `AuroraMeter.CreditsLotsConcurrencyTest` / `test I11 fifty independent holds against one wallet funded with ten admit exactly ten`
- `AuroraMeter.CreditsLotsConcurrencyTest` / `test I11 twenty concurrent holds across twenty wallets do not interfere`
- `AuroraMeter.CreditsLotsConcurrencyTest` / `test I11 without the balance row lock the same fifty holds oversubscribe the wallet`
- `AuroraMeter.CreditsLotsTest` / `test I11 every ledger write takes the balance row, then the transaction row, then the lots`
- `AuroraMeter.CreditsLotsTest` / `test I11 settling one hold below its reservation leaves a second hold's reservation on the same lot intact`

- `AuroraMeter.CreditsFiguresTest` / `test I11 summary reports spendable, held, expired, debt and promotional_spendable independently`
- `AuroraMeter.CreditsFiguresTest` / `test I11 debt appears in debt and makes spendable zero`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 the low-balance handler fires once per crossing and not again while below the threshold`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 a recovery above the threshold then a second crossing fires twice with different crossing ids`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 a replayed reconciliation cycle that re-crosses the same threshold fires once`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 a raising low-balance handler does not fail the ledger write`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 a low-balance handler that never returns is shut down at the timeout and the write stands`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 the low-balance trigger uses spendable, not balance minus held`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 lowering the threshold below the current spendable clears the standing crossing`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 no threshold means no crossing, no alert and no flag`
- `AuroraMeter.CreditsLowBalanceTest` / `test I11 a handler that needs a connection gets one while the writer holds a pinned one (X269)`

**Evidence.** `docs/evidence/v1/phase-05/i11.md`

## I12 Grant expiry cannot consume later or unrelated funds

**Guarantee.** `expire_due/1` removes only what is left of an expired promotional
grant. It never takes the balance below zero, never claws back credit that a hold
has already reserved, never reaches into credit a later grant contributed, and
never absorbs spending that happened before the expiring grant existed. Expiry is
idempotent: a grant expires once, and the entry records what the promotional
figure became.

**Prerequisites.** The Ecto storage adapter, schema version 3 or later, and a
scheduler that calls `expire_due/1`. Only `:promotional` grants may carry an
`:expires_at`; a paid grant with one is rejected.

**Known limits.** They now depend on which writer owns the wallet.

On a wallet that has **not** been cut over to credit lots (`lots_enabled_at IS
NULL`, which is every wallet until `mix aurora_meter.credits.migrate_lots` runs)
the legacy arithmetic is unchanged and both of the limits below still hold. The
single promotional figure per tenant cannot say which grant a spend came out of,
so overlapping promotions are handled correctly only for the cases in the tests
below. And expiry is a pass rather than a property of the money: value a hold had
reserved on an already expired grant is spendable again the moment the hold is
released and stays spendable until the next `expire_due/1` pass (finding L1).
`AuroraMeter.CreditsTest` asserts that behaviour so there is a before and after.

On a wallet the allocator owns, both are closed. Each grant is its own lot with
its own five quantities, so an overlapping promotion expires exactly its own
remainder; and a reservation released or settled on a lot past its `expires_at`
becomes `expired` rather than `available`, so nothing of an expired lot is ever
spendable again. A third difference goes with them and is a deliberate
compatibility change: credit whose `expires_at` has passed is not spendable even
before the sweep reaches it, which is what makes expiry bookkeeping instead of a
race.

**Tests.**

- `AuroraMeter.CreditsTest` / `test promotional credit I12 expiry never claws back credit a hold has reserved`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a grant expires only its own remainder`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a new expiring grant cannot absorb spending that predates it`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a release after the grant expired returns spendable credit (L1, fixed in 06a)`
- `AuroraMeter.CreditsReconcileHoldsTest` / `test recovery beside expiry I12 a reconciler release on an expired grant returns spendable credit (L1, fixed in 06a)`
- `AuroraMeter.CreditsTest` / `test promotional credit expire_due/1 expires only what is left, once, and never below zero`
- `AuroraMeter.CreditsTest` / `test promotional credit a promotional grant landing on a negative balance first repays the debt`
- `AuroraMeter.Credits.AllocatorTest` / `test I12 a reservation released on a lot past its expiry becomes expired, never available`
- `AuroraMeter.Credits.AllocatorTest` / `test I12 expiry moves only the due lot's available and refuses when it is all reserved`
- `AuroraMeter.CreditsLotsTest` / `test I12 expiry moves only the due lot's available to expired and leaves reserved alone`
- `AuroraMeter.CreditsLotsTest` / `test I12 overlapping promotions expire their own remainder and never each other's`
- `AuroraMeter.CreditsLotsTest` / `test I12 a reservation released on an expired lot becomes expired, never spendable`
- `AuroraMeter.CreditsLotsTest` / `test I12 a hold taken before expiry settles against its reserved portion afterwards`
- `AuroraMeter.CreditsLotsTest` / `test I12 the expiry sweep run twice writes one expire row, one allocation and the reference expire:<lot_id>:0`
- `AuroraMeter.CreditsLotsConcurrencyTest` / `test I12 expiry racing a release conserves and leaves no spendable expired value`

The wallet migration reproduces the **legacy** semantics for the history it
replays, because the balance row it is checked against was produced by them:
applying the fixed rule to a release that already happened would move money the
ledger did not move. The difference appears from cutover onward, and the two
tests below are what say so.

- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I12 a hold spanning a partial expiry replays without moving the money`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I12 a hold still open on an expiring lot is reported, and nothing moves`

- `AuroraMeter.CreditsFiguresTest` / `test I12 expired value appears in expired and never in spendable`

**Evidence.** `docs/evidence/v1/phase-06/i12.md`

## I16 Worker scheduling is not an exactly-once assumption

**Guarantee.** The core half of this invariant is that a periodic job run twice
produces one effect. `expire_due/1` is written to be run from a scheduler and
expires a grant once however often it is called, and a flush with nothing pending
writes nothing. Aurora Meter does not claim exactly-once host job execution
anywhere: every scheduled entry point is idempotent on its own state instead.

**Prerequisites.** The Ecto storage adapter. The host owns the scheduler; the core
ships no job runner.

**Known limits.** Nothing here promises that two schedulers cannot run
concurrently; it promises that the effect is the same if they do. The core has no
lease tokens and will not grow any: a lease is a duration, and on this hardware
the one clock every node shares steps backwards by up to 439 ms
(`open-findings.md` X100), so a short lease cannot be trusted to order two
instants. Exclusion, where it is needed at all, is a row lock or a session
advisory lock, neither of which has a clock in it.

The core does now have checkpoints. `AuroraMeter.Operations` keeps a cursor, a
counter map and a pause flag per named operation in `aurora_meter_checkpoints`,
and `AuroraMeter.Operations.run_batches/3` is the batch loop every core sweep
runs: the pause is read before every batch, the cursor is read from the row and
is never a job argument, and a per-item failure is counted and stepped over
rather than failing the run.

One window is left open deliberately and is worth stating where the guarantee is:
**a crash between a batch's commit and its checkpoint write re-runs that batch.**
The checkpoint is written as a statement of its own, outside the batch's
transaction, so a rolled-back batch cannot roll back an unrelated cursor. Re-running
a batch is safe only because every operation using the loop re-reads the thing it
is about to change under that row's own lock, and a later operation whose effects
were not idempotent could not use this loop.

**`AuroraMeter.Oban.PlanTransitions` keeps no checkpoint, and that is the
statement rather than an omission.** Its operation resumes by **predicate**, not
by position: a killed run leaves every un-applied tenant with
`transition_state = 'pending'`, and the next run finds exactly those from the
partial index. There is no cursor to rewind, no cursor to go stale, and nothing
a checkpoint could add except a second thing to keep in step with the rows. The
kill test asserts the complement rather than a cursor (`open-findings.md` X242:
when a worker's resume rests on a predicate, its row should say that instead of
borrowing a control that cannot discriminate for it). The `cursor` the operation
returns is paging within one run, not durable state.

The optional `AuroraMeter.Oban.*` workers add no guarantee of their own. Each
`perform/1` runs bounded batches of an operation that is already idempotent; the
worker opens no transaction, takes no lock and holds no state between runs, so
two nodes running one worker is the same case as two callers of the operation.
The `unique` option each worker declares is defence in depth: removing it on a
copy of the expiry worker leaves the duplicate-run result unchanged, which is
what `AuroraMeter.ObanConcurrencyTest` measures and records rather than claiming
a pass for a layer nothing tested.

`AuroraMeter.Credits.reconcile_holds/1` has no lease on a hold on purpose. A lease
would let a crashed reconciler leave a hold nothing could reconcile until a second
recovery mechanism cleared it, which trades a real problem for a worse one; and a
lease is a duration, which on this hardware the shared clock cannot be trusted to
order at a sub-second scale (`open-findings.md` X100). Mutual exclusion comes from
the hold row's own `FOR UPDATE` and the status re-read inside it, so two nodes
sweeping at the same instant produce one terminal transition and the loser is told
`:already_closed`. A run killed between the host callback and the decision writes
nothing and the next run asks again.

**Tests.**

- `AuroraMeter.CreditsTest` / `test promotional credit expire_due/1 expires only what is left, once, and never below zero`
- `AuroraMeter.MeteringTest` / `test flush persists ETS values and repeated flushes are idempotent`
- `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I16 two reconcilers on two connections release one hold once`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I16 killing the reconciler between the callback and the application leaves the hold pending`
- `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I16 killing the reconciler after the application commits leaves exactly one terminal transition`
- `AuroraMeter.Oban.WorkersTest` / `test I16 a second CreditExpiry run for the same tick expires nothing and adds no ledger row`
- `AuroraMeter.ObanConcurrencyTest` / `test I16 two CreditExpiry runs on independent connections expire each grant once`
- `AuroraMeter.ObanConcurrencyTest` / `test I16 the CreditExpiry run that loses the grant row lock expires nothing`
- `AuroraMeter.ObanConcurrencyTest` / `test I16 the same is true with Oban's uniqueness removed, so uniqueness is not what answers`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry processes at most batch_size grants per batch and records a cursor`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry killed between batches resumes at the checkpoint without skipping work`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry re-processes one batch when killed between the batch commit and the checkpoint write, with no second effect`
- `AuroraMeter.ObanJobControlsTest` / `test I16 a rewound cursor re-examines committed work and the ledger refuses it, not the cursor`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry cancels with :paused and continues from the cursor after resume`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry counts a grant the ledger refuses and expires the ones before it`
- `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry counts a grant whose transaction raises, advances past it, and expires the rest`
- `AuroraMeter.ObanJobControlsTest` / `test I16 an expire entry stamped before its own grant expires the right amount, because the fold orders by seq`
- `AuroraMeter.ObanJobControlsTest` / `test I16 HoldReconciliation pages with a cursor and finishes the scan`
- `AuroraMeter.ObanJobControlsTest` / `test I16 HoldReconciliation cancels with :paused within one batch`
- `AuroraMeter.ObanJobControlsTest` / `test I16 the cutoff is pinned across the pages of one scan`
- `AuroraMeter.RetentionControlsTest` / `test I16 the retention worker resumes at its checkpoint after a kill`
- `AuroraMeter.RetentionControlsTest` / `test I16 two retention jobs on independent connections delete every eligible row and none twice`
- `AuroraMeter.RetentionControlsTest` / `test I16 the retention worker cancels nothing and reports a paused table`
- `AuroraMeter.CreditsRecurrencesTest` / `test I16 the scan is bounded by limit and the next run continues from the cursor`
- `AuroraMeter.CreditsRecurrencesTest` / `test I16 a run killed mid-tenant resumes and reaches the same state as an uninterrupted one`
- `AuroraMeter.CreditsRecurrencesTest` / `test I16 a paused run writes nothing and says it is paused`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 a cancel racing an apply yields exactly one terminal state`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 a provider sync racing an apply yields one terminal state and one plan`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 the applier killed after commit and before cache invalidation converges`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 the applier killed before commit leaves the transition pending`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 the applier killed mid-batch leaves the applied tenants applied and the rest pending`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 twelve independent connections applying one due transition apply it once`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 twelve independent connections scheduling one ref produce one transition row`
- `AuroraMeter.PlanTransitionsConcurrencyTest` / `test I16 two Oban jobs from two nodes apply one transition`

**Evidence.** `docs/evidence/v1/phase-05/i16.md`

## I17 Historical plans remain stable

**Guarantee.** A plan is identified by `(plan_id, version)`. A subscription
records the version it was sold, and `AuroraMeter.Entitlements.plan/1` resolves
**that** version: from the compiled plans module when it is still there, and
otherwise from the snapshot `AuroraMeter.Plans.register!/0` stored in
`aurora_meter_plan_versions`. So deploying a new version of a plan does not move
a tenant already on an older one, and deleting a retired version's block does
not change what the tenants on it are entitled to.

Editing a version **in place** is refused rather than applied:
`register!/0` compares a fingerprint of each compiled version's commercial
content (the plan id, the version, the price, every feature and every recurring
credit) against the stored one and raises
`AuroraMeter.PlanVersionConflictError`, or logs the same message under
`plan_version_conflict: :warn`, which is the 0.5.x default.

Subscriptions written before core schema version 10 are named at the first boot
after the upgrade, with the plan's **base** version and that version's
fingerprint, in resumable batches. Registration never changes a `plan_id`, a
`plan_version` or a fingerprint that is already set.

**Prerequisites.** Core schema version 10, and a storage adapter that declares
the `:plan_versions` capability. An adapter that does not logs one warning and
leaves compiled code as the only authority, in which case a version deleted from
code becomes unreadable and the tenants on it fall back to the default plan.

**Known limits.** A feature or recurring credit name in a stored snapshot is read
back with `String.to_existing_atom/1`. A name whose atom does not exist on the
node is dropped from the resolved plan and logged once per version per node:
invisible to `check/2`, `entitled?/2`, `quota/2` and `feature_value/3`, which all
take atoms, and **not** invisible to code that enumerates `plan.features`.

A version's `:effective_at` is deliberately outside the fingerprint, so moving it
is not a conflict. It decides which version a **new** subscription gets and
cannot move a tenant already pinned to one.

Two of the three adversarial proofs `v1-release.md` section 17 asks of I17 are
proven here: the changed definition, and the explicit scheduled migration. The
third, a stale provider notification that cannot move the version, is Aurora
Meter Pro's and is proven in 07c.

**Attribution (build unit 07c).** A recorded event carries the
`(plan_id, plan_version)` in force when the usage **occurred**, resolved once by
`AuroraMeter.Plans.effective_for/2` at record time and never recomputed. A
correction copies its original's stamp rather than resolving it again, so a
credit issued after an upgrade is priced as the fact it reverses was. An instant
no recorded assignment or applied transition covers is stored as
`attribution: "plan_unresolved"` with both plan columns NULL, and its export
intent is staged `{:ineligible, :plan_unresolved}`: an unattributable fact is a
state, never a guess at today's plan. The stamp is deliberately **not** part of
`payload_hash`: it is derived rather than supplied, and including it would turn
an ordinary retry that straddles a plan change into a conflict rather than the
duplicate it is (finding X302).

A scheduled transition is the **only** thing in the package that rewrites
`plan_version` on a subscription that already has one, and it is explicit,
referenced by the caller, audited in `aurora_meter_plan_transitions`, and
conditional on the audit row still being pending. It never rewrites history: the
previous `(plan_id, version)` is copied into the transition row before the
subscription row changes, and the applied row carries the boundary the change
took effect at rather than the instant a worker noticed.

**Tests.**

- `AuroraMeter.PlansTest` / `test a duplicate feature raises at compile time`
- `AuroraMeter.PlansTest` / `test a negative limit raises at compile time`
- `AuroraMeter.SubscriptionsTest` / `test a subscription that is not in an entitled status falls back to the default plan`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 SKIP LOCKED makes a concurrent assignment take the rows another transaction is not holding`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 register! killed between assignment batches resumes and completes on the next run`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 register! killed inside a batch commits nothing from that batch`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 twelve concurrent put_plan_version calls for one key leave exactly one row`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 twelve concurrent register! calls insert one row per plan id and version`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 twelve concurrent register! calls reach the same conflict decision`
- `AuroraMeter.PlanRegistryConcurrencyTest` / `test I17 two concurrent assignments take disjoint batches and leave every row named`
- `AuroraMeter.PlanVersionsPropertyTest` / `property I17 encode then decode preserves the fingerprint`
- `AuroraMeter.PlanVersionsPropertyTest` / `property I17 the fingerprint is a pure function of the commercial content`
- `AuroraMeter.PlanVersionsPropertyTest` / `property I17 two plans with different commercial content have different fingerprints`
- `AuroraMeter.PlanVersionsTest` / `test I17 a future-dated version is not effective before its instant and is after it`
- `AuroraMeter.PlanVersionsTest` / `test I17 a non-UTC effective instant raises at compile time and says why`
- `AuroraMeter.PlanVersionsTest` / `test I17 a plan block without a version compiles as version 1 with no effective instant`
- `AuroraMeter.PlanVersionsTest` / `test I17 a plan id whose only version is future dated raises at compile time`
- `AuroraMeter.PlanVersionsTest` / `test I17 a storage adapter without snapshot support warns once and leaves code authoritative`
- `AuroraMeter.PlanVersionsTest` / `test I17 a subscription pinned to a version in neither code nor storage falls back and says so`
- `AuroraMeter.PlanVersionsTest` / `test I17 a tenant keeps version 1's limits when version 1's block is deleted from the module`
- `AuroraMeter.PlanVersionsTest` / `test I17 a tenant subscribed before version 2 exists keeps version 1 after version 2 is effective`
- `AuroraMeter.PlanVersionsTest` / `test I17 all/0 keeps its %{id => plan} shape`
- `AuroraMeter.PlanVersionsTest` / `test I17 an invalid version string raises at compile time`
- `AuroraMeter.PlanVersionsTest` / `test I17 an unknown option in the plan keyword list raises and lists the accepted keys`
- `AuroraMeter.PlanVersionsTest` / `test I17 base/1 is the version with no effective instant, whatever the clock says`
- `AuroraMeter.PlanVersionsTest` / `test I17 duplicate plan id and version in one module raises at compile time`
- `AuroraMeter.PlanVersionsTest` / `test I17 get/2 returns a compiled version and nil for a version in neither code nor storage`
- `AuroraMeter.PlanVersionsTest` / `test I17 plan_version_conflict warn logs the same message once and does not raise`
- `AuroraMeter.PlanVersionsTest` / `test I17 put_subscription never writes a transition column, even when asked to`
- `AuroraMeter.PlanVersionsTest` / `test I17 put_subscription still invalidates the subscription cache`
- `AuroraMeter.PlanVersionsTest` / `test I17 put_subscription with a full provider attribute map updates every syncable column`
- `AuroraMeter.PlanVersionsTest` / `test I17 put_subscription with a partial attribute map leaves every column it did not send`
- `AuroraMeter.PlanVersionsTest` / `test I17 register! names a subscription whose plan id is in no compiled module, with no fingerprint`
- `AuroraMeter.PlanVersionsTest` / `test I17 register! names the contract of a subscription that has none, and leaves a named one alone`
- `AuroraMeter.PlanVersionsTest` / `test I17 register! raises PlanVersionConflictError naming the plan, version and both fingerprints`
- `AuroraMeter.PlanVersionsTest` / `test I17 register! stamps first_seen_at from the database, not from the node clock`
- `AuroraMeter.PlanVersionsTest` / `test I17 register! stores one snapshot per compiled version and the second run writes nothing`
- `AuroraMeter.PlanVersionsTest` / `test I17 subscribe/2 selects the version effective now and stamps its fingerprint`
- `AuroraMeter.PlanVersionsTest` / `test I17 subscribe/3 with an explicit version pins it, including one not yet effective`
- `AuroraMeter.PlanVersionsTest` / `test I17 subscribe/3 with an unknown version is a changeset error naming plan_version`
- `AuroraMeter.PlanVersionsTest` / `test I17 the legacy assignment names the plan's base version, not the literal 1`
- `AuroraMeter.PlanVersionsTest` / `test I17 the legacy assignment takes plan_effective_at from the past, never from the upgrade clock`
- `AuroraMeter.PlanVersionsTest` / `test I17 two versions of one plan id both compile and versions/1 lists them oldest first`
- `AuroraMeter.PlanVersionsTest` / `test I17 two versions of one plan with the same effective instant raise at compile time`
- `AuroraMeter.PlansSnapshotTest` / `test I17 a boolean feature value and the integer 1 produce different fingerprints`
- `AuroraMeter.PlansSnapshotTest` / `test I17 an integer and a float unit price produce different fingerprints`
- `AuroraMeter.PlansSnapshotTest` / `test I17 decode drops a feature name with no existing atom and names it`
- `AuroraMeter.PlansSnapshotTest` / `test I17 decode refuses a plan id with no existing atom rather than creating one`
- `AuroraMeter.PlansSnapshotTest` / `test I17 encode then decode round-trips a plan`
- `AuroraMeter.PlansSnapshotTest` / `test I17 short/1 renders twelve hex characters, or says there is no fingerprint`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the canonical form lists features in name order, whatever order the map iterates in`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the canonical form renders every commercial field with visible separators`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the effective instant is not commercial content and does not change the fingerprint`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the fingerprint changes when any commercial field changes`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the fingerprint is independent of feature declaration order`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the fingerprint is independent of map iteration order above the small-map boundary`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the fingerprint is independent of recurring credit declaration order`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the fingerprint is the sha256 of the canonical form and is 32 bytes`
- `AuroraMeter.PlansSnapshotTest` / `test I17 the separators cannot appear in a name the DSL accepts`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition for a tenant with no subscription previews from the default plan`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition of a zero-price transition reports price 0 and no proration`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition of an unknown plan is refused`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition of an unknown version is refused`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition reports a limit change, an added feature and a removed feature`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition reports an added and a removed feature by name`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition reports an unchanged feature not at all`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition reports recurring credit changes`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition returns the effective time and the tenant's period`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition returns the old and new entitlements without writing anything`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition with Billing.Noop reports provider status :not_configured`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition with a provider implementing describe_plan_change shows it`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition with a provider that raises keeps the diff`
- `AuroraMeter.PlanPreviewTest` / `test I17 preview_transition with a provider that returns an error keeps the diff`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a cancellation wins over a sync that also names the scheduled target`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a cancelled transition is never applied by a later run`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test X296 a provider naming the plan id without the version cancels, and Aurora Meter Pro no longer produces that shape`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a provider sync that does not change the plan leaves the transition pending`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a provider sync to a different plan cancels the pending transition`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a provider sync to exactly the scheduled target applies the transition early`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a provider sync touching only provider ids leaves the transition pending`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a provider sync writing a non-entitled status cancels the pending transition`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a stale sync for an ended subscription cannot revive a cancelled transition`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 a transition effective before a later cancellation applies normally`
- `AuroraMeter.PlanTransitionPrecedenceTest` / `test I17 put_subscription with no pending transition opens no transaction`
- `AuroraMeter.PlanTransitionsTest` / `test I17 a second ref with replace: false returns a conflict naming the pending ref`
- `AuroraMeter.PlanTransitionsTest` / `test I17 a second ref with replace: true cancels the first and schedules the second`
- `AuroraMeter.PlanTransitionsTest` / `test I17 a transition to a version in neither code nor snapshots is failed and not retried`
- `AuroraMeter.PlanTransitionsTest` / `test I17 a zero-price transition issues exactly the statements a priced one does`
- `AuroraMeter.PlanTransitionsTest` / `test I17 an applied transition changes plan_id, plan_version, fingerprint and effective time`
- `AuroraMeter.PlanTransitionsTest` / `test I17 an applied transition writes applied_at on the audit row`
- `AuroraMeter.PlanTransitionsTest` / `test I17 an explicit scheduled migration is the only thing that moves a tenant's version`
- `AuroraMeter.PlanTransitionsTest` / `test I17 an invalid custom period source raises InvalidPeriodError naming the module`
- `AuroraMeter.PlanTransitionsTest` / `test I17 apply_due_transitions applies a provider transition once provider_ref is set`
- `AuroraMeter.PlanTransitionsTest` / `test I17 apply_due_transitions applies a transition whose effective_at has passed`
- `AuroraMeter.PlanTransitionsTest` / `test I17 apply_due_transitions does not apply a transition before its effective_at`
- `AuroraMeter.PlanTransitionsTest` / `test I17 apply_due_transitions pages with a keyset cursor and returns :done`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the applier refuses a row whose mirror says applied and whose audit row says pending`
- `AuroraMeter.PlanTransitionsTest` / `test I17 apply_due_transitions skips a provider transition with no provider_ref`
- `AuroraMeter.PlanTransitionsTest` / `test I17 applying a transition deletes no counter, history, event, transaction or lot row`
- `AuroraMeter.PlanTransitionsTest` / `test I17 cancel_transition moves pending to cancelled and clears the pending state`
- `AuroraMeter.PlanTransitionsTest` / `test I17 cancel_transition on an already cancelled transition is idempotent`
- `AuroraMeter.PlanTransitionsTest` / `test I17 cancel_transition on an applied transition returns a conflict`
- `AuroraMeter.PlanTransitionsTest` / `test I17 cancel_transition with an unknown ref returns not_found`
- `AuroraMeter.PlanTransitionsTest` / `test I17 confirm_transition applies immediately when the provider boundary has passed`
- `AuroraMeter.PlanTransitionsTest` / `test I17 confirm_transition is idempotent under redelivery of the same provider_ref`
- `AuroraMeter.PlanTransitionsTest` / `test I17 confirm_transition with a different provider_ref on an applied transition conflicts`
- `AuroraMeter.PlanTransitionsTest` / `test I17 confirm_transition with an unknown ref returns not_found`
- `AuroraMeter.PlanTransitionsTest` / `test I17 confirm_transition without a provider_ref is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 no transition source names a price, so no branch can depend on one`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition copies the current plan and version into from_plan_id`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition defaults effective_at to the end of the tenant's current period`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition defaults version to the version effective at the effective time`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition for a row with a null plan_version is registration_incomplete`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition for a tenant with no subscription is not_found`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition merges the caller's detail into the audit row`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition to a future-dated version is accepted when it is effective then`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition to a version not yet effective at the effective time is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition to an unknown plan is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition to an unknown version of a known plan is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition to the tenant's current plan and version is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition with a non-UTC effective_at is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition with a past effective_at is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition with a ref over 128 bytes is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition without a ref is refused`
- `AuroraMeter.PlanTransitionsTest` / `test I17 schedule_transition writes the audit row and mirrors it on the subscription`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the due scan's keyset pages partition the pending set with no repeat and no gap`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the default effective_at under a subscription-aligned source is current_period_end`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the default effective_at under a weekly host source is the end of the current week`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the default effective_at under the calendar source is the first of next month`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the same ref with different parameters returns a conflict naming both`
- `AuroraMeter.PlanTransitionsTest` / `test I17 the same ref with identical parameters returns the existing transition`
- `AuroraMeter.PlanTransitionsTest` / `test I17 usage recorded before the boundary stays in its period after the transition applies`
- PLANNED (07c): `AuroraMeter.Pro.PlanAttributionTest` / `test I17 a stale provider notification cannot move the version`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I17 deploying version 2 leaves a tenant on version 1 with an unchanged allowance`
- `AuroraMeter.PlanAttributionTest` / `test I17 a plan definition redeployed under a tenant does not change a recorded stamp`
- `AuroraMeter.PlanAttributionTest` / `test I17 an unresolved period is not asked for a plan at all`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for answers the current assignment for an instant inside it`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for costs no query at all for an instant inside the current assignment`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for ignores a cancelled or pending transition and reads only applied ones`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for is unresolved for a tenant with no subscription`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for is unresolved for an instant before an assignment with no history`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for is unresolved while the row still has no plan_version`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for resolves a backdated instant through an applied transition's to side`
- `AuroraMeter.PlanAttributionTest` / `test I17 effective_for resolves an instant before the first applied transition from its from side`
- `AuroraMeter.PlanAttributionTest` / `test I17 record for a tenant with no subscription stores attribution unresolved`
- `AuroraMeter.PlanAttributionTest` / `test I17 record of a backdated event resolves the version through applied transition history`
- `AuroraMeter.PlanAttributionTest` / `test I17 record of an event predating recorded history stores attribution unresolved and quarantines its outbox item`
- `AuroraMeter.PlanAttributionTest` / `test I17 record stamps plan_id and plan_version from the plan effective at occurred_at`
- `AuroraMeter.PlanAttributionTest` / `test I17 usage recorded before a transition keeps the old version after the transition applies`

**Evidence.** `docs/evidence/v1/phase-07/i17.md`

## I18 Recurring grants occur once per entitlement period

**Guarantee.** For one tenant, one entitlement name, one plan id, one plan
version and one period, at most one recurring grant exists, and at most one
rollover lot derives from the period before it. Two guards make that true and
both are evaluated inside the wallet's balance row lock:
`aurora_meter_credit_recurrences` is `UNIQUE (tenant_key, key)` and the period's
row is inserted `ON CONFLICT DO NOTHING`, and the grant carries the period's own
reference into `aurora_meter_credit_transactions`, which is
`UNIQUE (kind, reference)`. They are deliberately redundant because this is
money. Neither is a lease and neither is a duration, so neither can be inverted
by a clock that steps backwards.

Downtime catch-up processes missed periods in chronological order with bounded
work, and a period that had already ended when it was processed is granted and
expired in the same transaction, recorded `issued_and_expired`, so history is
complete and nothing owed months ago arrives spendable today. Rollover carries at
most the configured cap of one period's unused allowance into the next, as a new
lot with its own reference, and does not accumulate: two idle periods carry the
cap, not twice the cap. The cap is read from the previous period's **stored
policy snapshot**, so editing a plan cannot change what an already-issued period
may carry out of itself.

**Prerequisites.** Core schema version 9, a plan declaring
`AuroraMeter.Plans.recurring_credits/2`, a storage adapter implementing
`c:AuroraMeter.Storage.list_subscriptions/2`, and a host scheduler (Oban's
`AuroraMeter.Oban.RecurringGrants`, or any other caller of
`AuroraMeter.Credits.Recurrences.run/1`).

**Known limits.** The wallet must be on the lot engine: a wallet whose
`lots_enabled_at` is null is skipped with `reason: :lots_disabled` rather than
granted through the legacy projection, because the allowance, the cap and the
catch-up are all defined over lots. A tenant is never back-paid for periods
before its first recurrence row, and a host adopting an allowance mid-period
gets the whole of that period rather than a pro-rated part. A plan
transition landing inside a period is build unit 07b's to order; this engine
re-reads the subscription under the lock and refuses a tenant whose plan changed,
rather than granting the old plan's allowance.

Each period's key and each period's policy carry the version **that period was
sold under**, resolved through `AuroraMeter.Plans.effective_for/2`, so a
catch-up across an upgrade grants each period at its own contract rather than
all of them at today's. The version the sweep falls back to when nothing
recorded covers a period is the subscription's own; it never invents one. Two
narrower limits follow. The entitlement names a run considers are the ones the
tenant's **current** version declares, so an allowance that existed only in a
retired version is not back-paid; and a version that resolves to neither
compiled code nor a stored snapshot keeps the current version's policy, because
withdrawing an allowance a live contract declares would be a worse answer than
paying it.

**Tests.**

- `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference`
- `AuroraMeter.CreditsTest` / `test grant/3 a duplicate grant reports duplicate: true in telemetry and does not broadcast`
- `AuroraMeter.PlansTest` / `test I18 recurring_credits stores name, amount, category, rollover and expires on the plan`
- `AuroraMeter.PlansTest` / `test I18 a plan without recurring_credits has an empty list`
- `AuroraMeter.PlansTest` / `test I18 declaration order is preserved and features are untouched`
- `AuroraMeter.PlansTest` / `test I18 a duplicate entitlement name in one plan raises at compile time`
- `AuroraMeter.PlansTest` / `test I18 a float amount raises at compile time`
- `AuroraMeter.PlansTest` / `test I18 rollover greater than zero with expires: :never raises at compile time`
- `AuroraMeter.PlansTest` / `test I18 an expiring allowance must be promotional, because only promotional grants expire`
- `AuroraMeter.PlansTest` / `test I18 an unknown option, category or expiry raises at compile time`
- `AuroraMeter.PlansTest` / `test I18 a name or plan id that cannot be read back out of a recurrence key raises`
- `AuroraMeter.PlansTest` / `test I18 a never-expiring promotional allowance compiles and warns`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a tenant with no previous recurrence gets only the current period`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a tenant already granted for the current period is owed nothing`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 the walk from three months ago yields three periods in chronological order`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 the walk stops at max_periods and reports the remainder`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a weekly custom period source yields weekly periods`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a source exporting containing/2 is asked through it`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a period source that does not advance is detected and does not loop`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a period source that raises is reported rather than propagated`
- `AuroraMeter.Credits.RecurrencesPeriodsTest` / `test I18 a source that cannot place a past instant is an error, not a guess`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 one run grants one lot per entitled tenant for the current period`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 two tenants on one plan reach the same period without colliding`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 running the job five times in one period produces one grant and four duplicates`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a cancelled subscription receives nothing and a past_due one receives its allowance`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a plan that declares no allowance grants nothing at all`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a wallet the allocator does not own is skipped and told why`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 the recurrence reference namespace is rejected for a manual grant`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 an unused allowance rolls over capped at the policy cap and expires the rest`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a tenant that spent most of its allowance carries only what was left`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a fully spent allowance rolls over nothing`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 rollover is not compounded: two idle periods carry at most the cap into the third`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a rollover is unaffected by whether the expiry sweep or the recurrence ran first`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a plan with no rollover carries nothing and expires the whole allowance`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 three missed periods are issued and expired in order and leave no fresh availability`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a historical period's grant, rollover and expiries chain exactly in one run`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a catch-up bounded by max_periods resumes chronologically on the next run`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a tenant seen for the first time is not back-paid`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a plan edited between two periods grants the new amount and keeps the old cap`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a run one microsecond before the boundary grants the old period, and at it the new`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a dry run reports what it would grant and writes nothing`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 status/1 reports the tenant's periods newest first`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a tenant whose period source raises is skipped and the run continues`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a subscription cancelled between the scan and the lock is refused under the lock`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a storage adapter without list_subscriptions is refused rather than silently idle`
- `AuroraMeter.CreditsRecurrencesTest` / `test I18 a naive per-period reference double-grants, which is what the engine replaces`
- `AuroraMeter.CreditsRecurrencesConcurrencyTest` / `test I18 two schedulers against fifty tenants issue one grant and one rollover per period`
- `AuroraMeter.CreditsRecurrencesConcurrencyTest` / `test I18 a rendezvous that guarantees the race issues exactly one grant per period`
- `AuroraMeter.CreditsRecurrencesConcurrencyTest` / `test I18 the ledger's reference index refuses a second grant even with the recurrence guard bypassed`
- `AuroraMeter.CreditsRecurrencesConcurrencyTest` / `test I18 a per-run reference double-grants under the same rendezvous`
- `AuroraMeter.CreditsRecurrencesConcurrencyTest` / `test I18 a debit racing the recurrence leaves the carry computed from the committed availability`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a catch-up period before an upgrade is granted at the version that period was sold under`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a recurrence key written before this unit is not granted a second time`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a recurring grant uses the plan version effective for the period`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a tenant pinned to version 2 is granted version 2's allowance and key`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a transition at a period boundary produces one grant for each period at its own version`
- `AuroraMeter.CreditsRecurrencesVersionsTest` / `test I18 a version 2 that drops the allowance does not stop a version 1 tenant being paid`

**Evidence.** `docs/evidence/v1/phase-06/i18-once-per-period.md`

## I19 All supported schema histories preserve commercial state

**Guarantee.** `AuroraMeter.Migration` exposes one pinned, versioned migration per
schema step, and the package's own bookkeeping is checked rather than trusted:
every version up to the latest has a module and none beyond it, the moduledoc
lists exactly those versions, and the test database is migrated through every one
of them by pinned `up(from:, version:)` calls. An unpinned `up(from: n)` is
refused, because it would run to whatever the latest version happened to be on the
day it first applied, so two databases built from the same migrations would end up
with different schemas.

**Prerequisites.** PostgreSQL. The host generates its migration with
`mix aurora_meter.gen.migration`, which embeds the template in code rather than
shipping `priv/`.

**Known limits.** The structural checks prove that the version ladder is complete
and pinned. Build unit 03a adds running proof for core schema versions 7 and 8:
every published starting point reaches both, a fresh install and an incremental
upgrade produce identical catalogues, and an interrupted backfill resumes to the
same bytes. Those run against small disposable databases the tests seed
themselves. They do not prove that a *populated customer* database upgrades
without losing commercial state, or that a backup and restore round trips: those
need the populated upgrade fixtures of the phase 11 migration rehearsal, whose
evidence lives in the storefront repository because it exercises core, Pro and
the storefront together.

**Tests.**

- `AuroraMeter.MigrationTest` / `test every version up to the latest has a module, and none beyond it`
- `AuroraMeter.MigrationTest` / `test the moduledoc describes every version`
- `AuroraMeter.MigrationTest` / `test the test database is migrated through every version`
- `AuroraMeter.MigrationTest` / `test I19 up/1 records the reached version in the checkpoints table`
- `AuroraMeter.MigrationV7Test` / `test the ladder I19 a fresh install and an incremental upgrade produce the same catalogue`
- `AuroraMeter.MigrationV7Test` / `test the ladder I19 each published schema history reaches 7 and then 8`
- `AuroraMeter.MigrationV7Test` / `test the ladder I19 the schema marker is absent below version 7`
- `AuroraMeter.MigrationV9Test` / `test I19 a fresh install and an incremental upgrade to 9 produce the same catalogue`
- `AuroraMeter.MigrationV9Test` / `test I19 version 9 creates the lot, allocation and recurrence tables with their constraints`
- `AuroraMeter.MigrationV9Test` / `test I19 version 9 is additive over a database that already holds credit rows`
- `AuroraMeter.MigrationV9Test` / `test I19 version 9 refuses a database whose balance rows already violate the new checks`
- `AuroraMeter.MigrationV9Test` / `test I19 down(version: 9) without confirm_data_loss raises`
- `AuroraMeter.MigrationV9Test` / `test I19 version 9 is idempotent: running it twice changes nothing`
- `AuroraMeter.EventsBackfillTest` / `test filling every legacy row I19 it fills every row, and no row twice`
- `AuroraMeter.EventsBackfillTest` / `test filling every legacy row I19 it is idempotent: a second run updates nothing and changes no hash`
- `AuroraMeter.EventsBackfillTest` / `test filling every legacy row I19 a run killed between batches resumes byte for byte`
- `AuroraMeter.EventsBackfillTest` / `test filling every legacy row I19 rows an old writer inserts during the run are picked up by the same pass`
- `AuroraMeter.MigrationV10Test` / `test I19 a fresh install and an incremental upgrade to 10 produce the same catalogue`
- `AuroraMeter.MigrationV10Test` / `test I19 a populated version 9 database upgrades with no subscription changed`
- `AuroraMeter.MigrationV10Test` / `test I19 down of version 10 removes both tables and every column it added`
- `AuroraMeter.MigrationV10Test` / `test I19 version 10 creates both plan tables and every subscription column with its checks`
- `AuroraMeter.MigrationV10Test` / `test I19 version 10 is on the data-loss list, so its down needs confirm_data_loss`
- `AuroraMeter.MigrationV10Test` / `test I19 version 10 refuses a plan version fingerprint that is not 32 bytes`
- `AuroraMeter.MigrationV10Test` / `test I19 version 10 refuses a transition state it does not know`
- `AuroraMeter.MigrationV10Test` / `test I19 version 10 run twice is a no-op`
- PLANNED (11a): `AuroraMeter.MigrationFixtureTest` / `test I19 a populated core1 database upgrades with every total preserved`
- PLANNED (11a): `AuroraMeter.MigrationFixtureTest` / `test I19 an interrupted backfill resumes without double counting`

The wallet migration onto credit lots is the one data step in this package that
rewrites how a wallet's money is accounted for. It is checked against figures
the legacy ledger itself wrote: every row's `balance_after` and `held_after`
during the fold, and the balance row before the cutover commits. The first
group below replays populated wallets; the second is the refusals, one wallet
per reason; the third is the migration killed, resumed and raced.

- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a paid-only wallet replays into one lot per grant, spent oldest first`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 overlapping promotional grants replay soonest-expiry first, before paid`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a non-expiring promotional lot sorts last within its category`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a settlement above its hold replays into consume and debt`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a released hold hands its reservation back to the lot it came from`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a refund is attributed to the payment that funded it, not to spend order`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a dispute reversal carrying a dispute id in its reference resolves the payment`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a reconciled reversal and its restore adjustment both name the payment`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a reinstatement adjustment is a lot the same payment's reversal can reach`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a promotional grant that landed on debt keeps its amount and repays the debt`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 every fixture wallet migrates with balance, held and promotional unchanged`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 one lot per grant row, and every allocation names the ledger row that caused it`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 migration writes debt and expired and leaves the three legacy figures alone`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a shadow run reaches the same verdict as the real run that follows it`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a migrated wallet keeps answering the public credit API`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a recurring grant cannot reach a wallet the migration has yet to replay`
- `AuroraMeter.CreditsLotMigrationPropertyTest` / `property I19 a generated legacy history replays into lots that reproduce its balance row`

Refusals. A migration that cannot reproduce a wallet exactly must leave it
alone, and a refusal nobody can demonstrate is not a refusal:

- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a reversal with no resolvable payment intent blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a reversal larger than the lots that payment funded blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a reversal that would take reserved value blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 an adjustment whose restore reference names no payment blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a hold the overdraft tolerance allowed but no lot can back blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a settle with no hold in the history blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a release with no hold in the history blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a row of a kind the fold has no rule for blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 an expire row that names no grant blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 an expire row larger than the grant it names blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test X261 an expiry that destroyed a grant a hold had reserved blocks the wallet`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test X276 an expiry the legacy attribution over-counted because a hold blocked a spend`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 a history no ordering can reconcile blocks rather than migrating wrong`
- `AuroraMeter.Credits.LotMigrationReplayTest` / `test I19 every flag the fold raises is classified, and a blocking one halts the fold`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a blocked wallet keeps lots_enabled_at null, has no lots and records its reason`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 every blocking flag has a wallet that triggers it and none of them migrate`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a wallet larger than max_rows is deferred, paused and left untouched`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a run with a blocked wallet fails the Mix task rather than reporting success`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a wallet a previous run blocked is still counted as blocked by the next one`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 down(version: 9) refuses without confirm_data_loss, which is what protects the lots`

Interrupt, resume and concurrency, on independent connections:

- `AuroraMeter.CreditsLotMigrationTest` / `test I19 the run reports every wallet it examined, and the summary counts them`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 the scan resumes from the aggregate cursor and skips what is behind it`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 report-only re-reports a migrated wallet without demoting its verdict`
- `AuroraMeter.CreditsLotMigrationTest` / `test I19 status reports the aggregate cursor and every wallet verdict`
- `AuroraMeter.CreditsLotMigrationResumeTest` / `test I19 a ledger write committed during the snapshot lands in the tail, not in the snapshot`
- `AuroraMeter.CreditsLotMigrationResumeTest` / `test I19 a rerun after a completed run writes nothing and reports the wallet as skipped`
- `AuroraMeter.CreditsLotMigrationResumeTest` / `test I19 the aggregate checkpoint records the run and its cursor across two runs`

The wallet migration's own run reports, fixture catalogue, blocked catalogue
and lock durations are under `docs/evidence/v1/phase-06/`, named from the
phase 11 evidence below.

- `AuroraMeter.CreditsLotMigrationTest` / `test I19 a wallet holding a reverse row migrates and reconciles, and so does one holding the legacy shape (X266)`

**Evidence.** `storefront:docs/evidence/v1/phase-11/i19.md`

## I20 Optional integrations remain optional and tenant-safe

**Guarantee.** Phoenix LiveView, Phoenix HTML, Igniter, Oban,
`telemetry_metrics`, `phoenix_live_dashboard` and `opentelemetry_api` are
declared optional in `mix.exs`, and the metering, entitlement and credit paths do
not reference them. Five pieces of code do, and each is compiled behind a guard
rather than assumed:
`lib/aurora_meter/live_dashboard/page.ex` opens with
`if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do` and
`lib/aurora_meter/open_telemetry.ex` with `if Code.ensure_loaded?(:otel_tracer) do`,
and in both cases everything the page or the bridge is judged on lives in a
module that is **not** guarded (`AuroraMeter.LiveDashboard.Sections`,
`AuroraMeter.LiveDashboard.Auth`, `AuroraMeter.OpenTelemetry.Bridge`), so a build
with no optional dependency still compiles and still tests the behaviour;
`lib/aurora_meter/components.ex` opens with `if Code.ensure_loaded?(Phoenix.Component) do`,
so on a build without LiveView the components module simply is not defined;
`lib/aurora_meter/oban.ex` and every file under `lib/aurora_meter/oban/` open
with `if Code.ensure_loaded?(Oban) do`, so on a build without Oban there is no
`AuroraMeter.Oban` namespace and every operation those workers wrap is still a
public function any scheduler can call; and
`mix aurora_meter.install` is defined either way, falling back from the Igniter
one-step installer to a plain Mix task that generates the migration and prints
the remaining steps. On a build with no optional dependency present, the facade,
the credit ledger and the migration ladder all still work.

This is asserted in **both** directions, which matters more than it sounds: a
one-directional assertion would pass for the wrong reason the day an optional
dependency quietly stopped being fetched. `AuroraMeter.OptionalIntegrationsTest`
carries no tag and runs on every CI leg, asserting that the optional modules are
loaded exactly when they were not switched off, and that the components module is
compiled exactly when `Phoenix.Component` is. `AuroraMeter.HeadlessTest` asserts
the absence half on the one leg where absence is true.

**Prerequisites.** None for the headless path. The components require
`phoenix_live_view` and `phoenix_html`; the one-step installer requires `igniter`.
The absence half additionally requires a build made with `AURORA_HEADLESS=1`,
which is what removes the optional dependencies; its `setup` refuses to run
otherwise rather than passing vacuously.

**Known limits.** The three absence tests are tagged `:headless` and excluded by
default, so an ordinary `mix test` proves only the presence half. The absence half
is proved on exactly one CI leg. That is a deliberate trade and not a gap, but it
means a developer who breaks the headless build locally will not learn it until
CI runs.

The headless leg proves that the package compiles and that its facade, credits and
migrations work without the optional dependencies. It does **not** prove that a
dashboard is safe to expose: host-level authentication and tenant scoping for the
components, and the Pro LiveView dashboard's session tenant requirement, are phase
08 and phase 09 work. The components currently use LiveView 1.0 interpolation
syntax while `mix.exs` claims `~> 0.20 or ~> 1.0` (open finding C9), so the
supported range is itself unproven until that is resolved, and the `liveview-0.20`
CI leg fails by design until 09b settles it.

**Tests.**

- `AuroraMeter.OptionalIntegrationsTest` / `test I20 the optional integrations are present exactly when they were not switched off`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AuroraMeter.Components is compiled exactly when Phoenix.Component is available`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 the install task exists either way, with or without Igniter`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 the AuroraMeter.Oban namespace is compiled exactly when Oban is available`
- `AuroraMeter.HeadlessTest` / `test I20 the AuroraMeter.Oban namespace is absent without Oban`
- `AuroraMeter.HeadlessTest` / `test I20 Components are not compiled without Phoenix.Component`
- `AuroraMeter.HeadlessTest` / `test I20 the installer prints steps instead of raising without Igniter`
- `AuroraMeter.HeadlessTest` / `test I20 the facade, credits and migrations work with no optional dependency present`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AuroraMeter.Telemetry.Metrics is compiled exactly when Telemetry.Metrics is available`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AuroraMeter.Telemetry itself never depends on the optional dependency`
- `AuroraMeter.HeadlessTest` / `test I20 AuroraMeter.Telemetry.Metrics is absent without telemetry_metrics`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 the LiveDashboard page is compiled exactly when phoenix_live_dashboard is available`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AURORA_NO_DASHBOARD removes the dashboard dependency and nothing else`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AuroraMeter.OpenTelemetry is compiled exactly when opentelemetry_api is available`
- `AuroraMeter.OptionalIntegrationsTest` / `test I20 AURORA_NO_OTEL removes the OpenTelemetry pair and nothing else`
- `AuroraMeter.HeadlessTest` / `test I20 the dashboard page and the OpenTelemetry bridge are absent without their dependencies`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 dashboard page refuses without host auth: init/1 raises ArgumentError when :authorized_by is absent`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 dashboard page refuses without host auth: an unrecognised form raises and names the three`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 dashboard page refuses without host auth: a check returning false renders the refusal panel and no section data`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 dashboard page refuses without host auth: a check that raises is treated as false and logs a warning`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 {:assign, key} requires the assign to be exactly true, not truthy`
- `AuroraMeter.LiveDashboard.PageTest` / `test I20 the core page accepts :host_route, because it renders no tenant-identifying value`
- `AuroraMeter.RealtimeTest` / `test usage_meter renders the value and progressbar semantics`
- `Mix.Tasks.AuroraMeter.InstallTest` / `test wires config, supervision child, a plans module and the migration`
- NOT 08b's, and recorded rather than dropped: `AuroraMeter.ComponentsAuthTest` /
  `test I20 a usage component refuses to render without a host resolved tenant`.
  This line said PLANNED (08b). 08b's build document scopes the components out
  by name (it owns the two dashboard pages, the OpenTelemetry bridge and the Pro
  LiveView tenant fix), and `AuroraMeter.Components` takes the tenant from the
  caller and has no authorization decision of its own to refuse. The LiveView
  helpers are 09a's. See `open-findings.md` X333.
- `AuroraMeter.EntitlementsTest` / `test I20 every Noop billing provider callback returns :not_configured`
- PLANNED (09b): `AuroraMeter.RealtimeTest` / `test I20 every quota kind renders its own wording`
- PLANNED (09b): `AuroraMeter.RealtimeTest` / `test I20 a single-point and an empty series render without a broken chart`

**Evidence.** `docs/evidence/v1/phase-08/i20.md`

I20's first real proof is earlier than its evidence path suggests: the headless CI
leg landed in phase 01 and its record is `docs/evidence/v1/phase-01/ci.md`
(section 11.1). The phase-08 file is the invariant's home and must link back to
it. `invariant-map.md` currently gives I20 phase-08 and phase-09 only, and should
list phase-01 as well.

## I21 Public installation instructions resolve real artifacts

**Guarantee.** The code printed in the guides is executed, not merely proofread.
`AuroraMeter.ExamplesTest` extracts the snippets and plans modules from
`docs/examples/*.md` and asserts that each one compiles and behaves exactly as the
guide says, so a guide that drifts from the API fails the suite. `mix docs` builds
in the package gate, so a reference to a function that moved, or an extra that does
not exist, fails there.

**Prerequisites.** The guides under `docs/examples/` keep the fenced block shapes
the test extracts.

**Known limits.** This proves the snippets are true of the source in this working
tree. It does not prove that a clean-room install from the published Hex archive
resolves, that the version numbers printed in the install instructions exist on
Hex, or that the storefront and email snippets match the package. Those are the
phase 11 package smoke and clean-room installs, whose evidence lives in the
storefront repository.

**Tests.**

- `AuroraMeter.ExamplesTest` / `test concepts.md track/3 adds, and usage/2 reads it back`
- `AuroraMeter.ExamplesTest` / `test team-saas.md the plans module carries exactly what the guide prints`
- `AuroraMeter.ExamplesTest` / `test allowance-and-overage.md the plans module carries exactly what the guide prints`
- `AuroraMeter.ExamplesTest` / `test prepaid-credits.md the plans module carries exactly what the guide prints`
- `AuroraMeter.ExamplesTest` / `test showing-usage.md spend_history/2 is zero-filled and oldest first`
- PLANNED (11c): `AuroraMeter.InstallInstructionsTest` / `test I21 every version named in the install instructions exists in the candidate archive`

**Evidence.** `storefront:docs/evidence/v1/phase-11/i21.md`
