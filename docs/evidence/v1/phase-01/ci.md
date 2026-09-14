# Phase 01 evidence: the CI pipeline (`aurora_meter`)

Build unit **01f**, wave 1a. V1 tasks **01.07**, **01.08**, **01.09**. Read
`compatibility.md` first: it carries the pins, the compatibility table and the
reason for every version. This file is the job and leg map, the rules the
workflow enforces, and what was actually run.

## 1. The jobs, as implemented

`.github/workflows/ci.yml`. Triggers: push and pull request on `main` and
`aurorameter-v1`, plus `workflow_dispatch`. `permissions: contents: read`,
`concurrency` with `cancel-in-progress`.

| Job | What it is |
|---|---|
| `library` | the six named legs below |
| `database` | production database parity: the suite plus `mix v1.migrations` on Postgres 15.6 (`open-findings.md` X4) |
| `secrets` | gitleaks over the checkout with `fetch-depth: 0` |

### 1.1 The leg matrix

| Leg | Elixir | OTP | What it varies |
|---|---|---|---|
| `minimum` | 1.15.8 | 25.3.2.21 | the declared floor |
| `supported` | 1.18.5 | 27.3.4.17 | the retained middle pair; carries the one-per-repo tools |
| `current` | 1.20.4 | 29.0.6 | the then-current pair; carries docs and the package build |
| `headless` | 1.18.5 | 27.3.4.17 | no `phoenix_live_view`, no `phoenix_html`, no `igniter` |
| `liveview-1.0` | 1.18.5 | 27.3.4.17 | `phoenix_live_view` forced to `~> 1.0` |
| `liveview-0.20` | 1.18.5 | 27.3.4.17 | forced to `~> 0.20`; **expected to fail**, non-blocking for one merge |

### 1.2 Step by leg

"yes" means the step runs on that leg.

| Step | minimum | supported | current | headless | liveview-1.0 | liveview-0.20 |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| `mix deps.get` | yes | yes | yes | yes | yes | yes |
| `mix format --check-formatted` | yes | yes | yes | yes | yes | yes |
| `mix compile --warnings-as-errors --force` | yes | yes | yes | yes | yes | yes |
| `mix deps.unlock --check-unused` | yes | yes | yes | no | no | no |
| `mix credo --strict` | yes | yes | yes | yes | yes | yes |
| `mix deps.audit` | yes | yes | yes | no | no | no |
| `mix hex.audit` | yes | yes | yes | no | no | no |
| `mix dialyzer` | no | yes | no | no | no | no |
| `mix test.setup` | yes | yes | yes | yes | yes | yes |
| `mix test` | yes | yes | yes | yes (`--include headless`) | yes | yes |
| `mix coverage` | no | yes | no | no | no | no |
| `mix v1.migrations` | yes | yes | yes | no | no | no |
| `mix v1.faults` | yes | yes | yes | no | no | no |
| `mix docs --output` | no | no | yes | no | no | no |
| `mix hex.build -o` plus tarball assertions | no | no | yes | no | no | no |

Two kinds of "no" appear in that table and they are not the same thing:

- **Policy, one leg per repository.** `dialyzer`, `coverage`, `docs` and
  `hex.build` run on exactly one named leg because a PLT, a cover compiled
  suite, an ex_doc build and a tarball are expensive and none of them is
  runtime specific in practice. That is not a minimum-leg exemption: it applies
  to `current` exactly as much as to `minimum`.
- **Different dependency set.** `deps.unlock --check-unused` and the two audits
  are off on `headless` and the two LiveView legs, because those legs
  deliberately resolve something other than what `mix.lock` describes. On the
  LiveView legs an advisory in a deliberately-old LiveView would fail the leg
  for a reason that has nothing to do with the question the leg asks.

**No test step is skipped on any leg** (invariant M4), and `compile
--warnings-as-errors --force` runs on all six.

## 2. The minimum-runtime rule (M4), verbatim

> A minimum-runtime leg runs `deps.get`, `compile --warnings-as-errors --force`,
> `test.setup` and `test`. It may omit a **tool** (credo, dialyzer, ex_doc,
> coverage, mix_audit) only when that tool cannot resolve or run on the pair,
> and only with the exact resolution or runtime failure recorded in
> `docs/evidence/v1/phase-01/compatibility.md`. It may never omit a test. If the
> library itself, its hard dependencies, or its test suite fail on the pair, the
> pair is **not supported**: the floor is raised in `mix.exs`, the README,
> `docs/supported-versions.md` and the CHANGELOG, with an upgrade route. A
> tooling exemption is never a reason to keep a support claim.

### 2.1 Tools exempted on the minimum leg: none

The exemption table is **empty**, and that is a stronger result than the design
expected. Two things were checked rather than assumed:

1. **Every dev dependency resolves on Elixir 1.15.** From each dependency's own
   `mix.exs` in this checkout: credo `>= 1.13.0`, mix_audit `~> 1.8`, dialyxir
   `>= 1.6.0`, ex_doc `~> 1.15`, stream_data `~> 1.12`, floki `~> 1.15`. None
   excludes the floor.
2. **The formatter difference between Elixir 1.15 and the current release is
   already resolved in this repository.** The design proposed exempting
   `mix format --check-formatted` on the minimum leg because the formatter
   disagrees between majors. It does, and commit `cb38c3c` ("Format
   `with_credits/4`'s spec the way 1.15 wants it too") is the record of it: the
   1.15 CI leg failed on one `@spec` in `lib/aurora_meter/credits.ex`, and the
   fix expanded the spec into a layout that **both** versions leave alone. That
   commit is an ancestor of the current branch. So the step runs on every leg,
   and what it now protects is that version-stable property.

If the first `minimum` run does fail on a tool, the failure is pasted into
`compatibility.md` and the exemption is added there with it. It is not added in
advance on a guess, which is what M4 forbids.

## 3. The two environment switches

Both are build switches for this repository's CI. Neither is a consumer API,
neither appears in the package documentation, and both default to absent so an
ordinary `mix deps.get` is unchanged.

| Variable | Values | Effect (`mix.exs`) |
|---|---|---|
| `AURORA_HEADLESS` | `1` | `optional_deps/0` returns `[]`, so `phoenix_live_view`, `phoenix_html` and `igniter` are not fetched at all |
| `AURORA_LIVEVIEW` | `1.0` or `0.20` | `live_view_requirement/0` narrows the requirement to that half, and `lockfile/0` sends the resolution to `<tmp>/aurora_meter-liveview-<version>.lock` |

Two design points worth keeping:

- `optional: true` affects **consumers**, not this project. A plain
  `mix deps.get` here fetches and compiles all three optional dependencies, so
  the flag alone could never produce a headless build of Aurora Meter itself.
  `AURORA_HEADLESS` is what makes invariant I20 checkable by a machine.
- A LiveView leg resolves a dependency set the committed lock does not describe,
  so it resolves into **its own lock file outside the working tree**. No leg can
  rewrite `mix.lock`, in CI or locally. Verified: after both LiveView legs ran
  locally, `mix.lock` was byte identical
  (`70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` before and
  after) and `git status --porcelain` was unchanged.
- An unrecognised `AURORA_LIVEVIEW` value is a `Mix.raise`, not a silent
  fallback. An empty string (which is what a GitHub expression yields on a leg
  that does not set it) means absent.

## 4. The alias contract, shared with `scripts/v1/`

```elixir
"v1.migrations": ["test --only migration"],
"v1.faults":     ["test --only fault --seed 0"],
```

They are **aliases**, not command lines in YAML, for a structural reason: the V1
verification runners live in the storefront repository and package CI cannot
check out a private sibling, so the command is defined once here and both
callers invoke it by name. Changing what a suite means is a change to that line
and nothing else. `mix.exs`'s `cli/0` lists both in `preferred_envs`, so
`mix v1.faults` runs in `:test` like `mix test` does.

Neither `:fault` nor `:migration` is excluded in `test/test_helper.exs`, so both
also run inside the ordinary `mix test`. The dedicated jobs are a second, seeded
run rather than the only run: a tagged suite that quietly stopped being included
would otherwise vanish from CI, and RUN01 says a skipped required suite is a
failure. `test/aurora_meter/ci_contract_test.exs` asserts exactly that, and also
asserts that each alias selects a tag some module actually carries, because
`mix test --only <tag>` with no match exits non-zero with "no test was
executed" rather than passing quietly.

Modules carrying the tags today:

| Tag | Modules |
|---|---|
| `:migration` | `test/aurora_meter/migration_test.exs` |
| `:fault` | `test/aurora_meter/flush_batch_concurrency_test.exs`, `test/aurora_meter/credits_concurrency_test.exs` |

Those two `:fault` modules are the existing independent-connection suites (they
check out real, non-sandbox connections). **Build units 01b, 01c and 01d must
add `@moduletag :fault` to the fault modules they introduce**; until they do,
`mix v1.faults` runs only these two. The contract test fails loudly if the tag
ever has no carrier at all.

## 5. The one exclusion in `test/test_helper.exs`

```elixir
ExUnit.configure(exclude: [:headless])
```

`:headless` is the only excluded tag in this repository. The tests that carry it
assert the **absence** of the optional integrations, so they are meaningless,
and would fail, on a build where those modules are present. The `headless` leg
is the one leg that passes `--include headless`. This is the one deliberate
exclusion in the design, and `ci_contract_test.exs` asserts both that it is
there and that it is the only one.

Two test modules are wrapped in `if Code.ensure_loaded?(...) do`, the same guard
`lib/aurora_meter/components.ex:1` uses on the module it defines:
`test/aurora_meter/realtime_test.exs` (imports `Phoenix.LiveViewTest`) and
`test/mix/tasks/install_test.exs` (imports `Igniter.Test`). Without the guards
the headless leg cannot compile its own test suite, so I20 could never be proved
by running anything. The guards cannot silently swallow a suite, because
`optional_deps_test.exs` asserts positively, on every leg, that the optional
modules are present exactly when they were not switched off.

## 6. Cache keys (M3)

```
deps and _build:  ${{ runner.os }}-mix-${{ matrix.leg }}-${{ matrix.elixir }}-otp-${{ matrix.otp }}-${{ hashFiles('mix.lock') }}
restore-keys:     ${{ runner.os }}-mix-${{ matrix.leg }}-${{ matrix.elixir }}-otp-${{ matrix.otp }}-
PLT:              ${{ runner.os }}-plt-${{ matrix.elixir }}-otp-${{ matrix.otp }}-${{ hashFiles('mix.lock') }}
```

`matrix.leg` is in the key because the headless and LiveView legs resolve a
different dependency set from the same lock, and `restore-keys` stops one
component earlier so a partial restore cannot cross a leg boundary.

`priv/plts` moved **out** of the `deps`/`_build` entry into its own, restored
and saved only on the leg that runs Dialyzer. Before this unit it was listed
beside `deps` and `_build` while no job ran Dialyzer at all, so the directory
was never written: pure key churn against a cache nothing populated.

## 7. Database and connections

| | |
|---|---|
| Baseline image | `postgres:16.13` |
| Production parity image | `postgres:15.6` (`open-findings.md` X4) |
| `max_connections` on the official image | **100** |
| This package's test pool | **30** (`config/config.exs:28`; the credits concurrency test opens 20 real connections at once) |

One job is one database, so two pools are nowhere near the ceiling. The number
is recorded here so a future parallel-test change notices it before CI does.

Each job logs the resolved image digest and `select version()`, so a re-pushed
tag is detectable after the fact. The digests the tags resolved to when they
were pinned are in `compatibility.md` section 5.

`open-findings.md` **X18** (the storefront suite fails 4 of 571 tests when two
gates share one machine) is satisfied here by construction: every GitHub Actions
job gets its own runner, so no two gates share a machine. The same rule applies
locally and is `execution-waves.md` rule 7.

## 8. Local validation

The local machine has one toolchain, **Elixir 1.20.1 / Erlang OTP 29.0.1**, so
it rehearses the **commands**, not the pinned patches. Every Mix command went
through `tmp/v1/mixlane.sh`, which takes a `flock` per repository `_build`
(`execution-waves.md` rule 1). Logs are referenced by path and sha256 in the
storefront's git-ignored `tmp/`, never copied here.

### 8.1 Every step of the `current` leg, run in place

2026-09-14T08:41:27Z to 08:41:53Z, 26 s in total on a warm build.

| Step | Exit | Wall |
|---|---|---|
| `mix deps.get` | 0 | 5 s |
| `mix format --check-formatted` | 1 | 1 s |
| `mix compile --warnings-as-errors --force` | 0 | 1 s |
| `mix deps.unlock --check-unused` | 0 | under 1 s |
| `mix credo --strict` | 28 | 1 s |
| `mix deps.audit` | 0 | 2 s |
| `mix hex.audit` | 0 | 1 s |
| `mix dialyzer` | 2 | 5 s |
| `mix test.setup` | 0 | 1 s |
| `mix test` | 2 | 5 s |
| `mix docs --output <outside the tree>` | 0 | 3 s |
| `mix hex.build -o <outside the tree>` plus the tarball assertions | 0 | 1 s |

**The four non-zero exits are not this unit's.** They are wave 1a work in
flight in the shared tree at the moment of the run, and each was read before
being dismissed:

| Step | Cause | Owner |
|---|---|---|
| `format` | five new files under `test/support/aurora_meter/test/` and `test/aurora_meter/test/` are not formatted yet | 01b |
| `credo` | alias ordering in two of those files, an arity-9 function in `faults.ex`, and a fixture under `test/support/correctness_fixtures/` that uses `ExUnit.Case` without a `_test.exs` name | 01b, 01a |
| `dialyzer` | `Total errors: 2`, both `test/support/aurora_meter/test/kill.ex:96` and `:99`, an opaque `Task.ref()` compared in a guard | 01b |
| `test` | one failure, `AuroraMeter.CorrectnessIndexTest`, listing tests that claim an invariant and are not yet in `docs/correctness.md` | 01a (see section 11) |

Nothing in this unit's own work failed. The tarball assertions all passed:

```
ok: no test in the package        ok: LICENSE is in the package
ok: no demo in the package        ok: CHANGELOG.md is in the package
ok: no priv/plts in the package   ok: NOTICE.md is in the package
ok: no priv in the package        ok: README.md is in the package
ok: no doc in the package         ok: mix.exs is in the package
ok: no cover in the package       ok: .formatter.exs is in the package
                                  ok: lib/ is in the package
```

And the working tree was **byte identical before and after the whole rehearsal**,
which is the point of the `--output` and `-o` redirections
(`open-findings.md` X21, X27).

### 8.2 The `headless` leg

Run in a copy of the tree, because removing three dependencies makes
`mix deps.get` rewrite `mix.lock`; in CI that does not matter, because nothing
is committed there, but a local rehearsal must leave the tree alone.

| Step | Exit |
|---|---|
| `AURORA_HEADLESS=1 mix deps.get` | 0 |
| `AURORA_HEADLESS=1 mix compile --warnings-as-errors --force` | 0 |
| `AURORA_HEADLESS=1 mix test.setup` | 0 |
| `AURORA_HEADLESS=1 mix test --include headless` | 298 of 300 passed; the two failures are 01a's index test and 01b's `Kill` harness test, both also failing on an ordinary build |
| `AURORA_HEADLESS=1 mix test --include headless test/aurora_meter/optional_deps_test.exs` | **0, 6 passed** |
| the same file on an ordinary build | **0, 3 passed, 3 excluded** |

The dependency directory on that leg contained no `phoenix_live_view`, no
`phoenix_html` and no `igniter`. Both directions of invariant **I20** are
therefore proved by running something, not by reading `optional: true`:

- with the dependencies present, `AuroraMeter.Components` is loadable and the
  installer is the Igniter task;
- with them absent, `AuroraMeter.Components` is not loadable, the installer is
  the fallback `Mix.Task` whose `manual_steps/0` really does print the
  configuration, and `track/4`, `usage/2`, `check/2`, `Credits.grant/3`,
  `Credits.balance/1` and `Migration.latest_version/0` all work.

### 8.3 The `liveview-1.0` leg

| | |
|---|---|
| Resolved | `phoenix_live_view 1.2.11` |
| `mix deps.get` | exit 0, into `<tmp>/aurora_meter-liveview-1.0.lock` |
| `mix compile --warnings-as-errors --force` | **exit 0** |
| `mix test` | 308 of 309 passed; the one failure is 01a's index test |
| `mix.lock` | unchanged |

### 8.4 The `liveview-0.20` leg: the C9 capture

| | |
|---|---|
| Resolved | `phoenix_live_view 0.20.17` |
| `mix deps.get` | exit 0 |
| `mix compile --warnings-as-errors --force` | **exit 1** |
| `mix.lock` | unchanged |

The failure, verbatim:

```
==> aurora_meter
Compiling 50 files (.ex)
     warning: function runway_text/1 is unused
     |
 268 |     defp runway_text(nil), do: ...
     |          ~
     |
     └─ lib/aurora_meter/components.ex:268:10: AuroraMeter.Components (module)

     warning: function burn_text/1 is unused
     |
 264 |     defp burn_text(nil), do: ...
     |          ~
     |
     └─ lib/aurora_meter/components.ex:264:10: AuroraMeter.Components (module)

Compilation failed due to warnings while using the --warnings-as-errors option
```

This is **exactly** `open-findings.md` C9, and it is a sharper result than the
finding predicted. C9 says the components use LiveView 1.0 body interpolation
(`{@label}` and friends), which LiveView 0.20 treats as literal text. The
consequence the compiler reports is the mechanical shadow of that: because the
interpolations are literal text on 0.20, the private helpers those
interpolations would have called are never referenced, and the compiler
correctly says they are unused. In other words, the compiler can see that two
component helpers are dead on 0.20, which is the same statement as "every
component that renders a value is silently wrong on 0.20".

The leg is `continue-on-error: true` for exactly one merge. Build unit **09b**
(`docs/v1/build-plans/phase-09/09b-installers-and-host-compatibility.md`) owns
the resolution: either widen the component syntax so this leg passes, or remove
the leg together with the `~> 0.20` clause in `mix.exs`. **This unit did not
change that requirement**, because changing it would have destroyed the evidence
09b needs.

Note for 09b: the two unused helpers are the *visible* symptom. Widening the
syntax must be checked against the rendered output, not against the compiler
falling silent.

### 8.5 The two new aliases

| Command | Exit | Result |
|---|---|---|
| `mix v1.migrations` | 0 | 3 passed, 309 excluded |
| `mix v1.faults` | 0 | 5 passed, 307 excluded |

### 8.6 The workflow file itself

| Check | Result |
|---|---|
| parses as YAML | yes |
| every matrix key referenced by a step `if:` is defined on every leg | yes |
| `hex.publish`, `hex.organization`, `fly deploy`, `fly `, `git tag`, `git push` on a non comment line | **absent, all six** |
| every `run:` block passes `bash -n` (GitHub expressions substituted first) | 23 of 23 |

The same four checks are asserted from inside the suite by
`test/aurora_meter/ci_contract_test.exs`, so they hold on every future edit and
not only on the day the file was written. That test also asserts that every
Elixir, OTP and Postgres version in the workflow is an exact patch.

## 9. Wall time

Before this unit the workflow was two legs of ten steps with no Dialyzer, no
coverage, no docs, no package build, no migration or fault job, one database and
no second job beyond gitleaks. It is now six legs plus a database job plus
gitleaks.

**The real before and after numbers are OWNER BLOCKED** (section 10): no run has
happened. What is measured is the local rehearsal, 26 s for a full `current` leg
on a warm build and about 60 s for a cold dependency compile, from which a cold
GitHub runner leg is expected to be a few minutes and the whole workflow perhaps
three times the old wall time. That expectation is written down so the first run
can contradict it. The mitigations are already in place: Dialyzer and coverage
on one leg each, the PLT in its own cache entry so it is actually reused,
`cancel-in-progress` retained, and the `liveview-0.20` leg removed after one
merge.

## 10. Owner blocked

No agent pushes a branch or reaches GitHub (decision D13). Everything below
needs a real run and is therefore **not claimed**:

- pass or fail and a run URL for each of the six legs, the `database` job and
  the `secrets` job;
- the resolved `elixir --version` and `otp_release` per leg, matching the pins;
- the Postgres image digest each job actually ran;
- the demonstration that the PLT cache is hit on a second run;
- whether `gitleaks/gitleaks-action@v2` needs anything this repository does not
  provide.

The exact commands that produce them, after the owner has reviewed and committed
wave 1a:

```bash
# from the storefront checkout
git -C product-workspaces/aurora_meter push origin aurorameter-v1

# then, once the run has finished
gh run list  --repo liamkillingback/aurora-meter --branch aurorameter-v1 --limit 10
gh run view  --repo liamkillingback/aurora-meter <run-id> --log > 01f-core-run.log
```

The lines to fill in afterwards, here and in `compatibility.md`:

```
| leg           | elixir --version | otp_release | postgres digest | result | run URL |
| minimum       |                  |             |                 |        |         |
| supported     |                  |             |                 |        |         |
| current       |                  |             |                 |        |         |
| headless      |                  |             |                 |        |         |
| liveview-1.0  |                  |             |                 |        |         |
| liveview-0.20 |                  |             |                 | (expected fail) | |
| database      |                  |             |                 |        |         |
| secrets       |        n/a       |     n/a     |       n/a       |        |         |
```

## 11. Open defects

| Statement | Owner |
|---|---|
| `AuroraMeter.CorrectnessIndexTest` fails because six tests in `test/aurora_meter/optional_deps_test.exs` open their description with `I20` and are not yet listed in `docs/correctness.md`. That file belongs to build unit 01a and was deliberately not edited here. The six names are in section 11.1 | **01a** |
| `mix v1.faults` runs only the two existing independent-connection suites until 01b, 01c and 01d tag their new fault modules `@moduletag :fault` | 01b, 01c, 01d |
| `mix coverage` is wired on the `supported` leg against 01a's measured floor of **90** (measured 92.55%). It was not run to a green result here, because 01b's harness tests are red in the shared tree | 01a, 01b |
| The `liveview-0.20` leg fails, as designed, and must be removed or made to pass within one merge | 09b |
| Two Elixir advisories are unpatched on the `minimum` leg (see `security.md`) | 10a |

### 11.1 The six test names 01a needs to index under I20

```
I20 the optional integrations are present exactly when they were not switched off
I20 AuroraMeter.Components is compiled exactly when Phoenix.Component is available
I20 the install task exists either way, with or without Igniter
I20 Components are not compiled without Phoenix.Component
I20 the installer prints steps instead of raising without Igniter
I20 the facade, credits and migrations work with no optional dependency present
```

They live in `test/aurora_meter/optional_deps_test.exs`, in
`AuroraMeter.OptionalIntegrationsTest` (the first three, untagged, which run on
every leg) and `AuroraMeter.HeadlessTest` (the last three, `@moduletag
:headless`). `invariant-map.md` gives I20 the evidence path "phase-08, phase-09";
its first real proof is the headless leg here in phase 01, and the map should
list phase-01 as an I20 evidence location.

## 12. Handoff

Read `compatibility.md` (pins, the table, the Postgres digests, the S7 closure),
this file (the job map, the M4 rule, the switches, the alias contract) and
`security.md` (a disposition per finding). Then open
`.github/workflows/ci.yml`, `mix.exs` (`optional_deps/0`,
`live_view_requirement/0`, `lockfile/0`, `aliases/0`),
`test/test_helper.exs` and `test/aurora_meter/ci_contract_test.exs`.

**What must not change without a reason recorded here**: the
`phoenix_live_view` requirement (09b owns it), the `ecto_sql` requirement (S7
shows it is already correct), and the absence of any publish, deploy or tag step
in the workflow. The next verification target is the first real run, which is
the owner's push.
