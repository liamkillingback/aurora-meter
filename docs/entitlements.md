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
| `counter f` | always `:ok` (measured, never billed) |
| `feature f, true` | `:ok` |
| `feature f, false` | `{:error, :not_entitled}` |
| `feature f, n` (integer) | `:ok`: a plan value, read with `feature_value/3` |
| not declared on the plan | follows `:undeclared_feature_policy` (see below) |

Helpers:

```elixir
AuroraMeter.allowed?(tenant, feature)     # boolean (check == :ok)
AuroraMeter.entitled?(tenant, feature)    # plan grants access at all?
AuroraMeter.remaining(tenant, feature)    # non_neg_integer | :unlimited
AuroraMeter.feature_value(tenant, :seats, 1)  # the plan's value (boolean or integer), else 1
```

## Features the plan does not declare

Until 0.5.0 an undeclared feature was permitted, silently, with a warning that
only existed in a build compiled in `:dev`. That meant a misspelled feature name
granted access for the life of the install. `:undeclared_feature_policy`
(`:allow | :warn | :deny | :raise`) now decides:

```elixir
# Keep the 0.4.x behaviour exactly:
config :aurora_meter, undeclared_feature_policy: :allow
```

The default is `:warn` in the 0.5.x transition release and `:deny` from 1.0. The
full table, the upgrade sequence and the scanner that lists what would change are
in [Configuration](configuration.md#undeclared_feature_policy).

Two things worth knowing here. "Undeclared" means *not on this tenant's plan*, so
a `:free` tenant asking about a `:pro` only feature is undeclared, which is the
case the policy exists for. And `AuroraMeter.track/4` keeps counting either way:
metering is not entitlement.

Under `:deny`, `remaining/2` returns `0` rather than `:unlimited`. The documented
return type is `non_neg_integer() | :unlimited`, and `0` is the honest number
when nothing is entitled, so a renderer that draws "0 left" is correct.

## Subscription status

A subscription grants its plan only while its `status` is one of
`AuroraMeter.Schema.Subscription.entitled_statuses/0` (`active`, `trialing`,
`past_due`). Any other status (`canceled`, `unpaid`, `incomplete`, and so on) falls
back to the configured `:default_plan`, so a cancellation synced from the
billing provider revokes access without a separate downgrade step.

## quota: everything a dashboard needs

```elixir
AuroraMeter.quota(tenant, :ai_generations)
# %{feature: :ai_generations, kind: :hard, used: 812, limit: 1_000, included: 1_000,
#   remaining: 188, overage: 0, percent: 81, period: %{start: ..., end: ..., source: :calendar},
#   enabled: true, unit_price: nil}
```

`kind` is `:hard`, `:metered`, `:counter`, `:boolean`, `:feature` (an integer
plan value, carried in `value`) or `:undeclared`; metered features report
`included`, `unit_price` and `overage` instead of `limit`/`remaining`.

### Counters have no denominator

```elixir
AuroraMeter.quota(tenant, :requests)
# %{feature: :requests, kind: :counter, used: 6, limit: nil, included: nil,
#   overage: 0, remaining: :unlimited, percent: nil,
#   period: %{start: ..., end: ..., source: :calendar}, enabled: true, unit_price: nil}
```

`percent: nil` is deliberate, and so are `limit: nil` and `included: nil`.
**Anything rendering a bar must treat `nil` as "no bar", never as `0`**: a
counter has nothing to be a percentage *of*, and "0% of 0" is exactly the
reading this kind exists to prevent. `AuroraMeter.Components.usage_meter/1`
renders a counter as a bare count with no progress bar; do the same in your own
renderer. See [ADR 0006](adr/0006-counter-feature-kind.md).

`reserve/3` and `with_quota/4` still increment a counter (they simply never
refuse it), so the count stays correct under any load.

## with_quota: gate, run, meter, atomically

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
and, if the function raises, releases the reservation before re-raising. Under
concurrency, a hard limit of `n` admits exactly `n` reservations.

### Over a feature whose source is `:events`

For a feature configured `feature_sources: %{name => :events}` (see
[metering](metering.md)) the gate is unchanged and the reservation is still
strict on this node, but the reservation is **released** on success as well as on
failure. It is admission control and nothing else: the billable fact is whatever
`AuroraMeter.record/4` committed, and committing the reservation too would charge
your estimate on top of the recorded quantity.

The recipe is to record inside the callback:

```elixir
AuroraMeter.with_quota(org, :tokens, estimate, fn ->
  {:ok, result} = do_work()

  {:ok, _event, _outcome} =
    AuroraMeter.record(org, :tokens, result.tokens,
      id: result.request_id,
      occurred_at: result.finished_at
    )

  result
end)
```

The in-memory arithmetic over that sequence is `+estimate` at admission,
`+result.tokens` from the projection, `-estimate` at release, so the value nets
to the durable total. While the callback runs, every other caller sees the
estimate held, which is the point of the gate.

Two differences to plan around:

  * **The cap counts what is in flight, plus what has been recorded.** For a
    buffered feature an admitted call keeps its unit for the rest of the period.
    Here a call that records nothing gives its estimate straight back, because
    nothing was used.
  * **`reserve/2,3` raises** for these features. It bills what it reserves
    immediately, which would be the second count. Use `with_quota/4`, or
    `check/2` to ask without reserving.

A caller killed with `Process.exit(pid, :kill)` runs no release, so its estimate
stays held on that node until the Store restarts or the period rolls over. That
is the same documented local-quota leak buffered features have, and on this path
it cannot become a charge at all.
