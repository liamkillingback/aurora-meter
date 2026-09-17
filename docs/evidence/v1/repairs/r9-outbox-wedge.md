# R9: one node death stopped delivery for ever, and the fix is a number rather than a plugin

Repair unit R9, 2026-09-17 (UTC). Finding X486, raised by build unit 11d from
soak run 1. Branch `aurorameter-v1`, nothing committed and no checkbox ticked
(rule 4).

Core `aurora_meter` at 1.0.0-rc.1, Pro `aurora_meter_pro` at 1.0.0-rc.1. Elixir
1.20.1 / OTP 29 (erts 17.0.1), Postgres in the package container on port 5490.
11d's uncommitted work was in the tree throughout and none of it was reverted.
The three soak databases 11d kept were not touched, and no container was
created, started or removed.

Pro's half of this document, with the same measurements from Pro's side, is
`aurora_meter_pro:docs/evidence/v1/repairs/r9-outbox-wedge.md`.

---

## 0. The headline

**Delivery resumes after a node death.** Measured three ways, each with a real
`SIGKILL` of a second BEAM that was executing an
`AuroraMeter.Pro.Outbox.Deliverer` job at the moment it died, against the same
staged outbox item, on the same database, with the same surviving node ticking
the documented crontab every thirty seconds:

| Run | Tree | Host plugins | Ticks refused | First tick that was not the corpse | Item delivered |
|---|---|---|---|---|---|
| `before` | shipped (`period: :infinity`) | none | every one | **never** | **no** |
| `after` | repaired (`period: 900`) | none | 30, ages 4 s to 875 s | **corpse age 905 s** | **yes**, `accepted`, `attempts: 2` |
| `lifeline` | repaired | `{Oban.Plugins.Lifeline, rescue_after: 5_000}` | 1, at age 4 s | **corpse age 34 s** | **yes**, `accepted`, `attempts: 2` |

In the `before` run every enqueue returned **the corpse's own job id** with
`conflict?: true`, and the staged item was still `leased` by the dead node at the
end. That is X486, reproduced deterministically in under a minute, where 11d
needed a soak to find it.

In `after`, thirty consecutive ticks were refused with the corpse's id, and the
thirty first, 905 seconds after the corpse was enqueued, created job 255, ran
it, and the item reached `accepted` with a provider reference. The bound is
therefore not an argument about Oban's source; it is a measured number, and it
is the declared period to within one tick.

In `lifeline`, the orphan was rescued, **ran to `completed`**, and delivered the
item itself. Recovery was one plugin interval rather than fifteen minutes, which
is the whole reason the plugin is now documented.

**The choice, and what it costs.** Bounded uniqueness periods in the packages,
`Oban.Plugins.Lifeline` documented and warned about for the host. Section 1 is
the reasoning; section 1.4 is the cost.

**Seven workers had the defect, four of them in the free core.** X486 named one.
Section 2 is the disposition of all seventeen Oban workers across both packages,
including the ten that were already fine and why.

**The permanent detector is behavioural and lives in Pro**, because core's suite
starts no Oban instance and has no `oban_jobs` table, and it covers **both**
packages' workers. Section 3. It was watched failing first, and its controls
were re-run against the final version (X492).

---

## 1. The decision, stated before it was implemented

### 1.1 What is actually broken

`unique: [period: :infinity, states: <every incomplete state>]` and `:executing`
in that list. Oban's uniqueness query is

```elixir
Job
|> where([j], j.state in ^states)
|> since_period(period, timestamp)   # :infinity adds no clause at all
|> where(^dynamic)
|> limit(1)
```

(`deps/oban/lib/oban/engines/basic.ex`). `since_period(query, :infinity, _)`
returns the query unchanged, so with `:infinity` the only filter is the state.
A job stuck `executing` therefore matches for ever.

Nothing moves a job out of `executing` when its node dies. Oban has no crash
detection: the producer that would have failed the job died with it. So the row
is permanent, and with it the deduplication.

### 1.2 The four options, and why each was rejected or kept

**A bounded uniqueness period. KEPT.** The corpse stops matching `period`
seconds after its `inserted_at`, and the worker resumes. What it admits is a
second run of a worker whose first run has been going longer than the period.

**Dropping `:executing` from the states. NOT AVAILABLE, and that was measured
rather than argued.** Oban 2.23 refuses it at **compile time**:

```
warning: unique :states [:suspended, :scheduled, :available, :retryable] is missing
incomplete states [:executing] which may break uniqueness, use a unique group like
:incomplete
```

Both packages compile with `--warnings-as-errors` in their gate, so the plant
does not build at all (control C2, section 4.3). The option the finding listed
second is one Oban's own authors already decided against, and the guard against
somebody reintroducing it is stronger than any test this unit could write: it is
the compiler.

It would also have been strictly weaker than A. It recovers immediately, but it
gives up the deduplication *completely* rather than after a window: every tick
that lands while a run is going starts another worker. Soak run 1 enqueued a
deliverer every fifteen seconds; without `:executing` that is four new jobs a
minute into a queue whose documented limit is five, shared with every other
Aurora Meter worker. A is the same concession made later and only where it is
wanted. Dropping `:executing` is A with the period set to zero, and zero is the
wrong number, not a different mechanism.

**`Oban.Plugins.Lifeline` alone. REJECTED as the fix, KEPT as the
documentation.** It is the right cleanup and it is not available to either
package: Pro "starts no Oban instance, registers no `Oban.Plugins.Cron` and
supervises nothing of the sort" (`docs/operations/scheduler.md`), and core's
Oban dependency is optional. A library cannot install a plugin into a host's
supervision tree. Shipping a fix whose whole content is "please configure
something" leaves the default broken, and the default is what soak run 1 ran.
It also has a failure mode of its own: Lifeline rescues on **elapsed time
alone**, so a `rescue_after` shorter than a legitimate run moves a live job back
to `available` and produces two copies. That is a trade an operator makes with
knowledge of their own workload, not one a library can make for them.

**Both. CHOSEN.** The period makes the package's own liveness independent of
host configuration. The plugin clears the orphan, and is now named in both
scheduler maps, in both recommended configurations, and by
`AuroraMeter.Oban.validate!/1`.

### 1.3 Why a bounded period is safe here, which is the load-bearing claim

A bounded period admits a genuine duplicate run. That is only acceptable because
a duplicate run of every one of these workers was **already** safe, and both
packages have said so in print for longer than this finding has existed:

> The `unique` option on each worker is therefore defence in depth and not the
> guarantee. Removing it wastes work; it does not move money.
> `aurora_meter:lib/aurora_meter/oban.ex`

> The lease is the lock.
> `aurora_meter_pro:lib/aurora_meter/pro/outbox/deliverer.ex`

Not taken on trust. 04b's evidence measures it: `I16 twelve independent
connections claiming one item produce exactly one claim`, `I16 fifty items and
four workers produce fifty accepted items and no duplicate effect`, and every
transition out of `leased` is fenced on `lease_token` with a negative control
proving the fence is what answered. Those tests were re-run for this unit and
are in section 4.

**The outbox's delivery contract is unchanged.** No state transition was
touched, no identifier derivation was touched, and the at-least-once behaviour
11d measured (74 identities accepted twice under the *same* identifier, zero
under a different one) is the same behaviour after this unit as before it.
R9 changed three integers in Pro and four in core, plus documentation.

### 1.4 The number, and what it costs

**Twice the worker's documented schedule, rounded up to the next quarter hour,
and never more than an hour.** One sentence, seven workers, no exceptions.

| Package | Worker | Schedule | Was | Now | Resumes within |
|---|---|---|---|---|---|
| core | `AuroraMeter.Oban.CreditExpiry` | `*/30 * * * *` | `:infinity` | 3600 | 90 minutes |
| core | `AuroraMeter.Oban.HoldReconciliation` | `*/15 * * * *` | `:infinity` | 1800 | 45 minutes |
| core | `AuroraMeter.Oban.RecurringGrants` | `7 * * * *` | `:infinity` | 3600 | 2 hours |
| core | `AuroraMeter.Oban.PlanTransitions` | `*/5 * * * *` | `:infinity` | 900 | 20 minutes |
| Pro | `AuroraMeter.Pro.Outbox.Deliverer` | `*/5 * * * *` | `:infinity` | 900 | 20 minutes |
| Pro | `AuroraMeter.Pro.UsageReporter` | `*/5 * * * *` | `:infinity` | 900 | 20 minutes |
| Pro | `AuroraMeter.Pro.Outbox.Reconciler` | `*/10 * * * *` | `:infinity` | 1800 | 40 minutes |

**"Resumes within" is the period plus one schedule interval, and getting that
wrong was the first draft of this document.** The uniqueness stops matching the
corpse `period` seconds after it was enqueued; nothing enqueues a replacement
until the next **tick**. `RecurringGrants` is the worst ratio for the same
reason: at the hourly cap its period equals its schedule, so the tick that lands
exactly at the lapse is still refused and the one after it is not.

**The cost, stated plainly and without softening it:**

1. **Up to twenty minutes of stopped delivery after a node dies mid-batch**, and
   up to two hours for the hourly recurring-grants sweep. That is bounded
   backlog, not lost work: the outbox is durable, the dead node's leases lapse
   after `outbox_lease_seconds` (120 by default), and the next deliverer
   reclaims them. A grant is due from its period, not from the run that noticed
   it. It is not zero, and a host that cannot accept twenty minutes installs
   Lifeline with a shorter `rescue_after`, which is now the documented answer
   and which the third measurement in section 4.1 is of.
2. **A duplicate run admitted whenever a healthy run exceeds its period.** For
   the deliverer and the reconciler that is wasted database reads; the lease and
   the fence decide who acts. For the core workers it is a wasted scan; the row
   locks decide. Section 1.3 is the evidence.
3. **The orphaned job is still there.** A finite period stops it deciding
   anything; it does not remove it. Without Lifeline those rows accumulate, one
   per node death per worker, and `JOBS-01`-style counts of long-`executing`
   jobs keep rising. This is the half the package cannot fix and now documents.

**What was NOT done, deliberately.** No uniqueness was removed. No state
machine was touched. No default was changed that a host can observe other than
the three periods and one new warning. `validate!/1` does **not** refuse a
configuration without Lifeline, because X395 is what happens when a package
makes its own documented configuration unbootable.

---

## 2. Every Oban worker in both packages

Seventeen modules `use Oban.Worker`. **X486 named one of them; seven had the
defect.**

The scan reads the **resolved** uniqueness, `worker.new(args)` then
`Ecto.Changeset.get_change(:unique)`, not the literal keyword list. That matters
for exactly one worker: `AuroraMeter.Pro.Transitions.Applier` declares
`unique: [period: 60]` with no `:states`, and Oban's default states
(`~w(scheduled available executing retryable completed)a`) **include
`:executing`**. A check that read the declaration would have called it clean
without looking.

### 2.1 Had the defect, repaired here

| Worker | Was | Now |
|---|---|---|
| `AuroraMeter.Pro.Outbox.Deliverer` | `period: :infinity`, `:executing` in states | 900 |
| `AuroraMeter.Pro.Outbox.Reconciler` | `period: :infinity`, `:executing` in states | 1800 |
| `AuroraMeter.Pro.UsageReporter` | `period: :infinity`, `:executing` in states | 900 |
| `AuroraMeter.Oban.CreditExpiry` | `period: :infinity`, `:executing` in states | 3600 |
| `AuroraMeter.Oban.HoldReconciliation` | `period: :infinity`, `:executing` in states | 1800 |
| `AuroraMeter.Oban.RecurringGrants` | `period: :infinity`, `:executing` in states | 3600 |
| `AuroraMeter.Oban.PlanTransitions` | `period: :infinity`, `:executing` in states | 900 |

Four of the seven are in the **free core**, which X486 did not say. A host
running core alone, with no Pro and no outbox, had four workers that stopped
permanently on one node death: credit expiry, hold reconciliation, recurring
grants and plan transitions. Recurring grants stopping is a customer not
receiving credit they are entitled to.

### 2.2 Already fine, with `:executing` in the states and a bounded period

Unchanged, and each is inside the rule already.

| Worker | Period | Why it is fine |
|---|---|---|
| `AuroraMeter.Oban.Retention` | 3600 | Daily schedule, hourly period. The corpse stops matching 23 hours before the next tick asks, so a wedge costs this worker **nothing at all**. |
| `AuroraMeter.Pro.Rollup` | 3600 | Daily schedule. Same shape, same answer. |
| `AuroraMeter.Pro.Retention.Pruner` | 3600 | Daily schedule. Same shape, same answer. |
| `AuroraMeter.Pro.Alerts` | 300 | Ten minute schedule, five minute period: the period is **shorter** than the schedule, so a corpse never blocks a tick at all. |
| `AuroraMeter.Pro.Credits.AutoTopUpSweeper` | 240 | Five minute schedule, four minute period. Same shape. |
| `AuroraMeter.Pro.Credits.AutoTopUpWorker` | 600, keyed on `tenant_key` | Event driven, never cron. A wedge is per tenant, not global: one tenant's top-up waits ten minutes, everyone else's is unaffected. The payment path's guards are in the ledger and in Stripe's idempotency, never in the scheduler. |
| `AuroraMeter.Pro.Transitions.Applier` | 60, default states | The one worker whose `:executing` is implicit. Sixty seconds against a five minute schedule, so a wedge never reaches the next tick. |

**Six of the seven cost nothing at all after a node death**, because their
period is shorter than their schedule, so the corpse has stopped matching by the
time the next tick asks. The exception is `AutoTopUpWorker`, which has no
schedule: it is enqueued by the low-balance hook and by the sweeper, and a wedge
delays one tenant's top-up by up to ten minutes while every other tenant's is
unaffected, because its uniqueness is keyed on `tenant_key`.

**A period shorter than the schedule is what makes four of those safe, and it
is also what three of their comments got wrong.** Oban measures the uniqueness
window from `inserted_at`, so a worker deduplicates an overlapping tick only
while `period >= schedule`. `Alerts` (300 against 600), `AutoTopUpSweeper` (240
against 300), `Rollup` (3600 against a day) and `Transitions.Applier` (60
against 300) are all the other way round, and three of them carried a comment
saying a tick landing while the previous run is still going is deduplicated. It
is not, and a duplicate run of each is documented as harmless for its own
reasons. **R9 corrected the three comments and deliberately did not widen the
periods**: widening them would change the concurrency of workers this unit does
not own, in exchange for a property their own documentation says they do not
need, and it would lengthen the very outage X486 is about.

Measured rather than reasoned (`tmp/v1/r9/probe-shortperiod.exs`): plant a job
`executing` one full schedule interval ago, then enqueue once.

| Worker | Schedule | Period | Overlapping tick deduplicated |
|---|---|---|---|
| `AuroraMeter.Pro.Alerts` | 600 | 300 | **no** |
| `AuroraMeter.Pro.Credits.AutoTopUpSweeper` | 300 | 240 | **no** |
| `AuroraMeter.Pro.Transitions.Applier` | 300 | 60 | **no** |
| `AuroraMeter.Pro.Outbox.Deliverer` | 300 | 900 | yes |
| `AuroraMeter.Pro.UsageReporter` | 300 | 900 | yes |
| `AuroraMeter.Pro.Outbox.Reconciler` | 600 | 1800 | yes |

The bottom three are R9's, and the same probe is the proof that the rule
delivered what it promised: twice the schedule is what makes the overlapping
tick actually collapse. Filed as X499.

### 2.3 Cannot be wedged: no uniqueness at all

| Worker | Why |
|---|---|
| `AuroraMeter.Oban.EventsReplay` | `max_attempts: 1`, no `unique`, operator run. A replay claims its generation and refuses a second concurrent run in the **operation**, so there is nothing for the queue to deduplicate. A node death loses that run, which is correct: a replay resumes from its own checkpoint when the operator starts the next one. |
| `AuroraMeter.Pro.AuditLog.Pruner` | Deprecated shim, no `unique`. Delegates to `AuroraMeter.Pro.Retention.Pruner` narrowed to one table. |
| `AuroraMeter.Pro.Credits.Expirer` | Deprecated shim, no `unique`. Delegates to `AuroraMeter.Oban.CreditExpiry`, which is repaired above. |

All three are named explicitly in the detector, so a worker that loses its
uniqueness by accident shows up as a change to that list rather than as one
fewer subject.

**Nothing else in either package `use`s `Oban.Worker`.** The detector asserts
its own scan is not empty and finds at least seven Pro and five core workers, so
none of section 2 can pass by finding nothing.

---

## 3. The permanent detector

### 3.1 Where it lives, and why it lives there

`aurora_meter_pro:test/aurora_meter/pro/oban_wedge_test.exs`, covering **both**
packages' workers.

It cannot live in core. Core's dependency on Oban is `optional: true`, so core's
suite starts no Oban instance and its test database carries no `oban_jobs`
table; a test that cannot insert a job cannot watch one being refused. Pro's
suite has both, and core is a dependency of Pro, so the file reads
`AuroraMeter.Oban.__registry__/0` and subjects core's five unique workers to the
same three assertions as Pro's nine.

Core keeps the structural half as well, in
`aurora_meter:test/aurora_meter/oban_test.exs`, because Pro can be absent and
core's four workers are then wedged with nobody watching.

### 3.2 What it asserts

Three properties, and none of the three is sufficient alone.

1. **A corpse older than the worker's own uniqueness period does not block a new
   enqueue.** The behaviour X486 is about. On its own it is satisfied by a
   worker that is not unique at all.
2. **A corpse younger than that period still does.** The control for 1. Without
   it, 1 passes because there is nothing left to deduplicate against.
3. **Every period is finite and at most 3600.** The bound in 1 is only a bound
   because the number is stated and small. On its own this is reading an option,
   which is not verification.

Plus an end-to-end case: stage an outbox item, plant the corpse, tick the
crontab, and assert the item reaches `accepted` with the exporter having
recorded exactly one delivery. And two anti-vacuity cases: the scan finds both
packages' workers, and the three workers with no uniqueness are listed by name.

The corpse is **planted**, not produced by killing a node, and the row planted
is the row a real kill leaves, read back from the database in section 4.1:
state `executing`, `attempted_by` naming a node that never existed, and an
`inserted_at` the test sets relative to the worker's own declared period. A
test cannot kill a node every run. It can assert against what one leaves.

### 3.3 What it would catch, and what it would not

**Would catch:**

- any worker in either package reintroducing `period: :infinity` beside
  `:executing`, including implicitly through Oban's default states;
- a period raised past an hour, which is a bound in name only;
- a new worker added with either shape, because the scan is derived from
  `lib/**/*.ex` and the core registry rather than from a list;
- the uniqueness being **removed** to "fix" this, which property 2 refuses;
- the scheduler map and the code disagreeing about a period, in both directions,
  in both packages.

**Would not catch:**

- **an orphan accumulating.** Nothing in the packages clears one, and the
  detector asserts the corpse is still `executing` at the end rather than
  pretending otherwise. Lifeline is the host's, and the only thing the packages
  can do about it is warn, which `validate!/1` now does.
- **a host that never configures a rescue and never reads the warning.** The
  worker stays alive; the rows pile up.
- **a wedge caused by something other than `:executing`.** A job stuck
  `available` because the queue limit is zero blocks the same way. `validate!/1`
  already refuses a zero limit, which is a different detector for a different
  failure.
- **the fifteen minutes themselves.** The detector proves the period bounds the
  outage; it does not assert that fifteen minutes is acceptable to a given
  business. That is section 1.4 and it is a judgement, not a test.
- **a provider that stops accepting deliveries.** That is SOAK-05's territory,
  and 11d made it an assertion.

---

## 4. The measurements

### 4.1 A real node kill, three ways

Harness `tmp/v1/r9/kill-node.sh`, with `victim.exs` and `survivor.exs`. Held the
Pro mix lane for the whole cycle (X371). Two separate BEAMs against
`aurora_meter_pro_test` on 5490: the victim starts Oban with the documented
queue and crontab shape and **no rescue plugin**, stages one outbox item,
enqueues one deliverer, and blocks inside the exporter. The harness waits until
the job row really says `executing`, then sends `SIGKILL` to the victim's OS
pid. The survivor is a second BEAM that ticks the crontab every thirty seconds.

Every row the harness writes is deleted on EXIT, including on a crash. No soak
database was touched and no container was created, started or removed.

| | `before` | `after` | `lifeline` |
|---|---|---|---|
| Deliverer `unique` | `period: :infinity` | `period: 900` | `period: 900` |
| Host `plugins` | `[]` | `[]` | `[{Lifeline, rescue_after: 5_000, interval: 2_000}]` |
| Killed at | 12:42:43.823Z | 12:48:11.693Z | 12:45:28.924Z |
| Row the kill left | `executing`, `attempted_by {r9_victim@kill, d8495a24-...}` | `executing`, `{r9_victim@kill, 55384c7d-...}` | `executing`, `{r9_victim@kill, ed1092df-...}` |
| Item at the kill | `leased` by the dead node | `leased` by the dead node | `leased` by the dead node |
| Ticks refused | all | 30, corpse age 4 s to 875 s | 1, corpse age 4 s |
| First free enqueue | none | job 255, corpse age **905 s** | job 250, corpse age **34 s** |
| Dead job at the end | `executing` | `executing` | **`completed`** (rescued and run) |
| Item at the end | `leased`, no `provider_ref` | `accepted`, `attempts: 2`, `provider_ref` set | `accepted`, `attempts: 2`, `provider_ref` set |
| `delivery_resumed` | **false** | **true** | **true** |

Two things in that table are worth reading twice.

**`after` is refused for the whole period and then works, which is what a bound
is.** Thirty ticks in a row returned the corpse's id. Nothing distinguishes the
thirtieth from the tenth. A reader who watched the first five minutes of this
run and stopped would have written down exactly what the `before` run says.

**The corpse is still `executing` in `after`, and that is not a loose end this
unit forgot.** A finite period stops the corpse deciding anything; only Lifeline
removes it, and only the host can install Lifeline.

### 4.2 The detector watched failing, then passing

Against the **unrepaired** tree (`tmp/v1/r9/control-before.log`), 3 of 6:

```
1) ... does not stop its worker being enqueued again, in either package
   AuroraMeter.Oban.CreditExpiry cannot be enqueued while a job of its own sits
   `executing`, attempted by a node that never existed, 14400 seconds after it
   was inserted.   ...   The uniqueness period is :infinity.
2) ... every worker's uniqueness period is finite and at most an hour
3) ... the outbox drains: a corpse from a dead node does not stop the item being delivered
```

Against the repaired tree: **6 passed**.

The first run of that control failed **with the wrong message**: `assert pattern
= expr, message` is ExUnit's two-argument `assert/2`, which does not rewrite the
match, so the mismatch raised `MatchError` and printed a 30 line `%Oban.Job{}`
dump where a paragraph naming X486 had been written. Every enqueue assertion in
the file is a `match?/2` for that reason, and the same shape exists in 17 other
places in the two suites (X497).

### 4.3 Controls

Every control was run against the **final** version of the reader it controls,
not against the version that existed when it was written (X492). Both harnesses
snapshot by sha256, restore on an EXIT trap and verify the restore (X326), and
refuse to run unless they can prove they hold the mix lane (X371).

Core, `tmp/v1/r9/control-core.sh`:

| | Plant | Detector | Result |
|---|---|---|---|
| C0 | none | `oban_test.exs` | 43 passed |
| C1 | `CreditExpiry` back to `period: :infinity` | `oban_test.exs` | **2 failed**: the finite-period test and the map comparison |
| C2 | the map publishes 60 for `PlanTransitions` | `oban_test.exs` | **1 failed**: document 60, worker 900 |
| C3 | plants removed | `oban_test.exs` | 43 passed |

Pro, `tmp/v1/r9/control-pro.sh`:

| | Plant | Detector | Result |
|---|---|---|---|
| C0 | none | wedge, map | 6 passed, 14 passed |
| C1 | `Deliverer` back to `period: :infinity` | wedge | **3 of 6 failed**, including the delivery case |
| C2 | `:executing` dropped from the reporter's states | the build | **refused to compile**: Oban's own warning, under `--warnings-as-errors` |
| C5 | the deliverer's period silently changed to 60 in the **code** | map | **2 failed**. The wedge detector alone passed 6 of 6 |
| C3 | the map changed to 60, the **code** left at 900 | map | **1 failed** |
| C4 | plants removed | wedge, map | 6 passed, 14 passed |

**C5 is the one worth keeping.** A period quietly shortened to 60 seconds is
still finite, still under the ceiling, and still deduplicates inside itself, so
the wedge detector passes it 6 of 6. What catches it is the scheduler map
comparison, in both directions. Naming which layer answered is X125's rule, and
without C5 this document would have claimed the wedge detector guards the
number when it guards only the shape.

### 4.4 The suites

| | Baseline | After | Added |
|---|---|---|---|
| core `mix check` | 2346 passed | **2358 passed** (160 doctests, 22 properties, 2176 tests), 8 excluded, **exit 0** | 12 |
| Pro `mix check` | 1243 passed | **1251 passed** (97 doctests, 1154 tests), **exit 0** | 8 |

Both are the full gate: `format --check-formatted`, `compile --warnings-as-errors
--force`, `credo --strict`, `dialyzer`, `test`, docs. Formatting was applied to
**only** the files this unit changed and the diffstat of the formatting pass was
read each time (X439, X449, X462): two core files and one Pro file were
reformatted, by one, two and two lines.

**Pro's dialyzer failed once on a stale PLT and it is worth reading.** The first
`mix check` after this unit's changes reported three warnings naming **core**
functions that plainly exist: `AuroraMeter.Config.PrefixError.exception/1 does
not exist`, and calls to missing `AuroraMeter.Install.Plan.refuse_existing!/3`
and `detect_from/2`. R9 touched none of those. Dialyxir printed "PLT is up to
date!" against a PLT written at 08:30, while core's beams, which reach Pro as a
**path** dependency, were rebuilt at 12:44. `mix dialyzer --force-check` added
one module to the PLT and the identical analysis passed. Filed as X501: the
staleness check does not see a path dependency change, and the direction it
failed in this time was a false alarm, which is the safe half of the same
mechanism.

---

## 5. What nobody asked for

Seven findings, filed as X495 to X501. Four are consequences of looking at all
seventeen workers instead of the one X486 named; three are instruments.

1. **X495: four of the seven are in the free core.** Section 2.1. X486 was filed
   as Pro's, and the same line was in core four times.
2. **X496: Oban's default uniqueness states include `:executing`.** A worker
   that declares `unique: [period: 60]` and nothing else has the X486 shape
   implicitly, and `__opts__()` does not show it. Both detectors read the
   resolved option for that reason. The first draft of the disposition sweep
   read the declaration and was going to call `Transitions.Applier` clean
   without looking. It is clean, which is what makes the near miss worth
   recording.
3. **X497: `assert <pattern> = <expr>, <message>` discards the message**, in 17
   places across the two suites. It fails towards noise rather than towards
   success: the test still fails, but the explanation is replaced by a struct
   dump at the moment somebody needs it. Found by writing the eighteenth.
4. **X498: core's scheduler-map reader was unbounded** and parsed this unit's
   new table as workers: 14 rows for six workers, `Worker` as a module name,
   `binary_to_integer("Stopped for at most")`. Pro's copy of the same reader had
   been bounded when this happened to it; nobody asked the question of core's.
5. **X499: three workers' comments claim a deduplication their periods cannot
   deliver.** A period shorter than the schedule never sees the next tick. The
   comments are corrected here; the periods deliberately are not, because
   widening them would change the concurrency of workers this unit does not own
   and would lengthen the very outage X486 is about.
6. **X500: Pro's scheduler map says `AutoTopUpWorker` is `max_attempts: 1`** in
   its prose, while its own table two paragraphs above and the worker itself say
   5. The table is compared with the code by a test and cannot rot; the prose
   beside it can, and did. Filed rather than fixed: it is P20's, and it is about
   the payment path.
7. **X501: dialyxir's PLT staleness check does not see a path dependency's beams
   change**, so Pro's gate reported three `call_to_missing` warnings about core
   functions that exist, while printing "PLT is up to date!". Section 4.4.

And one thing the brief asked about that this unit deliberately did not do:
**`JOBS-01` still reports rather than asserts.** It counts jobs executing for
more than ten minutes, and 11d's C20 proved that counter discriminates, but the
reader's status is `"report"`, so a future soak would print the number and pass.
Promoting it is a one line change in `scripts/v1/soak/host/checks/run.exs`,
which is 11d's file, is dirty with 11d's uncommitted work, and whose control
would have to be re-run against the changed version (X492) through the soak
control harness. R9 put its permanent detector in the two package suites
instead, where it runs on every `mix check` rather than on every soak.
