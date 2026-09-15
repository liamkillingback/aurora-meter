# 05b: hold recovery callback and race safety

Build unit **05b**, `docs/v1/build-plans/phase-05/05b-hold-recovery-callback.md`.
Tasks **05.03** and **05.04** from `v1-release.md` section 9. Contributes to gate
**G05** bullets 1 and 3, and to invariants **I11**, **I12** and **I16**.

Status: **EVIDENCED**.

## Provenance

| | |
|---|---|
| Repository | `product-workspaces/aurora_meter` (core), branch `aurorameter-v1` |
| HEAD when the work began | `668818bd8538f50b94ed93b13c6a2fe0227b7bb5` |
| Schema version | **unchanged at 8.** No table created or altered, no column, no index. |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1) |
| PostgreSQL | 16.13 (Debian 16.13-1.pgdg13+1), container `aurora-meter-pro-testdb`, port 5490 |
| Date | 2026-09-15, times UTC |
| Commands | `05b-commands.txt` |

Test counts: core **1204 before, 1251 after** (+47), `mix check` exit 0. Pro
**863**, unchanged, `mix check` exit 0 with `priv/plts` deleted first
(`open-findings.md` X114).

## What the build document's "Existing implementation" got wrong

Checked against HEAD before anything was written, per X147.

1. **Every line number in the section is stale.** The document was written
   against `cb38c3c`; `1434084` (02c, the clock seam) has since moved
   `credits.ex` and `ledger.ex`. The L4 defect is at `credits.ex:405`, not `:401`.
   `pending_holds/1` is at `ledger.ex:57`, not `:56-75`. `pending_hold/2` is at
   `:507`, not `:506-518`. The symbols are all correct; only the numbers are not.
   (`open-findings.md` X67, X90, X93, X108, X163 say to cite symbols, and this is
   why.)
2. **Schema version.** The document says "6 plus whatever 03a and 06a have
   landed". It is 8.
3. **The defect this unit must fix (L4) is accurately described and was still
   present.** `git log --oneline -- lib/aurora_meter/credits.ex` shows no commit
   between the document's inspection and this run that touched `run_held/2`.
   Reproduced, see `05b-l4-before-after.md`.
4. **The applying side is accurately described.** `settle/3`, `release/1`,
   `pending_hold/2`, `close_hold!/3`, `transact_outcome/1`'s non-rolling-back
   refusal and the hold-row-then-balance-row lock order are all as the document
   says.
5. **The deciding side was correctly described as absent**, and the four credit
   configuration keys are still four.
6. **One material claim is wrong, and it is the clock claim.** The document says
   `held_at` is the hold row's `inserted_at` and that `age_seconds` is
   `DateTime.diff(Clock.now(), held_at)`, resting on 02c's clock seam. **The
   clock seam does not reach a credit ledger row's `inserted_at` at all.** See
   the finding below.

## Finding: the ledger's `inserted_at` does not come from the configured clock

`AuroraMeter.Credits.Ledger.apply_entry/3` builds its entry with
`inserted_at: Clock.now()`. `AuroraMeter.Schema.CreditTransaction.changeset/2`
casts `@castable`, which does **not** include `inserted_at`, and the schema
declares `timestamps(type: :utc_datetime_usec, updated_at: false)`. Ecto's
autogenerate therefore fills the column and the ledger's value is dropped.

Measured on 2026-09-15 with a throwaway test:

```
Clock.now():             ~U[2026-03-01 00:00:00.000000Z]
hold row inserted_at:    ~U[2026-09-15 05:24:27.875710Z]
days apart:              198
```

The clock was frozen at 2026-03-01 by `AuroraMeter.Test.with_clock/2` and the row
still landed at the real instant.

Three consequences.

* **`AuroraMeter.Test.with_clock/2` cannot control a credit row's timestamp.**
  `AuroraMeter.Test`'s own documentation says "a frozen clock stamps every row
  with the same `inserted_at`, so a test that writes several credit ledger rows
  and then pages `AuroraMeter.Credits.history/2` must `travel/2` between the
  writes", and `docs/testing.md` repeats it. **That claim is false for credit
  rows.** A test relying on it is testing something else.
* **The P07 clock audit cannot see it.** `AuroraMeter.ClockTest`'s audit greps
  `lib/` for `DateTime.utc_now()`, `System.system_time` and the rest. Ecto's
  autogenerate is a library call with none of those spellings in this tree, so a
  column stamped outside the seam passes an audit designed to prevent exactly
  that.
* **`open-findings.md` L20 cites `ledger.ex:452` as the line that "stamps
  `inserted_at` from the host wall clock".** The conclusion is right, the
  mechanism is not: that line is dead. Anything that fixes L20 by changing that
  line will change nothing.

**Not fixed here, deliberately.** The scope forbids changing `apply_entry/3`, the
fix belongs with 06a's move of every credit ordering onto `seq` and its
database-stamping of the ledger, and adding `inserted_at` to `@castable` would
change the timestamp of every ledger row in the suite at once. Recorded for
`open-findings.md` instead.

**What this unit did about it.** `age_seconds` is computed with `Clock.now/0`,
not `Clock.db_now/0`, and the reason is written into
`AuroraMeter.Credits.Reconciliation`'s moduledoc: the other side of the
comparison is a node wall clock, so `now/0` is the nearest thing to the same
clock, and `db_now/0` would put two clocks on the comparison and cost a round
trip for a number that decides nothing. The value is clamped at zero, and the
behaviour's documentation tells a host in plain words not to decide from it. Two
tests cover it: `uses one instant for every age in a run` and `reports an age of
zero rather than a negative one when the clock disagrees`. Both write their hold
rows directly so the instants are the test's, with a comment saying why.

## Durations, and X100

`architecture-map.md` section 3 binds this unit: `db_now/0` gives every node one
clock but not a monotonic one, and at seconds or less a comparison is not safe.

**No duration in this unit decides anything.**

| Duration | Where | What it decides | Bound relied on |
|---|---|---|---|
| `:older_than` | the listing query, `t.inserted_at < ^cutoff` | which holds are **candidates to be asked about**. Never whether one is releasable. | Caller's, at minutes-to-hours scale. Both sides are node wall clocks (see the finding above); a bounded backwards step of a few seconds cannot invert an hour. |
| `age_seconds` | handed to the host callback | nothing. It is a number for a log line and a metric. | Same, and clamped at zero. |
| `credits_hold_reconciler_timeout` | `Task.yield/2` | how long to wait for a callback before killing it and **keeping** the hold | An in-process span measured with `Clock.monotonic_ms/0`, which is strictly monotone within a node. It is not persisted and not compared across nodes. Its failure mode is keeping a hold, which is the safe direction. |

Mutual exclusion takes no clock at all. See `05b-race-proofs.md`.

## Public API added

| Entry | Class |
|---|---|
| `AuroraMeter.Credits.reconcile_holds/1` | additive |
| `AuroraMeter.Credits.HoldReconciler` behaviour, `decide/1` | additive |
| `AuroraMeter.Credits.reconciliation_report/0` type | additive |
| `AuroraMeter.Credits.release/2` (was `/1`, default argument) | additive |
| `AuroraMeter.Credits.settle/3` gains `:tenant` | compat |
| `AuroraMeter.Credits.pending_holds/1` gains `:tenant` and `:after`, orders by `(inserted_at, id)` | compat, bug fix |
| `AuroraMeter.Credits.with_credits/4` no longer raises `MatchError` on a concurrent close | compat, bug fix |
| `AuroraMeter.Config.credits_hold_reconciler/0`, `credits_hold_reconciler_timeout/0` | additive |
| `AuroraMeter.TaskSupervisor` in the supervision tree | additive, internal name |
| `AuroraMeter.Credits.Reconciliation` | internal, `@moduledoc false` |

`api-change-map.md` should gain the `release/1` to `release/2` widening in 1.1,
`reconcile_holds/1`, the behaviour and the Task supervisor in 1.2, the two
configuration keys in 1.5 and the telemetry event in 1.6. The build document's
own addendum says the same.

## Configuration added

| Key | Type | Default |
|---|---|---|
| `credits_hold_reconciler` | `{:or, [:atom, {:fun, 1}, {:tuple, [:atom, :atom]}, nil]}` | `nil` |
| `credits_hold_reconciler_timeout` | `:pos_integer` | `5_000` |

A module or `{module, function}` that cannot be loaded, does not implement
`AuroraMeter.Credits.HoldReconciler`, or does not export the named function at
arity 1, fails `Config.validate!/0` at boot. Seven cases in
`AuroraMeter.ConfigTest`, describe `"credits_hold_reconciler"`.

## Telemetry added

`[:aurora_meter, :credits, :hold_reconciliation]`, one event per hold examined.

* Measurements: `amount` (reserved micro-USD), `age_seconds`, `duration`
  (callback milliseconds, `0` when none ran).
* Metadata: `tenant_key`, `reference`, `decision`, `outcome`.

Documented in `docs/telemetry.md` with the full outcome table and in
`docs/api.md`'s literal inventory, which greps `lib/` for the event name.

## Acceptance criteria

| Criterion | Met | Where |
|---|---|---|
| No reconciler configured: ten stale holds return `examined: 10, kept: 10, released: 0, settled: 0` and the row count is unchanged | yes | `CreditsReconcileHoldsTest` / `keeps every hold when no reconciler is configured, and writes nothing`. Asserts `Config.credits_hold_reconciler() == nil` as well as the behaviour (X171), with the paired control `and the same holds are released once a reconciler is configured`. |
| A callback sleeping three times the timeout leaves every hold pending, completes in about one timeout per hold, and emits one event per hold with `decision: :keep, outcome: :callback_timeout` | yes | `keeps the hold and reports :callback_timeout when it never answers`. A `receive` that cannot match rather than a sleep (`docs/testing.md` rule 2); timeout 60 ms, two holds, elapsed asserted `>= 120` and `< 5_000`, measured 133 ms. |
| A raising callback, an exiting callback, and `:ok` / `{:settle, -1}` / `nil` each leave the hold pending and produce a warning naming the tenant key and the reference | yes | `keeps the hold and reports :callback_exit when it raises`, `... when it exits or throws`, `keeps the hold and reports :callback_invalid for a value that is not a decision` (seven values: `:ok`, `{:settle, -1}`, `{:settle, 1.5}`, `nil`, `{:release, 5}`, `"release"`, `:released`). Log asserted to contain the tenant and the reference. |
| Twelve concurrent pairs of release and settle on twelve holds, each on its own connection, produce twelve closing rows, no hold with both, and `balance - held` equal to the winners' value | yes | `05b-race-proofs.md` proof 1. **With the caveat recorded there**: over ten seeds the caller's settle won all twelve every time, so that test proves the volume property and the two directions are proved separately in proofs 2 and 3. |
| Two simultaneous runs with a `:release` callback over one hold produce one `:release` row, one reporting `released: 1` and the other `already_closed: 1` | yes, with one honest widening | `05b-race-proofs.md` proof 4. The loser is asserted to be `already_closed: 1` **or** `examined: 0`: a run that lists after the winner committed sees nothing, which is equally correct and is not a second row. |
| `with_credits/4` whose hold is settled by another process returns `{:ok, result}`, raises nothing, one `:settle` row | yes | `CreditsTest` / `with_credits/4 I11 returns its result when the hold was settled by someone else` |
| `with_credits/4` whose hold is released by another process returns `{:ok, result}` and leaves one `:debit` row `settle_missed:<reference>` with the actual cost; a rerun adds no second row | yes | `CreditsTest` / `I11 records the executed cost when the hold was released by someone else` and `is idempotent for the settle_missed debit across a retry`; on real connections, `05b-race-proofs.md` proof 3 |
| `settle(reference, n, tenant: <wrong>)` and `release(reference, tenant: <wrong>)` return `{:error, :not_found}` and write no row | yes | `CreditsReconcileHoldsTest` describe `"the tenant guard"`, four tests, each with the paired positive control (the same call with the right tenant succeeds), which is the X125 shape 04f used for 9a/9b |
| `pending_holds(older_than:, tenant: a)` returns only `a`'s holds; three same-microsecond holds paged with `limit: 1` and `:after` return each exactly once | yes | `pending_holds/1 scopes to :tenant` and `orders by (inserted_at, id) and pages without skipping same-microsecond rows`. The three rows are written directly with one identical `inserted_at`, because the clock seam cannot produce that (see the finding above). |
| Killing the reconciler between the callback and the application leaves the hold pending with no ledger row, and a second run applies the decision | yes | `05b-race-proofs.md` proof 6 |
| A hold kept on every run is still pending and reserved after twenty runs, with the available balance unchanged | yes | `a hold kept on every run is still pending and still reserved after twenty runs`: row count unchanged, `held: 400_000`, `available: 600_000` |
| `credits_test.exs` and `credits_concurrency_test.exs` pass unmodified except for description renames | yes, with one addition | `credits_concurrency_test.exs` is **untouched**. `credits_test.exs` is unchanged except for five new tests in the `with_credits/4` block and two private helpers; no existing test was edited. 71 passed. |
| `mix check` exits 0 and its log is in the evidence directory | yes | `05b-core-check.log` |

Two further criteria the document lists under Tests rather than Acceptance:

* `reconcile_holds/1` counts a failing application without stopping the run:
  `counts a failing application without stopping the run` fault-injects a raise
  on the first `:transaction_insert` write through `AuroraMeter.Test.FaultRepo`,
  asserts `examined: 3, released: 2, failed: 1`, that the failed hold is still
  `pending` and that the two behind it were released, and calls
  `Faults.assert_fired!/1`.
* `reconcile_holds/1` raises naming the supervision tree when
  `AuroraMeter.TaskSupervisor` is not running: `raises, naming the supervision
  tree, when AuroraMeter.TaskSupervisor is not running` unregisters the name,
  asserts the message names the supervisor and the host's `children`, and
  re-registers it in an `after`.

## Not done, and why

* **The doc-example compile test the document names does not exist.** The
  document says `docs/credits.md`'s example is "covered by the doc-example
  compile test 02a introduces". There is no such test in core: 02a shipped
  `api_inventory_test.exs` (A01 to A05) and `docs_claims_test.exs`, neither of
  which compiles code blocks in guides. The worked `HoldReconciler` in
  `docs/credits.md` is therefore **not** compiled by anything. Recorded as a
  finding rather than fixed, since writing a doc-example harness is a unit of its
  own.
* `AuroraMeter.Oban.HoldReconciliation` is 05a's. Batching, cursor persistence in
  `aurora_meter_checkpoints` and pause/resume are 05c's. The lock-order change
  and lot reservation are 06a's. The low-balance handler moving into a Task is
  06c's. Pro is untouched.
* The `inserted_at` stamping finding above is left for 06a.
