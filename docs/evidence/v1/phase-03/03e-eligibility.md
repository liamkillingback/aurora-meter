# 03e: the three eligibility outcomes core can produce for a correction

I09's provider clause is "never treat provider-ineligible corrections as
silently settled externally". Core's half of that is narrow and worth stating
exactly: **core never decides whether a correction can reach a provider, and
core never drops one.** Every correction is handed to the configured
`AuroraMeter.Events.Outbox` inside the transaction that commits it, with a
reason attached when core can already tell delivery is impossible.

Implementation: `AuroraMeter.Storage.Ecto`'s `correction_eligibility/1`.

## The three outcomes

| Outcome | Condition core can see | Outbox item | Test |
|---|---|---|---|
| `:eligible` | the corrected feature reports from events, and the original's `attribution` is not `unresolved` | staged, eligible | `AuroraMeter.CorrectTest` / `test eligibility a correction of an events-source feature's event is staged as eligible` |
| `{:ineligible, :feature_buffered}` | `Config.feature_source(feature) == :buffered`: the usage itself never went through the outbox, so neither can its correction | staged, with the reason | `AuroraMeter.CorrectTest` / `test eligibility a correction of a buffered feature's event is stored and marked ineligible` |
| `{:ineligible, :original_ineligible}` | the correction's `attribution` is `:unresolved`, which it inherited from the original: the period source could not place the original's `occurred_at` | staged, with the reason | `AuroraMeter.CorrectTest` / `test eligibility a correction of an unattributed original is marked ineligible original_ineligible` |

`:original_ineligible` rather than `:attribution_unresolved` (which is what a
usage event gets) because the two rows are different rows: on a correction the
unresolved attribution is the **original's** problem, and an operator reading a
quarantined item needs to be told which of the two to fix. `07c` resolves the
attribution; the correction is then re-derivable.

## What is asserted in each case

In all three the correction is **stored**: the row exists, the totals delta is
applied, `AuroraMeter.Events.total/3` reflects it, and the outbox item exists.
Ineligibility is a label on a committed fact, never a refusal to record one.
The buffered case asserts both halves explicitly:

```elixir
assert %{eligibility: {:ineligible, :feature_buffered}} = List.last(items)
assert length(rows(ctx.tenant)) == 2
assert Events.total(ctx.tenant, :ai_generations, ctx.period) == 7
```

A **duplicate** correction stages nothing a second time
(`AuroraMeter.CorrectTest` / `test eligibility a duplicate correction stages no
second intent`), and an outbox that refuses rolls the correction back entirely
(`test eligibility an outbox that refuses rolls the correction back`): a fact
whose export intent could not be staged must not commit without one.

## What is deliberately not core's

Whether the original was ever accepted by the provider, whether the meter event
is still inside Stripe's cancellation window, and whether the invoice has
finalised. All three are Aurora Meter Pro's, at enqueue time and at delivery
time (`architecture-map.md` 5.6). Pro's contract, which 04d must meet:

- correction items arrive with `subject_kind = "correction"` and `subject_ref`
  equal to the correction's `event_id`; the payload carries the original's
  `event_id` so the exporter can find the meter event to cancel;
- a correction whose original is outside the adjustment window becomes
  `quarantined` with `provider_window_closed` plus a `manual_adjustment`
  reconciliation item, never `accepted` and never dropped;
- Pro never fabricates a negative meter event.

No Pro `lib/` file changed in this unit. One Pro test-support file did:
`AuroraMeter.Pro.Test.FaultStorage` gained `record_correction/2`, because the
`AuroraMeter.Storage` behaviour grew a required callback and Pro compiles with
`warnings_as_errors` (`open-findings.md` X115, which predicted exactly this).
