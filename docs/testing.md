# Testing

Aurora Meter works with the standard `Ecto.Adapters.SQL.Sandbox`. Because the
flusher and broadcaster are background processes, use **shared** sandbox mode (or
allowances) in tests that flush.

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
```

## Determinism

- Set large `:flush_interval` / `:broadcast_interval` in test config so the timers
  don't fire mid-test, and drive them explicitly:

  ```elixir
  AuroraMeter.Flusher.flush()          # {:ok, persisted_count}
  AuroraMeter.Broadcaster.broadcast_now()
  ```

- Counters live in a shared ETS table. Give each test a unique tenant key so tests
  stay isolated and can run `async: true`:

  ```elixir
  tenant = "org_#{System.unique_integer([:positive])}"
  ```

## Asserting live updates

```elixir
AuroraMeter.LiveView.subscribe(tenant)
AuroraMeter.track(tenant, :ai_generations, 3)
AuroraMeter.Broadcaster.broadcast_now()
assert_receive {:aurora_meter, :usage, %{feature: :ai_generations, value: 3}}
```
