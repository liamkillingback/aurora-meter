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
