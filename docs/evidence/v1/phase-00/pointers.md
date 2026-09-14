# Phase 00, unit 00c: core execution pointers

Repository: `aurora_meter`. Written 2026-09-14. No commit, no tag, no publish.

## 1. `plan.md`

Inserted as a new section at lines 8 to 30, between the closing line of the
opening blockquote (line 6) and the `---` rule, which moved from line 8 to line
32. No checkbox, phase number or existing line was changed.

Exact inserted text:

```markdown
## Current programme (read this first)

This plan is history. Phases 0 to 14 are complete (74 ticked checkboxes, "Project
complete" at the Phase 14 gate) and describe how Aurora Meter 0.1.0 through 0.4.0
were built. It remains the reference for the original decisions D1 to D22 and for
the conventions in `AGENTS.md`.

The current programme is Aurora Meter V1. Its plan is `v1-release.md` in the
storefront repository that sits beside this one on the build machine
(`PhxTemplates/v1-release.md`), and its implementation-ready build documents are in
`PhxTemplates/docs/v1/build-plans/`. Start with that directory's `README.md`, then
read the build document for your unit. V1's decisions D01 to D14 and invariants I01
to I22 supersede this file wherever the two disagree; every V1 extension of a
decision recorded here has an ADR under `docs/adr/` numbered 0009 or higher.

Do not extend this file, do not tick further boxes in it, and do not reuse its phase
numbers for new evidence: V1 evidence lives in `docs/evidence/v1/phase-NN/`.

Two corrections to the text below, recorded here so nobody follows a stale
instruction: the test database is configured in `config/config.exs` under
`if config_env() == :test do`, not in `config/test.exs` (section 4); and the port
5490 container of record for V1 runs is `aurora-meter-pro-testdb`, not the
`aurora-meter-testdb` shown in section 4 (both claim the port; see
`docs/evidence/v1/phase-00/inventory.md`).
```

Checkbox counts, before and after the edit (unchanged):

| Pattern | Before | After |
|---|---|---|
| `grep -c -- '- \[x\]' plan.md` | 74 | 74 |
| `grep -c -- '- \[ \]' plan.md` | 0 | 0 |

## 2. `AGENTS.md`

Inserted at lines 12 to 15 (a blank line plus three lines), immediately after the
sentence ending "never skip a Verification Gate." in the "What Aurora Meter is"
section. Exact inserted text:

```markdown
`plan.md` is complete and historical; the current programme is Aurora Meter V1
(`PhxTemplates/v1-release.md` and `PhxTemplates/docs/v1/build-plans/`, starting at
its `README.md`).
```

## 3. `CLAUDE.md`

Inserted at lines 8 to 11 (a blank line plus three lines), immediately after the
sentence ending "never skip a Verification Gate.**". Exact inserted text:

```markdown
**`plan.md` is finished history.** The current programme is Aurora Meter V1:
`PhxTemplates/v1-release.md` with build documents in
`PhxTemplates/docs/v1/build-plans/` (start at its `README.md`).
```

## 4. Why the paths are prose and not links

Core and Pro are independent git repositories that a customer or a CI runner may
check out alone. A relative link that escapes the repository root resolves to
nothing on GitHub, so a reader would follow a broken link rather than learn that
the sibling checkout is missing. The prose form `PhxTemplates/...` tells a human
and an agent where to look and fails visibly when the sibling is absent.

## 5. `git diff --stat` for this repository

```
 AGENTS.md |  4 ++++
 CLAUDE.md |  4 ++++
 plan.md   | 25 +++++++++++++++++++++++++
 3 files changed, 33 insertions(+)
```

Untracked files added by this unit: `docs/adr/0009-*.md` through `0015-*.md`,
`docs/evidence/README.md`, `docs/evidence/v1/TEMPLATE.md`,
`docs/evidence/v1/phase-00/adrs.md`, `docs/evidence/v1/phase-00/pointers.md` and
`test/aurora_meter/adr_format_test.exs`. Nothing under `lib/`, `config/`, `priv/`,
`.github/` or `mix.exs` was touched, and no historical evidence file was modified
(`git status --porcelain docs/evidence/phase-00 .. phase-17` is empty).
