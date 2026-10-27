# 0001: Resolved decisions

- Status: Accepted
- Date: 2026-07-11

## Context

Aurora Meter must be buildable autonomously with no open questions. Its
predecessor project failed from scope creep, so every design fork is decided up
front rather than discovered mid-build.

## Decision

The full decision table lives in `plan.md` section 2 and is binding.
Highlights:

- Two packages: `aurora_meter` (MIT) + `aurora_meter_pro` (commercial).
- ETS `update_counter` metering; the hot path never touches the database.
- Buffered flush by default; per-feature `:durable` opt-in.
- Code-first plans DSL; no DB-editable plans in v1.
- Calendar-month periods in the core; subscription-aligned in Pro.
- Hard limits block; metered features allow overage and bill it.
- Stripe Billing Meters via an idempotent usage reporter.
- Standalone library; no Ash coupling in v1.

## Consequences

Agents follow `plan.md` without re-deciding. A genuinely new fork requires a new
ADR (with decision + rationale) before any code is written for it.
