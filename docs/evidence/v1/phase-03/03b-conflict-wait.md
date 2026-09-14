# 03b: does `ON CONFLICT DO NOTHING` wait, and is `conflict_unresolved` reachable?

Build unit 03b's document requires this measured rather than assumed, because
the whole duplicate-versus-conflict decision rests on what
`INSERT ... ON CONFLICT DO NOTHING` does when the conflicting row belongs to a
transaction that has not finished.

## The server

```
PostgreSQL 16.13 (Debian 16.13-1.pgdg13+1) on x86_64-pc-linux-gnu,
compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
default_transaction_isolation: read committed
```

Measured 2026-09-14, port 5490, database `aurora_meter_test`. Probe:
`tmp/v1/03b/probe_conflict_wait.exs`, log
`tmp/v1/03b/logs/conflict-wait.txt`. Elixir 1.20.1, OTP 29, ecto_sql 3.14.0,
postgrex 0.22.4.

## What was measured

Two independent, non-sandbox connections. The first opens a transaction and
inserts an identity, then waits. The second issues exactly the statement
`AuroraMeter.Storage.Ecto.record_events/2` issues, against the same identity.

| Case | Second inserter blocked after 1500 ms | Rows it inserted | Row visible to a later read | Elapsed |
|---|---|---|---|---|
| The holder **commits** | yes | 0 | yes (the holder's) | 1505 ms |
| The holder **rolls back** | yes | 1 | yes (its own) | 1505 ms |

**`ON CONFLICT DO NOTHING` waits.** The second inserter did not return until the
first transaction finished, in both directions. When the first committed, the
second skipped its row and the committed row was visible to the read-back that
follows in the same transaction, because READ COMMITTED takes a fresh snapshot
per statement. When the first rolled back, the second inserted normally.

## Is `{:error, {:unavailable, :conflict_unresolved}}` reachable?

The branch exists for one state: **the insert skipped the row and the row is
not visible to this transaction**. Guessing `:duplicate` there would silently
accept a conflicting reuse of an identity, which is how a retry bills twice;
guessing `:conflict` would fail a legitimate retry. Three attempts to produce
the state:

1. **The race the branch was written for, under READ COMMITTED.** Not
   reachable. The insert waits, and by the time it returns the row is either
   committed and visible, or gone.

2. **REPEATABLE READ, the racer committing after our snapshot is taken.** Not
   reachable, and for a different reason than expected: the insert raises
   `ERROR 40001 (serialization_failure) could not serialize access due to
   concurrent update` rather than skipping silently. Probe:
   `tmp/v1/03b/probe_unresolved.exs`. The adapter maps that to
   `{:error, {:unavailable, {:postgres, :serialization_failure}}}`, which is
   retryable with the same id, so the contract holds on that path too.

3. **READ COMMITTED, with the conflicting row deleted between the insert and
   the read-back.** **Reachable.** `ON CONFLICT DO NOTHING` takes no lock on the
   conflicting row, unlike `DO UPDATE`, so nothing stops a concurrent delete.
   Result `{:ok, {0, 0, []}}`: zero rows inserted, zero returned, read-back
   empty. Probe: `tmp/v1/03b/probe_unresolved2.exs`.

   This is not a contrived scenario. A retention prune racing a retry of the
   same identity produces exactly it.

## What the code and the tests do with that

- The branch stays, and is not "defensive" in the weak sense: case 3 is a state
  this Postgres can produce.
- `AuroraMeter.RecordConcurrencyTest` /
  `test measured Postgres behaviour ON CONFLICT DO NOTHING waits for an uncommitted conflicting row on this Postgres`
  asserts case 1 against the running server, so a Postgres upgrade that changed
  it fails here rather than silently changing what a retry costs.
- `AuroraMeter.RecordConcurrencyTest` /
  `test measured Postgres behaviour the conflict_unresolved precondition is producible: a concurrent delete of the conflicting row`
  reproduces case 3 statement for statement and asserts the `{0, 0, []}` state.
- `AuroraMeter.RecordTest` /
  `test capability an adapter that cannot resolve a conflict says so rather than guessing`
  asserts the facade surfaces `{:error, {:unavailable, :conflict_unresolved}}`
  unchanged, through `AuroraMeter.Test.UnresolvedStorage`.

**What is not proven:** the adapter's own branch driven end to end by a real
race. Doing that needs a fault point between the insert and the read-back
inside `AuroraMeter.Storage.Ecto.record_events/2`, and this unit deliberately
adds no fault point to production code. The two halves above are what stand in
its place: the state is producible, and the answer the caller gets for it is
asserted.

## The twelve-connection races

`docs/evidence/v1/phase-03/03b-concurrency.json`, seed 0: twelve independent
connections submitting one identity produced **1 inserted, 11 duplicate, 0
`conflict_unresolved`**, one row, one totals delta and one outbox item. That is
what the wait behaviour above predicts.
