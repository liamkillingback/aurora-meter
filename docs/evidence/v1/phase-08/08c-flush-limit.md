# 08c: a flush of more than 9,362 dirty counter keys cannot be sent at all

Finding **X338**, found by build unit 08c running the `flush_10k` mode that V1
task 08.06 asks for by name. It is a defect in the library, not in the benchmark.

## The fact

`AuroraMeter.Storage.Ecto.add_counters/1` builds **one** `insert_all` over every
counter row in a flush batch, with **seven bind parameters per row**. Postgres's
wire protocol accepts at most **65,535** bind parameters in a statement, so a
batch of more than `floor(65535 / 7) = 9,362` counter keys cannot be sent.

The flush does not degrade. It fails, and `AuroraMeter.Flusher.failed/2` retains
the batch for an idempotent retry, which is correct for a transient failure and
is exactly wrong for this one: the same impossible batch is retried for ever, the
dirty set never empties, and every increment after it is buffered with no way to
reach the database.

## Measured, to the key

`tmp/v1/08c-flushlimit.exs`, a bisection over the dirty-key count against the
real `aurora_meter_bench` database. Command:

```
AURORA_BENCH=1 MIX_ENV=test DB_PORT=5490 \
  elixir -S mix run --no-start tmp/v1/08c-flushlimit.exs
exit=0
```

```
  10000 keys: ERROR "postgresql protocol can not handle 70000 parameters, the maximum is 65535"
   5000 keys: ok
   7500 keys: ok
   8750 keys: ok
   9375 keys: ERROR "postgresql protocol can not handle 65625 parameters, the maximum is 65535"
   9062 keys: ok
   9218 keys: ok
   9296 keys: ok
   9335 keys: ok
   9355 keys: ok
   9365 keys: ERROR "postgresql protocol can not handle 65555 parameters, the maximum is 65535"
   9360 keys: ok
   9362 keys: ok
   9363 keys: ERROR "postgresql protocol can not handle 65541 parameters, the maximum is 65535"

largest dirty-key count that flushes: 9362
smallest that does not:              9363
confirming the boundary directly
  9362: {:ok, 9362}
  9363: {:error, "postgresql protocol can not handle 65541 parameters, the maximum is 65535"}

postgres: PostgreSQL 16.13 (Debian 16.13-1.pgdg13+1) on x86_64-pc-linux-gnu
elixir 1.20.1 / OTP 29
bind parameters per counter row: 6.999 (65535 / 9363)
```

The limit is **per statement**, so it applies to the counter insert and the
history insert separately: a host with `:history` on reaches it at 9,362
distinct `{tenant, feature, period}` keys, with the day buckets going in their
own statement.

## What it costs a host

`flush_1k` passes. `flush_10k` and `flush_100k` fail on every run, five runs
each, and their records are committed as failures:

```
flush_10k   errors.by_tag {"flush_failed": 1}   correct: false
            "postgresql protocol can not handle 70000 parameters, the maximum is 65535"
flush_100k  errors.by_tag {"flush_failed": 1}   correct: false
            "postgresql protocol can not handle 700000 parameters, the maximum is 65535"
```

The second measurement is the one that matters operationally. `db_recovery` run
with **12,000** rotating keys, a real 10 second container outage and a 60 second
drain bound:

```
bash scripts/v1/bench.sh run --modes db_recovery --runs 1 \
  --out tmp/v1/bench/outage-control --outage-seconds 10 --seconds-before-outage 10 \
  --extra "--duration 30000 --backlog-keys 12000 --drain-timeout 60000"
exit=2   (the task raised; no record was written, so the log is the artifact)
```

```
** (RuntimeError) the bench waited 60000 ms and the dirty set never emptied:
   24000 dirty keys, 24000 items in the pending batch.
```

with `AuroraMeter flush failed; the same batch will be retried: "postgresql
protocol can not handle 84000 parameters, the maximum is 65535"` repeating once
a second. **The database came back and the backlog still never drained.** The
same run with 2,000 keys recovers to exact totals in about half a second
(`08c-outage.md`).

So the operational shape is: a host whose traffic touches more than 9,362
distinct counter keys between two flushes cannot flush at all, and an outage on
such a host is unrecoverable without a restart, which discards the buffer. At a
five second flush interval that is 1,873 distinct keys per second, which a
multi-tenant metering library is meant to reach.

Raw artifacts: `runs/v1-rc1/flush_10k-*.json`, `runs/v1-rc1/flush_100k-*.json`,
`runs/outage-control/db_recovery-1.log`.

## Not fixed here, and why

08c must not change `Storage.flush_batch/3` or the flusher's retry: they are what
the `db_recovery` mode measures, and a unit that changed the thing it was
measuring would have no measurement. The bench's job was to find this and to
record it so it cannot be lost, and `AuroraMeter.Bench.ReportTest` names
`flush_10k` and `flush_100k` as expected failures with this finding's id, so the
day the defect is fixed **that test fails** and somebody has to come back and
delete the exception.

## The shape of the fix, for whoever takes it

Chunk the insert. `Storage.Ecto.add_counters/1` and `add_history/1` each need a
maximum rows-per-statement, chunked inside the existing transaction so the batch
stays atomic and the receipt still decides idempotency. The chunk size is
`floor(65535 / parameters_per_row)` and must be derived rather than written down:
the parameter count per row is whatever the schema has, and a column added later
would lower the limit silently. A test that flushes 9,363 keys is the one that
would have caught this.

There is a second question beside it, and it is the operator's rather than the
library's: a batch that can never succeed is retried for ever by a mechanism
built for batches that can. `Flusher.failed/2` has no notion of a permanent
failure, and the telemetry 08a defines reports the error count but not that the
same batch id has now failed a hundred times.
