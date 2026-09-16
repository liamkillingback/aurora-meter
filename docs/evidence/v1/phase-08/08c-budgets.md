# 08c: the performance budgets

V1 task **08.08**. The machine-readable form is
`scripts/v1/budgets.json` in the storefront; this is the rule in words and the
reference each mode is measured against.

## The rule

| Family | Modes | Metric | Budget |
|---|---|---|---|
| Hot path | `spread`, `hot`, `reserve`, `with_quota`, `cluster_2_sim` | median throughput across five runs | a fall of more than **10 percent** against the reference is a breach |
| Durable path | `record`, `record_batch`, `correct`, `replay`, `credits_debit`, `credits_hot_wallet`, `flush_1k`, `flush_10k`, `flush_100k` | median `latency_us.p95` across five runs | a rise of more than **20 percent** against the reference is a breach |
| Cluster and fault | `cluster_2`, `cluster_4`, `db_delay`, `db_recovery` | none | the correctness assertion must hold; the numbers are recorded and compared by eye |

**A breach is a stop, not a warning.** `bench.sh compare` exits non-zero naming
the mode, the reference, both medians and both spreads. The unit that caused it
either fixes the regression or writes a tradeoff note in `08c-regressions.md`
with the cause, the measurement, the reason the tradeoff is accepted and the
claim being retired. 08.08's last sentence ("publish the measured result without
the obsolete claim") is implemented as a rule with teeth: whenever a tradeoff is
accepted, the same change updates `README.md`'s table in the same branch, and
`AuroraMeter.Bench.ClaimsTest` fails if the README quotes a figure that is not in
`08c-results.md`.

### Why the cluster and fault modes have no numeric budget

Not because they matter less. A cluster overshoot is a function of the burst's
length against the `broadcast_interval`: the same code measured 10,000 at a
1,000 ms interval and between 880 and 2,462 at 25 ms (`08c-cluster.md`). A fault mode's figures
depend on where in the flush cycle the outage fell. A percentage threshold across
runs would fire on the shape of the run rather than on a change in the software,
which is the definition of a gate that trains people to ignore it. What those
four modes assert instead is arithmetic: exact totals, a bound computed from the
configured intervals, and zero admissions after one settling window.

## The reference for each mode

| Mode | Reference | Why |
|---|---|---|
| `spread` | **v0.4.0**, 4,782,812 ops/s, from a clone (`08c-baseline.md`) | the one shape the 0.4.0 task has |
| every other mode | **its own first V1 measurement**, the table in `08c-results.md` | the mode, or the code it measures, does not exist at 0.4.0 |

The second row is a real limitation and is stated rather than implied: **a budget
whose reference was taken by the same code it is policing can only catch a later
change.** It cannot say anything about the code as it stands today. `reserve` and
`with_quota` exist as APIs at 0.4.0 but not as bench modes, so they are in the
second row too.

## The threshold against the noise, which decides whether a budget means anything

Run-to-run spread from `08c-results.md`, five runs each, against the family's
threshold:

| Mode | Spread | Threshold | Meaningful? |
|---|---|---|---|
| `with_quota` | 4.63% | 10% | yes |
| `flush_1k` | 4.55% | 20% | yes |
| `db_delay` | 5.1% | none | |
| `record` | 5.24% | 20% | yes |
| `cluster_2_sim` | 6.85% | 10% | marginal |
| `db_recovery` | 9.47% | none | |
| `hot` | 10.01% | 10% | **no** |
| `spread` | 12.19% | 10% | **no** |
| `reserve` | 13.1% | 10% | **no** |
| `replay` | 15.11% | 20% | marginal |
| `credits_hot_wallet` | 19.36% | 20% | **marginal** |
| `cluster_4` | 24% | none | |
| `correct` | 30.64% | 20% | **no** |
| `cluster_2` | 41.32% | none | |
| `credits_debit` | 48.01% | 20% | **no** |
| `record_batch` | 61.1% | 20% | **no** |
| `flush_10k`, `flush_100k` | n/a | 20% | no measurement at all (X338) |

**Six modes have a run-to-run spread at or above their own threshold on this
hardware, and three of them are hot-path modes.** For those the budget can fire
on noise, and a breach is a reason to re-measure before it is a reason to act.
That is why `compare` reports both directories' spreads beside every verdict
rather than only the medians: a reader who sees `fall_percent: 22` beside
`candidate_spread_percent: 48` knows what they are looking at.

It is also worth knowing how much of this is the machine rather than the
workload. The same `spread` mode, on the same code, measured 6.67% spread on one
run of five and 12.19% on another an hour later, and the v0.4.0 baseline moved
from 4,933,320 to 4,782,812 between two measurements of **identical code at the
same tag**. This laptop had been running test suites and benchmarks for several
hours by the second measurement. 11d's soak should re-measure on a quiet machine
before anybody concludes that a mode is inherently noisy.

The one breach recorded so far is `spread` at 28.53% against a 12.19% spread,
which is more than twice the noise **and** has a cause measured to the
nanosecond. The second half is doing real work here: at a 12% spread the
threshold alone would not have been enough to believe a 12% fall.

## Running it

```
bash scripts/v1/bench.sh compare \
  --baseline docs-or-tmp/<reference-dir> \
  --candidate tmp/v1/bench/<candidate-dir> \
  [--budgets scripts/v1/budgets.json]
```

Exit 0 when nothing breached, 1 when something did, and 1 when **nothing was
compared**: an empty comparison is a failure and never a clean sweep
(`open-findings.md` X325).

The thresholds are tested rather than assumed. `scripts/v1/test/19-bench-budgets.sh`
builds synthetic run directories and asserts a 15 percent hot-path fall and a 25
percent durable p95 rise each exit non-zero, and that a 5 percent fall and a 10
percent rise each exit zero. The two passing cases carry as much weight as the
two breaches: a comparison that failed on everything would satisfy both breach
assertions and be useless.
