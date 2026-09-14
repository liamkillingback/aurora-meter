# Storage adapters

Aurora Meter reaches persistent storage through one behaviour,
`AuroraMeter.Storage`, and ships one implementation of it,
`AuroraMeter.Storage.Ecto`, backed by the host's Ecto repo on PostgreSQL.
Writing another one is supported. This page is what you need to do it, and
`AuroraMeter.StorageCase` is how you find out whether you have.

Configure yours by name:

    config :aurora_meter, storage: MyApp.Storage

## The shape of the behaviour

The callbacks fall into three groups.

**Counters and history.** `upsert_counters/1`, `add_counters/1`,
`load_counter/3`, `upsert_history/1`, `add_history/1`, `load_history/3`,
`load_history_range/4`, `stream_counters/1` and `flush_batch/3`. These are the
buffered metering path. `flush_batch/3` is the only one with a correctness
requirement beyond "store this": it must apply the receipt, the counter deltas
and the history deltas in **one** transaction, and a redelivery of a batch id it
has already applied must apply nothing and return the current totals.

**Subscriptions.** `get_subscription/1` and `put_subscription/1`.

**Durable events.** `capabilities/0`, `record_events/2`, `load_event/2`,
`load_event_total/3`, `stream_events/2`, `write_projection_totals/2` and
`activate_projection/1`. This is the billing-grade path behind
`AuroraMeter.record/4`, and it carries the guarantees the rest of this page is
about.

## If you cannot do durable events

Say so. Every callback is required, but `capabilities/0` is what decides
whether yours is ever called:

    defmodule MyApp.Storage do
      @behaviour AuroraMeter.Storage

      @impl AuroraMeter.Storage
      def capabilities, do: []

      @impl AuroraMeter.Storage
      def record_events(_entries, _opts), do: {:error, {:unsupported, :durable_events}}

      @impl AuroraMeter.Storage
      def record_correction(_entry, _opts), do: {:error, {:unsupported, :corrections}}

      @impl AuroraMeter.Storage
      def load_event(_tenant_key, _event_id), do: {:error, {:unsupported, :durable_events}}

      @impl AuroraMeter.Storage
      def load_event_total(_tenant_key, _feature, _period_start),
        do: {:error, {:unsupported, :durable_events}}

      @impl AuroraMeter.Storage
      def stream_events(_cursor, _opts), do: {:error, {:unsupported, :event_streaming}}

      @impl AuroraMeter.Storage
      def write_projection_totals(_generation, _rows),
        do: {:error, {:unsupported, :projection_generations}}

      @impl AuroraMeter.Storage
      def activate_projection(_generation),
        do: {:error, {:unsupported, :projection_generations}}

      # ... the counter, history and subscription callbacks ...
    end

`AuroraMeter.Storage`'s dispatchers read `capabilities/0` before every durable
call and answer `{:error, {:unsupported, operation}}` themselves, so the bodies
above are a safety net rather than the mechanism. A host calling
`AuroraMeter.record/4` against this adapter gets
`{:error, {:unsupported, :durable_events}}`, which is an answer it can handle.
A missing callback would give it a `FunctionClauseError`, which is not.

The four capabilities are `:durable_events` (record, read one event, read a
total), `:corrections`, `:projection_generations` (write and activate a replayed
projection) and `:event_streaming`.

## If you can: what `record_events/2` must do

It takes a list of entries in the caller's order and returns
`{:ok, [{event, :inserted | :duplicate}]}` in that same order. All of it happens
in **one** transaction. Six things, and the order is the design:

1. Read the projection generation state, taking a **shared** lock on it. Two
   concurrent records must not block each other, and both must block a
   generation activation.
2. Insert the events, skipping any whose `(tenant_key, event_id)` you already
   hold.
3. For every entry the insert skipped, read the stored row back and compare
   `payload_hash`:
   - equal: the outcome is `:duplicate`. **No totals delta and no outbox item.**
   - different: roll the whole call back with
     `{:error, {:conflict, index, existing}}`.
   - the row is not there: roll back with
     `{:error, {:unavailable, :conflict_unresolved}}`.
4. Add the quantities and counts of the **inserted** rows to the projection
   totals, for the active generation (and for the building generation as well,
   when one is present).
5. Call the configured `AuroraMeter.Events.Outbox` with one item per inserted
   event, passing it the repo running this transaction. A raise or an
   `{:error, reason}` rolls everything back.
6. Commit.

### The one thing not to simplify

Step 3's third branch is the whole unit. "The insert skipped this row and the
row is not visible to me" is **not** a duplicate. Treating it as one silently
accepts a conflicting reuse of an identity, which is how a retry bills twice.
It is also not a conflict: guessing that would fail a legitimate retry. The
honest answer is "I do not know", and the caller retries with the same id and
gets a definite one.

On PostgreSQL 16 the branch is not reachable through `ON CONFLICT` alone:
`ON CONFLICT DO NOTHING` waits for a concurrent transaction holding the
conflicting row, so by the time the statement returns the row is either
committed and visible or gone. It **is** reachable when something deletes the
conflicting row between the insert and the read-back, which a retention prune
racing a retry will do. Your storage may make it reachable in more ways.

## If you can: what `record_correction/2` must do

A correction is a new immutable row reducing the effective quantity of an
existing event in the same tenant. No historical row is ever updated, and the
cumulative magnitude of the corrections of one original may never exceed that
original's quantity. Exceeding it means crediting a customer more than they
were charged, so it is the one rule in this page that is about money rather
than about consistency.

The order of the steps is load bearing:

1. Read the generation state, share-locked, as `record_events/2` does, so a
   correction and a record never take these locks in different orders.
2. **The duplicate check, before the bound check.** Look the correction id up
   and, if it is held with an equal payload hash, return `:duplicate` and stop.
3. Take an exclusive lock on the **original** row. Not on the totals row: the
   bound is a property of one original, the totals row aggregates many
   originals, and locking it would serialise every concurrent `record/4` for
   that key as well.
4. **Check the duplicate again, now under that lock.** A corrector that arrived
   while an identical correction was still uncommitted saw nothing at step 2,
   waited at step 3, and would otherwise meet the bound with no headroom left
   and be told `exceeds_original` for a correction that is its own.
5. Sum the existing corrections of that original, and refuse
   `{:invalid, [quantity: :exceeds_original]}` when the new magnitude would not
   fit. Under `READ COMMITTED` this statement takes a fresh snapshot after the
   lock was granted, which is what makes the sum current; an implementation
   written for repeatable-read semantics here is subtly wrong.
6. Insert the correction, copying the original's feature, occurrence instant,
   period, period source, plan attribution and dimensions, and resolve a
   skipped insert exactly as `record_events/2` does.
7. Apply the totals delta: `-quantity` on `quantity`, `+1` on `events`.
8. Hand the export intent to the outbox, with a reason attached when you can
   already tell it is not deliverable. Never drop a correction.

Two further rules:

**A refusal returns; only a conflict rolls back.** A bound that was exceeded
wrote nothing, so there is nothing to undo, and calling `rollback` there would
destroy a host transaction that wrapped the call along with its own writes.

**If your storage has a non-negative constraint on the totals, check where it
applies.** On PostgreSQL a `CHECK` is applied to the tuple an
`INSERT ... ON CONFLICT DO UPDATE` proposes, before the conflict is resolved, so
the upsert `record_events/2` uses cannot carry a negative delta even when the
row it merges into stays positive. The Ecto adapter therefore ensures the row
exists at zero and then issues an `UPDATE`, which keeps the constraint as a
backstop on the value that results.

### Sorting, and why

Sort the entries by a total order before each multi-row statement: by
`{tenant_key, event_id}` for the insert, by
`{tenant_key, feature, period_start, generation}` for the totals. Two concurrent
batches touching the same rows in opposite input order deadlock inside the
statement otherwise, and the failure is intermittent and looks like something
else.

### Scan order is `seq`, never `id`

`stream_events/2` pages by a monotonic insertion identity. Event ids are random
UUIDs, so a keyset scan ordered by one can miss a row committed by a transaction
that started earlier than the cursor it has already passed. If your storage has
no such identity, `:event_streaming` is a capability you do not have.

## If you can: what the five generation callbacks must do

`:projection_generations` is the capability behind `AuroraMeter.Events.Replay`:
rebuilding the projection into an isolated generation while the system keeps
recording. Declaring it commits you to five callbacks and to one property that
is easy to miss.

`begin_projection_generation/0` announces a build. It must, in **one
transaction**:

1. take an exclusive lock on the same state `record_events/2` share-locks first,
   so it is granted only once every in-flight record has finished;
2. read the watermark, the highest insertion identity committed at that moment;
3. seed the new generation from the active one (see below);
4. publish the building generation, so every record that starts afterwards
   writes its delta to both.

It must be **idempotent**: called again while a build exists, it returns that
build with `resumed: true` and copies nothing.

`projection_state/0` reports the active, building, previous and seed
generations and the watermark, without locking anything.

`write_projection_totals/2` **adds** its deltas to a generation and creates the
rows that are absent. It must not set an absolute value: a record that commits
mid-build has already written its own delta there. Call it inside the caller's
transaction, because a replay commits its totals and its cursor together and
that is the whole of its resumability.

`drain_projection_seed/2` subtracts a bounded slice of the seed from the
generation it seeded and deletes that slice, in one statement, returning how
many rows it consumed. The seed row's own existence is the cursor, so an
interrupted drain resumes with no bookkeeping and can never subtract a row
twice.

`activate_projection/1` swaps the generation reads resolve to, under the same
exclusive lock, and records the previous one. It must be atomic for readers:
either the whole of the old generation or the whole of the new one, never a
mixture.

### Why the seed exists, and what breaks without it

A correction contributes a **negative** delta. While a generation is being
built, that delta goes to both generations. A correction whose original
committed below the watermark but whose key the scan has not reached yet would
drive the building generation's row below zero, and a storage with a
non-negative constraint on the column would refuse it: a perfectly legal
correction rejected, with a misleading reason, because a rebuild happened to be
running.

Copying the active generation into the building generation at announcement time
makes one thing true for the whole build:

    building(key) == active(key) + (whatever the scan has added so far)

Both terms are non-negative, so the building generation is refused exactly when
the active one would have been and never on its own account. The same rows are
frozen in a seed generation so the copy can be taken back out once the scan is
complete, which is what `drain_projection_seed/2` is for.

A replay batch's net delta for one key can also be negative on its own, because
events are read in insertion order and a batch can hold only corrections for a
key. If your storage evaluates a constraint against the tuple an upsert
*proposes* rather than the row it leaves, as PostgreSQL does, write it as "make
the row exist at zero, then move it" rather than as one upsert.

## Timeouts and concurrency

`record_events/2` receives `:timeout` in its options. Apply it to the
transaction **and** to every statement inside it, and pass it on to the outbox
in its context: the contract is that a storage that stops answering produces
`{:error, {:unavailable, :timeout}}` inside that bound, not an exit and not an
unbounded wait.

Do not implement a lease, a fence or a concurrency limit by comparing two
timestamps at second scale. The database clock is not monotonic: a 300 second
probe of `clock_timestamp()` on the hardware this package is tested on found it
stepping backwards nine times, worst 439 ms. Use a lock, a `SKIP LOCKED` claim
or a fencing token taken from an insertion identity.

## Errors

Every failure is `{:error, {tag, detail}}` with `tag` one of `:invalid`,
`:conflict`, `:unavailable`, `:unsupported` or `:not_found`. In particular,
`:unavailable` means "this may or may not have happened, retry with the same
id", so do not use it for anything a retry cannot fix.

## Proving it

    defmodule MyApp.StorageTest do
      use ExUnit.Case, async: false

      use AuroraMeter.StorageCase,
        adapter: MyApp.Storage,
        checkout: {MyApp.DataCase, :checkout!},
        tenant_prefix: "myapp_storage_case"
    end

The suite installs your adapter for the duration of each test, drives it
through `AuroraMeter.Storage`'s dispatchers and restores the previous
configuration afterwards. It adapts to what you declare: an adapter with no
capabilities is asserted to refuse cleanly, one with `:durable_events` is put
through identity, duplication, conflict and totals arithmetic. Passing it is
necessary, not sufficient: it says nothing about your storage under a kill or a
partition, which is what `AuroraMeter.Test.Connections` and a fault harness are
for in this repository.
