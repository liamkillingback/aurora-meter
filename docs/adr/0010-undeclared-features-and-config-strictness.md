# ADR 0010: Undeclared features and configuration strictness

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADRs: 0001 (resolved decisions) for the original entitlement model,
and 0006 (counter feature kind) for the feature vocabulary this policy applies to.

## Context

This ADR supersedes the second half of `plan.md` decision D12 ("feature not
declared in the plan gives `:ok` (permissive) plus `Logger.warning` in `:dev`")
and restores decision D20 ("NimbleOptions schema validated at boot, fail fast"),
which the implementation drifted away from. It does not edit `plan.md`.

Three defects share one shape: the library answers a question about a name it
does not know, and answers it silently.

`Entitlements.warn_undeclared/2` is compiled out of any build whose `Mix.env()`
is not `:dev` (`entitlements.ex:338`), and the environment in question is the one
the host compiled the dependency under. A production host therefore receives no
signal at all when it checks a feature that no plan declares, and the check
returns the permissive default.

`AuroraMeter.Config.validate!/0` calls `Keyword.take(config, Keyword.keys(@schema.schema))`
before validating (`config.ex:84`), so an unknown or misspelled configuration key
is discarded rather than rejected. A host that writes `defalut_plan:` gets the
library's default plan and no error.

`plan_atom/1` rescues `ArgumentError` from `String.to_existing_atom/1` and returns
`nil` (`entitlements.ex:331-335`), so a typo in `subscribe/2` silently subscribes
the tenant to the default plan.

Each of the three can change what a customer is entitled to, which is why the
policy is recorded here rather than decided inside a build unit.

## Decision

One runtime setting, `undeclared_feature_policy: :allow | :warn | :deny | :raise`,
applied uniformly to `check/2`, `allowed?/2`, `entitled?/2`, `feature_value/3`,
`quota/2`, `remaining/2`, `reserve/2,3`, `with_quota/3,4`, `record/4` and
`correct/4`. It is a runtime setting rather than a compile time warning precisely
because the warning today depends on how the host compiled the dependency.

`track/4` is deliberately excluded and keeps counting undeclared features:
metering is not entitlement, and a host that meters a name before adding it to a
plan is doing something reasonable. `track/4` reports `declared: false` in
`[:aurora_meter, :track]` telemetry metadata so the condition is observable.

Each entry point keeps its documented return shape under `:deny`:
`{:error, :not_entitled}` or `false` as the function already returns; `quota/2`
returns `kind: :undeclared, enabled: false`; `record/4` returns
`{:error, {:invalid, [feature: :undeclared]}}`. `:raise` raises
`AuroraMeter.UndeclaredFeatureError`. `:warn` behaves exactly as `:allow` and logs
once per feature per node. There is no per call override: a policy that a caller
can relax at the call site is not a policy.

Configuration validation stops discarding keys. Unknown keys warn in the 0.5.x
transition release and fail at boot in 1.0. Binary feature names raise
`ArgumentError` at the facade rather than creating a second ETS key, and no code
path calls `String.to_atom/1`. `subscribe/2` validates that the plan exists and
returns a changeset error instead of falling through to the default plan.

## Consequences

This is the transition contract required by D04, and both values are stated
together so no later unit ships 1.0 semantics in a 0.5.x release. The 0.5.0
transition release defaults to `:warn`, prints the exact snippet
`config :aurora_meter, undeclared_feature_policy: :allow` that restores today's
behaviour, and ships `mix aurora_meter.features` so a host can scan its own code
for names no plan declares. 1.0 defaults to `:deny`, and configuration generated
for a new install is `:deny`.

A host that never reads the warning and upgrades straight from 0.4.x to 1.0 gets
denials. That is the intended outcome of D04 and not an accident: the alternative,
keeping a permissive default forever, means a misspelled feature name silently
grants access for the life of the install. The behaviour is stated in the release
notes and in the guarantee table rather than left to be discovered.

Denial is an entitlement decision and nothing else. A denied undeclared feature
must not change the reservation arithmetic of `reserve/2,3` or `with_quota/3,4`:
no capacity is taken and none is released, which is the half of I04 this ADR is
responsible for stating.

## Migration impact

None. No schema change, no column, no backfill. The affected boundary is the
0.5.0 transition release listed in `api-change-map.md` section 3, which the owner
publishes.

## Verification

Unit 02b (table driven tests over every entry point crossed with every policy
value, plus unknown configuration keys, binary feature names and `subscribe/2`),
01c (I04: denial does not change reservation arithmetic) and 02d (the wording of
the guarantee table). No test for any of this exists yet.
