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
- `AuroraMeter.KillTest` / `test I03 Counter.commit_work after a Store restart raises (C6, fixed in 03b)`
- `AuroraMeter.ExamplesTest` / `test team-saas.md with_quota/3 gives the reservation back when the work raises`

The three catchable-failure cases that give the capacity back (a raise, a throw
and an exit) are named under I04, whose guarantee is the one they measure.

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

The last two are build unit 02b's contribution: `:undeclared_feature_policy` adds
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
back while the ETS increment stays (open finding C14). There is no event identity
and therefore no deduplication on retry today: a caller that retries a durable
`track/4` writes a second row. Event quantity is a 32 bit column (open finding
C13). None of these are fixed by this index; they are named so that a reader
cannot mistake the current behaviour for the phase 03 guarantee.

**Tests.**

- `AuroraMeter.MeteringTest` / `test a durable feature writes an event row on track`
- `AuroraMeter.StorageTest` / `test insert_events/1 appends rows`
- PLANNED (03b): `AuroraMeter.EventsTest` / `test I06 a kill before commit leaves nothing behind`
- PLANNED (03b): `AuroraMeter.EventsTest` / `test I06 a kill after commit before reply then a same id retry reports a duplicate`
- PLANNED (03b): `AuroraMeter.EventsTest` / `test I06 restart and replay reproduce the same totals`

**Evidence.** `docs/evidence/v1/phase-03/i06.md`

## I07 Conflicting reuse of event identity is rejected

**Guarantee.** Not guaranteed by the shipped code. Phase 03 introduces event
identity and a canonical form, after which reusing an identity with a changed
quantity, timestamp, feature, dimension set or metadata is rejected rather than
silently accepted or silently ignored, including under same tenant races and
inside batches, where a single conflict rolls the batch back.

**Prerequisites.** The phase 03 durable event path, the Ecto storage adapter and
the schema version that adds the event identity constraint.

**Known limits.** Nothing in the current release rejects a conflicting reuse,
because there is no event identity to conflict with. Until phase 03 lands, a host
that needs this must deduplicate before calling `track/4`. A guarantee statement
must not be copied from this section into customer-facing documentation before its
tests exist.

**Tests.**

- PLANNED (03b): `AuroraMeter.EventsTest` / `test I07 a changed quantity, time, feature, dimension set or metadata each conflict`
- PLANNED (03b): `AuroraMeter.EventsTest` / `test I07 twelve independent connections racing one identity admit one`
- PLANNED (03b): `AuroraMeter.EventsTest` / `test I07 one conflict rolls the whole batch back`

**Evidence.** `docs/evidence/v1/phase-03/i07.md`

## I08 One input source yields one commercial usage effect

**Guarantee.** Today this holds by construction rather than by enforcement:
durable event rows are written alongside the ETS counter but are never read by the
billing path, and the only thing a Pro reporter bills is a persisted counter. So a
unit of usage produces exactly one commercial effect because there is only one
commercial path. Phase 03 makes the source explicit per feature and enforces it,
so a feature whose source is events never appears in a flush batch, calling
`track/4` on an events sourced feature raises rather than double counting, and a
cutover from buffered to events happens at a watermark with the buffer drained
first.

**Prerequisites.** A single configured source per feature. While both paths exist,
the host must not also bill from the event log by hand.

**Known limits.** There is no configuration today that prevents a host from
reading `aurora_meter_events` and billing it in addition to the counters. Pro
rollups do read durable events directly when `history: false` (open finding C15),
which is a reporting read rather than a billing read, but it is the shape of the
double counting this invariant will forbid. The enforcement, and the cutover
watermark, belong to phase 03 and phase 04.

**Tests.**

- `AuroraMeter.MeteringTest` / `test a durable feature writes an event row on track`
- PLANNED (03c): `AuroraMeter.SourcesTest` / `test I08 a feature sourced from events never appears in a flush batch`
- PLANNED (03c): `AuroraMeter.SourcesTest` / `test I08 calling track on an events sourced feature raises`
- PLANNED (03c): `AuroraMeter.SourcesTest` / `test I08 a cutover at the watermark drains the buffer and takes events after it`

**Evidence.** `docs/evidence/v1/phase-03/i08.md`

## I09 Corrections preserve immutable history and bounded net quantity

**Guarantee.** Not guaranteed by the shipped code: there is no correction entry
point on the facade and no correction record. Phase 03 adds one, after which a correction appends
rather than mutates, concurrent partial corrections cannot exceed the original
quantity, a full reversal refuses any further correction, a duplicate correction
id is idempotent, and a correction after the provider's window opens a
reconciliation item instead of silently diverging.

**Prerequisites.** The phase 03 durable event path and its correction schema.

**Known limits.** The only correction available today is a negative `track/4`,
which mutates the counter in place, leaves no record of what was corrected and is
bounded by nothing. Hosts using it must keep their own audit trail.

**Tests.**

- `AuroraMeter.ExamplesTest` / `test allowance-and-overage.md a negative track/3 corrects an overcount`
- PLANNED (03e): `AuroraMeter.CorrectionsTest` / `test I09 concurrent partial corrections cannot exceed the original`
- PLANNED (03e): `AuroraMeter.CorrectionsTest` / `test I09 a full reversal refuses a further correction`
- PLANNED (03e): `AuroraMeter.CorrectionsTest` / `test I09 a duplicate correction id is idempotent`

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

"After the transaction commits" is true only of a ledger call that owns its
transaction. Inside a host transaction the ledger's is nested, so what
`transact_outcome/1` sees returning is a savepoint release; telemetry, PubSub and
the low-balance handler all fire, and the host can still roll back afterwards,
leaving a handler that saw a balance no reader will ever find (open finding L18).
`AuroraMeter.CreditsConcurrencyTest` asserts that current behaviour so 06c has a
before and after; 06c detects `in_transaction?/0` and defers the side effects.

Three further limits the generated histories exposed, each with a test that
asserts today's behaviour so its fixing unit has a before and an after:

- **L17**: no amount is range checked anywhere in `lib/`. A figure beyond `bigint`
  is refused by Postgrex's encoder as a `DBConnection.EncodeError` before any
  statement is sent, which is a driver message rather than an answer from the
  ledger. 06c adds `Money.assert_range!/1` at the facade.
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

`expire_due/1`'s own doc (`credits.ex:619-621`) still says expiry assumes at most
one live promotional grant, which contradicts `Promotions.consume/3`'s
soonest-first attribution (`promotions.ex:48-61`). The model implements the code;
the doc is wrong (finding L15, 06c).

**Tests.**

- `AuroraMeter.CreditsTest` / `test the ledger as a record every entry says what the promotional figure became`
- `AuroraMeter.CreditsTest` / `test promotional credit is consumed before paid credit`
- `AuroraMeter.CreditsTest` / `property Money cents round-trip through micro-dollars`
- `AuroraMeter.CreditsTest` / `test Money rounding modes and precision`
- `AuroraMeter.CreditsTest` / `test history/2 is newest first, hides holds and releases by default, filters by kind and pages`
- `AuroraMeter.CreditsConcurrencyTest` / `test I10 a refusal does not destroy the caller's own transaction`
- `AuroraMeter.CreditsConcurrencyTest` / `test I10 a host transaction that rolls back undoes the ledger row although the side effects already fired (L18, fixed in 06c)`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 a generated history of grants, holds, settles, releases, debits and reversals matches the pure model`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 a generated history including expiry matches the pure model`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 balance equals the sum of every transaction amount after every step`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 held equals the sum of open holds after every step`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 the newest row's snapshot columns equal the balance row`
- `AuroraMeter.CreditsModelTest` / `property generated histories I10 no two rows of one kind share a reference`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 cents round-trip through micro-dollars at the boundaries`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 to_cents rounds half away from zero at the boundaries`
- `AuroraMeter.CreditsRegressionsTest` / `test every saved seed file parses and names an invariant`

These four assert a defect rather than a guarantee, and each names the unit that
replaces it. Read them as the "before" half of a change, not as something the
ledger promises:

- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 a grant at the bigint ceiling is refused by the database (L17, fixed in 06c)`
- `AuroraMeter.CreditsModelTest` / `test integer bounds and rounding I10 a reversal at the bigint floor is refused by the database (L17, fixed in 06c)`
- `AuroraMeter.CreditsModelTest` / `test ordering the query does not fix I10 two grants due in one pass expire in an order the query does not fix (L19, fixed in 06a)`
- `AuroraMeter.CreditsModelTest` / `test the clock the ledger orders itself by I10 a backwards step in the wall clock leaves a promotional grant that can never expire (L20, fixed in 06a)`
- PLANNED (06a): `AuroraMeter.CreditsLotTest` / `test I10 the lot conservation constraint rejects drift`

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

**Tests.**

- `AuroraMeter.CreditsConcurrencyTest` / `test I11 twenty concurrent $0.10 holds against $1.00 admit exactly ten`
- `AuroraMeter.CreditsConcurrencyTest` / `test I11 concurrent settle and release of one hold: exactly one wins`
- `AuroraMeter.CreditsConcurrencyTest` / `test I11 fifty independent connections holding against one hot wallet admit exactly the funded count`
- `AuroraMeter.CreditsTest` / `test hold/4, settle/3, release/1 a hold is refused when the available balance does not cover it`
- `AuroraMeter.CreditsTest` / `test with_credits/4 releases when the function raises, throws or exits, then propagates`
- PLANNED (05b): `AuroraMeter.CreditsConcurrencyTest` / `test I11 a callback racing the reconciler produces one terminal transition`

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

**Known limits.** The current allocator assumes at most one live promotional grant
per tenant. Overlapping promotions are handled correctly for the cases in the
tests below, but the general multi grant case is the subject of the phase 06 lot
model, which replaces the single promotional figure with per lot accounting.

Expiry is a pass, not a property of the money. Value that a hold had reserved on
an already expired grant is spendable again the moment the hold is released, and
stays spendable until the next `expire_due/1` pass runs (open finding L1).
`AuroraMeter.CreditsTest` asserts that current behaviour so 06a has a before and
after; 06a's lot model makes the released value expired rather than spendable.

**Tests.**

- `AuroraMeter.CreditsTest` / `test promotional credit I12 expiry never claws back credit a hold has reserved`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a grant expires only its own remainder`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a new expiring grant cannot absorb spending that predates it`
- `AuroraMeter.CreditsTest` / `test promotional credit I12 a release after the grant expired returns spendable credit (L1, fixed in 06a)`
- `AuroraMeter.CreditsTest` / `test promotional credit expire_due/1 expires only what is left, once, and never below zero`
- `AuroraMeter.CreditsTest` / `test promotional credit a promotional grant landing on a negative balance first repays the debt`
- PLANNED (06a): `AuroraMeter.CreditsLotTest` / `test I12 overlapping promotions each expire only their own remainder`
- PLANNED (06a): `AuroraMeter.CreditsLotTest` / `test I12 value reserved on an expired lot becomes expired, not spendable, when released`
- PLANNED (06a): `AuroraMeter.CreditsLotTest` / `test I12 expiry racing a settlement conserves the total`

**Evidence.** `docs/evidence/v1/phase-06/i12.md`

## I16 Worker scheduling is not an exactly-once assumption

**Guarantee.** The core half of this invariant is that a periodic job run twice
produces one effect. `expire_due/1` is written to be run from a scheduler and
expires a grant once however often it is called, and a flush with nothing pending
writes nothing. Aurora Meter does not claim exactly-once host job execution
anywhere: every scheduled entry point is idempotent on its own state instead.

**Prerequisites.** The Ecto storage adapter. The host owns the scheduler; the core
ships no job runner.

**Known limits.** The core has no lease tokens and no checkpoints, so a long
running scheduled operation that is interrupted restarts rather than resumes. The
lease and checkpoint half of this invariant lives in Pro, whose workers run under
Oban, and in phase 05. Nothing here promises that two schedulers cannot run
concurrently; it promises that the effect is the same if they do.

**Tests.**

- `AuroraMeter.CreditsTest` / `test promotional credit expire_due/1 expires only what is left, once, and never below zero`
- `AuroraMeter.MeteringTest` / `test flush persists ETS values and repeated flushes are idempotent`
- `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference`
- PLANNED (05c): `AuroraMeter.SchedulingTest` / `test I16 duplicate runs from two schedulers produce one effect`
- PLANNED (05c): `AuroraMeter.SchedulingTest` / `test I16 a resumed operation restarts at its checkpoint after a kill`

**Evidence.** `docs/evidence/v1/phase-05/i16.md`

## I17 Historical plans remain stable

**Guarantee.** Not guaranteed by the shipped code. Plans are declared in a
compile-time DSL and resolved by id at read time, so redeploying a changed
definition changes what an existing tenant is entitled to, immediately and
silently. Phase 07 adds immutable plan versions and a `plan_version` on the
subscription, after which deploying a changed definition of an already used
version raises at registration, a tenant stays on the version it was subscribed
on until an explicit scheduled migration moves it, and a stale provider
notification cannot move a version.

**Prerequisites.** The phase 07 plan registry and the subscription schema change
that records the version.

**Known limits.** Today the only protections are compile-time: a duplicate feature
declaration and a negative limit both raise while the plans module compiles, and an
integer feature must be a non-negative integer. Those keep a plans module
internally consistent; they do nothing about a tenant's entitlement changing under
it between deploys. Any customer-facing claim of plan stability must wait for
phase 07.

**Tests.**

- `AuroraMeter.PlansTest` / `test a duplicate feature raises at compile time`
- `AuroraMeter.PlansTest` / `test a negative limit raises at compile time`
- `AuroraMeter.SubscriptionsTest` / `test a subscription that is not in an entitled status falls back to the default plan`
- PLANNED (07a): `AuroraMeter.PlanVersionsTest` / `test I17 deploying a changed definition of a used version raises`
- PLANNED (07a): `AuroraMeter.PlanVersionsTest` / `test I17 a tenant stays on v1 after v2 is deployed`
- PLANNED (07a): `AuroraMeter.PlanVersionsTest` / `test I17 a stale provider notification cannot move the version`

**Evidence.** `docs/evidence/v1/phase-07/i17.md`

## I18 Recurring grants occur once per entitlement period

**Guarantee.** Not guaranteed by the shipped code: there is no recurrence
scheduler. What exists today is the primitive the guarantee will be built on, an
idempotency key on every grant, so a grant retried with the same reference returns
the original entry instead of crediting twice. Phase 06 adds recurrences with a
uniqueness key per entitlement period, after which downtime catch up grants
chronologically and once per missed period, rollover is capped, two schedulers
produce one grant, and a cancellation or a plan transition lands on the correct
side of the boundary.

**Prerequisites.** The phase 06 recurrence schema and a host scheduler.

**Known limits.** A host implementing recurring allowances today must supply its
own period key in the grant reference. Nothing in the core computes the
entitlement period for a grant, so nothing in the core can refuse a second grant
for the same period under a different reference.

**Tests.**

- `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference`
- `AuroraMeter.CreditsTest` / `test grant/3 a duplicate grant reports duplicate: true in telemetry and does not broadcast`
- PLANNED (06d): `AuroraMeter.RecurrencesTest` / `test I18 downtime catch up grants each missed period once, in order`
- PLANNED (06d): `AuroraMeter.RecurrencesTest` / `test I18 rollover is capped at the configured maximum`
- PLANNED (06d): `AuroraMeter.RecurrencesTest` / `test I18 two schedulers produce one grant`
- PLANNED (06d): `AuroraMeter.RecurrencesTest` / `test I18 cancellation and transition land on the correct side of the boundary`

**Evidence.** `docs/evidence/v1/phase-06/i18.md`

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
and pinned. They do not prove that a *populated* database upgrades without losing
commercial state, that an interrupted backfill resumes correctly, or that a backup
and restore round trips: those need populated upgrade fixtures and are the phase 11
migration rehearsal, whose evidence lives in the storefront repository because it
exercises core, Pro and the storefront together.

**Tests.**

- `AuroraMeter.MigrationTest` / `test every version up to the latest has a module, and none beyond it`
- `AuroraMeter.MigrationTest` / `test the moduledoc describes every version`
- `AuroraMeter.MigrationTest` / `test the test database is migrated through every version`
- PLANNED (11a): `AuroraMeter.MigrationFixtureTest` / `test I19 a populated core1 database upgrades with every total preserved`
- PLANNED (11a): `AuroraMeter.MigrationFixtureTest` / `test I19 an interrupted backfill resumes without double counting`

**Evidence.** `storefront:docs/evidence/v1/phase-11/i19.md`

## I20 Optional integrations remain optional and tenant-safe

**Guarantee.** Phoenix LiveView, Phoenix HTML and Igniter are declared optional in
`mix.exs`, and the metering, entitlement and credit paths do not reference them.
Two pieces of code do, and each is compiled behind a guard rather than assumed:
`lib/aurora_meter/components.ex` opens with `if Code.ensure_loaded?(Phoenix.Component) do`,
so on a build without LiveView the components module simply is not defined; and
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
- `AuroraMeter.HeadlessTest` / `test I20 Components are not compiled without Phoenix.Component`
- `AuroraMeter.HeadlessTest` / `test I20 the installer prints steps instead of raising without Igniter`
- `AuroraMeter.HeadlessTest` / `test I20 the facade, credits and migrations work with no optional dependency present`
- `AuroraMeter.RealtimeTest` / `test usage_meter renders the value and progressbar semantics`
- `Mix.Tasks.AuroraMeter.InstallTest` / `test wires config, supervision child, a plans module and the migration`
- PLANNED (08b): `AuroraMeter.ComponentsAuthTest` / `test I20 a usage component refuses to render without a host resolved tenant`
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
