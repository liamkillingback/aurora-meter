# 07b: scheduled plan transitions, precedence and preview

Build unit **07b**. V1 tasks **07.04** (transition API), **07.05** (commercial
policy), **07.07** (ordering and precedence) and **07.09** (custom periods,
preview and no destructive reset), from `v1-release.md` section 11 and the 07b
row of `docs/v1/build-plans/README.md`.

## 1. What was run, on what

| Fact | Value |
|---|---|
| Date | 2026-09-16, UTC |
| Repository | `aurora_meter` (core), branch `aurorameter-v1`, working tree on top of `1877f86` |
| Aurora Meter Pro | `d8cf7e2`, read only: nothing under `lib/aurora_meter/pro` was touched |
| Storefront | `329d8a0` |
| Core version | 0.5.0 (the unreleased 1.0.0-rc.1 line) |
| Core schema version | **10, unchanged.** This unit adds no DDL |
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), jit, smp 24 |
| `core:mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| `pro:mix.lock` sha256 | `a2140b7e65132ec337fb7e6ac70fbd750b4ade13f1f6b1fb1762d1426bfbac8e` |
| Database | Postgres on `localhost:5490`, `aurora_meter_test`, pool 60 |

## 2. Commands, exit codes, seeds

| Command | Seed | Exit | Result | Log |
|---|---|---|---|---|
| `mix format --check-formatted` (core) | n/a | **0** | no file reformatted | `07b-logs/core-check.log` |
| `mix check` (core), core beams deleted first | random (`mix check` draws one) | **0** | **1808 passed** (73 doctests, 20 properties, 1715 tests), 4 excluded, 249.3 s | `07b-logs/core-check.log` |
| `mix check` (Pro), Pro PLTs and core beams in both trees deleted first (X114) | random | **0** | **987 passed** (66 doctests, 921 tests), 15.2 s | `07b-logs/pro-check.log` |
| headless leg: `mix compile --warnings-as-errors --force` with `AURORA_HEADLESS=1` | n/a | **0** | compiled with no optional dependency | `07b-logs/core-headless.log` |
| headless leg: `mix run -e '...'` (the criterion 10 script) | n/a | **0** | `headless ok` | `07b-logs/core-headless.log` |
| headless leg: `mix test --include headless` | 0 | **0** | **1717 passed** (69 doctests, 20 properties, 1628 tests) | `07b-logs/core-headless.log` |
| fixed-seed property sweep, every core file declaring a property | 0, 1, 7, 42, 1337 | **0** each | 217 passed (42 doctests, **20 properties**, 155 tests) at every seed | `07b-logs/property-seeds.log` |
| negative controls, 16 of them | 0 | see section 6 | 14 of 16 discriminated | `07b-logs/controls/` |
| lag and cache probe | n/a | **0** | section 5 | `07b-logs/lag.log` |

Baseline before this unit: core 1724 passed, Pro 987, headless 1635. Core is
**+84**, Pro unchanged, headless **+82**. The two headless tests short of the
full suite are the Oban-guarded ones in this unit's concurrency file and
elsewhere, which is the point of that leg.

Scripts, all kept: `tmp/v1/07b-core-check.sh`, `07b-pro-check.sh`,
`07b-core-headless.sh`, `07b-property-seeds.sh`, `07b-controls.sh`,
`07b-controls.py`, `07b-lag.exs`, `07b-dashes.sh`, `07b-facts.sh`.

## 3. What was built

`lib/aurora_meter/subscriptions.ex` grew from 78 lines to a documented facade
over five new public functions; the state machine is in
`lib/aurora_meter/subscriptions/transitions.ex` (`@moduledoc false`) and the
dry run in `lib/aurora_meter/subscriptions/preview.ex` (`@moduledoc false`).

### Public API added

| Entry | Notes |
|---|---|
| `AuroraMeter.Subscriptions.schedule_transition/3` | `:ref` required and idempotent per tenant; `:version`, `:effective_at` (default: the end of the tenant's own period), `:replace` (default `true`), `:confirm` (`:local` or `:provider`), `:detail` |
| `AuroraMeter.Subscriptions.cancel_transition/3` | idempotent; an applied transition is a conflict |
| `AuroraMeter.Subscriptions.preview_transition/3` | pure read; `from`, `to`, `changes`, `effective_at`, `period`, `provider` |
| `AuroraMeter.Subscriptions.confirm_transition/3` | the Pro seam; `:provider_ref` required, `:effective_at` wins over the scheduled boundary, idempotent under redelivery |
| `AuroraMeter.Subscriptions.apply_due_transitions/1` | `:limit`, `:after`, `:tenant`, `:now`; one transaction per tenant |
| `AuroraMeter.Billing.Provider.describe_plan_change/3` | optional callback |
| `AuroraMeter.Billing.Provider.update_subscription_plan/3` | optional callback, implemented by 07c |
| `AuroraMeter.Storage.list_subscriptions/2` filters | `:transition_state`, `:transition_confirm`, `:scheduled_before`, `:order` |
| `AuroraMeter.Oban.PlanTransitions` | now returned by `cron_entries/1` at `"*/5 * * * *"` with **no edit to the worker**: its operation is compiled in and `available?/1` started answering true |
| Telemetry `[:aurora_meter, :plans, :transition]` | measurements `%{count}`; metadata `%{tenant_key, ref, from_plan_id, from_version, to_plan_id, to_version, result}` |
| PubSub `{:aurora_meter, :plan_transition, %{tenant_key, ref, state}}` | on `AuroraMeter.Broadcaster.topic/1` |

`AuroraMeter.Storage.put_subscription/1` gains a side effect and is the
compatibility item of this unit: see section 4.

### Documentation

`docs/plans.md` gains the lifecycle, the precedence table, the measured lag and
the "core never prorates" statement; `docs/adr/0016-scheduled-plan-transitions.md`
is new (unpublished on hexdocs until the release that ships phase 07, like 0012);
`docs/api.md` sections 1.9, 1.15, 5, 6, 7 and 11; `docs/correctness.md` I16 and
I17; `docs/operations/scheduler.md`'s worker table; `CHANGELOG.md`.

## 4. The precondition: X288 moved to a database stamp

`AuroraMeter.Entitlements.subscribe_known/3` wrote
`plan_effective_at: DateTime.truncate(Clock.now(), :second)`. 07a named that
rather than half-fixing it because nothing compared the column. **This unit
compares it**, so it was moved first.

The value is now never read into Elixir at all. `subscribe_known/3` passes the
sentinel `plan_effective_at: :db_now`; `AuroraMeter.Storage.Ecto.put_subscription/1`
pops it before the changeset, omits the column from the insert, and sets it in
the same transaction with
`date_trunc('second', clock_timestamp() AT TIME ZONE 'UTC')`. That is X220's
remedy in the only form available without DDL: `Ecto.Repo.insert/2` accepts no
fragment in a value, a column default is DDL this unit does not own, and a
`db_now/0` read written back is the read-then-write form `architecture-map.md`
section 3 explicitly refuses. Cost: one extra statement on a path that writes
one row per tenant plan change.

**What now compares it.** Three things, and all three take the database's clock
on the other side:

1. `schedule_transition/3` refuses an `effective_at` that is not in the future,
   against `AuroraMeter.Clock.db_now/0`, because that instant is about to be
   persisted and every later run compares it against the database's clock.
2. `apply_due_transitions/1` decides "has this boundary arrived" with
   `Clock.db_now/0` against the persisted `scheduled_effective_at`, and the due
   scan filters on the same column.
3. The applier **writes** `plan_effective_at = transition.effective_at`, so the
   column becomes a value the database itself stored and 07c's attribution walk
   reads. A node-stamped value beside a boundary-stamped one is a column whose
   two halves came from two clocks.

Proved by `test X288 subscribe stamps plan_effective_at from the database, not
from this node`, which freezes the node clock to 2022 and asserts the stored
value is within a minute of `clock_timestamp()`. Negative control
`j-node-stamped-effective-at` reverts the line and that test, and only that
test, fails.

`AuroraMeter.Clock`'s P08 audit (`test/aurora_meter/clock_test.exs`) gains
`lib/aurora_meter/subscriptions/transitions.ex` to its `db_now/0` allow list,
with the reason written beside it: two comparisons, both against persisted
instants, a duration of a billing period rather than seconds (so X100's 439 ms
backwards step cannot invert it), and one read per scheduling call and one per
applier run, nowhere near `track/4`.

## 5. Measured numbers

From `tmp/v1/07b-lag.exs`, log `07b-logs/lag.log`. Full detail in
`07b-lag.md`.

| Measurement | Value |
|---|---|
| Cron lag, 12 transitions with boundaries across one interval, interval 5 s | min **1.020 s**, median **3.009 s**, max **4.991 s** |
| One `apply_due_transitions(limit: 500)` over 500 due transitions | **1816 ms**, 3.632 ms per transition |
| Cache staleness after a write with no invalidation, default TTL 5,000 ms | **5008 ms** |
| Cache staleness after `kill -9` between commit and invalidation (the acceptance criterion) | **5000 ms** from the warming read, **4995 ms** from the kill, against a 5,000 ms TTL |
| Row-lock waiters observed during the twelve-way apply | **12 of 12** |

## 6. Negative controls

Sixteen, each breaking exactly one thing in `lib/` and running the four test
files this unit adds. Full table in `07b-concurrency.md` section 4; the summary
is `07b-logs/controls/summary.txt`.

**Fourteen discriminated. Two passed, and both produced a finding** (X295 and
X297). Two more findings came out of the harness itself:

- Five controls initially reported "discriminated" on an exit code that was a
  **compile failure**, because `mix test` here compiles with
  `--warnings-as-errors` and orphaning a private function is an error, and
  because Elixir's type checker refuses an always-false clause in a `cond`.
  A control that does not run is not a control (**X300**).
- One control's patch did not apply at all (two matches where one was expected).
  The tree stayed intact, the suite stayed green, and the harness reported
  exactly what a non-discriminating control reports (**X300** again). The
  harness now treats a failed apply as a harness error and says so.

## 7. G07 coverage, per bullet

| G07 bullet | This unit's part | Owner of the rest |
|---|---|---|
| 1. Deploying Pro plan v2 leaves a tenant on v1 with unchanged limits, period, credit recurrence and Stripe price | `test I17 an explicit scheduled migration is the only thing that moves a tenant's version` proves the local half twice over: deploying version 2 moves nobody, and a transition is the only thing that does | the Stripe price half is 07c's |
| 2. New subscriptions select the intended effective version; future-dated versions are not active early | 07a proved it for `subscribe/3`; this unit proves the same rule for a transition's default `:version`, which resolves at the **effective time** and refuses a version not yet effective then | complete between 07a and 07b |
| 3. Duplicate schedules, worker retry and two nodes apply one transition. Crash between provider update and local commit converges through reconciliation | twelve schedules of one ref produce one row; twelve appliers produce one applied and eleven skips; two Oban jobs produce one applied; three kills. The core half of the crash case: a `confirm: :provider` transition stays `pending` and visible until `confirm_transition/3` records the provider's reference, and that call is idempotent under redelivery | the provider half (calling `update_subscription_plan/3`, then reconciling) is **07c's** |
| 4. Stale webhooks do not resurrect cancelled plans or override a newer transition. Zero-price transitions and cancellation at period end are covered | the whole provider precedence table core can observe, plus `test I17 a stale sync for an ended subscription cannot revive a cancelled transition`, plus the zero-price pair (a source scan and a statement-identity comparison) | the advance-notice half of cancellation at period end (`cancel_at_period_end`) is **07c's**, as the precedence table in `docs/plans.md` says |
| 5. Mid-period historical usage stays on its original plan or price mapping | contributor only: `test I17 usage recorded before the boundary stays in its period after the transition applies`, and `test I17 applying a transition deletes no counter, history, event, transaction or lot row` | attribution is **07c's** |
| 6. Generated migration upgrades old subscriptions without silently migrating their commercial contract | none: **07a's**, and this unit adds no DDL | 07a |

## 8. Open defects and findings raised

X295 to X301 in `docs/v1/build-plans/open-findings.md`. In short:

- **X295**: the applier's conditional predicate and its row lock are each
  redundant given the other, and the suite can only see the pair.
- **X296**: a provider write naming `plan_id` without `plan_version` can never
  equal a versioned scheduled target, so the early-apply branch is unreachable
  from Pro until 07c sends the pair. Behaviour pinned by a test.
- **X297**: `mark_applied/1`'s predicate cannot be reached with a non-pending
  row and cannot be tested from outside. Recorded, not removed.
- **X298**: the due scan's cursor is not a correctness property; the scan
  advances by doing the work. A read-only scan test was added so the cursor is
  proved by something.
- **X299**: the fleet-wide `plan_version IS NULL` guard the build document
  specifies was narrowed to the tenant's own row. Deviation, with reasons.
- **X300**: two ways a negative control can silently not run.
- **X301**: the build document's claim that this unit adds the first
  `@optional_callbacks` in either package is wrong; `AuroraMeter.Period` has
  had one since 0.5.0.

## 9. Handoff for 07c

**`confirm_transition/3`, exactly:**

```elixir
@spec confirm_transition(term(), String.t(), keyword()) ::
        {:ok, AuroraMeter.Schema.PlanTransition.t()}
        | {:error, {:invalid | :conflict | :not_found, term()}}

AuroraMeter.Subscriptions.confirm_transition(tenant, ref,
  provider_ref: "sub_123",          # required binary, non-empty
  effective_at: ~U[...],            # optional; the provider's own boundary wins
  detail: %{},                      # optional; merged into the audit row
  now: ~U[...]                      # optional; defaults to Clock.db_now/0
)
```

It records the reference, takes the provider's boundary over the scheduled one
(keeping the replaced instant in `detail.provider_effective_at_changed`), and
applies the transition in the same transaction when that boundary has passed.
Redelivery with the same `provider_ref` returns the row unchanged; a different
one on an applied transition is `{:error, {:conflict, %{provider_ref: stored}}}`.

**Finding the work.** `transition_confirm` holds `"local"` or `"provider"`.
Pro's applier finds what it owns with

```elixir
AuroraMeter.Storage.list_subscriptions(cursor,
  limit: 500,
  transition_state: "pending",
  transition_confirm: "provider",
  scheduled_before: AuroraMeter.Clock.db_now(),
  order: :scheduled_effective_at
)
```

The cursor for that order is opaque and encodes
`(scheduled_effective_at, tenant_key)`; pass back what the previous page
returned and stop at `nil`.

**Precedence rows 07c must implement on the Pro side**, from
`docs/plans.md`:

1. A cancellation known in advance (`cancel_at_period_end = true`) with a
   transition effective at or after `current_period_end`: call
   `cancel_transition/2` with `detail: %{reason: "cancel_at_period_end"}` when
   the flag is observed, so a customer is not shown a change that will never
   happen. Core cannot see that flag and will not gain a column for it.
2. **Send `plan_version` alongside `plan_id` on every sync** (finding X296).
   The early-apply branch compares the pair; a sync that names only the plan id
   is treated as an override and cancels the transition, which is safe and is
   not what a confirmed upgrade should do.
3. `update_subscription_plan/3` is declared optional here and implemented
   there: provider first, local second, with the transition visible as
   `pending` in between.
4. `describe_plan_change/3` on `AuroraMeter.Pro.Stripe`, returning the price id,
   the interval and the proration behaviour as an opaque map. Core never reads
   inside it.

**What core will not do.** No Stripe price, mode, account or proration concept
enters core. `preview_transition/3` reports each plan's declared list price and
nothing else; there is no proration arithmetic anywhere in V1 (decision D05,
task 07.05).
