# Rebuilding the event projection

`aurora_meter_event_totals` is a derived table. Every row in it can be rebuilt
by summing the events it came from, and `AuroraMeter.Events.Replay` is what does
the summing, into an isolated generation, while the system keeps recording.

This page is for the person who has to decide whether to run one.

## When to run a replay

* **Verification.** You want to know that the projection and the events agree.
  Run with the defaults: the rebuild is compared with the live projection and
  refuses to activate if they differ, so a verification run either tells you
  everything matches or hands you the keys that do not.
* **Repair.** You already know the projection is wrong (a fixed bug, a partly
  applied change, a hand-written statement that should never have been run) and
  you want the totals recomputed from the facts. Investigate the differences a
  verification run reported, then run with `compare: :report`.

A replay is **never scheduled**. There is no cron entry for it and there never
will be: an unattended rebuild of the number every invoice, quota and dashboard
reads is not a default anyone should get.

## What it does not do

A replay reads events and writes totals. It does not call `AuroraMeter.record/4`,
so it stages no export intent, inserts no event and cannot cause a resend. It
grants no credits, publishes no PubSub message, calls no host handler, marks no
counter key dirty and produces no flush batch. Every one of those is asserted by
`AuroraMeter.EventsReplayTest`, not merely intended.

## Running one

```elixir
# Verify. Refuses to activate if the rebuild and the live projection differ.
AuroraMeter.Events.Replay.run()

# Build and compare without activating, for a look first.
AuroraMeter.Events.Replay.run(activate: false)

# Repair, once you know why they differ.
AuroraMeter.Events.Replay.run(compare: :report)

# A bounded maintenance window: stop after 200 committed batches and resume later.
AuroraMeter.Events.Replay.run(max_batches: 200)
```

Options are on `AuroraMeter.Events.Replay.run/1`. The ones that matter most are
`:batch_size` (events per committed batch, default 5000) and `:compare`.

## Watching one

```elixir
AuroraMeter.Events.Replay.status()
AuroraMeter.Checkpoints.get("events_replay:1")
```

`status/0` gives the active, building and previous generations, the watermark
and the replay's own checkpoint. The checkpoint's `cursor` carries `seq` (where
the scan got to), `watermark`, `heartbeat_at` and `runner`; its `counts` carry
`scanned`, `projected`, `keys`, `batches` and, once compared, `differences`.

`[:aurora_meter, :replay, :batch]` fires once per committed batch, and
`[:aurora_meter, :replay, :phase]` once for each of `:announce`, `:drain`,
`:compare` and `:activate`.

**The heartbeat is a report, not a lease.** Nothing in this package subtracts it
from anything. A stalled replay is one whose `heartbeat_at` has stopped moving,
and that is a thing for a person to look at, not a thing the software decides.

## Pausing and abandoning one

```elixir
AuroraMeter.Checkpoints.pause("events_replay:1")   # stops at the next batch boundary
AuroraMeter.Checkpoints.resume("events_replay:1")  # the next run/1 carries on from the cursor
```

A pause is checked between batches, so the worst case is one more committed
batch after you asked. That batch is harmless: the cursor advances with it.

To abandon a half-built generation and start again:

```elixir
AuroraMeter.Events.Replay.prune(1)
```

That deletes the building generation's rows and its seed, clears it from the
projection state and marks its checkpoint `"abandoned"`. Nothing a reader sees
changes: a building generation is never read.

## What it costs

* **Two short exclusive locks.** The announcement and the activation each take
  `FOR UPDATE` on one row of `aurora_meter_checkpoints`. Every record and
  correction takes `FOR SHARE` on that same row first, so each of the two waits
  for the records that are already in flight (bounded by `:record_timeout`,
  15 seconds by default) and blocks the ones that start while it runs.
* **A copy of the totals table, inside the announcement.** The announcement
  copies the active generation into the building generation and into a frozen
  seed, which is what keeps a concurrent correction's negative delta off the
  `quantity >= 0` check while the scan has not reached its key. That copy is
  `2 x (rows in the active generation)`, which is one row per tenant, feature
  and period: orders of magnitude smaller than the events table, and it happens
  once. It is also the longest the announcement holds its lock, so a very large
  installation should expect recording to pause for the length of it and should
  run a replay in a quiet window.
* **Double totals writes while it runs.** From the announcement until the
  activation, every record writes its delta to two generations instead of one.
  That roughly doubles the totals-write cost of a record, and only that.
* **A full read of the events table**, in bounded batches, ordered by `seq` on
  `aurora_meter_events_seq_index`. Nothing holds a long lock and nothing holds a
  connection open across batches, so it can be paused, killed and resumed.

Expected duration is `events / per-batch rate`. Measure the rate from the first
few `[:aurora_meter, :replay, :batch]` events of your own run rather than from a
number on this page.

## If the rebuild turns out to be wrong

The previous generation is **retained**. `status/0` names it, and activating it
again is one short transaction with nothing to rebuild:

```elixir
status = AuroraMeter.Events.Replay.status()
AuroraMeter.Storage.activate_projection(status.previous_generation)
```

Prune the retired generation only once you are satisfied, and never before.

## What a kill leaves behind

Each batch commits its totals and its checkpoint in one transaction, so the
cursor always names a batch that is fully applied. A killed replay leaves:

* the building generation holding everything up to the cursor;
* the checkpoint naming that cursor;
* nothing else.

Running `run/1` again resumes there. A kill during the activation leaves either
the old generation active or the new one, and `status/0` says which.

A killed runner releases its claim by its **connection** dying, which is how a
session advisory lock works and is why there is no timeout anywhere in this.
That release is not instantaneous: a re-run in the same moment can still be told
`{:error, {:already_running, status}}`. Refusing is the safe direction to be
wrong in, and the answer is to run it again.
