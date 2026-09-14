# 03b: the buffered hot path, compared rather than asserted

The brief for this unit names functions that must not change and says the
buffered hot path must be byte-for-byte unchanged in behaviour, because 08c's
benchmark compares it. "I did not touch it" is a claim; this is the comparison.

Producer: `tmp/v1/03b/hotpath.py`. It extracts each function from
`git show HEAD:<file>` and from the working tree **by its `def` line and the
matching `end` at the same indentation**, never by line number (X67, X90,
X108), so a function that moved without changing still compares identical.
Result: `tmp/v1/03b/logs/03b-hotpath.json`.

## Functions compared, all identical to `286f3d6`

| File | Symbol |
|---|---|
| `counter.ex` | `bump/2` |
| `counter.ex` | `reserve/6` |
| `counter.ex` | `incr/4` |
| `counter.ex` | `reserve_pending/2` |
| `counter.ex` | `apply_remote/2` |
| `counter.ex` | `rebase/3` |
| `counter.ex` | `take_pending/2` |
| `counter.ex` | `mark_dirty/1` |
| `store.ex` | `handle_call(:snapshot_flush_batch, ...)` |
| `flusher.ex` | `persist/1` |
| `broadcaster.ex` | `do_broadcast/0` |
| `storage/ecto.ex` | `flush_batch/3` |
| `storage/ecto.ex` | `add_counters/1` |
| `storage/ecto.ex` | `load_counter/3` |
| `aurora_meter.ex` | `track/4` |

## Files with no change at all

`git diff --stat HEAD` over `lib/aurora_meter/credits/`,
`lib/aurora_meter/credits.ex`, `lib/aurora_meter/store.ex`,
`lib/aurora_meter/flusher.ex`, `lib/aurora_meter/broadcaster.ex` and
`lib/aurora_meter/cluster.ex`: **no change at all in any of these files.**

## What did change in `counter.ex`, and why each is permitted

`git diff --stat HEAD -- lib/aurora_meter/counter.ex`: 58 insertions, 14
deletions, four changes and no others.

1. **`commit_work/5` gains `ensure_seeded(key)` before its
   `:ets.update_counter/3`.** Open finding C6, which the brief explicitly
   permits ("only the missing `ensure_seeded/1` call"). The three operands of
   the update are the same three, in the same order, with the same signs: the
   arithmetic is untouched.
2. **`release_work/4` gains the same call**, for the same reason.
3. **`restore_pending/2` removed**, open finding C8: dead since 0.4.0, no
   caller in `lib/` and none in `test/`. Replaced in place by
   `apply_projection/2`, which is new and which nothing on the buffered path
   calls.
4. **`stored_value/1` asks `Config.feature_source/1` first.** For a feature with
   no `feature_sources` entry, which is every feature in 0.4.x and the default
   in 1.0, the answer is `:buffered` and the call is the same
   `Storage.load_counter/3` it always was. This runs on a **cold key seed**,
   which is already a database round trip, and never on a warm increment.

## The behavioural check, not only the textual one

- `RecordProjectionTest` / `a buffered feature still seeds from the counter table, not from event totals`:
  a buffered feature is tracked to 4 and flushed, a durable event of quantity
  100 is recorded against the same key, ETS is reset, and the cold read returns
  **4**. The indirection does not leak event totals into a buffered feature.
- Negative control C1 (`03b-controls.json`) makes `apply_projection/2` write
  `pending_flush` and mark the key dirty, and `I08 a projected event never
  appears in a flush batch` fails. The assertion is load-bearing.
- The 814 tests that existed before this unit all still pass, including the
  buffered path's own: `metering_test`, `entitlements_test`, `store_test`,
  `flusher_test`, `flush_batch_concurrency_test`, `statements_test`,
  `cluster_test`, `cluster_convergence_test`, `kill_test`. One assertion in one
  of them changed, and it is the C6 regression test, which asserted the defect
  this unit fixes.

## Not claimed

A timing comparison. 08c owns the benchmark. What is claimed here is that
`track/4`, `check/2`, `reserve/2,3` and `with_quota/3,4` reach the same code
they reached at `286f3d6`, with no database I/O, no lock and no extra ETS
operation added to any of them.
