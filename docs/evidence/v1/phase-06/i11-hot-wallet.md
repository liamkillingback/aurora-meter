# I11: holds cannot spend the same available micro-USD twice (06a's contribution)

G06 bullet 2: "concurrent holds cannot allocate the same available micro-USD
twice. Test many tenants and one hot wallet with independent connections."

Core `57996c5` plus this unit's uncommitted changes, PostgreSQL 16.13 on port
5490, Elixir 1.20.1, OTP 29, seed 0.

## 1. Fifty independent connections against one hot wallet

`AuroraMeter.CreditsLotsConcurrencyTest` /
`test I11 fifty independent holds against one wallet funded with ten admit exactly ten`

| | |
|---|---|
| Funded | 10,000,000 micro-USD (10 USD), one paid lot |
| Hold size | 1,000,000 micro-USD (1 USD) |
| Attempts | 50, each its own process on its own non-sandbox connection |
| Pool | 60 (raised from 30 in `config/config.exs` for exactly this test) |
| Admitted | **10** |
| Refused `:insufficient_credits` | **40** |
| Any other outcome | 0 |
| `reserve` allocations | 10 |
| Sum of those allocations | 10,000,000 |
| Lot after | `available: 0, reserved: 10000000, consumed: 0, reversed: 0, expired: 0`, state `open` |
| Balance row after | `balance: 10000000, held: 10000000, debt: 0`, available 0 |
| Wall time | the whole five-test file runs in 1.4 s |

The fifty tasks are armed at a barrier and released together. **The connection
is taken after the barrier and not before**, because holding one from every task
while they wait deadlocks the moment there are more tasks than connections;
that is what the first run of this test did, and the pool timeout it produced is
in the history of `tmp/v1/06a-fix14.py`.

**Contention is asserted, not assumed.** The test reads
`pg_stat_activity` for the number of backends on this database and requires more
than one, because fifty transactions that ran one after another with no overlap
would produce exactly the same numbers and prove only the arithmetic.

## 2. Many tenants

`test I11 twenty concurrent holds across twenty wallets do not interfere`

Twenty wallets, each funded 2 USD and each cut over to lots, twenty concurrent
1 USD holds on twenty independent connections, one per wallet. All twenty
admitted; every wallet ends `reserved: 1000000, available: 1000000` with
`held: 1000000` on its row. No wallet's lock delayed another's answer and no
wallet's hold landed on another's lot.

## 3. The negative control, and what it actually showed

`test I11 without the balance row lock the same fifty holds oversubscribe the wallet`

The balance row lock is removed and **nothing else changes**: the eligible lot
is read without `FOR UPDATE`, then written exactly as the allocator would write
it, fifty times from fifty connections.

| Outcome | Count (one representative run) |
|---|---|
| `:admitted` | more than 10 |
| refused by `aurora_meter_credit_lots_available_check` | more than 0 |

**It discriminated, and it discriminated more sharply than it was written to.**
Removing the lock does not quietly oversubscribe the wallet: it makes the
**second** layer fire. The lot's own `available >= 0` CHECK refuses the write
outright, so a lost lock is a refused transaction rather than silent corruption.
That is exactly the property finding X183 asked for and which
`aurora_meter_credit_balances` did not have before schema version 9. The test
asserts both halves: that more than the funded ten got as far as trying, and
that at least one was refused by that named constraint. After the run the lot
still conserves and the balance row is untouched.

The assertion message says, in the test, what a zero count would mean: that the
control did not discriminate and the locked test's claim has to be rewritten.

## 4. Two real BEAM nodes

`real-provider-verification.md` gives phase 06 "lot allocation under concurrent
spend from two nodes". Two tasks in one VM is a weaker claim: one scheduler, one
pool, one copy of the code.

Harness: `tmp/v1/06a-multinode/` (driver, `h6.ex`, `run.sh`). Node A is the
driver under `mix run`; node B is a plain `erl` OS process sharing node A's code
paths, so there is no second Mix workload (finding X18). Both open their own
Ecto pool against one disposable database, migrated core 1 to 9.

Run `third`, 2026-09-15T12:56:20Z to 12:56:24Z, exit 0.

| Round | Released first | Node A admitted | Node B admitted | Total admitted | Peak concurrent lock waiters |
|---|---|---|---|---|---|
| 1 | A | 10 | 0 | **10** | **18** |
| 2 | B | 9 | 1 | **10** | **18** |

Per round: 25 attempts per node, 50 in total, 10 USD funded, 1 USD holds, 10
admitted and 40 refused with `:insufficient_credits`, no other outcome; 10
`reserve` allocations summing to 10,000,000; the lot `available: 0,
reserved: 10000000` and conserving; `held == sum(reserved)`,
`balance == available + reserved - debt`, `debt == 0`.

**The distribution is printed and the asymmetry is real.** The first version of
this driver armed and released each node's batch on its own node, and node B
admitted **nothing** in every run: node A's `send/2` is in-process and node B's
travels over the distribution hop first. That is finding X209's shape across a
distribution boundary, and a race only one side can win proves the common path
and says nothing about the contended one (X182, X187). Reversing the release
order is what makes both sides reachable; the property being tested is that the
**answer** does not depend on which side wins, and it does not.

**The waiters are measured, not assumed.** A sampler on node A polls

    SELECT count(*) FROM pg_stat_activity
     WHERE datname = current_database()
       AND wait_event_type = 'Lock'
       AND pid <> pg_backend_pid()

every 5 ms for the length of the race. Peak 18 in both rounds. `pg_locks`
filtered by `database` would have returned zero throughout: a backend queued
behind a row lock waits on the holder's `transactionid`, and a `transactionid`
lock carries no database (finding X186).

## 5. What is not proved here

* The fifty-connection test bounds simultaneous connections by the pool (60), so
  "fifty at once" is true of this configuration and would not be on a host with
  a smaller pool. The claim that matters, that exactly the funded number are
  admitted, does not depend on it.
* Killing a writer mid-transaction is **not** covered; see 06a-report.md
  section 7 item 1 and finding X243.
