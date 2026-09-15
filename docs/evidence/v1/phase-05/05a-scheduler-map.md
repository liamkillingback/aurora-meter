# 05a: the scheduler inventory, both packages

Build unit 05a, tasks 05.01 and 05.02. Verified by reading the source on
2026-09-15 at core `8fa7128b5f6b5b6e1197ea11e811bd692c5cdd50` and Pro
`80306baa4896af3a9b2dc83ef93ed7b13a59d025`, before this unit changed either.

Everything below cites a **symbol**, never a line number: the line numbers in
05a's build document were all stale by the time this unit ran, which is the
fourth time that has happened (`open-findings.md` X147), and a citation that
rots is worse than none.

## 1. Resolved Oban versions

| Package | Requirement | Resolved in `mix.lock` |
|---|---|---|
| `aurora_meter` (new, **optional**) | `~> 2.17` | **2.24.1** |
| `aurora_meter_pro` (unchanged, required) | `~> 2.17` | 2.23.0 |

The two differ because the packages resolve independently and Pro's lock
predates 2.24. Nothing depends on them agreeing: core declares Oban
`optional: true`, so a consumer's own Oban is the one that is used, and within
Pro's build tree Pro's 2.23.0 is what core compiles against. Adding the
dependency added **one line** to core's `mix.lock` and pulled nothing
transitively: Oban 2.24.1 needs `ecto_sql ~> 3.10` (core has 3.14.0) and
`telemetry ~> 1.3` (core has 1.4.2), both already satisfied.

## 2. Core workers (new in this unit)

Every one is compiled only when `Oban` is loaded, behind
`if Code.ensure_loaded?(Oban) do` at the top of its file. The registry that
drives `cron_entries/1`, `validate!/1` and the scheduler map is the `@registry`
attribute in `AuroraMeter.Oban`.

| Worker | Operation | `max_attempts` | `unique` | Default schedule |
|---|---|---|---|---|
| `AuroraMeter.Oban.CreditExpiry` | `AuroraMeter.Credits.expire_due/1` | 3 | `[period: :infinity, states: incomplete]` | `*/30 * * * *` |
| `AuroraMeter.Oban.HoldReconciliation` | `AuroraMeter.Credits.reconcile_holds/1` | 3 | `[period: :infinity, states: incomplete]` | `*/15 * * * *` |
| `AuroraMeter.Oban.EventsReplay` | `AuroraMeter.Events.Replay.run/1` | 1 | none | none (operator run) |
| `AuroraMeter.Oban.RecurringGrants` | `AuroraMeter.Credits.Recurrences.run/1` | 3 | `[period: :infinity, states: incomplete]` | `7 * * * *` once 06d lands |
| `AuroraMeter.Oban.PlanTransitions` | `AuroraMeter.Subscriptions.apply_due_transitions/1` | 3 | `[period: :infinity, states: incomplete]` | `*/5 * * * *` once 07b lands |

`incomplete` is `Oban.Job.states() -- [:completed, :discarded, :cancelled]`, the
same expression `AuroraMeter.Pro.UsageReporter` already uses.

**Availability at this commit**, as `AuroraMeter.Oban.available?/1` reads it:

| Operation | `Code.ensure_loaded?` | `function_exported?` | In `cron_entries/1` |
|---|---|---|---|
| `AuroraMeter.Credits.expire_due/1` | true | true | yes |
| `AuroraMeter.Credits.reconcile_holds/1` | true | true | yes |
| `AuroraMeter.Events.Replay.run/1` | true | true | **no**, deliberately: no schedule |
| `AuroraMeter.Credits.Recurrences.run/1` | **false** | n/a | no |
| `AuroraMeter.Subscriptions.apply_due_transitions/1` | true | **false** | no |

The last two rows are the two halves of the predicate, and they are tested
separately for that reason: `PlanTransitions` is the case a
`Code.ensure_loaded?/1`-only check would have got wrong, because
`AuroraMeter.Subscriptions` exists and the function does not.

## 3. Pro workers (verified, and the inventory the build document got wrong)

**Nine, not seven.** 05a's build document lists seven and was written before
build unit 04b landed the outbox. Both new ones are cron-scheduled workers on
the same queue.

| Worker | Declaration | `max_attempts` | `unique` | Job args | Schedule now |
|---|---|---|---|---|---|
| `AuroraMeter.Pro.UsageReporter` | `use Oban.Worker` in `usage_reporter.ex` | 5 | `[period: :infinity, states: incomplete]` | none | `*/5 * * * *` |
| `AuroraMeter.Pro.Outbox.Deliverer` | `deliverer.ex` | 3 | `[period: :infinity, states: incomplete]` | none (owner from the job) | `*/5 * * * *` |
| `AuroraMeter.Pro.Outbox.Reconciler` | `reconciler.ex` | 3 | `[period: :infinity, states: incomplete]` | budget overrides | `*/10 * * * *` |
| `AuroraMeter.Pro.Alerts` | `alerts.ex` | 5 | none | none | `*/10 * * * *` |
| `AuroraMeter.Pro.Rollup` | `rollup.ex` | 5 | none | `since_days` | `15 2 * * *` |
| `AuroraMeter.Pro.AuditLog.Pruner` | `audit_log/pruner.ex` | 3 | none | `older_than_days` | `30 3 * * *` |
| `AuroraMeter.Pro.Credits.AutoTopUpSweeper` | `auto_top_up_sweeper.ex` | 3 | none | none | `*/5 * * * *` |
| `AuroraMeter.Pro.Credits.AutoTopUpWorker` | `auto_top_up_worker.ex` | 1 | `[keys: [:tenant_key], period: 600, states: incomplete]` | `tenant_key` | event driven |
| `AuroraMeter.Pro.Credits.Expirer` | `credits/expirer.ex` | 3 | none | none | **deprecated**, delegates |

All nine declare `queue: :aurora_meter`. Pro registers no `Oban.Plugins.Cron`
and starts no Oban instance: the host owns both. That is unchanged.

## 4. What the published documentation said, and what it says now

| Page | Before | After |
|---|---|---|
| `docs/getting-started.md` | `{"0 * * * *", AuroraMeter.Pro.UsageReporter}` | `{"*/5 * * * *", ...}` |
| `docs/usage-reporting.md` | `{"*/5 * * * *", AuroraMeter.Pro.UsageReporter}` | unchanged, plus the reason and a link to the map |
| `docs/getting-started.md` | no `AuditLog.Pruner` | added, `30 3 * * *` |
| `docs/getting-started.md` | no `Outbox.Deliverer`, no `Outbox.Reconciler` | both added |
| `docs/getting-started.md`, `docs/top-ups.md` | `{"*/30 * * * *", AuroraMeter.Pro.Credits.Expirer}` | `{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}`, with the deprecation named |

`AuroraMeter.Pro.SchedulerMapTest` now compares the guide's crontab with the
map's table and fails if either moves without the other, which is the mechanism
that was missing while the two schedules disagreed.

## 5. The reporter schedule decision (P12)

**Every five minutes: `{"*/5 * * * *", AuroraMeter.Pro.UsageReporter}`.** The
two published schedules could not both be right. The reasons are from the code:

1. The reporter's job is unique with `period: :infinity` over every incomplete
   state and no `keys`, so a tick landing while the previous run is still
   walking subscriptions is deduplicated by Oban. **Uniqueness is what prevents
   an overlap; tick frequency is not**, so "hourly, to avoid overlapping runs"
   was never the trade it looked like.
2. Each run stages a delta measured against `last_reported`, so five times the
   frequency stages the same total quantity in smaller pieces. The per-run cost
   is per subscription, which argues for bounding the batch (05c), not for an
   hourly tick.
3. Stripe finalises an invoice shortly after the period ends. Hourly leaves up
   to an hour of metered usage unstaged at that moment; five minutes bounds it
   to five minutes plus one run. `docs/usage-reporting.md`'s own claim that the
   reporter must run before invoice finalisation is only true at the tighter
   schedule.

No code changed: the schedule lives in the host's crontab and in the guides.

## 6. Supervision points

Unchanged by this unit, and listed because the map is the place an operator
looks for them:

* the host's Oban instance (default name `Oban`) and its `Oban.Plugins.Cron`,
  owned by the host in both packages;
* `AuroraMeter.TaskSupervisor`, in core's supervision tree since 05b, which is
  where a hold reconciler callback runs;
* `AuroraMeter.Pro.TaskSupervisor`, for Pro's async audit writes.

No worker in either package supervises anything, opens a transaction, or takes
a lock of its own.
