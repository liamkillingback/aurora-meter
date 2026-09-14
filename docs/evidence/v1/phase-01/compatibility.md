# Phase 01 evidence: the compatibility matrix (`aurora_meter`)

Build unit **01f**, wave 1a. V1 tasks **01.07**, **01.08**, **01.09**. Binding
design: `docs/v1/build-plans/phase-01/01f-ci-and-compatibility-matrix.md` in the
storefront repository. Decision **D12**.

This file is written **before** the workflow YAML, because a matrix written
before the official table is read is a guess. Every version below was resolved
from a published list on the date stated, not from memory.

## 1. Tasks, repository and revision

| | |
|---|---|
| Repository | `aurora_meter` (`product-workspaces/aurora_meter`) |
| Branch | `aurorameter-v1` |
| SHA at the start of this unit | `26e18b652d11c0928d68119e5ccea9c3260df56c` |
| Tree state | dirty for the whole wave: agents do not commit (D13, `execution-waves.md` rule 6) |
| Tasks | 01.07 (CI), 01.08 (compatibility matrix), 01.09 (dependency combinations) |

## 2. The official compatibility table

| | |
|---|---|
| Source | Elixir, "Compatibility and deprecations", section *Compatibility between Elixir and Erlang/OTP* |
| URL | <https://hexdocs.pm/elixir/compatibility-and-deprecations.html> (301 to <https://elixir.hexdocs.pm/compatibility-and-deprecations.html>, which is the page actually read) |
| Accessed | **2026-09-14** |

The rows this unit depends on, transcribed from that page:

| Elixir version | Supported Erlang/OTP versions |
|---|---|
| 1.20 | 27 to 29 |
| 1.19 | 26 to 28 |
| 1.18 | 25 to 27 |
| 1.15 | 24 to 26 |

Consequences, stated so no later reader has to re-derive them:

- Elixir **1.15 cannot reach OTP 27**. If a dependency ever needs OTP 27, the
  Elixir floor has to move with it; there is no 1.15 plus OTP 27 pair to fall
  back on. That is the single most important fact in this file for D12.
- Elixir 1.18 is the only line in this matrix that spans OTP 25 to 27, so it is
  the natural home for every leg that varies something other than the runtime
  (headless, the two LiveView legs, Pro's registry leg).
- 1.20 plus OTP 29 is inside the table, so the `current` leg is a supported pair
  and not an experiment.

## 3. Availability: what `erlef/setup-beam` can actually resolve

`version-type: strict` fails loudly when a pin does not exist. The pins below
were checked against the precompiled build lists the action installs from,
fetched on **2026-09-14**:

| List | URL |
|---|---|
| Elixir builds | <https://builds.hex.pm/builds/elixir/builds.txt> (689 rows) |
| OTP builds, ubuntu-24.04 | <https://builds.hex.pm/builds/otp/ubuntu-24.04/builds.txt> (171 rows) |
| OTP builds, ubuntu-22.04 | <https://builds.hex.pm/builds/otp/ubuntu-22.04/builds.txt> (182 rows) |

Latest patch available per OTP major, both images (identical for every major
this matrix uses, so `runs-on: ubuntu-latest` is safe for every leg and no leg
needs a pinned older image):

| OTP major | Latest build, ubuntu-24.04 | Latest build, ubuntu-22.04 |
|---|---|---|
| 25 | `OTP-25.3.2.21` (2025-05-09) | `OTP-25.3.2.21` |
| 26 | `OTP-26.2.5.21` (2026-05-31) | `OTP-26.2.5.21` |
| 27 | `OTP-27.3.4.17` (2026-09-01) | `OTP-27.3.4.17` |
| 29 | `OTP-29.0.6` (2026-09-01) | `OTP-29.0.6` |

Elixir builds present for the pinned pairs: `1.15.8-otp-25`, `1.15.8-otp-26`,
`1.18.5-otp-27`, `1.20.4-otp-29`. 1.15.8 is the **last** patch in the 1.15
series; the list contains no 1.15.9.

## 4. The pins

Every version in `.github/workflows/ci.yml` is an exact patch, resolved with
`version-type: strict` (invariant M1).

| Leg | Elixir | Erlang/OTP | setup-beam build | Why this patch |
|---|---|---|---|---|
| `minimum` | **1.15.8** | **25.3.2.21** | `1.15.8-otp-25` | the declared floor; newest patch of each, and 1.15.8 is the final 1.15 release |
| `supported` | **1.18.5** | **27.3.4.17** | `1.18.5-otp-27` | the retained middle pair (01.08); newest patch of each |
| `current` | **1.20.4** | **29.0.6** | `1.20.4-otp-29` | the then-current pair; newest patch of each, verified inside the table's `1.20: 27 to 29` row |
| `headless` | 1.18.5 | 27.3.4.17 | `1.18.5-otp-27` | varies the dependency set, not the runtime, so it sits on the middle pair |
| `liveview-1.0` | 1.18.5 | 27.3.4.17 | `1.18.5-otp-27` | same reason |
| `liveview-0.20` | 1.18.5 | 27.3.4.17 | `1.18.5-otp-27` | same reason; non-blocking for one merge, see section 8 |

Nothing in the workflow is a minor-only string, and no leg uses `latest`.

### 4.1 Two facts about these pins that must not be lost

1. **Elixir 1.15.8 will never receive another patch.** Two advisories are open
   against it with no 1.15 fix:

   | Advisory | CVE | Affected | Patched in |
   |---|---|---|---|
   | GHSA-w2h8-8x3g-278p, unbounded integer parsing in `Version` | CVE-2026-49762 | `>= 1.5.0 and < 1.20.1` | `>= 1.20.1` only |
   | GHSA-jf5q-v438-665c, unbounded recursion in `List.to_string/1` and `List.to_charlist/1` | CVE-2026-75758 | `>= 1.15.0 and < 1.18.5`, `>= 1.19.0 and < 1.19.6`, `>= 1.20.0 and < 1.20.4` | 1.18.5, 1.19.6, 1.20.4 |

   Read on 2026-09-14 from the Elixir security advisory pages. This is **not** a
   reason to drop the `minimum` leg: the library compiles and its suite runs on
   the pair, which is what a support claim means, and neither advisory is in the
   shipping dependency graph (they are in the compiler and standard library the
   host chooses). It **is** a reason the README must not say "Elixir 1.15+" and
   stop there. The README now names the tested pairs and points a host that
   needs a patched Elixir at 1.20.4 or newer. `security.md` carries the
   disposition.

2. **OTP 25 is no longer maintained upstream.** The newest OTP 25 build in the
   list is dated 2025-05-09, sixteen months before this file, while OTP 26, 27
   and 29 all received a build in the last four months. The `minimum` leg is a
   compatibility proof, not a recommendation.

## 5. Postgres

| Role | Image | Resolved manifest digest (2026-09-14) |
|---|---|---|
| baseline | `postgres:16.13` | `sha256:5d143123fdf80462d1778cd4f24b9f7ca13c87174bca19141fb194c5a1ebca59` |
| production parity | `postgres:15.6` | `sha256:1ebd963e5c598f944a4e9ba27de4c95289d663dcc73731025aa53c5254094d8f` |

Digests were read from the Docker Hub registry manifest endpoint, not by pulling
an image. Each workflow job also logs the digest of the image it actually ran
(`docker inspect` on the service container), so a re-pushed tag is detectable
after the fact. A digest pin in the YAML is deliberately not used: it is
unreadable by a human editing the file, and after-the-fact detection is the
property that matters.

Why **16.13** and not the newest 16.x: it is the exact server version of the
local test container every gate on this machine runs against
(`postgres (PostgreSQL) 16.13 (Debian 16.13-1.pgdg13+1)` on
`aurora-meter-pro-testdb`, port 5490). Pinning it means a CI result and a local
result name the same server. When the local container is refreshed, the pin
moves with it, and `ci.md` says so.

Why a **15.6** leg exists at all: `open-findings.md` X4. Production Postgres is
`flyio/postgres-flex` **15.6** while every CI lane and all three local
containers run 16. A green 16 run is not proof for 15, so the `database` job
runs the full suite plus the migration subset on 15.6. 15.6 is pinned rather
than the newest 15.x because the point of the leg is parity with the database
the product actually runs on; when production moves, the pin moves.

No Postgres 13 leg. `open-findings.md` S5 resolves the circularity: 13 is
documented as the floor (`gen_random_uuid()` needs PG13 or pgcrypto) and 16 is
the tested version. Claiming a tested 13 would require a leg; claiming a floor
with the tested version stated beside it is honest and is what the package can
support today. 10a's `docs/supported-versions.md` is written from this file.

`max_connections` on the official image is **100** (confirmed on the local
container). Core's test pool is 30 (`config/config.exs:28`). One job is one
database, so the ceiling is not close.

## 6. S7 closed

`open-findings.md` **S7** asked whether `add_if_not_exists`, used at
`lib/aurora_meter/migration.ex:228` (with `remove_if_exists` at `:237`), is
available under the declared floor `ecto_sql ~> 3.10`.

It is, by three years. The vendored changelog records it at
`deps/ecto_sql/CHANGELOG.md:528-533`:

> `## v3.0.5 (2019-02-05)` ... `[migrations] Add :add_if_not_exists and
> :remove_if_exists to columns in migrations`

and the function is defined at `deps/ecto_sql/lib/ecto/migration.ex:1274`
(`def add_if_not_exists(column, type, opts \\ [])`). The floor for the feature
is ecto_sql **3.0.5**, well below `~> 3.10`.

**No change to the `ecto_sql` requirement in `mix.exs`.** S7 is closed as INFO.
11a's migration matrix confirms it by resolving the minimum for real.

## 7. What this machine could and could not rehearse

The local machine has exactly one toolchain: **Elixir 1.20.1 / Erlang/OTP 29.0.1
(erts-17.0.1)**, Ubuntu 24.04.4 under WSL2. It can therefore rehearse the
commands of the `current` leg only, and even that at 1.20.1 rather than the
pinned 1.20.4.

| Leg | Rehearsed locally? | What proves it |
|---|---|---|
| `minimum` (1.15.8 / 25.3.2.21) | no, the pair is not installed | the workflow run |
| `supported` (1.18.5 / 27.3.4.17) | no | the workflow run |
| `current` (1.20.4 / 29.0.6) | commands rehearsed at 1.20.1 / 29.0.1 | section 9, plus the workflow run for the exact patches |
| `headless` | yes, at 1.20.1 / 29.0.1 | section 9 |
| `liveview-1.0` | yes, at 1.20.1 / 29.0.1 | section 9 |
| `liveview-0.20` | yes, at 1.20.1 / 29.0.1, and it fails | section 8 |

`open-findings.md` **T7** recorded that the committed PLT file names name a
second environment, 1.20.4 / OTP 29.0.6, while the local toolchain is 1.20.1 /
29.0.1. The `current` leg's pins are exactly 1.20.4 / 29.0.6, so from now on CI
builds a PLT for the pair the committed names describe, and the local machine
keeps its own. Dialyzer PLTs are cached per Elixir, OTP and lock hash, so the
two cannot be confused.

## 8. The `liveview-0.20` leg and C9

**Status: captured, and it fails, exactly as `open-findings.md` C9 predicted.**
It resolved `phoenix_live_view 0.20.17` and then
`mix compile --warnings-as-errors --force` exited 1 with
`function runway_text/1 is unused` and `function burn_text/1 is unused` at
`lib/aurora_meter/components.ex:268` and `:264`. See `ci.md` section 8.4 for the
verbatim output and why that failure is the mechanical shadow of C9, and
`docs/v1/build-plans/phase-09/09b-installers-and-host-compatibility.md` for the
unit that resolves it.

The leg is `continue-on-error: true` for exactly one merge. It is the mechanism
that turns C9 from an opinion into a machine result: `mix.exs:50` claims
`~> 0.20 or ~> 1.0` while `lib/aurora_meter/components.ex` uses LiveView 1.0
body interpolation (`{@label}` and friends), which is literal text in 0.20.
09b either widens the component syntax so the leg passes, or removes the leg
together with the `~> 0.20` clause. **This unit does not change that
requirement**: changing it here would destroy the evidence 09b needs.

## 9. Local rehearsal results

Recorded in `ci.md` section 8 ("Local validation"), with every command, its exit
code and its log path. Nothing in this file claims a result that was not run.

In summary: every step of the `current` leg ran, `mix deps.audit` and
`mix hex.audit` are clean, `mix docs` and `mix hex.build` both write outside the
working tree and all twelve tarball assertions pass, the `headless` leg compiles
and runs with the three optional dependencies genuinely absent from disk, the
`liveview-1.0` leg compiles and its suite passes, and the `liveview-0.20` leg
fails as section 8 says. The working tree was byte identical before and after
every one of those runs.

## 10. Open defects

Carried into `open-findings.md` by the phase report; listed here so this file
stands alone.

| Id | Statement | Owner |
|---|---|---|
| new | Elixir 1.15.8 carries two unpatched moderate advisories and will get no further patch. The support claim must state it; `mix deps.audit` cannot see it, because it audits Hex dependencies and not the compiler | 10a (`supported-versions.md`), this file, `security.md` |
| new | `mix hex.audit` and `mix deps.audit` say nothing about the Elixir or OTP release in use. G01 bullet 5 is about the shipping dependency graph, so this is a gap in coverage, not a failed audit | 11c |
| X4 | production Postgres is 15.6 while everything else is 16 | closed here by the `database` job; 11a owns the fixture databases |
| S7 | `add_if_not_exists` floor | closed here, section 6 |
| T7 | local toolchain differs from the committed PLT names | closed here, section 7 |

## 11. Handoff

A fresh agent continuing this work reads, in order: this file,
`docs/evidence/v1/phase-01/ci.md` (the job and leg map, the M4 exemption rule,
the environment switches and the alias contract) and
`docs/evidence/v1/phase-01/security.md` (audit dispositions). The pins live in
`.github/workflows/ci.yml`. The table in section 2 is the only source for a new
pair: re-read it, do not extrapolate.
