# Entitlements

Gate actions on the tenant's plan and live usage.

> **The `tenant` argument.** Every call takes the tenant first: the organisation
> or account being metered (`"org_42"`, an integer id, or your own struct through
> a configured `AuroraMeter.Tenant`). It must be stable and unique per customer.
> See "What `org` is" in the README and the `:tenant` option in
> [Configuration](configuration.md).

```elixir
AuroraMeter.check(tenant, :ai_generations)
# :ok
# {:error, :limit_exceeded}   # hard cap reached
# {:error, :not_entitled}     # feature disabled on the plan
```

## Semantics

| Plan config | `check/2` |
|---|---|
| `limit f, n, :hard` | `:ok` until usage reaches `n`, then `{:error, :limit_exceeded}` |
| `metered f, ...` | always `:ok` (overage is billed) |
| `feature f, true` | `:ok` |
| `feature f, false` | `{:error, :not_entitled}` |
| undeclared | `:ok` (permissive; logs a warning in `:dev`) |

Helpers:

```elixir
AuroraMeter.allowed?(tenant, feature)     # boolean (check == :ok)
AuroraMeter.entitled?(tenant, feature)    # plan grants access at all?
AuroraMeter.remaining(tenant, feature)    # non_neg_integer | :unlimited
```

## Subscription status

A subscription grants its plan only while its `status` is one of
`AuroraMeter.Schema.Subscription.entitled_statuses/0` (`active`, `trialing`,
`past_due`). Any other status — `canceled`, `unpaid`, `incomplete`, ... — falls
back to the configured `:default_plan`, so a cancellation synced from the
billing provider revokes access without a separate downgrade step.

## quota — everything a dashboard needs

```elixir
AuroraMeter.quota(tenant, :ai_generations)
# %{feature: :ai_generations, kind: :hard, used: 812, limit: 1_000, included: 1_000,
#   remaining: 188, overage: 0, percent: 81, period: %{start: ..., end: ..., source: :calendar},
#   enabled: true, unit_price: nil}
```

`kind` is `:hard`, `:metered`, `:boolean` or `:undeclared`; metered features
report `included`, `unit_price` and `overage` instead of `limit`/`remaining`.

## with_quota — gate, run, meter, atomically

`check/2` then `track/3` has a race: two concurrent requests can both pass a
near-full hard limit. Use `with_quota/4`, which reserves atomically:

```elixir
case AuroraMeter.with_quota(tenant, :ai_generations, fn -> generate() end) do
  {:ok, result} -> result
  {:error, :limit_exceeded} -> upgrade_prompt()
  {:error, :not_entitled} -> upgrade_prompt()
end
```

It increments the counter (the reservation *is* the usage), runs the function,
and — if the function raises — releases the reservation before re-raising. Under
concurrency, a hard limit of `n` admits exactly `n` reservations.
