# Phase 00 evidence: the core baseline gate (`aurora_meter`)

Build unit **00b**, wave 0. V1 task **00.04**. Binding design:
`docs/v1/build-plans/phase-00/00b-baseline-checks-and-blockers.md` in the
storefront repository.

This is a fresh run on a named commit with a recorded toolchain, seed and exit
code. It replaces the phase-17 numbers as the baseline for phase 01. Nothing was
edited to make a step pass.

## 1. What was run, and where

| | |
|---|---|
| Repository | `aurora_meter` (`product-workspaces/aurora_meter`) |
| Branch, SHA | `main`, `cb38c3cd552a60dc059b26b859ee92a640bc8300` (`git describe`: `v0.4.0-1-gcb38c3c`, one commit past the tag) |
| Command | `scripts/v1/verify.sh --repo core --profile check` (the `check` profile runs the `v1-release.md` 18.1 sequence, with `mix check` as the verbatim alias) |
| Run id | `verify-20260914T081521Z-6b7694` |
| Run directory | storefront `tmp/v1/verify-20260914T081521Z-6b7694/` (git ignored; referenced by path and sha256, never copied) |
| Result | **pass**, exit **0** |
| UTC start, end | `2026-09-14T08:15:21Z`, `2026-09-14T08:15:46Z` (25 s wall) |
| `status.json` sha256 | `b1b530bb4a5191627be58966b32fecd8cde169b88ac0c604b972a079f2d4f988` |
| Sanitiser redactions | 0 |

Pre-run working tree (recorded as the baseline this unit asserts against, not as
a clean tree; no agent commits during a wave, `execution-waves.md` rule 6):

```
 M AGENTS.md
 M CLAUDE.md
 M plan.md
?? docs/adr/0009-durable-event-semantics.md
?? docs/adr/0010-undeclared-features-and-config-strictness.md
?? docs/adr/0011-credit-lots-and-allocations.md
?? docs/adr/0012-immutable-plan-versions.md
?? docs/adr/0013-narrow-ai-shaped-sample.md
?? docs/adr/0014-optional-integrations-stay-free.md
?? docs/adr/0015-period-contract-and-clock-seam.md
?? docs/evidence/README.md
?? docs/evidence/v1/
?? test/aurora_meter/adr_format_test.exs
```

13 paths: the 00c ADRs and pointer edits, the 00a/00c evidence directories and
the one test file 00c added. Saved as
`tmp/v1/00b/core-porcelain.baseline` (sha256
`816638a2f993e91efb30d4814e98b8fb09af14a15663c5770614f0caa47fb616`). The tree
after every 00b command is byte identical to it.

## 2. Toolchain, environment and inputs

| Item | Value |
|---|---|
| Elixir | 1.20.1 (compiled with Erlang/OTP 29) |
| Erlang/OTP | 29.0.1 (`erts-17.0.1`) |
| OS | Ubuntu 24.04.4 LTS under WSL2, kernel `6.6.87.2-microsoft-standard-WSL2` |
| Docker | server 29.4.1 |
| Test database container | `aurora-meter-pro-testdb`, image `postgres:16`, host port **5490** (the designated 5490 container, `environment.md`) |
| Postgres server version | **16.13** (`postgres (PostgreSQL) 16.13 (Debian 16.13-1.pgdg13+1)`) |
| Test database | `aurora_meter_test`, created and migrated by `mix test.setup` |
| Dialyzer PLT | `priv/plts/dialyxir_erlang-29.0.1_elixir-1.20.1_deps-test.plt` (warm: built 2026-09-07 on this machine; the foreign `29.0.6_1.20.4` PLT is not used here) |
| `mix.lock` sha256 | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3`, unchanged by this run (`git diff -- mix.lock` is empty) |

**Warm start.** 00d ran a full core gate an hour earlier
(`verify-20260914T075944Z-9c9862`, profile `gate`, seed 424242, exit 0,
`status.json` sha256
`cc98f6783bbaafd68cc9a96474069b0d578f592f54e23a8fe9c5d1b7722f3f31`) which
created `aurora_meter_test`, compiled `_build` and warmed the PLT. Every duration
below is therefore a warm figure. No duration here is evidence of first-build
cost, and none should be quoted as one.

**Not proven by this run.** Production Postgres is `flyio/postgres-flex` **15.6**
(finding X4); a green 16.13 run says nothing about 15. The toolchain is far above
the declared floor `~> 1.15`; no floor is claimed (D12).

## 3. Step by step, the 18.1 sequence

| Step | Command | Status | Duration | Log sha256 |
|---|---|---|---|---|
| `core.deps.get` | `mix deps.get` | pass | 1606 ms | `dd56ced1aaaade4f171c25ffe2cccb1e2f26988fb622fc80c7ef37dbc59d7989` |
| `core.test.setup` | `mix test.setup` | pass | 675 ms | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (empty; the database already existed) |
| `core.check` | `mix check` (alias) | pass | 8365 ms | `3b7c1383508fbe96595fb26f3c3af2bd8c6636184dc53dd688a2843e38705b2a` |
| `core.unlock` | `mix deps.unlock --check-unused` | pass | 541 ms | empty output |
| `core.deps.audit` | `mix deps.audit` | pass | 1224 ms | `3016e51e4eac0d421674d2128bbbdefb2924b4646e0c14a1ab034977ad73fae5` |
| `core.hex.audit` | `mix hex.audit` | pass | 971 ms | `25ce35312da15695b9ab9e466ebdba2c1460f780ca6a14e164646fee228030d6` |
| `core.hex.build` | `mix hex.build -o <run dir>/core-hex.tar` | pass | 543 ms | `a1aa588612dd2992aa017c9d2d8ba24600864e87ca08fb3c52ce8ff585a643ad` |
| `core.clean_tree` | working tree state | recorded (optional) | 8 ms | `62e342fae1713c08cc894f6b7f0fc5fafde864ef6cb3acb19553864f705da35a` |
| `core.secrets` | gitleaks over the repository | pass | 9307 ms | `25afc3b6fcef0c5a7a5b735b1303cb38480ad56c605376245ac28f4bf707ba87` |
| `core.tree_unchanged` | porcelain before versus after | pass | 6 ms | `8035b9cac1a79f17f40b9341c9f4954c350a3b1d0dfc5e3bc721b30e9fc41d4f` |
| `v1.secret_sweep` | gitleaks over the run directory | pass | | |

Inside the `check` alias, in alias order:

| Alias step | Result |
|---|---|
| `format --check-formatted` | pass, no output |
| `compile --warnings-as-errors --force` | pass |
| `credo --strict` | pass: `516 mods/funs, found no issues` |
| `dialyzer` | pass: **`Total errors: 0, Skipped: 0, Unnecessary Skips: 0`**, `done in 0m3.94s`. Core declares no ignore file |
| `test` | pass: **seed 81374**, `Finished in 2.2 seconds (1.1s async, 1.0s sync)`, **`Result: 242 passed (35 doctests, 4 properties, 203 tests)`**, 0 failures, 0 skipped, 0 excluded, `max_cases: 48` |
| `docs` | pass, `View html docs at "doc/index.html"` |

`mix deps.audit`: `No vulnerabilities found.`
`mix hex.audit`: `No retired or security advisory packages found`.
`mix deps.unlock --check-unused`: exit 0 with no output (no unused lock entry).

One log line inside the test run is an expected, asserted-on error report from
the lost-response regression (I01):
`[error] AuroraMeter flush failed; the same batch will be retried: "connection lost after commit; a second node flushed before recovery"`.

## 4. Fresh counts against the historical record

| | Fresh (this run) | Historical |
|---|---|---|
| Total | **242 passed, 0 failures** | 234 |
| Doctests | 35 | 35 |
| Properties | 4 | 4 |
| Tests | 203 | 195 |
| SHA | `cb38c3c` | **not recorded** |
| Seed | 81374 | **not recorded** |
| Toolchain | Elixir 1.20.1 / OTP 29.0.1 | **not recorded** |
| Date, host | 2026-09-14, this WSL machine | **not recorded**, host "Northdoc" |

The historical row is `docs/evidence/phase-17/release-audit.md:26-27`. It is
**historical context from another host at an unknown commit**, never current
release evidence. The delta 195 to 203 is the eight tests 00c added in
`test/aurora_meter/adr_format_test.exs`; nothing else changed.

**Failing tests: none.** No test, source, migration, CI or config file was
edited by this unit.

## 5. Named invariants exercised by this run

They passed as part of the 242; this records that they ran, not that they are
freshly proven (01a to 01e do that).

| Invariant | Test |
|---|---|
| I01 | `flush_batch_concurrency_test` (one batch, simultaneous deliveries, deltas committed once); `flusher_test` lost-response case |
| I02 | batch atomicity, same file |
| I04 | `entitlements_test` concurrency (60 concurrent `with_quota`, 50 admitted); `metering_test` property |
| I11 | `credits_concurrency_test` (20 holds, 10 admitted) |
| I19 | `mix test.setup` applies the test-repo history. That history is fictional (finding T11: core applies 1, 2, 3, 6, 4, 5), so success here says nothing about a customer upgrade path. Fixtures arrive in 11a |

## 6. The package build (I21)

`mix hex.build -o` wrote the archive into the run directory, never into the
package tree (that redirection is the fix for finding X21).

| | Built here from `cb38c3c` | Published 0.4.0 | `docs/evidence/phase-17/package-builds.json` |
|---|---|---|---|
| Tarball sha256 | `ae7cb2a2b8c72e2e2cf934837a8cbdd8c720b2b4d3f4b3847233c3497fdd02e3` | `9e38d799514685b6657f4e3cfecc64f88eea03ca6180317ce307f98c1c3c0c96` | `9e38d799...3c0c96` |
| Bytes | 81,920 | 81,920 | not recorded |
| Inner file count | 46 | 46 | 46 |
| Inner `contents.tar.gz` sha256 | `6c0dadcd2f6c594c3f0a605ec072d5cb79c57c18a48bdab370e5c0f590dd5b84` | `2a0ca1c986cd8cae59cb5ec42ef85942b1ee95290f01b71c7370cc840e12bd62` | not recorded |
| Hex `CHECKSUM` | `250B67E318E5A30C9F639D92953B474C5D139FB27AEF383D48499D80EA7DB7FC` | `589BC4E610BDD6FE00775B51222F7D184261D8812AFA0BA535221C20C94ABCFD` | not recorded |

**Verdict: not equal, and correctly so.** This unit fetched the published 0.4.0
archive again (read only, `mix hex.package fetch`, into a scratch directory with
no `mix.exs`, deleted afterwards) and compared every inner file by sha256. The
two archives differ in **exactly one file**:

```
-9d94581fa7ebcd9ca267bddb1eb31cf17ed411796033d5e98e950e4e8018d639  ./lib/aurora_meter/credits.ex   (published 0.4.0)
+095a06012fd15fa1de42ebc8b65a3a3dfd59da2c789fdf941ca8c71ea44e311b  ./lib/aurora_meter/credits.ex   (built from cb38c3c)
```

The other 45 files are identical. That is exactly the commit `cb38c3c` on top of
tag `v0.4.0` (`9ddc0d1`), whose only change is a typespec format change in
`lib/aurora_meter/credits.ex`. **11c must build from the tag, not from HEAD, when
it compares hashes.**

**Correction to inherited evidence.** 00d's `runner-first-runs.md` states that
the `hex.build` checksum "is identical to the archive 00a fetched from the
registry, so the working tree still builds the published tarball byte for byte".
It is not: `ae7cb2a2...` is the sha256 of the archive built from HEAD and
`9e38d799...` is the sha256 of the published archive. The number 00d compared is
the value `mix hex.build` prints as `Package checksum`, which is the sha256 of
the archive it just wrote, so the comparison was a value against itself. The
underlying runner behaviour is sound; only that sentence is wrong.

The tarball was hashed, its file list read, and then deleted. `ls
product-workspaces/aurora_meter/*.tar` finds nothing.

## 7. What this baseline does not establish

- Nothing about Elixir 1.15/OTP 25 or 1.18/OTP 27: the CI matrices were not run
  here (01f owns that).
- Nothing about Postgres 15 (production), or about any database other than a
  fresh `aurora_meter_test` on Postgres 16.13.
- Nothing about customer upgrade paths: the test-repo migration history is
  fictional (T11).
- No process was killed (T1); no fault injection ran (01b).
- The `docs` step of the `check` alias writes `doc/` inside the package. That
  directory is in `.gitignore:4`, so it does not appear in `git status` and the
  tree comparison above still holds, but the verbatim 18.1 sequence does write
  there. The runner's own `gate` profile redirects it with `--output`.

## 8. Handoff

- Baseline counts for phase 01: **242 passed (35 doctests, 4 properties, 203
  tests), 0 failures, seed 81374, exit 0** at `cb38c3c` on Elixir 1.20.1 / OTP
  29.0.1 with Postgres 16.13.
- Any new failure in 01a to 01e is measured against this row, not against 234.
- The blocker register is storefront `docs/evidence/v1/phase-00/blockers.md`;
  the G00 verdict is `docs/evidence/v1/phase-00/g00.md`.
