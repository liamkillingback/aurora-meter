# 07b: the two lags, measured

Build unit 07b. `docs/plans.md` quotes these numbers, so they are measurements
rather than assertions. Harness `tmp/v1/07b-lag.exs`, raw output
`07b-logs/lag.log`, run 2026-09-16 on the development host (24 schedulers,
Postgres on `localhost:5490`, Elixir 1.20.1 / OTP 29).

## 1. The cron lag: boundary to application

A transition effective at `T` is applied by the next run of
`apply_due_transitions/1`. Under the `"*/5 * * * *"` default that is up to five
minutes plus the run's own time, and in between the tenant is entitled under the
**old** plan.

**Measured with the interval compressed to 5 seconds**, so this runs in half a
minute rather than in ten. Twelve transitions with their boundaries placed
evenly across one interval; the applier ticked at the interval boundaries, the
way a crontab ticks it; and the lag read back as the **database's own**
arithmetic, `applied_at - effective_at`, never a figure computed in Elixir.

```
=== A. cron lag, interval 5000ms, 12 transitions ===
tick 1: %{failed: 0, cursor: :done, applied: 0, skipped: 0}
tick 2: %{failed: 0, cursor: :done, applied: 12, skipped: 0}
applied: 12
lag seconds min=1.02 max=4.991
lag seconds median=3.009
lag seconds all=[1.02, 1.024, 1.027, 2.013, 2.017, 3.006, 3.009,
                 3.995, 3.998, 4.002, 4.986, 4.991]
wall clock across both ticks: 5053ms
```

| Figure | Value |
|---|---|
| Minimum | **1.020 s** |
| Median | **3.009 s** |
| Maximum | **4.991 s** |
| Interval | 5.000 s |

The distribution fills the interval, which is the shape the claim is about: a
transition's lag is uniform over `[0, interval]` plus the run's own time, and the
**bound** is the interval. Under the `*/5` default that is **up to 300 s plus
the run's own time**.

The values cluster at whole seconds because
`aurora_meter_plan_transitions.effective_at` is `:utc_datetime`, a second
precision column. A boundary is a second, never a millisecond, which is correct
for a commercial boundary and is why the measured lags land on the second.

## 2. The run's own time, which is the other term

```
=== B. one run over 500 due transitions ===
batch: %{failed: 0, cursor: "2026-09-16T00:00:11Z|lagbatch9476_99",
         applied: 500, skipped: 0}
apply_due_transitions(limit: 500) over 500 due transitions: 1816ms
per transition: 3.632ms
```

**1816 ms for 500 tenants, 3.632 ms each**, one transaction per tenant on one
node against a local Postgres. So the run's own time is not what the bound is
made of at any plausible batch size; the schedule is. A host that wants a
tighter bound raises the cron frequency, calls `apply_due_transitions/1` from
its own scheduler, or calls it with `tenant:` from the request that made the
change.

The `cursor` in that return is the compound keyset value
`"<effective_at ISO 8601>|<tenant_key>"`, which is the shape 07c pages with.

## 3. The cache staleness window

`apply_due_transitions/1` invalidates the subscription cache **after** the
transaction commits, and that invalidation is a PubSub broadcast, which is best
effort. A node that misses it serves the old plan until its own entry expires.

Two measurements, one from each side.

### 3a. A write that broadcasts nothing at all

```
=== C. cache staleness after an apply, default TTL ===
subscription_cache_ttl: 5000ms
converged on scale after 5008ms
```

The cache is warmed on the old plan, the row is then changed by a raw `UPDATE`
that no code path announces, and `AuroraMeter.Subscriptions.get/1` is polled
until it answers with the new plan. **5008 ms** against a **5000 ms** TTL: the
8 ms is the 10 ms poll interval.

### 3b. The acceptance criterion: `kill -9` between the commit and the invalidation

From `test I16 the applier killed after commit and before cache invalidation
converges`, printed by the ordinary suite run:

```
[07b] cache staleness after a kill: ttl=5000ms window_from_warm=5000ms window_from_kill=4995ms
```

| Figure | Value |
|---|---|
| `subscription_cache_ttl` | 5000 ms (the default, not a shortened one) |
| From the warming read to convergence | **5000 ms** |
| From the kill to convergence | **4995 ms** |

The test asserts `window > 0` (so a convergence that happened for some other
reason cannot pass it) and `window <= ttl + 1000`. Between the kill and the
convergence the **database is already correct**: the subscription row names the
new plan and the audit row says `applied`, both asserted on an independent
connection before the polling starts. This is a visibility bound, not a
correctness one.

Negative control `i-invalidate-before-commit` moves the invalidation inside the
transaction and this is the only test that fails, which is what makes it the
assertion carrying the claim rather than a description of one.

## 4. What these numbers licence, and what they do not

**Licensed.** `docs/plans.md` saying "up to five minutes plus the run's own
time" for the default schedule, and "at most `subscription_cache_ttl`
milliseconds, default 5,000" for the read-side lag.

**Not licensed.** Nothing here measures a multi-node cluster: the cache
staleness figures are one node's ETS entry expiring, and a second node that
missed the broadcast has exactly the same bound for exactly the same reason, but
that has not been measured here. Nothing here measures a production-sized table
either: the 500 tenant run is against a table with a few thousand rows, and the
due scan is served by the partial index core schema version 10 creates, so the
scan cost is bounded by the number of **pending** rows rather than by the table.
A host with a very large pending backlog should measure its own.
