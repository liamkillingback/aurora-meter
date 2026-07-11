# Getting started

Aurora Meter meters usage, enforces plan entitlements, and (with the Pro package)
bills via Stripe — from inside your Phoenix app.

## 1. Add the dependency

```elixir
def deps do
  [{:aurora_meter, "~> 0.1"}]
end
```

## 2. Create the tables

```bash
mix aurora_meter.gen.migration -r MyApp.Repo
mix ecto.migrate
```

This generates a thin migration that delegates to `AuroraMeter.Migration`.

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

# application.ex — after the Repo and PubSub
children = [MyApp.Repo, {Phoenix.PubSub, name: MyApp.PubSub}, AuroraMeter]
```

Aurora Meter validates its configuration at boot and raises immediately on a
missing or mistyped key.

## 5. Meter and gate

```elixir
AuroraMeter.subscribe(org, :free)
AuroraMeter.track(org, :api_calls)
AuroraMeter.check(org, :api_calls)   # :ok | {:error, :limit_exceeded}
```

Next: [Metering](metering.md) · [Entitlements](entitlements.md) ·
[Configuration](configuration.md).
