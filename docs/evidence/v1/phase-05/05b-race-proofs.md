# 05b: race proofs

The concurrency file is `test/aurora_meter/credits_reconcile_concurrency_test.exs`.
It uses no sandbox: every task takes a real connection with
`Sandbox.checkout(TestRepo, sandbox: false)` through
`AuroraMeter.Test.Connections`, because the sandbox wraps a test in one
transaction on one connection and would serialise the races being proven. Tenant
keys are synthetic (`reconcile_<integer>`) and the rows are deleted afterwards
with `Connections.cleanup!/1`.

Pool size 30, `Connections.max_tasks/0` 26.

## What provides mutual exclusion, and what does not

**It is the hold row's `FOR UPDATE` lock and the `status = 'pending'` re-read
inside it, in `AuroraMeter.Credits.Ledger.pending_hold/3`.** No lease, no fence,
no duration, no clock. That is deliberate and it is `open-findings.md` X100: a
reconciler decides whether work is abandoned, `clock_timestamp()` steps backwards
by up to 439 ms on this hardware, and a mechanism that needed sub-second ordering
could not get it from a shared clock. It does not need one. Postgres serialises
two writers on one row, and the loser reads what the winner wrote.

Of the three patterns already in the tree (03a's session advisory lock on a
pinned connection, 03d's claim, 04b's `lease_token` fence), this unit uses none
of them and adds no new one, because the ledger already had the right one. A
fence would answer "whose write wins" for a resource with no owner; a hold has an
owner, its own row, and locking it is both cheaper and stronger.

### The layer that is not there (X125, X160 shape)

`aurora_meter_credit_transactions` has a unique index on `(kind, reference)`
where `reference IS NOT NULL`. It refuses a **second `:settle` row** for one
hold. It cannot refuse a `:release` row beside a `:settle` row, because the two
differ in `kind`.

There are **no check constraints at all** on `aurora_meter_credit_balances` or
`aurora_meter_credit_transactions`: `grep -n "check_constraint" lib/aurora_meter/migration.ex`
returns nothing, and the V1 balances table declares `balance`, `held` and
`promotional` as bare `bigint NOT NULL DEFAULT 0`. So `held` can go negative and
nothing in the database will stop it.

**Therefore: a hold being both settled and released is prevented by application
code and one row lock, and by nothing else.** Removing the `FOR UPDATE` or the
status re-read from `pending_hold/3` would apply `held_delta: -hold.held_delta`
twice, drive `held` negative, and no constraint would fire. This is the 04e/X160
disclosure for this unit, and it is named rather than left implicit.

Both halves are asserted directly rather than argued, in
`AuroraMeter.CreditsReconcileHoldsTest`, describe `"what stops a hold being
closed twice"`:

| Test | What it does | Result |
|---|---|---|
| `the (kind, reference) unique index refuses a second settle row` | Settles a hold through the ledger, then inserts a second `(:settle, reference)` row past the ledger | `{:error, changeset}` with an error on `:reference`. The index is real and this test can see it. |
| `and permits a release row beside a settle row for the same reference` | Same hold, inserts a `(:release, reference)` row past the ledger | `{:ok, %CreditTransaction{kind: :release}}`. The index has nothing to say. |

The second row is the negative control that disables exactly one layer: with the
ledger's lock bypassed, the database accepts the write that a double terminal
transition would make.

## Proof 1: a reconciler release racing a caller settle

`test I11 a reconciler release and a caller settle produce exactly one terminal
transition`.

- One tenant funded 2,400,000 micro-USD, twelve holds of 100,000.
- 24 tasks, each on its own connection, started together by
  `Connections.run/3`. Odd tasks run
  `reconcile_holds(older_than:, tenant:, reference_prefix: <one hold>, reconciler: fn _ -> :release end)`;
  even tasks run `Credits.settle(reference, 40_000)` directly. Each hold has
  exactly one of each racing for it.
- Asserted on rows, not on return values: twelve hold rows all `settled` or
  `released`, twelve closing entries in total, and the intersection of the
  settled and released reference sets empty.
- Conservation: `balance == 2_400_000 - 40_000 * settle_rows`, `held == 0`,
  `available == balance`.

**Observed distribution of winners, over ten seeds (`tmp/v1/05b-logs/05b-seeds.log`,
printed only when `AURORA_RACE_REPORT` is set):**

| Seed | settled by caller | released by reconciler | settle losers | reconciler `already_closed` |
|---|---|---|---|---|
| 0, 1, 7, 13, 42, 101, 1009, 2026, 31337, 65535 | 12 | 0 | 0 | 12 |

**The caller's settle won all twelve holds on all ten seeds, and this is
reported rather than hidden.** `reconcile_holds/1` lists, spawns a task and calls
back before it writes, so it is always the slower of the two in this shape. Two
consequences, both stated in the test itself:

1. The assertion "every loser carries `:already_settled` and never an
   `%Ecto.Changeset{}`" is **vacuous in this test**, because there were no
   settle losers. It is kept as a guard against a future change making the
   reconciler the faster side, not as the proof.
2. What this test actually proves is the **volume** property: twelve
   simultaneous pairs, twelve closing rows, no hold closed twice, and the
   balance equal to what the winners alone imply.

Each direction of the race is therefore proved separately and deterministically.

## Proof 2: the reconciler as the loser, deterministically

`test I11 a reconciler decision applied after a concurrent settle is refused by
the hold row lock`.

The host callback blocks on a rendezvous. While it is blocked, the test process
settles the hold for 400,000 on its own connection and commits. The callback is
then released with `:release`, so the reconciler's decision is applied strictly
after the settle.

- `report.examined == 1`, `report.already_closed == 1`, `report.released == 0`,
  `report.failed == 0`.
- No `:release` row. Exactly one `:settle` row. The hold is `settled` with
  `settled_amount: 400_000`.
- Balance 600,000 of 1,000,000, `held` 0.

The layer that answered is named by the outcome: `:already_closed` is the
reconciler's mapping of `{:error, :already_settled}`, and `:already_settled` is
produced in exactly one place, the status re-read inside `pending_hold/3`'s
`FOR UPDATE`. The unique index cannot have answered, because the row that was
refused would have been a `:release` beside a `:settle`, which proof 1's control
above shows the index permits.

## Proof 3: the reconciler as the winner, deterministically

`test I11 a with_credits caller whose hold the reconciler released records the
executed cost`.

The mirror, and the direction that can lose money. A `with_credits/4` caller runs
on its own connection with its work blocked on a rendezvous. The test process
runs a full `reconcile_holds/1` with a `:release` callback, which wins. The work
is then released and returns `{:ok, :done, 300_000}`.

- The caller returns `{:ok, :done}`, not a `MatchError` (finding L4).
- One `:release` row, no `:settle` row.
- Exactly one `:debit` row, `amount: -300_000`, reference
  `settle_missed:job:<tenant>`.
- Balance 700,000 of 1,000,000, `held` 0. The executed cost was charged, once.

## Proof 4: two reconcilers, one hold

`test I16 two reconcilers on two connections release one hold once`.

Two `reconcile_holds/1` runs started together on two connections, same tenant,
same `:release` callback, one hold of 500,000.

- Exactly one `:release` row; no `:settle` row.
- `a.released + b.released == 1`; `a.failed + b.failed == 0`.
- The loser is asserted to be either `already_closed: 1` (it listed the hold and
  the row lock refused it) or `examined: 0` (it listed after the winner
  committed). Both are correct; a second release row is not.
- Balance 1,000,000, `held` 0.

## Proof 5: a hot wallet under twenty-four sweeps

`test I11 twenty-four concurrent reconciler runs over one hot wallet conserve the
balance`.

One tenant funded 1,200,000, twelve holds of 100,000. Twenty-four tasks on
twenty-four connections each sweep the **whole tenant**, so 288 decisions
contend for twelve holds and one balance row. The callback settles even-numbered
jobs for 25,000 and releases odd-numbered ones.

- Six `:settle` rows and six `:release` rows. Exactly twelve, one per hold.
- Every hold row `settled` or `released`.
- Conservation: `balance == 1_200_000 - 6 * 25_000 == 1_050_000`, `held == 0`,
  `available == 1_050_000`.
- Across the twenty-four reports: `released` sums to 6, `settled` sums to 6,
  `failed` sums to 0. The other 276 decisions reported `already_closed`.

## Proof 6 and 7: killing the reconciler

`test I16 killing the reconciler between the callback and the application leaves
the hold pending`. The callback signals the test and blocks; the reconciler
process is killed with `Process.exit(pid, :kill)` and its death observed through
a monitor (`:killed`). The callback is then released; it is under
`AuroraMeter.TaskSupervisor` with `async_nolink`, so it outlived its caller and
its answer goes nowhere.

- Read back on a fresh connection through `Kill.assert_db!/1`: the hold is still
  `pending`, no `:release` row, no `:settle` row, `held` 500,000, balance
  1,000,000.
- A second run with the same decision applies it normally: `examined: 1,
  released: 1`, hold `released`, `held` 0. A lost decision costs a cycle, never a
  hold that can no longer be reconciled. **This is what having no lease buys.**

`test I16 killing the reconciler after the application commits leaves exactly one
terminal transition`. `AuroraMeter.Test.FaultRepo` is configured as the repo and
`AuroraMeter.Test.Kill.run/2` arms `:after_commit_before_ack` with
`:exit_kill_self`, so the reconciler dies immediately after its release
transaction commits and before it can report. `Faults.assert_fired!/1` confirms
the fault ran.

- `{:killed, _pid}`; the release stands, one `:release` row, hold `released`.
- The next run finds nothing to list (`examined: 0, released: 0`) and writes no
  second row. Balance 1,000,000, `held` 0.

## Seeds

Ten seeds, `0 1 7 13 42 101 1009 2026 31337 65535`, all seven tests passing on
every one. Full output in `05b-seeds.log`; the run script is
`tmp/v1/05b-seeds.sh`.
