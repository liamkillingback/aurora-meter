# 03e: the two orderings that are wrong, and what each one does

Build unit 03e's document says the step order "is the single most important
thing in this document", and names the place a future maintainer is most likely
to simplify it. This is the file that stops them: each wrong ordering, the
observed failure, and the test that catches it.

Producer: `tmp/v1/03e/mutate.py` and `tmp/v1/03e/negative-controls.sh`. Logs:
`tmp/v1/03e/logs/negative/`. Every mutation is applied to the working tree,
run, and reverted, and the revert is **asserted** by sha256 rather than assumed
(`open-findings.md` X97). Each mutation keeps every function reachable, because
the test environment compiles with `--warnings-as-errors` and an orphaned
`defp` would fail the build instead of failing the test, which proves nothing.

## The order that ships

```
1.  FOR SHARE on the events_projection checkpoint row
2.  SELECT the correction by its own id            <- duplicate, before the bound
3.  SELECT the original FOR UPDATE                 <- the serialisation point
3b. SELECT the correction by its own id, again     <- duplicate, under the lock
4.  SELECT sum(quantity) of this original's corrections, and the bound
5.  INSERT the correction (ON CONFLICT DO NOTHING RETURNING), resolve
6.  Totals: ensure the row, then UPDATE by the signed delta
7.  Outbox
```

## Wrong ordering 1: the bound before the duplicate check

**What it looks like.** Deleting step 2 and step 3b, so the cumulative sum is
the first thing a retry meets.

**Why it is wrong.** A retry of a correction has **its own committed row inside
that sum**. Every retry of a correct correction is therefore refused for
exceeding the original, and `correct/4` becomes an operation that cannot be
retried. That is not a cosmetic defect: an unknown outcome on a financial write
is answered by retrying with the same id, and here the retry is the only way a
caller ever learns what happened.

**Observed**, mutation `bound_before_duplicate`, log
`tmp/v1/03e/logs/negative/bound_before_duplicate.log`:

```
1) test the cumulative bound I09 a duplicate correction id is idempotent even
   when the original is already fully corrected (AuroraMeter.CorrectTest)
     right: {:error, {:invalid, [quantity: :exceeds_original]}}

Result: 34/35 passed
```

**Caught by** `AuroraMeter.CorrectTest` / `test the cumulative bound I09 a
duplicate correction id is idempotent even when the original is already fully
corrected`.

## Wrong ordering 1b: the duplicate check only before the lock

**What it looks like.** Keeping step 2 and deleting step 3b, which is the step
order the build document itself specifies.

**Why it is wrong.** Step 2 runs before the lock, so a corrector that arrives
while an identical correction is still uncommitted sees nothing there. It then
waits at step 3, and by the time the lock is granted the other correction is
committed and inside the sum. Without a second check it is told
`exceeds_original` for a correction that is its own. Sequentially the defect is
invisible: the single-connection idempotence test passes either way.

**Observed**, mutation `no_recheck`, log
`tmp/v1/03e/logs/negative/no_recheck.log`:

```
1) test twelve correctors of one original I09 12 concurrent submissions of one
   correction identity produce one row, one delta and one outbox item
   (AuroraMeter.CorrectConcurrencyTest)

Result: 5/6 passed
```

**Caught by** `AuroraMeter.CorrectConcurrencyTest` / `test twelve correctors of
one original I09 12 concurrent submissions of one correction identity produce
one row, one delta and one outbox item`, which corrects **ten of ten** on
purpose, so a corrector that missed the winner arrives at the bound with no
headroom at all.

This is a **defect in the build document**, reported as such rather than
implemented.

## Wrong ordering 2: the sum without the lock

**What it looks like.** Deleting `lock: "FOR UPDATE"` from the read of the
original, so the cumulative sum is taken from whatever snapshot the statement
happens to get.

**Why it is wrong.** Two concurrent correctors each see the other's absence and
both commit, and between them they credit more than was charged.

**Observed**, mutation `no_lock`, log `tmp/v1/03e/logs/negative/no_lock.log`:

```
1) test twelve correctors of one original I09 12 concurrent partial corrections
   of one 10-unit original never exceed it
2) test twelve correctors of one original I09 the lock that serialises
   correctors is the one on the original row

Result: 4/6 passed
```

### The half of this that is worth reading twice

The first time this mutation was run, **the bound test passed without the
lock**, and only the dedicated lock test failed. The reason is that 03a's
`CHECK (quantity >= 0)` on `aurora_meter_event_totals` is a real second
enforcement of I09: when the bound is bypassed, the twelfth correction's totals
update takes the row negative, the constraint refuses it, the transaction rolls
back, and `record_correction/2` maps the violation to **the same error tuple**
the bound would have produced. Ten commit, two are refused, the totals row reads
zero, and every number the test asserts is right for the wrong reason.

Two things were done about that.

1. The bound test now captures the log and asserts that
   `aurora_meter_event_totals_quantity_check` **never appears**, so it can tell
   the two mechanisms apart. With that assertion it fails under `no_lock` with
   `the bound was bypassed and the check constraint caught it instead`.
2. A paired control was added: `no_lock_widened` removes the lock **and** holds
   the window between the sum and the insert open for 50 ms, and `widened_only`
   keeps the lock with the same window. The second passes (`Result: 6 passed`),
   which is what makes the first's failure attributable to the lock rather than
   to the window.

The general lesson, for whoever writes the next concurrency test: **a
concurrency test can be satisfied by a serialisation point it did not mean to
test.** Here it was a check constraint two steps further down; in another test
it might be a row lock taken incidentally by an upsert. A test whose subject is
a lock needs an assertion that names the lock.

## Wrong ordering 3: the in-memory floor

Not an ordering, but the same class: `Counter.apply_projection/2` subtracting
with `:ets.update_counter/3`'s three-element form, which has no floor.

**Observed**, mutation `no_floor`, log
`tmp/v1/03e/logs/negative/no_floor.log`:

```
1) test the in-memory projection I09 a correction whose magnitude exceeds this
   node's view re-seats it from the durable total (AuroraMeter.CorrectTest)
     right: 6

Result: 34/35 passed
```

## The positive control

With every mutation reverted and both files back to their baseline sha256:

```
Result: 59 passed
```

over `correct_test.exs`, `replace_test.exs` and
`correct_concurrency_test.exs`, seed 0.
