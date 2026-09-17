# 09d: the webhook, against real Stripe

Build unit 09d. The `stripe listen` session from the passing proof run, the
events it forwarded, what the sample's endpoint-mounted plug did with each, and
the grants that resulted.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only.

Rule 4 applies. Nothing here ticks a checkbox and nothing is committed.

Run `stripe-proof-20260917T011750Z-3651de`, 2026-09-17, Stripe CLI 1.43.7,
**test mode only**, `--live` never passed.

---

## 1. The transport

```
stripe listen --skip-update --format JSON \
  --events payment_intent.succeeded,payment_intent.payment_failed,charge.refunded,\
customer.subscription.created,customer.subscription.updated,customer.subscription.deleted \
  --forward-to http://127.0.0.1:4640/webhooks/stripe
```

**The registered webhook endpoint was not read, written or referenced** (finding
X1). Events arrive through the CLI, which creates nothing permanent, and the
harness prints that line into the run log at the moment the forwarder reports
ready.

The forwarder is ready **before** any money-shaped object exists: the run order
is meter, price, host, organisation, forwarder, and only then the subscription
and the payment.

### The signing secret

Obtained with `stripe listen --print-secret`, held in a shell variable, and
registered with the harness's sanitiser. It is **never written to disk**. The
session header in the transcript reads:

```
Ready! You are using Stripe API Version [2024-06-20]. Your webhook signing
secret is <redacted:STRIPE_WHSEC> (^C to quit)
```

A grep of the whole transcript for `whsec_[A-Za-z0-9_-]{8,}` returns **0**.

### The API version is not one version

The CLI reports the **account's** version, `2024-06-20`, and that is the
version every forwarded event body is serialised at. Aurora Meter Pro sends its
own requests at the pinned `2025-11-17.clover`. The two being different is not
hypothetical and it is not a defect: Stripe serialises a webhook event at the
version the endpoint was created with, or the account default when it names
none, and Pro records each event's `api_version` and compares it with
`expected_webhook_api_version/0`. The row it wrote for the refund carries
`api_version: "2024-06-20"`.

Both versions are recorded in `pro-proof/summary.json`, which is the point of
pinning: a proof run next quarter that behaves differently is attributable.

---

## 2. The deliveries

Seven, every one answered **200**:

```
7 [200] POST http://127.0.0.1:4640/webhooks/stripe
```

| type | count |
|---|---|
| `customer.subscription.created` | 1 |
| `customer.subscription.updated` | 1 |
| `customer.subscription.deleted` | 1 |
| `payment_intent.succeeded` | 3 (one original, one redelivered by the harness, one from the invoice's own payment) |
| `charge.refunded` | 1 |

What Pro did with them, counted from the host log:

| | count |
|---|---|
| `AuroraMeter.Pro.Webhook.record` (the event id written before the handler ran) | 7 |
| `AuroraMeter.Pro.Webhook.mark_applied` | 6 |
| `AuroraMeter.Pro.Webhook.applied?` (a redelivery recognised as already applied) | 1 |
| `AuroraMeter.Pro.Subscriptions.apply` | 3 |
| `AuroraMeter.Pro.Credits` card and closure paths | 4 |

Seven recorded, six applied, one recognised as a redelivery of an event that
had already been applied and answered 200 immediately without doing work,
taking no lock and making no Stripe call. That is the row in
`aurora_meter_webhook_events` doing its job.

---

## 3. The outcomes, on the ledger

| step | what Stripe sent | what the ledger did |
|---|---|---|
| 6 | `customer.subscription.created` | the organisation is on `:studio`, `active`, with the subscription's own period; the wait for it is an assertion rather than a sleep |
| 7 | `payment_intent.succeeded`, 2500 cents | **one** grant, 25 000 000 micro-USD, on **one** paid lot |
| 8 | the same event, redelivered with `stripe events resend` | **nothing**: grants stayed at 1 and the whole ledger reading was byte-identical before and after |
| 13 | `charge.refunded`, 1000 cents | **one** reversal, 10 000 000 micro-USD, out of the **paid** lot, `reversed: 10 000 000` |
| 16 | `customer.subscription.deleted` | the subscription row's status follows Stripe |

I14 and I13 against a real provider, at the sample's own mount point, through
the sample's own configuration.

---

## 4. The mount point, and the test that exists because of it

The plug is in `AuroraMeterExampleAiWeb.Endpoint`, **above `Plug.Parsers`**,
not in the router. Pro's documentation shows a router `forward` and says "mount
it where the raw request body is still available"; a Phoenix router is always
after the endpoint's parsers, so the `forward` cannot be the mount point.

Mounted behind the parsers, `read_body/2` answers `{:ok, "", conn}`, the HMAC
is computed over an empty string, and every event fails with a 400 while the
symptom appears at the far end as customers who paid and were never credited.

`test/pro/webhook_test.exs` mounts it the wrong way round and asserts the 400,
after separately asserting that the parser really did consume the body. It also
asserts:

- a correctly signed event through the real mount: 200;
- an unsigned request: 400;
- a signature computed over a different body: 400;
- an event type Pro does not handle: 200, not 500, because a 500 would make
  Stripe retry it for days;
- a handler that cannot apply an event: not 400, so a refusal is never
  mistakable for a signature failure.

## 5. The one thing the forwarder found that a fixture could not

The first run of this profile forwarded `customer.subscription.created` to
`http://127.0.0.1:4640/aurora/webhook`, which is where the harness's own
disposable host mounts the plug, and the sample's router answered **404**. The
event was created, signed, forwarded and lost, and the profile then waited four
minutes for a sync that was never going to happen.

Nothing about that is visible in a fixture test: the path only matters when
something real is delivering to it. `PROOF_WEBHOOK_PATH` is now a variable with
the old value as its default, so the profiles built against the disposable host
are unchanged.
