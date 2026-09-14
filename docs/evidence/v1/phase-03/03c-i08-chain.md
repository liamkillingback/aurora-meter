# 03c: the I08 chain, and the cuts this unit makes in it

**I08: one input source yields one commercial usage effect.**

This file traces, link by link, the only path by which a quantity metered in
Aurora Meter becomes money at a provider, and then shows where build unit 03c
cuts that path for a feature whose reporting source is `:events`.

Every reference is a **symbol**, never a line number, and every symbol was read
in the source at the SHAs below rather than recalled. A line number is wrong as
soon as anything above it is edited, which this programme has recorded happening
twice inside a day (`open-findings.md` X67, X90, X93, X108).

Verified 2026-09-14 (UTC) against core working tree on `6d798c0` and Pro
`0da7e1d`.

## Part 1: the chain, as it exists

Nine links. The first six are core, the last three Pro.

| # | Symbol | Repository | What it does to the quantity |
|---|---|---|---|
| 1 | `AuroraMeter.track/4` | core | resolves the tenant key and the period, then calls link 2 |
| 2 | `AuroraMeter.Counter.incr/4` | core | calls `Counter.bump/2` for the period key and `Counter.bump_history/4` for the UTC day key |
| 3 | `AuroraMeter.Counter.bump/2` (private) | core | one `:ets.update_counter/3` writing `value`, `pending_flush` **and** `pending_gossip`, then `Counter.mark_dirty/1` |
| 4 | `AuroraMeter.Counter.mark_dirty/1` | core | inserts the key into `AuroraMeter.Store`'s dirty table and its touched table |
| 5 | `AuroraMeter.Store.snapshot/0` (private, reached through `Store.snapshot_flush_batch/0`) | core | builds a batch from `Counter.dirty_keys/0` and `Counter.take_pending(key, :flush)`, dropping zero deltas |
| 6 | `AuroraMeter.Flusher.persist/1` (private) | core | calls `AuroraMeter.Storage.flush_batch/3` with that batch |
| 7 | `AuroraMeter.Storage.Ecto.flush_batch/3` | core | inside one transaction, writes the receipt and calls `Storage.Ecto.add_counters/1`, which upserts `aurora_meter_counters` |
| 8 | `AuroraMeter.Pro.UsageReporter.report_one/5` | Pro | reads that row through `AuroraMeter.Storage.load_counter/3`, computes `delta = usage - last_reported`, and stages an immutable payload |
| 9 | `AuroraMeter.Pro.UsageReporter.send_pending/1` to `AuroraMeter.Pro.Stripe.report_usage/1` to `Stripe.Billing.MeterEvent.create/2` | Pro | delivers the payload, with `identifier` as the idempotency key |

Two facts follow from reading those nine, and they are what make the invariant
provable rather than merely intended.

**First: there are exactly two writers of `pending_flush`.** `Counter.bump/2`
(link 3) and `Counter.commit_work/5`. Both call `Counter.mark_dirty/1`. Link 5
builds the batch from the dirty table and from `pending_flush`, so a key that is
never marked dirty and never carries a `pending_flush` delta cannot appear in a
flush batch, and therefore cannot reach link 7 or anything after it.

**Second: the reporter reads the persisted counter, not ETS.** Link 8 is
`AuroraMeter.Storage.load_counter/3`. It follows that keeping a projected
quantity out of `aurora_meter_counters` is both **sufficient** (nothing else is
read for billing) and **necessary** (anything that lands there is billable) for
I08 on this path.

`AuroraMeter.Pro.UsageReporter.metered_features/1` (private) narrows which
features are considered to the plan's `{:metered, _, _}` entries that have a
`stripe_meters` mapping, which is a further filter and not a safety property:
a feature that is both metered and mapped, which is the only kind anyone bills,
passes it.

## Part 2: what a durable event does instead

`AuroraMeter.record/4` reaches `AuroraMeter.Events.record/4` and
`AuroraMeter.Storage.Ecto.record_events/2`, which commits the event row, its
`aurora_meter_event_totals` delta and the configured export intent in one
transaction. After the commit, `AuroraMeter.Counter.apply_projection/2` moves
this node's in-memory view.

`apply_projection/2` is deliberately shaped like `Counter.apply_remote/2` and not
like `Counter.bump/2`:

    :ets.update_counter(table(), key, [{@value, qty}, {@pending_gossip, qty}])
    :ets.insert(Store.touched_table(), {key})

`value` moves so `AuroraMeter.usage/2` and the quota functions answer.
`pending_gossip` moves so peers converge. `pending_flush` is **not** written and
`mark_dirty/1` is **not** called, so link 4 never happens and link 5 has nothing
to find.

That function was written by build unit 03b. 03c owns the invariant, which means
03c owns closing every *other* way in.

## Part 3: the cuts 03c makes

There are exactly four ways a quantity for an events-source feature could still
have reached `pending_flush`, and each is now closed. The table names the symbol
that closes it and the test that proves it.

| # | The way in | The cut | Proved by |
|---|---|---|---|
| 1 | a host calls `AuroraMeter.track/4` for the feature | `AuroraMeter.buffered_source!/1` (private) raises `ArgumentError` **before** `AuroraMeter.Tenant.to_key/1` and before any ETS write, so a refusal leaves no partial state | `AuroraMeter.FeatureSourceTest` / `test the track and reserve guards I08 track/4 raises for an events-source feature and writes nothing` |
| 2 | the same call with `durable: true` | the same guard: the option is read after it, in `AuroraMeter.durable?/2` | `... I08 track/4 with durable: true raises for an events-source feature and writes no row` |
| 3 | a host calls `AuroraMeter.reserve/2,3` | `AuroraMeter.Entitlements.buffered_source!/1` (private) raises. This is the bill-now primitive: it takes the non-deferred branch of `AuroraMeter.Counter.reserve/6`, which calls `Counter.bump/2`, which is link 3 | `... I08 reserve/2 and reserve/3 raise for an events-source feature and write nothing` |
| 4 | a host calls `AuroraMeter.with_quota/4` and the callback succeeds | `AuroraMeter.Entitlements.settle/6` (private) calls `Counter.release_work/4` instead of `Counter.commit_work/5`. The reservation itself was never a risk: `Counter.reserve_pending/2` writes only `value` and `reserved` | `... test with_quota over an events-source feature I03 with_quota releases its reservation on success and leaves the recorded quantity`, and the eight-cell matrix in `03c-quota-matrix.md` |

And one declaration is refused rather than resolved:
`AuroraMeter.Config.check_sources!/1` (private, called from
`AuroraMeter.Config.validate!/1` and therefore from `AuroraMeter.start_link/1`)
raises when a feature is named both in `:durable_features` and in
`:feature_sources` as `:events`. Proved by
`AuroraMeter.FeatureSourceTest` / `test configuration I08 declaring a feature in durable_features and as an events source fails at boot`.

## Part 4: the chain asserted end to end, in core

Cutting a chain is not the same as proving it is cut. The proof is asserted at
**both ends** and in core, so that a future change to the projection breaks a
core test rather than a Pro one.

`AuroraMeter.FeatureSourceTest` /
`test flush isolation I08 a thousand recorded events reach no flush batch, no counter row and no reporter read`
records 1000 quantities and then asserts, in this order:

1. `AuroraMeter.usage/2` is 1000, so the projection really happened and the test
   is not passing because nothing was recorded;
2. the flush batch from `AuroraMeter.Store`'s snapshot holds no counter entry
   **and no history entry** for that tenant, which is link 5 refusing it;
3. `AuroraMeter.Flusher.flush/0` then returns without writing it;
4. `AuroraMeter.Storage.load_counter/3` for the tenant, feature and period is
   `nil`, which is link 8's exact call, and `nil || 0` is `0`, which is what
   `report_one/5` would compute a delta from;
5. `AuroraMeter.Events.total/3` is 1000, so the quantity was not lost, it was
   routed.

The measured numbers are in `03c-flush-isolation.json`.

`AuroraMeter.FeatureSourceTest` /
`test flush isolation I08 one flush writes the buffered feature and not the events-source one`
runs both sources for one tenant in one flush and asserts the batch carries
exactly the buffered delta.

## Part 5: what this does not prove

Three things, stated so the invariant is not read as covering them.

**A host reading `aurora_meter_events` and billing it by hand** is outside this.
I08 covers what the library writes to the table Pro bills from, not what a host
does with the rows afterwards. Pro's rollups do read durable events directly
when `history: false` (`open-findings.md` C15), which is a reporting read rather
than a billing read; 04d removes the direct query.

**A source migration for a feature that is already being billed** is not made
safe by anything in this unit. Core refuses a dual declaration, but it cannot
know whether a feature's existing counter rows were ever reported to a provider,
so nothing here stops a host flipping a source part way through a period and
leaving that period split between a frozen counter row and a growing event
total. The watermark, the boot refusal when `usage_reports` rows exist without a
cutover row, and `usage_reports.source` are all Pro's and land in build unit
**04c**. Core's part of the contract is the guards and the documented order, and
both are written down in `docs/metering.md` and in Pro's
`docs/usage-reporting.md`.

**A second node doing something different.** The tests here drive
`AuroraMeter.Cluster.apply/3` directly on one VM, which exercises
`Cluster.handle_batch/3`, `Counter.apply_remote/2` and `Counter.rebase/3` exactly
as a received PubSub message would, but it is not a real cluster. Two properties
were checked that way: a peer's projected delta moves this node's value, and a
peer's totals announcement does not rebase an events-source key. The second holds
for two independent reasons and only the weaker one is exercised: no node ever
puts such a key in a flush batch, so the announcement cannot exist; and if one
did arrive, `Cluster.handle_batch/3`'s totals branch only applies a total that is
at or above the key's current base, and a peer's counter total for an
events-source key is nothing.
