# 07b: independent connections, forced contention, kills and controls

Build unit 07b. Every number here was printed by a run; the run's own log is
`07b-logs/core-check.log` and the per-control logs are under
`07b-logs/controls/`.

## 1. The harness

`test/aurora_meter/plan_transitions_concurrency_test.exs`,
`use ExUnit.Case, async: false`, `@moduletag :fault`. **Not**
`AuroraMeter.DataCase`: the sandbox wraps a test in one transaction on one
connection, which serialises the contention a row lock and a conditional update
exist to survive. Every task takes its own connection through
`AuroraMeter.Test.Connections.run/3` (pool size 60, so twelve tasks are well
inside `max_tasks/0`), and every assertion is made on what the database holds
afterwards.

Tenant prefix `plantrans`, registered and swept in `test/test_helper.exs`.

**The contention is forced, not hoped for** (`open-findings.md` X182, X186,
X187). Two mechanisms:

1. **A rendezvous.** Each of the N tasks increments an atomic counter and spins
   on `:erlang.yield/0` until all N have arrived, with a five second deadline
   that raises naming how many did arrive. So the calls are issued together
   rather than in whatever order the scheduler started them.
2. **A holder.** For the twelve-way apply, a thirteenth process takes
   `SELECT ... FOR UPDATE` on the tenant's subscription row in its own
   transaction and holds it while the twelve start. It is released only after
   the waiter count has been read.

**The waiter count comes from `pg_stat_activity`, not `pg_locks`.** A process
waiting for a row lock is invisible to `pg_locks` filtered by `database`; it
reports `wait_event_type = 'Lock'` in `pg_stat_activity`, and that is what is
counted:

```sql
SELECT count(*) FROM pg_stat_activity
 WHERE wait_event_type = 'Lock' AND state = 'active'
```

## 2. The twelve-way results, seed 0

| Test | Connections | Observed |
|---|---|---|
| `I16 twelve independent connections scheduling one ref produce one transition row` | 12, rendezvous | 12 results, all `{:ok, %PlanTransition{}}`, **1 distinct id**, **1** row in `aurora_meter_plan_transitions`, mirror `transition_ref = "r"`, `transition_state = "pending"`. Telemetry: **`%{scheduled: 1, idempotent: 11}`** |
| `I16 twelve independent connections applying one due transition apply it once` | 12, rendezvous, behind a held row lock | **applied=1 skipped=11**, one `state = 'applied'` audit row, subscription on `("scale", "1")` with `transition_state = 'applied'`, **row_lock_waiters=12** |

Printed verbatim by the run:

```
[07b] twelve schedules of one ref: %{scheduled: 1, idempotent: 11} rows=1
[07b] twelve appliers of one due transition: applied=1 skipped=11 row_lock_waiters=12
```

**The contended branch is asserted on an ordinary run** (`open-findings.md`
X214): `assert results.counts[:idempotent] == 11`,
`assert skipped == 11`, `assert waiters == 12`, each with a message naming what
a smaller number would mean. None of them is behind an environment variable.

## 3. The two-racer results

Ten rounds each, fresh tenant per round, both racers behind the rendezvous.

| Test | Rounds | Assertion that carries it |
|---|---|---|
| `I16 a cancel racing an apply yields exactly one terminal state` | 10 | per round: the audit row is `applied` xor `cancelled`; the subscription's `plan_id` is `"scale"` for `applied` and `"pro"` for `cancelled`; the mirror agrees with the audit row; and **exactly one racer reports a win**, summed to `10` over the ten rounds. A loser is `{:ok, %{applied: 0, skipped: 1}}` or `{:error, {:conflict, %{state: "applied"}}}` and nothing else matches |
| `I16 a provider sync racing an apply yields one terminal state and one plan` | 10 | per round: one terminal state, mirror agrees, and a `cancelled` one carries `provider_override` with `plan_id = "payg"` on the row |
| `I16 two Oban jobs from two nodes apply one transition` | 1, 2 connections | one `{:ok, %{applied: 1}}`, one `{:ok, %{applied: 0, skipped: 1}}` |

The two-racer tests do not read `pg_stat_activity`: with two processes the
"exactly one winner" count is itself the contended-branch assertion, and it is
exact rather than probabilistic because the loser's predicate cannot both fail
and have been the winner.

## 4. The kills

`AuroraMeter.Test.Kill.run/2` with `AuroraMeter.Test.FaultRepo` configured, so
the fault fires inside a production transaction with no production code edited.
Each test asserts the fault **fired** (`Faults.assert_fired!/1`); a test that
arms a fault, drifts off the call path and passes is indistinguishable from a
proof.

| Test | Where the kill is injected | Before | After | Convergence |
|---|---|---|---|---|
| `I16 the applier killed before commit leaves the transition pending` | `:before_commit`, predicated on `statement: :subscription_upsert, repo_fun: :update_all`, which is the conditional update itself | subscription `pro`, transition `pending` | subscription **`pro`**, mirror **`pending`**, audit row **`pending`** | the next `apply_due_transitions/1` returns `%{applied: 1}` |
| `I16 the applier killed after commit and before cache invalidation converges` | `:after_commit_before_ack`, which `FaultRepo.transaction/1` fires only when the **outermost** transaction has committed | cache warm on `pro`, row `pro` | database **correct** (`scale`, audit row `applied`); this node's cache still serving **`pro`** | **5000 ms** from the warming read, **4995 ms** from the kill, against `subscription_cache_ttl` of **5000 ms** |
| `I16 the applier killed mid-batch leaves the applied tenants applied and the rest pending` | `:after_commit_before_ack` with a `:when` predicate counting to 2, so the kill lands after the **second** tenant's commit | four tenants, all `pending` | **2 applied, 2 pending**, asserted as an exact split with the states printed on failure | the next run applies **exactly 2** and skips **0** |

The measurement for criterion 4 is taken at the **default** TTL, not a shortened
one, which is why that test takes five seconds. Printed verbatim:

```
[07b] cache staleness after a kill: ttl=5000ms window_from_warm=5000ms window_from_kill=4995ms
```

## 5. Negative controls

Sixteen. Each breaks exactly one thing in `lib/`, runs the four files this unit
adds at seed 0, and is restored. Harness: `tmp/v1/07b-controls.py` and
`07b-controls.sh`; per-control logs in `07b-logs/controls/`.

| Control | What it breaks | Verdict | The assertion that caught it |
|---|---|---|---|
| `a-apply-unconditional` | the applier's `transition_ref = $ref AND transition_state = 'pending'` predicate | **discriminated** (82/83) | `I17 the applier refuses a row whose mirror says applied and whose audit row says pending`, **and only that one**. See finding X295 |
| `b-mark-applied-unconditional` | the audit row update's `state = 'pending'` predicate | **PASSED** | nothing. Finding **X297** |
| `c-ref-not-idempotent` | the canonical comparison is inverted | discriminated (80/83) | the two idempotency tests and the twelve-way schedule |
| `d-apply-before-boundary` | the due comparison is inverted | discriminated (61/83) | 22 tests |
| `e-effective-at-is-apply-time` | `plan_effective_at` becomes `clock_timestamp()` at both sites | discriminated (80/83) | `I17 an applied transition changes plan_id, plan_version, fingerprint and effective time`, the early-apply test and the confirm test |
| `f-no-provider-override` | the override comparison is inverted | discriminated (79/83) | four precedence tests |
| `g-no-provider-early-apply` | the scheduled-target comparison is inverted | discriminated (78/83) | five precedence tests |
| `h-no-cancellation-precedence` | the non-entitled branch removed | discriminated (80/83) | three precedence tests |
| `i-invalidate-before-commit` | the cache is invalidated **inside** the transaction | discriminated (82/83) | `I16 the applier killed after commit and before cache invalidation converges` |
| `j-node-stamped-effective-at` | X288 reverted: the node stamps `plan_effective_at` | discriminated (82/83) | `X288 subscribe stamps plan_effective_at from the database, not from this node` |
| `k-no-row-lock` | the applier's `FOR UPDATE` removed | **PASSED** | nothing. Finding **X295** |
| `l-replace-does-not-cancel` | `replace: true` stops cancelling | discriminated (82/83) | `I17 a second ref with replace: true ...` |
| `m-preview-writes` | the preview schedules the transition it describes | discriminated (82/83) | `I17 preview_transition returns the old and new entitlements without writing anything` |
| `n-no-reaction-at-all` | `put_subscription/1`'s pre-read removed, so no reaction can happen | discriminated (76/83) | seven precedence tests, including the "opens no transaction" one, which inverts in the other direction |
| `o-cursor-never-advances` | the keyset cursor is the page's **first** row | discriminated (82/83) | `I17 the due scan's keyset pages partition the pending set with no repeat and no gap`, which was **added after this control passed the first time**. Finding X298 |
| `p-no-lock-and-no-predicate` | both `a` and `k` at once | discriminated (78/83) | four concurrency tests plus the stale-writer one |

### The two that passed, and what was done about each

**`k-no-row-lock`.** Removing `FOR UPDATE` from `apply_locked/2` changed nothing
the suite can see, because the conditional `UPDATE` takes a row lock of its own
and Postgres re-evaluates its `WHERE` after that lock clears: eleven of twelve
appliers still see `transition_state = 'applied'` and count a skip. The
explicit lock and the predicate are **each redundant given the other**, which is
what control `p` measures: with **both** removed, four concurrency tests and the
stale-writer test fail. The rule from `open-findings.md` X242 applied twice, as
it asks: the first run tells you the assertion you believed is not load bearing
alone, and the second tells you what is. Recorded as **X295**; the explicit lock
is kept, because a correctness argument that rests on EvalPlanQual is one a
future edit will break silently.

**`b-mark-applied-unconditional`.** The audit row's `state = 'pending'` clause
is unreachable as a discriminator: `mark_applied/1` runs only after the
subscription update returned one row, which itself requires the mirror to say
`pending` for that reference, and `apply_transition/2` has already re-read the
audit row as `pending` under the same lock. There is no external state that
reaches it with a non-pending row, so no test can exist for it. Its value is
that an impossible state becomes a loud `MatchError` rather than a silent
second write. Recorded as **X297** and kept.

### Two ways a control silently does not run, both met here

Five controls first reported "discriminated" on an exit code that was a
**compile failure**, not a test failure: `mix test` in this repository compiles
with `--warnings-as-errors`, so a control that orphans a private function is an
error, and Elixir's type checker refuses an always-false clause in a `cond`. One
control's patch did not apply at all (two matches where one was expected); the
tree stayed intact, the suite stayed green, and the harness reported exactly
what a non-discriminating control reports.

Both were found by reading the per-control logs rather than the exit codes. The
harness now writes one log per control, treats a failed apply as a harness error
and says so, and prints `(no Result line: the run did not reach the suite)` when
there is no `Result:` line to quote. Recorded as **X300**.
