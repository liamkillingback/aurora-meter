# Metering

> **The `tenant` argument.** Every call takes the tenant first: the organisation
> or account being metered (`"org_42"`, an integer id, or your own struct through
> a configured `AuroraMeter.Tenant`). It must be stable and unique per customer.
> See "What `org` is" in the README and the `:tenant` option in
> [Configuration](configuration.md).

## Recording usage

```elixir
AuroraMeter.track(tenant, :ai_generations)        # +1
AuroraMeter.track(tenant, :ai_generations, 5)     # +5
```

`track/4` runs on the ETS hot path, with no database round-trip. It increments an
in-memory counter keyed by `{tenant, feature, period}` and marks it dirty for the
flusher. Aggregate throughput is millions of increments/second because load
spreads across many counter keys.

## Reading usage

```elixir
AuroraMeter.usage(tenant, :ai_generations)   # current-period integer
AuroraMeter.usage_all(tenant)                # %{feature => value}
```

A cold counter is seeded once from the last flushed database value, so reads are
always correct even after a restart.

## Periods

Usage is bucketed by billing period. The free core uses the calendar month (UTC);
a new period starts a fresh counter automatically (no reset job). With the Pro
package, periods align to the tenant's subscription.

A period is a **half-open UTC interval** `[start, end)`: `start` belongs to the
period, `end` does not, and the `end` of one period is the `start` of the next.
So an increment at exactly midnight on the first of the month is counted once,
in the new period, and no instant belongs to two periods or to none. Custom
period sources, the validation their return value is put through, and the
`:clock` seam that makes all of this testable are in [periods](periods.md).

## History

Alongside the period counter, `track/4`, `reserve/3` and `with_quota/4` also
bump a UTC **day bucket** for the same feature (still ETS, still no database on
the hot path). The flusher persists it to `aurora_meter_history`, and

```elixir
AuroraMeter.history(tenant, :ai_generations, days: 30)
# => [%{date: ~D[2026-08-08], value: 0}, ..., %{date: ~D[2026-09-06], value: 12}]
```

returns one point per day, oldest first, with today's live value merged in.
This is what usage charts read. Disable with `config :aurora_meter, history: false`
if you truly never chart usage.

## Where a feature's quantity comes from

Every feature has exactly one **reporting source**, and it is the answer to one
question: when something asks how much this customer used, which number does it
get? There are two answers, and the default is the first.

```elixir
config :aurora_meter, feature_sources: %{tokens: :events}
# anything not listed is :buffered
```

| Source | The quantity is | Written by | What you lose in a crash |
|---|---|---|---|
| `:buffered` (default) | the ETS counter, flushed to `aurora_meter_counters` | `track/4`, `reserve/2,3`, `with_quota/4` | everything not in an acknowledged flush batch |
| `:events` | the sum of the durable events in `aurora_meter_events` | `record/4`, `record_batch/2` | nothing that was committed |

A feature cannot be both, and the library goes to some trouble to keep it that
way, because a feature that was both would be billed twice: once as a counter
delta and once as an event.

  * `track/4` raises `ArgumentError` for an `:events` feature, with or without
    `durable: true`. The raise happens before anything is written.
  * `reserve/2,3` raises too. It is the reserve-and-bill-now primitive, so it
    writes straight into the pending flush.
  * `with_quota/4` keeps working and gates exactly as it always did, but
    **releases** its reservation on success instead of committing it. See
    [Entitlements](entitlements.md).
  * `record/4` on a `:buffered` feature stores the fact, because local truth is
    worth keeping, and marks the export intent ineligible so the same usage is
    not sent to a provider twice.
  * A feature named in both `:durable_features` and `:feature_sources` as
    `:events` stops the boot.

Two consequences worth knowing before you choose `:events`:

  * **The source is a deploy-time decision, not a runtime toggle.** It is read
    once at boot. A source that could change between two calls inside one period
    is the double count this key exists to prevent.
  * **An `:events` feature has no day history.** `AuroraMeter.history/3` returns
    zeros for one, because putting projected quantities into
    `aurora_meter_history` would feed a day rollup from the same units the export
    path sends. Chart it from `AuroraMeter.Events.stream/1` instead.

`AuroraMeter.usage/2`, `usage_all/1`, `quota/2`, `check/2`, `remaining/2` and
`entitled?/2` all keep working for either source: they read the same in-memory
row, which for an `:events` feature is hydrated from the durable total.

### Migrating a feature from `:buffered` to `:events`

Core cannot make this safe on its own, and this section says so rather than
implying otherwise. The order is:

1. Deploy your `record/4` calls while the feature is still `:buffered`. The
   events are stored and their export intents are marked
   `{:ineligible, :feature_buffered}`, so you can inspect what would have been
   sent before anything is billed from it.
2. Schedule the cutover in Aurora Meter Pro, choosing a period boundary as the
   watermark.
3. At that boundary, flip `:feature_sources` to `:events` and remove the
   `track/4` calls **in the same deploy**. A call site you missed then raises on
   that node, which is the failure you want rather than a silent second count.

Without Pro there is no watermark, so a source flipped part way through a period
leaves that period's usage split between a frozen counter row and an event
total, and reconciling it is a manual job.

## Durability

By default metering is **buffered**: counters live in ETS and are flushed to
Postgres every `:flush_interval` ms and once more on a clean shutdown. What
losing the Store or the VM costs you is everything that is not yet in an
acknowledged flush batch, which is usually the last interval and is not bounded
by it: while the database is unreachable the pending set keeps growing until the
database comes back or the VM dies. That is the right trade for dashboards and
soft quotas, and the wrong one for anything you invoice.

For usage you invoice, use `AuroraMeter.record/4`. You supply the identity, and
one transaction writes the fact, its projected total and the export intent
together, so a retry after a write you never saw the answer to is reported as a
duplicate rather than charged again:

```elixir
config :aurora_meter, feature_sources: %{tokens: :events}

AuroraMeter.record(tenant, :tokens, 1_420,
  id: request_id,
  occurred_at: finished_at,
  dimensions: %{"model" => "sonnet"}
)
#=> {:ok, %AuroraMeter.Event{}, :inserted}
```

### What a crash leaves behind, and the half that is easy to miss

The transaction above is the whole of what Aurora Meter promises: the fact, its
total and its export intent commit together or not at all. What it does not
cover is the gap between that commit and **your** own row for the same work, and
a process killed in that gap leaves a fact with nothing pointing at it. The
export intent is your durable record of what was recorded, so that is what to
rebuild the row from.

If the `record/4` was inside `AuroraMeter.Credits.with_credits/4`, there is a
third thing and it is money. The callback never returned, so the settle never
ran, and the estimate is **still reserved** against the customer: the event is
committed, your row is missing and `available` is short until somebody decides.
Rebuilding the row fixes two of the three. The reservation is closed by
`AuroraMeter.Credits.reconcile_holds/1`, from a decision only you can make,
because only you know whether the work finished. See
[Credits](credits.md#recovering-stale-holds); the sweep that calls it ships in
`AuroraMeter.Oban.cron_entries/1` and keeps every hold until a reconciler is
configured.

### Correcting a recorded fact

A recorded fact is never edited and never deleted. Correcting one means
appending a second fact that reduces it, so the history still says what
happened and an invoice can still be explained:

```elixir
AuroraMeter.correct(tenant, request_id, 3,
  id: "credit_" <> request_id,
  metadata: %{"ticket" => "SUP-118"}
)
#=> {:ok, %AuroraMeter.Event{kind: :correction, quantity: 3}, :inserted}
```

The quantity is the **magnitude of the reduction**, a positive integer. What
the library guarantees about it:

  * **The cumulative corrections of one original can never exceed it.** The
    check is made while the original row is held under `SELECT ... FOR UPDATE`,
    so two operators crediting the same fact at the same moment cannot between
    them give back more than was charged. The loser is told
    `{:error, {:invalid, [quantity: :exceeds_original]}}`.
  * **A repeated correction id is a duplicate, not a second credit** (including
    when the original is by then fully corrected).
  * **A correction belongs to the original's period.** A September fact
    corrected in October changes September's total, not October's. It carries
    the original's feature, plan attribution and dimensions for the same
    reason, and it never reprices.
  * **A correction of a correction is refused.** Correct the original.

`aurora_meter_event_totals.quantity` for a key is its usage events less its
corrections, and `events` counts the rows of both kinds, so a key whose 10 was
fully reversed reads `quantity: 0, events: 2`.

To change a **dimension or a time**, reduce nothing and restate everything:

```elixir
AuroraMeter.replace(tenant, request_id, %{
    quantity: 1_420,
    occurred_at: finished_at,
    dimensions: %{"model" => "opus"}
  },
  id: "fix_" <> request_id
)
#=> {:ok, %{correction: ..., replacement: ...}, :inserted}
```

That is one transaction holding a full reversal of the original and one new
fact. The replacement's id is the correction's with `~r` appended, unless you
pass `:replacement_id`, which is what makes a retry under one caller id
idempotent for the pair. `correct/4` refuses `dimensions:` and `occurred_at:`
rather than quietly ignoring them, because accepting either would be a second
way to do this with weaker guarantees.

A correction publishes `{:aurora_meter, :event, %{kind: :correction, quantity:
q}}` on the tenant topic with a **positive** `q`: consumers subtract a
`:correction` rather than adding a negative number they may not have expected.

Corrections are free and are core's, in both editions. What is not core's is
delivering one to a payment provider: Aurora Meter Pro decides whether a meter
event can still be adjusted, and quarantines the ones that cannot with a
reconciliation item rather than dropping them. Core hands every correction to
the export seam with a reason attached, including the ones it can already tell
are not deliverable, and never marks one settled that was not.

### The legacy durable track

```elixir
config :aurora_meter, durable_features: [:ai_generations]
# or per call:
AuroraMeter.track(tenant, :ai_generations, 1, durable: true, metadata: %{req: id})
```

This is the 0.4.x mechanism. It still works, it is deprecated, and it will be
removed in 2.0. What it does is write a second row in `aurora_meter_events`
after the ETS increment, and it is worth being precise about what that row is
and is not:

  * It has **no caller identity**, so there is nothing to recognise a retry by.
    Two identical calls write two rows, and so do one call and its retry.
  * It is **not** a second source. The quantity that is reported is still the
    buffered counter; nothing reads these rows for billing.
  * It contributes to no event total and stages no export intent. Its
    `event_id` carries a `track:` prefix and its `attribution` is
    `legacy_track`, which is how you tell these rows from recorded ones.
  * The insert is not in a transaction with the ETS increment. Inside a
    transaction of your own it joins that transaction and rolls back with it,
    while the increment survives and will flush. `record/4` has no such window.

Move to `feature_sources` and `record/4` when you need the fact to survive; the
steps are under "Migrating a feature" above.
