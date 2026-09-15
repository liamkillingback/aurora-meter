# 06a: the lock order, as implemented

`architecture-map.md` 7.3 fixes **one** order for every ledger write and this is
it:

1. the wallet's `aurora_meter_credit_balances` row, `FOR UPDATE`;
2. the specific `aurora_meter_credit_transactions` rows the operation needs (the
   hold row, for a settle or a release), `FOR UPDATE`;
3. the wallet's `aurora_meter_credit_lots`,
   `WHERE tenant_key = $1 ORDER BY id FOR UPDATE`.

0.4.0 had **two** orders: grant, hold and debit took the balance row first,
while settle, release and expiry took a transaction row first. No deadlock was
possible only because the second group locked exactly one transaction row each,
which stops being true the moment a third class of row joins them.

## Two measurements, because neither answers alone

`pg_locks` says what a transaction **holds**. It does not say in what order it
took them: there is no acquisition-order column. The statement stream does say
the order, and it is what the ledger's own behaviour is made of. Both are below.

### The order, from the statement stream

Captured by attaching to Ecto's `[:aurora_meter, :test_repo, :query]` telemetry,
which runs in the process that made the query, and keeping the `FOR UPDATE`
statements in the order they were issued. Script: `tmp/v1/06a-ddl/order.exs`.

| Wallet | Operation | `FOR UPDATE` order |
|---|---|---|
| lot | `grant` | balances, lots |
| lot | `hold` | balances, lots |
| lot | `settle` | **balances, transactions, lots** |
| lot | `release` | **balances, transactions, lots** |
| lot | `debit` | balances, lots |
| lot | `expire_due` (lot phase) | balances, lots |
| legacy | `settle` | **balances, transactions** |
| legacy | `debit` | balances |
| legacy | `expire_due` (grant phase) | **balances, transactions** |

The legacy rows matter as much as the lot rows: `settle/3`, `release/1` and
`expire_grant/2` took the transaction row first in 0.4.0 and now take the
balance row first **on both paths**, so there is one order in the package rather
than one per writer.

One capture is worth reading carefully. A single `Credits.expire_due/2` call
that has both a legacy wallet and a lot wallet with something due produces
`balances, transactions, balances, lots`: the legacy phase's
`expire_grant` for one wallet, then the lot phase's `expire_lot` for another.
Two transactions, each in the permitted order, not one transaction taking four
locks.

### What one transaction holds, from `pg_locks`

Captured by holding a ledger transaction open and reading `pg_locks` from a
third connection while it is still `idle in transaction`. Raw output:
`06a-locks-raw.txt`. During one settle on a lot wallet the transaction holds, on
the relations this unit is about:

    aurora_meter_credit_balances      RowExclusiveLock granted=true
    aurora_meter_credit_balances      RowShareLock     granted=true
    aurora_meter_credit_lots          RowExclusiveLock granted=true
    aurora_meter_credit_lots          RowShareLock     granted=true
    aurora_meter_credit_transactions  RowExclusiveLock granted=true
    aurora_meter_credit_transactions  RowShareLock     granted=true
    aurora_meter_credit_allocations   RowExclusiveLock granted=true

`RowShareLock` is what `SELECT ... FOR UPDATE` takes on the table;
`RowExclusiveLock` is what the `INSERT`s and `UPDATE`s take. All three relations
are held by the one transaction, which is the half `pg_locks` can prove.

## The assertion that runs every time

`AuroraMeter.CreditsLotsTest` /
`test I11 every ledger write takes the balance row, then the transaction row, then the lots`
asserts the table above for grant, hold, settle, release, debit and expiry, on
every ordinary `mix test` run. It is not behind an environment variable
(finding X214), and it discriminates by construction: before this unit a settle's
order was `[:transactions, :balances]`, which is not the asserted list in any
arrangement.

## Why the lots are ordered by `id` and not by the spend order

`Allocator.book/2` issues `ORDER BY id ... FOR UPDATE` and the **planner** then
sorts the returned rows by the spend key. Postgres may re-fetch a concurrently
updated row, so `FOR UPDATE` does not promise acquisition in output order; what
the ordering buys is that any two transactions that reached the lots without the
balance lock would still queue in the same direction. The balance row lock is
what actually gives one writer per wallet, and lots belong to exactly one wallet.
The comment in `book/2` says so, and says that no path touching a lot without
the balance lock may be added.

## What is not proved here

No deadlock test. The claim is that one order exists, which the table above
establishes; proving that no deadlock is reachable would need every pair of
operations run against each other, and the cheaper guarantee is that there is
only one order to violate. A future path that takes them in another order would
have to be written deliberately, and the test above is what would catch it.
