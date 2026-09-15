# I18: downtime catch-up, three missed periods

Build unit 06d, V1 task 06.05, `v1-release.md` 10.1 bullet 7. Raw output:
`logs/06d-evidence.txt`, section "i18-catchup"; produced by
`tmp/v1/06d_evidence.exs` on 2026-09-15, core `011ac34` plus 06d's working tree.

One tenant on plan `:allowance` (`amount: 5_000_000, rollover: 1_000_000,
expires: :period_end`). One run on 2026-06-15, then nothing until one run on
2026-10-15 with `max_periods: 12`. All amounts are micro-dollars.

## The run

```
%{"examined" => 1, "tenants" => 1,
  "granted" => 1, "issued_and_expired" => 3, "duplicate" => 0, "conflict" => 0,
  "skipped" => 0, "failed" => 0, "catching_up" => 0,
  "amount" => 20000000, "rollover" => 4000000}
```

Four periods in one run: July, August and September as history, October live.

## The recurrence rows

| period_start | state | rollover_from |
|---|---|---|
| 2026-06-01 | `granted` | no |
| 2026-07-01 | `issued_and_expired` | yes |
| 2026-08-01 | `issued_and_expired` | yes |
| 2026-09-01 | `issued_and_expired` | yes |
| 2026-10-01 | `granted` | yes |

The three missed periods are distinguishable in history from the two that were
granted while they were live, which is exactly what `architecture-map.md` 7.1
added the `state` column for.

## The ledger, in `seq` order

The transaction references are shortened: `recurring:<tenant>:...` is written
`recurring:...`.

| seq | kind | amount | balance_after | reference |
|---|---|---|---|---|
| 203150 | grant | 5,000,000 | 5,000,000 | `recurring:...:2026-06-01T00:00:00Z` |
| 203151 | expire | -5,000,000 | 0 | `expire:f2fd33d7...:0` |
| 203152 | grant | 5,000,000 | 5,000,000 | `recurring:...:2026-07-01T00:00:00Z` |
| 203153 | grant | 1,000,000 | 6,000,000 | `recurring:...:2026-07-01T00:00:00Z:rollover` |
| 203154 | expire | -5,000,000 | 1,000,000 | `expire:60e54f8b...:0` |
| 203155 | expire | -1,000,000 | 0 | `expire:d9f8a1a7...:0` |
| 203156 | grant | 5,000,000 | 5,000,000 | `recurring:...:2026-08-01T00:00:00Z` |
| 203157 | grant | 1,000,000 | 6,000,000 | `recurring:...:2026-08-01T00:00:00Z:rollover` |
| 203158 | expire | -5,000,000 | 1,000,000 | `expire:03c76a1c...:0` |
| 203159 | expire | -1,000,000 | 0 | `expire:ca8bb9b3...:0` |
| 203160 | grant | 5,000,000 | 5,000,000 | `recurring:...:2026-09-01T00:00:00Z` |
| 203161 | grant | 1,000,000 | 6,000,000 | `recurring:...:2026-09-01T00:00:00Z:rollover` |
| 203162 | expire | -5,000,000 | 1,000,000 | `expire:f8a47e5a...:0` |
| 203163 | expire | -1,000,000 | 0 | `expire:ffd25453...:0` |
| 203164 | grant | 5,000,000 | 5,000,000 | `recurring:...:2026-10-01T00:00:00Z` |
| 203165 | grant | 1,000,000 | 6,000,000 | `recurring:...:2026-10-01T00:00:00Z:rollover` |

Read it one period at a time. July (203152 to 203155) grants its allowance,
grants June's carry beside it, and then destroys both, ending at `balance_after
0`. August and September do the same. October (203164, 203165) grants and stops,
because October is the live period.

The `balance_after` chain is the oracle 01e found in the legacy rows (finding
X254) and it is computed under the balance row's lock: 203157 reads 6,000,000
and 203158 reads 1,000,000, which is `6,000,000 - 5,000,000` exactly. Nothing
committed between them.

## The lots afterwards

| seq | reference | amount | available | expired | expires_at | state |
|---|---|---|---|---|---|---|
| 34216 | `...:2026-06-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 | 2026-07-01 | expired |
| 34217 | `...:2026-07-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 | 2026-08-01 | expired |
| 34218 | `...:2026-07-01T00:00:00Z:rollover` | 1,000,000 | 0 | 1,000,000 | 2026-08-01 | expired |
| 34219 | `...:2026-08-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 | 2026-09-01 | expired |
| 34220 | `...:2026-08-01T00:00:00Z:rollover` | 1,000,000 | 0 | 1,000,000 | 2026-09-01 | expired |
| 34221 | `...:2026-09-01T00:00:00Z` | 5,000,000 | 0 | 5,000,000 | 2026-10-01 | expired |
| 34222 | `...:2026-09-01T00:00:00Z:rollover` | 1,000,000 | 0 | 1,000,000 | 2026-10-01 | expired |
| 34223 | `...:2026-10-01T00:00:00Z` | 5,000,000 | 5,000,000 | 0 | 2026-11-01 | open |
| 34224 | `...:2026-10-01T00:00:00Z:rollover` | 1,000,000 | 1,000,000 | 0 | 2026-11-01 | open |

**Seven historical lots, 23,000,000 granted, 0 available.** The live period holds
6,000,000: its own allowance plus the capped carry out of September. That is
criterion 6, and it is the assertion that carries it, because a catch-up that
left the historical allowances spendable would show the same seven lots, the
same 23,000,000 and a final spendable of 29,000,000.

## Two things worth stating rather than leaving implicit

**The rollover chain runs through the historical periods.** July carries out of
June, August out of July, September out of August and October out of September,
even though none of the historical allowances was ever spendable. That is the
build document's rule ("a catch-up reproduces the same chain a timely run would
have produced, except that no spending happened") and it is what makes the live
period's carry 1,000,000 rather than 0. A tenant that was owed an allowance in
July and never received it is not also punished in October.

**A tenant is not back-paid before its first row.** `test I18 a tenant seen for
the first time is not back-paid` runs the engine for the first time in October
with `max_periods: 12` and gets exactly one recurrence row and one lot. The
walk's `last == nil` branch returns the current period only, and there is no
option that changes it; a deliberate backfill would be new API with its own
evidence, not a default.
