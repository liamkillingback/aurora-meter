# Phase 01 evidence: security audits and the secret scan (`aurora_meter`)

Build unit **01f**, wave 1a. Gate **G01 bullet 5**: "security audits have no
unresolved exploitable critical or high finding in the shipping dependency
graph; any scanner false positive has specific evidence, not a blanket
exclusion."

Every result below was produced by running the tool on this machine on
**2026-09-14**, at Elixir 1.20.1 / Erlang OTP 29.0.1, against the working tree
described in `compatibility.md` section 1. **No secret value appears in this
file**, and no file that is known to hold a credential was opened (decision
D14).

## 1. The three ways a finding may be handled

Recorded here once, so no later reader has to infer the policy:

1. **Fixed**, by a lock bump, with the new version named.
2. **Not applicable**, with the specific reason and, for a library advisory, the
   call path that shows the vulnerable function is unreachable. "Probably fine"
   is not a reason.
3. **Accepted by the owner as a risk.** This is an owner decision and never an
   agent decision. No entry below is of this kind.

`mix_audit` supports an ignore file. There is none in this repository, and G01
bullet 5 forbids a blanket exclusion, so if one is ever added each entry must
name one advisory and carry its reason inline.

## 2. `mix deps.audit` (mix_audit against the Elixir security advisory database)

| | |
|---|---|
| Command | `mix deps.audit` (via `tmp/v1/mixlane.sh core`) |
| Exit code | **0** |
| Output | `No vulnerabilities found.` |
| Log | storefront `tmp/v1/01f/core/deps.audit.log`, sha256 `5abfeb6aaec67f181817a0e4fee4d9233fdc863268357b838024c2152f862f60` |

Findings: **none**. Dispositions required: none.

New in CI on the `minimum`, `supported` and `current` legs.

## 3. `mix hex.audit` (retired packages)

| | |
|---|---|
| Command | `mix hex.audit` |
| Exit code | **0** |
| Output | `No retired or security advisory packages found` |
| Log | storefront `tmp/v1/01f/core/hex.audit.log`, sha256 `0c4bbc33a7871f8a8556b74d9fcdea270dc4b9fb9386b69803e9ec611ae3059b` |

Findings: **none**.

## 4. gitleaks

gitleaks **8.30.1**. Four scans, all of this repository, all on 2026-09-14:

| Scan | Config | Result |
|---|---|---|
| directory scan of the working copy | gitleaks default | **0 findings** (850.57 KB scanned) |
| directory scan of the working copy | this repository's `.gitleaks.toml` | **0 findings** (850.57 KB scanned) |
| git history, 43 commits | this repository's `.gitleaks.toml` | **0 findings** |
| git history, 43 commits | gitleaks default | **0 findings** |

The default-config scans are the important pair: they show the repository is
clean **without** any configuration of ours, so the `.gitleaks.toml` this unit
adds is not what is producing the green result.

### 4.1 `.gitleaks.toml` is not a blanket exclusion

It sets `[extend] useDefault = true`, adds no rule, removes no rule, and
disables nothing. Its `[allowlist] paths` list only names content this
repository does not author and cannot publish: `deps/`, `_build/`,
`node_modules/`, `.elixir_ls/`, `priv/plts/`, `cover/`, `doc/`, `tmp/`, compiled
`.beam` and `.plt` artefacts, `erl_crash.dump`, and the three git-ignored paths
that really do hold credentials on a developer machine.

Those last three are the only entries that could be mistaken for an exclusion
that hides something, so they are handled twice over: they are git-ignored by
design, which is what stops them being published, and
`scripts/v1/lib/checks.sh` in the storefront asserts separately, **by name and
without opening any of them**, that none is tracked by git. That assertion is
the condition that would actually matter.

### 4.2 X26, measured: why no bare-prefix rule was added

`open-findings.md` **X26** warns that a scanner grepping for a bare provider
prefix matches ordinary prose that merely names it, which is the same trap as
X8. This unit measured the cost rather than assuming it, using the sibling Pro
repository (which, unlike this one, does name a provider prefix in its
configuration and documentation):

| Configuration | Findings |
|---|---|
| the repository's `.gitleaks.toml` as shipped | **0** |
| the same, plus one rule matching a bare webhook-secret prefix | **6**, every one a false positive |

The six were a placeholder in `config/config.exs`, a sentence in
`docs/getting-started.md`, a configuration key name in `lib/aurora_meter/pro/config.ex`
and three test files. Not one was a credential. A rule like that would make the
gate fail on documentation, and the only way to keep it green would be to stop
writing about credentials.

So the CI configuration adds no rule. The default gitleaks rules are value
shaped (prefix plus length plus entropy) and do not have this problem. Any rule
a future maintainer adds must match a value, never a prefix on its own, and this
paragraph is the specific evidence G01 bullet 5 asks for.

### 4.3 X28, reproduced and closed

`open-findings.md` **X28** records that a raw directory scan reports
`generic-api-key` twice inside the git-ignored `erl_crash.dump`. Reproduced
directly by pointing the scanner at the file:

| Scan | Result |
|---|---|
| the crash dump, scanned explicitly, default config | **2 findings**, both `generic-api-key` |
| the same file, with this repository's `.gitleaks.toml` | **0 bytes scanned, 0 findings** |

A crash dump is a memory image, so those bytes are not credentials at all.

One subtlety worth recording, because it explains why the finding looks
intermittent: gitleaks 8.30.1 honours `.gitignore` for files inside the
repository it is scanning, so `gitleaks dir <this repo>` skips the dump on its
own. It does **not** skip it when the scan is rooted at a parent directory and
walks into this repository as a nested checkout, which is exactly how the
storefront's scan reaches it. The named exclusion in `.gitleaks.toml` is the
durable fix, and it names one file rather than disabling a rule.

## 5. What the audits do **not** cover

Stated because G01 bullet 5 is about the shipping dependency graph and it would
be easy to read two green audits as more than they are.

`mix deps.audit` and `mix hex.audit` read `mix.lock` and the Hex advisory
database. **Neither says anything about the Elixir or Erlang/OTP release the
library is compiled and run with.** Two Elixir advisories are open against the
pinned `minimum` leg and one against the `supported` leg
(`compatibility.md` section 4.1):

| Advisory | CVE | Patched in | `minimum` 1.15.8 | `supported` 1.18.5 | `current` 1.20.4 |
|---|---|---|---|---|---|
| GHSA-w2h8-8x3g-278p | CVE-2026-49762 | 1.20.1 and later | affected | affected | patched |
| GHSA-jf5q-v438-665c | CVE-2026-75758 | 1.18.5, 1.19.6, 1.20.4 | affected | patched | patched |

**Disposition: not applicable to the shipping dependency graph, and disclosed.**
Both are in the Elixir compiler and standard library, which the host chooses and
installs; neither is a Hex dependency of this package, so neither can be fixed
by a lock bump here. Elixir 1.15.8 is the final 1.15 release, so no fix will
arrive there. The honest response is the one D12 requires: keep testing the
floor, and state it. `README.md` now names the tested pairs and says a host
that needs a patched Elixir wants 1.20.4 or newer. 10a's
`docs/supported-versions.md` inherits that sentence.

Also not covered: the Postgres image, and any advisory in a tool that runs only
in `:dev` or `:test` and never ships.

## 6. Owner items

| Item | Why it is the owner's |
|---|---|
| `gitleaks/gitleaks-action@v2` on a **private** repository may require an organisation licence key (`GITLEAKS_LICENSE`). This repository is public, so this does not apply here; it is recorded because the sibling Pro repository is private and its `security.md` carries the same line | repository and organisation settings |

Nothing in this workflow needs a repository secret except `GITHUB_TOKEN`, which
is already scoped `contents: read`.

## 7. Open defects

| Statement | Owner |
|---|---|
| Two Elixir advisories are unpatched on the tested floor and will not be fixed there. Not a finding in the dependency graph, but it must appear in the support claim | 10a |
| No audit tool in this repository looks at the Elixir or OTP release in use, so a compiler advisory can only be caught by a human reading the release notes | 11c |

## 8. Handoff

Read `compatibility.md` (the pins and the table), then `ci.md` (the job and leg
map). This file is regenerated by running the three tools and pasting their exact
output; it must never be edited to make a finding go away.
