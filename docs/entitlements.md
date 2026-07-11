# Entitlements

Gate actions on the tenant's plan and live usage.

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
