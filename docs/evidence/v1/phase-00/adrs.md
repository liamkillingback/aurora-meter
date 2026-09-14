# Phase 00, unit 00c: core architecture decision records

Repository: `aurora_meter`. Written 2026-09-14. No commit, no tag, no publish.

## 1. ADRs created

All seven carry `Status: accepted for Aurora Meter V1, 2026-09-14.` and the five
fixed sections (`Context`, `Decision`, `Consequences`, `Migration impact`,
`Verification`). Numbers 0009 to 0015 are allocated here and are not reassigned.

| No. | Title | Decision in one sentence | Invariants recorded | Schema step | Owning unit |
|---|---|---|---|---|---|
| 0009 | Durable event semantics | A durable event is identified by `(tenant_key, event_id)` with a canonical payload hash, so a retry is a duplicate and a changed payload under a used identity is a conflict; totals live in generations on the `aurora_meter_checkpoints` row `"events_projection"`, and the outbox seam runs inside the record transaction. | I06, I07, I08, I09 | S1, S2, S3 | 03a, 03b |
| 0010 | Undeclared features and configuration strictness | One runtime setting `undeclared_feature_policy` governs every entitlement entry point, `track/4` keeps metering undeclared features, and configuration stops discarding unknown keys (warn in 0.5.x, fail at boot in 1.0). | I04 | None | 02b |
| 0011 | Credit lots and allocations | Per grant lots and allocation rows become the source of truth, the balance row becomes a checked projection with explicit `debt`, and spend order and lock order are fixed and not customer configurable. | I10, I11, I12, I18 | S4, S5 | 06a |
| 0012 | Immutable plan versions | Plan identity becomes `(plan_id, version)` with a fingerprint; subscriptions pin their version, a changed definition raises instead of repricing, and entitlement changes happen through scheduled transitions. | I17 | S6 | 07a |
| 0013 | A narrow AI shaped sample application | The `plan.md:99` non goal is narrowed by exactly one deterministic token shaped workload generator inside `examples/`, MIT, offline, with no AI code in either package's `lib/`. | none | None | 09c |
| 0014 | Optional integrations stay free | Oban workers, metrics presets, the dashboard page, the OpenTelemetry bridge, the plug and the LiveView helpers stay in core behind optional dependencies, each a thin wrapper around a directly callable operation. | I20 | None | 08b |
| 0015 | Period contract and clock seam | A period is a half open UTC interval validated by `Period.current!/2`, a configurable `clock` replaces every direct time call, and work is charged to its admission period. | I01 and I03 period edges | None | 02c |

## 2. Relationship to `plan.md` decisions D1 to D22

`plan.md` section 2 is not edited by this unit. The table records which V1 ADR
extends or supersedes which recorded decision, as the ADR format requires.

| `plan.md` decision | Relationship | ADR |
|---|---|---|
| D5 (code first plans DSL, no DB editable plans) | extends: adds version identity and a history table; code stays authoritative and the non goal at `plan.md:96` is unchanged | 0012 |
| D8 (buffered default, durable per feature opt in) | extends: adds the transactional `record/4` path with caller supplied identity; legacy `durable: true` keeps its current behaviour | 0009 |
| D11 (calendar month UTC, Pro subscription aligned) | extends: states the half open interval contract and the clock seam; calendar month stays the default | 0015 |
| D12 (undeclared feature gives `:ok` plus a `:dev` only warning) | supersedes the permissive half: policy becomes a runtime setting, `:warn` in 0.5.x and `:deny` in 1.0 | 0010 |
| D15 (components ship in core behind optional deps) | extends: the same rule now covers Oban, metrics, dashboards, OpenTelemetry and the plug | 0014 |
| D16 (money in integer minor units; Stripe is the billing source of truth) | extends: adds per lot provenance and an explicit `debt` column; amounts stay integer and USD only | 0011 |
| D20 (NimbleOptions validated at boot, fail fast) | restores: the implementation discards unknown keys today, which this ADR reverses | 0010 |
| Section 3 non goal at `plan.md:99` ("anything AI or agent-related"), not a numbered decision | narrows by one named exception inside `examples/`; the non goal itself stands | 0013 |

## 3. Allocation rule for later units

A later unit that needs a new core ADR takes the next free number (0016 and
upward), adds a row to this table in its own evidence, and does not renumber an
existing file. A superseding ADR edits only the older file's status line.

## 4. Verification

`mix test test/aurora_meter/adr_format_test.exs` with `DB_PORT=5490`: 8 tests, 0
failures, seed 967666. The suite proves contiguous unique numbering (0001 to
0015), the heading and status convention from 0007 onward, the five sections in
every V1 ADR, a named schema step or `None` under `Migration impact`, a named
build unit under `Verification`, and the absence of the long and short dash
characters in the V1 ADRs, `docs/evidence/v1/TEMPLATE.md` and
`docs/evidence/README.md`.
