# 11e: core's final checks (task 11.14)

This package's own record, so it is complete without the storefront. The
cross-repository view is `PhxTemplates:docs/evidence/v1/release-manifest.md`, Part B.

## Freeze

| | |
|---|---|
| SHA | `afc0ac585c4dcaa422b3a9fbad1b2e130be093aa` |
| Branch | `aurorameter-v1` |
| Worktree at the freeze | **clean** |
| Head subject | `fix(v1): four free-core workers stopped for ever on one node death` |
| `mix.lock` sha256 | `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0` (52 dependencies) |
| `@version` | `1.0.0-rc.1` (`mix.exs:9`) |
| Schema version | **10** (`lib/aurora_meter/migration.ex:132`, `@latest 10`); concurrent-index version 8 |
| Tags | `v0.1.0`, `v0.2.0`, `v0.3.2`, `v0.4.0`. **`v1.0.0` does not exist and is the owner's to create at step 12.02** |
| Freeze declared | 2026-09-21T09:55:24Z |
| Toolchain | Elixir 1.20.1, OTP 29, ERTS 17.0.1, Ubuntu 24.04.4 on WSL2 |

## Checks run against this SHA

| Check | Command | Exit | Evidence |
|---|---|---|---|
| worktree clean | `v1_check_clean_tree` | 0 | `release-20260921T095711Z-6eceb6`, step `release.preflight.clean_core` |
| secret scan | `v1_check_secrets` | 0 | same run, `release.preflight.secrets_core` |
| version, CHANGELOG and README agree | `check_version_consistency core` | 0 | `release.preflight.version_core` |
| `package.files` completeness | `check_package_files core` | 0 | `release.preflight.files_core` |
| release tag absent | `check_tag_absent core` | 0 | `release.preflight.tag_core` |
| `mix hex.build`, isolated build and deps paths | `isolated_hex_build core` | 0 | `release.preflight.build_core`, 4.0 s. `mix.lock` restored byte identical |
| target version free on the registry | `mix hex.info aurora_meter 1.0.0-rc.1` | 0 | `No release with name aurora_meter 1.0.0-rc.1` |
| archive audit against the bytes | `scripts/v1/package-audit.sh --package core` | 0 | run `package-audit-20260921T095930Z-359cd2`, RESULT=pass, PKG-01 to PKG-09 |
| compiles in the test environment | `mix test <file>` reached `test_helper.exs:27` | 1 | compilation succeeded; the failure is the stopped database, not the code |

## Archive identity, rebuilt from this SHA

`aurora_meter-1.0.0-rc.1.tar`, **548,352 bytes**, **126 files** inside `contents.tar.gz`,
built with plain `mix hex.build`, no organisation in the archived `mix.exs` (the free core
publishes publicly).

**Never compare the tarball sha256 between builds** (finding B19): Hex archives are not
byte reproducible across toolchains. The identities to compare are the **uncompressed
contents tar sha256** and the **Hex inner checksum**, both recorded in this run's
`package-audit.json` together with the full 126-file list. 11c's measurement at the earlier
SHA `ab9f48f` was `d60f0c87561a4afde0bae69d7009473582db924ce7a20d8a2a90704e3498dd5a` and
`D4713EDEF641C03E7F6A382D14BAFCFF1C91A958648BF6BDFB1E59A3FD49B5DE`.

**These are candidate values.** Step 12.02 changes `@version` to `1.0.0` and the CHANGELOG
heading, which changes the archive, and the owner re-runs the audit and records the final
digests then.

## What could not be run here, and who runs it

`aurora-meter-pro-testdb` (port 5490) is `Exited (255)` and an agent may not create, start or
remove a container. `test/test_helper.exs:27` checks out a database connection **before any
test file loads**, so **no test in this package could run**, measured rather than assumed.

The suite number that describes this SHA is the orchestrator's, with the machine to itself:
**`mix check` exit 0, 2,358 passed**. It is attributed rather than claimed.

| Prepared, not run | Step |
|---|---|
| `package-smoke.sh post-publish --package core` against the published artifact | **12.04**, and it is the check that closes X419 |
| clean-room install from the final archive | **12.04** |
| `mix docs` with no warnings | **12.03**, from the repository checkout: `docs.extras` files are outside `package.files`, so the first one (`SECURITY.md`) fails against an extracted archive |

## Findings that are this package's at release

- **X419**: the published `aurora_meter` 0.4.0 cannot complete its own documented
  installation. It boots, subscribes, meters, flushes, and raises from
  `AuroraMeter.Plans.get/1` at the first `with_quota/3`. 0.4.0 has no boot-time export
  check, so it hides until then. **The repair (R5) is in this tree**: `ensure_exports!/4`
  at `lib/aurora_meter/config/schema.ex:166`. Publishing is the fix.
- **X263 and X257**: a wallet that has ever combined promotional credit with a hold is
  likely to decline the lot migration. Documented at `docs/upgrading-to-lots.md:152`.
- **X88 is closed and its scope is honest.** An independent sweep found 178 dash characters
  in shipped content and every one is inside the house-style guard's documented exemptions
  (published CHANGELOG entries, `lib/` line comments rather than docstrings, `docs/adr/`,
  `docs/launch/`). Zero are in README, NOTICE, the unreleased changelog section or any
  guarded `docs/*.md`.

The full classification of every finding is
`PhxTemplates:docs/evidence/v1/phase-11/defect-review.md`.
