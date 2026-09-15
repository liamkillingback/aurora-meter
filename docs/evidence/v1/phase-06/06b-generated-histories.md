# 06b: generated legacy histories, replayed and reconciled

Build unit 06b. The rest of this unit is fourteen hand-chosen wallet shapes,
chosen by the same mind that wrote the fold. This is the test that does not
share that blind spot, and it found three things the fourteen did not.

Test: `test/aurora_meter/credits_lot_migration_property_test.exs`.
Script: `tmp/v1/06b-property-seeds.sh`.
Log: `logs/06b-property-seeds.log`.

## What is generated and what it is compared against

`AuroraMeter.Test.LedgerCommands.history/1` (01e) draws a state-dependent
sequence of grants in all three categories, holds, settles above and below
their hold, releases, debits and expiry sweeps. Nothing is removed from what is
generated: 06a's cross-oracle has to drop `:reverse` and turn expiry off
because its oracle is a second model of the runtime, while this unit's oracle
is the wallet's own balance row, which knows what happened whatever it was.

Two things are rewritten during execution, both to make the history more like a
real one rather than less:

- a paid grant's reference is payment-intent shaped (`pi_...`), which is what
  `aurora_meter_pro` writes, so a later reversal has something real to name;
- a `{:reverse, ...}` becomes a Pro-shaped refund naming one of those payments,
  capped at what that payment has left to give back, which is the cap
  `v1-release.md` 10.1 requires and Pro implements. A reversal drawn before any
  payment exists, or after every payment is fully reversed, is skipped.

Each history runs against a wallet whose `lots_enabled_at` is null, on an
independent connection, and the wallet is then aged to the shape a 0.4.0
database has (null `hold_transaction_id`). The comparisons are:

1. the fold's running projection against **every row's** `balance_after`,
   `held_after` and `promotional_after`, inside the fold;
2. the folded book against the balance row, before the cutover commits;
3. after the cutover, the three figures through the public API and again
   straight out of the lots with SQL;
4. **each lot's five quantities against a fold of that lot's own
   allocations**, which is the direction nothing else in this unit checks;
5. one lot per grant row, and every settle and release row linked to its hold.

## Results: seven fixed seeds, forty histories each

Re-run at core `011ac34` after 06b was reopened at 06d's review. 06c changed
`reverse/4` to write `kind: :reverse` and 06d added recurring grants, so a seed
draws a different history from the one it drew when 06b first shipped; these are
the current numbers and the earlier ones are kept below them.

| Seed | compared | refused | reordered by `seq` | skipped |
|---|---|---|---|---|
| 0 | 27 | 14 | 0 | 0 |
| 1 | 29 | 12 | 0 | 0 |
| 7 | 30 | 11 | 0 | 0 |
| 42 | 21 | 20 | 0 | 0 |
| 1337 | 31 | 10 | 0 | 0 |
| 20260915 | 26 | 15 | 0 | 0 |
| 424242 | 33 | 8 | 0 | 0 |
| **total** | **197** | **90** | **0** | **0** |

At 06b's first hand-back, on core `6af77f9`: 198 compared, 89 refused, 0
reordered, 0 skipped, over the same seven seeds.

Each run's `compared` includes one from the negative-control test in the same
file, so the property itself compared 191 generated histories and refused 89.

**`reordered by seq` is zero**, and that is a measurement rather than an
absence: it counts histories whose `(inserted_at, id)` order failed the balance
chain and whose `seq` order then reproduced it. No wall-clock backwards step
was observed in 280 histories on this host during these runs. The mechanism is
proved by named tests instead
(`X213 a row stamped out of order folds correctly once the order comes from seq`).

## Why a history was refused

| Cause | Count | Finding |
|---|---|---|
| `promotional_divergence` raised by a `debit` | 28 | X263 |
| `promotional_divergence` raised by a `settle` | 17 | X263 |
| `promotional_divergence` raised by a `grant` | 3 | X263 |
| `promotional_divergence` raised by a `release` | 1 | X263 |
| `promotional_divergence` raised by a `reverse` | 2 | X257 |
| `expire_reserved_grant` | 18 | X261, X276 |
| `reversal_took_reserved` | 12 | |
| `hold_unbacked`, with `debt > 0` | 5 | X262 |
| `reversal_exceeds_lots` | 4 | |

Two changes from the first run are worth naming rather than leaving as noise.
`expire_reserved_grant` rises from 13 to 18 because it now catches X276's shape,
which the first run mis-filed as `expire_over_lot` and which failed the property
outright when 06d's review re-ran it. And `promotional_divergence` raised by a
`reverse`, which was **zero** in 280 histories on the first run, now appears
twice: X257's refund clamp is real and rare, and 06c's `kind: :reverse` change
is what let the generator reach it. X263 remains the common cause by a wide
margin, 49 of 90.

Every refusal the property accepts is named above with the finding that
explains it, and anything else fails the property with the history that
produced it. The `hold_unbacked` entry is accepted **only** when the detail
says `debt > 0`: the other cause of that flag needs a non-zero overdraft
tolerance, which this property does not configure, so it must never appear and
would fail the run if it did.

## What the generator found the second time

**X276, at seed 1337, after eleven clean runs of the property.** An expire row
one micro-dollar over its lot's `available`, with **nothing reserved on that
lot**. The fold refused, which was right, and filed it as `expire_over_lot`,
which was wrong: that flag tells an operator the row does not belong to the
grant and to go and look at the data, and there is nothing to look at.

The cause is the third instance of the one missing idea X261 and X263 are
about. `Promotions.consume/3` gives a spend to the soonest-expiring grant with
`remaining > 0` and has no idea a hold has reserved it; the lot model cannot
spend a reservation, so it takes the spend from the **next** grant; the two
attributions then differ by what was reserved, and the next grant's later
expiry is over by exactly that much.

Shrunk from 37 commands to six:

    promotional 1          expiring first
    promotional 10 USD     expiring later
    paid 50 USD
    hold 1                 reserves the whole of the first grant
    debit 1                legacy attributes it to the first, the lots to the second
    expire_due  x2         one sweep each, because two due in one pass is undefined (L19)

**The paid grant is load bearing**, and that is the part worth keeping. Without
other funds in the wallet the sweep's own `max(balance - held, 0)` clamp reduces
the expire row by exactly the micro-dollar in dispute and the disagreement never
reaches the log at all. It takes a wallet with money elsewhere for the legacy
attribution to be written down, which is why the first shrink of this history
did not reproduce and why five hand-written histories never found it.

The fix is the bound, not the refusal: `expire_reserved_grant` is now bounded by
the value reserved **anywhere in the wallet** rather than on the lot being
expired, because a reservation elsewhere is precisely how the two attributions
come apart. `expire_over_lot` keeps its meaning for a shortfall no reservation
explains, and that discrimination is now asserted rather than inferred from the
flag's name.

**And `mix check` cannot see any of this.** The property draws a different
history at whatever seed the run picks, so the whole suite was green at 1642
passing while seed 1337 failed. `tmp/v1/06b-property-seeds.sh` is the run that
sees it and it is not part of the gate.

## What the generator found the first time

**1. `expire_reserved_grant` (X261), on the first run of ten histories.** Off by
exactly one micro-dollar: a 522,138 promotional grant, a one micro-dollar hold,
and a sweep that expired all 522,138. `Ledger.expire_locked/4` clamps by
`max(balance - held, 0)` for the whole wallet, so another grant covering the
held amount lets it destroy the grant a hold was reserving. The unit now has a
flag of its own for it, a fixture that builds it, and an operator-facing
explanation, because "a hold was reserving part of the grant your sweep
destroyed" and "this row has been edited by hand" need different things done
about them.

**2. `hold_unbacked` with `debt > 0` (X262), in four of seven seeds.**
`Allocator.plan/2`'s `{:reverse, ...}` creates debt without repaying it out of
the availability other lots still hold, so the book ends in a state 06a's own
LI-06a-5 forbids, and a hold the legacy ledger then accepted on
`sum(available) - debt >= amount` is refused outright. The request tuple does
not even carry the debt, so the allocator could not repay if it wanted to.

That one was **measured rather than argued** (control C6,
`logs/06b-control6.log`): the allocator was patched to take the debt and repay
it, the fold pointed at the patched clause, the property re-run at three seeds,
and both files restored with their sha256 compared.

| Seed | `hold_unbacked` before | after | `promotional_divergence` before | after | compared before | after |
|---|---|---|---|---|---|---|
| 0 | 1 | **0** | 5 | 5 | 28 | 28 |
| 42 | 0 | 0 | 15 | 14 | 22 | 22 |
| 20260915 | 1 | **0** | 9 | 9 | 26 | 26 |

So fixing X262 closes `hold_unbacked` entirely and **buys nothing else**. That
matters, because the obvious prediction, written down before the measurement,
was that it would also close the promotional divergences. It does not, and the
control is what said so.

**3. `promotional_divergence` is not what this unit thought it was (X263).**
The hand-built fixture is a refund clamp, and the refund clamp appeared **zero**
times in 280 generated histories. Fifty four divergences appeared, every one of
them from a `debit`, a `settle`, a `grant` or a `release`, and the mechanism is
the same missing idea as X261: `promotional_delta/2` subtracts the whole of a
spend from `promotional` on the assumption that promotional credit is always
spent first, which is false the moment a hold has reserved some of it. The
arithmetic is worked in `06b-blocked-catalogue.md`.

**That is the most important number this unit produced.** Sixty seven of the
ninety refusals are one of these two shapes, both caused by the legacy figures
not knowing which grant a hold reserved. A wallet that has ever
combined promotional credit with a hold is likely to be unmigratable, and the
cause is a defect in the legacy arithmetic that the lot model fixes rather than
an ambiguity in the history.

## The negative control

`X125 the property's comparison can fail: one micro-dollar moved between two
buckets` moves one micro-dollar between two buckets of a committed lot, which
no ledger operation would do and which the lot's own CHECK constraint permits
because the sum is unchanged. Both directions the property relies on must
notice, and both are asserted to raise: the allocation fold and the SQL
identities.

## The teardown

The module raises when the property compared **nothing**, because a run in which
every history was legitimately refused would otherwise be green for the wrong
reason. It also asserts that every table is back to the row count it started
with, which is what says the prefix-bounded cleanup really ran rather than that
it is safe.
