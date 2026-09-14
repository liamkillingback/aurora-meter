# aurora_meter: V1 phase 00 inventory (unit 00a)

Generated 2026-09-14T05:44:37Z by read-only inspection. No Mix task was run in
this repository by this unit, no file outside `docs/evidence/v1/` was touched,
and nothing was published, tagged, committed or deleted.

The cross-repository manifest lives in the storefront at
`docs/evidence/v1/release-manifest.md`. The full inventory, environment record,
access manifest and external-prerequisite findings live in the storefront at
`docs/evidence/v1/phase-00/`. This file holds the core package's own rows.

The legacy evidence directories in this repository (`docs/evidence/phase-00`
through `phase-07` and `phase-14` through `phase-17`) belong to the previous
programme and are untouched by V1.

## 1. Repository state

| Item | Value |
|---|---|
| Branch | `main` |
| HEAD | `cb38c3cd552a60dc059b26b859ee92a640bc8300` |
| `git describe --tags --long` | `v0.4.0-1-gcb38c3c` |
| Working tree (WSL git) | clean (`git status --porcelain` empty) |
| Last commit | 2026-09-13T11:48:54+10:00, "Format with_credits/4's spec the way 1.15 wants it too" |
| Remote | `git@github.com:liamkillingback/aurora-meter.git` (fetch and push), reachable |
| `mix.lock` sha256 | `70e0f2b8015a57f0a513263bd67753db6618afd3033145905629432736e609d3` |

HEAD is one commit past `v0.4.0`. That commit changes
`lib/aurora_meter/credits.ex` only (7 insertions, 2 deletions, a typespec
format change). **A tarball rebuilt from HEAD will therefore not match the
published 0.4.0 hash; 11c must build from the tag.**

## 2. Package and schema

| Item | Value |
|---|---|
| `@version` | `0.4.0` (`mix.exs:4`) |
| `elixir:` requirement | `~> 1.15` (`mix.exs:11`) |
| Migration `@latest` | **6** (`lib/aurora_meter/migration.ex:36`) |
| `package.files` | `lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md` (`mix.exs:87`) |
| `source_ref` | `v#{@version}` (`mix.exs:127`) |
| CHANGELOG head | `## [0.4.0] - 2026-09-11` |
| Licence | MIT, public hexpm |

The storefront's vendored copies `priv/docs/aurora-meter/README.md` and
`priv/docs/aurora-meter/CHANGELOG.md` are byte-identical to this repository's
`README.md` and `CHANGELOG.md` (`diff -q` reported no differences).

## 3. Tags

| Tag | Commit | Tagged |
|---|---|---|
| `v0.1.0` | `8ccb3eb` | 2026-07-11 |
| `v0.2.0` | `bde7a5d` | 2026-09-07 |
| `v0.3.2` | `eaf00e8` | 2026-09-08 |
| `v0.4.0` | `9ddc0d1` | 2026-09-13 |

There is no `v0.3.0` and no `v0.3.1` tag.

## 4. Registry verdicts for core versions

Queried 2026-09-14T05:45:11Z with `mix hex.info` from a scratch directory with
no `mix.exs`, so no `_build` in this repository was touched. Every query
answered; none was unavailable.

| Version | Verdict | Released | Git tag | Schema |
|---|---|---|---|---|
| 0.1.0 | **published** | 2026-07-12 | `v0.1.0` | 1 |
| 0.2.0 | **published** | 2026-09-06 | `v0.2.0` | 2 |
| 0.3.0 | **published** | 2026-09-07 | **none** | 2 |
| 0.3.1 | **published** | 2026-09-07 | **none** | 2 |
| 0.3.2 | **published** | 2026-09-08 | `v0.3.2` | 2 |
| 0.4.0 | **published** | 2026-09-13 | `v0.4.0` | 6 |

All six exist. None is removed from the phase 11 migration matrix.

**Finding S8 confirmed.** 0.3.0 and 0.3.1 were published without tags, so their
hexdocs `source_ref` (`v0.3.0` and `v0.3.1`) does not resolve on GitHub. That is
a historical limitation, recorded by 11e, not repaired by retagging.

Published tarball for 0.4.0, fetched and hashed, then deleted from the scratch
directory (it was never placed inside this repository):

| Item | Value |
|---|---|
| sha256 of the Hex tarball | `9e38d799514685b6657f4e3cfecc64f88eea03ca6180317ce307f98c1c3c0c96` |
| Bytes | 81,920 |
| Files inside `contents.tar.gz` | 46 |
| `contents.tar.gz` sha256 | `2a0ca1c986cd8cae59cb5ec42ef85942b1ee95290f01b71c7370cc840e12bd62` |
| Hex `CHECKSUM` | `589bc4e610bdd6fe00775b51222f7d184261d8812afa0ba535221c20c94abcfd` |
| Compared with `aurora_meter_pro/docs/evidence/phase-17/package-builds.json` | **equal** (same sha256, same 46 files) |

Public registry downloads at the time of the query: 267 all time, 125 in the
last 7 days.

## 5. Dependency relationships

- Pro 0.3.0 requires core `~> 0.4`. Pro 0.2.1 and 0.2.2 accept `~> 0.2 or ~> 0.3`,
  Pro 0.2.0 requires `~> 0.2`, Pro 0.1.x requires `~> 0.1`. Those published
  requirements corroborate the valid pairings in
  `docs/v1/build-plans/schema-migration-map.md` section 1.
- Pro builds against this repository as a **path** dependency whenever
  `../aurora_meter` exists and `AURORA_METER_FROM_HEX` is unset, so every local
  Pro result is against `cb38c3c` rather than the published tarball.
- The template `aurora_api` pins `{:aurora_meter, "~> 0.2"}` with `mix.lock`
  holding 0.2.0 from hexpm. It is two minor versions behind what the storefront
  sells. Recorded for 12.09.

## 6. Test configuration and databases

- Test configuration is in **`config/config.exs`** under
  `if config_env() == :test do`. **There is no `config/test.exs`** in this
  repository. `plan.md:119` and the `env` comment in `.github/workflows/ci.yml`
  both say otherwise and are stale.
- Repo `AuroraMeter.TestRepo`, database `aurora_meter_test`, host
  `DB_HOST` or `localhost`, port `DB_PORT` or **5490**, `Ecto.Adapters.SQL.Sandbox`,
  **`pool_size: 30`** (the credits concurrency test opens 20 real non-sandbox
  connections at once).
- `mix test.setup` (`mix.exs:150`) is `["ecto.create --quiet", "ecto.migrate --quiet"]`.
- **The container serving host port 5490 for every V1 run is
  `aurora-meter-pro-testdb`.** A second container, `aurora-meter-testdb`, binds
  the same port and must stay stopped. Neither container nor volume is ever
  removed. The decision and its rule are in the storefront
  `docs/evidence/v1/phase-00/environment.md`.

## 7. CI matrix (recorded, not run here)

`.github/workflows/ci.yml`: Elixir 1.15 / OTP 25 and Elixir 1.18 / OTP 27, on
`postgres:16`, with `DB_PORT=5432`. The local toolchain of record (Elixir
1.20.1 / OTP 29.0.1) is far above the declared floor `~> 1.15`, and no local run
proves a floor. That is 01f's work.

## 8. PLTs

`priv/plts/*.plt` and `*.plt.hash` are git-ignored (`.gitignore:11-12`).

| PLT | mtime | Bytes | Origin |
|---|---|---|---|
| `dialyxir_erlang-29.0.1_elixir-1.20.1_deps-dev.plt` | 2026-07-11 23:04 | 4,813,146 | this machine |
| `dialyxir_erlang-29.0.1_elixir-1.20.1_deps-test.plt` | 2026-09-07 19:54 | 5,928,127 | this machine |
| `dialyxir_erlang-29.0.6_elixir-1.20.4_deps-test.plt` | 2026-09-11 18:17 | 5,977,550 | **foreign** devcontainer (Elixir 1.20.4 / OTP 29.0.6) |

`mix dialyzer` on this machine selects the `29.0.1_1.20.1` PLT by name. **No PLT
is deleted or rebuilt by this unit.** The foreign file is evidence that some
phase-17 results came from a second environment.

## 9. Crash dump

`erl_crash.dump` at this repository root: **17,620,677 bytes**, mtime
2026-09-11 18:16:41 +1000, slogan
`Runtime terminating during boot ({badarg,[{io,put_chars,[standard_error, ...`.
It is git-ignored (`.gitignore:6`), never analysed and **not deleted**. Deleting
it is an owner decision (finding T9).

## 10. Historical evidence in this repository

`docs/evidence/phase-17/release-audit.md` records 234 checks and is labelled "in
progress". It names no source SHA, no toolchain and no date for the runs, and it
was produced on another host. **It is historical context, not current release
evidence.**
