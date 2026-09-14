# ADR 0011: Credit lots and allocations

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADR: 0005 (prepaid credit ledger), whose wallet row and transaction
log this decision keeps and reinterprets. Mechanism detail lives in
`PhxTemplates/docs/v1/build-plans/architecture-map.md` section 7.

## Context

The ledger keeps one `promotional` figure per wallet and reconstructs per grant
state by replaying the whole tenant ledger under both locks for every due expiry
(`ledger.ex:340-349`). Four observable problems follow.

Per grant provenance cannot be reconstructed. Nothing in the wallet row says
which payment funded which spendable value, so a refund can only reconcile a
cumulative figure and cannot be explained to the customer who asked for it.

A settlement above the estimate drives the balance negative with only a telemetry
flag (`ledger.ex:167`). Negative balance is an implicit state that every caller
has to remember to check for.

A reservation released against an already expired grant becomes spendable again
until the next expiry pass (`ledger.ex:296-305`), which is a direct violation of
I12.

Partial expiry references are not idempotent (`ledger.ex:355-357`), and expiry
cost grows with the length of the tenant's history rather than with the number of
grants that are actually due.

## Decision

1. **Lots are the source of per grant truth.** `aurora_meter_credit_lots` holds
   `amount`, `available`, `reserved`, `consumed`, `reversed` and `expired`, with a
   check constraint that the five parts sum to `amount`.
   `aurora_meter_credit_allocations` records every movement with a kind
   (`reserve | unreserve | consume | expire | reverse | restore`) and the ledger
   transaction that caused it.
2. **The balance row becomes a checked projection.** After cutover,
   `balance = sum(available + reserved) - debt`, `held = sum(reserved)` and
   `promotional = sum over promotional lots`. A write that would break the
   identity rolls back with `AuroraMeter.Credits.ConservationError`.
3. **Debt is explicit.** A settlement above the reserved amount consumes remaining
   eligible availability and records the unavoidable remainder in a `debt` column.
   New holds and debits are refused while `debt > 0`, and every incoming grant
   repays debt first. Negative balance stops being an implicit state.
4. **Allocation order is fixed and is not customer configurable (D07).**
   Promotional before paid, with adjustment treated as paid; then earliest non
   null expiry; then oldest grant; then id. Non expiring lots come last within
   their category. Only the promotional half of this restates today's behaviour:
   ordering paid lots oldest first is new, and it is what lets a refund find the
   payment that funded it.
5. **Lock order is fixed.** Balance row `FOR UPDATE`, then the specific transaction
   rows needed (hold or grant) `FOR UPDATE`, then lots `FOR UPDATE ORDER BY id`.
   No network call may occur between taking the balance lock and commit. This
   reverses today's settle, release and expiry order, which locks the transaction
   row first. Unit 05b lands hold recovery against the current order and unit 06a
   switches every path and reruns 05b's tests, so the two orders are never in the
   tree at the same time.
6. **Expiry only removes `available`.** Reserved value on an expired lot stays
   reserved and becomes `expired` when it is released. It never becomes spendable
   again (I12).
7. **Legacy wallets cut over one at a time.** `lots_enabled_at` is null until
   `mix aurora_meter.credits.migrate_lots` replays that wallet and reconciles it
   exactly. The flag is read under the balance row lock, so the legacy writer and
   the allocator can never both write one wallet. Wallets whose attribution cannot
   be proved (pre version 4 rows without `promotional_after`, overlapping
   promotions over a negative balance, partial expiry with prior holds) are
   reported and left on the legacy path rather than guessed at.
8. **Recurring grants are keyed**
   `"recurring:<entitlement>:<plan_id>:<plan_version>:<period_start_iso>"`, unique
   per tenant, so two schedulers produce one grant (I18). The `recurring:`
   reference prefix is reserved and is rejected for caller supplied references.

The reversal bucket order is part of the contract, not an implementation detail:
available, then consumed, then reserved. Taking from `available` or `reserved`
moves the balance directly, while taking from `consumed` is money already spent
and must raise `debt`, so draining `available` first minimises the debt a refund
creates. `reserved` is taken last because an open hold represents work the host
believes is still running.

## Consequences

Money stays integer micro-USD and USD only (D06). There is no currency conversion
and no multi currency wallet in V1.

A mixed fleet during the wallet migration is safe only when every node honours
`lots_enabled_at`, which means every node must be on 1.0.0-rc.1 or later before S5
runs. This is a documented quiescence requirement for the wallet migration, not
for the DDL.

Application rollback after S5 is not supported. A previous image would ignore lots
and write the wallet with the legacy arithmetic, so the only recovery for
financial writes made after cutover is a data restore. Forward fix only.

Customers get provenance per grant: which payment funded which value, what was
spent, what expired and what was reversed. They do not get a configurable
allocation engine. Spend order is a correctness property that a refund cap reads,
so making it a customer setting would make refunds unexplainable.

Conservation has two strengths and both are stated, because the guarantee table
and `docs/correctness.md` quote this paragraph: before the lot cutover I10 is
proven behaviourally by a property model comparison, and after it the database
refuses to commit a violating row at all.

## Migration impact

S4 (core version 9: the three lot tables and the balance, transaction column
additions, all additive and transactional) and S5 (the per wallet migration task,
resumable, with a shadow mode that computes and reports without writing).
Rollback position: yes after S4 and before S5; no after S5, forward fix only.

## Verification

Unit 01e (I10 property model), 06a (I10, I11, I12), 06b (migration conservation
and interrupted resume), 06d (I18) and 06e (the Pro integration). None of these
tests exists yet and none is claimed to pass.
