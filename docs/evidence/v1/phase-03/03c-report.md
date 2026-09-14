# 03c: reporting-source isolation and the legacy durable track path

The seven items of `v1-release.md` 1.2.

Every command, exit code, seed, UTC timestamp and log path is in
`03c-commands.txt`.

## 1. Task ids, repositories and source state

V1 tasks **03.05** and **03.06**. Invariant **I08** (owner), **I01**, **I03**
and **I04** (contributor). Gate **G03** bullets 5 and 6, and G04's cutover
bullet through 04c.

| Repository | SHA at start | State at handoff |
|---|---|---|
| core `product-workspaces/aurora_meter` | `6d798c0` (03b) | dirty: 18 modified, 4 new. No commit was made; the owner reviews and commits. |
| Pro `product-workspaces/aurora_meter_pro` | `0da7e1d` | dirty: 2 documentation files, 1 new evidence file. **No Pro `lib/` change**, asserted mechanically (`03c-hot-path.json`, `pro_lib_changed_files: []`). |

Core files changed:

| File | What changed |
|---|---|
| `lib/aurora_meter/config.ex` | `events_features/0` and `refresh!/0` (both `@doc false`) and the `:persistent_term` cache behind them; `feature_source/1` rewritten to read that cache; `feature_sources/0` redocumented as the declaration; `check_sources!/1` with the dual-declaration boot error and the undeclared-events-feature warning; the stale 03c comment on `check_deprecations!/1` corrected. |
| `lib/aurora_meter.ex` | `buffered_source!/1`, the `track/4` guard, called before the tenant key is resolved; `maybe_write_event/5` and `write_legacy_event/5`, which carry the resolved period down and add the C14 rescue; `track/4`'s doc. |
| `lib/aurora_meter/entitlements.ex` | `buffered_source!/1`, the `reserve/2,3,4` guard; `settle/6`, the `with_quota/4` success rule; the source read once at the top of `with_quota/4`; docs on both. |
| `lib/aurora_meter/storage.ex` | `event_row` gains optional `period_start` and `period_source`, with the reason. |
| `lib/aurora_meter/storage/ecto.ex` | `insert_events/1` writes the period it is handed, and `period_source/1` normalises an atom source to a string; the comment block now states the three negatives (no totals, no outbox, no deduplication) that `AuroraMeter.LegacyDurableTrackTest` asserts. |
| `lib/aurora_meter/counter.ex` | moduledoc only: an "Events-source features" section explaining why `pending_flush` stays at zero, why `remote` grows without ever being cleared, and why there is no day bucket. **No function changed** (`03c-hot-path.json`). |
| `mix.exs` | `docs/examples/events-source.md` added to the docs extras. |
| `docs/metering.md` | "Where a feature's quantity comes from" (the source table, the three call-time consequences, the two limitations, the migration order) replaces the old durability text; "The legacy durable track" states what that path is and is not. The "billing-grade exactness" claim is gone. |
| `docs/configuration.md` | `:feature_sources` and, closing a gap 03b left, the four other keys 03b added; a `:feature_sources` section with the boot-error table. |
| `docs/entitlements.md` | "Over a feature whose source is `:events`": the release-on-success rule, the recipe, the arithmetic, and what the cap counts. |
| `docs/api.md` | `Config.feature_source/1`, `feature_sources/0` and 03b's four accessors; the raise noted on `track/4`, `reserve/2` and `reserve/3`; the settle rule noted on `with_quota/4`. |
| `docs/correctness.md` | I08 rewritten from "holds by construction" to the enforced guarantee with its cuts; six I08 bullets, four I03, one I04, two I05, each with a paragraph saying what the new ones measure. |
| `docs/examples/events-source.md` | **New.** The worked guide, compiled and run by `examples_test.exs`. |
| `docs/examples/concepts.md`, `docs/examples/allowance-and-overage.md` | both recommended the deprecated `:durable_features`; both now point at `feature_sources` and `record/4`, with the legacy key described honestly rather than deleted. |
| `docs/upgrading-to-1.0.md` | the `durable_features` row no longer says the replacement arrives in 1.0, because it is here. |
| `test/aurora_meter/feature_source_test.exs` | **New**, 25 tests. |
| `test/aurora_meter/legacy_durable_track_test.exs` | **New**, 12 tests. |
| `test/aurora_meter/feature_source_evidence_test.exs` | **New**, 2 tests, which measure and write `03c-flush-isolation.json` and `03c-quota-matrix.md` and assert every number before writing. |
| `test/aurora_meter/examples_test.exs` | `Lumen.Plans`, `Lumen.Gateway` (verbatim from the new guide), `Lumen.Model` (the host's, supplied here) and five tests. |
| `test/support/aurora_meter/test/config.ex` | the harness rebuilds the events-source cache on acquire, on release and on the holder's death, so a region that overrides `:feature_sources` changes the behaviour and not only the declaration. |

## 2. Schema, toolchain, environment

**No schema change.** This unit adds no DDL, no column, no index and no data
task. Core stays at schema version 8, Pro at 9.

Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), PostgreSQL on port 5490 (already
running; no container was created, started or removed). `mix.lock` is unchanged
in both packages; the hashes are in `03c-commands.txt`.

## 3. Commands, exit codes, seeds, timestamps

In `03c-commands.txt`: 23 lane-serialised runs plus 9 mutation runs, each with
its command, exit code, start and finish in UTC, and log path. The headline
results:

| Run | Result |
|---|---|
| core `mix test` (baseline, before any change) | **967 passed**, exit 0 |
| core `mix check` (final) | exit 0: format, `--warnings-as-errors`, `credo --strict`, dialyzer, **1011 passed** (42 doctests, 12 properties, 957 tests), `mix docs --warnings-as-errors` |
| Pro `mix check` with a **cold** Dialyzer PLT | exit 0, **420 passed**, docs generated |
| hot-path symbol comparison | 29/29 functions and 4/4 files byte identical; Pro `lib/` unchanged |
| negative controls | 9 mutations, 9 noticed, 9 restored |

Core went from **967** to **1011** tests. The 44 are 25 in
`feature_source_test.exs`, 12 in `legacy_durable_track_test.exs`, 2 in
`feature_source_evidence_test.exs` and 5 added to `examples_test.exs`.

The evidence generator asserts its numbers on every run and writes the two
files only under `AURORA_EVIDENCE=1`, so `mix check` still leaves the working
tree byte identical (`open-findings.md` X21, X27). The writing run is
`25-evidence-write` in `03c-commands.txt`.

**Pro's PLT was deleted before its `mix check`** (`priv/plts/*.plt` and the hash
file, 7.7 MB, rebuilt cold). Core's `lib/` changed in this unit, and a path
dependency's beams changing does not invalidate the consumer's PLT
(`open-findings.md` X114), so a warm Pro `mix check` after a core change proves
nothing. The cold run is green.

## 4. Expected against actual

| Expected | Actual | Where |
|---|---|---|
| 1000 records for an events-source feature leave the flush batch empty for that tenant, `load_counter/3` nil and `Events.total/3` 1000 | flush batch: none created at all (`present: false`); `load_counter/3` `null`; total 1000 over 1000 rows; ETS view 1000 | `03c-flush-isolation.json` |
| a mixed tenant flushes exactly the buffered delta | counter row 5 for `:requests`, `nil` for `:ai_generations`, durable total 7 | `feature_source_test.exs` |
| `with_quota/4` over an events-source feature leaves `reserved` at 0 and `value` equal to the recorded quantity; returns to its start when nothing is recorded | eight cells measured; every cell `reserved` 0, `pending_flush` 0 and `load_counter/3` nil on the events half | `03c-quota-matrix.md` |
| `n + 5` concurrent callers against a hard limit of `n` admit exactly `n` | 50 admitted, 5 refused with `{:error, :limit_exceeded}`, and no fifty-first admission while the fifty were held | `feature_source_test.exs` |
| a killed `with_quota` caller bills nothing | `Events.total/3` 0, `load_counter/3` nil, and the documented local leak measured exactly: `value` 6, `reserved` 6 | `feature_source_test.exs` |
| a legacy durable row satisfies core version 8 | insert succeeds; `event_id`, `payload_hash` and `occurred_at` all non-null; `seq` assigned | `legacy_durable_track_test.exs` |
| two identical legacy tracks make two rows | two rows, different `event_id` **and** different `payload_hash` | see below |
| the buffered hot path is behaviourally unchanged | 29 symbols byte identical; `entitlements_test.exs`, `metering_test.exs`, `flusher_test.exs`, `cluster_test.exs` pass unchanged | `03c-hot-path.json` |

**One expectation in the build document was not met as written**, and the
document is what was wrong. It says two identical legacy durable tracks differ
only in their `event_id`. They also differ in `payload_hash`, because the hash
covers `occurred_at` and `occurred_at` on this path is the write instant. The
test asserts the measured behaviour and says why; the conclusion the document
drew (no deduplication is possible on this path) is strengthened rather than
weakened by it.

### Known limitations, stated rather than worked around

- An events-source feature has **no day history**: `AuroraMeter.history/3`
  returns zeros. Deliberate; writing projected quantities into
  `aurora_meter_history` would feed the Pro day rollup from the same units the
  export path sends.
- A `with_quota/4` caller killed with `:kill` leaks its estimate in `value` and
  `reserved` on that node until the Store restarts or the period rolls. Measured,
  asserted and documented; it is never a charge.
- `AuroraMeter.track/4` inside a host transaction still bumps ETS while the
  legacy durable row rolls back with the host (C14). **Not fixed**, because
  fixing it means making `track/4` transactional, which is the hot path.
  Rescued, logged with the tenant and the feature, re-raised, asserted by
  `test when the write fails C14 a legacy durable write inside a host transaction rolls back with it while the ETS bump survives`,
  and named in `docs/metering.md`.
- A source migration for a feature already being billed is unsafe until 04c.
  Refused by nothing in core; documented in three places.
- The cluster assertions drive `AuroraMeter.Cluster.apply/3` on one VM. A real
  multi-node harness is 11d's.

## 5. Public API, configuration, migrations, telemetry, docs

| Change | Class |
|---|---|
| `:feature_sources` is now enforced rather than merely readable | additive |
| `AuroraMeter.Config.feature_source/1` reads the boot-time cache | behaviour change to a function 03b added in the same unreleased line |
| `AuroraMeter.Config.events_features/0`, `refresh!/0` | additive, `@doc false` |
| `AuroraMeter.track/4` raises for an `:events` feature | compat: only reachable by a host that opts in |
| `AuroraMeter.reserve/2,3` raises for an `:events` feature | compat, and **not** in `api-change-map.md` 1.1; see section 6 |
| `AuroraMeter.with_quota/4` releases instead of committing for an `:events` feature | compat |
| `AuroraMeter.history/3` returns zeros for an `:events` feature | new state, not a change to existing behaviour |
| a dual `durable_features` / `feature_sources` declaration raises at boot | compat |
| an `:events` feature no plan declares warns once per node at boot | additive |
| `AuroraMeter.Storage.event_row` gains two optional keys | additive; a 0.4.x caller of `insert_events/1` is unaffected |

No new telemetry event, no new PubSub message, no new behaviour, no Mix task, no
migration. No `CHANGELOG.md` entry: neither 03a nor 03b added one, the file has
no `Unreleased` section, and `docs/releases.md` owns changelogs at release time.

## 6. Open defects and findings

Severity is against the invariant named, not against the suite.

1. **The build document's I04 test as specified does not hold for an
   events-source feature.** Low; documentation defect in the build document, not
   in the code. It says to mirror `entitlements_test.exs`'s cumulative
   concurrency test (60 callers, limit 50, "exactly 50 admitted"). For a buffered
   feature the cap counts calls, because an admitted call keeps its unit. For an
   events-source feature the reservation is released on success, so callers that
   record nothing consume nothing and all `n + 5` are admitted, which is correct.
   The **acceptance criterion** says "admits exactly `n` of `n + 5` **concurrent**
   callers", which is satisfiable and is what the test now does: all 55 are held
   inside their callbacks at once, 50 are admitted, 5 refused. Next: whoever
   edits `03c-reporting-source-isolation.md`'s Tests section.
2. **The build document's cluster test as specified asserts something false.**
   Low. It says to deliver a `:totals` batch for a projected key with
   `Cluster.apply/3` and assert the value is unchanged, on the grounds that "the
   key is not in any peer's flush batch". Delivering it by hand defeats that
   reason. The value **is** unchanged, but because `Cluster.handle_batch/3`'s
   totals branch only moves a key forward and a peer's counter total for an
   events-source key is nothing. The test now names both mechanisms and says
   which one it exercises.
3. **`docs/correctness.md` carried a PLANNED (03c) bullet naming
   `AuroraMeter.SourcesTest`, a module this unit does not create** (the same
   family as `open-findings.md` X117). Two of the three were promoted to the
   tests actually written. The third, `test I08 a cutover at the watermark drains the buffer and takes events after it`,
   was **removed** rather than re-tagged: the cutover is Pro's 04c work, core has
   no `usage_reports` table to refuse against, and a PLANNED bullet naming a
   module the indexing repository will never create can never resolve, so it is a
   guard that fires never. The handoff is prose in I08's "Known limits" and in
   `i08.md`. **This is a deliberate removal of a planned commitment and 04c
   should re-read it.**
4. **03b left `docs/configuration.md` without the four configuration keys it
   added** (`:events_outbox`, `:events_future_tolerance`, `:record_timeout`,
   `:record_max_concurrency`), and without the four matching accessors in
   `docs/api.md`. That page states that a key not in its table is reported at
   boot, so the omission made the page wrong. Fixed here alongside
   `:feature_sources`. Low; documentation.
5. **`AuroraMeter.Pro.UsageReporter` still reads `AuroraMeter.Schema.*`
   directly** in two places, which `free-pro-boundary.md` rule 1 removes in 04b.
   Unchanged by this unit: it adds no Pro code. Noted because 03c's chain
   analysis had to read those queries.

Nothing was skipped. The one excluded tag in the suite is `:headless`, which is
pre-existing and has its own CI leg.

### A design decision worth naming

The build document specifies `Config.events_features/0` as a
`:persistent_term` cache for the hot-path guards, and leaves `feature_source/1`
reading the environment live. **That would have been two readers of one fact**,
and a stale cache beside a live read is precisely the split I08 forbids:
`track/4` would bump a key into the flush path while
`Counter.stored_value/1` seeded the same key from `load_event_total/3`.

`feature_source/1` therefore reads the same cache, and is the only seam. The
performance claim behind the cache was checked rather than assumed: over
2,000,000 iterations, net of the loop, `Application.get_env/3` plus `Map.get/3`
costs **75.2 ns** and `:persistent_term.get/1` plus `MapSet.member?/2` costs
**15.5 ns**. `track/4` already makes five configuration reads, so a sixth live
read would have been the most expensive one on the path. The cost of the cache
is that a source change needs a deploy, which the document already wanted and
which `docs/metering.md`, `docs/configuration.md` and a named test all state.

## 7. Handoff

**What a fresh agent needs to know.**

- The source is one fact with one reader: `AuroraMeter.Config.feature_source/1`,
  backed by the `:persistent_term` term `{AuroraMeter.Config, :events_features}`,
  filled by `AuroraMeter.Config.refresh!/0` from
  `AuroraMeter.Config.validate!/1`. **Any test that overrides `:feature_sources`
  must go through `AuroraMeter.Test.Config`**, which rebuilds the cache; a bare
  `Application.put_env/3` changes the declaration and nothing else, and there is
  a test that asserts exactly that.
- `AuroraMeter.Counter.apply_projection/2` is the load-bearing negative. It must
  never write `pending_flush` and never call `mark_dirty/1`. The mutation that
  makes it do both is in `03c-negative-controls.json` under
  `projection-marks-dirty`, and the flush-isolation test catches it.
- **04c** builds on this: `feature_sources`, the documented migration order in
  `docs/metering.md` and the "Reporting source" section in Pro's
  `docs/usage-reporting.md` are the contract it enforces. It owns the watermark,
  `usage_reports.source`, the boot refusal, and the cutover test that was removed
  from core's correctness index (finding 3 above).
- **04b** owns the outbox quarantine reasons. `{:ineligible, :feature_buffered}`
  is defined here and produced by `AuroraMeter.Storage.Ecto.eligibility/1`; there
  is a test for it and a negative control for it.
- **03e** runs next in wave 3c and edits `aurora_meter.ex`'s `correct`/`replace`
  additions and `storage/ecto.ex`. The overlap with this unit is real but in
  different functions: 03c touched `track/4`, `maybe_write_event/5`,
  `write_legacy_event/5`, `buffered_source!/1` and `insert_events/1`.
- **08c** benches the hot path. The pre-03c baseline is meaningful: 29 symbols on
  it are byte identical (`03c-hot-path.json`), and the only added work on a
  buffered `track/4` is one `:persistent_term.get/1` plus a `MapSet.member?/2`,
  measured at 15.5 ns.
- Every check this unit adds has been broken once on purpose and seen to fail.
  If you change one, re-run `tmp/v1/03c/negative_controls.py`: it restores what
  it mutates and asserts the restore.
