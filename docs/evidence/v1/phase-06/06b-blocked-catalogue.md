# 06b: every reason a wallet is not migrated, and the wallet that triggers it

Build unit 06b, V1 task 06.02 ("ambiguous historical allocation blocks that
wallet's cutover; do not invent grant provenance").

A refusal nobody can demonstrate is not a refusal. Every blocking flag below has
a wallet built for it, and the assertion for each is the same four facts: the
wallet is reported `blocked`, `lots_enabled_at` stays null, the wallet has zero
lot rows and zero allocation rows, and its checkpoint row carries the reason.

The generated proof is `AuroraMeter.CreditsLotMigrationTest` /
`test I19 every blocking flag has a wallet that triggers it and none of them migrate`,
which walks the table below in one run, plus one test per flag in
`AuroraMeter.Credits.LotMigrationReplayTest` against the pure fold.

## How the wallets were built

Nine of the thirteen are produced by calling the shipped `AuroraMeter.Credits`
API against a wallet whose `lots_enabled_at` is null, which is the legacy
writer. Four cannot be: a settlement with no hold, a release with no hold, a row
of a kind nothing writes and an expiry larger than the grant it names are
histories the API refuses to produce. Those are written directly by
`AuroraMeter.Test.LedgerFixtures.corrupt!/3`, and that is the point of them: a
database that has been hand repaired really can hold such a row, and the
migration's job is to refuse it rather than to guess.

The column "built by" says which.

## The catalogue

| Flag | Built by | The wallet | What the operator sees |
|---|---|---|---|
| `reversal_unattributed` | the API | a 5 USD payment, then `Credits.reverse/4` with a reference and metadata that name no payment intent | the refund cannot be tied to the payment it took back. Attributing it to the wallet's oldest paid lot would be inventing provenance, which 06.02 forbids by name |
| `reversal_exceeds_lots` | the API | a 1 USD payment `pi_b`, then a 3 USD refund naming `pi_b` | the reversal takes back more than that payment ever granted. Usually two reversals of one payment, or a reversal of a grant that was itself reversed |
| `reversal_took_reserved` | the API | a 2 USD payment wholly reserved by an open hold, then a 1 USD refund naming it | the refund would have to take value a pending hold has reserved, which moves `held` and the legacy row says it did not. Settle or release the hold first |
| `unparsable_restore_reference` | the API | an `:adjustment` grant whose reference is `reinstated:not-an-intent:100` | the reference has the shape of a payment restoration and carries no payment id, so the lot it would create has no provenance to copy |
| `hold_unbacked` | the API | `:credits_overdraft_tolerance` set to 3 USD, a 1 USD payment, then a 3 USD hold | **two causes, and the detail's `debt` separates them.** With `debt == 0`: the legacy ledger allowed the hold on `balance - held + tolerance` and a lot reserves exact value, of which there is none. With `debt > 0`: the wallet owes money and the planner refuses any hold, while the legacy ledger accepted one because `sum(available) - debt` still covered it. The second is a consequence of finding X262 and would disappear if a reversal repaid debt |
| `orphan_settle` | `corrupt!/3` | a paid wallet plus a `settle` row whose reference matches no hold | the settlement cannot be tied to what it closed, so the value it consumed cannot be taken from the right reservation |
| `orphan_release` | `corrupt!/3` | the same with a `release` row | as above |
| `unsupported_row` | `corrupt!/3` | a paid wallet plus a row of kind `:reverse` | `AuroraMeter.Schema.CreditTransaction` declares seven kinds and the ledger writes six. A row of the seventh has no replay rule, and the fold is total rather than silently skipping it |
| `expire_unattributed` | `corrupt!/3` | a partially expired promotional grant whose `expire` row lost its `metadata["grant_id"]` | the expiry names no grant, so the fold cannot tell which lot lost the value |
| `expire_over_lot` | `corrupt!/3` | the same wallet with the expire row's amount multiplied by ten | the expiry claims to have destroyed more than the grant held |
| `expire_reserved_grant` | the API | a 1 USD promotion expiring soonest, a 10 USD promotion expiring later, a 1 USD hold, then the sweep | **found by the generated-history property.** The legacy expiry guard is `max(balance - held, 0)` for the whole wallet, not per grant, so the later promotion covers the held amount and the sweep destroys the grant the hold was actually reserving. See below (finding X261) |
| `promotional_divergence` | the API | a 5 USD payment, spent; then a 4 USD promotion; then a 5 USD refund of the payment | see below. **Two causes, and the detail's `kind` says which.** The named fixture is the refund clamp; the generated-history property showed the common one is a hold reserving promotional credit (finding X263) |
| `projection_mismatch` | the API plus one edited row | a paid wallet whose balance row is one micro-dollar out | the replay reconciles against itself and not against the row. This is the flag that catches a balance row that had already drifted from its own log |
| `history_out_of_order` | the API plus two edited rows | a wallet with two rows stamped in the opposite order to their commit order **and** a third row whose `balance_after` is wrong | neither candidate ordering reproduces the chain, so the order the history really happened in cannot be recovered from what the rows carry |

Two further flags are informational and never block:
`promotional_clamped` (a promotional grant that landed while the wallet owed
money) and `reserved_on_expiring_lot` (a hold still open at cutover against a
lot that carries an expiry, which is the I12 population the report exists to
name). `internal_projection_drift` and `exception` block and have no fixture:
the first is a self-check with no natural trigger and is exercised by negative
control C4, the second by the fault-injection test that fails the balance
update inside the cutover transaction.

## The one that is not a corruption: `promotional_divergence`

This is the only refusal in the list that a perfectly healthy 0.4.0 wallet can
earn, so it is worth the arithmetic.

The legacy ledger clamps the promotional figure to the balance after every
entry: `promotional = min(promotional_after_delta, max(balance_after, 0))`
(`Credits.Ledger.apply_entry/3`). A reversal does not reduce `promotional`
directly, because a refunded top-up must not quietly spend a sign-up bonus, but
the clamp still applies. So a refund that drives the balance below zero sets
`promotional` to zero and the promotion is gone from the wallet's account of
itself for ever.

The lot model does not clamp. The promotional lot keeps its value, the refund
becomes `debt` against the paid lot it belongs to, and `balance` is
`sum(available + reserved) - debt`, which is the same number.

Worked, in dollars:

| Step | legacy `balance` | legacy `promotional` | lots |
|---|---|---|---|
| grant 5 paid `pi_e` | 5 | 0 | paid available 5 |
| debit 5 | 0 | 0 | paid consumed 5 |
| grant 4 promotional | 4 | 4 | promo available 4 |
| refund 5 of `pi_e` | -1 | **0** | promo available 4, paid reversed 5, debt 5 |

The lot model's projection is `balance = 4 - 5 = -1`, which matches, and
`promotional = 4`, which does not. Both accounts agree on what the customer can
spend (`-1` either way); they disagree on how much of the wallet is
promotional, and the migration will not pick a winner.

The consequence for the installed base is real and is stated rather than
softened: **a wallet that took a refund into debt while holding live
promotional credit cannot be migrated automatically.** It keeps working on the
legacy writer. Deciding such a wallet needs a person with that customer's
history in front of them, and a supervised per-wallet override belongs to a
later release, not to this one.

## The bigger cause of the same flag, which a generator found

The wallet above is the one this unit built by hand, and **it is the rare
case**. In 280 generated legacy histories across seven fixed seeds, a
`promotional_divergence` raised by a reversal appeared **zero** times. Fifty
four appeared, and every one of them was raised by a `debit`, a `settle`, a
`grant` or a `release`.

The mechanism is the other half of the same missing idea. `promotional_delta/2`
(`Credits.Ledger`) subtracts the **whole** of a negative amount from
`promotional`, on the assumption that promotional credit is always spent first.
That is true of an unencumbered wallet and false the moment a hold has reserved
promotional value, because a debit cannot spend a reservation. Worked, in
micro-dollars:

| Step | legacy `promotional` | lots |
|---|---|---|
| grant 10 promotional | 10 | promo available 10 |
| grant 10 paid | 10 | promo 10, paid 10 |
| hold 1 | 10 | promo available 9, **reserved 1**, paid 10 |
| debit 10 | 10 - 10 = **0** | promo available 0 reserved 1, paid consumed 1: **1** |

The legacy figure says the wallet holds no promotional credit; the lots say it
holds one micro-dollar, reserved by a hold that has not settled. The lots are
**right**, and there is no lot assignment that produces the legacy number
without writing a lot that is wrong, so the wallet blocks (finding X263).

The same missing idea produces `expire_reserved_grant`:
`Ledger.expire_locked/4` clamps the amount it expires by
`max(balance - held, 0)` for the **whole wallet**, so when another grant covers
the held amount the sweep destroys the grant a hold was reserving. Expiring
only the available part moves the balance by less than the row says; expiring
the reserved part as well moves `held`, which the row says did not move. Either
way the row cannot be reproduced (finding X261).

**This is the number that matters most in this unit.** Across 287 generated
histories, 198 reconciled exactly and 89 were refused, and 67 of those 89 were
one of these two shapes. A wallet that has ever combined promotional credit
with a hold is likely to be unmigratable, and the reason is a defect in the
legacy arithmetic that the lot model fixes rather than an ambiguity in the
history.

## What `--retry-blocked` is for, and what a later run still reports

Nothing retries a blocked wallet inside a run, and nothing repeats the replay on
the next run either: the wallet's checkpoint already says `blocked` and nothing
about the wallet has changed, so the work is not free and would reach the same
answer. `--retry-blocked` is the operator saying "I have fixed the data, look
again"; it also picks up wallets an operator paused.

**The verdict is still reported and still counted.** A later run records the
wallet as `blocked` with the reason `blocked_before`, its own reasons left
untouched on the checkpoint row, so the run's exit status is non-zero and the
summary names it. The first draft of this unit skipped such a wallet silently,
and the consequence was found in the evidence run rather than by a test: the
shadow run reported two blocked wallets and exited non-zero, and the real run
that followed reported `blocked 0` and would have exited **zero** with both
wallets still on the legacy writer. That is "a skipped required suite is a
failure" applied to money, and
`test I19 a wallet a previous run blocked is still counted as blocked by the next one`
is what now stops it coming back.
