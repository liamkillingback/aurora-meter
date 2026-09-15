# 05c: the installers

`mix aurora_meter.install --oban --check-support` and the new
`mix aurora_meter_pro.install`. G05's fifth bullet: **the installer detects
existing Oban configuration and adds only missing entries; a second execution is
a no-op.**

Every block below is copied from `05c-installers.log`, which is the output of
`tmp/v1/05c/capture-installers.exs` run through the Pro lane on 2026-09-15.
Core `4ac358d`, Pro `f7cf190`, Igniter 0.8.4.

## 1. A project with no Oban configuration

`mix aurora_meter.install --repo Demo.Repo --oban` on a bare project produces:

```elixir
import Config

config :demo,
       Oban,
       repo: Demo.Repo,
       queues: [aurora_meter: 5],
       plugins: [
         {Oban.Plugins.Cron,
          crontab: [
            {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
            {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation}
          ]}
       ]

config :aurora_meter,
  repo: Demo.Repo,
  pubsub: Demo.PubSub,
  plans: Demo.Plans,
  undeclared_feature_policy: :deny
```

and, in `lib/demo/application.ex`:

```elixir
def start(_type, _args) do
  if Code.ensure_loaded?(AuroraMeter.Oban),
    do: AuroraMeter.Oban.validate!(otp_app: :demo)

  children = [AuroraMeter]
  ...
```

Two entries and not five, because `cron_entries/1` returns an entry only for a
worker whose operation is compiled into the build: `EventsReplay` has no
schedule by design, and `RecurringGrants` and `PlanTransitions` are waiting for
06d and 07b. That is 05a's availability predicate doing its job, and the
installer inherits it rather than carrying a list of its own.

## 2. A project that already runs Oban

Before, with the host's own concurrency, its own plugin, its own worker, and its
own schedule for one of ours:

```elixir
config :demo, Oban,
  repo: Demo.Repo,
  queues: [aurora_meter: 2, mailers: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", AuroraMeter.Oban.CreditExpiry},
       {"@daily", Demo.Workers.Nightly}
     ]}
  ]
```

After:

```elixir
config :demo, Oban,
  repo: Demo.Repo,
  queues: [aurora_meter: 2, mailers: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 4 * * *", AuroraMeter.Oban.CreditExpiry},
       {"@daily", Demo.Workers.Nightly},
       {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation}
     ]}
  ]
```

**One line added and nothing else touched.** The concurrency is still 2, the
`mailers` queue is still there, `Oban.Plugins.Pruner` is still first, the host's
four-in-the-morning expiry schedule is intact, and there is no second entry for
`CreditExpiry` beside it. The test asserts the absence as well as the presence
(`refute config =~ "aurora_meter: 5"`), because `assert config =~ "aurora_meter: 2"`
alone would pass a config that had gained both.

## 3. The second run is byte identical

Measured by applying the first run and composing the task again on the applied
project. Composing twice into one igniter and asserting `assert_unchanged/1`
would prove nothing: the first composition's own changes are still in it.

```
Igniter.changed?(second) -> false
config/config.exs:       byte identical after the second run -> true
lib/demo/application.ex: byte identical after the second run -> true
lib/demo/plans.ex:       byte identical after the second run -> true
```

A **third** run is asserted too, in both packages' installer tests: a task that
is idempotent once can still drift on the next.

## 4. The Pro installer

`mix aurora_meter_pro.install --repo Demo.Repo` on a bare project:

```elixir
config :demo,
       Oban,
       repo: Demo.Repo,
       queues: [aurora_meter: 5],
       plugins: [
         {Oban.Plugins.Cron,
          crontab: [
            {"*/5 * * * *", AuroraMeter.Pro.UsageReporter},
            {"*/5 * * * *", AuroraMeter.Pro.Outbox.Deliverer},
            {"*/10 * * * *", AuroraMeter.Pro.Outbox.Reconciler},
            {"*/10 * * * *", AuroraMeter.Pro.Alerts},
            {"15 2 * * *", AuroraMeter.Pro.Rollup},
            {"30 3 * * *", AuroraMeter.Pro.AuditLog.Pruner},
            {"*/5 * * * *", AuroraMeter.Pro.Credits.AutoTopUpSweeper}
          ]}
       ]

config :aurora_meter_pro,
  webhook_secret: {:system, "STRIPE_WEBHOOK_SECRET"},
  stripe_account_id: {:system, "STRIPE_ACCOUNT_ID"},
  stripe_mode: :test,
  stripe_prices: %{},
  stripe_meters: %{}
```

Seven entries, which is X185's nine workers less the two that are never
scheduled (`AutoTopUpWorker` is event driven, `Credits.Expirer` is a deprecated
shim for a core worker the core registry already schedules).

`Igniter.changed?(pro_second) -> false`.

### The refusal

With both expiry workers in the host's crontab, the task stops rather than
writing:

```
issues: 1
config/config.exs schedules both AuroraMeter.Oban.CreditExpiry and
AuroraMeter.Pro.Credits.Expirer.
...
Keep the core worker and remove the Pro entry, which is deprecated and is a
shim for it. Then run this task again.
```

and the test asserts the refusal is a refusal: `refute source(igniter, @config)
=~ "AuroraMeter.Pro.UsageReporter"`, so the task did not add its entries beside
a warning about them.

### The secret scan

Every file in the generated tree, not only the config:

```
.formatter.exs                       key-shaped string: nil
README.md                            key-shaped string: nil
config/config.exs                    key-shaped string: nil
lib/demo.ex                          key-shaped string: nil
lib/demo/application.ex              key-shaped string: nil
mix.exs                              key-shaped string: nil
priv/repo/migrations/..._add_aurora_meter_pro.exs  key-shaped string: nil
test/demo_test.exs                   key-shaped string: nil
test/test_helper.exs                 key-shaped string: nil
```

The pattern is built from parts in the test (`Enum.join(["sk", "pk", "whsec"],
"|")`) so that **the test file itself contains no literal a secret scanner would
flag**. The task makes no network call of any kind: it does not ask Stripe
whether the account exists, because that is `AuroraMeter.Pro.validate!/0`'s job
at boot and a Mix task that reaches the internet is a Mix task that fails on a
train.

## 5. `--check-support`

```
Aurora Meter support check

  elixir             1.20.1          floor 1.15.8    ok
  erlang/otp         29              floor 25        ok
  postgres           not installed   floor 13        not checked  - reading a server
      version means connecting to it, which this check does not do.
  ecto_sql           3.14.0          floor 3.10.0    ok
  postgrex           0.22.4          floor 0.0.0     ok
  phoenix_pubsub     2.3.0           floor 2.1.0     ok
  telemetry          1.4.2           floor 1.2.0     ok
  jason              1.4.5           floor 1.4.0     ok
  nimble_options     1.1.1           floor 1.1.0     ok
  phoenix_live_view  1.2.11          floor 0.20.0    ok
  igniter            0.8.4           floor 0.8.0     ok
  oban               2.23.0          floor 2.17.0    ok

supported? -> true
```

**The Postgres row does not say "ok" and that is the point.** The build document
asks for the version "from the repo's configuration, not by connecting". A repo's
configuration carries a host, a port and a database name; it does not carry the
server's version, and the only way to learn one is to ask the server. An
installer that opened a connection to a host's production database to tell it
about compatibility would have done something the host did not ask for. So the
floor is printed, the reason is printed, and the check is the host's to run.
That is a deviation from the document, recorded here and in `open-findings.md`.

The exit code is non-zero when something **present** is below its floor; an
absent optional dependency is not a failure, which is the whole point of it
being optional (I20). `Support.supported?/1` is tested directly against
synthetic rows for both cases, because a host that is genuinely below a floor is
not something this machine can be made into.

## 6. `--dry-run`

**Not implemented, because Igniter already implements it**, as a global switch
every task inherits (`deps/igniter/lib/mix/task/info.ex`'s `@global_options`),
and `Igniter.do_or_dry_run/2` prints the diff and writes nothing. Declaring
`dry_run` in either task's own `schema` would be a second flag with the same
name; `Igniter.Mix.Task.Info` tracks `flag_conflicts` for exactly that case.

Both tasks document it as Igniter's, and each has a test asserting the two
halves of the claim: the task's schema does **not** declare `dry_run`, and
Igniter's global switches **do**. `open-findings.md` X192.

## 7. What made this hard, recorded so 09b and 11a do not repeat it

**Sourceror wraps every literal in a one-child `:__block__`.** A list item, a
tuple element and a keyword value all arrive wrapped, so a predicate written
against the bare shape never fires. The first draft of `--oban` matched
`{module, opts}` for the Cron plugin; `Igniter.Code.List.move_to_list_item/2`
answered `:error` every time, and the `:error` branch **appends**, so every run
added another `Oban.Plugins.Cron` plugin. Measured: a project with one plugin
had three after two runs.

The dangerous property is that the wrong predicate fails **open**. Nothing
raises, the task reports success, and the host's configuration grows a duplicate
plugin per run. `open-findings.md` X194.

Second half of the same lesson: `Igniter.Code.Keyword.set_keyword_key/4` re-wraps
whatever node its updater returns as the key's **value**, so an updater that
hands back a zipper from deeper in the tree replaces the whole list with that one
node. `Igniter.Code.Common.within/2` is what makes an updater come back to where
it started.

## 8. A known gap

In a project that has **not** run `mix aurora_meter.install` first, the Pro
installer adds `AuroraMeter.Pro` to the children and there is no `AuroraMeter`
for its `after:` predicate to sit behind, so the child list reads
`children = [AuroraMeter.Pro]`. The host's boot then fails with core's own
configuration error, which is the right failure in the wrong place: a notice
saying "run `mix aurora_meter.install` first" would be better. Recorded rather
than added, because an untested branch in an installer is worse than a documented
gap (`open-findings.md` X204).

## Commands

| Command | Exit |
|---|---|
| `mix test test/mix/tasks/install_test.exs` (core) | 0, 14 passed |
| `mix test test/mix/tasks/pro_install_test.exs` (Pro) | 0, 8 passed |
| `mix run --no-start tmp/v1/05c/capture-installers.exs` | 0, output in `05c-installers.log` |
