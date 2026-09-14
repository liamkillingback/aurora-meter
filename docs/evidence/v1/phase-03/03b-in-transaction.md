# 03b: what `repo.in_transaction?/0` reports, and therefore what `host_transaction?/0` is

Build unit 03b's document warned that a connection checked out from
`Ecto.Adapters.SQL.Sandbox` "may report `true` without a host transaction", and
required the implementation to be decided by measurement rather than by reading
the documentation. If that warning were true, `host_transaction?/0` would need a
sandbox carve-out, and every sandbox-based test would otherwise take the
conditional path and never hydrate the in-memory projection or publish.

**It is not true on ecto_sql 3.14.0.**

## The measurement

Probe `tmp/v1/03b/probe_in_transaction.exs`, log
`tmp/v1/03b/logs/in-transaction.txt`, 2026-09-14. ecto_sql 3.14.0, ecto 3.14.1,
Elixir 1.20.1, OTP 29. The repo's configured pool is
`Ecto.Adapters.SQL.Sandbox` in every row below; that is the test configuration
and it does not change between them.

| Connection | Position | `repo.in_transaction?/0` |
|---|---|---|
| none checked out | outside | `false` |
| `Sandbox.checkout(repo)` (sandbox: true) | outside any `Repo.transaction` | **`false`** |
| `Sandbox.checkout(repo)` | inside one `Repo.transaction` | `true` |
| `Sandbox.checkout(repo)` | inside a nested `Repo.transaction` | `true` |
| `Sandbox.checkout(repo, sandbox: false)` | outside any `Repo.transaction` | `false` |
| `Sandbox.checkout(repo, sandbox: false)` | inside one `Repo.transaction` | `true` |
| `Sandbox.checkout(repo, sandbox: false)` | after that transaction returned | `false` |

## Why

`Ecto.Adapters.SQL.in_transaction?/1` matches on a `conn_mode: :transaction`
connection held in the **process dictionary**, which only
`Ecto.Adapters.SQL.transaction/3` puts there. The sandbox's own `BEGIN` is
issued inside the DBConnection connection process by its proxy, not through
that function, so it never sets the flag a caller can see. The sandbox is
invisible to this question, which is the behaviour the durable path wants.

## The implementation

```elixir
@spec host_transaction?() :: boolean()
def host_transaction?, do: repo().in_transaction?()
```

No carve-out, no pool inspection, no `Mix.env` check. It is
`AuroraMeter.Storage.Ecto.host_transaction?/0` and it is called once, at the
top of `record_events/2`, before the transaction is opened.

A sandbox carve-out was considered and rejected on the measurement: it would
have been code with no reachable case, and worse, it would have made a **host**
transaction inside a sandbox test invisible, which is the one thing the
projection tests need to be able to see.

## The regression guard

`AuroraMeter.RecordProjectionTest` /
`test the sandbox and in_transaction?/0 03b verify in_transaction?/0 under the sandbox`
asserts every row of the table above, including the one that matters
(`refute host_transaction?()` on a sandbox checkout with no host transaction).
A future `ecto_sql` that changed this fails there, with a message naming the
carve-out that would then be needed, rather than silently switching every
sandbox-based record onto the conditional path.

## What still avoids the sandbox

Every durability assertion in this unit runs on non-sandbox connections through
`AuroraMeter.Test.Connections`, as the build document requires:
`AuroraMeter.RecordConcurrencyTest`, `AuroraMeter.RecordProjectionTest`,
`AuroraMeter.EventsGateTest` and `AuroraMeter.StorageCaseEctoTest` are all
`ExUnit.Case` rather than `AuroraMeter.DataCase`. The measurement above is what
makes the sandbox safe for the **validation** suite
(`AuroraMeter.RecordTest`), not a licence to assert durability on it.
