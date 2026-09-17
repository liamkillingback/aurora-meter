# 09d: the failure recipes

Build unit 09d, V1 task 09.08. Eight recipes, what each one left in the
database and in the ledger, the recovery command and its result, and what stays
uncertain.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only. Nothing here is invented: a command that was
> not run is named as not run.

Rule 4 applies. Nothing in this file ticks a checkbox and nothing is committed.

Run on 2026-09-17 against a real Postgres 16.13, from a database reset with
`mix ecto.reset` and seeded with `mix sample.seed`. Every figure below is read
out of `examples/aurora_meter_example_ai/tmp/sample-failures/<name>.json`,
which `mix sample.failure` wrote, and every one of them is also asserted by
`test/sample_failure_test.exs`.

```
mix ecto.reset && mix sample.seed && mix sample.failure all
mix sample.failure --check
  ok    callback_raise.json        (callback_raise,        2026-09-17T01:28:34Z)
  ok    duplicate_event.json       (duplicate_event,       2026-09-17T01:28:35Z)
  ok    exporter_timeout.json      (exporter_timeout,      2026-09-17T01:28:35Z)
  ok    insufficient_balance.json  (insufficient_balance,  2026-09-17T01:28:34Z)
  ok    late_correction.json       (late_correction,       2026-09-17T01:28:35Z)
  ok    untrappable_death.json     (untrappable_death,     2026-09-17T01:28:34Z)
  ok    worker_retry.json          (worker_retry,          2026-09-17T01:28:35Z)
```

Seven ran here. The eighth, `customer_cancellation`, needs a provider and ran
inside the real Stripe proof; its evidence is `pro-proof/summary.json` and
`09d-webhook.md`, and `mix sample.failure customer_cancellation` **aborts by
name** in the core profile rather than simulating anything.

---

## 1. insufficient_balance

**Trigger.** `Generations.create(scope, %{"kind" => "text", ...}, request_id)`
against two wallets.

**Application.**

| wallet | returns |
|---|---|
| holding nothing | `{:error, :insufficient_credits}` |
| owing 3 USD | `{:error, :debt_outstanding}` |

**Database.** `generations`: 0 rows. `sample_outbox_items`: 0 rows. For either
wallet. The refusal is at the credit hold, before the work and before the
record.

**Ledger.** The empty wallet, before and after, identical: balance 0, held 0,
available 0, spendable 0, 0 entries, conservation holds.

The indebted wallet, and this is the half the recent repairs made reachable:

| | micro-USD |
|---|---|
| balance | 1 000 000 |
| promotional | 4 000 000 |
| available | 1 000 000 |
| **spendable** | **0** |
| **promotional_spendable** | **0** |
| debt | 3 000 000 |
| lots | promotional 4 000 000 `:open`; paid 2 000 000 `:reversed` |

Conservation holds. R1, R2 and R3 in one row each: the promotion survived the
refund (R2), the reversal came out of the paid lot and stayed there (R1), and
both spendable figures read zero while `available` reports the identity it has
always reported (R3).

**Recovery.** None needed. `AuroraMeter.Credits.grant/3`; for the indebted
wallet a grant of any category clears the debt first.

**Uncertain.** Nothing.

---

## 2. callback_raise

**Trigger.** A prompt beginning `fail:` on an **image** request, so the raise
crosses both `Credits.with_credits/4` and `AuroraMeter.with_quota/4`.

**Application.** `{:error, {:provider_failed, "the simulated provider refused:
fail: the provider refused"}}`.

**Database.**

| table | rows |
|---|---|
| `generations` | 1: `status: "rejected"`, `event_id: nil`, `cost_micros: nil`, `estimate_micros: 1270` |
| `sample_outbox_items` | **0** |

**Ledger.** Before and after identical: balance 5 000 000, held **0**,
available 5 000 000, 1 entry. Usage 0 before and 0 after. The `:images` quota
reads `used: 0` of 200, so the reservation came back too.

**Recovery.** None. Both were released by the library, on the way out, because
the callback left as an exception.

**Uncertain.** Nothing.

---

## 3. untrappable_death

**Trigger.**

```elixir
Task.start(fn ->
  Generations.arm(:after_record, fn -> Process.exit(self(), :kill) end)
  Generations.create(scope, attrs, request_id)
end)
```

Exit reason observed: `:killed`. The seam was reached (`reached_the_seam:
true`), so the kill really did land after `record/4` committed and before the
`generations` row was written.

**Database.**

| what | result |
|---|---|
| `sample_outbox_items` | 1 row: `gen:a5ce41f1-…`, `tokens`, quantity 16, state `pending` |
| `generations` | **no row** |
| `Ops.orphans/1` | 1 |

and, through `AuroraMeter.Credits.pending_holds/1`:

| reference | held_delta | amount column | status |
|---|---|---|---|
| `gen:a5ce41f1-…` | **460** | **0** | `pending` |

**Ledger.**

| | before | after the kill | after recovery |
|---|---|---|---|
| balance | 5 000 000 | 5 000 000 | 4 999 840 |
| **held** | 0 | **460** | 0 |
| available | 5 000 000 | 4 999 540 | 4 999 840 |
| spent | 0 | 0 | 160 |
| lot consumed | 0 | 0 | 160 |
| lot reserved | 0 | 460 | 0 |

Conservation holds at all three points.

**The first draft of this recipe was wrong and the ledger is what said so.** It
recorded "the credit was settled: the money is right and only the local row is
missing". The kill lands *inside* the `with_credits/4` callback, after
`record/4` returned and before the callback did, so the settle never happened
and 460 micro-USD is reserved with nothing pointing at it.

**Recovery, two steps.**

1. `mix sample.repair --apply`: 1 orphan, 1 rebuilt, `generations` row present
   afterwards. What it cannot rebuild is the prompt, and the rebuilt row says
   so rather than inventing one.
2. `AuroraMeter.Credits.reconcile_holds(older_than: t)`, which asks
   `AuroraMeterExampleAi.HoldPolicy`:
   `%{examined: 1, settled: 1, released: 0, kept: 0, failed: 0, already_closed: 0}`.
   Settled for **160**, the real cost, not for the 460 that was held. The
   policy decides from the export intent and never from the hold's age.

**Uncertain.** Nothing. Every fact is either committed or absent.

---

## 4. worker_retry

**Trigger.** `Journal.script(reference, [{:retry, 1}, :accepted])`, then two
drainer ticks.

**Database.**

| after | state | attempts | last_outcome |
|---|---|---|---|
| first tick | `pending` | 1 | `retry:1` |
| second tick | `delivered` | 1 | `accepted` |

**Effects.** 2 delivery attempts, **1** accepted delivery.

The documented end state names the effect count and never the run count. The
`attempts` column reads 1 rather than 2 because it counts retries: only
`{:retry, _}` increments it, since an accepted, rejected or uncertain item is
not going to be sent again.

**Ledger.** Unchanged. Delivery does not touch it.

**Recovery.** None. This is what at-least-once with an idempotent effect looks
like when it works.

**Uncertain.** Nothing.

---

## 5. duplicate_event

**Trigger.** `record/4` twice with one id and one payload, then once more with
`occurred_at` one microsecond later.

| call | returns |
|---|---|
| first | `{:ok, %Event{seq: 15, quantity: 40}, :inserted}` |
| second | `{:ok, %Event{seq: 15, quantity: 40}, :duplicate}` |
| third | `{:error, {:conflict, %Event{…}}}` |

The second returns the **same event**: same `id`, same `seq`, same
`recorded_at`.

**Database.** `sample_outbox_items` for that id: **1** row, `pending`, quantity
40, attempts 0.

**Projection.** usage before 0, after 40, delta **40**.

**Recovery.** None.

**Uncertain.** Nothing about the duplicate. The third call is X381 reproduced
from a host's side: the identity covers the whole payload including
`occurred_at` to the microsecond, so "retry with the same id" means retry with
the same id **and the same payload**, and a caller that did not persist the
payload before the call cannot reproduce it afterwards.

---

## 6. exporter_timeout

**Trigger.** `Journal.script(reference, [:uncertain, :accepted])`, then four
drainer ticks. The `:accepted` queued behind the `:uncertain` is the control:
anything that retried the item would move it to `delivered`, and the recipe
would say so loudly rather than reporting an absence.

**Database.**

| after | state | attempts | last_outcome | next_attempt_at |
|---|---|---|---|---|
| first tick | `uncertain` | 0 | `uncertain` | `NULL` |
| three more ticks | `uncertain` | 0 | | |

`never_retried: true`. Age reported against a 82 800 second (23 hour) horizon,
`within_horizon: true`.

**Ledger.** Unchanged by the delivery: balance 4 999 840, held 0, spent 160,
conservation holds. The customer was charged when the work ran; whether the
provider was told is a question about an invoice.

**Recovery.** In the core profile there is none, and the recipe says so rather
than printing a row edit. In the Pro profile the recipe prints the read-only
provider query first and then
`AuroraMeter.Pro.Recovery.acknowledge_item/2` or `abandon_item/2` with an
`expected:` map, a reason and evidence. Neither has a `force:` option and both
refuse if the item has moved since it was read.

**Uncertain, three entries and not empty by design.**

- whether the provider accepted the item: the request may have arrived and the
  answer may have been lost, and retrying cannot distinguish those;
- an empty search at the provider is not proof that nothing arrived, and a zero
  on an invoice is not either;
- past the 23 hour horizon the provider's idempotency key may have expired, so
  a resend stops being the same request.

---

## 7. late_correction

**Trigger.** One settled generation of 16 tokens, its outbox item **delivered**,
then `AuroraMeter.correct(org, "gen:…", 4, id: "credit:…", metadata: %{"ticket"
=> "SUP-42"})`.

| call | returns |
|---|---|
| the correction | `{:ok, %Event{kind: :correction, quantity: 4, original_event_id: "gen:…"}, :inserted}` |
| a correction of 16 on top | `{:error, {:invalid, [quantity: :exceeds_original]}}` |
| the same correction id again | `{:ok, %Event{…}, :duplicate}` |

**Database.**

| event_id | state | quantity |
|---|---|---|
| `gen:154d5942-…` | `delivered` | 16 |
| `credit:7171a138-…` | `delivered` after a drain | 4 |

The original row is untouched.

**Quantities.** original 16, reduced by 4, `AuroraMeter.usage/2` = **12**.

**Ledger.** Unchanged. A correction reduces the quantity reported for billing;
it does not refund credit.

**Recovery.** In the core profile none is possible and that is the honest
answer. In the Pro profile the correction is staged for export and, past the
adjustment window, quarantined as a reconciliation item naming the difference.

**Uncertain, two entries:** whether the provider will accept the adjustment at
all, and what the customer should be charged once the invoice and the corrected
quantity disagree.

---

## 8. customer_cancellation

**Profile: Pro.** Without it:

```
** (RuntimeError) The customer_cancellation recipe needs the Pro profile, and
this build does not have Aurora Meter Pro in it.
```

It does not degrade into a simulation, and `test/sample_failure_test.exs`
asserts that refusal in the core profile rather than skipping.

Run inside the real Stripe test-mode proof, 2026-09-17,
`stripe-proof-20260917T011750Z-3651de`:

| | observed |
|---|---|
| subscription before | `sub_1UGTxz…`, `active`, period 1789606112..1792198112 |
| cancelled with | `stripe delete /v1/subscriptions/<id> --confirm` |
| status after | `canceled` |
| refund | `re_3UGTy7…`, 1000 cents, `succeeded` |
| reversals on the ledger | **1** |
| reversed micro-USD | 10 000 000 |
| the lot it came out of | the **paid** lot, `reversed: 10 000 000` |
| a redelivered refund | reverses nothing further (asserted at step 8's shape for payments; the refund's redelivery is `test/pro/billing_test.exs`) |
| export for the elapsed part | still delivered: the invoice charges 579 |

`stripe subscriptions cancel` is never used: it hangs on a prompt when it is not
attached to a terminal.

---

## 9. The instruments, and the seven that were watched failing

`tmp/v1/09d/controls-recipes.sh`, held on the core lane for the whole cycle,
every file snapshotted by sha256 and restored on an EXIT trap.

| control | planted | expected | observed |
|---|---|---|---|
| D0 | nothing | pass | pass |
| D1 | a recipe heading renamed in `docs/failures.md` | fail | fail, on the document-to-code cross-check |
| D2 | `UPDATE …` inside a `### Recovery` code fence | fail | fail, on the row-edit scan |
| D3 | UPDATE, INSERT and DELETE as **prose** in a Recovery section | **pass** | pass |
| D4 | `net_quantity/2` reverted to `gross - corrections` | fail | fail, on the net figure |
| D5 | the `kind` removed from the staged payload | fail | fail |
| D6 | the `:after_record` fault seam removed from the money path | fail | fail |
| D7 | nothing, after restore | pass | pass |

`controls with a wrong answer: 0`.

D3 is the one that makes D2 worth anything. The first version of the row-edit
scan read the whole document and failed on line 26, which is the sentence
**stating the rule**. You cannot say "no recovery step contains an UPDATE"
without the word, which is the same amendment `no_payment_test.exs` records for
pages and for the same reason. The scan now reads only fenced code inside
`### Recovery` sections, which is exactly the set of things a reader copies out
and runs.

D6 is the control for the recipe that would be easiest to fake: without the
fault seam there is no orphan, and the recipe reports one only because a
process really was killed at a real seam.

## 10. The tests

`test/sample_failure_test.exs`, 14 tests:

- one per recipe, asserting the figures above;
- the document-to-code cross-check, in both directions, with its own control on
  the heading parser;
- the row-edit scan, with its own three-leg control;
- the unknown-recipe refusal.

Both suites at two seeds:

```
core profile  --seed 0     266 passed, 2 files excluded (:pro)
core profile  --seed 1234  266 passed
Pro  profile  --seed 0     280 passed
```
