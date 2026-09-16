# 09a: the optional-dependency legs

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.
Runner: `tmp/v1/09a/legs.sh`, through the lane lock, each leg into its own
`MIX_BUILD_ROOT` so `_build/test` is never left partial for the agent working
beside this one.
Raw logs: `logs/09a-leg-headless.log`, `logs/09a-leg-plug-only.log`.

## 1. The finding that changed what these legs have to prove (X331)

**`plug` was already in the resolved tree before this unit declared it.**
`mix.lock` carries `plug 1.20.3`, pulled in by
`phoenix_live_view -> phoenix -> {:plug, "~> 1.14", optional: false}`. The build
document says "There is no `plug` dependency of any kind in core", which is true
of `mix.exs` and false of the build.

Two consequences:

  * `AuroraMeter.Plug.EnsureEntitled`'s `Code.ensure_loaded?(Plug.Conn)` guard
    would have been open on every ordinary build whether or not `mix.exs`
    declared anything, so the declaration is not decoration but it is also not
    what makes the module compile.
  * The only pre-existing leg that removes `plug` is `AURORA_HEADLESS`, which
    removes seven other things at the same time. A leg like that can say "the
    module is absent" but cannot say anything about **the plug specifically**,
    which is the X327 objection in the form X331 describes.

So this unit adds a second switch.

## 2. The switches, after this unit

| Switch | Removes | Leaves |
|---|---|---|
| `AURORA_HEADLESS=1` | every optional declaration | nothing optional |
| `AURORA_NO_METRICS=1` | `telemetry_metrics` **and** `phoenix_live_dashboard` (the dashboard requires the metrics package) | the rest |
| `AURORA_NO_DASHBOARD=1` | `phoenix_live_dashboard` | the rest |
| `AURORA_NO_OTEL=1` | `opentelemetry_api` and the test-only SDK | the rest |
| **`AURORA_NO_LIVEVIEW=1`** (new) | `phoenix_live_view`, `phoenix_html` **and** `phoenix_live_dashboard` | **`plug`**, `oban`, `igniter`, `telemetry_metrics`, the OpenTelemetry pair |

`AURORA_NO_LIVEVIEW` removes the dashboard for X331's reason exactly:
`phoenix_live_dashboard 0.8.7` declares
`{:phoenix_live_view, "~> 0.19 or ~> 1.0", optional: false}`, so leaving it
declared would pull LiveView straight back in and the switch named for removing
LiveView would remove nothing.

It is a real host configuration, not a test fixture: an API-only Phoenix
application that has `Plug.Conn` and mounts `AuroraMeter.Plug.EnsureEntitled` and
runs no LiveView at all.

The narrowness is **asserted by name**, not claimed, in
`AuroraMeter.OptionalIntegrationsTest` /
`test I20 AURORA_NO_LIVEVIEW removes the LiveView pair and the dashboard, and nothing else`.

## 3. The two legs, as run

`mix.lock` sha256 was `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0`
before and after **every** leg. No leg rewrote the lock, which matters because a
leg that did would change what every other leg resolves. `plug 1.20.3` already
satisfies `~> 1.15`, so declaring it required no resolution.

### `plug_only` (`AURORA_NO_LIVEVIEW=1`)

Applications in the build, probed **after** the compile (see section 7):

```
  plug                     PRESENT
  phoenix_live_view        absent
  phoenix_html             absent
  phoenix_live_dashboard   absent
  phoenix                  absent
  oban                     PRESENT
  igniter                  PRESENT
  telemetry_metrics        PRESENT
  aurora_meter             PRESENT
```

`mix compile --force --warnings-as-errors` exit 0.

**The first run of this leg found a defect outside `mix.exs`, and the write-up of
it was wrong before it was right.** The run reported
`Result: 2015/2047 passed`, with 30 failures in `Mix.Tasks.AuroraMeter.InstallTest`
and two `AuroraMeter.CorrectnessIndexTest` reports of its unindexed tests. Build
unit 09b was editing exactly those files in this same tree at the time, so this
evidence file first recorded them as 09b's in-flight work, which is the
comfortable reading and was not the true one.

The cause was this leg. `.formatter.exs` named `phoenix_live_view` in
`import_deps` unconditionally, and `mix format` **raises** when an
`import_deps` entry is not in the dependency tree for the current environment.
That is not only `mix format`: Sourceror reads the project's formatter
configuration on its way to printing an edit, so `mix aurora_meter.install`
raised `Unknown dependency :phoenix_live_view given to :import_deps` and took
thirty of its own tests with it. `Phoenix.LiveView.HTMLFormatter` in `plugins`
is the same claim in the same file.

`.formatter.exs` now branches on `AURORA_HEADLESS` and `AURORA_NO_LIVEVIEW`. The
fix was made by build unit 09b, working in the same tree, and is attributed to
both units in the file's own comment.

**The general shape is X331's, one file further out than X331 looked**: a switch
that removes a dependency has to remove every claim that depends on it, and a
claim in a configuration file is exactly as real as one in `mix.exs`. The
headless leg had the same latent defect and never showed it, because
`AURORA_HEADLESS` also removes Igniter, so nothing on that leg ever asked
Sourceror to print anything. `plug_only` is the first build in this repository
to have Igniter present and LiveView absent.

After that fix, this leg is **green**:
`Result: 2052 passed (80 doctests, 20 properties, 1952 tests), 8 excluded`,
`test exit=0`, `mix.lock UNCHANGED`. Log: `logs/09a-leg-plug-only.log`.

What this leg proves that no other leg could:

  * `AuroraMeter.Plug.EnsureEntitled` compiles and answers with `Plug` present
    and LiveView absent.
  * `AuroraMeter.LiveView`'s unguarded half **works**, not merely exists:
    `subscribe/1`, `subscribe/2`, `topics/1` and `unsubscribe/2` are called and
    asserted on this leg, because `test/aurora_meter/live_view_test.exs` is
    guarded on `Phoenix.LiveView` and does not compile here.
  * `on_mount/4`, `switch_tenant/2` and `handle_usage/2` are **not** exported.

### `headless` (`AURORA_HEADLESS=1`)

```
  plug                     absent
  phoenix_live_view        absent
  phoenix_html             absent
  phoenix_live_dashboard   absent
  phoenix                  absent
  oban                     absent
  igniter                  absent
  telemetry_metrics        absent
  aurora_meter             PRESENT
```

`mix compile --force --warnings-as-errors` exit 0.
`mix test --include headless`:
**`Result: 1898 passed (76 doctests, 21 properties, 1801 tests)`**, `test exit=0`,
`mix.lock UNCHANGED`.

An earlier run of this leg had 10 failures, of which 2 were this unit's (two
switch-interaction defects in assertions this unit wrote, section 6's shape one
more time), 2 were pre-existing (section 6), 3 were build unit 09b's in-flight
install work and 1 was a property flake that did not reproduce. All are
accounted for above or fixed.

Acceptance criteria 9 and 10 are asserted here by
`AuroraMeter.HeadlessTest`:

  * `test I20 AuroraMeter.Plug.EnsureEntitled is not compiled without Plug`,
    which also asserts `:plug` is not in `Application.loaded_applications/0`, so
    the guard is a fact about the resolved tree rather than about which
    dependency happened to carry it;
  * `test I20 AuroraMeter.LiveView.subscribe/1 works with no Phoenix.LiveView loaded`,
    which subscribes, reads `topics/1`, tracks, broadcasts, receives
    `{:aurora_meter, :usage, %{tenant_key: ^tenant, value: 2}}`, unsubscribes,
    and then refutes the four guarded functions.

## 4. Every absence assertion is paired with a positive control

Criterion 10 could be satisfied by a bare `refute` on one leg, and that is the
shape the coordinator warned about: 09b asserts the same module is undefined on
its headless leg, and that assertion passed vacuously for as long as the module
did not exist. Every assertion this unit adds is written as an **equality against
its own dependency**, so it is a positive control on every other leg:

```elixir
assert Code.ensure_loaded?(AuroraMeter.Plug.EnsureEntitled) == Code.ensure_loaded?(Plug.Conn)
```

On an ordinary build both sides are true and the module must exist; on the
headless leg both are false. The day the module stops compiling for an unrelated
reason, this fails everywhere rather than passing quietly on the one leg that
only ever asserts an absence.

## 5. Two guards that encoded "an optional dependency guards a whole module"

`AuroraMeter.LiveView` is the first module in this package that is **always
compiled** and puts only *some* of its functions behind an optional-dependency
guard. Every previous case is a whole module. Two suite guards had the old
assumption built in, and the `plug_only` leg is what found them:

| Guard | What it asked | What it should ask |
|---|---|---|
| `ApiInventoryTest` / `A01 every function listed in docs/api.md exists` | skip an `optional-dep` row when its **module** is absent | skip it when the **dependency it names** is absent (`skip_absent_optional?/1`) |
| `ApiInventoryTest` / `A01 each optional-dependency row is present exactly when ITS OWN dependency is` | compare `module_present?/1` with `dependency_present?/1` | compare `exported?/3` with `dependency_present?/1` |
| `DocExamplesTest` / `every AuroraMeter function a block calls is exported` | had no concept of a guarded function at all | `optional_function_and_absent?/2`, a **named list** of the four guarded functions, so a typo in `docs/phoenix.md` still fails on every leg |

The narrowness of the new skips is asserted in
`DocExamplesTest` / `a guide may name an optional module, and the skip applies only when the dependency is really absent`,
both directions, plus two `refute`s that a non-guarded function on the same
module and a guarded name on a different module are never excused.

## 6. Two pre-existing failures the headless leg had, which are not this unit's

Both were found by running the leg and both are in code this unit did not write
(`git diff` on those files shows no change from this unit at those lines).

  * **`AuroraMeter.OptionalIntegrationsTest` / `test I20 AURORA_NO_OTEL removes the OpenTelemetry pair and nothing else`.**
    Its `else` branch read `assert Code.ensure_loaded?(:otel_tracer)`.
    `AURORA_HEADLESS` removes the OpenTelemetry pair too, so on the headless leg
    the `if` branch does not run and the `else` branch is wrong. This is
    `open-findings.md` X337's shape, in the file X337 was written about, one
    switch later. Fixed here to `== not headless?()` because it stands directly
    in acceptance criterion 9's path.
  * **`AuroraMeter.ApiInventoryTest` / `A01 every module listed in docs/api.md exists`**, on
    `AuroraMeter.LiveDashboard.View`. `view.ex` opens with
    `if Code.ensure_loaded?(Phoenix.Component) do`, so it does not exist on any
    build without LiveView, and its `docs/api.md` row named no dependency. The
    **internal** table has two columns and no Class cell, so a row in it can
    never carry the `optional-dep` tag, which is why the existing skip could not
    express this. Fixed by naming the dependency in the row and by teaching the
    module test `skip_absent_dependency?/1`.

Both had been red at HEAD since 08b landed them, and nothing said so because the
legs are not part of `mix check`: `open-findings.md` X246 records exactly that
mechanism for `docs/operations/scheduler.md` and the headless leg.

## 6a. A handoff, not a change: `AURORA_NO_LIVEVIEW` is not in CI

`.github/workflows/ci.yml` gains no `plug_only` leg from this unit.
`execution-waves.md` puts 09a and 09b in the same wave, 09b owns the CI matrix
and the `--check-support` reporting, and 09b was editing that file in this tree
while this unit ran. Adding a matrix entry to a file another agent is rewriting
is how a merge loses one of them.

What 09b needs, and what this unit verified locally:

```yaml
- leg: plug_only
  elixir: "1.18.5"
  otp: "27.3.4.17"
  liveview: ""
  unlock: "no"
  headless: "no"
  # plus: AURORA_NO_LIVEVIEW: ${{ matrix.no_liveview == 'yes' && '1' || '' }}
```

The leg runs plain `mix test` (not `--include headless`: the absence tests are
tagged `:headless` and their `setup` refuses to run without `AURORA_HEADLESS=1`).
It resolves into the committed `mix.lock` without rewriting it, verified by
sha256 on both runs.

## 7. A defect in this unit's own probe, and why it is written up

The first `plug_only` run printed:

```
  plug                     absent
  phoenix_live_view        absent
  ...
```

which is the answer the leg was hoping for on four of the eight rows, and it was
wrong on all eight: the loop ran **before** `mix compile`, so
`$MIX_BUILD_ROOT/test/lib` did not exist yet and every `[ -d ... ]` was false. A
detector that can see nothing reports whatever its default is, and here the
default happened to look like success (X325).

The probe now runs after the compile, refuses to report at all if the build
directory is missing, and carries a positive control of its own: `aurora_meter`
must be in the list, and the leg exits 3 if it is not.
