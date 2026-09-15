# 06b: the wallet migration killed, resumed and raced

Build unit 06b, V1 task 06.08 ("pause mutations per wallet during final cutover
or use a verified watermark protocol; old and new allocation writers must not
operate simultaneously on a migrated wallet").

All of it is in `test/aurora_meter/credits_lot_migration_resume_test.exs`,
`async: false`, no `DataCase`. The sandbox wraps a test in one transaction on
one connection, which is exactly what an interrupt test must not have: a killed
process rolls its own transaction back, and the only trustworthy state
afterwards is what a different connection can read. Every assertion below is a
read of the database from an independent connection.

## Why one wallet is one transaction

The migration's per-wallet pass is: read the balance row unlocked to decide what
to do; count the rows; read the history; fold it, holding no lock; then open one
transaction which takes the balance row `FOR UPDATE`, reads anything committed
since the snapshot, verifies the fold against the locked row, writes the lots,
the allocations, the `hold_transaction_id` backfill and the balance row, and
runs the conservation check as its last statement. There is no step between the
first lock and the commit that can leave a partial effect, so a kill anywhere
inside it leaves the wallet exactly as it was.

That is an argument. The tests are what make it a fact.

## Kill 1: inside a wallet's transaction

`AuroraMeter.Test.Kill.run/2` arms `:before_commit` on the balance update,
through `AuroraMeter.Test.FaultRepo`, and the migration runs in a supervised
task on its own non-sandbox connection. `Kill.run/2` fails the test if the
worker returned normally although a kill was armed, and if the death reason is
anything other than exactly `:killed`, which is what distinguishes an
untrappable kill from a catchable callback exit.

Where the kill lands: after the lots and allocations have been inserted, after
the `hold_transaction_id` backfill, and before the balance row is updated. That
is the latest point at which a partial write would be visible if one were
possible.

What an independent connection then reads, for a `promotional_overlap` wallet
(two promotions, one payment, one debit):

- zero rows in `aurora_meter_credit_lots`
- zero rows in `aurora_meter_credit_allocations`
- `lots_enabled_at` still null, `debt` still 0
- `balance`, `held` and `promotional` unchanged
- no settle or release row has a `hold_transaction_id`

Then the run is repeated with nothing armed. The wallet migrates, and
`migrated_exactly_once!/1` asserts one lot per grant row two ways:
`COUNT(*)` against `COUNT(DISTINCT grant_transaction_id)`. The unique index
`(tenant_key, grant_transaction_id)` would refuse a second lot, so counting both
ways is what says the refusal did not happen rather than that the work was
quietly skipped.

Test: `LI-06b-4 a kill inside a wallet's transaction leaves it untouched, and the rerun takes it`.

## Kill 2: between two wallets

`:after_commit_before_ack` fires when the outermost transaction commits, and for
this task the outermost transaction is one wallet. Armed with `count: 1`, the
kill therefore lands after the first wallet is durable and before its checkpoint
report row exists, which is the worst moment for a resumable task: the work is
done and the cursor does not know it.

Three wallets (`paid_only`, `debits`, `promotional_overlap`). What an
independent connection reads after the kill:

- exactly **one** of the three has `lots_enabled_at` set, asserted as a count
  rather than by name, because which one committed depends on the scan order
- each of the other two has zero lots and zero allocations, not a partial book

The rerun then reports two `migrated` and one `skipped`, and every one of the
three passes `migrated_exactly_once!/1` with its three figures unchanged. The
wallet that committed before the kill is skipped because its `lots_enabled_at`
is re-read under the lock, not because a cursor remembered it: the cursor was
never written.

Test: `LI-06b-4 a kill after one wallet commits leaves the rest for the rerun, once each`.

## Race: two runs, one wallet, forced contention

Findings X182, X186 and X187: three units shipped a race test whose contended
branch ran zero times while reporting green. This one forces it.

A third connection takes the wallet's balance row `FOR UPDATE` in its own
transaction and holds it. Two migration runs are then started on their own
connections; both reach `lock_phase/5` and queue behind that row. The test polls
until Postgres reports **two** backends waiting, and only then releases the
holder.

The count is asserted on an ordinary run (X214), not printed behind an
environment variable:

```elixir
assert await_waiters(2, 500), "neither runner queued on the balance row lock"
```

The query is `pg_stat_activity` and not `pg_locks`, and the reason is X186: a
backend queued behind a row lock waits on the holder's `transactionid`, and a
`transactionid` lock carries no `database`, so the obvious `pg_locks` query
filtered by database removes exactly the rows being looked for.

Outcome: the two runs report `[:migrated, :skipped]` in some order, the wallet
has one lot per grant row, and the three figures are unchanged. The loser
re-reads `lots_enabled_at` under the lock it was waiting for and skips
(LI-06b-3), which is the same mechanism that makes a rerun a no-op.

Test: `LI-06b-3 two runs racing one wallet on its balance row migrate it exactly once`.

## A ledger write during the snapshot

The snapshot phase holds no lock, so a live ledger write can commit between the
fold and the cutover. The watermark that catches it is `seq`: a row committed
after the snapshot is written by the current code and therefore carries an
identity above every row the snapshot read, so the tail read
`WHERE tenant_key = $1 AND seq > $high` is exact. `seq` is not a sound **order**
for a pre-version-9 row (X244) and it is a sound **watermark**, and the
migration uses it for exactly one of those two jobs.

The harness blocks the migration between its snapshot read and its lock, commits
a debit on another connection, and releases it. The block point is the second
read of `aurora_meter_credit_balances` in one wallet's pass, which puts the
migration inside its transaction with no row lock taken. Blocking one statement
later, before the tail read, holds the balance row and the writer queues behind
it for ever; that is not hypothetical, it is what this harness did first, and
the five second block timeout is what said so.

Two tests, and the first is what proves the window is the one it claims to be:

- with `--max-tail 0`, a row folded in from the tail defers the wallet as
  `too_busy` and a row the snapshot had already seen migrates it. The wallet is
  deferred, so the concurrent write really did land after the snapshot.
- with the default `--max-tail`, the same rendezvous with the concurrent debit
  **backdated to the year 2000** migrates the wallet correctly, because the tail
  is appended in `seq` order rather than merged into the snapshot by timestamp.
  The discriminator is the second half of the test: the same rows merged by
  `(inserted_at, id)`, which is what a fold that trusted the stamp would do, put
  the debit before the grant that funded it and the balance chain refuses them.

`architecture-map.md` section 7.4 and the 06b build document both expected a row
committed out of timestamp order to **block** the wallet. It does not have to,
and the second test is why.

Tests: `I19 a ledger write committed during the snapshot lands in the tail, not in the snapshot`
and `X213 a tail row stamped before every snapshot row is still folded in commit order`.

## What was not tested, and why

There is no unfiltered `mix aurora_meter.credits.migrate_lots` run in this file.
A scan reads every balance row in the database, and rows committed by other
non-sandbox modules are still there, so an unfiltered real run would migrate
wallets belonging to another test. The cursor and scan mechanics are proved in
the sandboxed file instead, where a shadow run can walk the whole table and
write nothing
(`I19 the scan resumes from the aggregate cursor and skips what is behind it`).

There is no test of a run killed by `kill -9` at the operating-system level. The
package's harness kills the BEAM process, which is what
`AuroraMeter.Test.Kill` promises and what `open-findings.md` T1 asked for; an
operating-system kill of the whole VM is phase 11's rehearsal, and 11b reuses
this harness for it.
