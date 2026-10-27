# Getting started

Aurora Meter meters usage, enforces plan entitlements, and (with the Pro package)
bills via Stripe, from inside your Phoenix app.

## 1. Add the dependency

```elixir
def deps do
  [{:aurora_meter, "~> 1.0"}]
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
| `--feature-policy deny\|raise\|warn\|allow` | What happens when code asks about a feature no plan declares. `deny` is the default for a new install. An **existing** install upgrading from 0.4 wants `warn` first, then `mix aurora_meter.features` until it reports nothing, then `deny`. |
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

The installer adds `AuroraMeter` to the child list for you, after the Repo and
PubSub and before `MyAppWeb.Endpoint`, which needs Igniter 0.8.5 or later
(earlier 0.8 releases put it after the endpoint; move it up by hand if you see
that). It also writes `config/test.exs` timers so no flush or broadcast fires
mid-test, and adds `:aurora_meter` to `import_deps` in `.formatter.exs` so
`mix format` keeps the plans DSL free of parentheses.

Aurora Meter validates its configuration at boot and raises immediately on a
missing or mistyped key. A `:repo` naming a module that does not exist, or a
`:pubsub` that is the `Phoenix.PubSub` module rather than your server's name, is
refused with the key, the value given and an example.

## Phoenix 1.8 (phx.gen.auth scopes)

A Phoenix 1.8 application generated with `mix phx.gen.auth` assigns
`@current_scope`, a `%MyApp.Accounts.Scope{}`. Tell Aurora Meter which customer
a scope bills (the user here; use `scope.org.id` if your scope carries an
organisation):

```elixir
defmodule MyApp.AuroraTenant do
  @behaviour AuroraMeter.Tenant

  @impl true
  def to_key(%MyApp.Accounts.Scope{user: %{id: id}}), do: "user_#{id}"
  def to_key(key) when is_binary(key), do: key
end

# config/config.exs
config :aurora_meter, tenant: MyApp.AuroraTenant
```

```elixir
# router.ex, after the hook that assigns the scope
live_session :require_authenticated_user,
  on_mount: [
    {MyAppWeb.UserAuth, :require_authenticated},
    {AuroraMeter.LiveView, {:subscribe, assign: :current_scope}}
  ] do
  # your live routes
end
```

Then pass `socket.assigns.current_scope` (or `conn.assigns.current_scope`)
wherever these guides write `org`. Without the resolver, the default raises an
`ArgumentError` that shows this recipe.

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

## Using an AI coding agent

The package ships `usage-rules.md`, a short list of do and don't for agents
writing code against Aurora Meter. With
[usage_rules](https://hexdocs.pm/usage_rules) in your dev deps and
`usage_rules: [file: "AGENTS.md", usage_rules: [:aurora_meter]]` in your
`mix.exs` project config, `mix usage_rules.sync` copies it into your project's
agent instructions.

## Charging for it

Charging for it: Aurora Meter Pro adds Stripe checkout, top-ups, auto-recharge
and metered invoicing: https://aurorameter.com/pro

Next: [Metering](metering.md) · [Entitlements](entitlements.md) ·
[Configuration](configuration.md).
