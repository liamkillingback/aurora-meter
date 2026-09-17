# Scheduler map

Everything Aurora Meter wants run on a schedule, what runs it, and what happens
if it runs twice. Aurora Meter Pro's half of the same map is in that package's
`docs/operations/scheduler.md`; the two share one queue and one Oban instance,
and this page is the core half.

## Aurora Meter ships no scheduler

Every scheduled operation is a public function. Nothing here is required to run
it, and nothing here is where the correctness lives:

| Operation | What it does |
|---|---|
| `AuroraMeter.Credits.expire_due/1` | Expires promotional grants whose date has passed. |
| `AuroraMeter.Credits.reconcile_holds/1` | Asks the host about holds still open past a cutoff, and applies the answer. |
| `AuroraMeter.Events.Replay.run/1` | Rebuilds a projection generation from the event log. |
| `AuroraMeter.Retention.prune/1` | Deletes the disposable operational rows the retention allow list names, and only those. |

If you run Oban, the optional `AuroraMeter.Oban.*` workers wrap these so you do
not have to write the wrapper. If you run something else, or nothing, call the
functions. Both are supported and the second is not a downgrade.

## With Oban

Add `{:oban, "~> 2.17"}` to your own application. Aurora Meter declares it
`optional`, so it never forces a version on you and the
`AuroraMeter.Oban` namespace simply does not exist on a build without it:

```elixir
Code.ensure_loaded?(AuroraMeter.Oban)
#=> false on a host with no Oban
```

Configure the queue and the crontab:

```elixir
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [aurora_meter: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries()},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)}
  ]
```

The second plugin is not decoration. [A node that dies mid
job](#a-node-that-dies-mid-job) is what it is for, and `validate!/1` warns when
it is absent.

`AuroraMeter.Oban.cron_entries/1` returns the recommended entries for the
workers this build can actually run. Take it whole, or merge it into a crontab
you already have:

```elixir
config :my_app, Oban,
  queues: [aurora_meter: 5],
  plugins: [
    {Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries() ++ my_own_entries()}
  ]
```

### The workers

<!-- scheduler:core -->

| Worker | Operation | Schedule | `max_attempts` | What a second run does |
|---|---|---|---|---|
| `AuroraMeter.Oban.CreditExpiry` | `AuroraMeter.Credits.expire_due/1` | `*/30 * * * *` | 3 | Expires nothing and returns `{:ok, 0}`: the grant row's own `FOR UPDATE` re-read refuses a grant already carrying `expired_at`. |
| `AuroraMeter.Oban.HoldReconciliation` | `AuroraMeter.Credits.reconcile_holds/1` | `*/15 * * * *` | 3 | Asks the host again and is refused by the hold row's `FOR UPDATE` re-read, which reports `already_closed`. |
| `AuroraMeter.Oban.EventsReplay` | `AuroraMeter.Events.Replay.run/1` | operator run | 1 | Continues from the replay's own checkpoint, or refuses when one is already running. |
| `AuroraMeter.Oban.RecurringGrants` | `AuroraMeter.Credits.Recurrences.run/1` | `7 * * * *` | 3 | Grants nothing: every period it visits is already recorded, recognised from the recurrence row or refused by `UNIQUE (tenant_key, key)` inside the wallet's balance row lock. |
| `AuroraMeter.Oban.PlanTransitions` | `AuroraMeter.Subscriptions.apply_due_transitions/1` | `*/5 * * * *` | 5 | Applies nothing and counts a skip per tenant: every effect is an update conditional on the transition still being `pending`, so the first run's winner is the only one. |
| `AuroraMeter.Oban.Retention` | `AuroraMeter.Retention.prune/1` | `40 3 * * *` | 3 | Deletes nothing the first run did not: a `DELETE` finds the rows gone. There is no cursor to go stale, because the scan advances by doing the work. |

Every worker here now wraps an operation this release compiles. Two of them
shipped before their operation did, so that the registry an installer reads was
complete and no host wrote a module name that did not resolve; `cron_entries/1`
omitted each until its operation was compiled in and started returning it with
no change to anybody's configuration once it was. Neither
`AuroraMeter.Oban.RecurringGrants` nor `AuroraMeter.Oban.PlanTransitions` was
edited to be scheduled. `AuroraMeter.Oban.EventsReplay` has no schedule for a
different reason: rebuilding a projection is a deliberate act, not something
that should begin because a minute elapsed.

`AuroraMeter.Oban.RecurringGrants` takes `%{"limit" => n}` (also `"batch"`,
`"max_periods"` and `"tenant"`). The default limit of 500 tenants per run is a
floor, not a recommendation: size it so one period's worth of hourly runs can
visit every entitled tenant at least once.

```elixir
{Oban.Plugins.Cron,
 crontab: [{"7 * * * *", AuroraMeter.Oban.RecurringGrants, args: %{"limit" => 5_000}}]}
```

`AuroraMeter.Oban.PlanTransitions` takes `%{"limit" => n}` (tenants per batch),
`%{"batches" => n}` (batches per job, default 10) and `%{"tenant" => key}`. Its
`*/5` default is the delay a host is choosing between a plan change's effective
time and its application: until the worker runs, the tenant is still entitled
under the old plan. See [Plans](../plans.md) for the measured lag and for how to
tighten it.

All six declare the queue `:aurora_meter`, which is the queue Aurora Meter Pro's
workers declare too. One queue, because they are the same kind of work and a
host that sizes one has sized both.

### Check the configuration at boot

```elixir
def start(_type, _args) do
  if Code.ensure_loaded?(AuroraMeter.Oban), do: AuroraMeter.Oban.validate!(otp_app: :my_app)

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

`AuroraMeter.Oban.validate!/1` reads configuration, never a running Oban
instance, so it does not care whether Oban starts before or after Aurora Meter
in your tree. It raises `AuroraMeter.Oban.ConfigError` listing every problem it
found in one pass:

* no `:repo`, or a `:repo` that is not the one `AuroraMeter.Config.repo/0`
  returns, which would enqueue jobs in one database and read tenant data from
  another;
* no `:aurora_meter` queue, or a limit of zero, which leaves jobs sitting
  `available` for ever;
* a `:crontab` entry naming an `AuroraMeter.Oban.*` module this build does not
  have;
* a `:crontab` naming one worker twice, or naming both
  `AuroraMeter.Oban.CreditExpiry` and the deprecated
  `AuroraMeter.Pro.Credits.Expirer`;
* a `Oban.Plugins.Cron` `:timezone` that `DateTime.now/1` cannot resolve, which
  is the same test Oban applies, run early enough to name the key;
* `:testing` left at `:inline` or `:manual` outside the test environment, which
  stops every queue and every plugin quietly.

It also **warns**, without raising, when the crontab schedules Aurora Meter
workers and the plugins include no Lifeline. See [a node that dies mid
job](#a-node-that-dies-mid-job) for what that costs and how to choose
`rescue_after`. `AuroraMeter.Oban.rescue_advice/1` returns the same sentences if
you would rather put them in a health check than in the log.

**One case it cannot see.** A second `Oban.Plugins.Cron`, under a second Oban
instance with a different name, scheduling the same workers again. `validate!/1`
is given one instance's configuration and has no way to learn about another. If
you run more than one Oban instance, one of them owns Aurora Meter's crontab.

## Without Oban

Call the operations. A `:timer` in a small GenServer is enough for a single node
host:

```elixir
defmodule MyApp.AuroraMeterSchedule do
  use GenServer

  @half_hour :timer.minutes(30)
  @quarter_hour :timer.minutes(15)

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :timer.send_interval(@half_hour, :expire)
    :timer.send_interval(@quarter_hour, :reconcile)
    {:ok, :ok}
  end

  @impl true
  def handle_info(:expire, state) do
    {:ok, _count} = AuroraMeter.Credits.expire_due()
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    cutoff = DateTime.add(AuroraMeter.Clock.now(), -3600, :second)
    {:ok, _report} = AuroraMeter.Credits.reconcile_holds(older_than: cutoff)
    {:noreply, state}
  end
end
```

Run that on every node if you like. It is the same case as two Oban nodes, and
the next section is why it is safe.

## Running the same thing twice

Aurora Meter does not assume a scheduled job runs a single time, and neither
should you. A cron plugin can tick twice across a leader change, a rescued job
runs again, a deploy overlaps two releases, and two nodes can both be told to
sweep. Invariant I16 in `docs/correctness.md` is the statement of what is
promised instead: **the effect is the same if it happens twice.**

That property belongs to the operations, not to the workers:

* `expire_due/1` locks each grant row with `FOR UPDATE` and re-reads
  `expired_at` inside the lock. The second caller finds it set and expires
  nothing.
* `reconcile_holds/1` applies each decision through `settle/3` or `release/2`,
  which lock the hold row and re-read `status = 'pending'` inside the lock. The
  second caller is told `:already_closed` and counts it.
* `Replay.run/1` claims its generation and refuses a second concurrent run.

None of these is a lease, a fence or a timeout. That is deliberate: a lease is a
duration, and a duration at a sub-second scale cannot be ordered safely by a
clock that steps backwards, which the one clock every node shares does on this
hardware. Postgres already serialises two writers on one row, and the loser
reads what the winner wrote. There is no clock in that decision at all.

The `unique` option on each worker is defence in depth, and it is worth having:
it saves a duplicate run's work. It is not what keeps the ledger right, and
removing it would not make any of the above untrue.

## A node that dies mid job

A node killed while one of these workers is running leaves its job `executing`
for ever. Nothing observed the death, so nothing fails it, retries it or
discards it, and the row sits there with `attempted_by` naming a node that no
longer exists.

Two things follow from that, and they have different owners.

**The one this package owns: a wedged job must not stop its worker for ever.**
Every worker here that is unique at all has `:executing` among its uniqueness
states, so a job in that state deduplicates a new enqueue. Until repair unit R9 the period beside it was
`:infinity`, which never lapses, so **one node death stopped that worker
permanently**: the crontab ticked, every insert collapsed into the corpse, and
Oban looked healthy the whole time. Aurora Meter Pro's outbox deliverer was
measured doing exactly that in a soak run, with usage accumulating and never
being billed (`open-findings.md` X486). Every period is now finite:

<!-- scheduler:periods -->

| Worker | Schedule | `unique` period | Resumes within |
|---|---|---|---|
| `AuroraMeter.Oban.CreditExpiry` | `*/30 * * * *` | 3600 | 90 minutes |
| `AuroraMeter.Oban.HoldReconciliation` | `*/15 * * * *` | 1800 | 45 minutes |
| `AuroraMeter.Oban.RecurringGrants` | `7 * * * *` | 3600 | 2 hours |
| `AuroraMeter.Oban.PlanTransitions` | `*/5 * * * *` | 900 | 20 minutes |
| `AuroraMeter.Oban.Retention` | `40 3 * * *` | 3600 | the next nightly run |
| `AuroraMeter.Oban.EventsReplay` | operator run | none | not applicable: it is not unique |

The rule for the period is twice the worker's documented schedule, rounded up to
the next quarter hour, and never more than an hour. Inside the period a second
tick is still refused, which is what the option is for. Past it a run that has
been going for two full schedule intervals is either wedged or so far behind that
a second worker is help rather than harm, and a second worker is safe for the
reason the section above gives: the guarantee is in the operation, not in the
queue.

**"Resumes within" is the period plus one schedule interval, and the second term
is not a rounding error.** The uniqueness stops matching the corpse `period`
seconds after it was enqueued, but nothing enqueues a replacement until the next
**tick**, so the worker resumes at the first tick more than `period` after the
wedge. For `RecurringGrants` those two are the same hour, which is why its
figure is two hours rather than one. Anything faster than its own schedule is
`Oban.Plugins.Lifeline`'s job, below.

**The one you own: clearing the orphan.** A finite period keeps the worker
alive; it does not move the dead job, and nothing in this package can. That is
`Oban.Plugins.Lifeline`:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries()},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(20)}
  ]
```

Pick `rescue_after` yourself, and pick it **longer than your slowest legitimate
run**. Lifeline rescues on elapsed time alone: it cannot tell a dead node from a
slow one, so too short a value moves a job that is still running back to
`available` and you get two copies. Oban Pro's `DynamicLifeline` uses node
liveness instead and is the better answer if you have it.

`AuroraMeter.Oban.validate!/1` warns when your crontab schedules Aurora Meter
workers and no Lifeline is configured. It matches any plugin whose name ends in
`Lifeline`, so `DynamicLifeline` counts. It is a warning rather than a
refusal because these workers no longer depend on it to stay alive. Silence it
with `rescue: :ignore`, or make it a refusal with `rescue: :require`.

## Telemetry

The workers emit nothing of their own. The operations they call emit their own
events, which are listed in [Telemetry](telemetry.md). `[:oban, :job, :stop]`
and its siblings come from Oban and carry the worker name, which is how to chart
run counts and durations per worker.
