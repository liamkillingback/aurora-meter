# The failure catalogue

Eight ways this application can fail, what each one leaves in the database and
in the ledger, and what to do about it.

Every recipe here **runs**:

```bash
mix sample.failure                      # list them
mix sample.failure untrappable_death    # run one
mix sample.failure all                  # run the seven that need no provider
mix sample.failure --check              # re-assert the last run's JSON
```

Each run writes `tmp/sample-failures/<name>.json` with the figures it observed,
and `test/sample_failure_test.exs` asserts the end state every section below
documents. So this file cannot drift from the software without the suite going
red, which is the only arrangement under which a failure catalogue stays true.

The figures quoted below are from a real run on 2026-09-17 against a real
Postgres database. Yours will differ in the identifiers and agree in the
shapes.

## The two rules this file obeys

**No recovery step edits a row.** Not one `UPDATE`, not one `INSERT`, not one
`DELETE`. Every recovery is a named function or a Mix task, and where the free
core has no such function the recipe says so rather than printing a console
recipe that mutates the ledger by hand. A test asserts the absence of those
three words in this file.

**No recipe says "this is handled".** Each one shows the rows.

---

## insufficient_balance

**Profile:** core. **Shows:** a refusal before any work runs, and the two
different reasons a wallet can refuse.

### Setup

Two organisations. One has a wallet holding nothing at all. The other was
granted 2 USD paid and 4 USD promotional, then charged a 5 USD reversal: the
paid lot covers 2 USD of it and a promotion is never taken to repay a debt, so
that wallet ends up **owing 3 USD while still holding 4 USD of promotional
credit**.

### Trigger

```elixir
Generations.create(scope, %{"kind" => "text", "prompt" => "...", "model" => "nimbus-1-mini"}, request_id)
```

### What the application shows

| Wallet | Returns |
|---|---|
| holding nothing | `{:error, :insufficient_credits}` |
| owing 3 USD | `{:error, :debt_outstanding}` |

Two refusals, two different words, and the difference matters to whoever reads
them. `:insufficient_credits` is the ledger's word for a wallet that was never
funded and a support agent goes looking for a missing grant.
`:debt_outstanding` is a funded wallet that may not spend, and the grant is not
missing.

The `/generate` page renders each refusal in its own sentence, and the second
one gets the debt banner above the form.

### What the database shows

```sql
SELECT id, status FROM generations WHERE org_id = <org>;          -- 0 rows
SELECT event_id, state FROM sample_outbox_items
  WHERE tenant_key = '<tenant>';                                   -- 0 rows
```

Nothing at all, for either wallet. The refusal happens at the credit hold,
which is before the work runs and before anything is recorded. There is no
generation, no event, no export intent and no partial state to clean up.

### What the ledger shows

The empty wallet, before and after, identical:

| | |
|---|---|
| balance | 0 |
| held | 0 |
| available | 0 |
| spendable | 0 |
| debt | 0 |
| entries | 0 |

The indebted wallet:

| | |
|---|---|
| balance | 1 000 000 |
| promotional | 4 000 000 |
| available | 1 000 000 |
| **spendable** | **0** |
| **promotional_spendable** | **0** |
| debt | 3 000 000 |
| lots | promotional 4 000 000 `:open`; paid 2 000 000 `:reversed` |

Read the third and fourth rows against the first and second. The wallet holds
credit, `available` says so, and `spendable` says zero, because while a wallet
owes anything every hold and every debit is refused whatever the balance is.
`available` is an arithmetic identity (`balance - held`) with a published
meaning and it has not changed; `spendable` is the figure that answers "what
would a hold actually be allowed to take", and it is the one that went to zero.

Conservation holds in both: `sum(entry.amount) == balance`,
`sum(entry.held_delta) == held`, `balance - held == available`.

### Recovery

None is needed: nothing happened. To make the wallet able to spend:

```elixir
AuroraMeter.Credits.grant(org, amount, reference: "...", category: :paid)
```

For the indebted wallet a grant of **any** category clears the debt first and
only the remainder becomes spendable. That is the one place a promotion and a
payment behave the same way.

### What stays uncertain

Nothing.

---

## callback_raise

**Profile:** core. **Shows:** a raise inside the work, and the hold and the
quota reservation both coming back.

### Setup

One organisation on `:studio` with 5 USD of paid credit.

### Trigger

```elixir
Generations.create(scope, %{"kind" => "image", "prompt" => "fail: the provider refused", "model" => "nimbus-1"}, id)
```

A prompt beginning `fail:` makes the simulated workload raise
`AuroraMeterExampleAi.Tokens.ProviderError` from inside the
`AuroraMeter.Credits.with_credits/4` callback, which is itself inside
`AuroraMeter.with_quota/4` because this is an image request.

### What the application shows

```elixir
{:error, {:provider_failed, "the simulated provider refused: fail: the provider refused"}}
```

and the page says: the work failed, nothing was charged, and the quota was
given back.

### What the database shows

```sql
SELECT id, status, event_id, cost_micros, estimate_micros FROM generations WHERE org_id = <org>;
```

| id | status | event_id | cost_micros | estimate_micros |
|---|---|---|---|---|
| 5fbe8d91-… | `rejected` | `NULL` | `NULL` | 1270 |

One row, so the attempt is visible in the customer's history rather than only
in a flash message, and **no export intent at all**, because nothing was ever
recorded.

### What the ledger shows

Before and after are identical:

| | before | after |
|---|---|---|
| balance | 5 000 000 | 5 000 000 |
| held | 0 | 0 |
| available | 5 000 000 | 5 000 000 |
| entries | 1 | 1 |

Usage is 0 before and 0 after. The `:images` quota reads `used: 0` of 200.

### Recovery

None. The hold and the quota reservation were both released on the way out, by
the library, because the callback left as an exception.

**This is the sharpest edge in the whole integration.** `with_quota/4` commits
its reservation on any **normal** return, including `{:error, :whatever}` from
your own code. Raising is the only channel it has for "the work did not
happen". A business refusal that happens inside the callback therefore has to
leave as an exception and be turned back into a tuple outside, which is what
`AuroraMeterExampleAi.Generations.Refused` is for, and if you return an error
tuple instead you have billed a quota unit for work you did not do and nothing
will tell you.

### What stays uncertain

Nothing.

---

## untrappable_death

**Profile:** core. **Shows:** a process killed between the durable event and
this application's own row, and the **open hold** that nobody mentions.

### Setup

One organisation with 5 USD of paid credit.

### Trigger

```elixir
Task.start(fn ->
  AuroraMeterExampleAi.Generations.arm(:after_record, fn -> Process.exit(self(), :kill) end)
  AuroraMeterExampleAi.Generations.create(scope, attrs, request_id)
end)
```

`:after_record` is a fault seam in `Generations` that runs after
`AuroraMeter.record/4` has returned, which is after the event, its projection
delta and its export intent have committed, and before this application writes
its own `generations` row. `Process.exit(self(), :kill)` cannot be trapped,
runs no `after` block and runs no `on_exit`. Whatever survives, survives
because it was committed.

Observed exit reason: `:killed`.

### What the database shows

```sql
SELECT event_id, feature, quantity, state FROM sample_outbox_items WHERE tenant_key = '<tenant>';
SELECT id, status FROM generations WHERE org_id = <org>;
```

| what | result |
|---|---|
| `sample_outbox_items` | one row: `gen:6a3fad29-…`, `tokens`, quantity 16, state `pending` |
| `generations` | **no row** |
| `AuroraMeterExampleAi.Ops.orphans/1` | 1 |

and, read through `AuroraMeter.Credits.pending_holds/1`:

| reference | held_delta | amount column | status |
|---|---|---|---|
| `gen:6a3fad29-…` | 460 | **0** | `pending` |

Read that last line twice. `pending_holds/1` returns raw ledger transactions,
and on a hold row the `amount` column is `0`, because a hold moves the reserved
figure and not the balance. The reservation is in `held_delta`.
`reconcile_holds/1` maps that same column into the reconciler callback's
`hold.amount`, so the two halves of one documented job use the word "amount"
for two different things and only one of them is the money. Printing
`txn.amount` for an open hold prints zero for every hold there is.

### What the ledger shows

| | before | after the kill | after recovery |
|---|---|---|---|
| balance | 5 000 000 | 5 000 000 | 4 999 840 |
| **held** | 0 | **460** | 0 |
| available | 5 000 000 | 4 999 540 | 4 999 840 |
| spent | 0 | 0 | 160 |
| lot: consumed | 0 | 0 | 160 |
| lot: reserved | 0 | 460 | 0 |

**The hold is still open after the kill, and this is the half that is easy to
get wrong.** The first draft of this recipe said the credit had been settled;
the ledger said otherwise. The kill lands *inside* the `with_credits/4`
callback, after `record/4` committed and before the callback returned, so the
settle never happened. The money is not wrong, it is pending: 460 micro-USD of
estimate is reserved and `available` is that much lower until somebody decides.

Nothing releases it on its own, ever. The age of a hold is not evidence of
anything: a job that legitimately runs for nine hours and a job whose process
was killed nine hours ago are the same row.

### Recovery

Two steps, answering two different questions.

**1. The missing row.**

```bash
mix sample.repair --apply
```

Rebuilds the `generations` row from the export intent, which is this
application's own durable record of what it recorded. Observed: 1 orphan, 1
rebuilt. What it cannot rebuild is **the prompt**: customer content is not in
the event and is not in the intent, and the rebuilt row says so rather than
inventing one. What you did not record durably, you cannot get back.

**2. The open hold.**

```elixir
AuroraMeter.Credits.reconcile_holds(
  older_than: DateTime.add(AuroraMeter.Clock.now(), -3600, :second)
)
```

This asks the configured `AuroraMeterExampleAi.HoldPolicy` about every hold
older than the cutoff and applies the answer. The policy decides from the
**export intent**: if the intent is there the work finished, so settle for what
it really cost; if it is not, release the reservation whole. It never decides
from the age.

Observed report: `examined: 1, settled: 1, released: 0, kept: 0, failed: 0`,
and the hold settled for 160 micro-USD, not for the 460 that was reserved. The
difference went back.

Before configuring a policy that can release money, do a dry run, which
examines and reports and writes nothing:

```elixir
AuroraMeter.Credits.reconcile_holds(older_than: t, reconciler: fn _hold -> :keep end)
```

### What stays uncertain

Nothing. Every fact here is either committed or absent, and both are readable.

One note for a reader comparing this with the programme's own list.
`financial-correctness-review.md` section 8's fourth bullet reads: "A killed
`with_quota` caller: local reservation leak documented; never billed." This
recipe is that bullet's sibling one layer down, for `with_credits/4`: the
reservation leaked is a **credit hold** rather than a quota reservation, and it
is not merely documented here, it is measured, reported by
`pending_holds/1`, and closed by a policy this application had to write.


---

## worker_retry

**Profile:** core. **Shows:** two delivery attempts and one effect.

### Setup

One settled generation, one `pending` outbox item.

### Trigger

```elixir
AuroraMeter.Exporter.Journal.script(reference, [{:retry, 1}, :accepted])
AuroraMeterExampleAi.SampleOutbox.Drainer.drain_now()
# wait for next_attempt_at
AuroraMeterExampleAi.SampleOutbox.Drainer.drain_now()
```

The reference exporter is scripted per subject reference. Nothing is mocked:
this is the exporter the sample ships, answering what it was told to.

### What the database shows

```sql
SELECT state, attempts, last_outcome, provider_ref FROM sample_outbox_items WHERE event_id = '<ref>';
```

| after | state | attempts | last_outcome |
|---|---|---|---|
| first tick | `pending` | 1 | `retry:1` |
| second tick | `delivered` | 1 | `accepted` |

### Effects

| | |
|---|---|
| delivery attempts | 2 |
| accepted deliveries | 1 |

**Two attempts, one effect.** The documented end state names the effect count
and never the run count, because "the job ran once" is a claim about scheduling
that nobody can make. At-least-once with an idempotent effect is the correct
shape and this is what it looks like when it works.

The `attempts` column reads **1**, not 2. It counts retries, not attempts: only
`{:retry, _}` increments it, because an accepted, rejected or uncertain item is
not going to be sent again and counting the attempt that ended it would make
the figure mean two different things depending on where it stopped. If you want
"how many times did this leave the building", count deliveries.

### What the ledger shows

Unchanged. Delivery does not touch the ledger, in either direction. The
customer was charged when the work ran.

### Recovery

None. This is the success case of a retry.

### What stays uncertain

Nothing.

---

## duplicate_event

**Profile:** core. **Shows:** one identity recorded twice: one event, one
projection delta, one export intent.

### Setup

One organisation, nothing recorded yet this period.

### Trigger

```elixir
opts = [id: id, occurred_at: at, dimensions: %{"model" => "nimbus-1-mini", "kind" => "text"}]

AuroraMeter.record(org, :tokens, 40, opts)                                   # first
AuroraMeter.record(org, :tokens, 40, opts)                                   # again
AuroraMeter.record(org, :tokens, 40, Keyword.put(opts, :occurred_at, at_plus_1_microsecond))
```

### What the application shows

| call | returns |
|---|---|
| first | `{:ok, %Event{seq: 17, quantity: 40}, :inserted}` |
| second, same payload | `{:ok, %Event{seq: 17, quantity: 40}, :duplicate}` |
| third, one microsecond later | `{:error, {:conflict, %Event{…}}}` |

The second call returns the **same event**, with the same `id`, the same `seq`
and the same `recorded_at`. Nothing happened a second time.

### What the database shows

```sql
SELECT count(*) FROM sample_outbox_items WHERE tenant_key = '<tenant>' AND event_id = '<id>';
```

One row, `pending`, quantity 40, attempts 0. One export intent for one fact.

### What the projection shows

| | |
|---|---|
| usage before | 0 |
| usage after | 40 |
| delta | 40 |

One delta, not two.

### Recovery

None. A repeated identity with the same payload is reported, not persisted.

### What stays uncertain

Nothing about the duplicate. One thing about the **third** call, and it is
worth reading twice.

`record/4`'s identity covers the whole payload, including `occurred_at` to the
microsecond. So "an unknown outcome is retryable with the same `id`" means
retry with the same id **and the same payload**. A caller that retries after a
crash and stamps a fresh `DateTime.utc_now()` gets a conflict, not a duplicate,
which is correct behaviour and is not what the sentence leads a host to build.
The constraint is structural: a caller that did not persist the payload before
the call cannot reproduce it afterwards. The export-intent seam gives you that
record for free, which is why this application recovers from the intent rather
than by calling `record/4` again.

---

## exporter_timeout

**Profile:** core (and Pro, against a real provider timeout). **Shows:** an
outcome nobody knows, which is never retried automatically.

### Setup

One settled generation, one `pending` outbox item.

### Trigger

```elixir
AuroraMeter.Exporter.Journal.script(reference, [:uncertain, :accepted])
AuroraMeterExampleAi.SampleOutbox.Drainer.drain_now()   # and three more ticks
```

`:uncertain` means the provider may or may not have taken the item and nobody
can tell. It is the lost-acknowledgement case.

The `:accepted` queued **behind** the `:uncertain` is the control: if anything
retried this item, the item would go to `delivered` and the recipe would say so
loudly instead of quietly reporting an absence.

### What the database shows

```sql
SELECT state, attempts, last_outcome, next_attempt_at, updated_at
  FROM sample_outbox_items WHERE event_id = '<ref>';
```

| after | state | attempts | last_outcome | next_attempt_at |
|---|---|---|---|---|
| first tick | `uncertain` | 0 | `uncertain` | `NULL` |
| three more ticks | `uncertain` | 0 | | |

`next_attempt_at` is `NULL`, which is how "never automatically" is written
down. The age is reported against the 23 hour horizon.

### What the ledger shows

Unchanged by the delivery. The customer was charged when the work ran. Whether
the provider was told is the open question, and it is a question about an
invoice rather than about this ledger.

### Recovery

**In the free core there is no guarded recovery operation, and this recipe says
so rather than printing a row edit.**

What the free path gives you is the fact: the item is `uncertain`, it is
visible on `/ops` with its age, and nothing will retry it behind your back.
What it does not give you is a mechanism for recording a decision about it.

In the Pro profile that mechanism is `AuroraMeter.Pro.Recovery`. Read at the
provider first, with a read-only call:

```bash
stripe events list --limit 20
stripe billing meter_event_summaries list --meter <mtr_...> --customer <cus_...> \
  --start-time <t> --end-time <t>
```

then record what you found, with the state you expect to find:

```elixir
AuroraMeter.Pro.Recovery.acknowledge_item(item_id,
  expected: %{state: "uncertain", lease_token: token, subject_ref: subject, provider_ref: "mev_..."},
  reason: "confirmed at the provider",
  evidence: "meter event summary shows the quantity for this window")
```

or, if you can show it did **not** land:

```elixir
AuroraMeter.Pro.Recovery.abandon_item(item_id,
  expected: %{state: "uncertain", lease_token: token, subject_ref: subject},
  reason: "not present at the provider",
  evidence: "...")
```

Both refuse if the item has moved since you read it, both write a recovery
action row recording the decision and what you believed when you made it, and
neither has a `force:` option.

### What stays uncertain

This section is not empty, and it is not empty by design. The first entry is
the Aurora Meter V1 programme's own words, quoted rather than paraphrased, so
that the two can be compared:

> `financial-correctness-review.md` section 8, first bullet: "Provider meter
> event acceptance vs asynchronous rejection: `accepted` until reconciled."

This application's teaching outbox has no `accepted` and no `confirmed`. It has
`uncertain`, which is the same fact with fewer words. Aurora Meter Pro's outbox
has both, and the reconciler is what moves one to the other.

- **Whether the provider accepted this item.** The request may have arrived and
  the answer may have been lost, and no amount of retrying can distinguish
  those two.
- **An empty search at the provider is not proof that nothing arrived**, and a
  zero on an invoice is not either. If you cannot show that the request did not
  land, leave it uncertain: under-billing is recoverable and double-billing is
  a refund and an apology.
- **After the 23 hour horizon**, the provider's own idempotency key may have
  expired, so a resend stops being the same request and becomes a second one.
  That is the point after which the decision can no longer be undone by
  waiting.

---

## late_correction

**Profile:** core and Pro. **Shows:** a correction after the period's export,
bounded and immutable.

### Setup

One settled generation of 16 tokens, **already delivered**, so the provider has
been told the larger number.

### Trigger

```elixir
AuroraMeter.correct(org, "gen:154d5942-…", 4,
  id: "credit:7171a138-…",
  metadata: %{"ticket" => "SUP-42"})
```

### What the application shows

| call | returns |
|---|---|
| the correction | `{:ok, %Event{kind: :correction, quantity: 4, original_event_id: "gen:154d5942-…"}, :inserted}` |
| a correction of 16 on top of it | `{:error, {:invalid, [quantity: :exceeds_original]}}` |
| the same correction id again | `{:ok, %Event{…}, :duplicate}` |

The second row is the bound: the cumulative magnitude of the corrections of one
original can never exceed that original's quantity, checked under a lock on the
original row, so two operators correcting the same fact at the same moment
cannot between them credit more than was charged.

The third row is the same identity rule `record/4` has: repeating a correction
id is a duplicate, not a second credit, even when the original is by then
partly corrected.

### What the database shows

```sql
SELECT event_id, state, quantity, last_outcome FROM sample_outbox_items
  WHERE tenant_key = '<tenant>' ORDER BY inserted_at;
```

| event_id | state | quantity |
|---|---|---|
| `gen:154d5942-…` | `delivered` | 16 |
| `credit:7171a138-…` | `delivered` (after a drain) | 4 |

**The original row is untouched.** A correction is its own row pointing at the
event it reduces, with its own identity and its own export intent, and both
stay in the history for ever. That is what makes a corrected invoice explicable
six months later.

The correction inherits the original's period, feature, plan attribution and
dimensions. A September fact corrected in October changes September's invoice.

### Quantities

| | |
|---|---|
| original | 16 |
| reduced by | 4 |
| net expected | 12 |
| `AuroraMeter.usage(org, :tokens)` | 12 |

### What the ledger shows

Unchanged: balance 4 999 840, held 0, spent 160.

A correction reduces the **quantity reported for billing**. It does not refund
credit: the customer paid this application for work this application did, and
what was over-reported to the provider is a different conversation.

### Recovery

In the core profile: **none is possible**, and that is the honest answer. The
provider has the larger number and this application has no way to talk to it.

In the Pro profile the correction is staged for export like any other event
and, when the provider's adjustment window has closed, it is quarantined as a
reconciliation item naming the difference.
`AuroraMeter.Pro.Recovery.list_uncertain/1` and the `/ops` page show it, and
the operator settles the difference with Stripe. The software reports; it does
not fix, and it never edits a finalised invoice.

### What stays uncertain

- **Whether the provider will accept the adjustment at all.** The meter event
  adjustment window is finite.
- **What the customer should be charged**, once the invoice and the corrected
  quantity disagree. The software reports the difference; a person decides what
  to do about it, and that is a commercial decision rather than a defect.

---

## customer_cancellation

**Profile:** Pro, and a Stripe **test-mode** account. **Shows:** a cancelled
subscription and a refunded top-up, reversed exactly once.

Without the Pro profile this recipe **aborts by name**:

```
The customer_cancellation recipe needs the Pro profile, and this build does not
have Aurora Meter Pro in it.
```

It does not degrade into a simulation. A simulated refund in a billing sample
would be the one thing this sample exists not to teach.

### Setup

One organisation subscribed to `:studio` in Stripe test mode, one top-up paid
with `4242 4242 4242 4242` and granted by the webhook, and auto-recharge armed
so that the race between a manual top-up and an automatic one is in scope.

### Trigger

```bash
./scripts/pro-proof.sh
```

which, among the rest of its run, cancels the subscription with

```bash
stripe delete /v1/subscriptions/<id> --confirm
```

**never** `stripe subscriptions cancel`, which hangs on a prompt when it is not
attached to a terminal, and then refunds the last charge.

### What the database, the ledger and Stripe show

`docs/evidence/v1/phase-09/pro-proof/summary.json` in the core package carries
the observed run: the subscription's status and final period as Stripe reports
them, the reversal rows, the lot each reversal came out of, and the three
reconciliations (ledger, export and invoice).

The end state this recipe documents:

- the subscription row's `status` and period come from a **retrieve** against
  Stripe under the tenant lock, not from the event's snapshot, so a stale
  redelivery cannot move a subscription backwards;
- one reversal per refund, against the **paid** lot, with the lot's remaining
  amount restored exactly once;
- a redelivered `charge.refunded` reverses nothing further;
- export for the elapsed part of the period still delivers: cancelling stops
  the next period, not the one that has already been used.

### Recovery

None. The reversal rows are the record.

### What stays uncertain

Nothing about the refund. One thing about the cancellation: the final invoice
is Stripe's, it is produced on Stripe's schedule, and until it is finalised the
amount on it is Stripe's arithmetic rather than this application's.

---

## What this catalogue does not cover

- **A provider outage that lasts past the horizon.** `exporter_timeout` shows
  the first 23 hours. What to do on the second day is an operational decision
  that depends on the provider's own support answer.
- **Two nodes.** Everything here is one node. Buffered counters are strict on
  one node and convergent across nodes, and the difference is documented in
  Aurora Meter's own `docs/metering.md` rather than reproduced here.
- **A database that loses a committed transaction.** Every recipe here assumes
  Postgres keeps what it said it kept.
