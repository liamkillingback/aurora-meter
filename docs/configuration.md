# Configuration

All configuration lives under the `:aurora_meter` application key and is
validated at boot by `AuroraMeter.Config.validate!/0` (called from
`AuroraMeter.start_link/1`), which raises on a missing required key or wrong type.

| Key | Type | Required | Default |
|---|---|---|---|
| `:repo` | Ecto repo module | ✅ | — |
| `:pubsub` | `Phoenix.PubSub` server name | ✅ | — |
| `:plans` | module using `AuroraMeter.Plans` | ✅ | — |
| `:tenant` | `AuroraMeter.Tenant` impl | — | `AuroraMeter.Tenant.Default` |
| `:default_plan` | atom | — | `:free` |
| `:storage` | `AuroraMeter.Storage` impl | — | `AuroraMeter.Storage.Ecto` |
| `:provider` | `AuroraMeter.Billing.Provider` impl | — | `AuroraMeter.Billing.Noop` |
| `:period_source` | `AuroraMeter.Period` impl | — | `AuroraMeter.Period.Calendar` |
| `:durable_features` | list of atoms | — | `[]` |
| `:flush_interval` | ms | — | `5_000` |
| `:broadcast_interval` | ms | — | `1_000` |

```elixir
config :aurora_meter,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  plans: MyApp.Plans,
  default_plan: :free,
  durable_features: [:ai_generations],
  flush_interval: 5_000,
  broadcast_interval: 1_000
```

## Tenants

A tenant can be any term; it is resolved to a stable string key by the configured
`AuroraMeter.Tenant` implementation (`to_string/1` by default). For structs,
provide your own:

```elixir
defmodule MyApp.MeterTenant do
  @behaviour AuroraMeter.Tenant
  @impl true
  def to_key(%MyApp.Org{id: id}), do: "org:#{id}"
end

config :aurora_meter, tenant: MyApp.MeterTenant
```
