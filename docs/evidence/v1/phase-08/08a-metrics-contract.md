# 08a: the metrics contract (core)

Build unit **08a**, V1 tasks **08.01** (metric contract) and **08.02**
(cardinality and privacy). The Pro half is
`pro:docs/evidence/v1/phase-08/08a-pro-metrics-contract.md`. The tag rules and
what the tests try are `08a-cardinality.md`; the failure-mode tables are
`08a-runbook-map.md`; the serialised catalogue is `08a-telemetry-events.json`.

## 1. Facts

| | |
|---|---|
| Core SHA at hand-back | `58ae0fbe91e2b73657daf0d86715fbfd8d5b23a6` (`aurorameter-v1`), **dirty**, uncommitted by instruction, 31 files |
| Pro SHA | `78c803a11b7531a512bffda2066a2a070b8c4cd3`, dirty, 16 files |
| Storefront SHA | `5b85f998fb0ef07c1d73831b41440228acf9de9e`, dirty, 3 files |
| Version / schema | 0.5.0 unchanged / **10 unchanged**. **No DDL, no migration** |
| `mix.lock` | one line added in each package: `telemetry_metrics 1.2.0`. Nothing else moved |
| Elixir / OTP / ERTS | 1.20.1 / 29.0.1 / 17.0.1 |
| PostgreSQL | 16.13, port 5490 |
| Run date | 2026-09-16 (UTC) |

Baseline before this unit: core `mix check` exit 0, **1832 passed**; headless
**1740**.

## 2. Commands, in order, with exit codes

Every command went through `tmp/v1/mixlane.sh`, which holds the per-package
`_build` lock (wave rule 1). Logs are under `tmp/v1/08a-logs/` in the
storefront working tree, which is not committed; the numbers are here.

| # | Command | Exit | Result |
|---|---|---|---|
| 1 | `elixir tmp/v1/08a_census.exs <lib>` (core and Pro) | 0 | the two-method census, section 3 |
| 2 | `mix deps.get` (core, then Pro) | 0 | `telemetry_metrics 1.2.0`, one lock line each |
| 3 | `mix check` (core) | **0** | **1900 passed (73 doctests, 20 properties, 1807 tests), 5 excluded**, 0 failures. Baseline 1832. Re-run after the restoration of section 2a; the earlier reading was 1899 on the tree before the harness damaged it. The **+1 test** in both packages is X328's fix: one `api_inventory_test` case became two (`every optional-dependency row names the dependency it needs` and `each optional-dependency row is present exactly when ITS OWN dependency is`) |
| 4 | `mix check` (Pro) | **0** | **1098 passed (69 doctests, 1029 tests)**, 0 failures. Baseline 1058. Re-run after the restoration; the earlier reading was 1097. The first attempt at this re-run came back **1096/1098, exit 2**, both failures naming `AuroraMeter.Telemetry.Metrics` as unavailable: the optional-dependency leg had left a **headless core** inside Pro's `_build`, and `compile --force` does not rebuild a path dependency (**X329**). The dependency beams and the PLT are now deleted before each package's check, which is what this file already said was done for Pro and had not been carried into the re-run script |
| 5 | `tmp/v1/08a-property-seeds.sh core`, seeds 0/1/7/42/1337 | **0** at each | **10 files selected by content**; 214 passed (20 properties) at every seed |
| 6 | `tmp/v1/08a-property-seeds.sh pro`, same seeds | **0** at each | **0 files**: Pro declares no property. See section 8 and **X324** |
| 7 | `tmp/v1/08a-headless.sh core` (`AURORA_HEADLESS=1`) | deps.get 0, compile `--warnings-as-errors --force` **0**, contract run **0**, suite **0** | `AuroraMeter.Telemetry.Metrics` **undefined**, the catalogue still answers, **1791 passed (69 doctests, 20 properties, 1702 tests)**. The orchestrator observed 1790 on the pre-damage tree; this is the post-restoration re-run |
| 8 | `tmp/v1/08a-headless.sh pro` (**`AURORA_NO_METRICS=1`**, the narrow switch) | deps.get 0, compile `--warnings-as-errors --force` **0**, contract run **0**, suite **0** | **1084 passed**. `Telemetry.Metrics`, `AuroraMeter.Telemetry.Metrics` and `AuroraMeter.Pro.Telemetry.Metrics` all undefined; Oban, `Phoenix.Component`, `AuroraMeter.Oban.CreditExpiry` and `AuroraMeter.Components` all still present, which is what makes it a **narrow** switch rather than `AURORA_HEADLESS` renamed. 13 fewer tests than the full suite: the preset test files compile themselves away with the module. **X327** |
| 9 | `python3 tmp/v1/08a_controls.py` (32 controls) | **all 32 discriminated** | First run: **32 HARNESS ERROR** and the tree was damaged (**X326**). Harness rewritten to snapshot rather than to use git; see section 2a. Orchestrator's run on the repaired tree: **29 discriminated**, `restore verified: 12 files`, 3 `HARNESS ERROR` (`c01`, `c07`, `c27`) all X300's trap. Those three rewritten to invert rather than remove, and re-run: **all three discriminated**, zero compile warnings, `restore verified: 3 files`. Section 7 has the verdicts and the assertion each broke |
| 9a | `python3 tmp/v1/08a_patch_audit.py` (new: reads the harness's own CONTROLS table and says, per control, whether the tree holds the patched text) | **0** | after restoration: **32 clean, 0 applied, 0 unclear** |
| 10 | `python3 tmp/v1/08a_hygiene.py` | **0** | clean: no em dash, en dash or CR on any line this unit added |
| 11 | `mix run tmp/v1/08a_events_json.exs` (both packages) | **0** | core 22 events, Pro 18, both scanned clean of identifiers |
| 12 | `mix run tmp/v1/08a_pro_explain.exs` | **1**, fixed, **not re-run** | `--no-start` stops `db_connection`'s watcher, so the repo could not start. The flag is removed; the plan is **not** in the evidence |

Rows 3 and 4 are the **second** reading of each. The first (1899 and 1097) was
taken before the orchestrator's control run, which reverted four core files and
four Pro files to HEAD and left 15 control patches applied to six untracked
ones. Section 2a is what was lost, what was put back, and how it was measured.
The orchestrator's own run remains the authoritative number.

## 2a. The restoration, and what it cost

The orchestrator ran `08a_controls.py` against this unit's uncommitted tree.
`git checkout -- <file>` is a restore only when the work is committed;
programme rule 4 says the author does not commit, so it never was. Two
different failures at once, and the harness's output showed neither:

| What | Files | What happened |
|---|---|---|
| **Tracked, modified** | core `store.ex`, `flusher.ex`, `cluster.ex`, `docs/telemetry.md` | reverted to HEAD. **The unit's edits were destroyed** |
| **Tracked, modified (Pro)** | `outbox.ex` | reverted to HEAD. `outbox/deliverer.ex` kept its `defp gauge, do: Outbox.gauge()`, so **neither package compiled** |
| **Untracked, new** | core `lib/aurora_meter/telemetry.ex`, `telemetry/metrics.ex`, `test/support/.../telemetry_census.ex`; Pro `docs/telemetry.md`, `lib/aurora_meter/pro/telemetry.ex`, `.../telemetry/metrics.ex` | **not touched at all.** `git checkout --` is silent on a path git does not track, so every patch applied to them **stayed applied and accumulated** |

Four Pro files the orchestrator listed as damaged (`outbox/reconciler.ex`,
`reconcile.ex`, `recovery.ex`, `transitions/applier.ex`) turned out **not** to
be: this unit never edited them, so reverting them to HEAD was a no-op.

**Measured, not assumed.** The first sweep found and reversed 14 patches by
hand and reported "none still applied". That was wrong, and the reason is worth
recording because it is the same class of mistake as the harness's own: the
sweep tested "is the original text present?", which is true in **both** states
for an **insertion** patch (`new` contains `old` verbatim). `c24` survived it,
and `c24` inserts a live `:gen_tcp.connect/3` call site into the free core's
`AuroraMeter.Telemetry.emit_gauges/0`. A D11 violation, sitting in `lib/`,
three checks after it was declared reversed.

`08a_patch_audit.py` now reads the harness's own CONTROLS table and classifies
each control by shape: an **insertion** patch (`old` inside `new`) is applied
iff the extra text is present; a **deletion** patch (`new` empty, `c19` and
`c30`) is applied iff the deleted text is **absent**, because Python's
`"".count()` returns `len(text) + 1` and a naive count calls every file
patched. Result after restoration: **32 clean, 0 applied**. One of the two
deletions, `c30`, had removed Pro's `[:aurora_meter, :pro, :retention, :prune]`
row from `pro:docs/telemetry.md` and nothing had put it back; it was rewritten
from `AuroraMeter.Pro.Telemetry.events/0`, which is the side of the comparison
the guard reads.

`core:docs/telemetry.md` could not be recovered from any transcript and was
rewritten. Its events table is **generated** from `AuroraMeter.Telemetry.events/0`
rather than retyped, which is why the five doc-targeting controls (`c19` to
`c23`) all find their anchors again: the audit's "32 clean" is the proof that
the rewrite landed on the same text the harness expects.

Pro's PLT and the core beams inside Pro's `_build` were deleted before Pro's
first command (X114: a path dependency's beams changing does not invalidate the
consumer's PLT, and the failure reads as a real missing function).

## 3. The event census, built two ways

This is X222's measurement, and the reason it is here rather than asserted.

The A05 inventory guard found telemetry emit sites by grepping `lib/` for
`:telemetry.execute(` or `.span(` followed by a **literal** `[:aurora_meter,
...]` list. Anything emitted through a module attribute was invisible to it, in
both directions: it could not be found, and documenting it failed the guard with
"documented in `docs/api.md` but not emitted anywhere in `lib/`".

`AuroraMeter.Telemetry.events/0` is required by acceptance criterion 1 to return
every event that has a merged emitter. Building that catalogue with the same
grep would have made it incomplete in exactly the way the guard cannot see, so
it was built from the AST and both methods were **counted**.

| | method A (the guard's regular expression) | method B (AST, attributes resolved) |
|---|---|---|
| core, emit sites | **19** | **19** |
| core, distinct names | **19** | **19** |
| Pro, emit sites | **20** | **21** |
| Pro, distinct names | **17** | **18** |

The single Pro difference is
`pro:lib/aurora_meter/pro/retention.ex:476`, which emits
`[:aurora_meter, :pro, :retention, :prune]` as
`:telemetry.execute(@telemetry, ...)`. It was public, emitted on every retention
run since 0.4.0, and **in no documentation at all**. Recorded as **X311**.

**Core's two numbers agree for a reason that matters more than the agreement.**
X222 was closed in core by writing the event name out longhand at **four** emit
sites, each carrying a comment saying it was done so the grep could see it:
`events/replay.ex`, `subscriptions/transitions.ex`, `operations.ex` and
`retention.ex`. The numbers agree because the **source** was contorted until
they did. Read "19 and 19" without this paragraph and the conclusion is the
opposite of the truth.

Two of the four were worse than a style choice. `operations.ex` kept
`@telemetry [:aurora_meter, :operations, :batch]` **and** repeated the literal
at the call site, so one name lived in two places with a test to keep the copies
honest; `retention.ex`'s comment said "rather than the module attribute" when
there was no longer an attribute at all, so its justification was stale as well
as false.

What this unit did about it, recorded as **X322**:

- `AuroraMeter.Operations` goes back to `:telemetry.execute(@telemetry, ...)`.
  The duplication had no reason left, and it gives **core** a real
  attribute-emitted event, so the census's attribute path is exercised by
  production code and not only by a test fixture.
- The other three keep the literal. There is no attribute to go back to, a name
  used once reads better beside its call, and churning three feature units'
  files for a style preference is not this unit's business.
- **All four comments were rewritten.** A comment that gives a reason which has
  stopped being true is worse than no comment, because the next person preserves
  the shape for a reason that no longer exists.

Method B also sees two things method A cannot express rather than merely miss:

- a **family**, `[:aurora_meter, :credits, txn.kind]`, reported as
  `[:aurora_meter, :credits, kind]` with `form: :family` and expanded to the
  seven `AuroraMeter.Schema.CreditTransaction.kinds/0` names;
- a **span**, reported as `form: :span` with its three suffixed names, which is
  why the flush span and the flat flush event are two contracts under one name
  and the old count-based assertion would have broken on the day the span landed.

An emit site the census cannot resolve **raises**. Skipping it would reintroduce
the silent exemption this replaces.

## 4. What changed in core

| File | What |
|---|---|
| `lib/aurora_meter/telemetry.ex` | **new.** `events/0`, `event_names/0`, `tag_allow_list/0`, `feature_tag/0`, `forbidden_tags/0`, `forbidden_tag_suffixes/0`, `tag_allowed?/2`, `redact/2`, `emit_gauges/0` |
| `lib/aurora_meter/telemetry/metrics.ex` | **new**, behind `if Code.ensure_loaded?(Telemetry.Metrics)`. `metrics/1`, `groups/0` |
| `lib/aurora_meter/store.ex` | `taken_at_ms` on the batch map; the `[:aurora_meter, :store, :gauge]` timer and `emit_gauge/0` |
| `lib/aurora_meter/cluster.ex` | the peer map, `last_message_ms`, the `[:aurora_meter, :cluster, :lag]` timer and `emit_lag/0` |
| `lib/aurora_meter/flusher.ex` | a `:telemetry.span/3` around `Storage.flush_batch/3`. **The two existing events are byte identical** |
| `lib/aurora_meter/config.ex` | `metrics_interval`, `metrics_feature_label`, `metrics_scan_ceiling` and their accessors |
| `mix.exs` | `telemetry_metrics` as an optional dependency, gated on `AURORA_HEADLESS` **and** on the narrower `AURORA_NO_METRICS`, which removes this one and leaves Oban, LiveView, `phoenix_html` and Igniter alone (**X327**) |
| `config/config.exs` | `metrics_interval: 0` in the test environment (X320) |
| `docs/telemetry.md` | rewritten: the tag rules, the generated event table, the gauge semantics, the failure-mode table, correct presets, trace context |
| `docs/api.md` | the flush span, the two gauges, three configuration keys, two new sections of function rows, and the `Matched in lib/` column's meaning |
| `docs/configuration.md` | the three configuration keys |
| `docs/examples/showing-usage.md` | the second unbounded example, replaced (X313) |
| `docs/correctness.md` | sixteen new bullets under I01, I05 and I20 |
| `test/aurora_meter/api_inventory_test.exs` | the A05 guard reads the AST census, and compares **distinct names in both directions** rather than counting sites |
| `test/aurora_meter/optional_deps_test.exs` | `Telemetry.Metrics` in the I20 matrix, both directions |
| `test/aurora_meter/doc_examples_test.exs` | the optional-module skip covers the presets, narrowly, both directions |
| `test/aurora_meter/config_strictness_test.exs` | the `metrics_feature_label?` accessor exception |
| `lib/aurora_meter/operations.ex` | `:telemetry.execute(@telemetry, ...)` restored; the duplicated literal removed (X322) |
| `lib/aurora_meter/{events/replay.ex,subscriptions/transitions.ex,retention.ex}` | **comments only.** The justification for the longhand name was no longer true (X322) |
| `CHANGELOG.md` | the whole contract, under `[Unreleased]`, including the line telling a host who copied either unbounded example which line to change |

New tests: `telemetry_contract_test.exs`, `telemetry/cardinality_test.exs`,
`telemetry/metrics_test.exs`, `telemetry/redaction_test.exs`,
`telemetry/no_outbound_io_test.exs`, `store_gauge_test.exs`,
`flusher_span_test.exs`, `cluster_lag_test.exs`. New test support:
`test/support/aurora_meter/test/telemetry_census.ex` and
`refusing_storage.ex`.

## 5. Which clock each age uses, and why

X100 governs every duration here: the one clock every node shares was measured
stepping **backwards 439 ms**, nine times in a 300 second probe.

| Measurement | Clock | Why |
|---|---|---|
| `store.gauge.oldest_pending_age_ms` | `Clock.monotonic_ms/0` | a span inside one node's memory between two readings this process took. Never persisted, never compared across nodes |
| `store.gauge.pending_batch_age_ms` | `Clock.monotonic_ms/0`, via the new `taken_at_ms` on the batch map | same. The batch also keeps its wall-shaped `snapshot_at`, which `AuroraMeter.Retention` compares against database-stamped rows; the two readings are of the same instant and are used for different questions |
| `cluster.lag.since_last_message_ms` | `Clock.monotonic_ms/0` | the span between two local observations of gossip arriving |
| the peer horizon | `Clock.monotonic_ms/0`, against `10 x :broadcast_interval` | same |
| `flush.stop.duration` | `:telemetry.span/3`'s own monotonic reading | the library does not read a clock for it at all |

Nothing here reads `Clock.db_now/0`: no age in this unit is measured against a
database-stamped row, so a round trip would buy nothing and would put the
database on the gauge path.

`Clock.Fixed`'s `monotonic_ms/0` moves in step with the frozen instant, so every
age assertion in this unit is driven by `AuroraMeter.Test.travel/2` rather than
by `Process.sleep/1`. A test that waits for a real interval measures the
scheduler.

## 6. The deviation from the build document's cluster lag design

Recorded as **X319**, in full, with the reason: the primary design puts
`{:remote_keys, n}` bookkeeping on `Counter.apply_remote/2` and
`Counter.rebase/3`, and the document's own recorded fallback was taken instead.
`unreconciled_keys` is a bounded `:ets.select_count/2` over the `remote` column,
guarded by `:metrics_scan_ceiling` (default 50,000) and **omitted above it,
never zeroed**. Nothing was added to `apply_remote/2` or `bump/2`.

The consequence for this unit's own M4 is stated rather than argued away: "no
gauge emitter performs a full table scan" is met by a **bounded** scan, not by
no scan. 08c should measure the tick at the ceiling.

## 7. Negative controls

Thirty-two, one log each, in `tmp/v1/08a-logs/controls/`. Every control inverts
a behaviour rather than deleting a branch, because `mix test` compiles with
`--warnings-as-errors` and a deletion that orphans a private function fails to
**compile**, which reads exactly like a control that discriminated (X300). The
harness treats three things as a harness error rather than a result: a patch
anchor that does not occur exactly once, a control that did not compile, and a
control whose own log has no `Result:` line.

**All 32 discriminated.** The orchestrator ran them on the repaired tree with
the rewritten harness: **29 discriminated**, `restore verified: 12 files match
their sha256 snapshot`, and **three came back `HARNESS ERROR`**, all of them
X300's trap. `c01`, `c27` and `c07` each broke the code in a way
`--warnings-as-errors` rejects, so `mix test` never ran and no `Result:` line was
printed. The harness behaved exactly as designed: it reported a harness error
rather than a pass it had not earned. The three were rewritten and re-run:

| Control | Verdict | The assertion that failed |
|---|---|---|
| `c01-census-ignores-attributes` | **discriminated**, 9/13 | `an event emitted through a module attribute is visible to the census (X222)`, plus both directions of the emit-site comparison and the key check |
| `c27-pro-census-ignores-attributes` | **discriminated**, 26/33 | `X222 the attribute-emitted retention event is visible to the census`, both A05 directions, and `the Pro census is byte identical to core's` |
| `c07-redact-keeps-error-message` | **discriminated**, 6/8 | `redact/1 replaces error with error_class and never carries the message` |

Zero compile warnings in all three logs, which is the thing that had to change.
`restore verified: 3 files match their sha256 snapshot`.

These three mattered more than the average control. `c01` and `c27` are the
negative case for **this unit's central claim**, that the census resolves module
attributes, which is the whole of X222 and the reason
`[:aurora_meter, :pro, :retention, :prune]` was invisible for a release. Until
they ran, nothing proved the census would notice if attribute resolution were
removed. `c07` is the privacy claim.

One unplanned confirmation: `c27` patches **only Pro's** census, and
`the Pro census is byte identical to core's` failed as a result. That is `c31`'s
guarantee firing without being asked, which is the duplication guard doing its
job on a real divergence rather than on a synthetic one.

| # | Control | Claims, if the guard is real |
|---|---|---|
| c01 | the census stops resolving module attributes | X222 reopens: an attribute-emitted event is invisible again |
| c02 | a span is reported as a plain execute | the flush span and the flat flush event collapse into one contract |
| c03 | `tag_allowed?/2` accepts `tenant_key` and every `_id` | the closed allow list stops being closed |
| c04 | `feature_label: true` adds nothing | the opt-in tag is decorative |
| c05 | `decision_kind/1` keeps the settle amount | one time series per amount of money settled |
| c06 | `redact/2` keeps the tenant key by default | the default stops protecting anything |
| c07 | `redact/2` keeps `error` whole | the exception message travels into the log line |
| c08 | the tenant digest is salted per call | the pseudonymous digest correlates nothing |
| c09 | the batch reports an age it never had | `pending_batch_age_ms` is fiction |
| c10 | `empty_since/3` never resets on an empty set | a drained buffer keeps reporting an age |
| c11 | the age is read from the wall clock | X100's backwards step reaches a gauge |
| c12 | the tick calls `Counter.dirty_keys/0` | a full table scan lands on the flush path (M5) |
| c13 | `span_result/1` always answers `:ok` | a failed flush is reported as a successful one |
| c14 | the legacy flush event is renamed | every existing host handler detaches silently |
| c15 | `unreconciled_keys` reports `0` above the ceiling | an unscanned table reads as a converged cluster |
| c16 | the peer map is pruned for the report only | the map grows for the life of the process |
| c17 | the lag gauge ignores `cluster_sync` | a node that is not clustered reports convergence |
| c18 | "no peer ever" reports `0` | never having heard a peer looks like having just heard one |
| c19 | `docs/telemetry.md` loses one event row | X232 reopens in the doc-to-code direction |
| c20 | `docs/telemetry.md` gains an invented event | X232 reopens in the code-to-doc direction |
| c21 | a measurement key is misspelled in the doc | the key comparison is decorative |
| c22 | the unbounded `tenant_key` example returns | X313 reopens |
| c23 | a runbook anchor is renamed | the failure-mode table's links rot silently |
| c24 | core acquires a socket call site | D11 stops being asserted |
| c25 | core gains an `apply/3` with an unnamed target | the outbound scan's blind spot stops being declared |
| c26 | `AuroraMeter.Telemetry` names the optional module | I20's compile guard becomes decorative |
| c27 | Pro's census stops resolving attributes | X222 reopens where it was actually live |
| c28 | Pro's gauge rescues and emits zeros | a failing aggregate reads as an empty backlog |
| c29 | a Pro preset tags on `tenant_key` | the shared allow list stops binding Pro |
| c30 | Pro's `docs/telemetry.md` loses the retention event | the event X222 hid goes undocumented again |
| c31 | the duplicated Pro census drifts from core's | two copies of one rule drift unnoticed |
| c32 | Pro gains a fourth outbound call site | the two-file allow list stops binding |

The harness itself follows X300's three rules: **one log per control**, never a
cumulative grep; **a patch anchor that does not occur exactly once is a harness
error**, not a result; and **a control that did not compile has tested nothing**,
reported separately from one that discriminated. **Five** of the 32 needed
rewriting for exactly that reason, two before the run and three after it:

| Control | What it did | What it does |
|---|---|---|
| `c24` | `:httpc`, which may not be resolvable | `:gen_tcp`, which always is |
| `c25` | `if false`, which the type checker refuses | an `apply/3` guarded on a configuration read |
| `c01`, `c27` | inserted a `Map.fetch(%{}, name)` the type checker rejects | the `@attr` clause still matches, still reads the attribute table and still binds `name` and `attributes`; it just refuses to look **through** the attribute, which is the census's pre-X222 blindness exactly |
| `c07` | deleted the only call to `error_class/1`, orphaning it | **keeps** that call and **adds** the raw `:error` beside it, which is the real privacy failure. `redact/2`'s tests compare with `==`, so the extra key fails them |

The pattern in all five is one rule: **invert the behaviour, never remove the
branch.** A removal orphans a binding or a private function, the compiler
refuses the file, and the control's exit code is indistinguishable from a
control that discriminated. This is the third unit in the programme to hit it
after 07c's six, so it is a known technique rather than a discovery, and the
useful part of recording it again is that the harness caught all three rather
than scoring them as passes.

## 8. The fixed-seed property sweep

Selected **by content**: every file under `test/` declaring at least one
`property `, not by a filename glob (X276, and 07b's nine missing files).

**Core: 10 files, every seed green.** The selector found
`cluster_test.exs`, `credits/allocator_test.exs`, `credits_figures_test.exs`,
`credits_lot_migration_property_test.exs`, `credits_lots_test.exs`,
`credits_model_test.exs`, `credits_test.exs`, `metering_test.exs`,
`plan_versions_property_test.exs` and `record_test.exs`. A filename glob would
have found **2** of those 10.

| seed | exit | result |
|---|---|---|
| 0 | 0 | 214 passed (42 doctests, **20 properties**, 152 tests) |
| 1 | 0 | 214 passed |
| 7 | 0 | 214 passed |
| 42 | 0 | 214 passed |
| 1337 | 0 | 214 passed |

**Pro: 0 files, and the heading was a lie.** Pro declares no `property ` anywhere
under `test/` and carries no `stream_data` dependency in `mix.exs` or
`mix.lock`. The script then passed an **empty** file list to `mix test $files`,
the expansion vanished, the command became a bare `mix test`, and the leg ran
the **entire Pro suite** five times while reporting five green runs under the
heading "property sweep". Recorded as **X324**; the script now refuses an empty
selection instead of silently widening.

What those five runs really are is still worth having, under the right heading:
five full Pro suites at fixed seeds, **1097 passed** at each of 0, 1, 7, 42 and
1337. That is evidence of seed robustness. It is not evidence about any
property, because Pro has none.

## 9. Where each acceptance criterion is proved

The author does not tick these; this is where a reviewer looks.

| # | Criterion | Where |
|---|---|---|
| 1 | `events/0` returns every event with a merged emitter, with real keys | `AuroraMeter.TelemetryContractTest`, both directions against the AST census, plus the key comparison. Controls c01, c02 |
| 2 | a test fails when `docs/telemetry.md` and `events/0` disagree | same file, `X232 ...` and the key test. Controls c19, c20, c21, c30 |
| 3 | no `tags: [:tenant_key]` anywhere in either package | `no file in the package teaches a metric tagged on the tenant key`, in both packages, over `lib/`, `docs/`, `test/`, `README.md` and `CHANGELOG.md`. Control c22 |
| 4 | every preset tags only on the allow list; `:feature` only when enabled | `TelemetryCardinalityTest` M1, and Pro's `M1` pair. Controls c03, c04, c29 |
| 5 | a preset tagging on a forbidden key **fails** the cardinality test | the same file: each forbidden name is built into a metric and tried **one at a time**, and each allow-listed name is tried too so the checker is not simply refusing everything |
| 6 | `telemetry_metrics` absent: both compile, both suites pass, `Metrics` undefined | **Both halves now rest on a compile.** `tmp/v1/08a-headless.sh core` (`AURORA_HEADLESS=1`): compile 0, 1791 passed (69 doctests, 20 properties, 1702 tests). `tmp/v1/08a-headless.sh pro` (**`AURORA_NO_METRICS=1`**): compile 0, 1084 passed, and `AuroraMeter.Pro.Telemetry.Metrics` asserted undefined while Oban and `Phoenix.Component` are asserted **present**. The Pro half previously had no runnable leg at all: `AURORA_HEADLESS` is core's switch and core is Pro's path dependency, so it stripped four dependencies Pro requires and the leg could not compile (**X327**). Plus `AuroraMeter.HeadlessTest` and `AuroraMeter.OptionalIntegrationsTest` in both directions. Control c26 |
| 7 | a Store with no traffic, then ten increments | `StoreGaugeTest`: the dirty-keys test, the age test and the timer test, which asserts the **values** on the first timed sample as well as its arrival. Controls c09, c10, c11, c12 |
| 8 | a flush that fails once and succeeds on retry | `FlusherSpanTest`, the retry case (one start and stop per attempt, one legacy error event, the same batch id) and `StoreGaugeTest`'s `pending_batch_age_ms` case for the return to zero. Controls c13, c14 |
| 9 | `cluster_sync: false` emits no lag event | `ClusterLagTest`, asserted with a handler that fails the test if it fires, and paired with the same call succeeding once the flag is back. Control c17 |
| 10 | three occupied outbox states produce three gauge events | **unmeetable as written**: 04b shipped one event with a measurement per state. Recorded as **X316**; the property is tested in `AuroraMeter.Pro.OutboxGaugeTest` |
| 11 | a failing gauge query emits nothing | `AuroraMeter.Pro.OutboxGaugeTest`, driven through the fault repo. Control c28 |
| 12 | every failure-mode row names a real event and a real runbook anchor | the failure-mode tests in both contract files, with the anchor recomputed from the target file's own headings. Control c23 |
| 13 | the outbound-I/O scan: zero in core, only the allow-listed Pro sites | `no_outbound_io_test.exs` in both packages, with the Pro allow list checked in both directions. Controls c24, c25, c32. **The first version of the Pro scan was blind and its own reverse check caught it** (**X323**). The criterion's "three allow-listed Pro call sites" are `AuroraMeter.Pro.Stripe`, `AuroraMeter.Pro.Credits.StripeClient.Live` and the `stripity_stripe` dependency itself: the allow list is the two **files**, and the dependency is what they call |
| 14 | both evidence directories, with commands, exit codes, seeds and no identifier | this file and the three beside it; `pro:docs/evidence/v1/phase-08/` for the other three |

## 9a. G08's own bullets, checked rather than assumed

G08 bullet 1 is this unit's. The other four are checked here anyway, because a
unit reports against the criteria it read and a bullet it did not read is
invisible to it (X212).

| Bullet | Owner | State |
|---|---|---|
| 1. every invariant failure and recovery state has a signal and a runbook entry; no package sends data externally on its own | **08a** | Met. `08a-runbook-map.md` and `08a-no-outbound-io.md` |
| 2. optional dependencies absent and present both compile; attach and detach tests leave no handler leaks | 08b | First half met here for `telemetry_metrics`, in both packages. The handler-leak half is 08b's, and this unit contributes the strongest version of it: **neither package attaches a handler at all**, asserted over `lib/` |
| 3. load with a database outage recovers to exact totals; the backlog drains faster than arrival | 08c | Not this unit. The signals it would be read through exist |
| 4. new benchmark claims traceable to scripts and artifacts | 08c | Not this unit. **Nothing in this unit publishes a performance number** |
| 5. the dashboard and the sample hide cross-tenant operational data from ordinary tenant users | 08b | Not this unit, and worth flagging to it: every gauge here is **node-wide operational data** with no tenant dimension at all, so a dashboard that renders one to a tenant is leaking the deployment's shape |

## 10. What this unit could not prove

- **Acceptance criterion 10 is unmeetable as written.** It asks for one gauge
  event per occupied outbox state; 04b shipped one event with a measurement per
  state and `docs/api.md` has carried that as stable since 0.4.0. Recorded as
  **X316**, not changed, and the property the criterion protects is tested.
- **Metadata keys at seven emit sites are checked against `docs/api.md` only**,
  because those sites build their metadata with `Map.merge/2` and the source
  cannot state the keys. Two hand-written sources agreeing is weaker than source
  agreement, and the guard reports `:dynamic` rather than pretending otherwise.
- **The peer horizon and the scan ceiling are defaults nobody has measured
  against a real cluster.** Ten broadcast intervals and 50,000 rows are
  reasoned, not observed. 08c and 11d are where they get numbers.
- **`unreconciled_keys` is a sampled scan**, so a key that acquires and loses
  remote value between two ticks is never counted. The gauge is a convergence
  indicator, not an audit.
- **Nothing here proves a host's own handler is safe.** The library polices its
  presets and says so; a host that tags on `tenant_key` in its own list is
  outside anything this unit can reach.
