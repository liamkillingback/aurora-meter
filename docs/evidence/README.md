# Evidence directories: what is history and what is current

This file is a convention note. It contains no results, and nothing should be
written into it except corrections to the labels described below.

`phase-00` through `phase-17` hold the evidence of the 0.x programme, the build
described by `plan.md`. They are historical. Never edit a file in them, and never
read a passing count in one of them as current release evidence: those runs
happened against the code and the schema of their day.

V1 evidence lives in `docs/evidence/v1/phase-00/` through `phase-12/` and follows
`docs/evidence/v1/TEMPLATE.md`, which transcribes the seven required sections of a
phase report from `v1-release.md` section 1.2. The cross-repository manifest that
ties core, Pro and the storefront together for a release lives in the storefront at
`docs/evidence/v1/release-manifest.md`. V1 phase numbers are a separate sequence
from the 0.x phase numbers above and are never mixed with them.

Known label errors in the historical tree, recorded here rather than fixed in place:

- `phase-16/gate.txt:1` describes its work as "(0.5.0, schema version stays 3)".
  Both halves are stale. That work shipped as part of core 0.4.0, because the
  version history was renumbered downward before release; and "schema version stays
  3" refers to the ledger schema version of the time, not to the package schema
  version, which is `lib/aurora_meter/migration.ex` `@latest 6` at 0.4.0.
