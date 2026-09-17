# Getting started

Aurora Meter meters usage, enforces plan entitlements, and (with the Pro package)
bills via Stripe, from inside your Phoenix app.

## 1. Add the dependency

```elixir
def deps do
  [{:aurora_meter, "~> 1.0"}]
end
```

While 1.0.0 is still a release candidate, that requirement resolves nothing: a
`~>` requirement never admits a pre-release. Pin the candidate to try it:

```elixir
def deps do
  [{:aurora_meter, "1.0.0-rc.1"}]
end
```

## 2. Install

With [Igniter](https://hexdocs.pm/igniter) in your dev deps, one command does
steps 2 to 4 (config, supervision child, a starter plans module, the migration):

```bash
mix igniter.install aurora_meter
mix ecto.migrate
```

`mix igniter.install aurora_meter` adds the dependency and then runs
`mix aurora_meter.install`. Once the dependency is already in `mix.exs`, run
that task directly:

```bash
mix aurora_meter.install --repo MyApp.Repo
```

Either way it is the same task, and it takes four switches. Two of them are
worth a minute now, because **both are created and never changed**: a second run
on a host that already sets them keeps what the host has, says so, and names
what a fresh install would have been given.

| Switch | What it decides |
|---|---|
| `--feature-policy deny\|raise\|warn\|allow` | What happens when code asks about a feature no plan declares. `deny` is the default for a new install. An **existing** install upgrading to 0.5 wants `warn` first, then `mix aurora_meter.features` until it reports nothing, then `deny`. |
| `--events-source <feature>:events\|buffered` | Which features are recorded durably through `AuroraMeter.record/4` and projected, rather than counted through `AuroraMeter.track/4`. A feature has exactly one reporting source, and `track/4` raises for one listed as `events`. Pass it once per feature. See [Metering](metering.md). |
| `--oban` | Wires Aurora Meter's optional workers into your own Oban instance: the `aurora_meter` queue, the `Oban.Plugins.Cron` plugin and the recommended crontab, adding only what is missing. It needs `{:oban, "~> 2.17"}` in your deps; without one it refuses and says so. |
| `--check-support` | Prints what this host resolves against Aurora Meter's declared floors and exits non-zero when something present is below one. Writes nothing and connects to nothing. |

Igniter's own `--dry-run` shows the change set and writes nothing, in a script
as well as at a prompt. A refusal (a value that is not one of the above, `--oban`
without Oban) writes **nothing at all** and exits 1, so
`mix aurora_meter.install ... || exit 1` behaves.

Without Igniter, generate the migration and follow the printed steps:

```bash
mix aurora_meter.gen.migration -r MyApp.Repo
mix ecto.migrate
```

`mix aurora_meter.install` works without Igniter too. It writes no
configuration, because there is no Igniter to write it: it generates the
migration and prints the block to paste, including whatever
`--feature-policy` and `--events-source` you passed.

This generates a thin migration that delegates to `AuroraMeter.Migration`, which
is versioned: when a later release adds tables, run
`mix aurora_meter.gen.migration -r MyApp.Repo --from N` for a migration that
applies only the new versions.

## 3. Define plans

See [Plans](plans.md). Minimal example:

```elixir
defmodule MyApp.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :api_calls, 1_000, :hard
  end
end
```

## 4. Configure and start

```elixir
# config/config.exs
config :aurora_meter, repo: MyApp.Repo, pubsub: MyApp.PubSub, plans: MyApp.Plans

# application.ex, after the Repo and PubSub
children = [MyApp.Repo, {Phoenix.PubSub, name: MyApp.PubSub}, AuroraMeter]
```

The installer adds `AuroraMeter` to the child list for you. **Check where it put
it**: in a `mix phx.new` application it currently lands at the end of the list,
after the endpoint, and you want it before. A request arriving between the
endpoint accepting connections and Aurora Meter's tables existing has no table
to read. Move the line above `MyAppWeb.Endpoint` and the window is gone.

Aurora Meter validates its configuration at boot and raises immediately on a
missing or mistyped key.

## 5. Meter and gate

```elixir
AuroraMeter.subscribe(org, :free)
AuroraMeter.track(org, :api_calls)
AuroraMeter.check(org, :api_calls)   # :ok | {:error, :limit_exceeded}
```

`org` is your tenant: the organisation or account being metered. Strings,
integers and atoms work as they are; pass your own struct by configuring a
`tenant:` module that implements `AuroraMeter.Tenant` (see the README section
"What `org` is"). Subscribe and track with the same term.

Next: [Metering](metering.md) · [Entitlements](entitlements.md) ·
[Configuration](configuration.md).
