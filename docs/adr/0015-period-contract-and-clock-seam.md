# ADR 0015: Period contract and clock seam

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADR: 0003 (buffered versus durable and the period seam), which
introduced `AuroraMeter.Period` as a behaviour. This ADR states the contract that
behaviour was always assumed to satisfy, and adds the clock seam it needs to be
testable. ADRs 0009, 0011 and 0012 all depend on it, because an event, a recurring
grant and a scheduled transition are each keyed by a period.

## Context

There is no clock seam anywhere in core: `DateTime.utc_now/0` and `Date.utc_today/0`
are called directly in the facade, the counter and the ledger. Every time dependent
test therefore either manipulates real time, sleeps, or writes rows with contrived
timestamps, and boundary behaviour at a month end or a leap day is effectively
untested.

The period contract is also implicit. A host supplied `period_source` that returns
a `NaiveDateTime`, a non UTC zone, or an interval whose end precedes its start fails
somewhere far away from its cause: a counter key that does not match, a report for a
period nobody can find, or a quota that resets at the wrong instant.

## Decision

A period is a half open UTC interval `[start, end)`. The closed start and open end
are part of the contract, so an instant belongs to exactly one period and a period
boundary is never double counted.

`AuroraMeter.Period.current!/2` wraps every call site and validates that both values
are `DateTime` structs in `Etc/UTC`, that `start < end`, and that
`start <= now < end`. A violation raises `AuroraMeter.Period.InvalidPeriodError`
naming the source module, so the error points at the host module that produced it
rather than at the core function that consumed it.

Boot time validation confirms the configured module is loadable and exports
`current/2`. It deliberately makes no probe call with a synthetic tenant: a custom
source may legitimately raise for a tenant it has never seen, and turning that into
a boot failure would punish a correct implementation.

A new optional callback `containing/2` resolves the period holding a past instant,
defaulting to `current(tenant, instant)`. The backfill, corrections and record time
attribution all need to ask which period an old fact belongs to, and inferring it
from the calendar would silently disagree with a subscription aligned source.

Config `clock: module` (default `AuroraMeter.Clock.System`) replaces every direct
`DateTime.utc_now/0` and `Date.utc_today/0` in core `lib/`, and Pro uses the same
seam. `AuroraMeter.Clock.Fixed` is the test implementation.

Work admitted in one period is charged to that period even if the callback returns
after the boundary: the admission period is snapshotted at admission and carried
through. A callback that spans midnight on the last day of a month is charged where
it started, not where it finished.

## Consequences

Boundary behaviour becomes testable without sleeping and without touching the
machine clock, which is the precondition for the leap day, month end and UTC
boundary tests in unit 02c.

The calendar month stays the default (D08 and `plan.md` D11). The daily and weekly
custom source recipe is a documented example rather than a general scheduling DSL:
a host that wants a different period writes a module, and the contract above says
exactly what that module must return. Aurora Meter does not gain a period
expression language in V1.

Pro's subscription aligned periods are preserved. `AuroraMeter.Pro.Period.containing/2`
falls back to the calendar month with `source: :calendar_fallback` for an instant
outside the subscription window, so an event that predates a subscription is
attributed explicitly rather than dropped.

Snapshotting the admission period means a long running callback can be charged to a
period that has already closed by the time it finishes. That is the intended trade:
the alternative, charging the period the work ended in, would let a caller move
usage across a billing boundary by holding a callback open.

## Migration impact

None of its own. The `period_start` column that durable events need arrives with S1
under ADR 0009.

## Verification

Unit 02c (leap day, month end and UTC boundary with a fixed clock; invalid source
shapes raise), 01c (I03: a period crossing during a `with_quota` callback), 06d and
07b (period keys for recurring grants and scheduled transitions). None of these
tests exists yet.

I01 (one flush batch has at most one durable effect) is unchanged by this ADR and
stays recorded by ADR 0007; I03's other half, that failed tentative quota work is
never billed, stays recorded by ADR 0008. Neither is restated here.
