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
  plugins: [{Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries()}]
```

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
| `AuroraMeter.Oban.RecurringGrants` | `AuroraMeter.Credits.Recurrences.run/1` | not in this release | 3 | Cancels with `{:cancel, :not_implemented}`. |
| `AuroraMeter.Oban.PlanTransitions` | `AuroraMeter.Subscriptions.apply_due_transitions/1` | not in this release | 3 | Cancels with `{:cancel, :not_implemented}`. |

Two of the five wrap operations a later Aurora Meter 1.0 release adds. They ship
now so that the registry an installer reads is complete and no host writes a
module name that does not resolve. `cron_entries/1` omits them until their
operation is compiled in, and starts returning them with no change to your
configuration once it is. `AuroraMeter.Oban.EventsReplay` has no schedule for a
different reason: rebuilding a projection is a deliberate act, not something
that should begin because a minute elapsed.

All five declare the queue `:aurora_meter`, which is the queue Aurora Meter Pro's
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

## Telemetry

The workers emit nothing of their own. The operations they call emit their own
events, which are listed in [Telemetry](telemetry.md). `[:oban, :job, :stop]`
and its siblings come from Oban and carry the worker name, which is how to chart
run counts and durations per worker.
