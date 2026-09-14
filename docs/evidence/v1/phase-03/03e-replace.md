# 03e: `replace/4`, its two ids, its four outcomes and its rollback

`AuroraMeter.correct/4` reduces a quantity and inherits everything else. When
what was wrong is a **dimension or a timestamp**, there is nothing to reduce:
the honest record is a full reversal of the original plus a new fact, and
`architecture-map.md` 4.2 requires both in one transaction, "documented as two
ids". This is that documentation.

## The two ids

| Row | Id | Kind | Quantity |
|---|---|---|---|
| the correction | the caller's `:id` | `correction` | `original.quantity` less the corrections already committed |
| the replacement | `:replacement_id`, default `id` with `~r` appended | `usage` | the caller's new quantity |

Deriving the second id from the first is what makes the whole two-row operation
idempotent under **one** caller id, which is the property every other write in
this phase has: a retry finds both rows, matches both hashes and returns
`:duplicate` for the pair. The map requires one transaction and two ids but does
not say how a retry stays idempotent; this is the engineering answer, and it is
recorded in the build document's open questions as such.

The derived id must still fit the 128-byte column, so `:id` is limited to 126
bytes here and a longer one is refused **by name**, before any database call:

```
AuroraMeter.replace(org, "base", attrs, id: String.duplicate("x", 127))
#=> {:error, {:invalid, [id: :too_long_for_replacement]}}
```

126 is the last one that fits, and `AuroraMeter.ReplaceTest` / `test refusals a
caller id that leaves no room for the derived one is refused by name` asserts
both halves, including that the resulting replacement id is exactly 128 bytes.

## The four outcomes

| Outcome | When | Test |
|---|---|---|
| `{:ok, %{correction: c, replacement: r}, :inserted}` | both rows were inserted | `test the two rows replace fully corrects the original and records the replacement in one transaction` |
| `{:ok, %{correction: c, replacement: r}, :duplicate}` | both ids were already held with matching payload hashes | `test idempotence replace is idempotent under one caller id` |
| `{:error, {:conflict, existing}}` | any mixed or mismatched state, which is reachable only by overriding `:replacement_id` differently across attempts | `test idempotence a retry with an overridden replacement_id that differs conflicts` |
| `{:error, {:invalid, [quantity: :already_fully_corrected]}}` | the original has nothing left to reverse | `test refusals replace on a fully corrected original is already_fully_corrected` |

A mixed state is a conflict on the **correction**, not
`{:unavailable, :conflict_unresolved}`: nothing was inserted and nothing is
uncertain. The correction identity is spent on a pairing the caller is no longer
asking for, and the correction is the identity they can do something about.

## The transaction

One transaction, in this order: the correction's steps 1 to 5 with the magnitude
resolved inside as `original.quantity - sum(existing corrections)`, the
replacement inserted in the **same** `insert_all` statement, both totals deltas,
then both outbox items in the order `[correction, replacement]` so an exporter
that must cancel before re-sending sees them that way round
(`test the two rows replace stages two intents, correction first`).

Three failures, all asserted to leave nothing:

- **the replacement's id is already held by a different fact.** The pair is
  inserted together, `resolve/5` finds the conflict on the second row, and the
  whole statement rolls back. `test atomicity a failure inserting the
  replacement rolls the correction back too` asserts that only the original and
  the squatting row remain and that the total is unchanged.
- **the outbox refuses.** `test atomicity an outbox that refuses rolls both rows
  back`.
- **a host transaction rolls back.** Both events come back
  `durability: :conditional` and neither survives:
  `test atomicity inside a host transaction both rows are conditional and roll
  back with it`.

## The feature

A replacement restates the same commercial fact, so its feature is the
original's. `:feature` may be given in `attrs` only if it equals it. The facade
reads the original once without a lock to learn the feature (that read decides
nothing financial), and the transaction re-reads the original under
`FOR UPDATE` and refuses a replacement whose feature is not the one it finds.
Both the refusal and its negative control are asserted:
`test refusals replace with a changed feature is rejected` and
`test refusals replace with the same feature stated explicitly is accepted`.

## What a partially corrected original does

The correction's magnitude is the **remaining** quantity, not the whole of it:
an original of 10 already corrected by 4 is reversed by 6, and the total after a
replacement of 3 is 3 (`test refusals replace on a partially corrected original
corrects only the remaining magnitude`). That is also why the duplicate path
compares the stored row's own quantity: a `replace/4` caller never stated a
magnitude, so a magnitude is not something their retry can conflict on. Their
metadata still is.
