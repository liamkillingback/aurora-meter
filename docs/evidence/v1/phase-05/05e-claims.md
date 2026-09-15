# 05e claims: every guarantee sentence in core's operations guide, traced

| | |
|---|---|
| Task | 05.07 |
| Build unit | 05e |
| Repository | `aurora_meter` |
| Core SHA at authoring | `0a4bd0bef56cc0628485bc864e2043862a6a2214` |
| Pro SHA at authoring | `44ef949553e796ea86ecc7e360759f29deadf0f7` |
| Document traced | `docs/operations.md` |

Rule L05e-1: every guarantee sentence names the invariant it rests on and is
traceable to a named test. A sentence that cannot be traced is deleted or
rewritten as an explicit limitation. Rows marked **limitation** make no promise
and are here so the list is complete; each says what it costs instead.

Test names are full ExUnit names (`test <describe> <description>`), so
`docs/correctness.md`'s index parser and `docs_claims_test.exs` see the same
strings this table does.

## Section 1: what runs, and how often

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 1 | "Aurora Meter does not assume a scheduled job runs a single time" | I16 | `AuroraMeter.ObanConcurrencyTest` / `test I16 two CreditExpiry runs on independent connections expire each grant once` |
| 2 | "`expire_due/2` re-reads `expired_at` under the grant row's own `FOR UPDATE`" | I16 | `AuroraMeter.Oban.WorkersTest` / `test I16 a second CreditExpiry run for the same tick expires nothing and adds no ledger row` |
| 3 | "`reconcile_holds/1` re-reads `status = 'pending'` under the hold row's" | I11, I16 | `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I16 two reconcilers on two connections release one hold once` |
| 4 | "two independent connections behind a forced barrier, **two rows in ten of ten**" | I16 | `AuroraMeter.Pro.RestartTest` / `test I16 a forced race on one tenant shows how often Oban's unique loses it` (Pro), summarised in `docs/evidence/v1/phase-05/i16.md` measurement 3 |
| 5 | "sequential on one connection, one row" | I16 | `AuroraMeter.Pro.RestartTest` / `test I16 two sequential AutoTopUpSweeper runs enqueue exactly one job per tenant` (Pro) |
| 6 | "two nodes released together, one row in five of five runs" | I16 | `05c-multinode.log`, five runs, with the X125 control at two rows; `i16.md` measurement 2 |
| 7 | "The second job finds the work done and says so." | I16 | `AuroraMeter.ObanConcurrencyTest` / `test I16 the CreditExpiry run that loses the grant row lock expires nothing` |
| 8 | "Promotional credit stays spendable past its expiry date" if expiry runs less often | I12 | `AuroraMeter.CreditsTest` / `test promotional credit expire_due/1 expires only what is left, once, and never below zero` |

## Section 2: queue sizing

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 9 | "each commits bounded batches and keeps its position in `aurora_meter_checkpoints`, so a run that does not finish is resumed rather than restarted" | I16 | `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry killed between batches resumes at the checkpoint without skipping work` |
| 10 | "A limit of zero is worse than a small one ... `AuroraMeter.Oban.validate!/1` refuses that configuration at boot" | none (05a contract) | `AuroraMeter.ObanTest` / `test validate!/1 raises when the queue limit is zero`, with `test validate!/1 raises when the aurora_meter queue is absent` beside it |

Row 10 is the one sentence in section 2 that is a claim rather than advice; the
rest of the section is a recommendation with its reasoning, and is marked as such
in the text ("Five is the recommendation ... and the reasoning is short").

## Section 3: recovering stale holds

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 11 | "The default is `:keep`, and so is every way of failing to answer ... Nothing here can release money by accident." | I11 | Five tests, one per way of not answering: `AuroraMeter.CreditsReconcileHoldsTest` / `test the default keeps every hold when no reconciler is configured, and writes nothing`; `test a callback that misbehaves keeps the hold and reports :callback_exit when it raises`; `test a callback that misbehaves keeps the hold and reports :callback_exit when it exits or throws`; `test a callback that misbehaves keeps the hold and reports :callback_timeout when it never answers`; `test a callback that misbehaves keeps the hold and reports :callback_invalid for a value that is not a decision` |
| 12 | "exactly one terminal transition happens and the reconciler reports `already_closed`" (linked from `credits.md`, restated here as "the hold row's `FOR UPDATE`") | I11 | `AuroraMeter.CreditsReconcileConcurrencyTest` / `test I11 a reconciler release and a caller settle produce exactly one terminal transition` |
| 13 | "a debit referenced `settle_missed:<reference>` is written ... and it is idempotent on that reference" | I11 | `AuroraMeter.CreditsTest` / `test with_credits/4 I11 records the executed cost when the hold was released by someone else` |
| 14 | "Age is not evidence" | I11 | Not a guarantee about code: it is the reason the callback exists. The mechanical half (a hold's `inserted_at` is stamped by the node that took it) is `open-findings.md` X59, X100 and L20, and `AuroraMeter.CreditsModelTest` / `test the clock the ledger orders itself by I10 a backwards step in the wall clock leaves a promotional grant that can never expire (L20, fixed in 06a)` |

## Section 4: when the database is unavailable

Every row of this section's table is a row of `docs/guarantees.md`, whose
**Proven by** column is checked on every run by
`AuroraMeter.DocsClaimsTest` / `test G05 the guarantee table G05 every Proven by cell names a real test, defers to Pro, or says not yet proven`.

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 15 | "Everything not in an acknowledged flush batch can be lost if the VM stops ... nothing bounds it" | I01 (G6) | `AuroraMeter.KillTest` / `test I01 a Store killed before the flush loses the buffered deltas, as documented` |
| 16 | "the receipt's primary key is inserted inside the same transaction as the deltas, so a batch redelivered after a lost response applies its deltas a single time" | I01 (G7) | `AuroraMeter.FlushBatchConcurrencyTest` / `test I01 twelve independent connections deliver one batch once` |
| 17 | "Retains its batch and retries the same batch id" | I01 | `AuroraMeter.KillTest` / `test I01 a Flusher killed between the snapshot and the persist keeps the batch in Store` |
| 18 | "`record/4` returns `{:error, {:unavailable, reason}}` ... a retry after an unknown commit outcome is reported as a duplicate rather than persisted twice" | I06 | `AuroraMeter.RecordConcurrencyTest` / `test process death I06 killing the caller after commit before the reply leaves exactly one row, and the same-id retry returns duplicate without a second delta or outbox item` |
| 19 | "A refusal returns rather than raising, so it does not destroy a transaction of your own that wraps it" | I10 | `AuroraMeter.CreditsConcurrencyTest` / `test I10 a refusal does not destroy the caller's own transaction` |
| 20 | "`check/2` is advisory and stays advisory" | I04 (G1) | `AuroraMeter.EntitlementsTest` / `test check/2 is advisory: two callers are both allowed the last unit and nothing is reserved` |
| 21 | "A reservation is never persisted and never gossiped" | I03, I04 (G5) | `AuroraMeter.KillTest` / `test I04 a killed caller's reservation continues to occupy the limit on that node` |

**Row 18 needed a correction to `docs/guarantees.md` that this unit did not
make.** G10's Proven by cell still says "not yet proven (phase 03)" while
`docs/correctness.md`'s I06 section names fourteen tests, phase 03 having landed.
The guide therefore cites I06's test rather than G10's cell, and the stale cell is
recorded as a finding for the unit that owns `guarantees.md`.

## Section 5: pause and resume

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 22 | "A pause asks the operation to stop at its next batch boundary. The batch already in flight finishes and commits" | I16 | `AuroraMeter.OperationsTest` / `test run_batches/3 L05c-2 the pause is read before every batch, not only the first` |
| 23 | "the cursor advances with it" (a pause leaves the cursor where the last committed batch left it) | I16 | `AuroraMeter.ObanJobControlsTest` / `test I16 CreditExpiry cancels with :paused and continues from the cursor after resume` |
| 24 | "a run that starts while paused does no work at all" (implicit in "nothing runs") | I16 | `AuroraMeter.OperationsTest` / `test run_batches/3 L05c-2 a run that starts while paused does no work at all` |
| 25 | "A name that is not `\"<operation>:<scope>\"` raises `ArgumentError`" | none (05c contract) | `AuroraMeter.OperationsTest` / `test names an invalid checkpoint name raises ArgumentError` |
| 26 | "`\"events_projection\"` and `\"events_backfill\"` ... are not reachable here" | none (X203, deliberate) | `AuroraMeter.OperationsTest` / `test checkpoint/1 and clear_checkpoint/1 list/0 includes rows that are not operations` |

## Section 6: replay

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 27 | "A replay writes totals and nothing else. It records no event, stages no export intent, grants no credit, publishes no message and produces no flush batch." | I08 | `AuroraMeter.EventsReplayTest` / `test side effects I08 a replay enqueues nothing, grants nothing, notifies nothing and flushes nothing` |
| 28 | "the cursor always names a batch that is fully applied, and running `run/1` again carries on from it" | I16 | `AuroraMeter.EventsReplayTest` / `test pause and resume a paused replay stops within one batch and resumes at its cursor` |
| 29 | "The previous generation is retained until you prune it" | I08 | `AuroraMeter.EventsReplayTest` / `test activation L-03d-4 the previous generation survives activation and can be reactivated` |
| 30 | "refuses to activate if the rebuild and the live projection differ" | I08 | `AuroraMeter.EventsReplayTest` / `test activation L-03d-4 the previous generation survives activation and can be reactivated` (the comparison gate is the precondition that test's setup establishes; the option list is `docs/operations/replay.md`'s, which 03d evidences) |

## Section 7: retention

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 31 | "`plan/1` ... writes nothing at all" | I01 | `AuroraMeter.RetentionTest` / `test plan/1 writes nothing` |
| 32 | "the number it gives you is the number `prune/1` then removes" | I01 | `AuroraMeter.RetentionTest` / `test plan/1 returns exactly the counts prune/1 then deletes` |
| 33 | "Events, event totals, the credit ledger, subscriptions and live cursors are not deleted by anything in this package at any age under any option" | I01 | `AuroraMeter.RetentionTest` / `test prune/1 deletes nothing from any protected table` and `test the allow list and the protected list together name every table the package creates` |
| 34 | "the allow list is closed at compile time" | I01 | `AuroraMeter.RetentionTest` / `test prune/1 raises ArgumentError for a table outside the allow list` |
| 35 | "this is a refusal, not an error, and retention refuses rather than guessing" | I01 | `AuroraMeter.RetentionTest` / `test I01 no heartbeat anywhere blocks a prune that would delete something` |
| 36 | `:paused` row of the reasons table | I16 | `AuroraMeter.RetentionTest` / `test prune/1 reports a paused table rather than failing` |
| 37 | `:budget_exhausted` row ("a bounded run that could not say it was bounded would make the bound a silent ceiling") | none (X223) | `AuroraMeter.RetentionTest` / `test prune/1 stops at :max_items and the next run continues` |
| 38 | `:heartbeat_stale` row | I01 | `AuroraMeter.RetentionTest` / `test I01 a receipt is not pruned while a node's heartbeat is itself older than the cutoff` |
| 39 | `:pending_batch_older_than_cutoff` row | I01 | `AuroraMeter.RetentionTest` / `test I01 a receipt is not pruned while a node's heartbeat reports an older pending batch` |
| 40 | `:pending_since_unreadable` row | I01 | `AuroraMeter.RetentionTest` / `test I01 an unreadable pending_since blocks rather than being ignored` |
| 41 | `:unknown_state` row ("a newer node is writing to this database") | I01 | `AuroraMeter.RetentionTest` / `test I01 a heartbeat state this release does not write blocks` |
| 42 | `:no_heartbeats` row | I01 | `AuroraMeter.RetentionTest` / `test I01 no heartbeat anywhere blocks a prune that would delete something` |
| 43 | "It removes exactly that node's row" | I01 | `AuroraMeter.RetentionTest` / `test I01 forget_node/1 removes the block for exactly one node and leaves the others` |
| 44 | "if that node then returns and retries, the batch's usage is counted twice" | I01 | `AuroraMeter.RetentionTest` / `test I01 a retry of a batch whose receipt was pruned would double count`, with its control `test I01 a retry of a batch whose receipt was protected does not double count` |

## Section 8: backup and restore

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 45 | **limitation.** "Restoring to a point before a financial write loses that write." | none | No test, and none is possible from inside the package: it is a statement about what this software does not do. `schema-migration-map.md` section 7 is the programme's record of it. Cost of getting it wrong: the write is gone, so the guide says to reconcile per tenant afterwards. |
| 46 | **limitation.** "there is no `down` migration that is a rollback" | none | Same. `schema-migration-map.md` section 7. |
| 47 | "A receipt restored without the counters it acknowledged is a batch that will not be reapplied" | I01 | `AuroraMeter.RetentionTest` / `test I01 a retry of a batch whose receipt was protected does not double count` (the same mechanism, read the other way round) |
| 48 | Verification step 3, "It either tells you the projection and the events agree or hands you the keys that do not" | I08 | `AuroraMeter.EventsReplayTest` / `test side effects I08 a replay enqueues nothing, grants nothing, notifies nothing and flushes nothing` for the safety, and `docs/operations/replay.md` for the comparison semantics |

I19 covers backup and restore as an invariant and is **11a's**, not proved here.
The guide's restore section therefore describes a procedure and states its limits;
it claims no property. Row 45 and row 46 are why this section is the shortest one
in the guide.

## Section 9: the health check

| # | Sentence | Invariant | Named test |
|---|---|---|---|
| 49 | "a wallet's balance is the sum of its entries' amounts" | I10 | `AuroraMeter.CreditsModelTest` / `property generated histories I10 balance equals the sum of every transaction amount after every step` |
| 50 | "held is the sum of the holds still open" | I10 | `AuroraMeter.CreditsModelTest` / `property generated histories I10 held equals the sum of open holds after every step` |
| 51 | "They are written against the shape that `AuroraMeter.CreditsModelTest`'s generated histories assert after every command" | I10 | the two rows above |

## Sentences deleted because they could not be traced

Six, and they are the most useful output of this file.

| Deleted | Why |
|---|---|
| "Nothing is lost and nothing is duplicated" during a database outage (from the build document's plan for section 4) | It is two claims and both are wrong as stated. Buffered usage **is** lost if the VM stops (G6), and the guide now says so in the same table. Replaced by a per-subsystem table where each row names what it costs and the invariant behind it. |
| "Uniqueness prevents the duplicate job" (implied by the build document's queue-sizing section) | X209 measured the opposite in the case that matters: two independent connections, two rows, ten of ten. Replaced by the measurement and by a sentence saying what does protect the money. |
| "The heartbeat tells you whether a node is alive" | `AuroraMeter.Checkpoints`'s moduledoc and X100 say the heartbeat is a report and not a lease, and nothing in the package decides an exclusion question from its age. The guide says "has not been heard from" and sends the operator to investigate rather than to conclude. |
| "`forget_node/1` is safe when the node has been gone for a while" | Age is not the precondition and there is no test that could make it one. Replaced by the precondition as it actually is, plus the consequence of getting it wrong, which does have a test (row 44). |
| "A verification replay proves the projection is correct" | A replay proves the projection matches the events. If the events are wrong, both are wrong together. The guide says "the projection and the events agree". |
| "Restoring the credit tables alone is enough to restore the ledger" (the obvious shape of a restore section) | There is no test and it is false: the receipts and the counters are part of the same consistency set. Replaced by row 47's argument, which does have a test. |

## Two claims this guide deliberately does not make

Both are on `v1-release.md` section 17's forbidden list and both were tempting
in an operations guide, which is exactly why they are recorded here.

- **"A scheduled job runs once."** The guide says the opposite, twice, and gives
  the measurement.
- **"A retention prune cannot delete anything that matters."** The guide says the
  allow list is closed and names the test, which is a narrower and true claim.
  The wider one would be a claim about every future unit's judgement.

`AuroraMeter.DocsClaimsTest` scans `docs/operations.md` on every run, because its
scope is `README.md` plus every `*.md` under `docs/` outside `adr/` and
`evidence/`. It has no allow-list entry for this file and needs none.
