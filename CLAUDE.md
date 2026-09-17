# CLAUDE.md

Aurora Meter is a Phoenix/Elixir usage-metering, entitlements, and billing library.

**Read [`AGENTS.md`](AGENTS.md) before writing any code**: it is the authoritative
build contract. **Execute [`plan.md`](plan.md) phase by phase; never skip a
Verification Gate.**

**`plan.md` is finished history.** The current programme is Aurora Meter V1:
`PhxTemplates/v1-release.md` with build documents in
`PhxTemplates/docs/v1/build-plans/` (start at its `README.md`).

Quick commands:

    mix deps.get
    mix compile --warnings-as-errors
    mix credo --strict
    mix test
    mix format --check-formatted
    mix check   # everything the gate runs
