# 09c: the host-owned outbox, one state per outcome

`AuroraMeterExampleAi.SampleOutbox` implements `AuroraMeter.Events.Outbox`.
`AuroraMeter.record/4` calls it **inside** the transaction that writes the event,
so an export intent is staged in the same commit as the fact it describes.
`SampleOutbox.Drainer` claims a bounded batch afterwards, on its own connection,
and hands it to `AuroraMeter.Exporter.Journal`.

## 1. Every outcome, and the row it leaves

One test per row in `test/aurora_meter_example_ai/sample_outbox_test.exs`. Each
scripts the journal for the event's subject reference, runs one synchronous
drain, and asserts the row.

| Scripted outcome | `state` | `attempts` | `last_outcome` | other | retried automatically |
|---|---|---|---|---|---|
| `:accepted` | `delivered` | 0 | `accepted` | | no |
| `{:accepted, "prov_123"}` | `delivered` | 0 | `accepted` | `provider_ref: "prov_123"` | no |
| `{:retry, 30}` | `pending` | **1** | `retry:30` | `next_attempt_at` in the future | yes, after the delay |
| `:uncertain` | `uncertain` | 0 | `uncertain` | | **never** |
| `{:rejected, :no_such_customer}` | `rejected` | 0 | `rejected:no_such_customer` | | no |
| `{:something, :nobody, :planned, :for}` | `uncertain` | 0 | `uncertain` | | never |

Only a retry increments `attempts`. An accepted, rejected or uncertain item is
not going to be sent again, so counting the attempt that ended it would make the
figure mean two different things depending on where it stopped.

The last row is `AuroraMeter.Exporter.normalize/2` doing its job: an answer
nobody understood is `:uncertain`, never `:accepted` and never `{:rejected, _}`,
because both of those are terminal. The drainer never reads the adapter's return
value directly, so a host and Aurora Meter Pro cannot disagree about what a
missing or malformed entry means.

## 2. The three tests that are about time rather than about outcomes

**"a retried item is not claimed again until its time comes."** Script
`[{:retry, 30}, :accepted]`. First drain claims 1, second drain claims **0**.
Then `next_attempt_at` is moved into the past by one second and the third drain
claims 1 and delivers. Thirty seconds are not waited for; the clock the claim
compares against is moved instead.

**"uncertain stops, and is never retried automatically."** Script
`[:uncertain, :accepted]`. First drain leaves `uncertain`. The second drain
claims **0**, so the queued `:accepted` is never reached. If the item were
retried it would have been delivered, and it was not.

**"a claimed row whose drainer died is reclaimed after the reclaim window."**
A row is put into `claimed` with a fresh `updated_at`: the next drain claims
**0**, because a live claim must not be stolen. The same row is then put into
`claimed` with `updated_at` sixty seconds ago: the next drain claims it and
delivers it. Both halves, so "it reclaims" is not "it claims anything at all".

## 3. Staging, and what happens when staging fails

**"the intent is written in the same transaction as the event."** After one
generation there is exactly one row, its `event_id` is the same string as the
generation's, its `quantity` is `prompt_tokens + completion_tokens`, its
`payload["identifier"]` is the event id and its `payload["plan_id"]` is
`"studio"`, resolved by the library from the tenant's subscription.

**"an outbox that refuses rolls the event back with it, and nothing is charged."**
The configured `:events_outbox` is pointed at a module that raises, with the
restore registered in `on_exit` before the change is made. The result:

```
{:error, {:unavailable, {:outbox, _}}} = Generations.create(...)
Repo.aggregate(Item, :count) == 0
summary.available unchanged
summary.held == 0
```

**"with the real outbox back, the same call succeeds."** The discrimination for
the test above: without it, a configuration swap that silently failed to take
effect would leave the previous test passing for the wrong reason.

## 4. Eligibility

Core decides eligibility and hands it to the callback; the callback records it.

**"an ineligible entry is recorded as skipped with its reason and never
delivered."** `enqueue/2` is called directly with
`{:ineligible, :plan_unresolved}`, which is the branch a host is most likely to
get wrong and which cannot be reached through `record/4` without engineering a
plan-attribution failure. The row lands in state `skipped` with
`last_outcome: "ineligible:plan_unresolved"`, and the next drain claims **0**.

An event whose period could not be attributed, or whose plan could not be
resolved, names no commercial contract, and guessing one is how a customer gets
billed on a price they were not on. It is recorded rather than dropped, because
a correction that quietly disappears is worse than one that is visible and
unsent (I09).

## 5. What the live database looked like

After the browser walkthrough, `globex`:

```
outbox states: %{"delivered" => 12, "pending" => 1}
token outbox rows: 13
image outbox rows: 0
orphans: 0
```

The one `pending` row is the image generation submitted moments before the
figures were collected; the drainer ticks once a second in development and had
not reached it. `/ops` has a "Drain the outbox now" button for exactly that
impatience.

The journal's own record of what it was handed is on `/ops` under "What the
reference exporter was handed", ten entries at `attempt 0`, each `:accepted`. The
page says in the same breath that the journal is an `Agent`, that it is gone when
the node stops, and that it is not a record of what was billed.

## 6. The `claimed` state, and why it is in the check constraint

The build plan for this unit listed the states as
`('pending','delivered','uncertain','rejected','skipped')` in its data model and
then described a drainer that "claims a bounded batch ... the claim sets
`state = 'claimed'` in the same statement" in its concurrency section. Those two
do not agree.

`claimed` is in the constraint. A row that is being delivered right now is
neither pending nor finished, and a state machine with no word for "in flight"
cannot survive the worker dying mid-batch: the row would have to stay `pending`,
and a second drainer would take it while the first was still talking to the
provider.

The build plan's `pending` state for `generations` went the other way and was
dropped, for the mirror-image reason: this application writes that row after the
outcome is known, so nothing can put a row into it, and a state nothing can
reach gets read as if it meant something.
