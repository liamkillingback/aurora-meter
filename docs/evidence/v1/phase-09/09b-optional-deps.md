# 09b: the optional-dependency legs

Build unit 09b, task 09.10, invariant I20. Run on 2026-09-16 (UTC) from
`tmp/v1/09b-legs.sh` and `tmp/v1/09b-plug-leg.sh`, seeds as recorded per leg.
Raw logs, whole and unedited, in `tmp/v1/09b/legs/`.

Three legs, plus the storefront (its own file, `09b-storefront-separation.md`).
Each has its own `MIX_DEPS_PATH` and `MIX_BUILD_PATH`, and each build path is
deleted when the leg finishes: a leg that deliberately builds an incomplete tree
owns the cleanup, because the next reader has no way to tell an incomplete build
from a broken source and the error message points at the source every time
(`open-findings.md` X329).

**Why the whole resolved list is recorded for every leg, not a verdict.** An
optional dependency can silently satisfy another one's requirement (X331).
`phoenix_live_view 1.2` declares `plug` and `phoenix` as **non**-optional, so a
build that has LiveView has `Plug.Conn` whether or not `mix.exs` mentions `plug`,
and a leg that only asserted "the plug integration compiled" would have proved
nothing about the plug dependency. So each leg below prints what it actually
resolved and asserts what it actually lacks.

**And the first version of that assertion was vacuous, which is worth recording
because it is this unit's own harness doing what this unit spent the day
checking other people's code for.** `tmp/v1/09b-legs.sh` wrote each leg's
dependency list through `sed 's/^/  /'` and then grepped the saved file with
`^\* <name> `, a pattern that cannot match a line beginning with two spaces. The
leg printed "headless lacks phoenix_live_view" for eight dependencies and
"PLUG_ONLY LOST plug" for four, and both readings were the same reading: nothing.
A detector that can match nothing passes everything it cannot see (X325).

It was caught because the `plug_only` run said `LOST plug` about a leg whose
whole purpose is to keep `plug`, and the standalone
`tmp/v1/09b-plug-leg.sh` (which wrote its list unprefixed) had said `keeps plug`
about the same build an hour earlier. Two harnesses disagreeing about one fact is
what made it visible; one harness would have been believed. The script writes the
list unprefixed now and indents only on the way to the terminal, and the numbers
below are from a re-run afterwards, not from the run that could not fail.

## The legs

Final run, 2026-09-16, after the detector fix above and after every source
change this unit made:

| Leg | Switch | Resolved packages | Compile | Suite |
|---|---|---|---|---|
| `headless` | `AURORA_HEADLESS=1` | 25 | exit 0, `--warnings-as-errors --force` | **1900 passed, 0 failed** (`--include headless`) |
| `plug_only` | `AURORA_NO_LIVEVIEW=1` | 45 | exit 0, `--warnings-as-errors --force` | 2056 of 2059; the 3 are another unit's, see below |
| `liveview_10` | `AURORA_LIVEVIEW=1.0` | 52 | exit 0, `--warnings-as-errors --force` | **2127 passed, 0 failed** |
| ordinary | none | 52 | exit 0 | **2130 passed, 0 failed** (`mix check`, exit 0) |

The ordinary count is three above the `liveview_10` leg's because two repair
units landed tests in the tree between the two runs. Counts moved several times
during this wave, which is what a shared uncommitted tree does; each number here
names the run it came from, and the raw logs are in `tmp/v1/09b/`.

Both packages at the end of this unit: core `mix check` **exit 0**, 2130 passed;
Pro `mix check` **exit 0**, 1157 passed; `mix deps.unlock --check-unused` exit 0
in both; `mix hex.build` exit 0 in both (Pro's with `AURORA_METER_FROM_HEX=1`,
because Hex refuses a package carrying a path dependency and the workspace
checkout is a path dependency); storefront `mix test` 571 passed, run alone.

`mix.lock` sha256 `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0`
before and after all three; `git status --porcelain` byte identical before and
after.

**The three `plug_only` failures are not this leg's and not this unit's.** All
three are `{:error, :debt_outstanding}` where the test expects
`{:error, :insufficient_credits}`, in `credits_figures_test.exs` and
`credits_lots_test.exs`, and one of them is named "as repair unit R2 amends it".
The leg copies the tree with `tar` at the instant it starts, so it caught R2
between its source change and its test change. Checked rather than assumed: the
same three fail on the **ordinary** build at the same moment, 25 of 28, same
three names, same left and right. Nothing about them involves LiveView, `plug`
or a missing dependency.

### `headless`

Everything optional removed. The dependency directory held exactly:

    bunt credo db_connection decimal dialyxir earmark_parser ecto ecto_sql erlex
    ex_doc file_system floki jason makeup makeup_elixir makeup_erlang mix_audit
    nimble_options nimble_parsec phoenix_pubsub postgrex stream_data telemetry
    yamerl yaml_elixir

Asserted absent, one by one rather than as a group: `phoenix_live_view`,
`phoenix_html`, `plug`, `igniter`, `oban`, `telemetry_metrics`,
`phoenix_live_dashboard`, `opentelemetry_api`. All eight absent.

`mix test --include headless`: **1900 passed, 0 failed**. The `:headless` tag is
the one tag `test/test_helper.exs` excludes by default, so those assertions run
only here. `mix test --include headless test/aurora_meter/optional_deps_test.exs`:
**20 passed**.

What that leg proves for this unit's criterion 11, and what it does not:

- `AuroraMeter.Components`, `AuroraMeter.Plug.EnsureEntitled` and
  `AuroraMeter.Oban` are all undefined
  (`AuroraMeter.HeadlessTest` / `test I20 Components are not compiled without
  Phoenix.Component`, `test I20 AuroraMeter.Plug.EnsureEntitled is not compiled
  without Plug`, `test I20 the AuroraMeter.Oban namespace is absent without
  Oban`).
- **Each absence is paired with a positive control that runs on every other
  leg**, in `AuroraMeter.OptionalIntegrationsTest`, which carries no tag:
  `Code.ensure_loaded?(AuroraMeter.Components) == Code.ensure_loaded?(Phoenix.Component)`,
  `Code.ensure_loaded?(AuroraMeter.Plug.EnsureEntitled) == Code.ensure_loaded?(Plug.Conn)`
  and the same shape for the whole `AuroraMeter.Oban` namespace, worker by
  worker. Without those, "the module is absent" would pass on a leg where the
  module had never been written at all, which is a detector that cannot fail
  (X325). `AuroraMeter.Plug.EnsureEntitled` was landed by build unit 09a during
  this wave, and the paired assertion is 09a's; it is cited here rather than
  duplicated.
- The facade, the credit ledger, the migration ladder and
  `AuroraMeter.LiveView.subscribe/1` all still work on that build, which is the
  positive half: a headless host loses adapters, not behaviour.

### `plug_only`

The first build in this repository to have **Igniter present and LiveView
absent**, which is the shape of a real API-only Phoenix host mounting
`AuroraMeter.Plug.EnsureEntitled`. It found a defect on its first run, recorded
in full below.

Absent, asserted one by one: `phoenix_live_view`, `phoenix_html`,
`phoenix_live_dashboard`. Present, asserted one by one: `plug`, `igniter`,
`oban`, `telemetry_metrics`. The same detector returns a different answer for
the two lists, which is what makes either of them worth reading. That combination is the
point: `plug` survives when LiveView goes, which it could not have done before
09a declared it in `mix.exs`, because until then `plug` reached this package only
as `phoenix_live_view`'s own requirement (X331).

**The defect this leg found, in `.formatter.exs` and not in any source file.**
`.formatter.exs` named `:phoenix_live_view` in `import_deps` and
`Phoenix.LiveView.HTMLFormatter` in `plugins`, unconditionally. `mix format`
raises for an `import_deps` entry that is not in the dependency tree, and
**Sourceror reads the project's formatter configuration on its way to printing
an edit**, so every Igniter task raised

    ** (Mix.Error) Unknown dependency :phoenix_live_view given to :import_deps
    in the formatter configuration.

and took **30 of this package's installer tests with it**. Not a host-facing
defect (a host has its own `.formatter.exs`), but a real one: it made the
installer untestable on exactly the configuration `plug_only` exists to test.
Both entries are now conditional on the same two switches that remove the
dependency. The shape is X331's again: a leg that removes a dependency has to
remove every claim that depends on it, and a claim in a configuration file is as
real as one in `mix.exs`.

### `liveview_10`

Resolved `phoenix_live_view 1.2.12` fresh, into its own lock file
(`$TMPDIR/aurora_meter-liveview-1.0.lock`), with the committed `mix.lock`
untouched: sha256 `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0`
before and after every leg. **2127 passed, 0 failed**, which includes the eleven
component render assertions in `test/aurora_meter/components_test.exs`.

There is no `liveview_0.20` leg any more. This unit narrowed the declared
requirement to `~> 1.0` (finding C9, decision D12), so a 0.20 leg would resolve a
version the package no longer claims. The decision, and the measurement behind
it, are in `09b-components-liveview.md`; 01f's capture of the 0.20 failure is
kept at `docs/evidence/v1/phase-01/ci.md` section 8.4.

## Which of these legs is actually watched, and by what

This section exists because of a question the orchestrator put to this unit,
and the answer is not comfortable.

**`AURORA_HEADLESS` was red at `HEAD` for two phases and nothing reported it.**
Two defects (`open-findings.md` X356): `optional_deps_test.exs:147` asserted
`Code.ensure_loaded?(:otel_tracer)` in a branch that only runs when OpenTelemetry
is absent, and `docs/api.md:932` listed `AuroraMeter.LiveDashboard.View` in the
internal table, which has no Class cell and so cannot carry the `optional-dep`
tag its skip needs. Both were fixed by 09a, which needed the leg green for its
own criteria.

The mechanism is `open-findings.md` **X246**, already recorded and not acted on:
three units reported "the headless leg passes", each accurately describing a run
it had chosen to do by hand, and none of those runs was the same run. **A leg
that is not in the gate is a leg nobody is watching.**

Where the three legs stand today:

| Leg | In CI? | Blocking there? | Run by `mix check`? | Run by anything on this machine? |
|---|---|---|---|---|
| `headless` | yes | yes (`experimental: "no"`) | no | `scripts/v1/verify.sh --profile headless` (00d), which is not part of `--profile gate` |
| `plug_only` | **yes, added by this unit** | yes | no | this unit's `tmp/v1/09b-plug-leg.sh` |
| `liveview_10` | yes | yes | no | this unit's `tmp/v1/09b-legs.sh` |

So the honest statement of the gap is narrower than "nothing watches them" and
worse than "CI watches them": **all three are in CI and all three block, and the
workflow has never run at all.** 01f section 10 records it as OWNER BLOCKED. Two
phases of "the leg passes" were hand-runs against a workflow nobody had executed.

### Why `mix check` is not the answer, with the runtime

`mix check` is the local edit loop's gate and it must leave the working tree byte
identical (which is why `mix docs` gained `--output`, X21 and X27). A headless
leg cannot meet either bar:

- **It resolves a different dependency set.** `AURORA_HEADLESS=1 mix deps.get`
  rewrites `mix.lock`, so the leg has to run in a copy of the tree (01f's rule,
  and this unit follows it). A `mix check` step that copies the repository, runs
  a second `deps.get` into it and throws it away is not a check step, it is a
  build.
- **The runtime is wrong by two orders of magnitude.** Measured on this machine
  today, from the log timestamps in `tmp/v1/09b/legs/`: the `headless` leg takes
  **about 9 minutes** end to end (`deps.get` 01:29, `mix test --include headless`
  finishing 01:38), of which the suite alone is 252 s. `plug_only` is about 12
  minutes. `mix check` on a warm build is about 26 s (01f section 9). Putting
  either in `mix check` would make the ordinary local gate twenty times slower,
  and the first thing anyone would do is stop running it.

CI is the right home for the runtime, and they are already there. What CI cannot
supply until the owner unblocks it is a run.

### What this unit added instead

Two tests in `test/aurora_meter/ci_contract_test.exs`, which `mix check` runs on
every invocation in both packages, refusing the two silent ways a leg stops being
watched:

- `I20 every optional-dependency leg is in the matrix, and every one of them
  blocks` fails if `headless`, `plug_only` or `liveview-1.0` is deleted from the
  workflow, and fails if any leg is marked `experimental: "yes"`, which is this
  workflow's spelling of `continue-on-error`.
- `I20 every AURORA_ switch a leg sets is one mix.exs actually reads` fails if
  the workflow sets a switch `mix.exs` never reads, which is how a leg comes to
  resolve the ordinary dependency set while claiming not to. It fails open and
  silently otherwise, which is the worst failure shape there is.

**Both were watched failing before they were trusted passing** (X325).
`tmp/v1/09b-ci-control.sh` induces all three defects for real against the file,
restoring it from a sha256 snapshot on an EXIT trap:

| Induced | Result | What it said |
|---|---|---|
| nothing | 10 passed | |
| the `plug_only` leg deleted | 9/10 | "the plug_only leg is not in .github/workflows/ci.yml" |
| `headless` marked `experimental: "yes"` | 9/10 | "these legs are non-blocking: [\"headless\"]" |
| `AURORA_NO_SUCH_THING` set in the workflow | 9/10 | "sets AURORA_NO_SUCH_THING and mix.exs never reads it" |
| restored | 10 passed | sha256 identical, `db8183d950212e3d4df1a58822bf2c63a977db747b752ccbaa9aac58406cdd61` |

The second control found a defect in the detector itself: the first version of
the non-blocking check used one regex spanning `- leg:` to `experimental: "yes"`,
which is not lazy enough to stay inside one matrix entry. It failed for the right
reason and **named the wrong leg** (`["minimum"]` when `headless` was the one
flipped). It now splits per leg. A control that had only asserted "the test
fails" would have shipped that.

### What is still not watched, and who can fix it

Nothing here makes CI run, and nothing here puts the headless leg in the path of
a wave gate. Two things would, neither of them this unit's to do:

1. **The owner unblocking CI.** Until the workflow runs, every leg in it is a
   description. 01f section 10 has the detail.
2. **`scripts/v1/verify.sh --profile gate` calling the `headless` profile**, or
   the wave gate calling both profiles in turn. The runner already has the
   profile (00d built it); the gate profile does not reach it. That is a change
   to 00d's file and to what a wave gate means, so it is recorded here and named
   in this unit's report rather than made.

## What the legs did to the working tree

`git status --porcelain` before and after all three, and `sha256sum mix.lock`
before and after. The lock file is byte identical. The porcelain differs by
exactly two lines, both this unit's own work and neither written by a leg: the
`.gitignore` entry added for `_build_legs/` and the disappearance of that
directory from the untracked list. The `headless` and `plug_only` legs run in a
`tar` copy of the tree precisely so that removing dependencies cannot rewrite the
committed `mix.lock` (01f's rule), and `liveview_10` runs in place because
`mix.exs` sends it to a lock file outside the tree.

Nothing here was restored with `git checkout --`. It reverts tracked files to
`HEAD`, which in a wave where another unit is working uncommitted in the same
tree takes their work with it, and it fails silently on untracked paths
(X326). The legs never edit the tree; they measure it, and print both digests.
