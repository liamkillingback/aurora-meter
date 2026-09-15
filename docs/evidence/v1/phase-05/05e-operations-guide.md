# 05e: core's operational guide

| | |
|---|---|
| Task | **05.07** (operational guide) |
| Build unit | 05e, the last of phase 05 |
| Repository | `aurora_meter` |
| Core SHA | `0a4bd0bef56cc0628485bc864e2043862a6a2214` |
| Pro SHA | `44ef949553e796ea86ecc7e360759f29deadf0f7` |
| Elixir | 1.20.1 (compiled with Erlang/OTP 29) |
| Erlang/OTP | 29 [erts-17.0.1] |
| PostgreSQL | the lane database on port 5490 |
| Decisions | D02, D11, D12, D13 |
| Invariants | none owned. The guide is the human-facing statement of I01, I06, I08, I10, I11, I12 and I16 |
| Gate | G05 |

## What was written

`docs/operations.md`, new, 12 fenced `elixir` blocks, ten sections:

1. **What runs, and how often.** The four core operations with a recommended
   frequency and, for each, the sentence that matters more: what running it less
   often costs. Then the two ways to run them, and a subsection on why running
   one twice is not an error, carrying X209's three measurements.
2. **Queue sizing.** What `queues: [aurora_meter: N]` controls, that it is per
   node, why five, and the one case that does not fit (replay).
3. **Recovering stale holds.** Look (`pending_holds/1`), decide (a complete
   `HoldReconciler` answering from the host's own job table), act
   (`reconcile_holds/1`). Age is not evidence; every way of not answering keeps
   the hold; a release that loses the race records the cost.
4. **When the database is unavailable.** A per-subsystem table taken from
   `architecture-map.md` section 12 and `docs/guarantees.md`, with the cost and
   the invariant on every row.
5. **Pause and resume.** `list/0` and `paused?/1` before `pause/1`; what a pause
   promises (a batch boundary, not a job); the foot-gun stated plainly.
6. **Replay.** When to run one, `status/0` first, and the three properties an
   operator needs in their head. The runbook itself stays in
   `docs/operations/replay.md`.
7. **Retention.** `plan/1` before `prune/1`; what `{:blocked, counts, reasons}`
   means, reason by reason, with a wait/investigate/forget column; then
   `forget_node/1` with its precondition and its consequence.
8. **Backup and restore.** What must be restored together, what a restore
   before a financial write loses, and four verification steps in order.
9. **A health check worth having.** A module a host can paste: conservation,
   held drift, negative balances, stale holds, paused operations, oldest pending
   flush batch, oldest cursor.
10. **What to alert on.** Nine signals with the operational meaning of each.

Also in core:

| File | Change |
|---|---|
| `mix.exs` | `docs/operations.md` added to `extras`, between `telemetry.md` and `retention.md`. `groups_for_extras` is unchanged: `Operations` matches `docs/operations/`, with the trailing slash, so the new page lands in `Guides` as the build document specifies |
| `docs/credits.md` | One paragraph under "Recovering stale holds" saying that section is the contract and section 3 of the operations guide is the runbook. The two now point at each other instead of drifting |
| `docs/telemetry.md` | Two rows added: `[:aurora_meter, :operations, :batch]` (05c) and `[:aurora_meter, :retention, :prune]` (05d). Both were in `docs/api.md` and in neither guide, so the page section 10 sends an operator to was incomplete |
| `docs/examples/team-saas.md` | `import Ecto.Query` and an `alias` added to `Bramble.Members`, which used `from/2` without importing it and therefore could not compile as printed. Found by the new harness |
| `docs/examples/allowance-and-overage.md` | The hourly `UsageReporter` crontab entry corrected to `*/5 * * * *`, and `AuroraMeter.Pro.Outbox.Deliverer` added beside it. This is a **P12** site nobody had listed, in the free package |
| `docs/examples/showing-usage.md` | Two `usage_csv(org, days: 90)` calls corrected to `bucket_kind: "month"`, with a paragraph saying `:days` is accepted and discarded. A **P13** site nobody had listed, also in the free package |
| `test/aurora_meter/doc_examples_test.exs` | **New.** The doc-example harness core did not have |

## The harness core did not have

`open-findings.md` X184 records that 05b's build document promised a doc-example
compile test that does not exist. It was half right: **Pro has one and core had
none at all**, under any name. `grep -rl "Code.compile_string\|Code.string_to_quoted" test/`
found only the correctness index parser and the fault shims.

So this unit ported `AuroraMeter.Pro.DocExamplesTest`, keeping its four layers
and its argument for why "compile every block" is the wrong rule for a tree full
of fragments:

1. every `elixir` block parses;
2. every `AuroraMeter*` module a block names exists;
3. every `AuroraMeter*.function(` a block calls is exported at some arity;
4. every block whose top level is nothing but `defmodule` declarations is
   compiled for real.

**187 blocks** across the 37 published pages (`README.md` plus the `docs/`
extras `mix.exs` names), against Pro's 48.

Three adaptations were forced by core, and each is written into the moduledoc
with its reason:

* **`@transcribed`.** Seven of core's self-contained blocks define modules that
  `test/aurora_meter/examples_test.exs` also defines at its own top level, as
  verbatim transcriptions of the same guides. Compiling such a block would
  redefine a module another file's assertions run against, and purging it
  afterwards would delete it outright. Both suites are `async: false`, and ExUnit
  does not order two synchronous modules, so the damage would depend on the seed:
  the definition of a flaky test. Those blocks are read by layers 1 to 3 and
  compiled by `examples_test.exs`, and a test asserts that file still defines
  each of the seven, so the exemption dies with the transcription that justifies
  it.
* **A type is not a function.** `docs/exporters.md` prints the two exporter
  callbacks verbatim, and `AuroraMeter.Exporter.Item.t()` inside a `@callback`
  looks exactly like a call to layer 3's regex. The module's own compiled
  typespecs are read and its type names excluded, rather than the line being
  special-cased.
* **`@pro_modules`, exempted by being asserted absent.** Core's guides name Pro
  modules where the honest answer to "how do I bill this?" is "with the
  commercial package". Those cannot load here, so the exemption is inverted: a
  test asserts every `AuroraMeter.Pro.*` name a core guide uses is **not**
  loadable, because `architecture-map.md` rule 1 is that core never references a
  Pro module. If one ever loads, that is a boundary violation and this suite says
  so, which is a more useful failure than the one the exemption suppresses. The
  same test fails if no core guide names a Pro module any more, so the class
  cannot quietly become empty.

The harness found two real defects on its first run, both listed in the table
above (`Bramble.Members` and, indirectly through the scan it prompted, the two
P13 sites in core's examples).

## The deliberate-failure control

`open-findings.md` X211 and X155: a criterion is about a branch that runs.
`tmp/v1/05e-core-control.sh` breaks `docs/operations.md` **seven** times, once
per thing the harness claims to catch, and asserts it names the file and the
fragment each time. Full output at `05e-core-control.log`.

| Control | The break | What the harness said |
|---|---|---|
| 1, layer 3 | `pending_holds(` renamed to `pending_hold(` | `guides call functions that do not exist: docs/operations.md:112 AuroraMeter.Credits.pending_hold` and a second site |
| 2, layer 2 | `AuroraMeter.Operations` misspelled `AuroraMeter.Oprations` | `guides name modules that do not exist: docs/operations.md:212 AuroraMeter.Oprations` and a second site |
| 3, layer 4 | an extra `def decide(` added to the policy module | `self-contained blocks that do not compile: docs/operations.md:122 mismatched delimiter ... def decide( ... unclosed delimiter`, and layer 1 caught it too |
| 4, layer 1 | an extra `(` in the `pause/1` block | `elixir blocks that are not Elixir: docs/operations.md:220 token missing ... missing terminator: )` |
| 5, structure | the read-only block deleted from the retention section | `a mutation is shown before anything that looks at what it is about to change: ## 7. Retention: Retention.prune( with no read-only block before it`, and the same for `forget_node(` |
| 6, the boundary | `aurora_meter_outbox_items` added to section 10 | `docs/operations.md names something only Aurora Meter Pro has: aurora_meter_outbox_items` |
| 7, P12 | an hourly crontab entry added to section 2 | `these pages carry the hourly crontab expression P12 was about: docs/operations.md` |

Each run exited 2. The guide was restored after each, the script carries a
`trap` on every exit path, and the restore was verified by hash:
`91df8bd0eb858f13ccff367685a1279d7b208a779b121cfccc4fd3510f1e8a11` before and
after, with the suite passing 12 of 12 on the restored file.

**One thing went wrong here and it is worth recording rather than tidying
away.** The first run of the control was piped to `head`, which closed the pipe
and killed the script between control 4's edit and its restore. The next
`mix check` therefore ran against a deliberately broken guide and failed, exactly
as it should have. The file was restored and the hash compared against the
control's own recorded value before the gate was run again; the runner script now
writes to a file and never pipes. The lesson is small and general: **a script
that breaks something and restores it must not be able to die between the two**,
and a pipe to `head` is a way of dying that leaves no error.

## Commands, with exit codes

Every command below went through `tmp/v1/mixlane.sh core`, which serialises Mix
against the package `_build` and sets `DB_PORT=5490`.

```
bash tmp/v1/mixlane.sh core mix test test/aurora_meter/doc_examples_test.exs --trace
bash tmp/v1/mixlane.sh core bash tmp/v1/05e-core-control-run.sh
bash tmp/v1/mixlane.sh core bash tmp/v1/05e-core-final.sh   # claims, format, docs, check
bash tmp/v1/05e-claims-scan.sh                               # greps only, no Mix
```

**The final gate: `mix docs` exit 0 and warning free, `mix check` exit 0, 1411
passed (57 doctests, 12 properties, 1342 tests), 4 excluded.** Exit codes for
every run, including the three that failed and why, are in `05e-commands.txt`;
the logs are `05e-core-docs.log`, `05e-core-check.log`,
`05e-core-control.log` and `05e-core-claims-verify.log`.

**Every `Module` / `test name` pair in `05e-claims.md` resolves.**
`tmp/v1/05e-verify-claims.exs` parses the test tree into ExUnit full names and
matches the table against it: 45 pairs, 43 of them core's and all 43 resolved;
the two Pro pairs are checked by Pro's run of the same script. The parse is AST
rather than grep, because a grep validates the documentation against itself
(`open-findings.md` X84) and both claims tables cite tests by name in prose.

## One environment defect, found before any of that

A fresh `mix test` in the core lane failed to compile, with three
`--warnings-as-errors` failures in `lib/mix/tasks/aurora_meter.install.ex`:
`AuroraMeter.Oban.cron_entries/0`, `AuroraMeter.Install.Oban.wire/2` and
`validate_call/2` "is undefined (module ... is not available or is yet to be
defined)".

The cause is a stale `_build/test`: the whole `AuroraMeter.Oban` namespace is
wrapped in `if Code.ensure_loaded?(Oban) do`, evaluated when `oban.ex` compiles.
If `oban` is compiled into the environment **after** `aurora_meter`, the manifest
believes `lib/aurora_meter/oban.ex` is current while the modules it should have
produced do not exist, and the install task fails on every subsequent run. The
first run of this session compiled 70 oban files, which is how it arrived in that
state.

`mix compile --force` fixes it, and the recovery is recorded because the next
agent to hit this will otherwise read it as a defect in their own change. It is
filed as a finding: a conditional `defmodule` is invisible to the compiler's
dependency tracking, so nothing invalidates `oban.ex` when its condition changes.

## G05 bullet coverage

`open-findings.md` X212: a unit reports against the criteria it read, and a gate
bullet it did not read is invisible to it. Phase 05 ends with this unit, so
every bullet of G05 is checked here rather than only 05.07's.

| G05 bullet | Covered by | Where |
|---|---|---|
| 1. Duplicate cron ticks and jobs from two nodes perform one effective expiry, report, reconciliation or terminal hold transition | 05b, 05c, 05d | `i16.md`'s per-worker table: proved, or `by construction` with the mechanism named, for all fourteen workers in both packages. The two-node run is `05c-multinode.log`; the forced-race measurement that corrects it is X209 |
| 2. Worker killed between batches resumes without skipping work. A single invalid tenant does not starve later tenants | 05c, 05d | Kill-and-resume proved for `CreditExpiry`, `AutoTopUpSweeper`, `Oban.Retention` and `EventsReplay`; the per-item failure proved for `UsageReporter`. **Four Pro workers with a cursor still have no kill test** and are named in `i16.md` as 11d's, with X218 recording why (Pro has no non-sandbox kill harness) |
| 3. Long-running legitimate work remains held; abandoned synthetic work is released only by the configured host decision | 05b | `05b-hold-recovery.md` and `05b-race-proofs.md`; the five keep cases are the tests named in rows 11 of `05e-claims.md` |
| 4. Queue restart and database reconnect do not erase in-flight immutable payloads | 05c, after X212 | `AuroraMeter.Pro.RestartTest` / `test G05 a queue restart and a database reconnect leave every in-flight payload byte identical`, summarised in `i16.md`. **This bullet had no test at all until the 05c review searched for it**, which is the finding X212 records |
| 5. Installer detects existing Oban configuration and adds only missing entries; second execution is a no-op | 05c | `05c-installer.md` and `05c-pro-install.md`, with `05c-installers.log` |

**05.07's own bullet** is this unit: the guide documents queue sizing (section
2), run frequency (1), the stale-hold callback (3), database-outage behaviour
(4), replay (6), dead-letter inspection (Pro's sections 7 and 10), restore (8)
and unknown provider outcomes (Pro's 10), and every command is read-only by
default with an expected-state guard on every mutation that has one.

Two bullets are met while the criteria behind them are not, and the distinction
is X215's: bullets 1 and 2 ask about *effects*, which the per-worker table
establishes, while 05c's criteria enumerated seven workers each that the gate
never named. Those criteria stay unticked and their remainders are owned by 11d,
06d and 07b.

## What this unit could not prove, and did not claim

* **I19 (backup and restore) is 11a's.** Section 8 describes a procedure and
  states its limits; it claims no property, and `05e-claims.md` rows 45 and 46
  say so.
* **The conservation queries in section 9 are the host's**, not the package's.
  They are written against the shape `AuroraMeter.CreditsModelTest` asserts after
  every command of a generated history, which is the strongest thing available
  short of shipping them as a function.
* **The recommendation of five for the queue is a recommendation.** Nothing
  measures it. The guide says so in the text rather than dressing it as a
  finding.
