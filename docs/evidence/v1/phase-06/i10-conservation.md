# I10: every ledger amount has exact provenance and conservation (06a's contribution)

Invariant I10 is owned by 01e, which proves it **behaviourally** by comparing a
generated history against an independent pure model. 06a adds the **structural**
half: after the lot cutover the database refuses to commit a violating row at
all. `docs/correctness.md` states both strengths, as `invariant-map.md` requires.

All runs: core `57996c5` plus this unit's uncommitted changes, PostgreSQL 16.13
on port 5490, Elixir 1.20.1, OTP 29, seed 0.

## The three layers, and what each one catches

| Layer | Where | What it refuses | Test |
|---|---|---|---|
| 1. per-row CHECK | `aurora_meter_credit_lots` | a lot whose five quantities do not add up to its amount, a negative quantity, a `state` that disagrees with the quantities | `AuroraMeter.CreditsLotsTest` / `test I10 a lot edited by hand is refused by aurora_meter_credit_lots_conservation_check` |
| 2. the allocation trail | `aurora_meter_credit_allocations` | nothing; it is a **record**, and what it buys is that a lot's quantities can be rebuilt rather than trusted | `AuroraMeter.CreditsLotsTest` / `test I10 every lot quantity is reproduced by folding that lot's allocations` |
| 3. the in-transaction projection check | `Allocator.check!/4` | a balance row that disagrees with a `SUM` over the wallet's lots | `AuroraMeter.CreditsLotsTest` / `test I10 a balance row edited by hand raises ConservationError and the write is rolled back` |

### Where conservation is checked, exactly

At the end of **every** ledger transaction on a wallet with `lots_enabled_at`
set, after the allocations, the lot updates and the balance update, and before
the transaction commits.

### What it compares

Two independently derived statements of the same four numbers.

* **The row**, moved by the plan's deltas: `row.balance + deltas.balance`, and
  the same for `held`, `promotional` and `expired`, with `debt` set to
  `row.debt + plan.debt_delta`.
* **The lots**, re-read from the database inside the same transaction:

      SELECT coalesce(sum(available), 0)::bigint,
             coalesce(sum(reserved), 0)::bigint,
             coalesce(sum(available + reserved)
                      FILTER (WHERE category = 'promotional'), 0)::bigint,
             coalesce(sum(expired), 0)::bigint
        FROM aurora_meter_credit_lots
       WHERE tenant_key = $1

  from which `balance = available + reserved - debt`, `held = reserved`,
  `promotional` and `expired` follow.

**Deltas and not absolutes, and that is the whole check.** The first
implementation wrote the balance row from `Allocator.projection/2` over the
planner's own book and then compared it with the sum over the lots. Those are
the same arithmetic run twice: they could not disagree, and a check that cannot
fail proves nothing. Moving the row by a delta makes the lots an independent
statement, so a row that had **already** drifted is caught by the next write to
it, which is what the acceptance criterion asks for. The mistake and its fix are
in `lib/aurora_meter/credits/allocator.ex`'s `deltas/4` doc.

### What it does when it fails

Emits `[:aurora_meter, :credits, :conservation_error]` with the four deltas and
`%{tenant_key, operation, reference}`, then **raises**
`AuroraMeter.Credits.ConservationError`. The raise aborts the transaction, so
nothing is written and the wallet is exactly as it was. It is a raise and not an
error tuple because a `with` chain can swallow a tuple, and this is the one
thing that must never be swallowed. The wallet then refuses every further write
until a human looks at it; reads keep working so the lots, the allocations and
the ledger can all be inspected.

## The deliberate-corruption runs

### A hand-edited lot row

    UPDATE aurora_meter_credit_lots SET available = available + 1 WHERE id = $1

    ** (Postgrex.Error) ERROR 23514 (check_violation)
       new row for relation "aurora_meter_credit_lots" violates check constraint
       "aurora_meter_credit_lots_conservation_check"

The test asserts the constraint **name**, not just that something failed.

**The negative control, in the same test.** The same statement written to keep
the sum (`available = available - 1, consumed = consumed + 1`) is accepted, one
row changed. So it is the conservation constraint that answered and not
something about `UPDATE` on this table.

### A hand-edited balance row

    UPDATE aurora_meter_credit_balances SET balance = balance + 1 WHERE tenant_key = $1

then an ordinary `Credits.debit/4`:

    ** (AuroraMeter.Credits.ConservationError) Aurora Meter credit conservation
       failed for tenant "lots_..." during debit: the balance row and the
       wallet's credit lots disagree.

         balance row : %{balance: 5000001, expired: 0, held: 0, promotional: 0}
         lots say    : %{balance: 5000000, expired: 0, held: 0, promotional: 0}
         difference  : %{balance: 1, expired: 0, held: 0, promotional: 0}

       Nothing was written: the transaction has been rolled back and the wallet
       is unchanged. ...

Asserted after the raise: the credit-transaction count and the allocation count
are unchanged, the lot still holds its full 5 USD, and the balance row still
holds the hand-written `5000001`. The write really was rolled back rather than
partially applied.

### A negative `held`, `promotional`, `debt` or `expired`

Each is refused by its own named constraint
(`aurora_meter_credit_balances_held_check` and the three beside it). This is
finding **X183**'s remedy: before schema version 9 those columns were bare
`bigint` and the only thing standing between a lost row lock and silent
corruption was the lock itself.

## Conservation as a property rather than an assertion at the end

Three places make it a property:

1. `AuroraMeter.Credits.AllocatorTest`'s StreamData property
   (`property I10 every planned movement conserves: each lot's five buckets
   still sum to its amount`) checks it after **every** generated plan over a
   generated book, together with the wallet law that a debit moves the balance
   by exactly its amount and a hold does not move it at all.
2. The applier runs the check after every write, so a ledger write that would
   break it does not commit.
3. `AuroraMeter.CreditsLotsConcurrencyTest` /
   `test I10 concurrent grants and debits on one wallet leave the projection
   exact` asserts it after twenty interleaved writes from independent
   connections, reading the lots and the row separately.
4. `AuroraMeter.CreditsLotsTest` /
   `property I10 a generated history on a lot wallet reconstructs the balance
   row, the debt, the held amount and every lot's allocations` replays up to
   twelve generated commands (grants of all three categories with a past,
   future or absent expiry; holds; settles of any size including above the
   hold; releases; debits; expiry sweeps) through the real ledger, and then
   reconstructs the rows three ways: every lot's five quantities folded from
   that lot's own allocations, the balance row projected from the lots, and the
   balance summed from the ledger's `amount` column. Refusals are accepted as
   legal outcomes; a raise is not, so a `ConservationError` anywhere in a
   generated sequence fails the property. This is **G06 bullet 4** for the lot
   half.

## The second oracle

The three layers above all read the same database. 01e's
`LedgerModel.lot_view/1`, written from `architecture-map.md` section 7 before
06a existed, is a **fourth** and independent one, and it found three defects the
other three could not: see `06a-report.md` section 7b and finding X251. The
worst of them, a settlement handing back its hold's original per-lot reservation
instead of the remainder, satisfied every conservation layer on this page while
quietly taking another hold's reservation into `available`.

## Under process death and injected faults

`AuroraMeter.CreditsLotsFaultsTest` (finding X243) asserts the conservation
property re-read from the database after each of four kills at the stage
boundaries of a lot-path transaction and each of four injected raises, so a
fault that left a lot row moved without its allocation fails there even though
nothing reached a caller. Two negative controls run the same harness with
nothing armed, because every "nothing happened" assertion would otherwise be
satisfied by a writer that never ran.

## The negative control for the allocation trail

`tmp/v1/06a-control.py break` drops every `:expire` movement from
`Allocator.write_allocations!/5` and changes nothing else, so the lot rows move
and their trail does not.

| | |
|---|---|
| Before | `lib/aurora_meter/credits/allocator.ex` sha256 `e9f3e5b4326168947b0d555b6bdbe51b773139c85b9b2d158a8421ed37948fca` |
| Broken | sha256 `39f6c973e24f5b412ac7371e0fd02834294db77cd19c1ebdb9d674907b5e593a` |
| Result | **3 of 19 failed**: the property and the two expiry tests |
| The property's counterexample | shrunk to two commands: `[{:grant, 3150734, :promotional, :past}, {:expire}]`, reporting `trail says available: 3150734` against `row says expired: 3150734` |
| After restore | sha256 back to `e9f3e5b4...`, 19 passed |

So the property is about the trail rather than about the rows agreeing with
themselves. Note what it did **not** catch: the balance projection assertions
all still passed, because the lot rows were written correctly and only their
trail was missing. That is the X242 lesson applied here, and it is why the
per-lot fold is a separate assertion rather than folded into the projection
check.

## Logs and seeds

| Run | Seed | Result | Log |
|---|---|---|---|
| `mix test test/aurora_meter/credits/allocator_test.exs` | 0 | 11 passed (1 property) | `logs/06a-check.log` |
| `mix test test/aurora_meter/credits_lots_test.exs` | 0 | 18 passed | `logs/06a-check.log` |
| `mix check` (whole suite) | 0 | 1450 passed, exit 0 | `logs/06a-check.log` |
