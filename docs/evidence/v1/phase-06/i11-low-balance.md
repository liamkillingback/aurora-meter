# I11: one low-balance alert per crossing

V1 task **06.07**: "low-balance signals use the spendable amount and avoid
duplicate threshold alerts on replay". Lower-level invariants **LI-06c-1** (one
alert per crossing) and **LI-06c-2** (a handler cannot fail a write).

Tests: `AuroraMeter.CreditsLowBalanceTest`, eight, all `I11`. Trace log
`tmp/v1/06c-logs/lowbal-deferral-trace.log` sha256
`4a4542151a77f3c83f12e74913d68fc0bd157d4355ee31c6b856ac10973ba47b`, seed 0,
2026-09-15, 14 passed (this file's eight plus `06c-deferral.md`'s six).

## The mechanism, in one paragraph

The crossing's identity is a column on the balance row,
`low_balance_crossing_id`, and it is written **inside the same transaction as
the balance change that caused it**, under the lock that transaction already
holds. Alerting is therefore not a comparison of two figures across two writes,
which is what the old edge-triggered rule was; it is a state on the row, and
that state rolls back with the write that set it.

The trigger figure is `spendable`, not `balance - held`.

## The crossing matrix

**Every count below is a count of `{:aurora_meter, :low_balance, event}`
broadcasts**, not of handler invocations, and the distinction is finding X269's.
The broadcast is sent **synchronously by the writer** before anything else, so
once the writes have returned every broadcast that will ever happen is already
in the test's mailbox and the count is exact. Delivery to the handler happens in
a watcher process and is asserted separately with `assert_receive`, because it
is a different claim: the crossing is a property of the ledger, the handler is a
delivery mechanism documented as at most once.

A threshold of 5 USD throughout except where stated.

| # | Scenario | Crossings broadcast | `low_balance_crossing_id` after | Test |
|---|---|---|---|---|
| 1 | grant 10, set threshold 5, debit 6 | **1** | set to the debit's id | `fires once per crossing…` |
| 2 | then five more debits of 0.001 each, all below the line | **still 1** | **unchanged**, the same id | same |
| 3 | grant 6 back, above the threshold | still 1, **no alert on the way up** | cleared to `nil` | `a recovery… then a second crossing…` |
| 4 | debit 6 again | **2** | a **different** id | same |
| 5 | debit under a reference already used (`:duplicate_reference`) | **1** | unchanged | `a replayed reconciliation cycle…` |
| 6 | a redelivered grant that returns the existing entry | **1** | unchanged | same |
| 7 | threshold lowered from 5 to 2, wallet at 4 | still 1, **no alert** | **cleared** | `lowering the threshold…` |
| 8 | then debit 3, wallet at 1 | **2** | a new id, threshold 2 | same |
| 9 | threshold set to `nil` | no alert | **cleared** | same |
| 10 | no threshold at all, grant 10 then debit 9 | **0** | `nil` | `no threshold means no crossing…` |
| 11 | a wallet whose only funds are on an expired lot, threshold 5 | **1** | set | `the trigger uses spendable…` |

Row 2 is the one the old behaviour would also have passed, **if the assertion
were "at least once"**. It is not: it is `length(events) == 1` with a message
naming the actual count, and the crossing id is asserted to be the same object
across all five later writes.

Row 11 is the difference between `spendable` and `available`, measured: the
wallet's `available` is 10.001 USD, well above its 5 USD threshold, and its
`spendable` is 0.001 USD because the 10 USD is past its `expires_at`. The test
asserts **both** figures on the event, so the assertion that fails if `spendable`
were a copy of `available` is right there:

```elixir
assert snapshot.available == 10 * @dollar + 1000
assert snapshot.spendable == 1000
assert hd(events).spendable == 1000
assert hd(events).available == 10 * @dollar + 1000
```

## The handler cannot fail, block or delay a write

| Handler | Ledger call returns | Write | Telemetry `handler:` | Crossing |
|---|---|---|---|---|
| raises `RuntimeError` | `{:ok, %CreditTransaction{kind: :debit}}` | committed, balance 4 USD, one `:debit` row | `:raised` | set |
| never returns, `timeout: 50` | `{:ok, txn}` in **under 50 ms**, which is less than the timeout | committed, balance 4 USD | `:timeout` | set |
| none configured | `{:ok, txn}` | committed | `:none` | set |
| reads the database, inside `Repo.checkout/1` | `{:ok, txn}` | committed | `:ok`, and the handler's read returned 4 USD | set |

The second row used to read "after **under 500 ms**", a bound ten times the
timeout. It is now "in under 50 ms", which is less than the timeout itself: the
caller does not wait for the handler at all. **That is finding X269**, and the
fourth row is its regression.

The raising case's log line, from the trace:

```
[warning] AuroraMeter.Credits: the low-balance handler raised the host's handler
is broken for tenant "lowbal_467" (crossing "16e2f8a7-…"). The ledger write
stands and no alert was delivered; the crossing is already recorded, so no later
write will re-send it.
```

**At most once, and the flag is why.** The crossing means "this crossing has
been decided", not "this alert was delivered". Clearing the flag when a handler
failed would re-alert on every subsequent write from a wallet whose handler is
broken, which is the failure mode `open-findings.md` P29 already records for
Pro's own alert dedupe. The operator remedy, documented in `docs/credits.md`, is
to lower and restore the threshold.

The timing assertion is a bound rather than a guess: `elapsed < 500` against a
50 ms timeout is ten times the budget and still two orders of magnitude below
"never returned", so it cannot pass by accident on a loaded machine and cannot
pass at all if the task were awaited without a timeout.

## Negative controls

Each break is one line, reverted immediately, with the file's sha256 printed
either side. Baseline and restored are both
`2f27218d5f16a868699b5ad03703849caa62052ec3e4370085df8b6011aed3c8`, identical.
Script `tmp/v1/06c-controls.sh`, run over four files (26 tests).

| Control | Break | Result |
|---|---|---|
| **C1** | `crossing_state/3` ignores the standing flag, so every write below the threshold alerts | **1 failure**: `fires once per crossing and not again while below the threshold`. 25/26 |
| **C2** | the trigger figure becomes `row.balance - row.held` | **1 failure**: `the low-balance trigger uses spendable, not balance minus held`. 25/26 |
| **C3** | every ledger call defers, whether or not the host had a transaction open | **8 failures**, listed in `06c-deferral.md` |
| **C5** | the `%{duplicate: true}` clause is removed from `decide_crossing/2` | **0 failures**, 96 passed |

### C1 run twice, which is what says which line carries the claim

X242's rule: run the control once to see the assertion you believe is load
bearing fail, and again with **only** that assertion relaxed, to see whether
anything else would have caught it.

With C1 in place **and** `assert length(events) == 1` relaxed to `>= 1`, the
**same test still fails**, at

```elixir
assert crossing_id(tenant) == crossing
```

Under C1 every write below the line rewrites the column, so the standing
crossing after five more debits is the **last** debit's id while the alert
carried the first. So two assertions in that test carry the claim
independently: the count, and the stability of the id. That is the shape X254
found valuable in 06b, arrived at here by measuring rather than by design, and
it means the test survives someone weakening either line.

Both files were restored sha256-identical after the relaxed run
(`ledger.ex 2f27218d…`, `credits_low_balance_test.exs 4298ebcd…`).

### C5 is the honest one: the duplicate clause is not load bearing

`decide_crossing(_repo, %{duplicate: true}), do: :none` is the line that refuses
to evaluate a crossing for a redelivered write. Removing it fails **nothing**:
96 tests pass without it.

That is not a reason to remove it, and it is a reason to say what row 6 of the
matrix actually proves. The crossing flag already prevents a second alert for a
redelivery, because the wallet is still below the threshold and the flag is
still set; the duplicate clause is **defence in depth**, and it also saves a
`spendable_of/2` read on a path that cannot alert. Row 5 of the matrix is
carried by `:duplicate_reference` refusing the write, not by the flag: C1 does
not fail that test either.

Written down rather than dressed up: **the replay row of this matrix is proved
by the ledger's idempotency, which predates this unit, and not by the crossing
flag.** What the crossing flag proves is rows 1, 2, 3 and 4.
