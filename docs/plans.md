# Plans

Plans are declared with a compile-time DSL and validated when your module
compiles (duplicate features, invalid modes, and negative numbers all raise).

```elixir
defmodule MyApp.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0                                   # minor units (cents) / month
    limit :ai_generations, 50, :hard          # hard cap: blocks at 50
    feature :api_access, false                # feature off
  end

  plan :pro do
    price 2_000                               # $20.00 / month
    limit :ai_generations, 1_000, :hard
    feature :api_access, true
    feature :seats, 5                         # a plan value, read with feature_value/3
  end

  plan :scale do
    price 2_000
    metered :ai_generations, included: 1_000, unit_price: 2  # allow overage, ~$0.02 each
    feature :api_access, true
  end

  plan :payg do
    price 0
    counter :requests                         # measured; never blocked, never billed
    feature :api_access, true
  end
end
```

## Feature kinds

- `limit :f, n, :hard` — a hard cap. `check/2` blocks at `n`.
- `metered :f, included: i, unit_price: p` — allow overage beyond `i`; Pro bills
  it. `included`/`unit_price` are for local estimates and display — Stripe is the
  billing source of truth.
- `counter :f` — measured, never blocked, never billed. `check/2` is always
  `:ok`, `remaining/2` is `:unlimited`, and `quota/2` reports
  `kind: :counter` with `limit`, `included` and `percent` all `nil`. Reach for
  it when the money lives somewhere else — a prepaid credit ledger, an invoice
  built outside Aurora Meter — and the plan only wants a number on the
  dashboard.
- `feature :f, boolean` — plain on/off access (no quota).
- `feature :f, n` (non-negative integer) — a value the plan carries for your
  code to read (seats, projects, retention days). Always entitled, never
  counted; `AuroraMeter.feature_value(tenant, :f, default)` returns `n`, and
  `quota/2` reports `kind: :feature, value: n`.

## Lookups

```elixir
AuroraMeter.Plans.all()                              # %{id => %AuroraMeter.Plan{}}
AuroraMeter.Plans.get(:pro)                           # %AuroraMeter.Plan{}
AuroraMeter.Plans.feature_config(:free, :ai_generations)  # {:limit, 50, :hard}
AuroraMeter.Plans.feature_config(:payg, :requests)        # {:counter}
AuroraMeter.Plans.feature_value(:pro, :seats)             # 5
AuroraMeter.Plans.feature_value(:free, :seats, 1)         # 1 (default when undeclared)
```

Point config at your module: `config :aurora_meter, plans: MyApp.Plans`. Add the
DSL to your formatter's `import_deps` for paren-free definitions:

```elixir
# .formatter.exs
[import_deps: [:aurora_meter]]
```

## Counter or metered?

They look similar — both count without blocking — but they say different things
to your customer, and the dashboard repeats whichever one you picked.

| | `metered :f, included: i, unit_price: p` | `counter :f` |
|---|---|---|
| Blocks? | no | no |
| Denominator | `included` | none |
| `quota/2` `percent` | `used / included` | `nil` |
| `quota/2` `overage` | `max(0, used - included)` | always `0` |
| Reads as | "1,200 of 1,000 · 200 over the included allowance" | "1,200 this period" |
| Bill it how? | subscription overage, at period end | it is already paid for |

If a request is paid for out of a prepaid balance the moment it runs, it has no
allowance and no overage: it is a counter. Writing it as
`metered(included: 0, unit_price: 0)` makes every single request read as
overage against an allowance of zero. See
[ADR 0006](adr/0006-counter-feature-kind.md), and chart the money itself with
[`AuroraMeter.Credits.spend_history/2`](credits.md#money-series).

## Recurring credit allowances

A plan can grant credit on a schedule: a monthly allowance, a weekly top-up, a
trial's starting balance. It is off unless the plan says otherwise.

```elixir
plan :pro do
  price 4_900
  metered :tokens, included: 1_000_000, unit_price: 1

  recurring_credits :monthly_allowance,
    amount: 5_000_000,        # micro-dollars, required, a positive integer
    category: :promotional,   # the default
    rollover: 1_000_000,      # micro-dollars carried into one following period
    expires: :period_end      # the default
end
```

Nothing happens until something calls the engine. With Oban, that is
`AuroraMeter.Oban.RecurringGrants` on the schedule
`AuroraMeter.Oban.cron_entries/0` returns; with any other scheduler, or none, it
is `AuroraMeter.Credits.Recurrences.run/1`. See
[Recurring allowances](credits.md#recurring-allowances) for what a run does and
[the scheduler map](operations/scheduler.md) for how to wire it.

### The options

| Option | Default | What it means |
|---|---|---|
| `:amount` | required | Micro-dollars granted per period. A positive **integer**; a float is a compile error, because money is an integer everywhere in this package. |
| `:category` | `:promotional` | `:promotional`, `:paid` or `:adjustment`, the lot categories. Promotional is spent before paid. |
| `:rollover` | `0` | At most this many micro-dollars of one period's **unused** allowance are carried into the next period, as a lot of their own. `0` is no rollover. |
| `:expires` | `:period_end` | `:period_end`, `:never`, or `{:seconds, n}` from the grant. |

### Three combinations that do not compile

They are refused at compile time, with the plan and the entitlement named,
because each one is arithmetic that cannot be honoured rather than a preference:

* **`rollover` above zero with anything but `expires: :period_end`.** A rollover
  is defined as what the previous period's lot did not spend *before it
  expired*. A lot that outlives the period boundary would be carried into the
  new period and still be spendable in the old one, and the tenant would hold
  the same micro-dollar twice.
* **An expiry on a non-promotional allowance.** Only promotional grants expire;
  `AuroraMeter.Schema.CreditTransaction` refuses an `expires_at` on any other
  category. A paid recurring top-up is money the customer keeps, so it takes
  `expires: :never`.
* **A name or a plan id that is not lower snake case.** Both become part of the
  recurrence key (`"recurring:<name>:<plan>:<version>:<period start>"`), which is
  read back by splitting on `:`, so neither may contain one.

`expires: :never` on a promotional allowance compiles and warns: every period's
grant stays spendable for ever and the tenant accumulates them, which is almost
always a mistake.

### Reading it back

```elixir
AuroraMeter.Plans.get(:pro).recurring_credits
#=> [%{name: :monthly_allowance, amount: 5_000_000, category: :promotional,
#      rollover: 1_000_000, expires: :period_end}]

AuroraMeter.Plans.get(:free).recurring_credits
#=> []
```

It is a list rather than a map, in declaration order, and a plan may declare
more than one allowance as long as the names differ. It is deliberately **not**
a feature kind: `t:AuroraMeter.Plan.feature_config/0` and everything that reads it
are untouched by this, so adding an allowance to a plan cannot change what
`check/2`, `quota/2` or `remaining/2` say about anything.

## Versions

A plan is identified by an id **and a version**. A block that names no version
is version `"1"`, so a plans module written before Aurora Meter 1.0 is unchanged
and every tenant on it is on version `"1"`.

```elixir
plan :pro do                                   # version "1"
  price 2_000
  limit :ai_generations, 1_000, :hard
end

plan :pro, version: "2", effective_at: ~U[2026-10-01 00:00:00Z] do
  price 3_000
  limit :ai_generations, 2_000, :hard
end
```

`:effective_at` is the UTC instant from which a **new** subscription gets that
version. Exactly one version of each plan id must omit it: that one is the
plan's base version, the contract in force before any other version was written,
and it is what a subscription created before versions existed is assigned to.

Two versions of one plan may not share an effective instant, and a version label
is 1 to 32 characters of `A-Za-z0-9._-`. Both are compile-time errors.

### What resolves to what

```elixir
AuroraMeter.Plans.get(:pro)          # the version effective right now
AuroraMeter.Plans.get(:pro, "1")     # that version, whatever the clock says
AuroraMeter.Plans.base(:pro)         # the version with no effective instant
AuroraMeter.Plans.versions(:pro)     # every version, oldest first
AuroraMeter.Plans.all()              # %{id => the effective version of that id}

AuroraMeter.subscribe(org, :pro)                 # the effective version
AuroraMeter.subscribe(org, :pro, version: "1")   # that version, pinned
AuroraMeter.plan(org)                            # the version the tenant is on
```

`AuroraMeter.plan/1` resolves the version **the subscription names**, not the
plan id's current definition. That is the whole point: deploying version 2 does
not move a tenant who bought version 1, and it is why there is no way to reprice
somebody by editing code.

Pinning a version that is not yet effective is allowed. An explicit opt-in is
not the same thing as a future-dated version becoming active early, because the
caller asked for it by name.

### Editing a version is refused

`AuroraMeter.Plans.register!/0` runs from `AuroraMeter.start_link/1`. It stores a
snapshot of each compiled version in `aurora_meter_plan_versions` and compares
the fingerprint of every version it has seen before. Changing the price, a
limit, a metered included count or unit price, a feature value or a recurring
credit **inside an existing version** is
`AuroraMeter.PlanVersionConflictError`, naming the plan, the version, both
fingerprints and the remedy.

```elixir
config :aurora_meter, plan_version_conflict: :raise   # the 1.0 default
config :aurora_meter, plan_version_conflict: :warn    # the 0.5.x default
```

`:warn` logs the same message and continues. Neither setting reprices anybody: a
tenant stays on the stored definition either way.

Changing a version's `:effective_at` is **not** a conflict. It says when the
version starts applying to new subscriptions, and a tenant already pinned to one
is not moved by it. It is also what makes retiring a version possible at all:
deleting the base version's block forces the version left behind to drop its own
instant, and a fingerprint that covered the instant would turn every such
deletion into a refused boot for a plan whose price nobody had touched.

### The registry is not a plan catalogue

`aurora_meter_plan_versions` exists so that a subscription or an event naming a
version whose block has been deleted from your code is still interpretable. Code
is authoritative: there is no `Plans.put/1`, nothing reads the table to decide
what a plan is, and a row is never updated after it is inserted.

Registration also names the contract of every subscription written before core
schema version 10, in batches, resumably, on the first boot after the upgrade.
It never changes a `plan_id`, a `plan_version` or a fingerprint that is already
set. A subscription whose plan id is in no compiled module gets the version and
a null fingerprint, and is counted as `orphan_plans` in the log line: retiring a
plan id from code is ordinary and refusing the upgrade over one would make the
upgrade unrunnable for exactly the oldest installs.

Run it yourself from a release task before a rolling deploy when the
subscriptions table is large. Do not call it inside a transaction of your own:
its batch loop opens its own.

If `AuroraMeter` starts **above** your Repo in the supervision tree, registration
is deferred with one warning and retried on the first lookup that needs a stored
snapshot, rather than failing the boot. Starting it below the Repo registers at
boot, which is what you want.

### Two known limits

**A deleted version's feature names have to stay loadable.** A snapshot stores
feature names as strings and they are read back with
`String.to_existing_atom/1`, never `String.to_atom/1`, because a row read out of
a database must not be able to grow the atom table. A name whose atom does not
exist on the node is dropped from the resolved plan and logged once per version
per node. Every entitlement function takes an atom, so no caller can ask about a
dropped name; code that **enumerates** `plan.features` will not see it. Keep the
module that declares the name loadable, or restore the version's block.

**A storage adapter that cannot store snapshots is reported, not ignored.** It
logs one warning and compiled code becomes the only authority, which means a
version whose block is deleted becomes unreadable and the tenants on it fall
back to the default plan.

### One operational note

Resolving a stored snapshot writes a per-node cache with
`:persistent_term.put/2`, which triggers a global garbage-collection scan. It is
bounded: one put at registration, and one per genuinely unknown version per node
thereafter, including for versions that do not exist, which are cached
negatively so a bad lookup cannot loop.

## Moving a tenant between plans

A plan change is **explicit and scheduled**. Redeploying a plan definition never
moves anybody (ADR 0012); a tenant moves because somebody scheduled it, at an
instant they chose, with a reference they can cancel or retry.

```elixir
{:ok, transition} =
  AuroraMeter.Subscriptions.schedule_transition("org_1", :scale, ref: "upgrade-8412")

transition.effective_at
#=> ~U[2026-10-01 00:00:00Z]
```

With no `:effective_at` that is the end of the tenant's current period, from the
tenant's **own** period source: the first of next month under the calendar
default, `current_period_end` under `AuroraMeter.Pro.Period`, the end of the week
under a weekly host source. Until that instant nothing about the change is
visible to `check/2`, `quota/2` or `reserve/3`: the tenant is entitled under the
old plan and the new one is a row on the side.

Applying it is a separate call, so a host owns when it happens:

```elixir
AuroraMeter.Subscriptions.apply_due_transitions(limit: 500)
#=> {:ok, %{applied: 3, skipped: 0, failed: 0, cursor: :done}}
```

Run it from any scheduler. With Oban installed, `AuroraMeter.Oban.cron_entries/1`
returns `{"*/5 * * * *", AuroraMeter.Oban.PlanTransitions}` and you need write
nothing.

### The lifecycle

```
                 schedule_transition/3
    (none) ----------------------------> pending
                                            |
       cancel_transition/2  <---------------+
             (cancelled)                    |
                                            |
    a provider write naming neither the     |
    current nor the scheduled plan          |
             (cancelled, reason             |
              "provider_override")          |
                                            |
    apply_due_transitions/1, at or after    |
    effective_at                            v
                                         applied
                                            ^
    a provider write naming exactly the     |
    scheduled plan and version -------------+
             (applied, reason "provider_applied_early")

    the target version resolves through neither code
    nor a stored snapshot  ---------------> failed
```

Every move is a conditional update predicated on the transition still being
`pending`, so running the applier twice, from two nodes, at any interleaving,
applies the change once and reports a skip for every other caller. A transient
database error never produces `failed`: the transaction rolls back and the row
stays `pending` for the next run. Only a deterministic validation failure, a
target version in neither code nor the registry, is terminal, and it is never
retried automatically: an automatic retry of a target that does not exist loops
for ever. Restore the definition (or its snapshot), cancel, and schedule a new
one.

`schedule_transition/3` is idempotent by `(tenant, ref)`. The same reference with
the same parameters returns the existing transition; with different parameters it
is `{:error, {:conflict, ...}}` naming both what is stored and what was
submitted. A second reference cancels the first by default (`replace: true`), in
one transaction, or is refused with `replace: false`.

### Precedence

A provider-driven change (a customer using the billing portal) reaches Aurora
Meter through `AuroraMeter.Storage.put_subscription/1`, and core reacts there, so
a provider integration cannot forget to tell it.

| Situation | Rule | Owner |
|---|---|---|
| A scheduled change effective before the subscription stops being entitled | applies at its boundary; the cancellation happens later on its own | core |
| A provider write whose status is not in `entitled_statuses/0` | the transition is cancelled, `detail.reason = "subscription_not_entitled"` | core |
| A provider write naming exactly the scheduled `{plan_id, plan_version}` | the transition is applied early, `detail.reason = "provider_applied_early"` | core |
| A provider write naming any other plan | the provider wins now; the transition is cancelled, `detail.reason = "provider_override"`, with the observed pair recorded | core |
| A provider write that changes nothing about the plan | the transition stays pending | core |
| Two local schedules for one tenant | the later one with `replace: true` cancels the earlier atomically; with `replace: false` it is refused | core |
| The same schedule submitted twice | idempotent by `(tenant, ref)` | core |
| A zero-price transition | identical to any other; core never looks at a price | core |
| A cancellation known in advance (`cancel_at_period_end`) with a transition effective at or after the period end | Aurora Meter Pro calls `cancel_transition/2` when it observes the flag, so a customer is not shown a change that will never happen | Pro |
| A stale provider payload for an ended subscription | never reaches core: Pro retrieves the subscription fresh and refuses a payload that would resurrect an ended one | Pro |

The status rule is tested **first**, so a provider write that both names the
scheduled plan and ends the subscription cancels rather than applying: a tenant
who is no longer entitled has no plan to move to.

Core cannot see a future provider cancellation, because a
`cancel_at_period_end` flag is a provider concept and
`aurora_meter_subscriptions` carries none. That is why the last two rows belong
to Aurora Meter Pro.

**The comparison is on the pair, not on the plan id.** A provider that names a
plan id without naming a version has said nothing about which contract it means,
so such a write is an override and not an early apply. A provider integration
that wants the early-apply path sends `plan_version` alongside `plan_id`.

### The lag, and how to tighten it

A transition effective at `00:00` is applied by the next run of the applier.
Under the `*/5` default that is **up to five minutes plus the run's own time**,
and between the boundary and the apply the tenant is entitled under the **old**
plan: conservative for a downgrade (they keep briefly more than they paid for)
and visible to the customer for an upgrade.

Measured locally on one node, a run applying 500 due transitions takes on the
order of a second, so the run time is not what the bound is made of; the
schedule is. A host that needs a tighter bound registers a more frequent cron
entry, or calls `apply_due_transitions/1` from its own scheduler, or calls it
with `tenant:` from the request that made the change. Aurora Meter runs no timer
of its own: optional Oban integration is an optional module, not a mandatory
process.

There is a second, smaller lag on the read side. `apply_due_transitions/1`
invalidates the subscription cache **after** the transaction commits, and that
invalidation is a PubSub broadcast, which is best effort. A node that misses it
serves the old plan for at most `:subscription_cache_ttl` milliseconds (default
5,000), after which its entry expires and it reloads. Measured after a `kill -9`
between the commit and the invalidation: 5,000 ms at the default TTL. The
database is already correct throughout; this is a visibility bound, not a
correctness one.

### Previewing a change

```elixir
{:ok, preview} = AuroraMeter.Subscriptions.preview_transition("org_1", :scale)

preview.changes
#=> [%{kind: :feature, name: :ai_generations, from: {:limit, 1_000, :hard},
#      to: {:metered, 1_000, 2}, direction: :changed}, ...]
```

A pure read: no lock, no transaction, no row, safe from a LiveView render. Each
change carries a `direction` of `:increase`, `:decrease`, `:added`, `:removed` or
`:changed`.

**Core never prorates.** `preview.from.price` and `preview.to.price` are the
plans' declared list prices in cents and are not invoice amounts. The billing
provider is authoritative for what a customer is charged, and the only place a
price id or a proration mode appears is `preview.provider`, which comes from the
optional `c:AuroraMeter.Billing.Provider.describe_plan_change/3` callback. On a
core-only installation that is `%{status: :not_configured, detail: %{}}`; a
provider that errors or raises gives `%{status: :error, detail: %{reason: ...}}`
and the entitlement diff is returned either way, because that half is core's and
is right whatever the provider says.

### Nothing is reset

Applying a transition writes `aurora_meter_subscriptions` and
`aurora_meter_plan_transitions`, and nothing else. It deletes no counter, no
history bucket, no event, no credit transaction and no credit lot, and it zeroes
nothing. A new period's counters are new rows keyed by `period_start`, which is
how periods already work, so there is nothing to clear and no reset job to run.
Usage recorded before the boundary stays in the period it was recorded in.

### Two rules, and one rollout note

**Do not schedule a transition from inside a credit callback.** A transition
takes the subscription row's lock and a credit operation takes the wallet's; the
two are never taken in the same transaction, and taking them in both orders is
how a deadlock is built.

**`put_subscription/1` has a side effect from 1.0.0-rc.1.** A host calling it
directly with a changed plan while a transition is pending will now see that
transition settled, per the table above.

**Finish the rolling upgrade before scheduling.** A subscription row written
before core schema version 10 has no `plan_version` until
`AuroraMeter.Plans.register!/0` names it, and `schedule_transition/3` refuses
such a row with `{:error, {:unavailable, :registration_incomplete}}` rather than
moving a tenant whose current contract is unnamed. Registration runs at boot, so
this clears itself; the wider rule is the one the upgrade guide states, that
0.4.x nodes should be gone before any transition is scheduled, because a 0.4.x
node's `put_subscription/1` predates the explicit replace list.
