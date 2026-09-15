# Retention

Aurora Meter keeps financial history for ever. Events, event totals, the credit
ledger, subscriptions and the cursors every sweep resumes from are never deleted
by anything in this package, at any age, under any option, and nothing prunes
anything at all until you schedule it.

Two tables grow with traffic rather than with tenants, and both are genuinely
disposable once a couple of conditions hold. `AuroraMeter.Retention` is that
list, and the proof that each entry is safe to remove.

```elixir
AuroraMeter.Retention.plan([])
#=> {:ok, %{flush_receipts: 482_100, replay_checkpoints: 2}}

AuroraMeter.Retention.prune([])
#=> {:ok, %{flush_receipts: 50_000, replay_checkpoints: 2}}
```

`plan/1` is a dry run. It runs the prune's own predicate with `count(*)` instead
of a `DELETE` and writes nothing at all, so the number it gives you is the
number `prune/1` then removes, generated from one predicate rather than from two
that could drift.

## The allow list

| Table | Kept for | Deleted only when |
|---|---|---|
| `aurora_meter_flush_receipts` | `:flush_receipt_retention`, 30 days | every node's flush heartbeat proves no node holds a batch from before the cutoff |
| `aurora_meter_checkpoints`, the `"events_replay:<generation>"` rows | `:replay_checkpoint_retention`, 365 days | the row is `activated` or `abandoned`, and its generation is not one the live projection names |

That is the whole list. There is no option, no configuration key and no argument
that adds a table to it. `:only` narrows the list and can never widen it, which
is why it is called `:only` rather than `:tables`:

```elixir
AuroraMeter.Retention.prune(only: [:replay_checkpoints])

AuroraMeter.Retention.prune(only: [:aurora_meter_credit_transactions])
#=> ** (ArgumentError) :aurora_meter_credit_transactions is not a table
#=>    AuroraMeter.Retention may delete from...
```

**Age alone never authorises a deletion.** Every entry has an age predicate and
a state predicate, because "this row is old" and "this row can no longer affect
anything" are different statements and only the second is a reason to delete.

A test in this package derives the tables the migrations create and fails unless
every one of them appears in exactly one of the two lists, in both directions.
A table nobody classified is a table that grows for ever, or worse, one a later
prune reaches.

## Why the flush receipt is the careful one

`AuroraMeter.Storage.Ecto.flush_batch/3` inserts a batch's receipt with
`on_conflict: :nothing` and applies the counter deltas only when that insert
reported one new row. That single check is the whole of "one flush batch has at
most one durable effect". Delete a receipt while a node still holds the batch in
memory, let that node retry, and the deltas are added a second time: a double
count of real usage, in money.

So every node's `AuroraMeter.Flusher` writes a heartbeat row named
`"flush:<node>"` into `aurora_meter_checkpoints`:

* `"idle"` after a batch commits;
* `"pending"`, carrying the batch's `snapshot_at`, after one fails;
* `"idle"` on a tick with nothing to send, at most once a minute, so a node with
  no traffic still proves it is alive without writing a row every five seconds.

A receipt prune proceeds only when **every** one of those rows says either
"idle, and I said so after the cutoff" or "pending, with a batch taken after the
cutoff". Anything else blocks, and the refusal names the node:

```elixir
AuroraMeter.Retention.prune(only: [:flush_receipts])
#=> {:blocked, %{flush_receipts: 0},
#=>  [%{table: :flush_receipts, reason: :node_liveness_unknown,
#=>     detail: %{nodes: [%{node: "app@10.0.1.7", state: "pending",
#=>                        why: :pending_batch_older_than_cutoff, ...}]}}]}
```

Three refusals are stricter than "check the rows that are there", and each is
deliberate:

* **no heartbeat rows at all**, when there is a receipt older than the cutoff.
  That is what a fleet running the previous release looks like, and "nobody is
  reporting" is not evidence that nobody is holding a batch.
* **no `aurora_meter_checkpoints` table**, which is a database below core schema
  version 7, for the same reason.
* **a `pending_since` that cannot be read**, rather than ignoring it.

Being blocked is a normal outcome, not an error. The return is
`{:blocked, report, reasons}`, the other tables are still pruned, and the Oban
worker still completes.

## Before you schedule it

Do these in order, once, when you upgrade:

1. Deploy the release to **every** node.
2. Wait for each node to write a heartbeat. An idle node writes one within a
   minute; a busy one writes one on its next flush.
3. Check them:

   ```elixir
   AuroraMeter.Retention.status()
   #=> %{cutoff: ~U[...], versions: ["1.0.0"],
   #=>    heartbeats: [%{node: "app@10.0.1.7", state: "idle", blocks: false, ...}, ...]}
   ```

   One row per node, `blocks: false` on all of them, and one entry in
   `versions`. More than one version is normal during a rolling deploy and worth
   a look if it persists.
4. Add the crontab entry (`AuroraMeter.Oban.cron_entries/1` includes it), or call
   `AuroraMeter.Retention.prune/1` from whatever scheduler you have.

Doing it in the other order is safe, because retention refuses rather than
guessing, but the refusal is easier to read before it is a surprise.

### When several nodes call themselves `nonode@nohost`

An unnamed BEAM is `:nonode@nohost`, so several unnamed VMs against one database
write **one** heartbeat row between them, and that row cannot tell one node from
ten. `AuroraMeter.Retention` logs a warning when it sees the name. Give each node
an identity:

```elixir
config :aurora_meter, flush_node_id: System.get_env("FLY_MACHINE_ID")
```

or start the VMs with names.

### When a node is never coming back

A node that was scaled down, terminated or replaced leaves a heartbeat behind,
and a `"pending"` one blocks receipt pruning for ever. `forget_node/1` removes
exactly that node's row:

```elixir
AuroraMeter.Retention.forget_node("app@10.0.1.7")
```

It logs at `:warning` with the row it removed. **The precondition, in plain
words: the node must not be coming back with its memory intact.** If it is
merely partitioned, or stopped and about to be restarted from the same process,
it may still hold a flush batch; forgetting it removes the protection for that
batch, and if it then returns and retries, that batch's usage is counted twice.

It is the only override of the receipt rule, and it overrides it for one named
node rather than removing the rule.

## Pausing

One operation per table, so you can stop receipt pruning and leave the replay
rows alone:

```elixir
AuroraMeter.Operations.pause("retention:flush_receipts")
AuroraMeter.Operations.resume("retention:flush_receipts")
```

A paused table is reported as a `:paused` reason rather than as a failure.

## Sizing, measured

`priv/v1/receipt_sizing.exs` produces these numbers; they were measured on
PostgreSQL with one million synthetic receipts on 15 September 2026, and
`docs/evidence/v1/phase-05/05d-sizing.md` carries the full output.

| | |
|---|---|
| One million receipts | 50 MB table, 39 MB primary-key index, **88 MB total** |
| Per row | **92.6 bytes**, heap and index together |
| At the shipped 5,000 ms `flush_interval` | **17,280 rows per node per day** |
| | **1.53 MiB per node per day**, **0.54 GiB per node per year** |
| A four-node cluster, one year | about 2.2 GiB and 25 million rows |
| `plan/1` over a million rows | 25 ms (a parallel sequential scan) |
| One `prune/1` batch of 1,000 | 62 ms |
| Pruning 499,033 rows in batches of 1,000 | 20.8 s |

Nothing reads a receipt except the conflict check on a retry, and that only ever
looks up a batch id minutes old.

### The sequential scan, and when to care

`aurora_meter_flush_receipts` carries only its primary key, so
`where inserted_at < cutoff order by inserted_at limit 1000` is a sequential
scan. Measured above: 62 ms per batch over a million rows, on a nightly job that
runs off peak, against an append-only table whose old rows are physically first.
That is cheap enough that an index on `inserted_at` would cost more (a write on
every flush, for ever) than it saves.

If your first prune has years of backlog, run it with a small `:max_items` over
several nights rather than in one pass:

```elixir
AuroraMeter.Retention.prune(only: [:flush_receipts], max_items: 200_000)
```

The default `:max_items` is 50,000 per table per run, and a run that stopped
there leaves the rest for the next one.

## Archiving

Aurora Meter uploads nothing anywhere and ships no archiver. Building one would
be a second storage system, and you already have a better one: your backups.

If you want a copy of what a prune is about to remove, take it with `COPY`
before the prune:

```sql
COPY (SELECT * FROM aurora_meter_flush_receipts
       WHERE inserted_at < now() - interval '30 days')
  TO '/var/backups/aurora_flush_receipts.csv' WITH CSV HEADER;
```

For the tables that are **never** pruned, which is where your financial history
lives, the archive is your ordinary database backup and nothing here changes
that. If you want them out of the hot database for size reasons, that is a
partitioning or a warehouse question rather than a retention one, and deleting
them is not the answer: an event, a correction or a ledger row that is gone
cannot be reconciled against a provider afterwards.

## Aurora Meter Pro

The commercial package adds tables of its own, with its own allow list and its
own protected list on the same terms. Its retention guide is the page of the same
name in that package's documentation. The two lists are deliberately independent:
a Pro host schedules both, and neither package prunes the other's tables.
