# 09c: the sample application, run

Build unit 09c, the MIT reference application at
`examples/aurora_meter_example_ai/`. Core at `0.5.0`, branch `aurorameter-v1`,
HEAD `0b6b48c` at the time of the runs below.

## 1. What it was built from

| Tool | Version |
|---|---|
| Elixir | 1.20.1 (compiled with Erlang/OTP 29) |
| Erlang/OTP | 29 (erts 17.0.1) |
| `phx_new` archive | `phx_new-1.8.13` |
| Postgres | the package's own container on port 5490 |

Generated with, in this order:

```
mix phx.new examples/aurora_meter_example_ai --app aurora_meter_example_ai \
  --module AuroraMeterExampleAi --no-install --no-agents-md --no-version-check
mix phx.gen.auth Accounts User users --live
mix aurora_meter.install --repo AuroraMeterExampleAi.Repo \
  --pubsub AuroraMeterExampleAi.PubSub --plans AuroraMeterExampleAi.Plans \
  --feature-policy deny --events-source tokens:events
```

The Aurora Meter configuration block, the supervision child and
`priv/repo/migrations/20260916205902_add_aurora_meter.exs` in this tree are that
installer's output, unedited except for the four keys named in a comment in
`config/config.exs` and the position of the `AuroraMeter` child (see
`09c-library-findings.md`, finding 3).

## 2. Resolved dependency versions

From the sample's committed `mix.lock`:

| Package | Version |
|---|---|
| `phoenix` | 1.8.14 |
| `phoenix_live_view` | 1.2.12 |
| `phoenix_html` | 4.3.0 |
| `phoenix_live_dashboard` | 0.8.7 |
| `ecto` | 3.13.x |
| `ecto_sql` | 3.13.x |
| `postgrex` | 0.22.4 |
| `bandit` | 1.12.x |
| `lazy_html` | test only, used for the text-level page scans |
| `igniter` | 0.8.x, dev and test only, for `mix aurora_meter.install` |

`phx.new 1.8.13` generates `{:phoenix_live_view, "~> 1.2.0"}`, which satisfies
core's `~> 1.0`. The sample therefore runs on LiveView 1.2 against a library
that declares 1.0 and up, which is the combination `09b` narrowed the
requirement to.

## 3. `mix test`

```
$ DB_PORT=5490 mix test --seed 0
Running ExUnit with seed: 0, max_cases: 48
Finished in 3.9 seconds (0.4s async, 3.4s sync)
Result: 222 passed (4 doctests, 218 tests)
```

Database `aurora_meter_example_ai_test`, on the same Postgres container as the
library's own suite. No environment variable other than `DB_PORT`, no network
access, no credential, no provider.

### Eight seeds

`tmp/v1/09c-runcount.sh`, which decides each run positively: a run is clean only
if its `Result:` line contains `" passed"` and contains no `/`. An absent line
is a failure, never a pass (X325), and a ratio present is a failure (X350).

```
run 1 seed 802997  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 2 seed 355809  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 3 seed 959886  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 4 seed 785856  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 5 seed 47976   Result: 222 passed (4 doctests, 218 tests)  rc=0
run 6 seed 975305  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 7 seed 733154  Result: 222 passed (4 doctests, 218 tests)  rc=0
run 8 seed 818816  Result: 222 passed (4 doctests, 218 tests)  rc=0

clean=8 dirty=0 of 8
```

Logs at `tmp/v1/09c/runcount/run-*.log`.

### The counter was watched failing first

`tmp/v1/09c-runcount-control.sh` plants one failing test, runs the counter once,
removes the plant and verifies by digest that the test tree listing is exactly
as it was. No git is used for the restore (X326); the whole cycle runs under
`mixlane.sh hold core` (X371).

```
=== planted one failing test; the counter must report FAILURE ===
run 1 seed 7786  Result: 222/223 passed (4/4 doctests, 218/219 tests)  -> FAILURE
clean=0 dirty=1 of 1
counter exit=1
CONTROL PASSED: the counter can see a failure
restore verified: the test tree listing digest is unchanged
  (1ffe7fc90ef531a4870178b7b1864501a6b46893ba50db8b993939fe7481cb0c)
```

## 4. Compilation and formatting

```
$ mix compile --warnings-as-errors --force     # dev:  rc=0
$ MIX_ENV=test mix compile --warnings-as-errors --force   # rc=0
$ mix format --check-formatted                 # rc=0
```

Two warnings appear while compiling the **dependency** `aurora_meter` in this
host, and they are the library's, not the sample's. They are finding 2 in
`09c-library-findings.md`.

## 5. The library's own gate

Run step by step rather than as `mix check`, because a neighbouring unit (repair
unit R4) had core's `lib/` and `test/` open at the time. The tree state is
recorded so a reviewer can tell what was in it.

```
 M .github/workflows/ci.yml        (this unit)
 M .gitignore                      (this unit)
 M README.md                       (this unit)
 M docs/evidence/v1/phase-08/runs/smoke/flush_*.json   (R4)
 M lib/aurora_meter/broadcaster.ex                     (R4)
 M lib/aurora_meter/storage/ecto.ex                    (R4)
 M lib/aurora_meter/supervisor.ex                      (R4)
 M test/aurora_meter/bench/report_test.exs             (R4)
 M test/aurora_meter/kill_test.exs                     (R4)
?? test/aurora_meter/broadcaster_test.exs              (R4)
?? test/aurora_meter/packaging_test.exs                (this unit)
?? test/aurora_meter/storage_bind_ceiling_test.exs     (R4)
```

| Step | Result |
|---|---|
| `mix format --check-formatted test/aurora_meter/packaging_test.exs` | rc=0 |
| `mix compile --warnings-as-errors --force` | rc=0 |
| `mix credo --strict` | rc=4, **one** issue, in `test/aurora_meter/storage_bind_ceiling_test.exs:235`, which is R4's untracked file |
| `mix test --seed 0` | **2151 passed** (81 doctests, 22 properties, 2048 tests), 8 excluded, 0 failures |
| `mix dialyzer` | rc=0, `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` |
| `mix test test/aurora_meter/packaging_test.exs` | 6 passed |

**Two honest caveats about that gate.**

A project-wide `mix format --check-formatted` is **red**, and the only file it
names is `test/aurora_meter/storage_bind_ceiling_test.exs`, which is untracked
and is not this unit's. Formatting a file this unit did not change is what the
repository rule forbids, so it was left alone and reported instead.

The suite was at **2133** when this unit started and is at **2151**. Six of the
eighteen are this unit's `packaging_test.exs`; the other twelve are R4's two new
test files. The number cannot be attributed to this unit alone while a
neighbour has the tree open, and that is stated rather than papered over.

## 6. Run in a browser

`PORT=4021 mix phx.server`, against the dev database after `mix ecto.reset` and
`mix sample.seed`. Every figure below was read off the rendered page.

| What was done | What was seen |
|---|---|
| `/` unauthenticated | "There is no AI here and there is no payment here", and the instruction to run `mix sample.seed` |
| logged in as `owner@globex.example.com` | `/generate` shows Globex Studio on the studio plan, `images 3 / 200`, `tokens 561 / 2000000`, available `$31.99` |
| submitted one **image** generation | "Generated.", `Estimated $0.00047, settled $0.00031 for 7 prompt and 24 completion tokens`, meter `images 4 / 200`, tokens `592` |
| a **second tab** on `/generate`, never touched | moved from `images 3 / 200` to `images 4 / 200` and `tokens 561` to `592` with no reload, from the broadcast alone |
| submitted `fail: on purpose` | "The work failed: the simulated provider refused: fail: on purpose. Nothing was charged and the quota was given back." Images stayed at 4, tokens at 592, available unchanged |
| `/ops` | conservation `identity holds: yes`, four lots in spend order, thirteen consume allocations all from the earliest-expiring promotional lot, `image outbox rows 0` |

The second tab moving is the live-update claim, and it only works because
`GenerateLive` passes a changing attribute into `AuroraMeter.Components.usage_meter/1`.
That is finding 4 in `09c-library-findings.md`, and
`test/aurora_meter_example_ai_web/live/usage_meter_change_tracking_test.exs`
shows both halves.

## 7. Scripts

| Script | What it does |
|---|---|
| `tmp/v1/09c-test.sh` | the sample's suite at a given seed |
| `tmp/v1/09c-runcount.sh` | N seeds, verdict positive |
| `tmp/v1/09c-runcount-control.sh` | plants a failure, proves the counter fails, restores by digest |
| `tmp/v1/09c-core-gate.sh` | the library gate step by step |
| `tmp/v1/09c-pack.sh` | the Hex archive listing, tarball written outside the tree |
| `tmp/v1/09c-collect.sh` | the live figures the other evidence files quote |
| `tmp/v1/09c-lots-probe2.sh` | the credit lot reachability probe (finding 5) |
| `tmp/v1/09c-dryrun-fresh.sh` | the installer dry-run reproduction (finding 1) |
| `tmp/v1/09c-plans-nesting.sh` | the generated plans module probe (finding 1) |
