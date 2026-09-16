# Upgrading a wallet to credit lots

Aurora Meter's credit ledger used to keep three numbers per tenant: `balance`,
`held` and `promotional`. From core schema version 9 it can instead keep one
**lot** per grant, with explicit allocations recording every movement of value
between a lot's buckets. A lot knows which payment funded it, when it expires
and how much of it is left, which is what makes a refund able to find the
payment it belongs to and an overlapping promotion able to explain itself.

This page is the procedure for moving an existing installation onto lots. It is
written for the person running the upgrade, not for the person who wrote it.

## What changes, and what does not

A wallet is on lots when its `aurora_meter_credit_balances.lots_enabled_at` is
set. Until then it is on the legacy writer and behaves exactly as it did in
0.4.0. Nothing sets the column except the migration described here.

`balance`, `held` and `promotional` keep their meaning and their values. After
cutover they are a **checked projection** of the wallet's lots: every ledger
write recomputes them from the lots and refuses to commit if the two disagree.
Two figures join them, both zero on a legacy wallet:

| Column | Meaning |
|---|---|
| `debt` | executed cost the wallet could not fund, or a refund of credit it had already spent. Every incoming grant repays it before creating spendable value, as does credit the wallet already holds **unless that credit is promotional**, and no hold or debit may spend while it is outstanding. A wallet can therefore hold a live promotion and owe money at once, and spend neither until a grant clears the debt. `balance/1` says so in two places: `spendable` and `promotional_spendable` both read `0` while `debt` is outstanding, and `hold/4` and `debit/4` refuse with `{:error, :debt_outstanding}` rather than `:insufficient_credits`. The full state, and what clears it, is under "Debt" in `credits.md` |
| `expired` | value destroyed by expiry, kept apart from value spent so the two are never confused |

Two behaviours change for a wallet that has been cut over, and both are
deliberate:

- Credit whose `expires_at` has passed is not spendable, even if the expiry
  sweep has not reached it yet. Before, it stayed spendable until the sweep ran.
- Value a hold was still holding on a lot past its expiry is written off when
  the hold is released, rather than handed back as spendable credit.
- A cut-over wallet can refuse with a reason a legacy wallet never returns.
  `hold/4` and `debit/4` answer `{:error, :debt_outstanding}` when the wallet
  owes money; a legacy wallet has no `debt` and goes on answering
  `:insufficient_credits`, including when its balance is negative. **A caller
  that matches `{:error, :insufficient_credits}` has to add the new term before
  the first wallet is cut over.**

The migration's per-wallet report names every wallet that held such a
reservation at cutover, under the flag `reserved_on_expiring_lot`.

## Before you start

1. **Core schema version 9 must be applied.** The task refuses to start below
   it.
2. **Every node must be running a release that honours `lots_enabled_at`**,
   which means 1.0.0-rc.1 or later. A node on an older image ignores the column
   entirely and would keep writing legacy arithmetic to a wallet the allocator
   now owns. No code can detect that, so it is your step, not the task's. The
   damage is not silent: the next ledger write on such a wallet raises
   `AuroraMeter.Credits.ConservationError` rather than absorbing the difference.
3. **Take a backup.** After a wallet is cut over there is no rollback to the
   legacy writer: an older image would ignore the lots and write on top of
   them. The forward fix is to correct the code and re-run the conservation
   check; the fix of last resort is a restore.

## The procedure

### 1. Run it in shadow, and read the report

```
mix aurora_meter.credits.migrate_lots -r MyApp.Repo
```

Shadow is the default. The task replays every wallet, reconciles the replay
against that wallet's own balance row, and writes nothing but checkpoint rows.
It prints a summary and a line per wallet it could not migrate.

Read the blocked list before doing anything else. A shadow run reaches the same
verdict as the real run that follows it, so the list you get here is the list
you will get for real.

**Expect it to be long if your wallets combine promotional credit with holds.**
In 280 generated legacy histories, 69 per cent reconciled exactly and the
majority of the rest were refused for one of two reasons that come from the
same place: the pre-1.0 ledger kept one `promotional` number and one `held`
number per wallet, with no record of which grant a hold was reserving, so both
figures can be wrong in ways the lots make visible and cannot reproduce. Those
wallets keep working exactly as they do today; they simply stay on the legacy
writer.

### 2. Deal with the blocked wallets

A blocked wallet is not migrated, nothing is written for it, and it keeps
working on the legacy writer indefinitely. That is a supported state, not a
broken one: a wallet may stay on the legacy path for ever without losing any
function. What it loses is per-payment provenance, which matters when a refund
arrives.

The reason is on the wallet's checkpoint row:

```elixir
AuroraMeter.Credits.LotMigration.status()
```

| Flag | What it means | What to do |
|---|---|---|
| `reversal_unattributed` | a refund or chargeback in the history names no payment this installation can resolve | nothing automatic. The ledger never recorded which payment the reversal belonged to, and inventing one would put a customer's money against the wrong grant. Wallets written by Aurora Meter Pro 0.2.0 and later carry the payment intent and do resolve |
| `reversal_exceeds_lots` | a reversal took back more than the payment it names ever granted | inspect the wallet: it usually means two reversals of one payment, or a reversal against a grant that was itself reversed |
| `reversal_took_reserved` | a reversal would have to take value a pending hold has reserved | settle or release the hold, then re-run with `--retry-blocked` |
| `hold_unbacked` | either a hold that `:credits_overdraft_tolerance` let through with no credit to reserve, or a hold taken while the wallet owed money. The reason's `debt` figure says which | settle or release the hold, then re-run with `--retry-blocked` |
| `orphan_settle`, `orphan_release` | a settlement or release with no hold in the history | the history has been edited by hand. Investigate before migrating |
| `expire_unattributed`, `expire_over_lot` | an expiry row that names no grant, or one far larger than the grant it names | as above |
| `expire_reserved_grant` | an expiry that asks for more of a grant than the lots hold, by an amount a hold somewhere in the wallet explains. Either the sweep destroyed a grant a hold was reserving (its guard is the whole wallet's `balance - held`), or a hold on a **different** grant pushed an earlier spend onto this one | nothing to repair: the wallet's own figures are inconsistent about which grant a hold was holding, and the amounts are usually tiny. It keeps working on the legacy writer. The reason carries `available`, `reserved` and `wallet_reserved` so you can see which of the two it is |
| `promotional_divergence` | the wallet's `promotional` figure and its lots disagree. The common cause is a hold reserving promotional credit, which the single `promotional` figure cannot see, so a later spend reduced it by more than was actually spent from promotions; the rarer one is a refund that drove the balance below the promotional total | the two accounts genuinely disagree about what the customer holds, and the lots are the more accurate of the two. Decide the correct figure with the customer's history in front of you; there is no safe automatic answer |
| `unparsable_restore_reference` | an adjustment whose reference looks like a payment restoration but carries no payment id | the history has been edited by hand. Investigate before migrating |
| `ledger_chain_mismatch`, `history_out_of_order` | the log does not add up to the balance row under any ordering the rows support | investigate. This is the flag that says the wallet's own history is inconsistent, not that the migration is confused |
| `projection_mismatch` | the replay reconciled internally but did not match the balance row | as above |

`--retry-blocked` re-processes wallets a previous run blocked. It is what you
run after fixing the underlying data; nothing retries automatically.

A later run does not repeat the replay for a wallet already reported blocked,
and it does still **report** it, with the reason `blocked_before` and its
original reasons untouched on the checkpoint row. So the run keeps exiting
non-zero until every wallet is either migrated or deliberately paused. That is
the intended nuisance: unmigrated money should keep asking for attention.

### 3. Deal with the deferred wallets

| Reason | What it means | What to do |
|---|---|---|
| `too_large` | the wallet has more ledger rows than `--max-rows` (default 50000). It is **paused** rather than migrated, so the lock it would need is never taken by accident | pick a maintenance window, `AuroraMeter.Operations.resume("lot_migration:<scope>")`, then re-run with a higher `--max-rows` |
| `too_busy` | more rows were committed during the snapshot than `--max-tail` allows to be folded in under the lock | re-run during a quieter period, or raise `--max-tail` |

The checkpoint name for a wallet is
`AuroraMeter.Credits.LotMigration.checkpoint_name(tenant_key)`. It is
`"lot_migration:<tenant_key>"` when the key is a legal operation name and
`"lot_migration:sha256-<digest>"` when it is not, because a tenant key is yours
and may contain anything.

### 4. Run it for real

```
mix aurora_meter.credits.migrate_lots -r MyApp.Repo --no-shadow
```

One wallet is one transaction: it is either entirely migrated or entirely
untouched. The balance row lock is held only for the verify and the writes, not
for the replay, so a wallet with a long history costs the live path one short
lock rather than a long stall. The run is resumable: killing it loses at most
the wallet in flight, and re-running skips every wallet that already committed.

The run exits non-zero if any wallet was blocked, so a runner cannot report
success while wallets were left behind.

> **This step is permitted from this release, and it was refused before it.**
> The refusal existed because `AuroraMeter.Credits.reverse/4` did not take the
> lot path, so a paid refund on a cut-over wallet consumed promotional credit
> the refund had no claim on. Both refund calls are lot aware now:
> `reverse_lot/4` is scoped to one payment's lots and capped by them, and
> `reverse/4` takes the wallet's non-promotional lots in spend order. A cut-over
> wallet is safe on either.
>
> `--no-shadow` is the whole ask at the command line: the task turns it into
> `allow_cutover: true` for you, because a run that writes is the only thing
> `--no-shadow` can mean. From `run/1` the two are separate and both are
> required. Everything above works without either: the replay, the
> reconciliation and the blocked list are all produced by the shadow run, so the
> whole upgrade can be rehearsed first.

### 5. Read the report again

```elixir
AuroraMeter.Credits.LotMigration.status()
```

Every migrated wallet's checkpoint carries the three figures before and after,
the lot and allocation counts, how long its balance row lock was held, and any
informational flags. Nothing in it is a customer identifier beyond the tenant
key you chose.

## A large installation

Two bounds are worth knowing before the first run on a database with a lot of
wallets.

The run holds one report in memory per wallet it examines, and `status/1` reads
every checkpoint row this unit has written. Neither is paged. `--max-wallets`
(default 100000) is what bounds a run, and the cursor means the next run picks
up where it left off:

    mix aurora_meter.credits.migrate_lots -r MyApp.Repo --max-wallets 5000

Run it repeatedly until `status/1` reports a cursor at the end of the table. The
run is safe to interrupt and safe to repeat at any point.

## What the migration will not do

- It never writes `balance`, `held`, `promotional`, `currency` or
  `low_balance_threshold`.
- It never changes a historical ledger row except to fill in
  `hold_transaction_id`, which was null on every row written before version 9.
- It never deletes anything.
- It never rounds, adjusts or nudges a figure to make a wallet reconcile. A
  wallet that does not reconcile exactly is not migrated.
- It never contacts a payment provider and never sends mail.

## Running it without Mix

A release without Mix can run the same thing from a remote console:

```elixir
AuroraMeter.Credits.LotMigration.run(shadow: true)
AuroraMeter.Credits.LotMigration.run(shadow: false, allow_cutover: true)
AuroraMeter.Credits.LotMigration.status()
```

The options are the Mix task's flags with underscores.
