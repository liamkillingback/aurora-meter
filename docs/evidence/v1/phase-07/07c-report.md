# 07c: the core half

Build unit **07c**, V1 tasks **07.06** and **07.08**. The Pro half, and the
unit's full report, are `pro:docs/evidence/v1/phase-07/07c-report.md`; this file
is what changed in the core package and why.

## 1. Facts

| | |
|---|---|
| Core SHA at hand-back | `03f200843c64a2c76ceea40397fc6b58e74c9b04` (`03f2008`, `v0.4.0-31-g03f2008`, branch `aurorameter-v1`), **dirty**, uncommitted by instruction |
| Pro SHA | `d8cf7e2d313fbb2897aed27335086ac15536a8f9` |
| Version / schema | 0.5.0 unchanged / **10 unchanged**. **No core DDL** |
| `mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6`, unchanged |
| Elixir / OTP / ERTS | 1.20.1 / 29 / 17.0.1 |
| PostgreSQL | 16.13, port 5490 |
| `mix check` | **exit 0**, 1832 passed (73 doctests, 20 properties, 1739 tests), 4 excluded |
| headless leg | **exit 0**, 1740 passed |
| property sweep, seeds 0 / 1 / 7 / 42 / 1337 | **exit 0** at every seed, 217 passed (20 properties) each |

Baseline before this unit: 1808 and 1717.

## 2. What changed

| File | What |
|---|---|
| `lib/aurora_meter/plans.ex` | `effective_for/2`: the `{plan_id, version}` a tenant was on at an instant |
| `lib/aurora_meter/events.ex` | the plan stamp on the `record` path, and the rule that an unresolved **period** is not asked for a plan |
| `lib/aurora_meter/event.ex` | the `attribution` vocabulary gains `:plan_unresolved`, with the whole vocabulary rewritten to say what each value grades |
| `lib/aurora_meter/events/outbox.ex` | the `ineligibility/0` type gains `:plan_unresolved`, documented in the behaviour |
| `lib/aurora_meter/storage/ecto.ex` | eligibility maps `:plan_unresolved` to its own reason, and a correction carrying it is named `:original_ineligible` so the operator is told which row is the problem |
| `lib/aurora_meter/credits/recurrences.ex` | the tenant's own version rather than the version effective now (X307), and each period's own version and policy |
| `lib/aurora_meter/subscriptions/transitions.ex` | the three specs corrected to `t:result/0` (X304). **No behaviour change**, and 07b's state machine is untouched |
| `lib/aurora_meter/test.ex` | `subscribe_since!/4`, so a test whose usage is dated in the past can have the assignment a real host would |
| `test/support/test_plans.ex` | `AuroraMeter.Test.AllowanceDroppedPlans`, for negative control C7 |

New tests: `test/aurora_meter/plan_attribution_test.exs` (17) and
`test/aurora_meter/credits_recurrences_versions_test.exs` (7). Six existing test
files were updated; `plan_transition_precedence_test.exs`'s X296 test was
rewritten (below).

Documentation: `docs/plans.md`, `docs/credits.md`, `docs/api.md`,
`docs/correctness.md`, `CHANGELOG.md`.

## 3. The behaviour change a host will notice

`attribution` now grades the **plan** as well as the period. An event recorded
for a tenant with no subscription row, or dated before that tenant's assignment
started with no applied transition covering it, is stored with both plan columns
NULL and `attribution: "plan_unresolved"`, and its export intent is staged
`{:ineligible, :plan_unresolved}` rather than eligible.

**Core ships no delivery**, so a core-only installation sees no change: the
default `AuroraMeter.Events.Outbox.Noop` ignores every item and eligibility with
it. In Aurora Meter Pro the same items were already quarantined as
`:no_customer`, because a tenant with no subscription has no
`provider_customer_id` either, so the visible change is a more accurate reason
rather than a new quarantine.

The window that is genuinely new: a subscription **with** a customer whose
`plan_version` is still NULL, which is the gap between core schema version 10
and the first `AuroraMeter.Plans.register!/0`. Events recorded in it are
quarantined. Registration runs at boot, so the window is boot-length, and it is
the same window `schedule_transition/3` already refuses to act in.

Both are release-noted in `CHANGELOG.md` under Changed.

## 4. X296's test, and what happened to it

07b pinned this, and its comment said *07c sends the pair, which is what makes
the early-apply branch reachable from Pro*:

```
test "I17 a provider sync naming the plan id without the version cancels rather than applies"
```

**The core behaviour it asserts has not changed and is still right.** Strict pair
equality stays the default: a provider that names a plan id without naming a
version has said nothing about which contract it means, and inventing one on its
behalf would move a tenant onto a version nobody asked for.

What changed is its **premise**. When 07b wrote it, that was the shape Aurora
Meter Pro produced, so the early-apply branch above it was unreachable from Pro
and every Stripe-confirmed upgrade to exactly the scheduled target was cancelled.
07c makes `plan_for_price/1` answer the pair and `sync/1` write both columns, so
the shape below is now a **third-party** `AuroraMeter.Billing.Provider` that has
not adopted plan versions, and nothing this programme ships.

The test was **renamed and re-commented, not deleted**:

```
test "X296 a provider naming the plan id without the version cancels, and Aurora Meter Pro no longer produces that shape"
```

Its assertions are unchanged (`state == "cancelled"`, `reason ==
"provider_override"`, `observed == %{"plan_id" => "versioned", "plan_version" =>
"1"}`), and the comment says in full what changed and why, the way 06a's
comment does for X213's reproduction. Its entry in `docs/correctness.md` was
renamed with it.

The half core cannot make is asserted in Pro:
`AuroraMeter.Pro.PlanRefTest` / `test I17 X296 sync writes the plan id AND the
version, so a confirmed upgrade applies early instead of cancelling`, with a
negative control (C9) that strips the version and fails twelve of that file's
twenty-six tests.

One correction to X296's own wording, worth recording: a version-less sync that
does not also change the **plan id** leaves the transition **pending** rather
than cancelling it, because core's S4 rule keeps a column the caller omitted and
the written pair then equals the previous one. The cancelling shape X296
describes is what a version-less sync produces when the plan id changes too.
Either way the customer's confirmed upgrade never applies, and sending the pair
fixes both. `test I17 X296 the same sync without the version leaves the
transition pending for ever` pins it.

## 5. The attribution evidence

`07c-attribution.md`, in this directory: the four outcomes as stored, the
resolution rules with the test for each, the counted query cost, I09's
correction inheritance, the crossing-usage scenario end to end, the redeploy
case, the recurring-grant rules, and finding **X302** (why the stamp is not part
of `payload_hash`, and the test that pins the opposite).

## 6. What this unit did NOT touch in core

- the transition state machine, the preview and the precedence engine (07b's).
  The only edit in `subscriptions/transitions.ex` is three `@spec` lines;
- the plan registry, the DSL, the snapshot fallback and the legacy backfill
  (07a's);
- the outbox's states and its retry taxonomy (04b's). One value is added to
  core's **eligibility** vocabulary, which is the seam's, not the taxonomy's;
- the ETS hot path, the credit ledger's allocator, and core migration versions 1
  to 10;
- `.github/workflows/ci.yml` (X188).
