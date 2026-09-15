# Operations

The runbook: what to run, how often, what breaks when it does not run, and what
to do at three in the morning when something already has.

Everything here is core. A host running Aurora Meter with nothing else has a
complete operations story on this page, and every command on it reaches your own
database and nothing else.

Two rules govern the whole guide.

> **Look, then decide, then act, and the acting command names what you expect to
> be true.**

Every section that changes something shows the read-only call first. Where a
change has no expected-state guard to offer, the section says so in the same
paragraph and says what to check by hand instead.

> **A sentence here names the invariant it rests on, or it is not written.**

[Guarantees and limits](guarantees.md) is the contract, with a test named
against every row. [Correctness](correctness.md) is the longer form, invariant by
invariant. If this page and either of those disagree, they are right and this
page is a defect.

## 1. What runs, and how often

Aurora Meter ships no scheduler. Every scheduled operation is a public function
you can call from anything:

| Operation | Recommended | Running it less often costs you |
|---|---|---|
| `AuroraMeter.Credits.expire_due/2` | every 30 minutes | Promotional credit stays spendable past its expiry date. The money moves the wrong way (towards the customer) and the balance a customer sees is too high until the sweep catches up. |
| `AuroraMeter.Credits.reconcile_holds/1` | every 15 minutes | Holds whose work died stay reserved, so `available` is understated and a customer is refused work they have the funds for. |
| `AuroraMeter.Retention.prune/1` | nightly | `aurora_meter_flush_receipts` grows at about 17,280 rows per node per day at the shipped flush interval. Nothing reads them after minutes. See [Retention](retention.md) for the measured sizing. |
| `AuroraMeter.Events.Replay.run/1` | never on a schedule | Nothing. A replay is a deliberate act; see section 6. |

Two ways to run them, and the second is not a downgrade:

```elixir
# Any scheduler, or none.
AuroraMeter.Credits.expire_due(AuroraMeter.Clock.db_now(), limit: 500)
AuroraMeter.Credits.reconcile_holds(older_than: stale_cutoff(), limit: 200)
AuroraMeter.Retention.prune(max_items: 50_000)
```

or, when the host runs Oban, the optional `AuroraMeter.Oban` workers wrap exactly
those functions and `AuroraMeter.Oban.cron_entries/1` gives the crontab. The
schedules, the queue, the `max_attempts` and what a second run of each worker
does are one table in the [scheduler map](scheduler.md), which is the page to
read next and is deliberately not repeated here.

### Running one twice is not an error

A cron plugin can tick twice across a leader change, a rescued job runs again, a
deploy overlaps two releases, and two nodes can both be told to sweep. Aurora
Meter does not assume a scheduled job runs a single time, and neither should you.
That is invariant I16, and what stands behind it is the operation, not the
scheduler: `expire_due/2` re-reads `expired_at` under the grant row's own
`FOR UPDATE`, and `reconcile_holds/1` re-reads `status = 'pending'` under the
hold row's.

**A queue's uniqueness is not what protects money, and it is worth knowing why
before you read a duplicate as an incident.** Oban's `unique` option is a check
inside the insert rather than a constraint on the table, so two inserts arriving
together on two connections can both pass it and the loser is not told. Measured
in this programme: sequential on one connection, one row; two nodes released
together, one row in five of five runs; two independent connections behind a
forced barrier, **two rows in ten of ten**. So seeing two queued jobs for one
intent is expected on a busy installation and is not, on its own, a reason to
cancel either of them. The second job finds the work done and says so.

## 2. Queue sizing

`queues: [aurora_meter: 5]` is the number of jobs this queue runs at once **on
each node**. It is not a rate limit and it is not cluster wide: four nodes at 5
is twenty concurrent jobs.

Five is the recommendation for a host running the core workers, and the reasoning
is short. The two scheduled core operations are short and paged: each commits
bounded batches and keeps its position in `aurora_meter_checkpoints`, so a run
that does not finish is resumed rather than restarted. Retention is nightly and
bounded by `:max_items`. None of the three holds a connection between batches.

The one that does not fit that description is replay. A rebuild reads the whole
events table, and on a large installation it runs for a long time. At a
concurrency of 1 it would occupy the queue for the duration and the half-hourly
expiry sweep behind it would simply not run, which is the failure that looks like
nothing at all: no error, no alert, a balance drifting.

So: **do not put replay in a queue of 1 with anything else in it.** Either leave
the shipped concurrency of 5, which gives the short jobs room beside it, or give
replay a queue of its own on a large installation. It is not in
`AuroraMeter.Oban.cron_entries/1` in the first place, so it costs you nothing
until the day you run one.

A limit of zero is worse than a small one: jobs sit `available` for ever and
nothing says so. `AuroraMeter.Oban.validate!/1` refuses that configuration at
boot, along with a missing queue and a repo that is not the one Aurora Meter
reads tenant data from.

## 3. Recovering stale holds

A hold is taken before the row that remembers it exists, and those two cannot be
one write: the ledger is a different schema and often a different database. A
process killed in between leaves money reserved against a tenant with nothing
anywhere pointing at it.

Only you can tell such a hold from one whose work is simply still running. Look
first:

```elixir
AuroraMeter.Credits.pending_holds(
  older_than: DateTime.add(AuroraMeter.Clock.db_now(), -6 * 3600, :second),
  reference_prefix: "job:",
  limit: 50
)
```

Then decide, with something that knows whether the work is alive:

```elixir
defmodule MyApp.Holds.Policy do
  @moduledoc "Answers AuroraMeter.Credits.reconcile_holds/1 from our own job table."
  @behaviour AuroraMeter.Credits.HoldReconciler

  @impl true
  def decide(%{reference: "job:" <> id}) do
    case MyApp.Jobs.get(id) do
      %{state: :running} -> :keep
      %{state: :done, cost_micro_usd: cost} -> {:settle, cost}
      %{state: :failed} -> :release
      nil -> :keep
    end
  end

  # Anything this policy does not recognise is something it cannot tell about.
  def decide(_hold), do: :keep
end
```

Then act, from whatever scheduler you have:

```elixir
AuroraMeter.Credits.reconcile_holds(
  older_than: DateTime.add(AuroraMeter.Clock.db_now(), -6 * 3600, :second),
  reconciler: MyApp.Holds.Policy,
  limit: 200
)
#=> {:ok, %{examined: 12, kept: 9, released: 2, settled: 1,
#=>         already_closed: 0, failed: 0, cursor: nil}}
```

**Age is not evidence, and that is the whole point of the callback.** A job that
legitimately runs for nine hours and a job whose process was killed nine hours
ago are the same row. `age_seconds` is there for your log line. Deciding from it
releases money that is about to be spent.

The default is `:keep`, and so is every way of failing to answer: no configured
reconciler, a callback that raises, exits or throws, one that does not answer
within `:credits_hold_reconciler_timeout` (5 seconds by default, after which the
task is killed), and one that returns anything other than `:keep`, `:release` or
`{:settle, n}`. Nothing here can release money by accident.

The mutation has no expected-state map to give it, because the state it acts on
is the hold row and it re-reads that row under its own lock. What you check by
hand instead is the policy: run it against a page with
`reconciler: fn _hold -> :keep end` first and read what it would have been asked
about.

If your policy releases a hold whose work then completes, the cost is recorded
rather than lost: a debit referenced `settle_missed:<reference>` is written, which
may take the balance negative, and it is idempotent on that reference. A policy
that is doing this shows up as a stream of `released_by_other` outcomes on
`[:aurora_meter, :credits, :hold_reconciliation]`.

The contract, every keep case and what happens when the race is lost are in
[Credits](credits.md); this section is the operational half of the same
mechanism.

## 4. When the database is unavailable

Each subsystem behaves differently, and the differences are the point.

| Subsystem | What happens | What it costs you | Rests on |
|---|---|---|---|
| `track/4` and `check/2` | Keep working. They are ETS reads and writes and never touch the database. | Everything not in an acknowledged flush batch can be lost if the VM stops before the database returns. The pending set grows for as long as the outage lasts, and nothing bounds it. | G6, I01 |
| `AuroraMeter.Flusher` | Retains its batch and retries the same batch id, for as long as it takes. | Nothing, once the database returns: the receipt's primary key is inserted inside the same transaction as the deltas, so a batch redelivered after a lost response applies its deltas a single time. | G7, I01 |
| `AuroraMeter.record/4` | Returns `{:error, {:unavailable, reason}}`. | Nothing, if you retry with the same `id:`. The identity is yours, so a retry after an unknown commit outcome is reported as a duplicate rather than persisted twice. | G10, I06 |
| `AuroraMeter.Credits` | Every call returns an error and writes nothing. A refusal returns rather than raising, so it does not destroy a transaction of your own that wraps it. | Nothing is half applied. | G8, I10 |
| Scheduled operations | Fail. Under Oban they are retried; called directly they return an error. | The backlog of section 1, and nothing else: each one re-reads what it is about to change. | G12, I16 |

Two consequences worth stating on their own.

**`check/2` is advisory and stays advisory during an outage.** It reads the local
counter, which is still there. Two callers can both be told `:ok` for the last
unit, during an outage or outside one. Use `reserve/2,3` or `with_quota/3,4` when
you need capacity held.

**Reservations are local, so an outage does not change quota behaviour at all.**
A reservation is never persisted and never gossiped. The cluster limits are
unchanged by the database being away, and are in [Clustering](clustering.md).

## 5. Pause and resume

Every scheduled operation can be stopped at its next batch boundary, from `iex`
or a release command, with no deploy and no configuration change.

Look first. `list/0` is every checkpoint the installation holds, and
`checkpoint/1` is one of them with its cursor, its counts and when it last moved:

```elixir
AuroraMeter.Operations.list()
AuroraMeter.Operations.checkpoint("credit_expiry:global")
AuroraMeter.Operations.paused?("credit_expiry:global")
```

Then act:

```elixir
AuroraMeter.Operations.pause("credit_expiry:global")
AuroraMeter.Operations.resume("credit_expiry:global")
```

The core operation names are `"credit_expiry:global"`,
`"hold_reconciliation:global"`, `"retention:flush_receipts"` and
`"retention:replay_checkpoints"`. A name that is not
`"<operation>:<scope>"` raises `ArgumentError` rather than quietly creating a
second checkpoint nothing reads.

A pause asks the operation to stop at its **next batch boundary**. The batch
already in flight finishes and commits; nothing is interrupted and nothing is
rolled back. The worst case is one more committed batch after you asked, and the
cursor advances with it.

**A paused operation looks exactly like a healthy one from the outside.** Nothing
runs, nothing errors, and the backlog grows quietly. `pause/1` takes no
expected-state map, because there is no state to contradict; what you do instead
is record the pause somewhere a person reads and put `paused?/1` in the health
check of section 9.

Two rows core writes are not operations and are not reachable here:
`"events_projection"` (which projection generation is live) and
`"events_backfill"`. Neither is paused or resumed by an operator. Read them with
`AuroraMeter.Checkpoints`, which is the table's own module.

## 6. Replay

Rebuilding `aurora_meter_event_totals` from the events it was derived from.

**When.** To verify that the projection and the events agree, or to repair a
projection you already know is wrong. Never as a routine operation, and there is
no cron entry for it.

Look first:

```elixir
AuroraMeter.Events.Replay.status()
```

`status/0` names the active, building and previous generations, the watermark and
the replay's own checkpoint. Then run one, and what a run does is decided by its
options rather than by a separate confirmation step:

```elixir
# Verify. Builds, compares, and refuses to activate if the rebuild and the live
# projection differ.
AuroraMeter.Events.Replay.run()
```

The full runbook is [Rebuilding the event projection](replay.md): the option list,
what a rebuild costs while it runs, how to activate the previous generation again
if the new one turns out to be wrong, and what a kill leaves behind. Three things
from it belong in any operator's head:

* **A replay writes totals and nothing else.** It records no event, stages no
  export intent, grants no credit, publishes no message and produces no flush
  batch. Every one of those is asserted by a test rather than intended.
* **An interrupted replay resumes.** Each batch commits its totals and its
  checkpoint in one transaction, so the cursor always names a batch that is fully
  applied, and running `run/1` again carries on from it.
* **The previous generation is retained** until you prune it, and pruning is
  explicit.

## 7. Retention

Look first, always. `plan/1` runs the prune's own predicate with `count(*)`
instead of a `DELETE` and writes nothing, so the number it gives you is the
number `prune/1` then removes:

```elixir
AuroraMeter.Retention.status()
AuroraMeter.Retention.plan([])
#=> {:ok, %{flush_receipts: 482_100, replay_checkpoints: 2}}
```

Then act:

```elixir
AuroraMeter.Retention.prune(max_items: 50_000)
```

Aurora Meter keeps financial history for ever. Events, event totals, the credit
ledger, subscriptions and live cursors are not deleted by anything in this
package at any age under any option, and the allow list is closed at compile
time. [Retention](retention.md) is the list, the windows, the measured sizing and
the flush-receipt rule.

### Blocked is a normal answer

`plan/1` and `prune/1` both return `{:blocked, counts, reasons}` when a table
could not be touched. The other tables are still pruned and the worker still
completes: this is a refusal, not an error, and retention refuses rather than
guessing.

`reasons` is a list of `%{table:, reason:, detail:}`. What each one means, and
what to actually do:

| `reason` | What it means | What to do |
|---|---|---|
| `:paused` | An operator paused this table's operation (section 5). | Resume it, or leave it paused deliberately and record why. |
| `:budget_exhausted` | The run hit its `:max_items` with work still waiting. | Nothing is wrong. Run it again, or raise `:max_items` for a backlog. A bounded run that could not say it was bounded would make the bound a silent ceiling. |
| `:no_heartbeats` | No node has written a flush heartbeat and there are receipts older than the cutoff. | Deploy the release to every node and let each write one heartbeat, then prune. "Nobody is reporting" is not evidence that nobody is holding a batch. |
| `:checkpoints_unavailable` | The database is below core schema version 7, so there is no heartbeat table to read. | Migrate. Same reasoning as the row above. |
| `:node_liveness_unknown` | At least one node's heartbeat does not prove it is holding no batch from before the cutoff. `detail.nodes` names each one and why. | Read the table below. |
| `:error` | The count or the delete raised. `detail.error` carries it. | An ordinary database problem. Nothing was deleted. |

For `:node_liveness_unknown`, each blocking node carries a `why`:

| `why` | Wait, investigate, or forget |
|---|---|
| `:heartbeat_stale` | **Investigate.** The node said "idle" but said it before the cutoff, so it has not been heard from in longer than the retention window. Either it is gone, or its Flusher is not running. |
| `:pending_batch_older_than_cutoff` | **Wait**, if the node is alive: it is holding a batch it has not committed and the receipt it would conflict against is the protection. If the node is gone, forget it. |
| `:pending_since_unreadable` | **Investigate.** The row says "pending" and its timestamp cannot be parsed, which should not happen and is not something to override. |
| `:unknown_state` | **Investigate.** A heartbeat vocabulary this release does not know, which means a newer node is writing to this database. Upgrade, do not forget. |

### Forgetting a node

A node that was scaled down, terminated or replaced leaves its heartbeat behind,
and a `"pending"` one blocks receipt pruning for ever. Look at it first, in the
`status/0` output above, and then:

```elixir
AuroraMeter.Retention.forget_node("app@10.0.1.7")
```

It removes exactly that node's row and logs at `:warning` with what it removed.
**It takes no expected-state map and there is nothing it can check for you**, so
the precondition is yours to establish, and it is this: the node must not be
coming back with its memory intact. If it is merely partitioned, or stopped and
about to be restarted from the same process, it may still hold a flush batch.
Forgetting it removes the protection for that batch, and if that node then
returns and retries, the batch's usage is counted twice. It is irreversible in
the way that matters: it unblocks a deletion.

## 8. Backup and restore

Aurora Meter ships no backup tool and no archiver, and building one would be a
second storage system when you already have a better one.

**What has to be restored together: the whole database.** The credit ledger, the
events, the event totals and the flush receipts are one consistent set and are
not independently restorable. A receipt restored without the counters it
acknowledged is a batch that will not be reapplied; counters restored without the
receipts are a batch that can be. The events and the totals derived from them are
the same argument in the other direction, and that one at least has a remedy in
section 6.

**Restoring to a point before a financial write loses that write.** There is no
mechanism in this package that replays a lost grant, hold or settlement, and
there is no `down` migration that is a rollback: a `down` restores a schema, not
the rows a later schema held. After any restore that crossed a financial write,
reconcile per tenant.

**How to verify a restore**, in this order:

1. Run the health check of section 9 against the restored database. Every figure
   in it should be zero or empty.
2. Compare per-tenant conservation: each wallet's `balance` should equal the sum
   of its ledger entries' amounts, and its `held` the sum of its open holds.
   Section 9 has both queries.
3. Run a verification replay (section 6) if durable events are in use. It either
   tells you the projection and the events agree or hands you the keys that do
   not.
4. Check `AuroraMeter.Retention.status()`. A restored database carries the
   heartbeat rows of whatever nodes were alive when the backup was taken, and
   those nodes are not the ones running now.

## 9. A health check worth having

The reconciliation that matters most is the one that asks whether the ledger
still adds up. Checking it once by hand proves very little. Checking it every few
minutes and alerting on a change is what turns "it was correct when I looked"
into "I will know within minutes when it stops being correct".

```elixir
defmodule MyApp.Health.AuroraMeter do
  @moduledoc "Invariants that should hold at all times. Every figure is zero or empty."

  import Ecto.Query

  @stale_hold_age 6 * 3600

  def check do
    %{
      conservation: conservation_breaks(),
      held_drift: held_drift(),
      negative_balances: negative_balances(),
      stale_holds: stale_holds(),
      paused: paused_operations(),
      oldest_pending_batch: oldest_pending_batch(),
      oldest_cursor: oldest_cursor()
    }
  end

  # I10: a wallet's balance is the sum of its entries' amounts.
  defp conservation_breaks do
    MyApp.Repo.all(
      from(t in "aurora_meter_credit_transactions",
        join: b in "aurora_meter_credit_balances",
        on: b.tenant_key == t.tenant_key,
        group_by: [t.tenant_key, b.balance],
        having: sum(t.amount) != b.balance,
        select: {t.tenant_key, sum(t.amount), b.balance}
      )
    )
  end

  # I10: held is the sum of the holds still open.
  defp held_drift do
    MyApp.Repo.all(
      from(b in "aurora_meter_credit_balances",
        left_join: t in "aurora_meter_credit_transactions",
        on: t.tenant_key == b.tenant_key and t.kind == "hold" and t.status == "pending",
        group_by: [b.tenant_key, b.held],
        having: coalesce(sum(t.amount), 0) != b.held,
        select: {b.tenant_key, coalesce(sum(t.amount), 0), b.held}
      )
    )
  end

  defp negative_balances do
    MyApp.Repo.aggregate(
      from(b in "aurora_meter_credit_balances", where: b.balance < 0),
      :count
    )
  end

  defp stale_holds do
    AuroraMeter.Clock.db_now()
    |> DateTime.add(-@stale_hold_age, :second)
    |> then(&AuroraMeter.Credits.pending_holds(older_than: &1, limit: 200))
    |> length()
  end

  # Section 5: a paused operation looks healthy from outside. This is the look.
  defp paused_operations do
    AuroraMeter.Operations.list()
    |> Enum.filter(&(&1.state == "paused"))
    |> Enum.map(& &1.name)
  end

  # The oldest flush batch any node is still holding, in seconds.
  defp oldest_pending_batch do
    AuroraMeter.Retention.status().heartbeats
    |> Enum.filter(& &1.pending_since)
    |> Enum.map(&DateTime.diff(AuroraMeter.Clock.db_now(), &1.pending_since))
    |> Enum.max(fn -> 0 end)
  end

  # The oldest cursor that has not moved, in seconds. A sweep that stopped
  # reports nothing; its checkpoint stops moving.
  defp oldest_cursor do
    AuroraMeter.Operations.list()
    |> Enum.map(&DateTime.diff(AuroraMeter.Clock.db_now(), &1.updated_at))
    |> Enum.max(fn -> 0 end)
  end
end
```

Two figures in that module are thresholds rather than invariants, and they are
the ones to tune. `@stale_hold_age` should be longer than your longest legitimate
job: it is a count of holds worth **looking at**, not holds that are wrong.
`oldest_cursor` should be compared against the schedule of the slowest operation
you have registered, with room for a run to be skipped.

The conservation queries read core tables directly and are yours, not the
package's. They are written against the shape that
`AuroraMeter.CreditsModelTest`'s generated histories assert after every command,
which is what makes them the right two queries rather than a guess.

## 10. What to alert on

Alert on a change, not on a level, for everything except the first two rows.

| Signal | Operational meaning |
|---|---|
| A non-empty `conservation` or `held_drift` from section 9 | The ledger and its projection disagree. Nothing else on this list is more serious. |
| `negative_balances` above your overdraft tolerance | Settlements are landing above their holds, which usually means the estimates passed to `with_credits/4` are too low. |
| `[:aurora_meter, :flush, :error]`, repeatedly | Counts are piling up in memory and can be lost with the VM. The metadata carries the error. |
| `[:aurora_meter, :credits, :settle]` with `overrun: true`, often | The same estimate problem as the row above, seen at the source. |
| `[:aurora_meter, :credits, :hold_reconciliation]` with `outcome: :released_by_other` | Your policy is releasing work that then completes. Each one is a `settle_missed:` debit. |
| `[:aurora_meter, :operations, :batch]` stopping for an operation | Its measurements are `items` and `duration_ms` and its metadata carries `name` and `result`. Silence from one name is what a pause and a dead scheduler both look like. |
| `[:aurora_meter, :retention, :prune]` with `blocked: true`, for more than a day | Section 7's table. A single blocked run is normal; a week of them is a node nobody has looked at. |
| `[:aurora_meter, :record, :stop]` with an error `result` | Durable recording is failing. `{:error, {:unavailable, _}}` is retryable with the same id; `{:error, {:conflict, _}}` is a caller reusing an identity for different content. |
| Stale holds by age, rising | Either a policy that is not configured or work that is dying without saying so. |

The full event list, with every measurement and every metadata key, is
[Telemetry](telemetry.md). `[:oban, :job, :stop]` and its siblings come from
Oban and carry the worker name, which is how to chart run counts per worker.

## Where next

* [Scheduler map](scheduler.md): every worker, its schedule and what a second run
  of it does.
* [Retention](retention.md): the allow list, the flush-receipt rule and the
  measured sizing.
* [Rebuilding the event projection](replay.md): the replay runbook.
* [Credits](credits.md): the hold, settle and release contract behind section 3.
* [Guarantees and limits](guarantees.md) and [Correctness](correctness.md): what
  is promised, under what conditions, and which test holds it.
