# 08c: load across a real database outage

**G08 bullet 3**: "Load with database outage recovers to exact totals; backlog
drains faster than arrival rate at the documented tested load."

The outage is a real `docker stop` of the Postgres container, orchestrated by
`scripts/v1/bench.sh`. Nothing is simulated: connections die, the flusher's
write fails, the batch is retained, and the container is started again.
`AuroraMeter.Bench.DelayStorage` can refuse a flush, and it is deliberately not
used here, because a storage adapter that returns `{:error, _}` proves the
flusher retries and proves nothing about what Postgres does when it comes back.

## 1. Tasks, repository and revision

- Tasks: 08.06 (the `db_recovery` mode), 08.07 (the record), G08 bullet 3.
- Core working tree at `34c188d`, dirty with 08c's changes.

## 2. Environment

| | |
|---|---|
| Machine | WSL Ubuntu 24.04.4, AMD Ryzen 9 7900X, 24 logical CPUs, 19.5 GiB |
| Runtime | Elixir 1.20.1, OTP 29, ERTS 17.0.1, 24 schedulers |
| Database | Postgres 16.13 in container `aurora-meter-pro-testdb`, port 5490, database `aurora_meter_bench`, pool 30 |
| Flush interval | 1,000 ms (the flusher's own timer runs: its retry is the thing measured) |
| History | on |

## 3. Commands and logs

```
bash scripts/v1/bench.sh run --modes db_recovery --runs 3 --out tmp/v1/bench/outage \
  --outage-seconds 20 --seconds-before-outage 15 \
  --extra "--duration 60000 --backlog-keys 2000 --drain-timeout 300000"
exit=0
```

Per run: 8 workers increment 2,000 rotating keys for 60 seconds; at 15 seconds
the runner stops the container; 20 seconds later it starts it; the load finishes
its window and the task then waits for the dirty set and the pending batch to
reach zero, timing that wait.

Artifacts: `runs/outage/db_recovery-{1,2,3}.json` (records, including the
per-second timeline) and `runs/outage/db_recovery-{1,2,3}-outage.txt` (the
container timeline, with the UTC instant of each `docker stop` and `docker
start`).

Run 1's container timeline is `runs/outage/db_recovery-1-outage.txt`, and it
carries the UTC instant of the `docker stop`, of the container reporting itself
stopped, of the `docker start` and of the task's exit.

## 4. Results

Three runs, all `correct: true`:

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| Increments issued | 89,344,406 | 88,538,665 | 91,074,200 |
| Persisted after the drain | **89,344,406** | **88,538,665** | **91,074,200** |
| Dirty keys at the end | 0 | 0 | 0 |
| Pending batch items at the end | 0 | 0 | 0 |
| Arrival rate | 1,489,093/s | 1,475,658/s | 1,517,926/s |
| **Recovery rate** | **35,595,900/s** | **34,741,004/s** | **34,811,861/s** |
| Recovery faster than arrival | **true** | **true** | **true** |
| Samples with no persisted read (the outage) | 6 | 7 | 7 |
| Backlog left when the load stopped | 1,785,886 | 335,504 | 596,032 |
| Time to clear it | 1,213.29 ms | 1,112.68 ms | 909.61 ms |
| Post-load drain rate | 1,471,936/s | 301,528/s | 655,261/s |
| Post-load drain faster than arrival | false | false | false |

**The exact-totals half of G08 bullet 3 holds on all three runs**, asserted by
the mode itself rather than by eye: the run's `correct` is a comparison of the
persisted sum over this run's tenant prefix against the number of increments the
workers actually issued, and a mismatch fails the run and exits non-zero.

**The drain half needs its two numbers distinguished, and the difference is the
most useful thing on this page.**

- `recovery_rate_per_sec` is the largest one-second increase in the persisted
  total anywhere in the run, taken from the timeline. It is **23 times the
  arrival rate** on all three runs, and it is what the guarantee is about: how
  fast the backlog that accumulated during the outage was cleared once the
  database returned.
- `drain_rate_per_sec` is what was left when the load **stopped**, divided by the
  time to clear it. That is whatever the flush cycle happened to be holding at
  that instant, divided by the roughly one-second fixed cost of the flush that
  clears it. On this run it is below the arrival rate on all three, and on run 2
  it is 335,504 increments cleared in 1.1 seconds by a system that had cleared
  34 million a second a few seconds earlier.

  **It is recorded because it is a real measurement and it is not the claim.**
  An earlier set of three runs of the same code had it above the arrival rate on
  two of three, purely because the load happened to stop at a different point in
  the flush cycle. A metric that flips on where a five second timer was when the
  clock stopped is not a metric to gate on, and that is the whole reason
  `recovery_rate_per_sec` exists beside it.

Both are in every record, and neither is presented as the other.

### The timeline, which is the artifact

Every run's per-second samples are in its record under `backlog.timeline`, as
`(elapsed_ms, dirty keys, pending batch items, persisted total)`. The shape,
which is the same on all three:

```
  4000   4000            0      load starts
  4000      0    1,682,855
  4000      0    3,727,561
  ...                          persisted climbing about 1.5M a second
  4000   4000         null     <- docker stop; the sum query cannot run
  4000   4000         null      six or seven samples, the outage window
  4000   4000         null
  4000   4000   23,423,484     <- container back; first successful read
  4000      0   25,350,681
  4000      0   61,000,000+    <- +35M in one second: the catch-up
  ...
     0   4000   <total - tail>  load stops
     0      0   <total>         the last batch commits; totals are exact
```

`persisted` is **null** while the database is gone, and it is null rather than
zero on purpose: a zero there would read as "nothing had been persisted", which
is a measurement, and this is its absence. The six or seven null samples per run
are the outage window.

`dirty_keys` sits at 4,000 throughout (2,000 period counters plus 2,000 day
buckets) because the workload rotates a fixed key set, so it cannot show the
backlog growing. The backlog is visible in `persisted` instead: it stops moving
for the duration of the outage and then jumps by the whole accumulation.

## 5. Changes

None to the library. `AuroraMeter.Bench.Modes.Faults` is new bench code.

## 6. Open defects, and the control that found one

**X338, and it makes this result conditional.** The three runs above rotate
2,000 keys. The same measurement with **12,000** keys never drains at all, with
the database back and running:

```
bash scripts/v1/bench.sh run --modes db_recovery --runs 1 \
  --out tmp/v1/bench/outage-control --outage-seconds 10 --seconds-before-outage 10 \
  --extra "--duration 30000 --backlog-keys 12000 --drain-timeout 60000"
exit=2   (the task raised, so no record was written: the log IS the artifact,
          and the runner refused to write a summary for a partial set)

** (RuntimeError) the bench waited 60000 ms and the dirty set never emptied:
   24000 dirty keys, 24000 items in the pending batch.
AuroraMeter flush failed; the same batch will be retried:
   "postgresql protocol can not handle 84000 parameters, the maximum is 65535"
```

One flush uses seven bind parameters per counter row against Postgres's 65,535,
so a batch of more than 9,362 counter keys cannot be sent, and the flusher
retries it for ever. Measured to the key in `08c-flush-limit.md`.

**So G08 bullet 3 is met at the documented tested load and not above it**, and
the load has to be documented in keys rather than in increments per second: the
recovery is fast at 2,000 distinct counter keys and does not happen at all above
9,362. That is the sentence a host needs, and it is not the sentence the gate
bullet currently says.

The control is why this page can say that. Without it the three green runs would
have read as an unconditional recovery guarantee.

## 7. Handoff

Re-run the three commands in sections 3 and 6. The runner takes both package Mix
lane locks before stopping the container, because that container also serves
`aurora_meter_test` and `aurora_meter_pro_test` and a suite running beside it
would fail for a reason its author could never find.

11d's soak consumes this mode and this record format. What it should add is the
one thing three minutes cannot show: whether the recovery rate holds when the
outage is long enough that the accumulated deltas exceed what one batch can
carry, which on this code is the X338 boundary again.
