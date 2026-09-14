# 04a: exporter behaviour, reference journal and conformance suite

**V1 task:** 04.10 (provider contract tests).
**Build document:** `docs/v1/build-plans/phase-04/04a-exporter-behaviour-and-conformance.md`
(in the storefront repository).
**Status:** EVIDENCED.

## Repository and revision

| Repository | Path | HEAD at the start of this unit |
|---|---|---|
| core | `product-workspaces/aurora_meter` | `4dbbbb5ceb0fd78b7c9b27fe4f6eb1feea381b7d` |
| Pro | `product-workspaces/aurora_meter_pro` | `f46b6864ffc0c0f3a6878a29cd2d02cb5c2095f3` |
| storefront | `PhxTemplates` | `177d4ff639e1df789a2e3ed41420d2611c667e53` (branch `aurorameter-v1`) |

Both package trees were clean at the start. Nothing is committed by this unit.

## Toolchain

```
Elixir 1.20.1 (compiled with Erlang/OTP 29)
Erlang/OTP 29 [erts-17.0.1] [64-bit] [smp:24:24] [jit:ns]
Linux DESKTOP-8R659B3 6.6.87.2-microsoft-standard-WSL2 x86_64 (WSL2, Ubuntu 24.04)
PostgreSQL 16 (docker container aurora-meter-pro-testdb, host port 5490)
```

The container on 5490 is the one build unit 00a selected (`open-findings.md` T7:
two containers claim that port). No container was created, started or removed by
this unit.

## What was added

Three modules and one guide, all in core. No migration, no configuration key, no
dependency, no telemetry event, no Mix task, no PubSub message.

| File | What it is |
|---|---|
| `lib/aurora_meter/exporter.ex` | the behaviour, `AuroraMeter.Exporter.Item`, the outcome types, `item!/1`, `normalize/2`, `outcome?/1`, `conservatism/1`, `subject_kinds/0` |
| `lib/aurora_meter/exporter/journal.ex` | the deterministic Agent-backed reference implementation |
| `lib/aurora_meter/exporter_case.ex` | the `ExUnit.CaseTemplate` conformance suite |
| `docs/exporters.md` | the host extension guide |
| `test/aurora_meter/exporter_test.exs` | 25 tests, including 3 doctests |
| `test/aurora_meter/exporter/journal_test.exs` | 18 tests |
| `test/aurora_meter/exporter_case_test.exs` | 34 tests: the journal through the suite, and 12 deliberately wrong adapters |
| `mix.exs` | ExDoc `extras` and `groups_for_modules` only |

The full reflected surface is in `04a-api-surface.txt`, which also records that
`AuroraMeter.Billing.Provider.behaviour_info(:callbacks)` is unchanged at four
callbacks.

## Commands

Every command, with its exit code, seed, UTC timestamp and log path, is in
`04a-commands.txt`. The headline results:

| Run | Result | Exit |
|---|---|---|
| core `mix test test/aurora_meter/exporter_test.exs --seed 0` (the first verification target) | 25 passed | 0 |
| core `mix test` over the three new files, `--seed 0 --trace` | 77 passed | 0 |
| core `mix test --seed 0`, whole suite | 1197 passed, 3 excluded | 0 |
| core `mix test --seed 0` without this unit's three files | 1120 passed, 3 excluded | 0 |
| core `mix check` | format, compile, credo --strict, dialyzer, 1197 tests, docs --warnings-as-errors | 0 |
| Pro `mix test --seed 0` before the X126 fix | 420 passed | 0 |
| Pro `mix test --seed 0` after it | 425 passed | 0 |
| Pro `mix check`, PLT cleared first (X114) | 425 tests, dialyzer clean | 0 |

The before and after core counts were produced by the same tree and toolchain,
not by arithmetic: the "before" run passed the same 58 test files minus this
unit's three.

## The six conformance areas, and what the reference journal covered

`AuroraMeter.ExporterCase` checks nine areas. Six are the ones V1 task 04.10
names; three more were added because the behaviour has three properties 04.10's
list does not reach.

| Area | 04.10 | Covered by the journal | Needs |
|---|---|---|---|
| identity | yes | yes | nothing |
| retry | yes | yes | `script/2` |
| partial success | yes | yes | `script/2` |
| malformed response | yes | yes | `script/2` |
| rate limiting | yes | yes | `script/2` |
| unknown outcome | yes | yes | `script/2` |
| payload identity (E5, core's half of I15) | added | yes | `sent/1` |
| exceptions (E3) | added | yes | `script/2` |
| description (E4) | added | yes | nothing |

The journal conformance module (`AuroraMeter.ExporterCaseJournalTest`) is used
with `require_scriptable: true`, so an area it could not exercise would fail
rather than warn. All eleven injected tests ran and passed; the trace in
`04a-conformance-run.log` names each one.

## The suite has rejected something

X125's rule is that a guard which has never failed is not known to be a guard,
and a conformance suite is exactly that shape. Twelve adapters, each wrong in one
way, are permanent tests in `test/aurora_meter/exporter_case_test.exs`, and each
is asserted to be rejected by the named assertion:

| Wrong adapter | The defect | Rejected by |
|---|---|---|
| `Dropping` | returns no outcome for a one-item batch | `assert_identity!/1` |
| `Inventing` | answers for an id it was not given | `assert_identity!/1` |
| `AnswersOk` | returns `:ok` instead of a list | `assert_identity!/1` |
| `Mutating` | re-derives a payload field between attempts | `assert_payload_identity!/1` |
| `Swallowing` | catches its own blow-up and reports accepted | `assert_exceptions!/1` |
| `TerminalRateLimit` | maps a rate limit to `{:rejected, _}` | `assert_rate_limiting!/1` |
| `OptimisticUnknown` | maps an unrecognised status to `:accepted` | `assert_unknown_outcome!/1` |
| `OptimisticMalformed` | maps an unparseable answer to `:accepted` | `assert_malformed_response!/1` |
| `HaltsOnFirstProblem` | halts the batch at the first non-acceptance | `assert_partial_success!/1` |
| `BareRetry` | answers a bare `:retry` atom | `assert_retry!/1` |
| `BadDescription` | `max_batch: 0` | `assert_description!/1` |
| `DriftingDescription` | `describe/0` changes between calls | `assert_description_constant!/1` |

Two more (`Exiting`, `Throwing`) are positive controls for the caller's guard:
the suite's `call/2` must catch an exit and a throw, not only a raise.

`TerminalRateLimit` and `HaltsOnFirstProblem` are not inventions. They are the
two defects recorded in `investigation/03-pro-runtime.md`: HTTP 429 classified as
a definite rejection on the usage path, and a batch reduced with
`Enum.reduce_while` that halts on the first error so later members are never
attempted.

### "and no other": measured, and false for half of them

The acceptance criterion asks that each broken exporter fail its named test "and
no other". That was measured rather than assumed, by running every wrong adapter
against every assertion. `F` means the assertion rejected the adapter, `.` means
it passed, `u` means the area could not be exercised.

```
adapter               iden payl retr part malf rate unkn exce desc desc
Dropping              F    F    F    .    .    F    .    .    .    .
Inventing             F    .    F    .    F    F    F    .    .    .
AnswersOk             F    .    F    F    .    F    .    .    .    .
Mutating              .    F    .    .    .    .    .    .    .    .
Swallowing            .    .    .    .    .    .    .    F    .    .
TerminalRateLimit     .    .    F    F    .    F    .    .    .    .
OptimisticUnknown     .    .    .    .    F    .    F    .    .    .
OptimisticMalformed   .    .    .    .    F    .    .    .    .    .
HaltsOnFirstProblem   .    .    .    F    .    .    .    .    .    .
BareRetry             .    .    F    F    .    F    .    .    .    .
BadDescription        .    .    .    u    .    .    .    .    F    .
DriftingDescription   .    .    .    .    .    .    .    .    .    F
```

**Every adapter fails its target. Six of the twelve fail only their target, and
six fail more.** The criterion is therefore met in its first half and not in its
second, and the second half is not achievable without contorting the adapters:
an adapter that answers `:ok` for everything is visible to every area that reads
an answer, and most areas deliver a single item, so an adapter broken on the
single-item path shows up in several of them. Saying "and no other" would have
meant writing adapters that break only when the suite is watching, which is the
opposite of a negative control.

`BadDescription`'s `u` in the partial-success column is the suite working: its
`max_batch` is 0, and an area that needs a batch of two records itself as
unexercised rather than asserting on a batch the adapter said it cannot take.

Probe: `tmp/v1/04a/wrong-adapter-matrix.exs`, run inside the core suite and
removed afterwards. It touches no database, so it needs no sweep prefix (X130).
Log: `tmp/v1/04a/logs/wrong-adapter-matrix.log`.

## The documentation actually renders

`mix check`'s docs step exits 0 whether or not a page is in `extras`, so the
question was asked of the output rather than of the exit code (X82's rule):

```
Extension seams: AuroraMeter.Billing.Provider, AuroraMeter.Exporter,
                 AuroraMeter.Exporter.Item, AuroraMeter.Exporter.Journal,
                 AuroraMeter.ExporterCase, AuroraMeter.Storage,
                 AuroraMeter.StorageCase
Behaviours:      AuroraMeter.Clock, AuroraMeter.Events.Outbox,
                 AuroraMeter.Period, AuroraMeter.Tenant
Test helpers:    AuroraMeter.Clock.Fixed, AuroraMeter.Test
exporters.html rendered, 55745 bytes
```

`AuroraMeter.Storage`, `AuroraMeter.StorageCase` and
`AuroraMeter.Billing.Provider` moved into the new group, which the build document
asks for. Nothing else in `groups_for_modules` changed, and the `Internal` group
that `AuroraMeter.ApiInventoryTest` asserts on is untouched.

Script: `tmp/v1/04a/docs-group-check.sh`.

## Negative controls

Eleven controls, each disabling exactly one thing and asserting that exactly the
named test fails. Every mutation is restored from a saved copy and the restore is
asserted with sha256 before the next control runs (X97, and X132, which is what
happens when a restore is a second textual edit instead of a copy).

| Control | What it disables | Test that must fail | Result |
|---|---|---|---|
| n1 | drops `worker` from Pro's sweep list | `Y4 the test_helper sweep list names every prefix the non-sandbox modules use` | failed as required |
| n2 | adds a prefix nothing uses to the sweep list | the same test's exactness half | failed as required |
| n3 | puts `sync_refund_test` back on the bare `unique_tenant/0` default | `Y4 no non-sandbox module takes the bare unique_tenant default` | failed as required |
| n4 | removes the four-character guard from `register_prefix/1` | `Y4 sweep! refuses a prefix too short to be distinctive` | failed as required |
| n5 | makes `sweep!/1` reach past the prefixes it was given | `Y4 sweep! deletes the prefixes it is given and leaves every other prefix alone` | failed as required |
| n6 | makes `sweep_oban_jobs!/1` delete every job | `Y4 sweep_oban_jobs! deletes only jobs whose tenant_key carries a swept prefix` | failed as required |
| n7 | `normalize/2` believes an outcome it does not recognise | `E2 normalize maps an unrecognised outcome term to uncertain` | failed as required |
| n8 | `normalize/2` keeps the least conservative of two answers | `E2 normalize keeps the most conservative of two outcomes for one id` | failed as required |
| n9 | `normalize/2` drops an unknown id instead of refusing the call | `E1 normalize rejects a result carrying an id that was not delivered`, and the `Inventing` self-test | failed as required |
| n10 | the caller's guard rescues but does not catch an exit | `E3 the guard catches an exit as well as a raise` | failed as required |
| n11 | deletes the rate-limiting `describe` block from the `using` macro | `the case injects exactly the eleven named tests` | failed as required |

n9's first attempt did not run: the mutation left a binding unused and core
compiles with `--warnings-as-errors`, so it failed to compile rather than failing
the test it was aimed at. A control that cannot run is not a control, and it is
recorded here rather than quietly rewritten. The second attempt keeps every
binding used and fails the three named tests.

## The X126 precondition (Pro test contamination)

Core sweeps nine non-sandbox tenant prefixes before `ExUnit.start/0`. Pro had the
same shape and no sweep. This unit ported `sweep!/1`, added
`sweep_oban_jobs!/1` for the rows a prefix cannot reach through a table, and
renamed two modules' tenant prefixes so the list can be exact.

**The leak is measured, not assumed.** Killing the five non-sandbox files with
`timeout -s KILL` left a credit account, a grant of 30,000,000 micro-USD and a
balance row committed under one tenant key (`org_3215`), with the grant reference
`pi_org_3215` naming the module that wrote it.

**The prefixes were derived, not guessed.** Every module in Pro's suite that
commits on a real connection does so through `AuroraMeter.Pro.Test.Connections`
or `AuroraMeter.Pro.Test.Kill`; there are five, and their tenant prefixes are:

| Module | Prefix | How it is named in the source |
|---|---|---|
| `AuroraMeter.Pro.Test.HarnessTest` | `harnessa`, `harnessb` | `tenant!("harnessa")` |
| `AuroraMeter.Pro.Credits.ChargeConcurrencyTest` | `charge_race` | `AuroraMeter.Test.unique_tenant("charge_race")` |
| `AuroraMeter.Pro.Credits.AutoTopUpWorkerTest` | `worker` | `@tenant_prefix "worker"` |
| `AuroraMeter.Pro.Credits.PendingPaymentTest` | `pendingpay` | renamed by this unit |
| `AuroraMeter.Pro.Credits.SyncRefundTest` | `syncrefund` | renamed by this unit |

The last two took `AuroraMeter.Test.unique_tenant/0`'s default prefix, `"org"`.
That prefix **cannot be swept at all**: `register_prefix/1` refuses anything
shorter than four characters, which is the guard that stops a sweep deleting rows
it does not own (X38). It is also the prefix most of the sandboxed modules use,
so sweeping it would be exactly the over-reach that guard exists to prevent.
Renaming the two modules was the only way to make the list exact.

The derivation is now mechanical rather than remembered.
`AuroraMeter.Pro.Test.HarnessTest` finds the non-sandbox files by their use of
the harness, reads their tenant prefixes from source with doc strings and
comments stripped (X84), and asserts three things: every prefix they use is
swept, every swept prefix is used by one of them, and no such module takes the
bare default. Controls n1, n2 and n3 prove each half fails when it should.

The sweep's bound was demonstrated directly: rows seeded under `harnessa_999999`
and `notswept_999999` (plus one `oban_jobs` row each), then one Pro test file
run. The `harnessa` rows were gone and the `notswept` rows were untouched.

## Invariants

This unit owns none. It contributes to I15 (owner 04b, evidenced in Pro), I16
(owner 05c) and I20 (owner 08b).

**No test in this unit carries an `I<nn>` prefix, and that is a deliberate
departure from the build document.** The document names
`I15 an identical item redelivered carries an identical payload` and
`I16 a repeated delivery of one identity returns an outcome rather than raising`
as tests in core's `test/`. `invariant-map.md` is binding and says a test may be
named `I<nn> ` only when it genuinely proves that invariant; I15 is Pro's, core's
`docs/correctness.md` has no I15 section, and
`AuroraMeter.CorrectnessIndexTest` fails a core test whose description starts
with an invariant id it does not own. Those two tests are named `E5` and `E6`
here, with the relationship to I15 and I16 written in the test bodies, in
`AuroraMeter.Exporter`'s moduledoc and in `docs/exporters.md`.

The local contracts this unit introduces:

- **E1** `deliver/2` returns one outcome per input item id, and no outcome for an
  id it was not given. Violations are detected by `normalize/2`, not by the
  adapter.
- **E2** an outcome is one of the five documented shapes; anything else is
  `:uncertain` to the caller, never `:accepted` and never `{:rejected, _}`.
- **E3** `deliver/2` never raises for a provider-side problem; if it raises,
  exits or throws, the caller treats every item in the call as `:uncertain`.
- **E4** `describe/0` is pure and constant, and its `max_batch` is a hard upper
  bound the caller must respect.
- **E5** (new here) a redelivered item carries an identical payload: an adapter
  may not re-derive a field between attempts. This is core's half of I15.
- **E6** (new here) `deliver/2` is at-least-once: a repeated identity is answered,
  not refused. This is core's half of I16 at the adapter level.

## Time, and which clock (X100)

The vocabulary carries **no absolute deadline**, deliberately. `{:retry, seconds}`,
`idempotency_horizon` and `timestamp_window` are durations the caller adds to its
own clock reading. The single instant that crosses the boundary is
`Item.first_attempt_at`, and the behaviour documents that the caller stamps it
from the **database** (`AuroraMeter.Clock.db_now/0` or a `clock_timestamp()`
default), because it is persisted and later compared against.

That comparison is sound only because the idempotency horizon is measured in
hours. `AuroraMeter.Exporter`'s moduledoc and `docs/exporters.md` both state the
measured reason: the shared database clock is shared but not monotonic, and it
stepped backwards by up to 439 ms several times in a five-minute probe on this
hardware. Both documents then say the consequence in the form 04b and 06a need:
**a lease, a fence or a short timeout is not decided with these types.** Use
`SELECT ... FOR UPDATE SKIP LOCKED`, an advisory lock, or a fencing token.

No clock primitive is called anywhere in this unit's `lib/` except
`AuroraMeter.Clock.now/0`, once, to stamp a journal log entry, which is a record
and not a decision. The suite's own instants are fixed literals so that two runs
are comparable.

## Known limitations

- **The suite warns rather than fails when an area cannot be scripted.** Forcing
  every adapter author to fake a 429 would make the suite unusable, so an area
  whose scenario `script/2` reports `:unsupported` passes and is named through
  `IO.warn/1`. `require_scriptable: true` turns that into a failure, and 04b's
  Stripe adapter must use it. The warning path has its own test, and so does the
  failure path.
- **A generated test reports the macro's line, not its own.** Every assertion is
  therefore a public function with a written failure message, which is also what
  makes the twelve wrong adapters testable.
- **`Exporter.Journal` is memory, not a ledger.** Its log dies with its process.
  Said in the module's own words, and again in `docs/exporters.md`.
- **`ExUnit` is referenced from `lib/`.** `AuroraMeter.ExporterCase` ships inside
  `lib/` so a host can run it from an installed Hex package, exactly as
  `AuroraMeter.Test` and `AuroraMeter.StorageCase` already do. `ExUnit` is part of
  the Elixir distribution and is not a Hex dependency, so nothing was added to
  `mix.exs` deps. Build unit 01f's headless leg is where that is confirmed on a
  build with no optional dependency present.

## Files

- `04a-exporter-conformance.md` (this file)
- `04a-conformance-run.log`, the full `--trace` output for the three new files,
  with every absolute path outside the repository rewritten
- `04a-api-surface.txt`, read-only module reflection
- `04a-commands.txt`, every command with exit code, seed, UTC timestamp and log

No file in this tree names a credential, a real tenant, a provider, a URL or an
access date. This unit read no provider documentation; those records belong to
04b and 04d.
