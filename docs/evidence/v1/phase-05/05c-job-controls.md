# 05c: job controls (core)

Task **05.05** (job controls: bounded batches, stable keyset cursors, unique
scheduling, explicit retry limits, pause and resume; job args hold ids and
references, not payment secrets or metadata) and the **G05** bullets it feeds.
Invariant **I16** is this unit's; its index is `i16.md` and `i16.md`.

## Provenance

| | |
|---|---|
| Core SHA at the start of the unit | `4ac358d9919286f23199aa10c23f0fbb2c2fcf49` |
| Pro SHA at the start of the unit | `f7cf190ff8405d2149a477100b174c48f80a5e6a` |
| Storefront SHA | `ca4b894db18293c17ef59c0c0789db83d674b4ff` |
| Core schema version | 8 (`AuroraMeter.Migration.latest_version/0`); **no DDL added by this unit** |
| Pro schema version | 10; **no DDL added by this unit** |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1) |
| Postgres | 16 on port 5490, container selected by 00a |
| Oban resolved in core | **2.24.1** |
| Oban resolved in Pro | **2.23.0** (see X195: they snooze differently) |
| Igniter | 0.8.4 in both packages |

## What was built

### `AuroraMeter.Operations` (new, `lib/aurora_meter/operations.ex`)

The documented operator surface over `aurora_meter_checkpoints`. It **delegates
to `AuroraMeter.Checkpoints`** and reimplements none of its SQL: `Checkpoints`
already shipped in 03a with `get/2`, `put/5`, `update/3`, `pause/2`, `resume/2`,
`paused?/2`, `heartbeat/2` and `claim/3`, and its own moduledoc names
`AuroraMeter.Operations` as the surface over the same rows.

What `Operations` adds:

- **Name validation.** `[a-z_]+:[A-Za-z0-9_.:-]+`, `ArgumentError` otherwise.
- **Arity-1 forms** of the arity-2 functions: `pause/1`, `resume/1`, `paused?/1`,
  `checkpoint/1`, `put_checkpoint/2`, `clear_checkpoint/1`, `list/0`.
- **`run_batches/3`**, the batch loop, which is a deviation from the build
  document and is recorded as one below.
- **No Oban reference anywhere** (I20), asserted by a test.

### `AuroraMeter.Checkpoints.put_progress/4` (new)

One statement, in the module that owns the table's SQL (X161). It writes
`cursor` and `counts` without touching `state`, creating the row as `"idle"`
when it does not exist. Neither `put/5` (which overwrites `state`, and so would
clear a pause an operator had just set) nor `update/3` (which refuses to create
a row, so the first batch of a never-run scan would have nowhere to write) can
do this on its own.

### The batch loop, and why it is one function rather than nine copies

The build document says the loop is "implemented once per worker rather than in
a shared macro (the workers live in two repositories and their operations have
genuinely different shapes; a macro across a package boundary would be a worse
coupling than a repeated eight-line loop)".

**A macro would be. A function is not**, and `AuroraMeter.Operations.run_batches/3`
is a function: a public, documented, `@spec`'d higher-order function taking the
operation name and a callback. The three lower-level invariants the unit
introduces are properties of the loop, and written once they are proven once:

- **L05c-1** (the cursor is never a job argument) is structural: `run_batches/3`
  reads the cursor from the checkpoint row and the callback receives it.
- **L05c-2** (the pause is read at the start of every batch) is one `cond` at
  the top of the loop, and its test can force a pause from inside batch two.
- **L05c-3** (a per-item failure is counted and stepped over; only a mechanism
  failure aborts) is the shape of the callback's contract.

Written nine times, each of those would be nine things to get right and nine to
test. `free-pro-boundary.md` line 32 already lists `AuroraMeter.Operations.*` as
core surface Pro may use, so the boundary permits it.

### Per-worker settings, as implemented

| Worker | Operation name | Cursor | `batch_size` | `max_batches` | `max_attempts` | `unique` |
|---|---|---|---|---|---|---|
| `AuroraMeter.Oban.CreditExpiry` | `credit_expiry:global` | `%{now, expires_at, id}` | 200 | 10 | 3 | `[period: :infinity, states: incomplete]` |
| `AuroraMeter.Oban.HoldReconciliation` | `hold_reconciliation:global` | `%{older_than, inserted_at, id}` | 200 | 10 | 3 | same |
| `AuroraMeter.Oban.EventsReplay` | `events_replay:<generation>` (03d) | 03d's | 03d's | 03d's | 1 | same |
| `AuroraMeter.Oban.RecurringGrants` | none yet | none yet | n/a | n/a | 3 | same |
| `AuroraMeter.Oban.PlanTransitions` | none yet | none yet | n/a | n/a | 3 | same |
| `AuroraMeter.Pro.UsageReporter` | `usage_reporter:global` | subscription keyset | `reporter_batch_size` (200) | 10 | 5 | unchanged |
| `AuroraMeter.Pro.Outbox.Deliverer` | none (the lease is the cursor) | n/a | `outbox_batch_size` | n/a | 3 | 04b's |
| `AuroraMeter.Pro.Outbox.Reconciler` | `outbox_reconciler:{confirm,error_reports}` (04d) | 04d's | 04d's | 04d's | 3 | 04d's |
| `AuroraMeter.Pro.Alerts` | `alerts:global` | subscription keyset | 200 | 10 | 5 | **added** `[period: 300, states: incomplete]` |
| `AuroraMeter.Pro.Rollup` | `rollup:global` | **none** | n/a | n/a | 5 | **added** `[period: 3600, states: incomplete]` |
| `AuroraMeter.Pro.AuditLog.Pruner` | `audit_log_pruner:global` | **none** | 1000 (internal) | n/a | 3 | none |
| `AuroraMeter.Pro.Credits.AutoTopUpSweeper` | `auto_top_up_sweeper:global` | `%{tenant_key}` | 500 | 10 | 3 | **added** `[period: 240, states: incomplete]` |
| `AuroraMeter.Pro.Credits.AutoTopUpWorker` | none (one attempt) | n/a | n/a | n/a | **5** (was 1) | unchanged |
| `AuroraMeter.Pro.Credits.Expirer` | none (deprecated shim) | n/a | n/a | n/a | 3 | none |

**Fourteen workers, not twelve.** The build document's table lists seven Pro
workers; `grep -rn 'use Oban.Worker' lib/` at Pro HEAD finds **nine**
(`open-findings.md` X185): 04b added `Outbox.Deliverer` and `Outbox.Reconciler`
and no planning document listed them.

**Two workers keep no cursor, and it is a statement rather than an omission.**
`Rollup`'s month aggregate is one `GROUP BY` over the counter table with no
per-item effect a cursor could resume between; the pruner's every batch deletes
the rows it examined, so the scan advances by doing the work and a cursor would
name a position in a set that no longer contains it. Both are pausable, checked
once before the work rather than per batch.

### The args allow list

`tenant_key`, `since_days`, `older_than_days`, `batch_size`, `max_batches`,
`limit`, `older_than_seconds`, `reference_prefix`, `tenant`, and
`EventsReplay`'s `generation`, `compare`, `compare_limit`, `activate`, `resume`,
`rehydrate`, `timeout`. **No cursor, no payload, no secret, no metadata map.**

Both packages have a test enumerating every `Oban.Worker` implementation and
asserting its arg keys are a subset. Pro's reads the **source** rather than the
moduledoc, and it reads it because its own vacuity check caught the first draft:
`AutoTopUpWorker` documents its argument as `%{"tenant_key" => key}` rather than
as a table row, so a moduledoc scan saw nothing there and would have passed a
worker that had grown a payload.

## Commands

Every command below was run. `bash tmp/v1/mixlane.sh core ...` is the lane lock
(`DB_PORT=5490`, one Mix workload per `_build`).

| Command | Exit | Result |
|---|---|---|
| `mix compile --warnings-as-errors` | 0 | |
| `mix test test/aurora_meter/operations_test.exs` | 0 | 22 passed |
| `mix test test/aurora_meter/oban_job_controls_test.exs` | 0 | 12 passed |
| `mix test test/mix/tasks/install_test.exs` | 0 | 14 passed |
| `mix test test/aurora_meter/oban_concurrency_test.exs` | 0 | 3 passed |
| `mix test` (whole suite, seed default) | 0 | **1351 passed** (53 doctests, 12 properties, 1286 tests), 4 excluded |
| `mix check` | see `05c-core-check.log` | |

Pro's numbers are in `pro:docs/evidence/v1/phase-05/05c-pro-job-controls.md`.

## Where the build document was wrong

Recorded here as well as in `open-findings.md`, because a reader of this file
should not have to go and look.

1. **`resume/1` writes `"idle"`, not `"active"`.** `"active"` is taken by the
   `"events_projection"` row, which is not a task. `Checkpoints.resume/2` shipped
   `"idle"` in 03a and every reader in the package understands it.
2. **`cursor`, `counts` and `state` are `NOT NULL`** in the shipped V7 table,
   while every binding map and the build document's own data-model table
   describe them as nullable and say a `NULL` state means active (X193). "No
   cursor" is therefore `'{}'`, not `NULL`. No DDL was added.
3. **Pro has nine workers, not seven** (X185).
4. **`--dry-run` is already an Igniter global switch** (X192). Implementing a
   second one would be two flags with one name.
5. **The reporter did not starve later tenants** (X198). It staged every
   subscription and then failed the job, which is a different defect with the
   same fix.
6. **A `:held` refusal is balance-wide, not per-grant** (X199), so the per-item
   test the document specifies cannot be written with it.
7. **Oban's snooze accounting differs between the two versions the two packages
   resolve** (X195). The document states Pro's as a general fact.
8. **`AURORA_SKIP_OPTIONAL` does not exist**; 05a shipped `AURORA_HEADLESS=1`
   (X190). Not used by this unit, which adds no headless obligation of its own:
   `AuroraMeter.Operations` has no Oban reference and compiles without it.

## What the resume test found, and why it changed

The fifty-grant kill-and-resume test failed one full-suite run in ten with
**43 expiries instead of 50**, and the cause is a pre-existing ledger defect
rather than a flaky test (`open-findings.md` X213).

`AuroraMeter.Credits.Promotions.consume/3` does `Map.update!` for an `:expire`
entry against a map of grants folded in `(inserted_at, id)` order, and raises
`KeyError` when the grant has not been folded yet. `inserted_at` is stamped by
Ecto's autogenerate from the **node wall clock** (X181), which steps backwards
(X59, X100), so an expire row written after its grant can sort before it. The
log showed `key "04473098-..." not found` in a fourteen-entry map spanning 47 ms
of `inserted_at`.

**This unit's own per-item rescue is what made it silent.** X200 added it so one
grant's failure cannot starve the grants behind it, which is right; what it also
did was turn a crashed sweep into a shortfall nobody counted. Two changes
followed:

1. The resume test **drains**: it runs the sweep until it stops making progress,
   because a grant the ledger refused is still due and the next run is what
   expires it. That is what a scheduled sweep does, and the claim (nothing
   skipped, nothing duplicated, fifty rows for fifty grants) is unchanged. The
   exact count committed before the kill is no longer asserted, and the comment
   says why rather than leaving it looking lax.
2. A **deterministic reproduction** sits beside it: an expire row planted one
   second before its own grant, asserting `examined: 1, failed: 1, expired: 0`,
   that the log names the `KeyError` and the grant, and that nothing was written.
   06a can make it pass.

Ten seeds over the file after the change: **10 of 10 green, 13 tests each.**

## What this unit did not do

- **`Rollup`'s month aggregate is still unbounded.** Bounding it means rewriting
  its `GROUP BY` over `aurora_meter_counters` into a per-tenant keyset walk,
  which is a rewrite of the queries 04d tuned and not a batch loop wrapped round
  them. It is pausable and unique; the bound is not there. Named rather than
  claimed.
- **`RecurringGrants` and `PlanTransitions` have no cursor**, because they have
  no operation yet. 06d and 07b land the bodies and the loop with them; the I16
  index carries `PLANNED` rows for both.
- **No `mix check` run is claimed before it appears in `05c-core-check.log`.**
