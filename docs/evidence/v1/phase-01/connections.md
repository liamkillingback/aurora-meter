# 01b: independent connections and prefix-bounded cleanup (core)

Recorded 2026-09-14. `AuroraMeter.Test.Connections`,
`test/support/aurora_meter/test/connections.ex`.

## The table list `cleanup!/1` deletes from

Every schema this package owns that carries a `tenant_key`:

| Schema | Table |
|---|---|
| `AuroraMeter.Schema.Counter` | `aurora_meter_counters` |
| `AuroraMeter.Schema.CreditBalance` | `aurora_meter_credit_balances` |
| `AuroraMeter.Schema.CreditTransaction` | `aurora_meter_credit_transactions` |
| `AuroraMeter.Schema.Event` | `aurora_meter_events` |
| `AuroraMeter.Schema.History` | `aurora_meter_history` |
| `AuroraMeter.Schema.Subscription` | `aurora_meter_subscriptions` |

One schema has no `tenant_key` and is listed separately as `tenantless/0`:
`AuroraMeter.Schema.FlushReceipt` (`aurora_meter_flush_receipts`, primary key
the batch id). A test that writes a receipt deletes it by id itself; the
harness self-tests do exactly that.

The self-test `Y4 cleanup! covers every schema the package owns` enumerates
`Application.spec(:aurora_meter, :modules)` for `AuroraMeter.Schema.*` and
fails, naming the module, when one is in neither list. A table added in phase
03 or 06 without a cleanup entry therefore fails here rather than by leaking
rows into a later run.

## The prefix validation rule

`cleanup!/1` raises `ArgumentError` **before issuing any statement** when the
prefix:

- is shorter than four characters, or
- is neither a `AuroraMeter.Test.unique_tenant/1` value
  (`~r/^[a-z][a-z0-9_]{2,}_\d+$/`) nor a prefix registered with
  `register_prefix/1`.

The build document wrote `{3,}` for the middle class. That literal rejects
`unique_tenant()`'s own default output (`org_1795`: one leading letter, then
`rg`, then `_1795`), so the harness uses `{2,}` and keeps the four-character
minimum as the separate, explicit check. Both refusals are asserted, and the
self-test also asserts that no row count changed across the refusal.

Deletion is `left(tenant_key, length(prefix)) = prefix`, not `LIKE prefix ||
'%'`, because `unique_tenant/1` values contain `_`, which `LIKE` treats as a
single-character wildcard. A consequence worth knowing and written into
`docs/testing.md`: a tenant key that is a strict prefix of another test's key
would take both, so two tenants in one test are given different prefixes
(`harnessa`, `harnessb`) rather than relying on the unique integer.

`run/3` refuses more tasks than the pool can serve, at `pool_size - 4`, and the
error carries the arithmetic:

    AuroraMeter.Test.Connections.run/3 refuses 27 tasks: the pool is 30 and 4
    connections are reserved for the test process, the sandbox owner and
    cleanup, so at most 30 - 4 = 26 tasks can be served.

## Row counts before and after a full run

`aurora_meter_test` on the 5490 container (`aurora-meter-pro-testdb`,
Postgres 16.13), counted with `select count(*)` per table from a psql session
outside the suite. Before the five seeded runs, and after them:

| Table | Before | After |
|---|---|---|
| `aurora_meter_counters` | 0 | 0 |
| `aurora_meter_credit_balances` | 0 | 0 |
| `aurora_meter_credit_transactions` | 0 | 0 |
| `aurora_meter_events` | 0 | 0 |
| `aurora_meter_flush_receipts` | 0 | 0 |
| `aurora_meter_history` | 0 | 0 |
| `aurora_meter_subscriptions` | 0 | 0 |
| `schema_migrations` | 6 | 6 |

Every package table is at its starting count. The three `seed for I02` tests
additionally assert conservation inside the test: they take the row counts
before, clean up their own tenant explicitly, take them again, and assert every
delta is zero before emitting the `AURORA_FAULT_REPORT` line.

## The `AURORA_FAULT_REPORT` line

`Connections.report!/1` appends one JSON object per call to the file named by
`AURORA_FAULT_REPORT` and is a no-op when the variable is unset, so the suite
is unchanged outside the runner. Shape, as `scripts/v1/faults.sh` (00d) will
consume it:

    {"test": string, "seed": integer, "point": string, "action": string,
     "tenant_prefix": string,
     "before": {table: integer}, "after": {...}, "delta": {...}}

Checked with `node` (there is no `jq` on this machine, and
`scripts/products/release-check.sh` already uses `node` for JSON):

    AURORA_FAULT_REPORT=/tmp/v1/faults-01b.jsonl bash tmp/v1/mixlane.sh core \
      mix test test/aurora_meter/test/harness_test.exs --seed 0
    # 3 lines parse, every required key present, every delta an integer

Tenant keys in the report are the synthetic `<prefix>_<integer>` values
`unique_tenant/1` produces (`harnessa_387`). No credential, and no value that
is not an integer or a synthetic tenant prefix, reaches the file.
