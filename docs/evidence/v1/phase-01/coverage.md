# 01a: measured coverage baseline and floor (aurora_meter)

## Environment and command

| Field | Value |
|---|---|
| Command | `mix coverage` (alias for `mix test --cover`), run through `tmp/v1/mixlane.sh core` |
| Repository | `product-workspaces/aurora_meter` |
| Commit | `26e18b652d11c0928d68119e5ccea9c3260df56c` (`aurorameter-v1`), plus the uncommitted wave-1a working tree (01a and 01b) |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1, jit) |
| OS | Linux 6.6.87.2-microsoft-standard-WSL2, WSL2 Ubuntu 24.04 |
| PostgreSQL | 16.13 (Debian 16.13-1.pgdg13+1), container `aurora-meter-pro-testdb`, `DB_PORT=5490` |
| Coverage tool | the built-in `Mix.Tasks.Test.Coverage`; no dependency added |
| UTC timestamp | 2026-09-14T08:42Z |

The built-in tool was chosen over `excoveralls` deliberately. It already fails the
run below the threshold, already supports `:ignore_modules`, and needs no
dependency: adding a runtime-false dependency plus an upload path to a third party
to a package whose whole positioning is a small dependency tree buys per-line HTML
and a badge, neither of which is a V1 gate.

## Result

Total line coverage of `lib/`, with the `:ignore_modules` list below applied:

    92.55%

Full per-module summary as printed:

| Percentage | Module |
|---|---|
| 8.33% | AuroraMeter.Migration |
| 50.00% | AuroraMeter.Billing.Noop |
| 62.50% | AuroraMeter.Test |
| 75.00% | AuroraMeter.Install.Templates |
| 75.00% | AuroraMeter.Schema.Subscription |
| 82.76% | AuroraMeter.Broadcaster |
| 83.33% | AuroraMeter.Billing |
| 86.05% | AuroraMeter.Flusher |
| 89.29% | AuroraMeter.Credits.Promotions |
| 90.00% | AuroraMeter.Counter |
| 91.26% | AuroraMeter.Components |
| 92.86% | AuroraMeter.Cluster |
| 94.12% | AuroraMeter.Entitlements |
| 94.44% | AuroraMeter.Storage |
| 95.00% | AuroraMeter |
| 96.97% | AuroraMeter.Store |
| 97.30% | AuroraMeter.Plans |
| 97.33% | AuroraMeter.Credits |
| 97.73% | AuroraMeter.Credits.Series |
| 98.14% | AuroraMeter.Credits.Ledger |
| 100.00% | AuroraMeter.Billing.Provider |
| 100.00% | AuroraMeter.Config |
| 100.00% | AuroraMeter.Credits.Money |
| 100.00% | AuroraMeter.LiveView |
| 100.00% | AuroraMeter.Period |
| 100.00% | AuroraMeter.Period.Calendar |
| 100.00% | AuroraMeter.Plan |
| 100.00% | AuroraMeter.Schema.Counter |
| 100.00% | AuroraMeter.Schema.CreditBalance |
| 100.00% | AuroraMeter.Schema.CreditTransaction |
| 100.00% | AuroraMeter.Schema.Event |
| 100.00% | AuroraMeter.Schema.FlushReceipt |
| 100.00% | AuroraMeter.Schema.History |
| 100.00% | AuroraMeter.Storage.Ecto |
| 100.00% | AuroraMeter.Subscriptions |
| 100.00% | AuroraMeter.Supervisor |
| 100.00% | AuroraMeter.Tenant |
| 100.00% | AuroraMeter.Tenant.Default |
| **92.55%** | **Total** |

## The floor and its arithmetic

    floor = floor(measured total) - 2
          = floor(92.55) - 2
          = 92 - 2
          = 90

`mix.exs` carries `test_coverage: [summary: [threshold: 90], ignore_modules: ...]`.

Two points of headroom absorb the ordinary churn of adding a module before its
tests. They are not enough to hide a deleted test suite: the smallest tested
module in the table is worth more than two points of the whole.

00b produced no coverage number (open finding T5 records that no coverage number
had ever been produced for either package), so this unit measured the baseline
itself. There is no earlier figure to compare against.

Both directions of the floor were demonstrated, then reverted:

- at `threshold: 90` the run exits zero;
- at `threshold: 93`, one point above the measured total, the run prints
  `Coverage test failed, threshold not met: Coverage 92.55% / Threshold 93.00%`
  and exits 3. Log: `logs/01a-core-threshold-demo.txt`.

**Moving this floor requires a new measurement in this file**, with the command
and the commit that produced it, and a phase report that says why. Lowering it
needs a reviewer.

### Re-measurement later in the same wave

01b landed its fault harness while this unit was writing its evidence, and a
second run at 2026-09-14T08:46Z measured **92.46%** over 298 tests (the first run
was 254). The floor of 90 holds for both. The nine hundredths of a point that moved
are 01b's new `lib/`-adjacent paths, not a regression, and the number is recorded
here so a later reader does not think the 92.55% was mis-measured. `logs/01a-core-coverage.txt`
holds the later run; it exits 2 because two of 01b's own harness tests were still
failing at that moment, which is 01b's work in progress and not a coverage result.
The 92.55% run that set the floor is the one described above.

## `:ignore_modules` and why each entry is there

| Entry | Justification |
|---|---|
| `AuroraMeter.TestRepo` | Test fixture compiled from `test/support` by `elixirc_paths(:test)`. It is harness, not library. |
| `AuroraMeter.TestPlans` | Same: the plans module the suite meters against. |
| `AuroraMeter.DataCase` | Same: the ExUnit case template. |
| `AuroraMeter.AmbiguousStorage` | The existing fault double. Retained while 01b moves it under the new harness namespace; a module that no longer exists is simply not matched. |
| `~r/^AuroraMeter\.Test\./` | The fault harness 01b adds under `test/support/aurora_meter/test/`. Note that `AuroraMeter.Test` itself, which is shipped in `lib/`, is deliberately **not** matched by this pattern and stays in the denominator. |
| `~r/^AuroraMeter\.Migration\.V\d+$/` | Executed by `mix test.setup`, a separate Mix invocation that finishes before `--cover` starts its cover server, so they read as zero however well they are exercised. Their real proof is the 11a migration matrix, which runs in its own OS processes. |
| `~r/^Mix\.Tasks\./` | Mix tasks are exercised by their own tests under `test/mix/`. `aurora_meter.install` needs Igniter, which is optional, so it is zero on the headless leg and would make the floor depend on the optional-dependency matrix. |

Every ignored module keeps its own named tests where it has them. Ignoring a
module removes it from the denominator; it does not excuse it from testing.

## Uncovered error branches

Every uncovered line in the summary appears below with a disposition. Dispositions
(a), (b) and (c) are the three the build document requires. Disposition (d) is a
fourth this unit had to add and is flagged for the reviewer: it is not untested
code but code that cannot be observed by this measurement at all.

- **(a)** covered by a named test in 01c, 01d or 01e, with the intended name.
- **(b)** requires the fault harness and is scheduled in 01b's follow-up.
- **(c)** unreachable without a provider or database failure the harness cannot
  produce; documented as a known limit in `docs/correctness.md`.
- **(d)** measurement artefact: the code runs outside the cover run, so it is
  reported as zero however well it is exercised.

| Uncovered branch | Disposition |
|---|---|
| `AuroraMeter.Migration.up/1`, `down/1`, `module/1` (the unknown-version raise) | (d). Run by `mix test.setup` in a separate Mix invocation before the cover server starts. Its behavioural proof is `AuroraMeter.MigrationTest`, which asserts the ladder is complete and pinned, and the 11a migration matrix. **Recommendation for a later unit:** add `AuroraMeter.Migration` to `:ignore_modules` for the same reason its `V<n>` children are there, re-measure and raise the floor. It is left in the denominator here so the recorded floor stays conservative. |
| `AuroraMeter.Billing.Noop.sync_subscription/1`, `report_usage/1` | (a). `I20` prerequisite: the Noop provider's other clause is covered by `AuroraMeter.EntitlementsTest` / `test the Noop billing provider returns :not_configured`; these two arms need the same test extended. 01c: `test I20 every Noop provider callback returns :not_configured`. |
| `AuroraMeter.Billing.sync_subscription/1` | (a). Same delegation path, same 01c test. |
| `AuroraMeter.Broadcaster.handle_info(:broadcast, _)`, `handle_info(_other, _)`, the PubSub broadcast arm | (b). The timer-driven tick and the unexpected-message arm need the harness's controlled clock rather than a sleep. 01b follow-up. |
| `AuroraMeter.Cluster.publish_totals([])`, `handle_info(_other, _)` | (b). Same: the empty-list short circuit and the unexpected-message arm. |
| `AuroraMeter.Counter.day_value/3` | (a). 01c I03/I04 period-boundary tests read the day bucket directly. |
| `AuroraMeter.Counter.restore_pending/2` | (c) by way of dead code: open finding C8 records it as unreachable. It is marked internal in 02a and removed in 03b; it must not be given a test that pretends it is supported. |
| `AuroraMeter.Counter` cold-key `[] -> 0` and `[] -> ...` arms (3 sites) | (b). A cold key mid-callback is exactly open finding C6 (`commit_work/5` and `release_work/4` skip `ensure_seeded`). 01b's harness can kill the Store between the reserve and the commit; 01c's `test I03 a caller killed with :kill is never billed and leaves a documented local reservation` reaches the neighbouring path. |
| `AuroraMeter.Credits.Ledger.refuse(:already_expired)`, `refuse(:held)` | (a). 01e's `property I10 a generated history matches the pure sequential model` generates expire-after-hold and settle-after-expire orderings that reach both refusals. |
| `AuroraMeter.Credits.Ledger.duplicate_reference_error/1` (the changeset arm) | (c). Reached only when Postgres raises the unique violation as a changeset error under a genuine write race. The non-racing arm is covered; the racing arm needs two committed connections colliding, which 01c's `test I11 fifty connections on one hot wallet admit exactly the affordable holds` may reach but cannot guarantee. Recorded as a known limit rather than claimed. |
| `AuroraMeter.Credits.Promotions.apply_entry/2` (the catch-all), the `nil -> 0` and `min(total, max(...))` arms | (a). 01e's model property generates the entry kinds that reach them. |
| `AuroraMeter.Credits.Series` `:kinds` ArgumentError | (a). 01c: extend `AuroraMeter.CreditsSeriesTest` / `test spend_history/2 an invalid bucket or an inverted range raises` to the `:kinds` arm. This one is cheap and should not wait. |
| `AuroraMeter.Credits.spend_history/2`, `spend_total/2` (default-argument heads) | (d). Default-argument function heads generate a clause the cover tool attributes to the definition line; the bodies are covered by `AuroraMeter.CreditsSeriesTest`. |
| `AuroraMeter.Entitlements.feature_value/3` (default head), `nil -> nil`, `percent(_used, 0)`, the `ArgumentError -> nil` rescue | Mixed: the default head is (d); `percent(_used, 0)` and `nil -> nil` are (a), covered by 01c's `test I04 a raise, a throw and an exit each give the capacity back` once a zero-limit plan is in the fixture; the `ArgumentError -> nil` rescue is open finding C3 (`String.to_existing_atom` rescued so a non-existent plan silently falls back) and is (c) until 02b changes the behaviour rather than testing the bug. |
| `AuroraMeter.Flusher.handle_info(:flush, _)`, `handle_info(_other, _)`, `failed/1`, the `[] -> 0` arm | (b). The timer tick and the failure path need the harness's controlled clock and its storage fault points. 01b's `:before_commit` and `:after_commit_before_ack` seeds reach `failed/1`; the bullet is in `docs/correctness.md` under I01 and I02 as planned 01c work. |
| `AuroraMeter.Install.Templates.manual_steps/0` | Now (a), and no longer planned: 01f's `AuroraMeter.HeadlessTest` / `test I20 the installer prints steps instead of raising without Igniter` calls it and asserts the printed steps are real. It still reads as uncovered in **this** measurement because the test is tagged `:headless` and excluded by default; it is covered on the headless CI leg. Indexed under I20 in `docs/correctness.md`. |
| `AuroraMeter.Plans` invalid-price raise | (a). 01c: extend `AuroraMeter.PlansTest` beside `test a negative limit raises at compile time` with an invalid-price case. |
| `AuroraMeter.Schema.Subscription.entitled?/1` | (a). Open finding C5 records that `Entitlements.plan/1` re-lists the entitled statuses instead of calling this function, which is why it is dead. 02b makes the call; 01c's I17 bullets then reach it. Do not add a test that only calls it directly: that would hide C5. |
| `AuroraMeter.Storage.add_history([])` | (a). 01c: a flush with counters but no day history, which is the `history: false` configuration. |
| `AuroraMeter.Store.handle_info(_other, _)` | (b). Unexpected-message arm; harness follow-up. |
| `AuroraMeter.Test.reset!/0`, `reset_aurora_meter/1`, `checkout/1`, `aurora_meter_checkout/1`, the `quote bind_quoted` head, the flush helper | (d) and (c). This module ships in `lib/` but exists to be called from a *host's* test suite, so this package's own suite does not call most of it. 01b's harness self-tests now exercise part of it. The rest is (c): proving it needs a consumer project, which is the 11c clean-room install, not a unit test here. |
| `AuroraMeter.history/3`, `start_link/1` (default-argument heads) | (d). Bodies covered by `AuroraMeter.HistoryTest` and `AuroraMeter.SupervisorTest`. |
| `AuroraMeter.Components` (10 uncovered arms: `runway_text(1)`, `bar_height(_, 0, _)`, `range_text([only])`, three `usage_text/1` clauses, the overage and promotional render arms, `nil -> []`) | (a). 01c and 09b own the component coverage. The named tests are `AuroraMeter.RealtimeTest` / `test I20 every quota kind renders its own wording` and `test I20 a single-point and an empty series render without a broken chart`. Note that this module is also open finding C9 (LiveView 1.0 syntax against a `~> 0.20 or ~> 1.0` requirement), so its coverage number is not meaningful until 09b settles the supported range. |

No uncovered branch is left without a disposition.

### Which disposition (a) names are indexed

The build document requires that every "covered by a named test in 01c/01d/01e"
disposition names a test that appears in `docs/correctness.md`. Every name in the
table above that carries an invariant id does:
`test I20 every Noop billing provider callback returns :not_configured`,
`test I20 every quota kind renders its own wording`,
`test I20 a single-point and an empty series render without a broken chart`,
`test I03 a caller killed with :kill is never billed and leaves a documented local reservation`,
`test I04 a raise, a throw and an exit each give the capacity back`,
`property I10 a generated history matches the pure sequential model` and
`test I11 fifty connections on one hot wallet admit exactly the affordable holds`
are all planned bullets in the index, and the index test refuses to let any of
them be written without being promoted there.

The remaining (a) entries are **ordinary coverage work, not invariant proofs**:
extending `AuroraMeter.CreditsSeriesTest`'s invalid-argument test to the `:kinds`
arm, extending `AuroraMeter.PlansTest` to an invalid price, adding a
`history: false` flush case to `AuroraMeter.StorageTest`, and reading the day
bucket in an existing counter test. They are named by the existing test they
extend rather than by a new invariant id, because giving them an id would claim an
invariant proof that they are not. They belong to 01c's ordinary work and are not
indexed.

## Statements 02d and 10a must fix

This unit wrote every guarantee, prerequisite and known limit in
`docs/correctness.md` from the source rather than from the shipped guides, because
several shipped statements are known stale. It did **not** edit the offending
files: 02d owns the guarantee table and 10a owns the trust pack. The list is
handed over here.

| File and line | The statement | Why it is wrong | Owner |
|---|---|---|---|
| `docs/metering.md:56` | "only a hard crash can lose increments (at most one interval's worth)" | Bounds the loss window at one flush interval. `docs/clustering.md:40-42` and `README.md:285` say the opposite ("an outage can make this longer than one interval"), and the source agrees with them: a failing flush retains the batch and retries it, so an outage spanning several intervals loses more than one interval's worth. Aurora Meter must not claim no buffered loss. | 02d |
| `docs/adr/0003-buffered-vs-durable-and-period-seam.md:8` | "tolerates a tiny loss window" | Same bounded-window framing as above, in the ADR that the guarantee table will cite. | 02d |
| `docs/clustering.md:8` | "Every counter row on a node is `{key, value, pending_flush, pending_gossip}`" | The ETS row is a six-tuple: `{key, value, pending_flush, pending_gossip, remote, reserved}` (`lib/aurora_meter/counter.ex` moduledoc, and `Counter.rebase/3` which reads all six). A reader reasoning about cluster behaviour from the four-tuple cannot account for `remote`, which is exactly what tells a node its view moved for a reason the database has not seen. | 10a |
| `docs/clustering.md:69` | "Schema version 2. 0.3 adds **no migration**." | The package is 0.4.0 and `AuroraMeter.Migration` reaches V6. The clustering guide's stated schema prerequisite is four versions out of date. | 10a |

`docs/correctness.md` states the source-derived version of each of these under
I01, I05 and I19.
