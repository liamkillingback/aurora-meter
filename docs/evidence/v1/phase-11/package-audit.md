# Package audit: `aurora_meter` 1.0.0-rc.1

Build unit **11c**, task 11.10. Written 2026-09-17 from the runs named below.
Every number here is from a recorded run. Nothing is asserted in advance.

Runner: `scripts/v1/package-audit.sh` in the storefront repository.
Run: `package-audit-20260917T074645Z-bb2634`, **RESULT=pass**, exit 0.

## The candidate version, and why it is this one

`1.0.0-rc.1`. Chosen from the **registry**, not from this repository.

| Package | Published on 2026-09-17 | Latest | `1.0.0-rc.1` | `1.0.0` |
|---|---|---|---|---|
| `aurora_meter` (public hexpm) | 0.1.0, 0.2.0, 0.3.0, 0.3.1, 0.3.2, 0.4.0 | 0.4.0 | HTTP 404 | HTTP 404 |
| `aurora_meter_pro` (`phxtemplates`) | 0.1.0, 0.1.1, 0.2.0, 0.2.1, 0.2.2, 0.3.0 | 0.3.0 | HTTP 404 | HTTP 404 |

Read from `https://hex.pm/api` directly. The full transcript is in the
storefront's `docs/evidence/v1/phase-11/candidate-versions.md`.

**This repository was wrong about itself.** `mix.exs` carried `@version "0.5.0"`,
and 0.5.0 has never been published: it is the transition release 02d prepared and
the owner has not cut. Pro was worse: its `mix.exs` carried `0.3.0`, which **is**
published, so every `mix hex.build` in that tree produced a tarball claiming a
version an existing artifact already owns. The published Pro 0.3.0 has inner
checksum `1b85c0fb...`; the local build of "0.3.0" on 2026-09-17 hashed
`5160fa5e...`. Two different artifacts, one version number.

## Identity

| | |
|---|---|
| archive | `tmp/v1/11c/candidates/aurora_meter-1.0.0-rc.1.tar` |
| bytes | 538,624 |
| sha256 (Hex outer checksum) | `593904c403f2bb0b6fcf2e4c414d703ccdc586179b7f20b0ef3e64e25b75fd64` |
| Hex inner checksum (`CHECKSUM`) | `D4713EDEF641C03E7F6A382D14BAFCFF1C91A958648BF6BDFB1E59A3FD49B5DE` |
| uncompressed `contents.tar` sha256 | `d60f0c87561a4afde0bae69d7009473582db924ce7a20d8a2a90704e3498dd5a` |
| files in the archive | 126 (plus 22 directory entries in `metadata.config`) |
| source HEAD | `ab9f48ff930d7e2fb216dd7e1958c9936b2f1fa2` on `aurorameter-v1` |
| worktree | **dirty**, 14 modified files |
| `git diff HEAD \| sha256sum` | `7793cbefdd502045f42cbb714eb39be2c9fdd55e472d243065ec2ff54038471f` |
| Elixir | 1.20.1 (compiled with Erlang/OTP 29) |
| OTP | 29 |
| OS | Linux 6.6.87.2-microsoft-standard-WSL2 x86_64 |
| `mix.lock` sha256 | `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0` |

**The tree is dirty and cannot be otherwise.** Programme rule 4 forbids this
unit committing. The build document asks for a clean worktree; that is not
available to an agent, so the state is pinned exactly instead: HEAD plus the
sha256 of `git diff HEAD` reproduces this tree byte for byte. The owner commits,
tags and rebuilds in phase 12.

**No hash above is compared with a recorded one, and no gate may do so.** 00b's
blocker B19: Hex archives are not byte reproducible across toolchains, because
the gzip stream differs while the contents do not. The two values that ARE
comparable between builds are the **uncompressed contents tar sha256** and the
**Hex inner checksum**, and those are the two 11e should quote.

## What is in the archive (L-11c-1)

Top-level entries are exactly `package.files` expanded:

```
lib  .formatter.exs  mix.exs  README.md  LICENSE  CHANGELOG.md  NOTICE.md
```

Asserted both ways: nothing declared is absent, and nothing present is
undeclared. The full 126-entry list is in the run directory and in
`tmp/v1/11c/final/core-files.txt`.

Absent, checked individually: `test/`, `demo/`, `examples/`, `doc/`, `docs/`,
`priv/`, `_build/`, `deps/`, `bench/`, `tmp/`, `.env`, `.plt`, `.dump`, `.beam`,
`.git`, `node_modules/`, and symbolic links. That matters because this
repository carries a tracked `demo/` (a path dependency pinned to a July
migration, finding T10) and an `examples/` directory of 266 tests, and 09c found
153 stray HTML files in a package root at a commit gate rather than by their
author.

`LICENSE` is present, 1,073 bytes, first line `MIT License`.

## What the metadata says (L-11c-2, L-11c-4)

`metadata.config` is read with `:file.consult/1` and asserted field by field
(`scripts/v1/lib/read_metadata.exs`). It is not grepped: the check in
`package-smoke.sh` that reads "Pro names aurora_meter as a registry requirement"
is `grep -q '<<"aurora_meter">>' && grep -q '<<"repository">>'`, and the second
half is true whenever the archive declares any requirement at all.

| Field | Value |
|---|---|
| `app` | `aurora_meter` |
| `version` | `1.0.0-rc.1` |
| `build_tools` | `["mix"]` |
| `elixir` | `~> 1.15` |
| `licenses` | `["MIT"]` |
| `organization` | **absent** |
| `links` | Website, Aurora Meter Pro, GitHub, PhxTemplates |
| `files` | equals the tarball contents exactly |
| `VERSION` file | `3` (the Hex tarball format version, not the package version) |

Every link is `https://` and points at `aurorameter.com`, `www.phxtemplates.com`
or `github.com`. No other host.

**L-11c-2 holds.** All 14 requirements carry `repository: "hexpm"`. None carries
an organisation, none carries a path, and `aurora_meter_pro` is not among them.
The metadata names `phxtemplates` only inside `links`, never in a requirement, so
a host with no organisation key can install the free core. Proved by execution as
well as by assertion: the extracted tree resolved and compiled with
`--warnings-as-errors` from an empty `MIX_HOME` and `HEX_HOME` with no credential
of any kind.

**L-11c-4 holds, from the archive rather than from the repository.** The
`CHANGELOG.md` inside the tarball heads `## [1.0.0-rc.1] - 2026-09-17`, and the
`README.md` inside the tarball carries `{:aurora_meter, "1.0.0-rc.1"}`. The
exact pin matters: `Version.match?("1.0.0-rc.1", "~> 1.0")` is **false**, so the
`~> 1.0` line the README also carries, which is the right line after publication,
resolves nothing during the candidate window.

## Secrets

`gitleaks` over the extracted tree with the repository's high-signal rule list:
no findings. A second, independent scan for **value shaped** literals
(`sk_live_[A-Za-z0-9]{16,}` and six more): no hits.

The first version of that second scan looked for bare prefixes and reported four
hits in the Pro archive, every one a prefix NAMED in source or documentation
(`String.starts_with?(key, ["sk_live_", "rk_live_"])`). That is finding X26
reproduced by a new instrument; the length floor is what separates a value from a
mention. `package-audit.sh --inject-failure secret` plants a value-shaped string,
and the scan was watched catching it before it was trusted reporting nothing.

## Standalone compile

The extracted tree was copied out of the run directory, given its own empty
`MIX_HOME` and `HEX_HOME`, and built with `mix deps.get && mix compile
--warnings-as-errors` under `env -i`. It compiled. No `test/support` module is
referenced from `lib/`, and no `priv/` file is read at compile time, because
neither directory is in the archive at all.

## `mix docs` from the extracted tree (T12), recorded as observed

```
Generating docs...
** (File.Error) could not read file "SECURITY.md": no such file or directory
    (ex_doc 0.40.4) lib/ex_doc/extras.ex:117: ExDoc.Extras.build_extra/3
```

Exit 1. It fails on `SECURITY.md`, which is the first extra in `docs()` that is
not in `package.files`; `CONTRIBUTING.md` and all 34 pages under `docs/` follow it.

**The conclusion, which is now in `docs/RELEASE.md`:** documentation is published
by `mix hex.publish` from the repository checkout **at the release tag**, never
from an extracted tarball. The tag must exist first, because `docs()` sets
`source_ref: "v#{@version}"` and hexdocs source links point at it.

The alternative, adding `docs/` to `package.files`, was considered and not taken:
it roughly doubles the archive for files hexdocs already serves and no consumer
compiles. **This is a constraint on the owner, not a defect in the archive**, and
11e's manifest should repeat it.

The first version of this check ran `mix docs` in the wrong directory and got
"no mix.exs was found in the current directory". It exited 1, which is what the
check expected, and would have been recorded as T12's outcome. An expected
failure is the easiest control to get wrong, because a wrong answer looks right.

## `mix hex.publish --dry-run`

Ran, printed the full plan, contacted nothing. It names `aurora_meter 1.0.0-rc.1`,
14 dependencies, 148 file entries, `Licenses: MIT`, the four links, and
`Elixir: ~> 1.15`. Full output in the run directory.

**It names no organisation**, which is asserted: the free core must publish to the
public registry. `mix hex.publish` without `--dry-run` was not run, and D13 says
it never is by an agent.

## The tag

```
git tag --list
v0.1.0  v0.2.0  v0.3.2  v0.4.0
```

`v1.0.0-rc.1` **does not exist**, and creating it is the owner's step (D13,
phase 12 step 12.02). It is recorded rather than failed, and the reason it is
recorded rather than ignored is finding S8: core 0.3.0 was published with no tag
and its hexdocs source links are broken to this day.

Note also that **v0.3.0 and v0.3.1 are absent from this list** although both are
published. Only v0.1.0, v0.2.0, v0.3.2 and v0.4.0 are tagged. S8 named 0.3.0; 0.3.1
has the same defect and nobody had listed it.

## Verdicts

| Check | Verdict |
|---|---|
| PKG-01 identity, SHA and toolchain recorded | pass (worktree dirty, pinned by diff hash) |
| PKG-02 file list equals `package.files`, no forbidden path (L-11c-1) | pass |
| PKG-03 `metadata.config` parsed and asserted (L-11c-2) | pass |
| PKG-04 version, changelog and README agree, in the archive (L-11c-4) | pass |
| PKG-05 gitleaks and the value-shaped literal scan | pass |
| PKG-06 the extracted tree compiles standalone | pass |
| PKG-07 `mix docs` from the extracted tree (T12) | **fails, as expected; recorded** |
| PKG-08 `mix hex.publish --dry-run` and its destination | pass |
| PKG-09 the tag `source_ref` points at | **absent; the owner's step** |

## Controls

Every check was watched failing before it was trusted passing
(`tmp/v1/11c/selftest/`, and `scripts/v1/package-audit.sh --inject-failure`):

| Injection | Expected | Observed |
|---|---|---|
| none (baseline) | pass | pass |
| `forbidden-path` (a `test/` entry) | fail | fail, naming the path |
| `missing-licence` | fail | fail, naming `LICENSE` |
| `secret` (a value-shaped `sk_live_`) | fail | fail, naming the file |
| `version` (a wrong `VERSION` file) | fail | fail, naming both values |

Each injection is applied to the extracted copy under the run directory. A
sha256 over both archives and both repositories' `git status` was taken before
and after the whole self-test sweep and is unchanged:
`c6f6aea5ec1a4e1b56aef77a252542ed73c0679a37299035be911e0a6e6f3f42`.
