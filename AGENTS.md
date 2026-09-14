# AGENTS.md — Aurora Meter build & contribution contract

Authoritative for anyone (human or agent) changing Aurora Meter. `CLAUDE.md`
points here. Read fully before writing code.

## What Aurora Meter is

A Phoenix/Elixir library that meters usage, enforces plan entitlements, and (Pro)
bills via Stripe — living inside the host app, which owns its data. The moat is
ETS-backed real-time metering. Follow `plan.md` phase by phase; never skip a
Verification Gate.

`plan.md` is complete and historical; the current programme is Aurora Meter V1
(`PhxTemplates/v1-release.md` and `PhxTemplates/docs/v1/build-plans/`, starting at
its `README.md`).

## Commands

    mix deps.get
    mix compile --warnings-as-errors
    mix credo --strict
    mix dialyzer
    mix test
    mix format --check-formatted
    mix check   # all of the above

Do not run `mix` inside a parallel task that shares `_build` with a sibling task.

## Module conventions

- One responsibility per module; namespace `AuroraMeter.*` (core),
  `AuroraMeter.Pro.*` (pro).
- Every public function has a `@spec` and a `@doc` with a purpose line and an
  `## Examples` block. `@type t` on every struct.
- `snake_case` verbs/nouns. No stringly-typed options — validate with
  `NimbleOptions`.
- The hot path (`track`/`reserve`) never touches the database. ETS only; the DB
  is written by the `Flusher` on an interval.
- Tenants are opaque terms resolved via `AuroraMeter.Tenant.to_key/1` — never
  assume they are strings or integers.
- `Storage` and `Billing.Provider` are behaviours; never call Ecto or Stripe
  directly outside their adapters.

## Definition of done (every change)

1. `mix check` is green (format, warnings-as-errors, credo --strict, dialyzer,
   test, docs).
2. New public functions have specs, docs, and tests. Money/limit logic has a
   concurrency test.
3. Evidence saved under `docs/evidence/phase-NN/`.
4. No scope creep beyond `plan.md` §3 (Non-Goals). New forks become an ADR under
   `docs/adr/` before coding.

## Prohibited shortcuts

- No calling the real Stripe API in tests — use `AuroraMeter.Pro.Stripe.Fake`.
- No GenServer-per-tenant counters (use `:ets.update_counter`). No DB writes on
  the hot path.
- No secrets in the repo. No telemetry that phones home. No email gate on source.
- No swallowing errors to make a gate pass. Fix the cause.
