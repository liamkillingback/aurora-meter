# 09d: the real Stripe test-mode sample proof

G09 bullet 4. The sample application itself, in its Pro profile, unmodified,
against a real Stripe **test-mode** account, with the ledger, the export and
the invoice reconciled.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only. Test-mode object ids are recorded, which the
> owner authorisation records as safe.

Rule 4 applies. Nothing here ticks a checkbox and nothing is committed.

- **Run**: `stripe-proof-20260917T011750Z-3651de`, 2026-09-17, **outside CI**,
  by hand, with the owner gesture `AURORA_STRIPE_PROOF=owner`.
- **Result**: `pass`. All fifteen required steps passed, cleanup ran from the
  trap, the reconciliation reports **no unexplained difference**.
- **Machine-readable**: `summary.json` (this run's steps and the
  reconciliation), `reconciliation.json` (the three pairs on their own),
  `sample-pro-proof.json` (the harness's full report, 59 KB),
  `runs/sample-pro-proof-stripe-proof-20260917T011750Z-3651de.json` (the
  permanent per-run copy).

---

## 0. Bounds, restated where they were executed

| bound | how it was held |
|---|---|
| test mode only | harness guard G1: `STRIPE_API_KEY` must begin `sk_test_`, refused without echoing any part of it |
| never in CI | guard G2: `CI` must be unset |
| the owner gesture | guard G3: `AURORA_STRIPE_PROOF=owner`, and there is no flag that substitutes for it |
| `--live` never passed | the CLI is invoked from `stripe_call` and `stripe listen` only, neither of which takes it |
| `livemode: false` | asserted on every object that carries the field; the two that do not are named below |
| the documented test card | `pm_card_visa`, read from the documentation record at step 2 before any object existed |
| the registered webhook endpoint | not read, written or referenced; `stripe listen --forward-to` only (X1) |
| `config/secrets.exs` | detected by existence and **not opened** (D14) |
| no Docker container created, started or removed | the package container was used as it was found |
| cleanup | from a trap on every exit path |

### livemode, and the two objects that do not carry it

The authorisation says `livemode` must be `false` on every object the run
touches. Two of the objects this profile reads do not have the field at all:
`GET /v1/account`, and the `Refund` this run created. `jget` answers `""` for an
absent field and `"false"` for a present false one, so printing it is not an
assertion and an absent field printed as `livemode=` reads exactly like a false
one.

`assert_test_mode` therefore distinguishes three cases: `false` passes, `true`
**aborts the run**, and absent is recorded as absent, in the manifest, so a
reader can see which objects the assertion could actually be made against. For
those two the mode is bounded by the key prefix, which is structural.

---

## 1. What made this run different from every other profile

The host is **the sample**, not a disposable application built to be proved.
`core:examples/aurora_meter_example_ai` ran unmodified with
`AURORA_SAMPLE_PRO=1`, on a free port, against a disposable database
(`aurora_v1_stripeproof_3651de`), with both migration paths applied, and with
`stripe listen` forwarding into the webhook the sample mounts in its own
endpoint.

No proof-only HTTP surface was added to the sample. Where the other profiles
use `/aurora/ctl` and `/aurora/state`, this one uses `mix run -e` against the
sample's own public API, which is what a reader would type.

The live adapters were asserted rather than assumed, from the sample's own
configuration accessors, before any object was created:

```json
{"provider":"AuroraMeter.Pro.Stripe",
 "events_outbox":"AuroraMeterExampleAi.Pro.Outbox",
 "credits_client":"AuroraMeter.Pro.Credits.StripeClient.Live",
 "exporter":"AuroraMeter.Pro.Exporter.StripeMeterEvents",
 "meter_client":"Stripe.Billing.MeterEvent",
 "mode":":test","account":"acct_1Pho8bIWRG2AbpPz",
 "webhook_secret_configured":true,"api_version":"2025-11-17.clover"}
```

A run against a fake proves nothing, so the check refuses on any module name
matching `Fake`.

---

## 2. The steps

| # | step | result |
|---|---|---|
| 1 | guards G1 to G7 | pass, nothing created |
| 2 | the official Stripe documentation, read first | pass |
| 3 | the meter, the product and the graduated tiered metered price | pass, `livemode=false` on all three |
| 4 | the SAMPLE on the live adapters, and the forwarder ready | pass |
| 5 | a disposable organisation in the sample's own database | pass, tenant `org_1` |
| 6 | the test clock, the customer, the metered subscription | pass, and the real `customer.subscription.created` synced the tenant onto `:studio` |
| 7 | a real off-session PaymentIntent, the webhook, one grant | pass |
| 8 | the same event redelivered | pass, nothing further |
| 9 | 20 generations through `Generations.create/3` | pass, 20 created, both outboxes staged |
| 10 | Pro's deliverer to the real meter events API | pass |
| 11 | Stripe's own meter event summary | pass, **579** |
| 12 | a correction after the export | pass |
| 13 | a real refund, one reversal on the paid lot | pass |
| 14 | the clock advanced past the period end and the draft window | pass, invoice **paid** |
| 15 | the three reconciliations | pass, no unexplained difference |
| 16 | `stripe delete /v1/subscriptions/<id> --confirm` | pass, `canceled` |
| 99 | cleanup | pass |

---

## 3. The three reconciliations

### Ledger

```
granted   25 000 000   (the top-up, 2500 cents)
spent          5 790   (20 generations)
reversed  10 000 000   (the refund, 1000 cents)
balance   14 994 210
held               0
available 14 994 210
spendable 14 994 210
debt               0
identity: granted - spent - reversed == balance; balance - held == available
holds: true
```

### Export

```
sample outbox rows      21     (20 usage + 1 correction)
Pro outbox rows         21
Pro items delivered     20
staged gross           587
staged usage           579
staged corrections       8
staged net             571
delivered usage        579
provider summary       579     <- Stripe's own aggregate
identity: staged usage - staged corrections == staged net;
          staged usage == delivered usage == provider summary
holds: true
```

### Invoice

```
invoice            in_1UGTztIWRG2AbpPzZ16AkJYq   status paid
total              14 425 cents
metered quantity      579
delivered total       579
net for the period    571
difference from net     8
holds: true
```

`differences: []`.

The eight-token difference between the invoice and the net is **reported, not
zeroed**, and it is in `uncertain` with its reason: the correction was recorded
after the meter events were delivered, this run sends no meter event
adjustment, so the invoice charges the uncorrected quantity. That is
`financial-correctness-review.md` section 8's territory and the software
reports it rather than fixing it.

### What stays uncertain

1. the correction, above;
2. **the hosted Checkout redirect is not exercised.** This profile confirms an
   off-session PaymentIntent, which produces the same
   `payment_intent.succeeded` the sample's `/billing` page would. What is
   unproved is the browser round trip, not the grant.

---

## 4. Two defects this run found that a fixture could not

Both were silent, both were found by the run failing.

1. **The forwarder was delivering to the wrong path.** `start_listener` had the
   disposable host's `/aurora/webhook` hard-coded; the sample mounts at
   `/webhooks/stripe`. Stripe delivered, the router answered 404, and the
   profile waited four minutes for a sync that could never arrive. `04f`'s
   helper now takes `PROOF_WEBHOOK_PATH`, defaulting to the old value.

2. **Pro's recommended crontab and an events-source feature refuse to boot
   together.** `AuroraMeter.Pro.cron_entries()` includes `UsageReporter`, which
   reports a metered feature from the buffered counter. The sample declares
   `feature_sources: %{tokens: :events}` and exports through the outbox.
   Running both staged one `aurora_meter_usage_reports` row, and the next node
   to start raised `AuroraMeter.Pro.CutoverRequiredError` naming a cutover the
   installation never needed. Filed against Pro; the sample excludes the
   reporter with a paragraph saying why.

A third, found by the reconciliation rather than by a crash: **a correction
stages an outbox row whose `quantity` is a positive magnitude**, so summing the
column counts a credit as a charge. The first reconciliation reported 587
against 579 and both figures were correct. The sample's `/ops` page now shows
gross, corrections and net separately, and `Ops.net_quantity/2` carries the
arithmetic with a note about the trap in it.

---

## 5. The account, before and after

Created by this run and removed by its cleanup trap:

| object | what became of it |
|---|---|
| subscription `sub_1UGTxz...` | cancelled by step 16, confirmed by cleanup |
| test clock `clock_1UGTxw...` | **deleted**, with its customers and their subscriptions |
| payment method `pm_1UGTxx...` | detached |
| customer `cus_VH22IP...` | gone with the clock |
| price `price_1UGTxZ...` | **deactivated** (Stripe prices cannot be deleted) |
| product `prod_VH21I5...` | **deactivated** (a product with a price cannot be deleted) |
| meter `mtr_test_61VPrus...` | **deactivated** (Stripe meters cannot be deleted) |
| database `aurora_v1_stripeproof_3651de` | dropped |

Retained because Stripe has no delete for them in test mode, and recorded as
such:

```
pi_3UGTy7...  payment_intents cannot be deleted through the Stripe API in test mode
ch_3UGTy7...  charges cannot be deleted
re_3UGTy7...  refunds cannot be deleted
in_1UGTzt...  invoices cannot be deleted
```

`failed: []`.

**The account audited afterwards**, read back from Stripe
(`tmp/v1/09d/account-state.sh`, read only):

```
meters:        9 created by this unit, all inactive
               (4 other meters on the account are active and predate this unit)
products:     23 with an aurora_v1_run tag, 0 active
prices:       27 with an aurora_v1_run tag, 0 active
test clocks:   0
subscriptions: 3 tagged, 0 not canceled
customers:     0
```

The nine inactive meters, and the products and prices from this unit's nine
runs (eight while the profile was being made to work, one that passed), are the
whole of what this unit added and could not remove. Nothing it created is
active, and nothing it did not create was touched.

---

## 6. Commands

```bash
# the plan, with no API call and no object created
bash scripts/v1/stripe-proof.sh sample --dry-run

# the run, by hand, outside CI, with the key sourced into the shell and
# never passed on a command line
bash tmp/v1/mixlane.sh hold core bash tmp/v1/09d/run-proof.sh
```

`tmp/v1/09d/run-proof.sh` sources `.env.dev`, refuses anything that is not
`sk_test_`, unsets `CI`, and sets `AURORA_STRIPE_PROOF=owner`. It prints no
value of anything.
