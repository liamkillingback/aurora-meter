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

| Seed | compared | refused | reordered by `seq` | skipped |
|---|---|---|---|---|
| 0 | 28 | 13 | 0 | 0 |
| 1 | 29 | 12 | 0 | 0 |
| 7 | 29 | 12 | 0 | 0 |
| 42 | 22 | 19 | 0 | 0 |
| 1337 | 31 | 10 | 0 | 0 |
| 20260915 | 26 | 15 | 0 | 0 |
| 424242 | 33 | 8 | 0 | 0 |
| **total** | **198** | **89** | **0** | **0** |

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
| `promotional_divergence` raised by a `debit` | 32 | X263 |
| `promotional_divergence` raised by a `settle` | 17 | X263 |
| `promotional_divergence` raised by a `grant` | 4 | X263 |
| `promotional_divergence` raised by a `release` | 1 | X263 |
| `expire_reserved_grant` | 13 | X261 |
| `reversal_took_reserved` | 13 | |
| `hold_unbacked`, with `debt > 0` | 5 | X262 |
| `reversal_exceeds_lots` | 4 | |
| `promotional_divergence` raised by a `reverse` | **0** | X257 |

Every refusal the property accepts is named above with the finding that
explains it, and anything else fails the property with the history that
produced it. The `hold_unbacked` entry is accepted **only** when the detail
says `debt > 0`: the other cause of that flag needs a non-zero overdraft
tolerance, which this property does not configure, so it must never appear and
would fail the run if it did.

## What the generator found

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
eighty nine refusals are one of these two shapes, both caused by the legacy
figures not knowing which grant a hold reserved. A wallet that has ever
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
