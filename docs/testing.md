# Testing

Aurora Meter ships a test helper, `AuroraMeter.Test`, so your suite does not
have to know how the runtime works.

```elixir
defmodule MyApp.MeterCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use MyApp.DataCase              # your usual Ecto sandbox
      use AuroraMeter.Test            # imports the helpers below
    end
  end
end
```

Set large intervals in test config so the timers never fire mid-test, and
drive them explicitly:

```elixir
# config/test.exs
config :aurora_meter, flush_interval: 60_000, broadcast_interval: 60_000
```

```elixir
AuroraMeter.Test.flush!()          # persists dirty counters, returns the count
AuroraMeter.Test.broadcast!()      # broadcasts touched counters (and gossips deltas)
```

## Isolation

Counters live in a shared ETS table. Either give each test a unique tenant key
(the default recommendation, works with `async: true`):

```elixir
tenant = AuroraMeter.Test.unique_tenant()
```

or clear the tables before each test (requires `async: false`):

```elixir
use AuroraMeter.Test, reset: true   # setup :reset_aurora_meter
# or
AuroraMeter.Test.reset!()
```

`reset!/0` discards unflushed usage and never touches the database.

## Sandbox

The flusher and broadcaster are background processes, so tests that flush must
use **shared** sandbox mode (the standard `DataCase` pattern:
`Sandbox.start_owner!(Repo, shared: not tags[:async])`). If your case template
does not already do that, `use AuroraMeter.Test, sandbox: true` starts an owner
on the configured repo.

## Asserting live updates

```elixir
AuroraMeter.LiveView.subscribe(tenant)
AuroraMeter.track(tenant, :ai_generations, 3)
AuroraMeter.Test.broadcast!()
assert_receive {:aurora_meter, :usage, %{feature: :ai_generations, value: 3}}
```

## Credits

`fund!/3` grants with a unique reference (category `:adjustment`) so a test
never trips the idempotency check, `drain!/1` debits whatever is available and
`credit_balance/1` reads the snapshot:

```elixir
fund!(tenant, Money.from_cents(1_000))
{:ok, _} = AuroraMeter.Credits.hold(tenant, 250_000, "job:1")
assert credit_balance(tenant).available == 9_750_000
drain!(tenant)
```

Ledger tests can be `async: true` with unique tenants: each write is its own
transaction on the tenant's row, and the sandbox isolates the rows.

## Simulating other nodes

Cluster behaviour can be exercised on one node:

```elixir
AuroraMeter.track(tenant, :ai_generations, 2)

# another node gossips 5 increments
AuroraMeter.Test.simulate_node(:"web@10.0.0.2", [{tenant, :ai_generations, 5}])
assert AuroraMeter.usage(tenant, :ai_generations) == 7

# another node flushes and announces the database total
AuroraMeter.Test.simulate_flush(:"web@10.0.0.2", [{tenant, :ai_generations, 40}])
assert AuroraMeter.usage(tenant, :ai_generations) == 42   # 40 + our unflushed 2
```

See the [clustering guide](clustering.md) for what these messages mean.
