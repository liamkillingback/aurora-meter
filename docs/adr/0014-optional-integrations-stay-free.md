# ADR 0014: Optional integrations stay free

Status: accepted for Aurora Meter V1, 2026-09-14.

Prerequisite ADR: 0001 (resolved decisions), whose D15 already ships the LiveView
components in core behind optional dependencies. This ADR extends that rule to
every integration V1 adds.

## Context

V1 decision D03 places events, projections, credit lots, plan identity, public
behaviours and local observability in core, and says that the Oban, OpenTelemetry
and Phoenix integrations are optional dependencies and optional modules rather than
additional paid products.

Without a record, the natural commercial instinct pulls the other way. Schedulers,
dashboards and tracing all look like operator features, and an operator is exactly
the person who pays. Moving them into Pro would be a quiet regression for every
host that already runs the free package, so the boundary is fixed here before unit
05a writes the first worker.

## Decision

The following live in core, each behind an optional dependency:
`AuroraMeter.Oban.{CreditExpiry, HoldReconciliation, RecurringGrants, EventsReplay,
PlanTransitions}` with `Oban.cron_entries/1` and `Oban.validate!/1`,
`AuroraMeter.Telemetry.Metrics`, `AuroraMeter.LiveDashboard.Page`,
`AuroraMeter.OpenTelemetry`, `AuroraMeter.Plug.EnsureEntitled` and
`AuroraMeter.LiveView`.

Every worker is a thin wrapper around a directly callable operation:
`Credits.expire_due/1`, `Credits.reconcile_holds/1`, `Credits.Recurrences.run/1`,
`Events.Replay.run/1` and `Subscriptions.apply_due_transitions/1`. No `perform/1`
hard matches its operation's return. A host that uses Quantum, a cron entry or its
own supervisor therefore loses no functionality by not using Oban, which is the
test of whether an integration is optional.

Metric presets carry bounded labels (`result`, `kind`, `exporter`, `state`, and
`feature` only when `metrics_feature_label: true`) and never tag on `tenant_key`.
An unbounded label is how a metrics backend becomes the most expensive part of an
install.

Pro keeps only the commercial workers: the outbox deliverer, the reconciler and the
provider confirmed transition applier, plus the Pro dashboards.

## Consequences

Core must compile and pass its suite with none of the optional dependencies
present. This is not an assertion about the code as written: it is enforced by a
headless CI leg (no LiveView, no Oban, no telemetry metrics) that unit 01f adds,
which is the first real proof of I20 and lands in phase 01 rather than phase 08.

`AuroraMeter.Pro.Credits.Expirer` becomes a deprecated delegate to
`AuroraMeter.Oban.CreditExpiry`, and the installer refuses to register both, because
two schedulers expiring the same grants is a duplicated financial effect rather
than a duplicated job.

The commercial line this draws is explicit: nothing that is free in 0.4.0 requires
Pro in 1.0.0, and the new free surface (events, lots, transitions, workers,
dashboards page, OTel bridge, plug, sample) is free as well. Pro sells Stripe
settlement and commercial automation, not access to a scheduler.

## Migration impact

None. No schema change, no column, no backfill.

## Verification

Unit 01f (the headless CI leg), 05a and 05c (workers as thin wrappers, and the
directly callable operations), 08b (I20: the dashboard page refuses to render
without host authorisation) and 09b (the installer refusal). None of these tests
exists yet.
