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

## Maintaining Aurora Meter itself: the fault harness

Everything above is for hosts. This section is for maintainers of this
repository, and describes `test/support/aurora_meter/test/`, which ships in no
Hex archive and is no part of the public surface.

Seven modules:

| Module | What it is for |
|---|---|
| `AuroraMeter.Test.Faults` | arming, matching, firing and the fired log |
| `AuroraMeter.Test.FaultStorage` | an `AuroraMeter.Storage` shim that can fail at a callback boundary |
| `AuroraMeter.Test.FaultRepo` | a repo shim that can fail one statement inside the real transaction |
| `AuroraMeter.Test.Connections` | N independent non-sandbox connections, and prefix-bounded cleanup |
| `AuroraMeter.Test.Kill` | kills a worker at a chosen point and observes the death |
| `AuroraMeter.Test.Config` | `with_config/2` and `put_config/1`, the only way to change configuration in a test |
| `AuroraMeter.Test.Clock` | a settable clock. Temporary: build unit 02c deletes it |

### The seven points

`:before_commit`, `:after_commit_before_ack`, `:after_claim`,
`:after_provider_accept`, `:before_ack_persist`, `:during_shutdown`,
`:during_recovery`. Arming anything else raises and names the valid set.

`FaultStorage` checks `:before_commit` before, and `:after_commit_before_ack`
after, every one of the twelve storage callbacks, with `callback:` in the
context. `FaultRepo` checks `:before_commit` before every statement, with
`statement:`, `schema:`, `repo_fun:` and `kind:` (`:read` or `:write`) in the
context, and `:after_commit_before_ack` after the outermost transaction
commits. The remaining points are wired by Pro's outbox and recovery units.

### The four actions

| Action | Effect |
|---|---|
| `:raise` | raises `AuroraMeter.Test.Faults.Injected` |
| `:exit_kill_self` | `Process.exit(self(), :kill)`, untrappable, at the check |
| `{:block_until, ref}` | rendezvous with the owner, then wait for the release, raising `AuroraMeter.Test.Faults.Timeout` if it never comes |
| `{:delay, ms}` | the only sanctioned sleep |

### Ownership

A fault belongs to the process that armed it and to every process whose
`$callers` chain contains that process. `Task`, `Task.Supervisor` and
`Task.async_stream` set `$callers`; a bare `spawn/1` and a `GenServer.call/3`
do not, so a fault meant for a server names `owner:` explicitly, and `fired/1`
and `assert_fired!/2` take the same option.

### Three rules, enforced in review

1. **Assert the fault fired.** Every test that arms a fault calls
   `AuroraMeter.Test.Faults.assert_fired!/2`. A test that arms a fault, drifts
   off the call path and then passes because the fault never ran is
   indistinguishable from a proof.
2. **No new `Process.sleep/1` in a test.** A race is manufactured with
   `{:block_until, ref}` and a rendezvous message. The one exception is a
   `{:delay, ms}` fault for a wall-clock horizon the clock seam cannot reach,
   and it carries a written reason.
3. **Assert database totals, not task return values.** A test on independent
   connections reads the rows back; twelve tasks all returning `{:ok, _}`
   proves nothing about what was committed.

And two more. **Every module that exercises a fault point carries
`@moduletag :fault`**, so `mix v1.faults` (`test --only fault --seed 0`, added
by build unit 01f and wired into CI) runs it; without the tag it silently drops
out of the lane that exists to run it. And **every configuration change goes
through `AuroraMeter.Test.Config`.** `Application.put_env/3` with a hand-written
`on_exit` loses the race when the test process is killed, and silently overlaps
when two modules touch the same key.

### Independent connections

```elixir
tenant = AuroraMeter.Test.unique_tenant("flush_batch")
on_exit(fn -> AuroraMeter.Test.Connections.cleanup!(tenant) end)

AuroraMeter.Test.Connections.run(12, fn _index ->
  AuroraMeter.Storage.flush_batch(id, counters, history)
end)

assert AuroraMeter.Storage.load_counter(tenant, :ops, period) == 5
```

`cleanup!/1` refuses a prefix shorter than four characters, and one that is
neither a `unique_tenant/1` value nor a prefix registered with
`register_prefix/1`. It deletes by `left(tenant_key, n) = prefix`, so a tenant
key that is a strict prefix of another test's key would take both: give the two
different prefixes rather than relying on the unique integer.

`run/3` refuses more tasks than the pool can serve, with the arithmetic in the
error message. `aurora_meter_flush_receipts` carries no `tenant_key`, so a test
that writes one deletes it by id itself.

### Killing a supervised process

`AuroraMeter.Test.Kill.run/2` kills a worker at a fault point.
`AuroraMeter.Test.Kill.await_restart!/2` is for the other kind of kill, a
supervised named process:

```elixir
pid = Process.whereis(AuroraMeter.Store)
reference = Process.monitor(pid)
Process.exit(pid, :kill)
assert_receive {:DOWN, ^reference, :process, ^pid, :killed}
Kill.await_restart!(AuroraMeter.Store, from: pid)
```

Two things it does that a hand-written wait does not. It waits past the *old*
pid, which is why `:from` is passed after the kill: a supervisor can restart a
child before the test process is scheduled again, and a bare
`Process.whereis/1` would then be waiting for the replacement to be replaced.
And it waits for the new process to be **ready**, not merely registered:
`:gen_server` registers the name before it calls `init/1`, and
`AuroraMeter.Store` creates its five ETS tables inside `init/1`, so a test that
returned on the registration could read `:aurora_meter_flush_batches` before it
existed. `await_restart!/2` blocks on a synchronous system call, which a
`GenServer` does not answer until `init/1` has returned.

Assert the `:DOWN` reason is exactly `:killed`. A catchable exit is not process
death, and a test that cannot tell them apart proves nothing about either.

**Mind the restart budget.** `AuroraMeter.Supervisor` is `one_for_one` with
OTP's defaults: three restarts in five seconds, and the fourth takes the
supervisor down along with every test that follows.
`AuroraMeter.KillTest` spends all three. A new kill test either replaces one of
those or gives itself a supervisor of its own, as
`AuroraMeter.Test.HarnessTest` does for the `await_restart!/2` self-test.
`Supervisor.restart_child/2`, which `AuroraMeter.FlusherTest` uses, is a manual
restart and does not count.

### A non-sandbox module discards, it does not drain

A module that runs on real connections must never start by calling
`AuroraMeter.Flusher.flush/0` to clear the decks. The flusher takes *every*
dirty key, including the ones a sandbox-based module left pending, and on a
real connection those commit for good under that module's `org_<n>` tenant
keys. `System.unique_integer/1` starts again at the same values in the next
`mix test`, so the committed rows seed a later run's counters and it fails for a
reason that appears nowhere in its own file.

Use `AuroraMeter.Test.reset!/0` instead. It throws the buffered deltas away and
touches no database row, which is exactly what a non-sandbox module wants, and
it is safe because such a module is `async: false` and ExUnit runs synchronous
modules one at a time.

### When a shim stops covering production

Two self-tests in `test/aurora_meter/test/harness_test.exs` fail rather than
letting a proof go quiet:

- `AuroraMeter.Test.FaultRepo.uncovered_call_sites(["lib"])` parses `lib/`
  and reports every `repo().fun(...)`, `repo.fun(...)` and
  `Config.repo().fun(...)` call site the shim does not export. A new call site
  in production fails the harness test.
- `AuroraMeter.Test.FaultStorage.uncovered_callbacks/1` reports every
  `AuroraMeter.Storage` callback the shim does not wrap with a `Faults.check/2`
  call. A new callback, or a shim callback that loses its checks, fails the
  harness test.

### The test clock is temporary

`AuroraMeter.Test.Clock` exists only until build unit 02c lands the real clock
seam (`AuroraMeter.Clock`, configuration key `clock:`), which deletes it. Until
then, a test that needs the library to see a different instant passes one
explicitly to the function that already takes one (`Credits.expire_due/1`,
`Period.current/2`) and says so in a comment.
