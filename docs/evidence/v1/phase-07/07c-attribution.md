# 07c: occurrence-plan attribution

Build unit 07c, V1 task **07.08**, gate **G07 bullet 5**. Core `03f2008`, core
schema **10**.

A recorded event carries the `{plan_id, plan_version}` in force when the usage
**occurred**, resolved once by `AuroraMeter.Plans.effective_for/2` at record time
and never recomputed. Neither a plan redeploy nor a plan change can reprice a
fact that is already recorded (decision D05, L17.12).

## The four outcomes

| Outcome | `plan_id` | `plan_version` | `attribution` | Export intent |
|---|---|---|---|---|
| resolved from the current assignment | the pair | the pair | `"resolved"` | `:eligible` |
| resolved from applied transition history | the historical pair | the historical pair | `"resolved"` | `:eligible` |
| no assignment covers the instant | NULL | NULL | `"plan_unresolved"` | `{:ineligible, :plan_unresolved}` |
| the tenant has no subscription at all | NULL | NULL | `"plan_unresolved"` | `{:ineligible, :plan_unresolved}` |

A fifth, unchanged from 03b: a period the source could not place at all is
`"unresolved"` and `{:ineligible, :attribution_unresolved}`, and the plan is not
even asked for. A period this code had to guess is not an instant worth
resolving a contract against, and that ordering is asserted by
`test I17 an unresolved period is not asked for a plan at all`.

### The value, and the deviation from criterion 7

Criterion 7 says the row is stored with `attribution = 'unresolved'`. It is
stored with **`"plan_unresolved"`**, and finding **X306** records why:
`"unresolved"` already means "the period source could not place `occurred_at`",
and reusing it for a plan failure would say that of a row whose period is a
fact. Making the value coarse would also have flipped **every** event of a tenant
with no subscription from `resolved` to `unresolved`, which is every event a free
core installation records.

The criterion's other two halves are met exactly: the outbox item is quarantined
with reason **`plan_unresolved`**, and no export carries a plan attribution for
it. **A reviewer should read criterion 7 against `plan_unresolved`.**

## The rows, as stored

Read back out of `aurora_meter_events` by
`AuroraMeter.PlanAttributionTest`'s `stored/2`, which selects the three columns
directly rather than through the `%AuroraMeter.Event{}` struct, so the
assertion is about the database and not about the decoder.

**Resolved from the current assignment**, tenant on `:pro` version 1 since 2020,
event now:

```
%{plan_id: "pro", plan_version: "1", attribution: "resolved"}
```

**Resolved from history.** Tenant on `:scale` version 1 since 2026-06-01, with
one applied transition from `{:pro, "1"}` effective 2026-06-01. An event dated
2026-05-20:

```
%{plan_id: "pro", plan_version: "1", attribution: "resolved"}
```

**Unresolvable: before recorded history.** Tenant subscribed to `:pro` now, no
transitions, event dated an hour ago:

```
%{plan_id: nil, plan_version: nil, attribution: "plan_unresolved"}
```

and the staged item: `[%{eligibility: {:ineligible, :plan_unresolved}}]`.

**Unresolvable: no subscription.** Same stamp, same eligibility.

## `effective_for/2`, rule by rule

| Rule | Behaviour | Test |
|---|---|---|
| no subscription row | `{:error, :unresolved}` | `test I17 effective_for is unresolved for a tenant with no subscription` |
| `plan_version` still NULL | `{:error, :unresolved}` | `test I17 effective_for is unresolved while the row still has no plan_version` |
| instant at or after `plan_effective_at` | the row's own pair, **zero queries** | `test I17 effective_for answers the current assignment for an instant inside it` |
| instant before it: latest applied transition at or before the instant | its `to` pair | `test I17 effective_for resolves a backdated instant through an applied transition's to side` |
| failing that: earliest applied transition after the instant | its `from` pair | `test I17 effective_for resolves an instant before the first applied transition from its from side` |
| nothing covers it | `{:error, :unresolved}` | `test I17 effective_for is unresolved for an instant before an assignment with no history` |
| a cancelled or pending transition | ignored entirely | `test I17 effective_for ignores a cancelled or pending transition and reads only applied ones` |

### Cost

Counted, not asserted by inspection.
`test I17 effective_for costs no query at all for an instant inside the current
assignment` attaches a handler to the repo's own `[:aurora_meter, :test_repo,
:query]` event, filtered to the test's own process, and counts:

| Case | Queries |
|---|---|
| instant inside the current assignment, cache warm | **0** |
| backdated instant, no history at all | 2 (the at-or-before read, then the after read) |
| backdated instant with history | 1 |

Two indexed single-row reads is the ceiling, and only a backdated instant pays
either.

## A correction inherits its original's stamp (I09)

`correct/4` copies `plan_id`, `plan_version` and `attribution` from the original
inside the transaction that reads it under lock; it does not resolve them again.
`test I09 a correction copies the original's plan_id, plan_version and
attribution` moves the tenant to `:scale` **between** the fact and its
correction, and the correction still carries `"pro"`.

A correction whose original could not be attributed is staged
`{:ineligible, :original_ineligible}` rather than `:plan_unresolved`, so an
operator is told which of the two rows is the problem.

Negative control **C4** makes `correction_entry/3` write `nil` instead of
copying. One test fails.

## The stamp is not part of `payload_hash`, and the build document says it should be

Finding **X302**. Two reasons, and the second is the one that matters.

The encoding is **immutable**: ADR 0009 fixes the tuple and
`AuroraMeter.Events.Canonical`'s own moduledoc says `encode/1` cannot be changed
without invalidating every `payload_hash` in every database that has run the V7
backfill.

And the hash separates *a retry of the same fact* from *a different fact reusing
the identity*, which is about what the **caller sent**. Attribution is derived.
Putting it in the hash would make an ordinary retry that straddles a plan change
hash differently, and the caller would be told their idempotent retry was an I07
**conflict**.

`test I06 a retry of one event_id across a plan change is a duplicate and keeps
the first stamp` pins the opposite: a plan change between two identical
`record/4` calls, and the second answers `:duplicate` carrying the **first**
stamp. The property the build document wanted is still there and comes from
somewhere better: the stamp is written once, at record time, so two records of
one `event_id` cannot disagree about it.

## Crossing usage: a fact recorded before a transition, exported after it

`test I17 usage recorded before a transition keeps the old version after the
transition applies`, end to end through the real scheduler so the columns 07b
writes are the ones read:

1. tenant on `:pro` version 1 since 2020;
2. a transition to `:scale` is scheduled at a boundary two seconds out;
3. an event is recorded with `occurred_at` ten minutes ago: stamped `pro`/`1`;
4. `apply_due_transitions/1` applies it; the subscription is now `scale`;
5. the recorded row is re-read from the database: **still `pro`/`1`**;
6. a new event dated after the boundary is stamped `scale`/`1`;
7. `effective_for/2` for the pre-boundary instant now resolves through the
   applied transition's `from` side and answers `{:pro, "1"}` again.

And the redeploy case: `test I17 a plan definition redeployed under a tenant
does not change a recorded stamp` swaps in a plans module where version 2 of the
tenant's plan is already effective. `Plans.get(:versioned).version` is `"2"`, the
stored row still says `"1"`, and `effective_for/2` still answers `{:versioned,
"1"}`.

## Recurring grants

`AuroraMeter.Credits.Recurrences` resolves each period's version from
`effective_for(tenant, period.start)` and uses **that version's policy**, so a
catch-up across an upgrade grants each period at its own contract.

| Claim | Test |
|---|---|
| a grant uses the version effective for the period | `test I18 a recurring grant uses the plan version effective for the period` |
| a tenant pinned to version 2 gets version 2's amount and key | `test I18 a tenant pinned to version 2 is granted version 2's allowance and key` |
| a key written before this unit is not granted a second time | `test I18 a recurrence key written before this unit is not granted a second time` |
| a transition at a period boundary produces one grant per period, at each period's own version | `test I18 a transition at a period boundary produces one grant for each period at its own version` |
| a catch-up period before an upgrade is granted at that period's version | `test I18 a catch-up period before an upgrade is granted at the version that period was sold under` |
| a version 2 that drops the allowance does not stop a version 1 tenant being paid | `test I18 a version 2 that drops the allowance does not stop a version 1 tenant being paid` |

Compatibility with the keys 06d already wrote needs no special rule and gets
none: 06d wrote the literal `"1"`, a tenant on version 1 resolves to `"1"`, so
the key is byte for byte the same string. And "already granted" is decided by the
**period** (`last_recurrence/2` plus `periods/4`), not by the key; the `UNIQUE
(tenant_key, key)` index is the racing-schedulers guard underneath it.

## Two nodes

`pro:docs/evidence/v1/phase-07/07c-multinode.md`, claim 4: a transition applied
on node A, and node B then resolves both sides of the boundary and records
events stamped correctly, through history node B never wrote.
