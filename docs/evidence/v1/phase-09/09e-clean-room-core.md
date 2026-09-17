# 09e: the clean-room core profile (G09 bullet 1)

Build unit 09e, 2026-09-17. `scripts/v1/package-smoke.sh --profile core`.

G09 bullet 1: "Clean-room core profile resolves from built or registry artifacts
with no sibling checkout, no Pro source, no external credentials and no hidden
local config."

Three legs were run. Two pass, one fails, and the one that fails is the most
important result in this file.

| Leg | Artifact | Run | Result |
|---|---|---|---|
| A: built artifact | `aurora_meter-0.5.0.provisional.tar`, sha256 `200fb12305779ff8ff8a71297bf6ab4592f5cc87710f2628443f392602d60a62` | `package-smoke-20260917T050830Z-eaefb3` | **pass** |
| B: built artifact plus the sample's suite | the same archive | `package-smoke-20260917T045250Z-2b9c68` | fail, at the sample's own suite, 265 of 266 |
| C: registry artifact, no credential | `aurora_meter` 0.4.0 from hex.pm | `package-smoke-20260917T045424Z-93bf68` | **fail**, at the first entitlement check |

## Isolation, assertion by assertion

Taken from `logs/smoke.isolation.log` of leg A. Every line is the runner's own
output, not a restatement.

**1. No sibling checkout is reachable.**

```
consumer: .../tmp/v1/package-smoke-20260917T050830Z-eaefb3/consumer-package-smoke-...
ok: no aurora_meter aurora_meter_pro directory in any parent, and the consumer is
    outside product-workspaces/
```

The consumer lives under the storefront's `tmp/v1/`, three levels of parent are
checked, and the check is `v1_no_sibling_checkout` from `scripts/v1/lib/checks.sh`,
the shipped function. Self-test case 21c plants
`tmp/v1/selftest/.../runs/aurora_meter` and the same step fails naming that path;
with the plant removed it answers ok. The control was watched failing.

**2. No cache from this machine can satisfy the resolution.**

```
MIX_HOME=.../package-smoke-<runid>/mix-home
HEX_HOME=.../package-smoke-<runid>/hex-home
operator HOME=/home/liamk
packages cached in this HEX_HOME before the resolution: 0
```

Both are created empty for the run. Neither is under `~/.mix` or `~/.hex`, and
the run asserts that rather than arranging it.

**3. The child environment is exactly the declared allowlist.**

```
expected: HEX_HOME HOME LANG MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV MIX_HOME PATH
          TERM V1_CONSUMER_DB V1_DB_HOST V1_DB_PORT
actual:   HEX_HOME HOME LANG MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV MIX_HOME PATH
          TERM V1_CONSUMER_DB V1_DB_HOST V1_DB_PORT
ok
```

Built with `env -i` plus that list. Self-test case 21g shadows `env` with a
wrapper that slips one extra variable into every `env -i`; the same step then
prints `FAIL: the child environment is not the allowlist`, names
`V1_SELFTEST_SMUGGLED`, and the step's status in `status.json` is `fail`. The
comparison is not a constant.

**4. No credential crosses into the child.** `ok: none`. Before any of that, the
profile refuses to start at all if `HEX_API_KEY`, or any `AURORA_` or `STRIPE_`
variable, is in its own environment, naming the variable rather than unsetting
it. `--registry-auth-env` is refused outright: the core profile takes no
credential. Self-tested in case 21d, four variables, each refused by name and
never with its value printed.

**5. The operator's own Hex configuration is untouched.**
`ok: ~/.hex/hex.config does not mention phxtemplates`.

**6. Nothing was written into either package repository.** `git status
--porcelain` in core and in Pro, taken immediately before and immediately after
leg A with nothing else of this unit's in flight:

```
core working tree difference:  none
pro working tree difference:   none
aurora_meter/tmp:      0 entries modified in the last two hours
aurora_meter_pro/tmp:  0 entries modified in the last two hours
```

(An earlier whole-run comparison did show a difference, and it was two other
things: this unit's own evidence files, which the unit writes and no script
does, and a neighbouring build unit editing `lib/aurora_meter/credits/lot_migration.ex`
while the runs were in flight. The bracketed single-run check above is the one
to read.)

**7. Only this run's own databases.** One database was created,
`aurora_v1_consumer_eaefb3`, matching `^aurora_v1_[a-z0-9]+_[0-9a-f]{6}$`, and it
was dropped. The only difference in the server's database list across the
bracketed run was `aurora_v1_25_4039952`, created by something else on the shared
5490 container while this run was in flight, and which this run neither created
nor touched.

## Leg A: the built artifact

**Archive metadata.**

```
version matches: 0.5.0
contents (126 entries)
no test/, demo/, priv/plts/, .env or erl_crash.dump in the archive
licence present: LICENSE
core has no private registry requirement
source_ref v0.5.0 has no tag in product-workspaces/aurora_meter. RECORDED, NOT
FAILED: the manifest marks this archive provisional ... A candidate or registry
artifact with no tag still fails this check.
no high signal secret findings in the extracted tree
```

**The file list is exactly `mix.exs` `package.files`**, which is a set
comparison and not only a forbidden-prefix check:

```
declared in mix.exs package.files (7 entries):
.formatter.exs  CHANGELOG.md  LICENSE  NOTICE.md  README.md  lib  mix.exs

top-level entries actually in the archive:
.formatter.exs  CHANGELOG.md  LICENSE  NOTICE.md  README.md  lib  mix.exs

the archive ships exactly the declared set
no examples/, demo/, docs/, priv/ or test/ path in the archive
```

Self-test 21b runs the same check against an archive carrying `priv/` and
`docs/` and it prints `PRESENT BUT NOT DECLARED` and fails.

**The resolved tree (I20).** The consumer is a plain `mix new --sup`
application, not a Phoenix one. It declares `ecto_sql`, `postgrex`,
`phoenix_pubsub` and `igniter` (dev only) and nothing else. Read back from the
tree afterwards:

```
I20: the clean-room core consumer must resolve no LiveView, no Plug, no Oban
  ok: no phoenix_live_view
  ok: no plug
  ok: no oban
  ok: no telemetry_metrics

no aurora_meter_pro anywhere in the resolution
  ok: not under deps/, not in mix.exs, not in mix.lock
```

`mix deps.tree` in the same log shows `aurora_meter` resolving from the unpacked
archive path and its own requirements: `ecto_sql`, `igniter`, `jason`,
`nimble_options`, `phoenix_pubsub`, `postgrex`, `telemetry`. That is the free
package's whole surface with no optional dependency in it.

**The installer.** `mix aurora_meter.install --repo AuroraV1Consumer.Repo --yes`,
run in a host that never had it before. It wrote `config/config.exs` (repo,
pubsub, plans, `undeclared_feature_policy`), `lib/aurora_v1_consumer/plans.ex`,
the supervision child, and `priv/repo/migrations/<ts>_add_aurora_meter.exs`.

The step does not trust `$?`. X366 records that every Igniter refusal in both
packages wrote nothing and exited 0 until repair unit R5, three days ago, so the
step asks the tree: the plans module exists, the configuration names it, the
policy key is there, and a migration matching `*_aurora_meter*.exs` was
generated. If the command returned 0 with any of those missing the run fails
with `required_step_skipped`, which is self-tested.

**Migrate, then boot.** `mix ecto.migrate` ran the generated file, and then
`mix run` started the application and executed the proof:

```
first counter: usage=1
hard quota: refused past the limit
SMOKE_OK
```

X374's lesson is the reason the last line exists: a generator's acceptance
criteria must include running its output, because every file-content assertion
in the world passes on a module with the wrong name.

**Credential scan.** No credential was read by this leg, so there is no literal
value to search for, and the generic shape scan over everything the run produced
found nothing. `v1.secret_sweep` (gitleaks over the whole run directory with the
rule set that does not allowlist `tmp/`) passed.

## Leg B: the sample's suite, built from the archive (G09 bullet 6)

The sample was copied out of `product-workspaces/aurora_meter/examples/aurora_meter_example_ai`
into the run directory, without `deps`, `_build` or `tmp`, and its
`{:aurora_meter, path: "../.."}` was rewritten to the unpacked archive. The copy
is asserted to carry no `path: "../.."` afterwards. Its test database is a
disposable `aurora_v1_sample_<runid>`.

**Result: 265 of 266 passed** (4 of 4 doctests, 261 of 262 tests), resolving and
compiling from the archive rather than from the working tree.

The single failure is `AuroraMeterExampleAi.ProfileTest`, at
`test/aurora_meter_example_ai/profile_test.exs:174`:

```
assert mix_exs =~ ~s|{:aurora_meter, path: "../.."}|
```

**The sample carries a test that asserts it is built from the working tree.** So
the sample cannot pass its own suite when built from a package archive, which is
the thing G09 bullet 6 requires. Two units' requirements contradict, and neither
is wrong on its own: 09c's guard exists so the sample does not quietly start
resolving a published package, and G09 bullet 6 exists so a release rehearsal
tests what it ships. Filed as X422. Everything else in the sample passes from
the archive, which is the useful half of the result.

## Leg C: the published artifact, and why it is the most important line here

`--mode registry --core-version 0.4.0`, with **no credential of any kind**:
`aurora_meter` is public on hexpm and the profile refuses to accept a key.

The resolution worked, the compile worked, the installer ran and exited 0, the
migration ran, and then:

```
first counter: usage=1
** (UndefinedFunctionError) function AuroraV1Consumer.Plans.__aurora_plans__/0
   is undefined or private
    (aurora_meter 0.4.0) lib/aurora_meter/plans.ex:163: AuroraMeter.Plans.get/1
    (aurora_meter 0.4.0) lib/aurora_meter/entitlements.ex:68: AuroraMeter.Entitlements.plan/1
```

That is X374, the nested-module defect repair unit R5 fixed in the working tree,
**reproduced against the tarball hex.pm is serving today**. It was reproduced
twice independently: here, in a bare `mix new` consumer, and by
`scripts/v1/quickstart.sh --source archive` against the published 0.4.0 tarball
in a full `mix phx.new` application, at the same line.

X374 says the installer "produces an application that cannot boot". At 0.4.0
that is not quite what happens, and the difference matters: **the application
boots, subscribes, meters a counter and flushes it, and raises on the first
entitlement check.** Core 0.5.0 added the boot-time `ensure_exports!` check that
turns the same defect into an immediate, well-explained refusal at start-up;
0.4.0 has no such check, so it looks like it works right up until the first
`with_quota/3`. Filed as X419.

The practical consequence for the release runbook: **the currently published
core cannot complete its own documented installation**, and the repair is
already in the working tree. `11c`'s post-publication rerun is the check that
catches this class of thing, and it has now been rehearsed and shown to
discriminate.

## Run index

| Run | Command |
|---|---|
| `package-smoke-20260917T050830Z-eaefb3` | `--profile core --mode local --core-archive tmp/v1/09e/artifacts/aurora_meter-0.5.0.provisional.tar --core-version 0.5.0 --manifest tmp/v1/09e/artifacts/09e-artifacts.json` |
| `package-smoke-20260917T045250Z-2b9c68` | the same plus `--examples all --sample-dir product-workspaces/aurora_meter/examples/aurora_meter_example_ai` |
| `package-smoke-20260917T045424Z-93bf68` | `--profile core --mode registry --core-version 0.4.0` |
| `quickstart-20260917T050647Z-bf06f7` | `quickstart.sh --source archive --archive tmp/v1/09e/artifacts/aurora_meter-0.4.0.published.tar --manifest ...` |
