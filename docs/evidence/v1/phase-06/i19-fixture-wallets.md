# 06b: the fixture wallets, and how each one was built

Build unit 06b, V1 task 06.02. The machine-readable form of everything below,
including each wallet's whole ledger, its lot table, its allocation table and
its before and after figures, is `06b-fixture-wallets.json`.

## The rule these fixtures follow

**Every wallet is built by calling the shipped `AuroraMeter.Credits` API against
a wallet whose `lots_enabled_at` is null**, which is the legacy writer. No row
is inserted by hand and no figure is written by hand. That matters more here
than anywhere else in the programme: the wallet migration is checked against
`balance`, `held` and `promotional`, and a fixture that set those values would
be checking the migration against the author's belief about the legacy
arithmetic rather than against the arithmetic.

`AuroraMeter.Test.LedgerFixtures` is the module. Two helpers change rows after
they are written and both model something a real database has:

- `age!/2` nulls `hold_transaction_id` on every row, because the column arrives
  with core schema version 9 and every row written before it has none. Without
  this the backfill would have nothing to backfill and its test would pass
  vacuously. With `promotional_after: :null` it also nulls that column, which is
  the shape of every row written before version 4 (finding L10).
- `corrupt!/3` and `swap_inserted_at!/3` write histories the API refuses to
  produce, and they exist only for the refusal catalogue
  (`06b-blocked-catalogue.md`). No wallet in the table below uses them.

References are suffixed with the tenant key, because `(kind, reference)` is
unique across the whole table rather than per tenant. A Pro-shaped reference
keeps its prefix and its colons, so `refund:pi_refunded_org_7:200` is what the
migration's provenance parsing really sees.

## The fourteen shapes

The build document asked for twelve wallet shapes covering a list of features.
Fourteen were built, because two of the features in that list (a promotional
grant landing on a negative balance, and a pre-version-4 wallet) are wallets in
their own right rather than rows to bolt onto another shape.

| Shape | The 0.4.0 calls, in order | What it is for |
|---|---|---|
| `paid_only` | `grant 5 pi_paid_a`, `grant 3 pi_paid_b`, `grant 2 top_up_manual`, `debit 6 job_1` | one lot per paid grant, spent oldest first, and a grant whose reference is not a payment intent |
| `promotional_overlap` | `grant 3 promotional expires 2026-01`, `grant 5 promotional expires 2026-02`, `grant 10 paid`, `debit 6` | G06 bullet 1: overlapping promotions, soonest expiry first, paid untouched |
| `promotional_no_expiry` | `grant 4 promotional no expiry`, `grant 2 promotional expires 2099`, `grant 1 paid`, `debit 3` | non-expiring lots sort last within their category |
| `partial_expiry` | `grant 10 promotional expires 2020-06`, `hold 4`, `expire_due`, `release`, `expire_due` | a hold spanning an expiry, a partial `expire:<grant_id>:<n>` row (L7), and the I12 shape |
| `pending_hold` | `grant 6 paid`, `grant 2 promotional expires 2099`, `hold 3` | a hold still open at cutover, which is the I12 population the report names |
| `settled_overrun` | `grant 4 paid`, `hold 2`, `settle 6` | a settlement above its hold: consume, then debt |
| `released_hold` | `grant 4 paid`, `grant 1 promotional`, `hold 2`, `release`, `debit 1` | a reservation handed back to the lots it came from, then spent |
| `debits` | `grant 5 paid`, `debit 2`, `debit 2`, `debit 1` | plain spending, and the wallet the ordering tests perturb |
| `refund` | `grant 5 pi_refunded`, `debit 1`, `reverse 2 refund:<pi>:200` | a Pro-shaped refund with `payment_intent_id` in its metadata |
| `dispute` | `grant 5 pi_disputed`, `reverse 3 dispute:<pi>:du_1:300` | a dispute reversal carrying a dispute id in its reference |
| `reconciled` | `grant 5 pi_reconciled`, `debit 1`, `reverse 2 reconciled:<pi>:sync:...`, `grant 1 adjustment reconciled_restore:<pi>:sync:...` | payment reconciliation's reversal and its restore adjustment |
| `reinstated` | `grant 5 pi_reinstated`, `reverse 3 dispute:<pi>:du_2:300`, `grant 3 adjustment reinstated:<pi>:du_2:300` | a dispute reinstatement, which becomes a lot the same payment's next reversal can reach |
| `grant_on_debt` | `grant 2 paid`, `hold 1`, `settle 5`, `grant 6 promotional` | a promotional grant landing on a negative balance |
| `pre_v4` | `grant 4 promotional`, `grant 6 paid`, `debit 5`, then `promotional_after` nulled on every row | L10: the column was added in version 4 with no backfill |

Amounts are USD; the ledger stores micro-dollars.

## The three-figure comparison

For every shape the assertion is the same and it is made twice, from two
different places:

1. `AuroraMeter.Credits.balance/1` before the migration equals
   `AuroraMeter.Credits.balance/1` after it, for `balance`, `held` and
   `promotional`.
2. The same three figures read back out of the **lots** with SQL:
   `sum(available) + sum(reserved) - debt`, `sum(reserved)`, and
   `sum(available + reserved) FILTER (WHERE category = 'promotional')`.

The second is the one that carries the claim. A fold that reconciled the wallet
totals while putting the value in the wrong lots would satisfy the first, every
CHECK constraint, the conservation check and the per-row chain, and would still
have destroyed the per-payment provenance the unit exists to create. So each
shape also has a test asserting **which** lot holds what: that the 6 USD debit
in `paid_only` takes 5 from the first grant and 1 from the second, that the 6
USD debit in `promotional_overlap` takes 3 and 3 and leaves the payment alone,
that the refund in `refund` lands on the payment's own lot as `reversed` rather
than on the wallet's oldest availability.

Run verdicts, lot counts and the exact figures per shape are in
`06b-fixture-wallets.json`.

## Two shapes worth reading the arithmetic of

### `partial_expiry`, which is where the fixed semantics must not be applied

The legacy sweep expired 6 USD of a 10 USD grant because a 4 USD hold covered
the rest, left `expired_at` unset, the release handed the 4 USD back, and a
second sweep took it. The replay reproduces exactly that: the release unreserves
to `available`, and the second `expire` row then moves it to `expired`. Applying
I12's fixed rule during the replay instead would write the 4 USD off at the
release, and the second `expire` row would have nothing to take
(`open-findings.md` X253).

Final lot: `amount 10, expired 10`, everything else zero. Final row: all three
figures zero. Both agree.

### `grant_on_debt`, where the lot says more than the legacy figure could

A 5 USD settlement against a 2 USD wallet leaves the balance 3 USD down.
`AuroraMeter.Credits.Promotions` then attributes only 3 USD of the following
6 USD promotional grant, because only the part above zero was ever spendable.
The lot model gives the lot its whole 6 USD and immediately consumes 3 USD of it
repaying the debt, which leaves the same 3 USD spendable and the same
promotional figure.

Recording the row's own amount rather than the attributed amount is not a
preference: it is the only version that keeps the lot's balance delta equal to
the row's, which is what the per-row chain check compares. The difference is
visible to an operator, so the report flags it `promotional_clamped` with the
amount repaid, because a 6 USD lot showing 3 USD available deserves an
explanation.
