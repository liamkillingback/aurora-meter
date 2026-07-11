# 0001 — Resolved decisions (D1–D22)

- Status: Accepted
- Date: 2026-07-11

## Context

Aurora Meter must be buildable autonomously with no open questions. Its
predecessor project failed from scope creep, so every design fork is decided up
front rather than discovered mid-build.

## Decision

The full decision table (D1–D22) lives in `plan.md` §2 and is binding.
Highlights:

- Two packages: `aurora_meter` (MIT) + `aurora_meter_pro` (commercial). (D1)
- ETS `update_counter` metering; the hot path never touches the database. (D7)
- Buffered flush by default; per-feature `:durable` opt-in. (D8)
- Code-first plans DSL; no DB-editable plans in v1. (D5)
- Calendar-month periods in the core; subscription-aligned in Pro. (D11)
- Hard limits block; metered features allow overage and bill it. (D12)
- Stripe Billing Meters via an idempotent usage reporter. (D17)
- Standalone library; no Ash coupling in v1. (D3/D4)

## Consequences

Agents follow `plan.md` without re-deciding. A genuinely new fork requires a new
ADR (with decision + rationale) before any code is written for it.
