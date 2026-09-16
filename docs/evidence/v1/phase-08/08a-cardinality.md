# 08a: cardinality and privacy

Build unit **08a**, V1 task **08.02**. The contract, the run log and the
toolchain are `08a-metrics-contract.md`; this file is the tag rules, where each
bound comes from, and what the tests actually try.

## 1. Why this is not a tidiness rule

A metric tag becomes one time series per distinct value, in the host's reporter
and then in the host's monitoring bill. Tag a metric on `tenant_key` and a
deployment with ten thousand tenants buys ten thousand series for that one
metric; do it on five metrics and the observability cost of the product exceeds
the product. Tag on anything ending `_id` and the multiplier is objects rather
than tenants, which is worse.

The same tag is a privacy defect from the other side. `tenant_key` in a metric
label is customer data leaving the system through the monitoring pipe, to a
destination the host chose for operational telemetry and not for personal data.
`reference` on the ledger events is the caller's idempotency key, and in an
Aurora Meter Pro deployment it carries PaymentIntent identifiers, so it is a
payment identifier under another name.

The library cannot police a handler a host writes, and `docs/telemetry.md` says
so plainly rather than implying a guarantee it cannot give. What it can do, and
what this unit does, is refuse to do it in its own presets and refuse to teach
it by example.

## 2. The allow list, and the bound behind each name

`AuroraMeter.Telemetry.tag_allow_list/0` is `[:result, :kind, :exporter,
:state, :worker]`. It is closed: a name that is not on it is refused whether or
not anybody thought of it.

| Tag | Bounded by | Where that bound is written down |
|---|---|---|
| `:result` | the documented outcome set of the operation | `AuroraMeter.Entitlements` `result_tag/1` (`:ok \| :limit_exceeded \| :not_entitled`); `AuroraMeter.Events`' record outcomes (`:inserted \| :duplicate \| :conflict \| :invalid \| :unavailable \| :unsupported`); the flush span's `span_result/1` (`:ok \| :error`) |
| `:kind` | an enumeration in code | `AuroraMeter.Schema.CreditTransaction.kinds/0` (7 values); `AuroraMeter.Retention.tables/0` (the retention allow list); the cluster batch kinds `:deltas \| :totals`; `:telemetry.span/3`'s exception kinds `:error \| :exit \| :throw` |
| `:state` | a state machine | the lot migration states; Pro's outbox states |
| `:exporter` | the exporter modules a host configures | `AuroraMeter.Pro.Config` `:exporter`, one or two in practice |
| `:worker` | the `AuroraMeter.Oban.*` module list | `AuroraMeter.Oban.cron_entries/1` |
| `:feature` | **the host's own plan definitions**, which is why it is opt-in | `metrics_feature_label: true`, default `false` |

`:feature` is the one name whose bound the library does not control. It is
offered, it is off, and the option's documentation states the cost next to it.

## 3. The denial list

`AuroraMeter.Telemetry.forbidden_tags/0` names 32 keys one by one, and
`forbidden_tag_suffixes/0` refuses any name ending `_key`, `_id`, `_secret`,
`_token` or `_ref` whatever the rest of it is.

A denial list that is only "everything not on the allow list" cannot say **why**,
and a test that tries each name by name is the test that would notice a preset
quietly acquiring one. Both halves are asserted:

- every forbidden name is refused, one at a time, in its own iteration, so the
  failure message names the key that was accepted;
- every allow-listed name is **accepted**, so the checker is not simply refusing
  everything, which is X125's shape and the reason the second assertion exists.

Three entries deserve their reason in writing:

- `origin` on `[:aurora_meter, :cluster, :apply]` is a node name. A scheduler
  that gives each pod its own node name rotates them for the life of the
  deployment, so the series count is "every node that has ever existed here".
- `period_start` grows one series per billing period and never stops. It looks
  bounded because a month is bounded; the sequence of months is not.
- `attempts` on Pro's deliver event is a count. A count is a measurement.

## 4. Two keys that look bounded and are not

**`decision` on `[:aurora_meter, :credits, :hold_reconciliation]`** is
documented as `:keep`, `:release`, `{:settle, amount}` or `:none`. That is a
bounded set of *shapes* and an unbounded set of *values*: three atoms and a
tuple carrying micro-USD. A host charting reconciler decisions by tagging on it
gets one series per settlement amount, which on a busy wallet is one per
settlement. Recorded as **X314**.

The preset does not tag on it. It tags on `:kind` and `:result` and maps them
with `:tag_values`, collapsing `{:settle, _}` to `:settle` and `outcome` to
`result`. The test asserts the **mapped value**, not the presence of a mapping
function:

```elixir
tagged = metric.tag_values.(%{decision: {:settle, 123_456_789}, outcome: :settled, ...})
assert tagged == %{kind: :settle, result: :settled}
```

Negative control `c05-hold-decision-tagged-raw` restores the amount into the tag
value and the test fails.

**`table` on `[:aurora_meter, :retention, :prune]`** is bounded by the retention
allow list, and `table` is not an allow-listed tag name. Rather than widen the
allow list, the preset maps it onto `:kind`. The name of a dimension is a
contract with a reporter, and keeping the set of names closed is what lets a
dashboard built on one deployment read the same on another.

## 5. What the cardinality test actually tries

`test/aurora_meter/telemetry/cardinality_test.exs` and Pro's
`telemetry/metrics_test.exs` both express the rule as a function over a list of
metrics, `offenders/2`, and then point it at three things:

1. the shipped preset list, which must produce no offenders;
2. a metric built **for the test** with each forbidden name as its tag, one at a
   time, each of which must produce exactly one offender;
3. a metric with each allow-listed name, which must produce none.

That is the difference between a rule that has been stated and a rule that has
been shown to refuse something. The names tried by name:

- core, by name: `tenant_key`, `reference`, `origin`, `node`, `error`,
  `period_start`;
- core, by suffix: `event_id`, `original_event_id`, `batch_id`, `crossing_id`,
  `item_id`;
- core, never-thought-of: `invented_dimension`, `customer`, `email`, `payload`,
  `dimensions`;
- Pro, by name: `tenant_key`, `reference`, `origin`, `node`, `error`,
  `period_start`, `watermark`, `subject_ref`, `attempts`;
- Pro, by suffix: `item_id`, `payment_intent_id`, `plan_id`, `lease_token`,
  `event_id`.

The `:feature` tag is asserted in both directions in the same test: absent by
default, present with `feature_label: true`, allowed when the label is on and
**refused when it is off**, so the option is wired to the rule and not merely to
the list.

## 6. `redact/2`: the privacy half

`AuroraMeter.Telemetry.redact/2` is the supported way for a host to put event
metadata into a log line or a span attribute. Its test is driven **from the
catalogue** rather than from an invented map: for every event in `events/0`, a
metadata map is built from that event's real keys, redacted, and every surviving
key must be either tag-eligible or on a short named list of safe correlation
keys. A future event that adds a `_key` or an `_id` is covered on the day it is
added rather than when somebody remembers to extend a list.

- `tenant: :drop` (default) removes the tenant key.
- `tenant: :digest` substitutes a stable 16 character SHA-256 prefix, documented
  as **pseudonymous and not anonymous**: it still links one person's activity
  across records, and several regimes treat it as personal data.
- `tenant: :raw` keeps it, spelled out so that carrying an identifier into a
  monitoring pipeline is a decision somebody wrote down.
- `error` becomes `error_class`: the exception module or the outcome tag, never
  the message, which is where a query, a key or a customer's data ends up.

Four negative controls attack it (`c06` to `c08`, and the error case inside
`c07`): keeping the tenant by default, keeping the exception message, and making
the digest unstable.

## 7. The synthetic data rule

Every tenant key in these tests and in this evidence is synthetic
(`org_synthetic`, `gauge_<n>`, `lagprune_<n>`). No file under
`docs/evidence/v1/phase-08/` contains a real tenant key, a Stripe object id, a
customer identifier or a secret, in either package.
