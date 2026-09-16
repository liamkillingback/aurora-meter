# 08c: overshoot and convergence on real nodes

Build unit **08c**, V1 task **08.06** (the two and four node cluster modes), and
the measured half of invariant **I05** ("overshoot measured and asserted within
bound").

Two and four **real BEAM nodes**, started with `:peer`, each with its own
supervision tree and its own connection pool, sharing one database and one
distributed `Phoenix.PubSub`. Not a simulation. `cluster_2_sim` exists beside
these and is labelled `micro`, because a single-VM gossip measurement has one
scheduler, one pool, one ETS table and one copy of the code, and the whole point
of naming it `_sim` is that it can never be quoted as a cluster result.

## 1. Tasks, repository and revision

- Tasks: 08.06, 08.07, invariant I05.
- Core working tree at `34c188d`, dirty with 08c's changes.

## 2. Environment

| | |
|---|---|
| Machine | WSL Ubuntu 24.04.4, AMD Ryzen 9 7900X, 24 logical CPUs |
| Runtime | Elixir 1.20.1, OTP 29, ERTS 17.0.1 |
| Distribution | `:peer`, short names, one cookie, every node on this host |
| Database | Postgres 16.13, `aurora_meter_bench`, pool 8 per node |
| Plan | `AuroraMeter.Bench.Plans` `:bench_cluster`, `limit :ops, 10_000, :hard` |
| Workload | 20,000 `AuroraMeter.Entitlements.reserve/4` calls per node against one shared tenant |

Pool 8 per node and not the configured 30: four nodes at 30 opened 120
connections against a server whose `max_connections` is 100, and the peers
reported `too_many_connections` while the run carried on measuring whatever got
through.

Each peer's repo, PubSub and `AuroraMeter` tree run under **one supervisor**,
started inside a process that is held for the life of the node. `:erpc.call/4`
runs the call in a transient process on the peer, and three bare `start_link`s
died with it: the first version's peers shut down mid-run and reported a
`DBConnection.Holder.checkout` failure several layers from the cause.

## 3. Commands and logs

```
bash scripts/v1/bench.sh run --modes cluster_2,cluster_4 --runs 5 --out tmp/v1/bench/v1-rc1
exit=0

bash scripts/v1/bench.sh run --modes cluster_2,cluster_4 --runs 5 \
  --out tmp/v1/bench/cluster-gossip --extra "--broadcast-interval 25"
exit=1   (one of ten: cluster_2 run 4, finding X346)
```

Records: `runs/v1-rc1/cluster_{2,4}-*.json` and
`runs/cluster-gossip/cluster_{2,4}-*.json`. Every record's `backlog.cluster`
block carries the node names, the per-node admissions and denials, the overshoot,
the bound, the measured per-node reservation rate and the formula that produced
the bound.

## 4. Results

### The guarantee

`architecture-map.md` section 3: cluster overshoot is bounded by **what other
nodes admitted within one `broadcast_interval`** (one `flush_interval` if gossip
was lost). The bound is therefore computed from the configured interval and the
measured per-node reservation rate, never from a constant:

```
bound = (nodes - 1) x ceil(per_node_reservation_rate x broadcast_interval_ms / 1000)
```

The rate is the **reservation** rate and not the admitted rate, because inside
the window before gossip arrives a node admits everything it attempts.

### Shape one: `broadcast_interval` 1,000 ms, the burst finishes inside it

Five runs each. The burst takes about 190 to 230 ms, which is 19 to 28 percent of
one interval, so on nine of the ten runs **no gossip tick happens at all** and
every node admits the whole limit on its own. That is the worst case the
guarantee allows.

| | cluster_2 | cluster_4 |
|---|---|---|
| Nodes | 2 | 4 |
| Reservations attempted | 40,000 | 80,000 |
| Admitted | 20,000 on four runs, 18,766 on the fifth | 40,000 on all five |
| Limit | 10,000 | 10,000 |
| **Overshoot** | **10,000** (= limit), 8,766 on the fifth | **30,000** (= 3 x limit) |
| Computed bound | 61,279 to 104,420 | 217,305 to 285,933 |
| Overshoot within bound | yes, on all five | yes, on all five |
| Admitted after one settling window | **0** on all five | **0** on all five |
| Persisted after a flush on every node | equal to admitted | equal to admitted |
| Every node's value equal after the flush | yes | yes |
| `correct` | true on all five | true on all five |

**Overshoot is exactly `(nodes - 1) x limit`** on nine of ten runs, which is what
"no node heard from any other" means: each of them independently admitted up to
the limit. The tenth, `cluster_2` run 5, took 326 ms and therefore spanned a
third of an interval more than the others; one gossip tick landed inside it and
1,234 fewer reservations were admitted. That single run is the shape the second
measurement below makes deliberate.

### Shape two: `broadcast_interval` 25 ms, so gossip ticks during the burst

The same burst now spans 7.5 to 12.3 intervals.

| Run | cluster_2 overshoot | bound | within? | cluster_4 overshoot | bound | within? |
|---|---|---|---|---|---|---|
| 1 | 1,596 | 2,388 | yes | 4,812 | 4,863 | yes |
| 2 | 880 | 2,661 | yes | 4,193 | 6,258 | yes |
| 3 | 2,141 | 2,620 | yes | 2,068 | 7,395 | yes |
| 4 | **2,462** | **2,316** | **NO** | 1,908 | 7,134 | yes |
| 5 | 2,179 | 2,517 | yes | 3,996 | 6,720 | yes |

Every run: converged, `admitted_after_one_settling_window: 0`, persisted equal to
admitted. Nine of ten `correct: true`; `cluster_2` run 4 is `correct: false`
because its overshoot exceeded its computed bound by **146 admissions, 6.3
percent**.

**The overshoot falls from 10,000 to between 880 and 2,462 at two nodes, and from
30,000 to between 1,908 and 4,812 at four, purely by shortening the gossip
interval.** That is the guarantee behaving as stated: the overshoot is a function
of the interval, and an operator who needs a tighter bound buys it with a shorter
`broadcast_interval` and more PubSub traffic.

### The run that crossed its bound, and why it is left failing

`cluster_2` run 4: 40,000 reservations attempted across two nodes in 216 ms, a
per-node reservation rate of 92,623/s, a 25 ms interval, and therefore a computed
bound of `1 x ceil(92,623 x 0.025) = 2,316`. Observed overshoot **2,462**.

The bound is the guarantee's own sentence turned into arithmetic, and the
guarantee says **"within one `broadcast_interval`"**. What actually bounds a
node's blind window is the interval **plus** the time for the tick's message to
be published, delivered across the distribution link and applied to the local
ETS row. At a 1,000 ms interval that addition is lost in the rounding. At 25 ms
it is 6 percent of the window, and it is the difference between the ten runs
passing and nine of them passing.

**The assertion is deliberately not loosened.** Adding a delivery allowance would
mean choosing a constant, and a bound with a chosen constant in it is no longer
the documented guarantee, it is the documented guarantee plus whatever made the
run green. What is recorded instead is finding **X346**: at short intervals the
documented bound is tight, and a host computing a worst case from the sentence as
written would be a few percent short. The wording, not the arithmetic, is what
needs deciding.

### Convergence, which is the half a burst cannot show

After the burst, every run waits one settling window (3,000 ms) and then asks
**every node** for one more unit. Every node refuses, on all twenty runs across
both shapes. A cluster that overshot and then went on overshooting would satisfy
a bound check and be broken.

## 5. Changes

None to the library. `AuroraMeter.Bench.Modes.Cluster` is new bench code, and
`Mix.Tasks.AuroraMeter.Bench` gains `--broadcast-interval` and
`--flush-interval` so that a guarantee stated in terms of an interval can be
measured at more than one value of it.

## 6. Open defects, and two measurement errors this unit made and corrected

Both were found by running the second shape, and neither would have been visible
from the first.

1. **The convergence reading was wrong, and it read as a failure of the
   software** (X340). The first version flushed and read each node in turn, so
   node 1 was read against the database total node 1's own flush had just
   produced and was never read again. Four nodes reported 10,000 / 20,000 /
   30,000 / 40,000, a perfect staircase, and the record said `converged: false`.
   Every one of those readings was correct at the instant it was taken. The fix
   is to flush on every node, wait the settling window, and then read every node;
   all twenty runs since report `converged: true`.

2. **The bound was too tight, and at the default interval it could not fail**
   (X341). The first formula used the per-node **admitted** rate, which divides
   the admissions by the whole run including its long tail of denials. At a
   1,000 ms interval the overshoot is the limit and the bound is a hundred
   thousand, so the error was invisible. At 25 ms it refused overshoots the
   guarantee allows: 776 against a bound of 715 on the first run, and ten of ten
   reporting `correct: false` for a system that was behaving correctly.

   This is `open-findings.md` X125's shape in an assertion rather than in a test:
   the check passed at the only workload anyone had run it at, and it passed for
   a reason that had nothing to do with its being right. **An assertion whose
   subject is a rate against an interval should be run at two intervals before it
   is believed**, and doing so here found one error in the assertion and one in
   the guarantee's wording.

3. **X346**, above: the documented bound is tight at short intervals.

## 7. Handoff

Both commands are in section 3. `:peer` needs `epmd`, which ships with OTP; when
distribution cannot start, or a peer cannot be booted, the mode exits non-zero
with `reason: "distribution_unavailable"` in `backlog.cluster` and a note saying
it did **not** fall back to `cluster_2_sim`. That path is exercised by
`Mix.Tasks.AuroraMeter.BenchTest` with `AURORA_BENCH_NO_DISTRIBUTION=1`, which
exists so the refusal can be observed on a host where distribution works.

11d's soak inherits this rig. The question it can answer and three minutes cannot
is whether the settling probe still refuses after hours, when the counters have
been rebased by many flushes from many nodes rather than by one. It should also
settle X346 one way or the other: a hundred runs at 25 ms would say whether one
in ten is the rate, and whether the excess is bounded by anything.
