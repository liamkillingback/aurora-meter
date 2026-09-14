# 01a: invariant index (aurora_meter)

## What was built

`docs/correctness.md` is the engineering index of this package's correctness
invariants, and `test/aurora_meter/correctness_index_test.exs` is the mechanical
check that stops it drifting. The index cannot be wrong in either direction: an
invariant may not be listed without a test, and a test may not claim an invariant
without being listed.

The parser reads the test sources with `Code.string_to_quoted/2` and a manual walk
rather than by module reflection. ExUnit only loads the files in the current run
set, so `Code.ensure_loaded?/1` would make the index pass when it is run on its
own, which is exactly how a developer checks it. Parsing is independent of the run
set and of compilation order, and it runs on the headless CI leg because it opens
no database connection, starts no process and loads no optional module.

## Command and environment

| Field | Value |
|---|---|
| Command | `mix test test/aurora_meter/correctness_index_test.exs --trace --seed 0` through `tmp/v1/mixlane.sh core` |
| Further seeds run | 1, 4242, 98765, plus the full suite at its own random seed |
| Commit | `26e18b652d11c0928d68119e5ccea9c3260df56c` plus the uncommitted wave-1a tree |
| Elixir / OTP | 1.20.1 / 29 (erts 17.0.1) |
| UTC timestamp | 2026-09-14T08:42Z |
| Log | `logs/01a-core-index.txt` |

Tests added by this unit: 12. The phase-00 baseline of record for this package is
242 tests; 01a takes it to 254. 01b adds further tests in the same wave, so the
wave total is higher than that; 254 is 01a's contribution alone.

## Invariants this package owns

Core owns I01 to I12 and I16 to I21. I13, I14 and I15 are Pro's. I22 is the
storefront's and appears in neither package file.

| Invariant | Title | Indexed tests that exist | Planned tests | Owning units of the planned tests |
|---|---|---|---|---|
| I01 | One flush batch has at most one durable effect | 5 | 2 | 01c |
| I02 | Counter, day history and receipt update atomically | 2 | 1 | 01c |
| I03 | Failed tentative quota work is never billed | 4 | 3 | 01c |
| I04 | A local hard quota cannot oversubscribe completed plus pending work | 4 | 2 | 01c |
| I05 | Cluster guarantees match documented limitations | 6 | 2 | 01c |
| I06 | Durable accepted events survive process loss without duplication | 2 | 3 | 03b |
| I07 | Conflicting reuse of event identity is rejected | 0 | 3 | 03b |
| I08 | One input source yields one commercial usage effect | 1 | 3 | 03c |
| I09 | Corrections preserve immutable history and bounded net quantity | 1 | 3 | 03e |
| I10 | Every ledger amount has exact provenance and conservation | 5 | 3 | 01e, 06a |
| I11 | Holds cannot spend the same available funds twice | 5 | 2 | 01c, 05b |
| I12 | Grant expiry cannot consume later or unrelated funds | 5 | 3 | 06a |
| I16 | Worker scheduling is not an exactly-once assumption | 3 | 2 | 05c |
| I17 | Historical plans remain stable | 3 | 3 | 07a |
| I18 | Recurring grants occur once per entitlement period | 2 | 4 | 06d |
| I19 | All supported schema histories preserve commercial state | 3 | 2 | 11a |
| I20 | Optional integrations remain optional and tenant-safe | 8 | 4 | 01c, 08b, 09b |
| I21 | Public installation instructions resolve real artifacts | 5 | 1 | 11c |

Totals: 18 sections, 64 test bullets that resolve to an existing test, 46 planned
bullets that must not resolve yet.

### I20 after 01f

I20 was the only invariant in this file whose bullets were all planned or
peripheral when the index first landed. 01f then wrote
`test/aurora_meter/optional_deps_test.exs`, six tests whose descriptions open with
`I20 `, and this unit's orphan check failed until they were indexed. They are now
six existing bullets, the planned 01f bullet they replace has been removed, and
I20's guarantee and known limits were rewritten against the real tests rather than
the intended ones. Three substantive changes came out of that rewrite:

1. The guarantee now names the mechanism, `if Code.ensure_loaded?(Phoenix.Component) do`
   at the top of `lib/aurora_meter/components.ex`, rather than asserting optionality
   in the abstract.
2. It records that the claim is asserted in **both** directions from one module,
   and why: a one-directional assertion passes for the wrong reason the day an
   optional dependency quietly stops being fetched.
3. A new known limit: the three absence tests are tagged `:headless` and excluded
   by default, so an ordinary `mix test` proves only the presence half. A developer
   who breaks the headless build locally will not learn it until CI runs.

`AuroraMeter.Install.Templates.manual_steps/0` also moved in `coverage.md` from
"no test" to a named test, while still reading as uncovered in the default
measurement, because its test only runs on the headless leg.

Worth recording because it was not obvious in advance: the parser reads test
**sources**, so it indexes the three `:headless` tests even though they are
excluded from the run. A reflection-based index would have been blind to exactly
the tests that carry the invariant. The index test passes identically with and
without `--include headless`.

## Invariants whose proof does not exist yet

The build document asks this to be stated explicitly rather than left implicit.

**No existing test at all: I07.** Conflicting reuse of event identity cannot be
proven because there is no event identity in the shipped code. Its three bullets
are all planned against 03b. Its section says so in both the guarantee and the
known limits, so nobody can read the section as a shipped promise.

**Existing tests that do not yet prove the invariant, only a piece of it:**

| Invariant | What the existing tests actually prove | What is missing |
|---|---|---|
| I06 | That a durable feature writes an event row, and that the storage adapter appends rows | Survival across process loss, and deduplication on a same-identity retry. 03b. |
| I08 | That a durable feature writes an event row | Source enforcement and the cutover watermark. Today the invariant holds only by construction, because durable events are never billed. 03c. |
| I09 | That a negative `track/3` corrects an overcount | Immutable correction records and a bounded net quantity. 03e. |
| I17 | Compile-time plan consistency (duplicate feature, negative limit) and the entitled-status fallback | Immutable plan versions. A changed definition today silently changes an existing tenant's entitlement. 07a. |
| I18 | Grant idempotency per reference | Recurrence keys per entitlement period, catch-up, rollover cap. 06d. |
| I19 | That the migration ladder is complete and pinned | Populated upgrade fixtures, interrupted backfill, backup and restore. 11a, in the storefront. |
| I20 | That a component renders and the install task wires a host | The headless leg (01f) and dashboard authorisation (08b). |
| I21 | That the guides' snippets compile and behave as printed | A clean-room install from the published archive. 11c, in the storefront. |

By the end of phase 01 the "no existing test" column must be empty for I01 to I05
and for I10 to I12. It is expected to stay non-empty for I06 to I09 and I16 to
I21, whose owning units are in later phases.

## The index is drift-proof: demonstrated failures

| Mutation | Result | Log |
|---|---|---|
| Rename `AuroraMeter.MigrationTest` / `test the moduledoc describes every version` to `... lists every version` | Fails, naming the missing `(module, name)` pair under I19 and printing the three nearest existing names by Jaro distance, the first of which is the renamed test | `logs/01a-core-demo-rename.txt` |
| Delete `AuroraMeter.MigrationTest` / `test every version up to the latest has a module, and none beyond it` from the source tree | Fails, naming the deleted test under I19 with its nearest matches | `logs/01a-core-demo-delete.txt` |
| Add `AuroraMeter.ZzOrphanDemoTest` / `test I07 a conflicting reuse of event identity is rejected` and do not index it | Fails, naming the orphan with its module, full ExUnit name and `file:line` | `logs/01a-core-demo-orphan.txt` |

The orphan check also fired on real work rather than only on the synthetic case:
01b added five tests named `I01 seed: ...` and `I02 seed: ...` in
`AuroraMeter.Test.HarnessTest` without indexing them, and this unit's check failed
naming all five with their line numbers. 01b then renamed them to
`seed for I01: ...`, which takes them out of the indexable set deliberately,
because a harness seed is not itself a proof of the invariant: 01c's tests are.
That exchange is the handoff this unit exists to force, and it happened within
minutes of the parser landing.

Every mutation was reverted; `git status` shows no change to any test file this
unit does not own.

## Deviations from the build document, for the reviewer

1. **Planned bullets.** The build document asks for at least one test bullet per
   invariant and, separately, for an "exists yet" column covering invariants whose
   tests belong to later phases. Those two requirements conflict if every bullet
   must resolve. This unit resolves it with a second bullet form,
   `PLANNED (<unit>):`, which the parser requires **not** to resolve. Writing the
   test without promoting the bullet fails the suite, which is what makes the
   handoff to 01c, 01d, 01e and the later phases mandatory rather than polite.
2. **Repo-qualified evidence paths.** `invariant-map.md` puts I19's and I21's
   evidence in the storefront. A bare `docs/evidence/v1/...` in this file would be
   ambiguous about which repository, so the parser accepts an optional `core:`,
   `pro:` or `storefront:` prefix. `invariant-map.md` should adopt the same
   convention.
3. **A fourth coverage disposition.** See `coverage.md`.
