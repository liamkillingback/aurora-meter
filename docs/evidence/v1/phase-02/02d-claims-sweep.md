# 02d: the stale-claim sweep

Build unit 02d, 2026-09-15. The mechanical half of gate G02 bullet 4
("unsupported global quota guarantees are absent").

The method was the point: write the check first, with an **empty** allow-list,
and run it before touching a single document. Its output is both the work list
and the evidence that the work list was complete. A sweep done by reading is a
sweep whose coverage nobody can state.

The check is `test/aurora_meter/docs_claims_test.exs`. It scans `README.md` and
every `*.md` under `docs/` except `docs/adr/` and `docs/evidence/`, for nine
phrases in three families. `CHANGELOG.md` is excluded as history, the rule
`open-findings.md` W12 sets for the dash sweep.

## 1. The raw work list

`mix test test/aurora_meter/docs_claims_test.exs --seed 0`, allow-list empty,
before any documentation was edited. Exit 2, 2 of 5 passing. Twelve occurrences
in five files:

```
1) G01 no package document claims a bounded loss window
  docs/examples/allowance-and-overage.md:62: "up to five seconds" in "consciously: **if the node dies, up to five seconds of counts die with it.**"
  docs/examples/allowance-and-overage.md:64: "never lose" in "For a 2¢ generation, losing a few is cheaper than the machinery to never lose"
  docs/examples/concepts.md:151: "up to five seconds" in "lose up to five seconds of counts. If a particular feature must never lose a"
  docs/examples/concepts.md:151: "never lose" in "lose up to five seconds of counts. If a particular feature must never lose a"
  docs/metering.md:63: "at most one interval" in "hard crash can lose increments (at most one interval's worth) - fine for"

2) G01 no package document claims exactly-once delivery
  docs/correctness.md:128: "exactly once" in "- `AuroraMeter.StatementsTest` / `test I02 a retry after a failed statement applies the deltas exactly once`"
  docs/correctness.md:300: "exactly once" in "invariant, that an accepted event is recorded exactly once across a kill before"
  docs/correctness.md:591: "exactly-once" in "## I16 Worker scheduling is not an exactly-once assumption"
  docs/correctness.md:596: "exactly-once" in "writes nothing. Aurora Meter does not claim exactly-once host job execution"
  docs/credits.md:64: "exactly once" in "exactly once, say. Ask it rather than probing for the reference beforehand:"
  docs/examples/allowance-and-overage.md:252: "exactly once" in "# Once an hour, Pro tells Stripe about the delta, exactly once"

3) G01 no package document claims a global or globally serialized quota
  docs/correctness.md:210: "global quota" in "claim a strict global quota. A `:metered` feature is never refused by design, and"
```

Full log: `tmp/v1/02d/core-sweep-prefix.txt` in the storefront (git-ignored).

## 2. The work list against the build document's table

The build document listed nine locations. The sweep agrees on four of them, is
blind to four by construction, and found one the table missed.

| Build document said | Sweep | Outcome |
|---|---|---|
| `docs/metering.md:56` bounded loss at one interval | found, at line **63** | corrected. The line number in the build document was stale; the text was not |
| `docs/examples/concepts.md:149-151` five seconds | found, at line **151** | corrected |
| `docs/examples/allowance-and-overage.md:60-62` five seconds | found, at line **62** | corrected |
| `docs/examples/allowance-and-overage.md:252` exactly once | found | corrected |
| `docs/examples/concepts.md:152` durable row implies billing source | **not found** | corrected anyway. It carries no forbidden phrase: a wrong implication is not a wrong word, and no phrase list catches it |
| `docs/clustering.md:8` four-element counter row | **not found** | corrected anyway, same reason |
| `docs/clustering.md:69` "Schema version 2" | **not found** | corrected anyway |
| `docs/clustering.md:86-92` rolling upgrade from 0.2 | **not found** | rewritten anyway |
| ADR 0003 absolute-value upserts | **excluded** by design | dated note appended, original text intact |
| not listed | `allowance-and-overage.md:64` "the machinery to never lose one" | reworded. The sweep found it; the reading pass that produced the table did not |

Two conclusions, and the second is the one worth carrying forward:

1. **The phrase list catches the claims that are wrong in their wording. It
   cannot catch a claim that is wrong in its content.** Four of the nine
   locations were prose that is false without containing a forbidden phrase.
   The sweep is a floor, not a ceiling, and `docs/guarantees.md` plus a reading
   pass is what found the other four.
2. **The line numbers in the build document were already stale**, two of them,
   one day after it was written. `open-findings.md` X67 and X90 record the same
   thing happening twice inside a day elsewhere. This unit's allow-list
   therefore keys on the **text** of each permitted occurrence, never on a line
   number, and an entry whose text is gone fails the test.

## 3. Before and after, location by location

### `docs/metering.md`, "Durability"

Before:

> ...flushed to Postgres every `:flush_interval` ms and once more on a clean
> shutdown, so only a hard crash can lose increments (at most one interval's
> worth), fine for dashboards and soft quotas.

After: the loss is everything not yet in an acknowledged flush batch, "usually
the last interval and not bounded by it: while the database is unreachable the
pending set keeps growing until the database comes back or the VM dies."

### `docs/examples/concepts.md`

Before:

> A background flusher writes the totals to Postgres every five seconds. That is
> why it is fast enough to call on every request, and also why a hard crash can
> lose up to five seconds of counts. If a particular feature must never lose a
> count, list it in `:durable_features` and it is written straight through.

Two claims, both wrong. The five seconds is the default `:flush_interval`, not a
bound on loss; and "written straight through" invites the reader to think the
event row is what gets billed. After: the interval is named as the default it
is, loss is everything not in an acknowledged flush batch, and the durable row
is described as a record beside the counter, with the statement that usage
reporting reads the persisted counters either way.

### `docs/examples/allowance-and-overage.md`

Three changes. The loss paragraph gets the same correction. "the machinery to
never lose one" becomes "the machinery that would keep every one", because a
guarantee is not something you buy with machinery. And the durable paragraph
stops saying "written straight through to the database", which was true of the
row and misleading about the billing source.

Line 252, inside a worked example, said:

```elixir
# Once an hour, Pro tells Stripe about the delta, exactly once
```

After:

```elixir
# Once an hour, Pro reports the delta to Stripe under an identifier Stripe
# deduplicates on, so a retried send does not bill the units twice
```

Worth noting for `10a` and `09e`, which both plan to check documented snippets:
**this one was inside a fenced code block.** A sweep that skipped fenced blocks,
which is a tempting simplification, would have missed the only occurrence of
"exactly once" in the whole examples tree.

### `docs/clustering.md`

- The counter row was documented as `{key, value, pending_flush,
  pending_gossip}`. It is a six-tuple: `remote` and `reserved` were missing, and
  they are precisely the two that explain reservations and gossip rebasing. Both
  are now documented, with a closing note that the tuple is descriptive and is
  explicitly outside the compatibility promise (the support policy says so).
- "Schema version 2. 0.3 adds no migration" named a version that has moved twice
  since. It now names `AuroraMeter.Migration.latest_version()` and says that
  clustering adds no columns of its own.
- "Rolling upgrades from 0.2" described a rollout nobody supported is in the
  middle of. It is replaced by the two upgrades that matter, 0.4.x to 0.5.0 and
  0.5.x to 1.0.0, with one paragraph retaining the pre-0.3 warning and pointing
  at the support policy.

### `docs/adr/0003-buffered-vs-durable-and-period-seam.md`

Its consequences say absolute-value upserts make the flusher idempotent and
reset-free. The flusher has applied **deltas** since ADR 0004, and idempotence
comes from the flush receipt inside the transaction (ADR 0007).

**The original text is unchanged.** A dated note is appended instead, because an
ADR records what was decided and when, and retconning one destroys the only
thing it is for. The note corrects both statements, says which later ADR
superseded each, and points at the guarantee page for the current contract.

## 4. The allow-list, with reasons

Six occurrences remain, all legitimate, all allow-listed with a written reason
that the test itself requires (an entry with a reason shorter than 40 characters
fails, as does an entry whose snippet carries no forbidden phrase).

| File | Snippet | Why it stays |
|---|---|---|
| `docs/correctness.md` | "claim a strict global quota. A `:metered` feature is never refused by design, and" | The sentence begins on the line above with "Aurora Meter does not". It is the denial this check exists to protect, in I05's known limits |
| `docs/correctness.md` | "invariant, that an accepted event is recorded exactly once across a kill before" | I06's statement of what phase 03 will prove. The paragraph ends "is not guaranteed by the current code", so it withholds the claim rather than making it |
| `docs/correctness.md` | "## I16 Worker scheduling is not an exactly-once assumption" | The invariant's own title, which is a denial, and is fixed by `invariant-map.md` |
| `docs/correctness.md` | "writes nothing. Aurora Meter does not claim exactly-once host job execution" | The explicit refusal of the claim |
| `docs/correctness.md` | "- `AuroraMeter.StatementsTest` / `test I02 a retry after a failed statement applies the deltas exactly once`" | A test name, quoted so the index and the suite agree; `correctness_index_test` fails if either is reworded. The test is about one flush batch having one durable effect, which a receipt primary key inside the transaction gives, and is not a claim about delivery |
| `docs/credits.md` | "exactly once, say. Ask it rather than probing for the reference beforehand:" | The host announcing a payment to its customer once, decided by `grant_with_status/3` inside the balance row's lock (I14). Ledger idempotency, not delivery |

**The build document's acceptance criterion is wrong here**, and it is recorded
rather than quietly satisfied: it says "the only allow-listed occurrence at the
end of the unit is `docs/credits.md:64`". `docs/correctness.md` carries five
more, every one of them a denial of a claim or the name of a test that proves
one. The alternative would have been to exclude `docs/correctness.md` from the
scan, which would exempt the one document in the package whose whole subject is
what is and is not guaranteed. The criterion is met in substance: no occurrence
is exempted without a reason, and no occurrence that survives is a claim.

## 5. The negative controls

Three for this sweep, each broken once and recorded in
`tmp/v1/02d/negative-controls.txt`:

| Control | Result |
|---|---|
| A bounded-loss claim added to `docs/metering.md` | fails, naming the file, the line and the phrase |
| An allow-listed sentence in `docs/credits.md` reworded so the entry no longer matches | fails with "allow-listed occurrences that are no longer in the file" |
| `docs/examples/` quietly added to the excluded directories | fails, because the scan is compared against the wildcard and its size is asserted |

The third exists because every other test in this file passes trivially when the
scan covers nothing.

## 6. What this sweep does not cover, and who owns it

- **`lib/` doc strings.** Moduledocs render on hexdocs and are user-facing copy,
  and the scan does not read them. It was checked by hand: core `lib/` contains
  none of the nine phrases. Pro's contains two, both verified legitimate
  (`pro/alerts.ex` and `pro/credits.ex`, both claiming ledger or row uniqueness
  under a lock, neither claiming delivery). Widening the scan to `lib/` doc
  strings is cheap and is recommended to **10a**, which owns package
  documentation at release.
- **The em dash sweep** (`open-findings.md` X88, 475 occurrences). Out of scope,
  owned by 10a.
- **The storefront guides** (`open-findings.md` W5, which carries the same "up
  to five seconds" and "exactly once" claims). Owned by 10c. This sweep is the
  wording it should copy.
