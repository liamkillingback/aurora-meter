# 05d: retention controls (core)

Tasks **05.06** (only prune explicitly disposable audit and operational records;
never expire dedupe receipts, grants, event facts or unresolved operations
because they are old; expose retention dry-run counts) and **03.09** (default
financial events, correction references and dedupe receipts to retained
indefinitely; raw audit-log pruning must not delete billing events; publish
storage sizing and archive guidance; no automatic pruning that reopens
idempotency holes). Invariants **I01**, **I06/I07/I09**, **I10**, **I15** and
**I19** are contributed to; **I16** gains the retention worker's rows, which
`open-findings.md` X215 left open.

## Provenance

| | |
|---|---|
| Core SHA at the start of the unit | `0b3df43d7e6e425177f2f926df98a8aeb004d512` |
| Pro SHA at the start of the unit | `f08561bf19d7449523e934e8a0926b6a8dc575d3` |
| Storefront SHA | `c916b9b131382534898f141e35bac000c898ebb4` |
| Core schema version | 8 (`AuroraMeter.Migration.latest_version/0`); **no DDL added by this unit** |
| Pro schema version | 10; **no DDL added by this unit** |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1) |
| Postgres | 16 on port 5490 |
| Oban resolved in core | 2.24.1 |
| Date | 2026-09-15 |

## Commands, with exit codes and seeds

Every command went through `tmp/v1/mixlane.sh core`, which sets `DB_PORT=5490`
and serialises `_build`.

| Command | Exit | Note |
|---|---|---|
| `mix compile --warnings-as-errors` | 0 | |
| `mix format <the 14 files this unit touched>` | 0 | Only changed files, never project wide |
| `mix test test/aurora_meter/retention_test.exs` | 0 | 32 passed (4 doctests, 28 tests) |
| `mix test test/aurora_meter/retention_controls_test.exs` | 0 | 5 passed |
| `AURORA_RACE_REPORT=1 mix test test/aurora_meter/retention_controls_test.exs --seed 1` | 0 | the race distribution below |
| `mix test test/aurora_meter/flusher_test.exs` | 0 | 10 passed |
| `mix check` | **0** | **1399 passed** (57 doctests, 12 properties, 1330 tests), 4 excluded; Dialyzer `Total errors: 0`; `mix docs --warnings-as-errors` clean |
| `bash tmp/v1/05d-core-headless.sh` | 0 | `headless ok`, then **1311 passed** (53 doctests, 12 properties, 1246 tests) at seed 0 |
| `mix run priv/v1/receipt_sizing.exs` | 0 | `05d-sizing.md` |

`mix check`'s log is `05d-core-check.log`. For core the proving command is
`mix check` and not `mix test` (X139, X156): it stops at its first failing step,
so a formatting failure would mean nothing after it ran.

## What was built

### `AuroraMeter.Retention` (new, `lib/aurora_meter/retention.ex`)

`plan/1`, `prune/1`, `status/1`, `forget_node/2`, `tables/0`, `protected/0`,
`operation/1`, `node_id/0`. `plan/1` and `prune/1` return `{:ok, report}` or
`{:blocked, report, reasons}`; `report` is `%{table_key => count}`.

**The allow list, as implemented.**

| Key | Table | Age predicate | State predicate | Window |
|---|---|---|---|---|
| `:flush_receipts` | `aurora_meter_flush_receipts` | `inserted_at < cutoff` | every `"flush:%"` heartbeat proves no node holds an older batch | `flush_receipt_retention`, 30 days |
| `:replay_checkpoints` | `aurora_meter_checkpoints` | `updated_at < cutoff` | `name LIKE 'events_replay:%'` **and** `state IN ('activated','abandoned')` **and** the generation is not one the live `events_projection` row names | `replay_checkpoint_retention`, 365 days |

**The protected list, as implemented**: `aurora_meter_checkpoints`,
`aurora_meter_counters`, `aurora_meter_credit_balances`,
`aurora_meter_credit_transactions`, `aurora_meter_event_totals`,
`aurora_meter_events`, `aurora_meter_history`, `aurora_meter_subscriptions`.

`aurora_meter_checkpoints` is on both lists and is the only table that is: the
allow list reaches exactly the finished replay rows, and every other row in it is
a live cursor or an operator's pause.

**New configuration**: `:flush_receipt_retention` (30 days),
`:replay_checkpoint_retention` (365 days), `:flush_node_id` (string or `nil`,
`nil` meaning `to_string(node())`). The two windows are validated by
`AuroraMeter.Config.retention_days/2` and a value below **one day** is refused at
boot. `AuroraMeter.Retention.node_id/0` resolves the third, because
`AuroraMeter.Config`'s B03 rule is that an accessor returns the schema default
and `node()` is not a value a compile-time schema can hold.

**New telemetry**: `[:aurora_meter, :retention, :prune]`, measurements
`%{deleted, duration}`, metadata `%{table, blocked}`.

### The flush heartbeat

`AuroraMeter.Store.snapshot_flush_batch/0` stamps `snapshot_at` with
`Clock.now/0` (there is no database in that function and there must not be one,
which the code says at the line). `AuroraMeter.Flusher` writes
`"flush:<node id>"` into `aurora_meter_checkpoints`:

* `state: "idle"` after `persist/1` clears the pending ETS entry, never before;
* `state: "pending"`, `cursor["pending_since"]` and `cursor["batch_id"]` after a
  failure, best effort;
* `state: "idle"` on an idle tick, at most once per 60 seconds (the throttle is
  `Clock.monotonic_ms/0`, an in-memory span).

Every heartbeat carries `cursor["version"]`, the node's package version, which
`architecture-map.md` section 6 requires so a mixed-fleet check is mechanical.
`status/0` reports the distinct versions and `plan/1` logs a warning when there
is more than one, and when the fleet files everything under `nonode@nohost`.

A heartbeat write can never fail a flush: `record_flush_state/2` catches
everything, and the Flusher logs the first failure at `:warning` and later ones
at `:debug`.

### `AuroraMeter.Oban.Retention` (new)

A thin `perform/1` around `AuroraMeter.Retention.prune/1`, `max_attempts: 3`,
`unique: [period: 3600, states: incomplete]`, args `only`, `batch_size`,
`max_items`, schedule `"40 3 * * *"`, added to `AuroraMeter.Oban.__registry__/0`
and therefore to `cron_entries/1`, `validate!/1`, the installer and the scheduler
map. `map_result/1` never hard-matches (L05a-1).

### Documentation

`docs/retention.md` (new, in `mix.exs` extras), the retention row in
`docs/operations/scheduler.md` and in the operations list above it,
`docs/api.md` section 1.14 plus the three configuration keys and the two
telemetry events, the I01 and I16 test lists in `docs/correctness.md`, and the
`CHANGELOG.md` entry.

## The heartbeat against the cutoff: the decision, and the arithmetic

`AuroraMeter.Checkpoints`' moduledoc says the heartbeat is not a lease and that
**nothing in this package subtracts it from anything**, citing X100. This unit
subtracts it from something. The orchestrator asked for the arithmetic rather
than an assertion, so here it is.

**The decision is (1): the moduledoc's rule is about exclusion at seconds scale,
and retention is a comparison at a scale of days.** The rule's own justification
is the durations rule in `architecture-map.md` section 3, which states the
distinction explicitly: unsafe at seconds, safe at minutes and hours. The
moduledoc has been given a sentence saying so, and `AuroraMeter.Retention`'s
moduledoc carries the full argument at the call site.

### The three comparisons, and the clock on each side

| Comparison | Left, and who stamps it | Right | Clocks |
|---|---|---|---|
| receipt age | `flush_receipts.inserted_at`, the flushing **node**'s wall clock | `clock_timestamp() - 30 days`, in the statement | two |
| heartbeat staleness | `checkpoints.updated_at`, the **database** (`clock_timestamp()` in `Checkpoints`' upsert) | the same expression, selected in the same statement | **one** |
| pending batch age | `cursor->>'pending_since'`, the holding **node**'s wall clock | the same expression | two |

Every cutoff is computed **by the database, inside the statement that uses it**,
through a materialised `bound` CTE. Nothing is read into Elixir and written back,
which is the stronger form `architecture-map.md` section 3 asks for and is why
neither `retention.ex` reads `AuroraMeter.Clock.db_now/0` at all. Neither
package's clock-audit allow list needed widening.

### The measured numbers

| Source | Measurement |
|---|---|
| X100 | `clock_timestamp()` stepped backwards **9 times in 300 s, worst 439 ms**, on a 32.5 s cadence |
| X59 | `System.system_time/1` stepped backwards **6 times, worst 2.6472 s**; `DateTime.utc_now/0` **13 times in 420 s, worst 1.3309 s** |
| This unit's own run | `[clock control] 150s, 24 loaders, 119,646,818 samples: Clock.now/0 backwards=2 worst=1.569817s; DateTime.utc_now/0 backwards=4 worst=0.804974s` (core's standing soak, in this unit's `mix check`) |

### The arithmetic

The smallest cutoff the configuration accepts is **one day = 86,400 s**, refused
below that at boot.

* **Single-clock comparison (heartbeat staleness).** The error is the shared
  clock's own backwards step, worst measured 0.439 s. Ratio at the floor:
  86,400 / 0.439 = **196,810 : 1**. At the 30 day default: 2,592,000 / 0.439 =
  **5,904,328 : 1**. Five to six orders of magnitude.
* **Two-clock comparisons (receipt age, pending batch age).** The error is not a
  backwards step but the **offset** between a node's wall clock and the
  database's, plus a step on either side (worst measured combined:
  0.439 + 2.647 = 3.086 s, ratio at the floor 86,400 / 3.086 = **28,000 : 1**).
  The offset is the term that is not measured here, so it is stated as an
  assumption rather than a measurement: **the argument holds for any node to
  database clock disagreement below the whole window**, which at the floor is a
  full day. A fleet whose clocks disagree by a day has already stopped being able
  to record a durable event (`events_future_tolerance` refuses one 300 s ahead)
  or to accept a Stripe webhook (the signature tolerance is the same 300 s), so
  one day is **288 times** the largest disagreement anything else in this system
  tolerates.

### What a wrong answer would actually cost

The dangerous direction is a receipt deleted while a node could still retry its
batch. For that, a node's heartbeat has to be read as "idle and current" when it
is not. The row would have to sit within 439 ms of a cutoff a day or more wide,
and the node it belongs to was reporting **idle** at that instant, so any batch
it holds was taken after that instant and its receipt is within 439 ms of the
cutoff too. The exposure is one receipt, at the boundary, for a node that was
idle at the boundary.

### The floor has a test, and the test has a control

The whole argument above assumes a window below one day cannot be configured. At
the 05d review that assumption had correct wiring and **nothing asserting it**
(X225): a later unit replacing `type: {:custom, __MODULE__, :retention_days,
[...]}` with a plain type would have removed the floor with every test still
green, and the first thing anyone would have learned is a deletion that cannot be
undone. That is X153's shape.

`AuroraMeter.ConfigStrictnessTest / "the retention floor"`, five tests, and
`AuroraMeter.Pro.ConfigTest / "the retention floor"`, five more:

| Test | |
|---|---|
| `every key whose name says it is a retention window is found` | the enumeration cannot pass vacuously: core asserts at least 2 keys and names both, Pro at least 5 and names all five |
| `a window below one day is refused at boot, and the message names the key and the floor` | `0`, `-1` and `-365`, for **every** retention key, through `AuroraMeter.Config.validate!/0` and `AuroraMeter.Pro.validate!/0`. Three assertions on the message: it names the key, it names `floor is 1 day`, and it names the value given |
| `exactly one day is accepted, so the boundary is pinned on both sides` | `1` validates and the accessor returns `1` |
| `a window below one day is refused in transition mode too` | a floor a transition release waived would be absent on every host that upgrades |
| `a value that is not a number of days at all is refused` | `"30"`, `30.0`, `:thirty`, `nil` |

**The keys are enumerated by name** (`~r/_retention(_days)?$/` over
`Config.schema().schema` and `Schema.keys()`), deliberately **not** by looking
for the custom type. Enumerating by type would make the test disappear the moment
the type was replaced, which is the exact regression worth catching; enumerating
by name means the key stays in the list, the below-floor value is then accepted,
and the test fails naming it. A retention key added by a later unit that follows
the naming convention is covered without an edit.

**It goes through the real boot entry point**, `Config.validate!/0` and
`AuroraMeter.Pro.validate!/0`, not through `retention_days/2`. Calling the
validator directly would pass even if the schema entry had stopped referencing
it.

#### The control

One schema entry's type swapped away from the custom validator, everything else
unchanged, the new test run, then restored and the restore verified by hash.
`tmp/v1/` is not where this lived: it is a three-line edit and a `sha256`, and
both files came back byte identical.

| Package, key | Swap | Result |
|---|---|---|
| core `:flush_receipt_retention` | `:pos_integer` | **1 of 29 fails.** `the refusal of :flush_receipt_retention does not name the floor: invalid value for :flush_receipt_retention option: expected positive integer, got: 0` |
| core `:flush_receipt_retention` | `:non_neg_integer` | **2 of 29 fail**, including the raise itself: `0` is accepted |
| Pro `:outbox_retention_days` | `:pos_integer` | **1 of 32 fails.** `the refusal of :outbox_retention_days does not name the floor: invalid value for :outbox_retention_days option: expected positive integer, got: 0` |
| Pro `:outbox_retention_days` | `:non_neg_integer` | **2 of 32 fail**, same two |

Restores: core `config.ex` sha256
`e1a5df580c57852c50ab9a1d293ce4c0a78185ff02db24fc77bbcb6c9481c7f8` before and
after; Pro `config/schema.ex` sha256
`f7f38ed925fdd30ffd239c0dafcd3913ea8e710542d57238f760f1ba839e0ac0` before and
after.

**The `:pos_integer` arm is the interesting one, and it is why the message had to
be asserted rather than the raise.** NimbleOptions' positive integer is `>= 1`,
so that swap **keeps the numeric floor by accident**: `0` and `-1` are still
refused and a test that only checked that something raised would have passed
while the custom validator was gone. What it loses is the message an operator
acts on, which is the assertion that caught it. The `:non_neg_integer` arm is the
swap that loses the floor outright, and it fails on the raise. Both arms
discriminate, for different reasons, and neither would have been caught by a test
that asserted only `assert_raise`.

### Why the floor is a floor and not advice

The orchestrator's point stands: at one minute the ratio is 86,400/60 = 1,440
times smaller, so 60 / 3.086 = **19 : 1**, and at one second the argument is
gone. The value is therefore refused at boot, where an operator can read the
message, rather than allowed and warned about. `:older_than` and
`:older_than_days` are one-off operator overrides and are deliberately not
floored, because an operator passing an explicit instant is making the decision
themselves; `plan/1` is there to show them what it means first.

## A node that never comes back

Default: **it blocks.** A `"pending"` heartbeat older than the cutoff, or an
`"idle"` one that has gone stale, refuses the prune with
`reason: :node_liveness_unknown` and a detail naming the node, its state, its
`updated_at`, its `pending_since`, its `batch_id` and its version.

Three refusals are stricter than the build document asked for, and each closes a
hole the document left to documentation:

1. **No heartbeat rows at all** blocks with `reason: :no_heartbeats` when there
   is a receipt older than the cutoff. That is exactly what a fleet running the
   previous release looks like, and the build document's mitigation was "the
   installer adds the schedule after the deploy, and `docs/retention.md` states
   the order". An ordering documented is an ordering somebody gets wrong; this
   is the same rule enforced. An installation with nothing eligible is not
   blocked, so a fresh database is not reported as a problem.
2. **A missing `aurora_meter_checkpoints` table** blocks with
   `reason: :checkpoints_unavailable`. That is a database below core schema
   version 7, which has receipts and cannot have heartbeats.
3. **An unreadable `pending_since`**, and **any heartbeat state this release does
   not write**, block. The vocabulary can grow; the default must be to keep the
   receipts.

The override is `forget_node/1`, one named node at a time. It returns
`{:error, :not_found}` rather than `:ok` for a node it has never heard of, so a
typo cannot look like success; it logs at `:warning` with the whole row it
removed and with the consequence spelled out; and `docs/retention.md` states the
precondition in plain words in a warning admonition. There is no `force:` option
and no way to disable the rule.

## Tables, classified

Every table each package's migrations create is in exactly one list, asserted in
**both directions** (X206) by
`RetentionTest / "the allow list and the protected list together name every table the package creates"`,
which parses `create_if_not_exists table(...)` out of the migration sources
rather than reading a list written in the test.

### Core, all nine

| Table | Classification | Why |
|---|---|---|
| `aurora_meter_events` | protected | the durable fact table (I06, I07) |
| `aurora_meter_event_totals` | protected | its projection |
| `aurora_meter_counters` | protected | the buffered usage Pro bills from |
| `aurora_meter_history` | protected | the day buckets `history/3` reads |
| `aurora_meter_subscriptions` | protected | the tenant's plan |
| `aurora_meter_credit_balances` | protected | the ledger (I10) |
| `aurora_meter_credit_transactions` | protected | the ledger (I10) |
| `aurora_meter_checkpoints` | **both** | allow-listed for finished replay rows only; every other row is a live cursor or a pause |
| `aurora_meter_flush_receipts` | **allow list** | behind the receipt rule |

06a's `aurora_meter_credit_lots`, `_credit_allocations` and `_credit_recurrences`
and 07a's `_plan_versions` and `_plan_transitions` do not exist yet. When they
land, this test fails until they are classified, which is the intended mechanism
and is one line of change in each of those units.

### Pro, all ten

See `pro:docs/evidence/v1/phase-05/05d-pro-retention.md` for the table.
`aurora_meter_source_cutovers`, which no planning document classified in a
retention context, is **protected**, and the reason is in
`AuroraMeter.Pro.Retention`'s moduledoc: it is one row per feature for ever, it
does not grow with traffic, and both the reporter and the reconciler read it to
decide which source a past period is billed from, so deleting one would change
the commercial answer for every period after it.

## `plan/1` and `prune/1` share one query

Each allow-list entry carries **one** `predicate` string. `count_sql/2` wraps it
in `SELECT count(*) ... WHERE <predicate>` and `delete_sql/2` in
`DELETE ... WHERE id IN (SELECT id ... WHERE <predicate> ORDER BY ... LIMIT $2)`.
Both prepend the same `bound` CTE with the same parameters.

That is asserted structurally as well as behaviourally, so the two cannot drift
without a test failing:

```
RetentionTest / "plan/1 and prune/1 are generated from one predicate"
  for every entry: count_sql contains entry.predicate
                   delete_sql contains entry.predicate
                   count_params == delete_params
                   count_sql contains "count(*)" and does not contain "DELETE"
```

and behaviourally by
`"plan/1 returns exactly the counts prune/1 then deletes"`, which runs `plan/1`,
`prune/1` and `plan/1` again on a database holding a mix of eligible and
ineligible rows in both tables: `%{flush_receipts: 7, replay_checkpoints: 2}`,
then the same from the prune, then zeros, with the four ineligible receipts
still present.

## `plan/1` writes nothing, proved by row counts

`"plan/1 writes nothing"` populates all seven protected schemas plus three
receipts and a heartbeat, runs `plan/1`, and asserts the row count of every one
of them is unchanged and that the heartbeat table still holds exactly one row.
It is not "it returned a map".

## The run budget is visible

A run that hits `:max_items` with rows still eligible returns
`{:blocked, report, [%{reason: :budget_exhausted, detail: %{deleted, max_items,
batch_size}}]}` rather than an `{:ok, ...}` that looks complete. This is not in
the build document. It is here because the alternative is a table that grows
faster than one nightly run removes and says nothing about it for months, which
is the failure mode a silent partial prune has.

## What is not proved, and why

* **I19** (pruning a populated upgrade fixture leaves per-tenant reconciliation
  unchanged) is **not proved here.** 11a's `core6_pro9` fixture does not exist
  yet: phase 11 is `PLANNED` and nothing in either repository builds it. What is
  proved instead is the property that fixture would check, directly:
  `prune(older_than: now)` against a database holding a row in every protected
  table leaves every one of those row counts unchanged, in both packages. 11a
  should re-run its own version against the real fixture.
* **A real multi-node fleet.** The receipt rule is exercised with heartbeat rows
  written directly, not with two BEAM nodes each running a Flusher. The rule
  reads rows, and the rows are what the Flusher writes (proved separately in
  `flusher_test.exs`), so the seam is covered from both sides, but nobody has yet
  watched two real nodes disagree. 11d's soak is where that belongs.
* **The sequential scan at production scale.** Measured at one million rows
  (`05d-sizing.md`). A host with a hundred million has not been measured.
* **A clock actually skewed by more than the window.** The two-clock argument
  rests on a stated bound, not on an experiment that moved a node's clock a day.
  Recorded as finding X219.
* **That a host cannot defeat the floor another way.** The floor is enforced on
  the configuration keys. `:older_than` and `:older_than_days` are deliberately
  not floored, because an operator passing an explicit cutoff is making that
  decision themselves, and a job argument below a day still reaches
  `prune/1`. What stops that being a hole is that it is a per-call override with
  no persistence, not that anything refuses it.
