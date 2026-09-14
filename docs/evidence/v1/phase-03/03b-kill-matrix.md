# 03b: the kill matrix

One row per armed fault point on the durable path, with the state asserted
afterwards. Every kill is `Process.exit(pid, :kill)` through
`AuroraMeter.Test.Kill.run/2`, which fails the test when the worker returns
normally and when the death reason is anything other than exactly `:killed`.
Every post-kill assertion is made on a connection taken **after** the death,
through `AuroraMeter.Test.Kill.assert_db!/1`, so it never reads the connection
that aborted.

Logs: `tmp/v1/03b/logs/03b-concurrency-seed0.txt` (seed 0, `--trace`) and
`tmp/v1/03b/logs/03b-faults-seed0.txt` (`mix v1.faults`, seed 0, 76 passed).

| Point | Armed on | Event row | Totals delta | Outbox item | In-memory value | PubSub | Retry with the same id |
|---|---|---|---|---|---|---|---|
| `:before_commit` | `record_events/2` | none | none | none | unchanged | none | inserts, once |
| `:after_commit_before_ack` | `record_events/2` | exactly 1 | exactly 1 (quantity 9, events 1) | exactly 1 | **unchanged, low** | none | `:duplicate`, adds nothing |
| `:before_commit` | `record_events/2`, batch of 5 | none | none | none | unchanged | none | n/a (the raise is asserted) |
| `:before_commit` | `record_events/2`, gate at capacity 1 | none | none | none | unchanged | none | the permit is returned |

The tests, by name:

- `AuroraMeter.RecordConcurrencyTest` / `test process death I06 killing the caller before commit leaves no row, no delta, no outbox item and no ETS delta`
- `AuroraMeter.RecordConcurrencyTest` / `test process death I06 killing the caller after commit before the reply leaves exactly one row, and the same-id retry returns duplicate without a second delta or outbox item`
- `AuroraMeter.RecordBatchTest` / `test I06 a storage failure mid-batch rolls back every new row`
- `AuroraMeter.EventsGateTest` / `test record/4 under backpressure a permit is returned even when the storage call raises`

## The row that is worth reading twice

`:after_commit_before_ack` is the "commit succeeded, the caller never learned of
it" boundary. The event, its totals delta and its export intent are all
committed. The **in-memory** value is not: the caller died before the
post-commit projection ran, so `AuroraMeter.usage/2` reads low until the retry
or the next cold seed. The test asserts that explicitly
(`assert AuroraMeter.usage(...) == 0` while the durable row says 9) rather than
pretending the view is never behind. `AuroraMeter.Events.total/3` is
authoritative and reads 9 throughout.

The retry is the recovery, and it is the same id: it returns `:duplicate`, adds
no second row, no second totals delta and no second outbox item, and performs
the post-commit effects then.

## Process death and the gate

A caller killed with `:kill` runs no `after` block, so the permit it holds is
returned by the gate's monitor rather than by the caller. Asserted separately in
`AuroraMeter.EventsGateTest` / `test admission a killed admitted caller releases its permit`,
which kills an admitted holder with `:kill` and waits for the next caller to be
admitted. This is why `AuroraMeter.Events.Gate` is a process and not a
`:counters` reference: a leaked permit is a permanent availability loss.

## The restart budget

`AuroraMeter.KillTest` warns that `AuroraMeter.Supervisor` allows three restarts
in five seconds and that its three tests spend all three. This unit's kill tests
kill the **caller**, never a supervised child, so they take nothing from that
budget. The one 03b change inside `AuroraMeter.KillTest` replaced an assertion
in an existing test rather than adding a fourth kill.
