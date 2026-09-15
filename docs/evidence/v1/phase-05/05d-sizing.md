# 05d: what the flush receipt table costs, measured

Task **03.09**'s third clause: publish storage sizing and archive guidance.
Build unit **05d**, 2026-09-15.

The full output is `05d-sizing.log`. The script that produced it is
`priv/v1/receipt_sizing.exs`, kept in the repository because 11d's soak re-runs
it. It refuses to run against a database whose name does not contain `_test`,
because it inserts a million rows and then truncates the table.

## Provenance

| | |
|---|---|
| Command | `DB_PORT=5490 MIX_ENV=test mix run priv/v1/receipt_sizing.exs`, exit **0** |
| Core SHA | `0b3df43d7e6e425177f2f926df98a8aeb004d512` plus this unit's working tree |
| Postgres | 16, port 5490, database `aurora_meter_test` |
| Elixir / OTP | 1.20.1 / 29 (erts 17.0.1) |
| Rows inserted | 1,000,000, `inserted_at` spread uniformly over 60 days |

## The numbers

| | Measured |
|---|---|
| Rows | 1,000,000 |
| Table | **50 MB** |
| Primary-key index | **39 MB** |
| Total relation | **88 MB** |
| **Bytes per row, heap and index together** | **92.6** |
| Insert of a million rows | 3,044 ms |

The row is a `uuid` and a `timestamp`, 24 bytes of payload. The rest is the
Postgres row header and the index entry, which is why the honest figure is 92.6
and not 24.

### Per node, at the shipped defaults

`flush_interval` ships at 5,000 ms and a node under continuous traffic produces
one receipt per tick. **The test environment configures 60,000 ms**, so the
script reads the shipped default out of `AuroraMeter.Config.defaults/0` rather
than out of the running configuration; taking the environment's value would have
understated every figure below by a factor of twelve.

| | |
|---|---|
| Rows per node per day | **17,280** |
| Per node per day | **1.53 MiB** |
| Per node per year | **0.54 GiB** (6.3 million rows) |
| A four-node cluster, one year | about **2.2 GiB**, 25 million rows |

The 05d build document's arithmetic estimate was "roughly 100 bytes ... 1.7 MB
per day per node, 630 MB per year per node". Measured: 92.6 bytes, 1.53 MiB,
0.54 GiB. The estimate was high by about 8 per cent, which is close enough that
the estimate was not wrong, and the measurement is what `docs/retention.md` now
cites.

## `EXPLAIN (ANALYZE, BUFFERS)`

### `plan/1`, the count

```
Result  (actual time=22.956..25.306 rows=1 loops=1)
  Buffers: shared hit=6370
  CTE bound
    ->  Result  (actual time=0.002..0.003 rows=1 loops=1)
  InitPlan 3 (returns $3)
    ->  Finalize Aggregate  (actual time=22.953..25.301 rows=1 loops=1)
          ->  Gather  (actual time=22.901..25.297 rows=3 loops=1)
                Workers Planned: 2   Workers Launched: 2
                ->  Partial Aggregate  (actual time=20.549..20.549 rows=1 loops=3)
                      ->  Parallel Seq Scan on aurora_meter_flush_receipts
                            (actual time=0.008..16.350 rows=166677 loops=3)
                            Filter: (inserted_at < $1)
                            Rows Removed by Filter: 166657
Execution Time: 25.321 ms
```

**25 ms** over a million rows. A parallel sequential scan, which is what a count
over half a table should be.

### `prune/1`, one batch of 1,000

```
Delete on aurora_meter_flush_receipts  (actual time=62.065..62.067 rows=0 loops=1)
  Buffers: shared hit=11215 read=158 dirtied=29
  ->  Nested Loop  (actual time=60.690..63.124 rows=1000 loops=1)
        ->  HashAggregate  (actual rows=1000)
              ->  Limit  (actual rows=1000)
                    ->  Sort  Sort Key: inserted_at
                          Sort Method: top-N heapsort  Memory: 168kB
                          ->  Seq Scan on aurora_meter_flush_receipts
                                (actual time=0.008..42.354 rows=500030 loops=1)
                                Filter: (inserted_at < $1)
        ->  Index Scan using aurora_meter_flush_receipts_pkey
              Index Cond: (id = "ANY_subquery".id)
Execution Time: 62.098 ms
```

**62 ms** per batch of 1,000 over a million rows: a sequential scan feeding a
top-N heapsort, then a primary-key index scan per row to do the delete.

### The whole eligible set, through the public API

```
prune/1 over the eligible rows: 20,787 ms -> {:ok, %{flush_receipts: 499033}}
rows left (inside the 30 day window): 499967
```

499,033 rows in 500 batches of 1,000, in **20.8 seconds**, about 42 ms a batch.

## The decision about the index

`aurora_meter_flush_receipts` carries only its primary key, so the predicate is a
sequential scan. The 05d build document recorded three options and chose to
accept the scan for V1. Measured, that choice holds:

* 62 ms per batch at a million rows, on a job that runs once a night off peak.
* The table is append-only, so the old rows are physically first and the scan
  stops finding qualifying rows early once the backlog is gone.
* An index on `inserted_at` would cost a write on **every flush, for ever**
  (17,280 per node per day) to save a number that is already tens of
  milliseconds.

The contingency is unchanged and is recorded rather than done: if 11d's soak
shows otherwise at a hundred million rows, the index goes into the next core
schema version that is already being opened, and `schema-migration-map.md` is
updated with it. **This measurement is at one million rows and says nothing
about a hundred million**, which is the honest limit of it.

## Archive guidance

Aurora Meter uploads nothing anywhere and ships no archiver, because building one
would be a second storage system and the host already has a better one. The
guidance in `docs/retention.md` is:

* **Before a prune, if you want a copy**, `COPY (SELECT ... WHERE inserted_at <
  now() - interval '30 days') TO ... WITH CSV HEADER`.
* **For everything that is never pruned**, which is where the financial history
  is, the archive is the host's ordinary database backup. Getting those tables
  out of the hot database for size reasons is a partitioning or warehouse
  question, not a retention one: an event, a correction or a ledger row that is
  gone cannot be reconciled against a provider afterwards.
* **A very large first prune** runs with a small `:max_items` over several
  nights. A run that stops at its budget now says so
  (`reason: :budget_exhausted`) rather than looking complete.
