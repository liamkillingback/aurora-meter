# I12: grant expiry cannot consume later or unrelated funds

Invariant **I12 is 06a's to own**. Core `57996c5` plus this unit's uncommitted
changes, PostgreSQL 16.13, Elixir 1.20.1, OTP 29, seed 0.

Quantities below are micro-USD. Each scenario is one wallet with
`lots_enabled_at` set; the legacy behaviour it replaces is stated beside it,
because the difference is the point.

## How the invariant is enforced

`Allocator.plan(book, {:expire, lot_id, now})` looks at **one** lot and moves
**one** bucket: all of that lot's `available` to `expired`. It cannot reach
another lot because it never reads one. Everything else follows from that plus
the release and settle rules:

* a hold's reservation is untouched by expiry;
* when that hold is released or settles, whatever it does not spend on a lot
  whose `expires_at` has passed becomes `expired` rather than `available`;
* a lot past its `expires_at` is not eligible to be spent at all, so no later
  operation can consume what the sweep has not reached yet.

## Scenario 1: only the due lot's available moves

`test I12 expiry moves only the due lot's available to expired and leaves reserved alone`

Wallet: a 5 USD promotional lot expiring in October ("due"), a 4 USD
promotional lot with no expiry ("later"), a 2 USD hold.

| Lot | before | after |
|---|---|---|
| due | `available 3000000, reserved 2000000, expired 0`, state `open` | `available 0, reserved 2000000, expired 3000000`, state `open` |
| later | `available 4000000, expired 0` | `available 4000000, expired 0` |

Balance row `expired` moves to 3,000,000. The sweep reported `expired: 1`.

The lot that was not due kept every micro-USD. "due" stays `open` because it
still holds a reservation, so the sweep has more to do once the hold closes.

## Scenario 2: overlapping promotions expire their own remainder

`test I12 overlapping promotions expire their own remainder and never each other's`
(G06 bullet 3)

Wallet: 5 USD promotional expiring 1 Oct, 10 USD promotional expiring 1 Nov, a
12 USD debit.

The debit spends soonest-expiry first, so October pays all 5 and November pays
7, leaving `oct: available 0` and `nov: available 3000000`.

| Sweep at | examined | expired | `oct.expired` | `nov.available` | balance |
|---|---|---|---|---|---|
| 2 Oct | 0 | 0 | 0 | 3000000 | 3000000 |
| 1 Dec | 1 | 1 | 0 | 0 (`nov.expired 3000000`) | 0 |

October is already exhausted, so its sweep has nothing of its own to take and
does not reach into November's remainder. **This is the case the legacy
`promotional` figure cannot get right**, and `docs/credits.md` documented it as
a limitation: one number per wallet cannot say which grant a spend came out of,
so the first grant to expire could reclaim value the second had contributed.

## Scenario 3: a reservation released on an expired lot (finding L1)

`test I12 a reservation released on an expired lot becomes expired, never spendable`

Wallet: a 5 USD promotional lot expiring 1 Oct, a 2 USD hold taken on
15 September, the sweep run on 1 December, then the hold released, all under a
frozen clock so the release itself sees the lot as past.

| | after the sweep | after the release |
|---|---|---|
| `available` | 0 | 0 |
| `reserved` | 2000000 | 0 |
| `expired` | 3000000 | **5000000** |
| state | `open` | `expired` |
| balance row | `balance 2000000, held 2000000` | `balance 0, held 0` |
| `Credits.sufficient?(tenant, 1)` | | **false** |

The release row carries `amount: -2000000` and
`metadata["expired_amount"] => 2000000`, with one `expire` allocation naming the
lot. A release is the one case where it moves the balance by something other
than nothing, so the row says what it destroyed.

**What this replaces.** In 0.4.0 the released reservation became spendable again
and the sweep could never take it, because the grant's `expired_at` was already
stamped. `AuroraMeter.CreditsTest` still asserts that behaviour for a legacy
wallet, so there is a before and an after, and `docs/correctness.md`'s I12
section now says which writer each applies to.

## Scenario 4: a hold taken before expiry settles against its reserved portion

`test I12 a hold taken before expiry settles against its reserved portion afterwards`

Same setup, but the work really ran and cost 1.5 USD.

| | after |
|---|---|
| `consumed` | 1500000 |
| `expired` | 3500000 |
| `available` | 0 |
| settle row | `settled_amount 1500000`, `metadata["expired_amount"] => 500000` |
| balance row | `balance 0, held 0` |

The promise `hold/4` made is kept: the work is paid for out of the reservation
the hold took before the expiry. The half it did not use is written off rather
than handed back.

## Scenario 5: idempotency (finding L7)

`test I12 the expiry sweep run twice writes one expire row, one allocation and the reference expire:<lot_id>:0`

| Pass | examined | expired | rows |
|---|---|---|---|
| 1 | 1 | 1 | one `:expire` ledger row, `amount -3000000`, reference `expire:<lot_id>:0`; one `expire` allocation |
| 2 | **0** | 0 | unchanged |

The second pass does not examine the lot at all, which is stronger than refusing
it: `available = 0` takes it out of the candidate set, so a sweep running every
half hour does no work per already-expired lot rather than one refused
transaction each. The reference is derived from the count of `expire`
allocations already on the lot, read under the lot's lock, so a retry after a
rollback recomputes the same string. In 0.4.0 a partial expiry took
`System.unique_integer/1` into its reference and a retried pass wrote a second
row.

## Scenario 6: expiry racing a release, from a forced rendezvous

`AuroraMeter.CreditsLotsConcurrencyTest` /
`test I12 expiry racing a release conserves and leaves no spendable expired value`

Six rounds, each on its own wallet: a 5 USD promotional lot expiring 1 Oct and a
2 USD hold, then `expire_due` and `release` run on two independent connections.
A third connection holds the wallet's balance row `FOR UPDATE` until Postgres
reports **two** backends waiting on a lock, then commits, releasing both
together.

| | |
|---|---|
| Rounds | 6 |
| Rounds where both writers were observed waiting | **6** (asserted, not printed) |

After every round, whichever order they committed in:

    lot:  available 0, reserved 0, expired 5000000, state expired
    row:  balance 0, held 0, expired 5000000, debt 0
    Credits.sufficient?(wallet, 1) == false

**Why the waiters are read from `pg_stat_activity` and not `pg_locks`.** A
backend queued behind a row lock waits on the holder's `transactionid`, and a
`transactionid` lock carries no `database`, so the obvious
`pg_locks WHERE NOT granted AND database = ...` returns zero while two backends
are demonstrably blocked (finding X186). The failure mode is the dangerous one:
the poll never succeeds and, with a generous deadline and a lenient assertion,
it looks like a slow test rather than a broken rendezvous. The assertion here is
`contended == 6` with a message naming both things a zero would mean.

## Scenario 7: credit past its expiry is not spendable before the sweep

`test I10 credit past its expires_at is not spendable before the sweep reaches it`

The lot row still says `available: 5000000, state: open`. `Credits.sufficient?`
is false, `hold/4` and `debit/4` both return `{:error, :insufficient_credits}`.
A second, live promotional grant is then spendable, and the debit lands on
**it** rather than on the expired lot.

This is the one deliberate compatibility change in the unit. It is what makes
expiry bookkeeping instead of a race: the sweep no longer decides whether money
can be spent, it only decides when the books say it was destroyed.

## The legacy path is unchanged

Two existing tests changed in this unit because the defects they asserted are
fixed, and both are named in `06a-report.md`. Everything else in
`credits_test.exs` and `credits_concurrency_test.exs` passes unchanged: a wallet
with `lots_enabled_at IS NULL` writes no lot, and the 0.4.0 expiry arithmetic,
including the L1 leak, is exactly as it was.
