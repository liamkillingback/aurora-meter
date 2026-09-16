# Changelog

All notable changes to Aurora Meter are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Everything below landed after the 0.5.0 transition release and is not in any
published version. The 0.5.0 section beneath is a historical record of that
release and is deliberately not rewritten, including its statement that the
schema version is 6: that was true of 0.5.0. **This branch carries schema 10.**

### Added

- **`mix aurora_meter.bench <mode>`: eighteen modes, a machine-readable record
  and a correctness assertion on every run.** The task measured one shape and
  crashed printing it: it seeded a four column ETS row and the runtime reads a
  six column one, so every run since 0.4.0 did the work and then raised a
  `MatchError` at its own summary line. It now measures the hot path
  (`spread`, `hot`), the entitlement arithmetic (`reserve`, `with_quota`), the
  durable event path (`record`, `record_batch`, `correct`, `replay`), the credit
  ledger (`credits_debit`, `credits_hot_wallet`), the flusher at 1k, 10k and
  100k dirty keys, a slow database and a real outage (`db_delay`,
  `db_recovery`), and convergence and hard-limit overshoot on **real** peer
  nodes (`cluster_2`, `cluster_4`).

  Every run ends with a correctness assertion, records `correct: true|false`,
  and **exits non-zero when it is false**: a throughput measured while the
  arithmetic was wrong is a different system, not a slower correct one. Every
  run writes a JSON record with the machine, the OS, the runtime, the database,
  the exact command, the warm-up, the workload, p50, p95, p99, throughput,
  memory, backlog and error rate, and a field whose source was unavailable is
  `null` **with a note saying why**, never a zero. Each record carries `kind`,
  `"micro"` or `"end_to_end"`, because the two differ by three orders of
  magnitude.

  `mix aurora_meter.bench 8 500000` still runs, as `spread`, and prints a
  deprecation notice naming the new form. It is removed in 2.0.

  End-to-end modes run against their own database, whose name must end in
  `_bench`, with an ordinary pool; a repo configured with the Ecto sandbox is
  refused outright, because the sandbox's single owned connection is not the
  pool a host runs and the run would be measuring the sandbox.

- **The README's throughput table is now a measurement.** Every figure it
  carries was produced by this suite on a named machine and toolchain on a named
  date, is the median of five runs each in a fresh BEAM, is labelled micro or
  end to end, and links
  `docs/evidence/v1/phase-08/08c-results.md`. The figures it carried before were
  measured against the 0.3 counter row that 0.4.0 replaced, and the headline one
  is **lower** now, not higher: the spread-key figure the page used to carry was
  about a third above what this machine measures today. A figure that is lower
  and true is worth more than one that is higher and unverifiable. A test fails
  if a superseded figure reappears in any document that makes a claim.

- **An optional LiveDashboard page, with no default authorization and no tenant
  data on it.** `AuroraMeter.LiveDashboard.Page` shows what Aurora Meter is
  doing on this node: what is buffered and how old it is, cluster convergence,
  the durable-event checkpoints, credit holds and debt in aggregate, checkpoint
  state grouped by operation, and the observability-relevant configuration, each
  with its runbook link. It is compiled only when the new optional
  `phoenix_live_dashboard` dependency is installed.

  `:authorized_by` is **required** and has no default: a library page cannot
  know who is signed in and will not guess, so adding it to
  `additional_pages:` by copy-paste raises an `ArgumentError` naming the three
  accepted forms. The check runs again on every refresh, so a session that loses
  its marker stops seeing data without waiting for a remount.

  The page renders **no tenant key, feature name, reference or event id**, which
  is what lets it be shown behind a plain operator marker. A section it could not
  read renders "unavailable" with an error class, never a `0` and never an empty
  table: an operator reads both of those as "nothing is wrong", and that is the
  case the page exists for. A gauge-derived figure whose last sample is older
  than three `:metrics_interval`s renders as stale with the sample age.
- **An OpenTelemetry bridge that starts nothing.**
  `AuroraMeter.OpenTelemetry.attach/1` and `detach/0,1` turn the slow half of
  the catalogue (the durable write, the flush, a replay batch, a hold
  reconciliation, and Pro's outbox delivery and provider calls) into spans in
  **your** SDK. It uses the OpenTelemetry API and only the API: no tracer
  provider, no exporter, no batch processor, no socket. Compiled only when the
  new optional `opentelemetry_api` dependency is installed.

  The hot path gets no span and there is no friendly switch that turns it on.
  `attach/1` is idempotent: five calls leave the handler set one call leaves.
  Span attributes go through `redact/2`, so no tenant key, reference, object id
  or provider reference reaches a tracer; an error is carried as `error_class`
  rather than as its message, and a failing span's status message is empty for
  the same reason.

  A span pair puts the caller's previous span back when it ends. These handlers
  run inside processes that live for ever (`AuroraMeter.Flusher` flushes for
  ever), so a bridge that left an ended span current would parent every later
  span to a finished one.
- `AuroraMeter.Telemetry.gauges/0`: the most recent sample of each gauge with
  how long ago it was taken, **without** emitting one. For a dashboard that
  refreshes faster than `:metrics_interval` and should not fire a gauge event,
  and every handler a host attached to it, on every refresh. A gauge that has
  never sampled contributes no entry rather than a zero.
- `docs/alerts.md`: five worked alert examples, each with the signal, the
  derivation of its threshold from a configuration value you control, a severity
  and a runbook link, plus a "do not alert on this" section for the four signals
  that look like incidents and are not. They are deployment examples, not
  service level objectives.
- **The telemetry contract is data, and every page describing it is guarded.**
  `AuroraMeter.Telemetry.events/0` returns every core event with its real
  measurement and metadata keys, the tags a metric may use, the emitter and the
  version it arrived in; `event_names/0` flattens it. The suite compares it
  against the emit sites in `lib/`, against `docs/api.md` and against
  `docs/telemetry.md`, in both directions each time, so a new undocumented event
  and a documented event nothing emits both fail the build.
- **A closed tag allow list, because cardinality is an outage.**
  `AuroraMeter.Telemetry.tag_allow_list/0` is
  `[:result, :kind, :exporter, :state, :worker]`, with `:feature` behind the new
  `metrics_feature_label` option. `forbidden_tags/0`, `forbidden_tag_suffixes/0`
  and `tag_allowed?/2` are the other half. A metric tagged on `tenant_key` is
  one time series per tenant for ever, and this page used to show one:
  `docs/telemetry.md` and `docs/examples/showing-usage.md` both did, and both
  are fixed. **If you copied either, delete the tag.**
- `AuroraMeter.Telemetry.redact/2`: a copy of event metadata safe for a log line
  or a span attribute. Every identifier dropped, `error` reduced to
  `error_class` with no message, and `tenant: :digest` for a stable pseudonymous
  digest that the documentation is explicit is **not** anonymous.
- `AuroraMeter.Telemetry.Metrics.metrics/1` and `groups/0`: `Telemetry.Metrics`
  presets over the whole catalogue, compiled only when the new optional
  `telemetry_metrics` dependency is installed. Without it the module does not
  exist, every event is still emitted, and nothing in `lib/` references it.
- **Flush latency, at last.** `:telemetry.span/3` around the storage write emits
  `[:aurora_meter, :flush, :start | :stop | :exception]`. The existing
  `[:aurora_meter, :flush]` and `[:aurora_meter, :flush, :error]` events are
  **unchanged**, so a host attached to either sees no difference; `:stop`
  carries `duration` and `result`.
- **Two gauges**, sampled every `metrics_interval` (default 10 s, `0` to switch
  the internal timers off) inside processes that already exist, with no new
  supervised process. `[:aurora_meter, :store, :gauge]` reports `dirty_keys`,
  `counter_keys`, `oldest_pending_age_ms`, `pending_batch_age_ms` and
  `pending_batch_items`; `[:aurora_meter, :cluster, :lag]` reports `peers`,
  `since_last_message_ms` and `unreconciled_keys`. Both ages are monotonic spans
  inside one node, never a wall clock. `AuroraMeter.Telemetry.emit_gauges/0`
  drives them from `telemetry_poller` or your own scheduler.
- Configuration keys `metrics_interval`, `metrics_feature_label` and
  `metrics_scan_ceiling`. The last bounds the counters-table scan behind
  `unreconciled_keys`: above it the measurement is **omitted**, never reported
  as zero, because a zero there reads as "the cluster has converged".
- `docs/telemetry.md` is rewritten around a generated event table, the exact
  meaning of each gauge, and a failure-mode to signal to runbook table covering
  every state the library can be in.

- **Occurrence-plan attribution on every recorded event.**
  `AuroraMeter.Plans.effective_for/2` answers which `{plan_id, version}` a
  tenant was on at an instant, from the subscription for an instant inside the
  current assignment and from the applied transition history for one before it,
  and `AuroraMeter.record/4` stamps the answer onto `plan_id` and `plan_version`
  once, at record time. Nothing recomputes it afterwards, so neither a plan
  redeploy nor a plan change can reprice a fact that is already recorded
  (decision D05). A correction copies its original's stamp rather than resolving
  it again, so a credit issued after an upgrade is priced as the fact it
  reverses was (invariant I09). The common case costs **no query at all**: an
  instant inside the current assignment is answered from the cached
  subscription row, and only a backdated one reads the transition history, as at
  most two indexed single-row reads.
- **Scheduled plan transitions.** A tenant moves between plans because somebody
  scheduled it, at a boundary they chose, with a reference they can cancel or
  retry. `AuroraMeter.Subscriptions.schedule_transition/3` writes an audit row in
  `aurora_meter_plan_transitions` and mirrors it onto the subscription;
  `cancel_transition/3` withdraws it; `preview_transition/3` shows the
  entitlement diff, the effective time and the provider's mapping without
  writing anything; `apply_due_transitions/1` applies what has come due, one
  transaction per tenant, from any scheduler. With no `:effective_at` the
  boundary is the end of the tenant's **own** period, from whatever period
  source the host configured. Every effect is an update conditional on the
  transition still being pending, so two nodes, an Oban retry and a duplicated
  cron tick apply it once and report a skip for everybody else. See
  [Plans](plans.md) for the lifecycle, the precedence table and the measured
  lag.
- **Core reacts to a provider-driven plan change.** A customer who changes plan
  in the billing provider's portal reaches Aurora Meter through
  `AuroraMeter.Storage.put_subscription/1`, and that is now where a pending
  transition is settled: a write naming exactly the scheduled
  `{plan_id, plan_version}` applies it early, a write naming any other plan
  cancels it as an override with the observed pair recorded, and a write whose
  status is not entitled cancels it whatever the plan says. **This is a new side
  effect on an existing public function.** A host calling `put_subscription/1`
  directly with a changed plan while a transition is pending will see that
  transition settled. A tenant with nothing pending pays one uncached read and
  opens no transaction.
- `AuroraMeter.Subscriptions.confirm_transition/3`, for a billing provider
  integration: it records the provider's reference, takes the provider's own
  boundary over the scheduled one, and applies the transition if that boundary
  has passed. Idempotent under webhook redelivery.
- `AuroraMeter.Billing.Provider` gains two **optional** callbacks,
  `describe_plan_change/3` (what a preview shows in its `provider` section) and
  `update_subscription_plan/3`. `AuroraMeter.Config.validate!/0` checks only the
  required four, so a provider written before these existed still boots, and
  `AuroraMeter.Billing.Noop` implements neither: a core-only installation
  previews with `provider: %{status: :not_configured}` rather than a fabricated
  mapping. Core computes no proration of any kind; a preview reports each plan's
  declared list price and the billing provider is authoritative for the invoice.
- `AuroraMeter.Oban.PlanTransitions` starts appearing in
  `AuroraMeter.Oban.cron_entries/1` at `"*/5 * * * *"`, with no edit to the
  worker: its operation is now compiled in. Job arguments `limit`, `batches` and
  `tenant`.
- `AuroraMeter.Storage.list_subscriptions/2` gains the filter keys
  `:transition_state`, `:transition_confirm` and `:scheduled_before`, and an
  `:order` of `:scheduled_effective_at` whose keyset walks the partial index
  core schema version 10 creates.
- Telemetry `[:aurora_meter, :plans, :transition]` and the PubSub message
  `{:aurora_meter, :plan_transition, %{tenant_key, ref, state}}` on the tenant's
  topic.
- **Immutable plan versions.** A plan is identified by `{id, version}`, not by
  `id` alone: `plan :pro, version: "2", effective_at: ~U[2026-10-01 00:00:00Z] do
  ... end` publishes a new commercial contract without touching the one existing
  tenants are on. `AuroraMeter.Plans.get/2` resolves a named version,
  `versions/1` lists every version a plan has ever had, `get/1` and `all/0` keep
  their shapes and answer with the version effective now, and
  `AuroraMeter.subscribe/3` takes `version:` to pin one. A subscription records
  `plan_version`, `plan_fingerprint` and `plan_effective_at`, and
  `AuroraMeter.plan/1` resolves the version the row names rather than the plan
  id's current definition. See [Plans](plans.md); the decision and its
  implementation notes are in `docs/adr/0012-immutable-plan-versions.md`, which
  is deliberately not in the published documentation until the release that
  ships the whole of phase 07.
- **Editing a plan version in place is refused, not applied.**
  `AuroraMeter.Plans.register!/0` runs from `AuroraMeter.start_link/1`, stores a
  snapshot of each compiled version in `aurora_meter_plan_versions`, and raises
  `AuroraMeter.PlanVersionConflictError` when a compiled version's commercial
  content differs from the one already registered. The message names the plan,
  the version and both fingerprints, and the remedy is to publish a new version.
  `config :aurora_meter, plan_version_conflict: :warn` logs it instead and is
  the default in 0.5.x; `:raise` is the default from 1.0.
- **Existing customers get an explicit version, not a new one.** The first boot
  after core schema version 10 names the contract of every subscription written
  before plan versions existed: the plan's base version, its fingerprint, and
  `plan_effective_at` taken from the version's own instant or the subscription's
  `inserted_at`, never from the clock at upgrade time. It runs in batches with
  `FOR UPDATE SKIP LOCKED`, is idempotent, and resumes after an interruption
  without a checkpoint. A subscription whose plan id is no longer in code is
  named and counted rather than refused.
- **A version deleted from the plans module stays readable.** `Plans.get/2`
  falls back to the stored snapshot, so a tenant on a retired version keeps the
  limits, feature values, price and recurring credits they were sold. A feature
  name in a snapshot that no atom on the node matches is dropped from the
  resolved plan and logged once per version per node, which is a documented
  limit rather than a fixed problem: see [Plans](plans.md).
- `AuroraMeter.Storage` gains `put_plan_version/1`, `list_plan_versions/1` and
  `assign_legacy_plan_versions/1` behind a new `:plan_versions` capability. An
  adapter that declares it cannot store snapshots logs one warning and leaves
  compiled code as the only authority.
- **`AuroraMeter.Credits.reverse_lot/4` and `AuroraMeter.Credits.restore_lot/4`**,
  the source-scoped refund pair. `reverse_lot/4` takes credit back off the lots
  one payment funded, in the order `available`, `consumed` (which raises `debt`),
  `reserved`, and **never touches a promotional lot**, whatever order it sorts in
  and however late it was granted; `restore_lot/4` puts it back on the same lots
  for a failed or cancelled refund and a won dispute. Both take a required
  `:source` (`%{payment_intent_id: ...}` in this release), `:metadata` and
  `:allow_partial` (default `false`, which refuses above the cap and writes
  nothing). `reverse/4` stays wallet wide for a host with no payment provenance
  and the documentation says which to use. See [Credits](credits.md).
- **`AuroraMeter.Credits.reverse/4` takes the lot path on a wallet the allocator
  owns.** It reverses the wallet's **non-promotional** lots in spend order,
  `available` first, then `consumed` (which raises `debt`), then `reserved`,
  writing `reversed` on every lot it touches, and records as `debt` whatever
  those lots cannot give back, so it is still never refused. Before this it was
  planned as a debit: a refund on a cut-over wallet drained lots in spend order,
  which takes **promotional credit first**, destroyed the customer's promotion,
  left the paid credit that funded the purchase in the wallet and wrote nothing
  into `reversed`. `reverse_lot/4` remains the right call where the payment is
  known, because only it is capped by that payment's own lots.
- **A debt is never repaid out of promotional credit the wallet already holds.**
  The refund pair above may not take a promotion for a paid refund, and until
  this change that rule held for the refund's own transaction and no longer: the
  refund correctly left a `debt` rather than taking the promotion, and then the
  next `release` or `settle` repaid that debt in spend order, which takes
  promotional credit first. The customer's promotion paid for their refund one
  ordinary event later, leaving an allocation row that said `consume` like any
  spend. There is now one repayment path for every operation and it takes only
  non-promotional availability.

  **Two consequences worth reading before you upgrade.** A wallet can now hold
  promotional credit and owe money at the same time, and while it owes money it
  can spend neither: `balance/1` reports a positive `promotional` beside a
  positive `debt` and every hold and debit is refused. The way out is a grant of
  any kind, because the repayment a grant makes comes out of the lot it is
  creating, whatever its category. A promotion left standing beside a debt until
  its `expires_at` is destroyed by the expiry sweep like any other unspent
  promotion, so a host that grants promotional credit to wallets that may be in
  debt should watch `debt` on the balance row. See [Credits](credits.md).
- `AuroraMeter.Credits.history/2` takes `:reference_prefix`, for a host that
  mints references in namespaces of its own and needs to total one of them. It
  filters the ledger's **reference namespace**, which is the host's naming, and
  is never a substitute for provenance: which grant a spend came out of is a
  question for `AuroraMeter.Credits.Lots`.
- **The wallet cutover is no longer refused.**
  `AuroraMeter.Credits.LotMigration.cutover_blocked/0` asked whether a lot-aware
  refund path existed, because turning a wallet on without one would have
  exposed it to a refund that consumed promotional credit. `reverse_lot/4` is
  that path, so the check answers `nil` and `mix aurora_meter.credits.migrate_lots
  --no-shadow` will cut a wallet over. **Both refund calls are lot aware in this
  release**, so a host that cannot supply a payment id is safe on `reverse/4`
  too; `reverse_lot/4` is still the one to use where the payment is known,
  because only it is capped by that payment's own lots.
- **Recurring credit allowances, capped rollover and downtime catch-up.** A plan
  declares the policy with `AuroraMeter.Plans.recurring_credits/2` (`:amount`,
  `:category`, `:rollover`, `:expires`) and
  `AuroraMeter.Credits.Recurrences.run/1` issues it: one grant per tenant,
  entitlement, plan version and period, whatever the scheduler does. Two guards,
  both evaluated inside the wallet's balance row lock, make a second run a
  no-op: `aurora_meter_credit_recurrences` is unique on `(tenant_key, key)` and
  the period row is inserted `ON CONFLICT DO NOTHING`, and the grant carries the
  period's own reference into the ledger's `(kind, reference)` index. A run is
  paused with `AuroraMeter.Operations.pause("credits_recurrences:global")`.
  `AuroraMeter.Oban.RecurringGrants` now has an operation and appears in
  `AuroraMeter.Oban.cron_entries/0` at `"7 * * * *"`, with no change to the
  worker itself. See [Plans](plans.md) and [Credits](credits.md).
- **Capped rollover.** `rollover: n` carries at most `n` micro-dollars of one
  period's unused allowance into the next, as a lot of its own with its own
  reference and allocation trail. It does not accumulate: two idle periods carry
  the cap, not twice the cap. The cap comes from the previous period's stored
  policy snapshot, so editing a plan cannot change what an already-issued period
  may carry out of itself.
- **Downtime catch-up.** Missed periods are processed in chronological order
  with bounded work (`:max_periods`, 12 by default); a period that had already
  ended when it was processed is granted and expired in the same transaction and
  recorded `issued_and_expired`, so history is complete and nothing owed months
  ago arrives spendable. A tenant is never back-paid for periods before its
  first recurrence row.
- `AuroraMeter.Schema.CreditRecurrence`, the readable row for one period of one
  allowance, carrying the policy snapshot and the transaction it granted.
- `%AuroraMeter.Plan{recurring_credits: [...]}`, a new struct field. It is not a
  feature kind, so `t:AuroraMeter.Plan.feature_config/0` and every consumer of it
  are untouched.
- Telemetry `[:aurora_meter, :credits, :recurrence]`, with `amount` and
  `rollover_amount` measurements and `tenant_key`, `name`, `plan_id`,
  `plan_version`, `period_start`, `result` and `reason` metadata.

- **`AuroraMeter.Retention`, and `AuroraMeter.Oban.Retention`.** A closed,
  compile-time allow list of what may be deleted, with an age predicate **and** a
  state predicate on every entry: `aurora_meter_flush_receipts` past
  `:flush_receipt_retention` (30 days), and finished
  `"events_replay:<generation>"` checkpoint rows past
  `:replay_checkpoint_retention` (365 days). Everything else is on the protected
  list and is never deleted at any age, and a test derives the tables the
  migrations create and fails unless every one is classified, in both
  directions. `plan/1` is a dry run that runs the prune's own predicate with
  `count(*)` and writes nothing; `prune/1` deletes in bounded batches with a
  per-run budget. See [Retention](retention.md).
- **The flush heartbeat, and the receipt rule it exists for.** A flush receipt
  is what makes a retried batch apply at most once, so deleting one while a node
  still holds that batch would double-count real usage. Every node's
  `AuroraMeter.Flusher` now writes a `"flush:<node>"` row into
  `aurora_meter_checkpoints` (idle after a batch commits, pending with the
  batch's instant after one fails, and idle on a throttled tick otherwise), and
  `AuroraMeter.Retention` refuses to prune receipts unless every one of those
  rows proves no node holds a batch from before the cutoff. It also refuses when
  no node is reporting at all, which is what an un-upgraded fleet looks like.
  `AuroraMeter.Retention.status/0` lists the fleet, and
  `AuroraMeter.Retention.forget_node/1` is the one explicit, logged override for
  a node an operator has confirmed is gone.
- Configuration: `:flush_receipt_retention` (30 days),
  `:replay_checkpoint_retention` (365 days) and `:flush_node_id` (this node's
  heartbeat identity, defaulting to `to_string(node())`). The two windows have a
  **floor of one day**, refused at boot below it: a retention window is compared
  against a stored timestamp, and the clocks that write those timestamps step
  backwards by up to a few seconds, so a window of minutes is not a sound test
  and this decision cannot be undone.
- Telemetry `[:aurora_meter, :retention, :prune]`, with `deleted` and `duration`
  measurements and `table` and `blocked` metadata.
- **`AuroraMeter.Operations`**: pause, resume and cursors for every scheduled
  operation, free and with no Oban reference in it, so a host running Quantum or
  a plain timer gets the same controls.
  `AuroraMeter.Operations.pause("credit_expiry:global")` stops a sweep at its
  next batch boundary; `run_batches/3` is the batch loop both packages' workers
  run, and it reads the pause before every batch, keeps the cursor in
  `aurora_meter_checkpoints` rather than in a job argument, and lets a per-item
  failure be counted and stepped over.
- **`AuroraMeter.Credits.expire_due/2`**: the expiry sweep, paged, with `:limit`
  and `:after` and a report carrying the keyset cursor. `expire_due/0,1` are
  unchanged.
- **`mix aurora_meter.install --oban`**, which adds the `aurora_meter` queue, a
  `Oban.Plugins.Cron` plugin and every entry from
  `AuroraMeter.Oban.cron_entries/1` that is missing, and the
  `AuroraMeter.Oban.validate!/1` call in `Application.start/2`. It changes no
  value a host already set: a queue concurrency, a schedule chosen for one of
  these workers, and the order of the plugins list all survive, and a second run
  changes nothing. `--check-support` prints what this host resolves against the
  declared floors and exits non-zero when something present is below one.
  `--dry-run` is Igniter's own global switch.
- **Telemetry `[:aurora_meter, :operations, :batch]`** per batch, with `items`
  and `duration_ms`, and `name` and `result` in the metadata.
- Durable events. `AuroraMeter.record/4` and `record_batch/2` validate and
  canonicalise at the facade and commit the event with its local totals in one
  transaction. PubSub and ETS hydration happen only after commit.
- Core schema 7 and 8. Events gain `seq` (a generated identity, so ordering
  never comes from a wall clock), a payload hash, `occurred_at`, `period_start`
  and `attribution`, with a concurrent unique index. A checkpointed backfill
  gives legacy events deterministic ids and records what it approximated.
- `AuroraMeter.correct/4` and `replace/4`. A correction never edits a fact; it
  records a signed one against it, under a lock, and cumulative corrections can
  never exceed the original.
- `AuroraMeter.Events.Replay`. A resumable rebuild of a projection generation
  from the event log, safe to interrupt and resume.
- `feature_sources`, which declares where each billable feature's commercial
  quantity comes from, so a quantity cannot be counted by both the buffered path
  and the durable one.
- `AuroraMeter.Exporter`, a reference journal exporter and a conformance suite,
  so a host can write its own exporter and prove it behaves.
- Seven storage callbacks and a `capabilities/0` declaration, so an adapter that
  cannot do durable events says so instead of failing obscurely.
- `AuroraMeter.Storage.list_subscriptions/2`, a keyset page of subscriptions
  ordered by `tenant_key`, with `:limit` and `:status_in`. It is what a worker
  that must walk every subscription uses instead of loading the table at once,
  and it is what Aurora Meter Pro's usage reporter now reads instead of
  querying `AuroraMeter.Schema.Subscription` directly. `AuroraMeter.StorageCase`
  gained two cases for it: a page walked one row at a time may not repeat a
  row, skip one, or fail to end.
- **Hold recovery: `AuroraMeter.Credits.reconcile_holds/1` and the
  `AuroraMeter.Credits.HoldReconciler` behaviour.** A hold is taken before the
  row that remembers it exists, so a process killed in between leaves money
  reserved with nothing pointing at it. The ledger could already list those
  holds; now it can close them, and the host says which. Configure
  `:credits_hold_reconciler` as a module, a `{module, function}` pair or a
  one-argument function returning `:keep`, `:release` or `{:settle, amount}`.
  The callback runs in a task under the new `AuroraMeter.TaskSupervisor`,
  outside any transaction and while no ledger row is locked, bounded by
  `:credits_hold_reconciler_timeout` (default 5000 ms).

  **Nothing about it can release money by accident.** The default is `nil`,
  which keeps every hold, so upgrading and configuring nothing changes nothing.
  A callback that raises, exits, throws, times out or returns something that is
  not a decision keeps the hold. An old timestamp makes a hold a candidate to be
  asked about, never a candidate to be released, and the documentation says so
  in those words: age is not evidence that work was abandoned, and a hold's
  `inserted_at` is stamped by a different node's wall clock in any case.

  Decisions are applied through the existing `settle/3` and `release/1,2`, which
  lock the hold row and re-read its status, so a reconciler racing the hold's own
  worker produces exactly one terminal transition and the loser is reported as
  `already_closed`. Two nodes sweeping at once are the same case. There is no
  lease on a hold, deliberately: a lease is a duration, and a crashed reconciler
  holding one would leave a hold nothing could recover.
- Telemetry `[:aurora_meter, :credits, :hold_reconciliation]`, one event per hold
  examined, carrying the reserved amount, the age, the callback's duration in
  milliseconds, the decision and the outcome.
- `:credits_hold_reconciler` and `:credits_hold_reconciler_timeout`
  configuration keys. A module or `{module, function}` that cannot be loaded or
  does not export `decide/1` fails at boot rather than at the moment a stale
  hold is being decided.
- `AuroraMeter.TaskSupervisor` in the supervision tree. It supervises nothing at
  rest and exists so that a host callback the library invokes runs in a process
  of its own.
- **Optional Oban workers: the `AuroraMeter.Oban` namespace.**
  `AuroraMeter.Oban.CreditExpiry`, `.HoldReconciliation`, `.EventsReplay`,
  `.RecurringGrants` and `.PlanTransitions`, each a `perform/1` that calls one
  public operation and maps its result. `AuroraMeter.Oban.cron_entries/1`
  returns the recommended crontab and `AuroraMeter.Oban.validate!/1` refuses a
  host Oban configuration that cannot run them, raising
  `AuroraMeter.Oban.ConfigError` with every problem in one message: a missing or
  zero-limit `:aurora_meter` queue, a `:repo` that is not Aurora Meter's, a
  crontab naming a worker twice or naming both the core expiry worker and the
  deprecated `AuroraMeter.Pro.Credits.Expirer`, an unresolvable cron timezone,
  and `:testing` left on outside the test environment.

  `oban` is declared **optional**, so it forces no version on a host and the
  whole namespace is compiled behind `if Code.ensure_loaded?(Oban)`: without
  Oban there is no `AuroraMeter.Oban` and every operation those workers wrap is
  still a public function any scheduler can call. `docs/operations/scheduler.md`
  is the map, including the direct-call recipe for a host with no Oban.

  No worker opens a transaction, takes a lock or reads a clock to decide
  anything. Running one twice, or on two nodes at once, produces one effect
  because the operation it calls re-reads the row it is about to change under
  that row's own lock. The `unique` option each worker declares is defence in
  depth: a copy of the expiry worker with it removed produces the same result
  under a forced race.

  Two of the five wrap operations a later 1.0 release adds. They ship now so the
  registry is complete, are omitted from `cron_entries/1`, and cancel with
  `{:cancel, :not_implemented}` if run by hand.

- **`AuroraMeter.Credits.Lots`**, the public read side of credit lots:
  `list/2` (open lots in spend order by default, `states: :all` for every state,
  `:categories`, `:limit`, `:order` and a keyset `:cursor`), `get/2` (by lot id
  or by the grant's reference, which is what support has), `allocations/2` (the
  movement trail, filtered by lot, transaction or reference) and `for_source/2`
  (the lots a payment funded). Read only, no locks, a snapshot; a wallet that
  has not been cut over to lots answers `[]` or `nil`. `for_source/2` accepts
  `:payment_intent_id` and `:recurrence_key` only and raises `ArgumentError` for
  any other key, because a matcher that ignored a key it did not understand
  would match every lot and its caller is a refund path.
- **`AuroraMeter.Credits.balance/1` and `summary/1` report four more figures**:
  `spendable`, `promotional_spendable`, `debt` and `expired`. Additive keys, and
  the existing six keep their meanings exactly. On a wallet that has not been cut
  over to lots `spendable == available`, `promotional_spendable == promotional`,
  and `debt` and `expired` are `0`, so a dashboard can render all of them without
  asking which writer owns the wallet.
- **`AuroraMeter.Credits.after_commit/1` and `deferred_effects?/0`.** A ledger
  call made inside a host's own `Repo.transaction/1` sees a savepoint release
  rather than a commit, so its telemetry, PubSub and low-balance effects are now
  queued on the calling process and run by `after_commit/1`; the rollback branch
  calls `after_commit(discard: true)` and nothing fires. A call that owns its
  transaction is unaffected and needs neither function. At most once by design:
  a process that dies between the commit and the drain loses that round of
  effects, and the write is still committed and correct.
- **`AuroraMeter.Credits.history/2` takes `:cursor`**, with
  `AuroraMeter.Credits.cursor/1` producing one. It pages on the ledger's own
  ordering key, so a walk returns every entry exactly once even when rows share a
  microsecond. `:before` is kept, is a filter on `inserted_at` rather than a
  cursor, and is documented as lossy for exactly that reason. Passing both raises
  `ArgumentError`.
- **`AuroraMeter.Credits.Money.assert_range!/1` and `max_micro/0`.** Amounts
  beyond 9e15 micro-dollars (nine billion USD) are refused at the facade with an
  `ArgumentError` naming the limit, before any database work, rather than
  reaching Postgrex's encoder. The limit is three orders of magnitude below the
  `bigint` ceiling because `balance_after` and the conservation aggregate are
  sums of amounts.
- **`AuroraMeter.Schema.CreditTransaction.reversal?/1`**, the single predicate
  that recognises a reversal in either of its two permanent row shapes.
- Configuration `:credits_low_balance_handler_timeout` (5,000 ms).

### Changed

- **BREAKING: the optional `phoenix_live_view` requirement is now `~> 1.0`.**
  It was `~> 0.20 or ~> 1.0`.

  **This is breaking at resolution.** If your application has
  `phoenix_live_view` in its dependencies and it resolves to 0.19 or 0.20, your
  next `mix deps.get` will **refuse** where it previously succeeded, with a Hex
  dependency resolution conflict. Nothing installs, nothing compiles, and you
  see it immediately.

  ```elixir
  # your mix.exs, before: this resolved
  {:phoenix_live_view, "~> 0.20"},
  {:aurora_meter, "~> 0.4"}

  # after: this does not
  {:phoenix_live_view, "~> 0.20"},
  {:aurora_meter, "~> 1.0"}
  ```

  **What to do**, and the second door costs almost nothing:

    1. **Upgrade LiveView to 1.0.** Phoenix's own migration guide covers it, and
       Aurora Meter needs nothing from you in the process.
    2. **Remove the optional dependency**, if Aurora Meter was the only thing
       that wanted it. You lose `AuroraMeter.Components` and
       `AuroraMeter.LiveDashboard.Page`, and you keep the facade, the credit
       ledger, the plans DSL, the migrations, telemetry, the Oban workers and
       `AuroraMeter.LiveView.subscribe/1`, which is deliberately outside the
       compile guard. A build with no LiveView present runs 1900 of this
       package's tests.

  **Why it is right, which is not the same as it being invisible.** Every
  component and dashboard template in this package is written in LiveView 1.0's
  curly body interpolation, and in 0.20 a `{...}` in an element body is not an
  interpolation: it renders as the literal characters. 172 of them across four
  files in the two packages, counted rather than estimated. So a 0.20 host
  compiled this package without an error and shipped a page reading `{@label}`
  to its own customers. The wider requirement was a claim that had never worked,
  and removing it is why `mix deps.get` now refuses rather than installing
  something broken.

  If you do not have `phoenix_live_view` in your dependencies at all, nothing
  here affects you.

  `mix aurora_meter.install --check-support` now prints the floor for every
  dependency, required and optional, and **exits non-zero** when something
  present is below one or is installed without its integration compiled.

- **`attribution` gains the value `"plan_unresolved"`, and grades the plan as
  well as the period.** An event whose period resolved but whose plan did not
  (the tenant has no subscription, or none that covers `occurred_at`, or the row
  still has no `plan_version`) is stored with both plan columns NULL and this
  value, and its export intent is staged
  `{:ineligible, :plan_unresolved}` rather than eligible. **This is a behaviour
  change for a host that records events for tenants it has no subscription
  row for**: those events were staged eligible before and are staged ineligible
  now. Core ships no delivery, so nothing changes for a core-only installation;
  in Aurora Meter Pro the same items were already quarantined as `no_customer`,
  and they now carry the more accurate reason. An unattributable fact is a
  visible state, never a guess at today's plan.
- **A recurring allowance is granted under the contract its period was sold
  under.** `AuroraMeter.Credits.Recurrences` resolved the plan with
  `AuroraMeter.Plans.get/1`, which answers the version effective **now**, so a
  tenant still on version 1 began receiving version 2's allowance the moment
  version 2's `effective_at` passed. It now resolves the tenant's own version,
  and each period's key and stored policy carry the version
  `AuroraMeter.Plans.effective_for/2` resolves for that period, so a catch-up
  across an upgrade grants each period at its own contract. Keys written before
  this change are unaffected: a tenant on version 1 mints the identical string,
  and "already granted" is decided by the period rather than by the key.

- **`AuroraMeter.Storage.put_subscription/1` no longer nulls a column the
  caller omitted.** It upserted with `{:replace_all_except, [...]}`, which wrote
  NULL into every column not cast, so a provider sync would have erased a
  tenant's plan version and any scheduled transition. The replace list is now
  computed from the attributes actually supplied and intersected with an allow
  list that excludes the transition columns entirely. A host that relied on
  omission to clear a provider field now passes `nil` explicitly.
- `AuroraMeter.Plans.all/0` keeps its `%{id => Plan.t()}` shape and its content
  becomes time dependent: it answers with the version of each plan effective at
  `AuroraMeter.Clock.now/0`.
- The generated `__aurora_plans__/0` is keyed by `{plan_id, version}` rather
  than by `plan_id`. It is `@doc false` and generated, and a host that called it
  directly has to change.
- `aurora_meter_flush_receipts.inserted_at` is stamped by the database.
  `AuroraMeter.Retention` compares it against a cutoff the database computes,
  and it was written from the node's wall clock, which put two clocks on one
  comparison and made an early prune (and so a double count) possible.
  **This needs core schema version 10**: the column's default arrives with it,
  and a 1.0.0-rc.1 node against a version 9 database cannot flush.
- **References beginning `recurring:` are reserved.**
  `AuroraMeter.Credits.grant/3`, `grant_with_status/3`, `hold/4`, `debit/4` and
  `reverse/4` raise `ArgumentError` for a caller-supplied reference with that
  prefix, because the recurring-grant engine mints its own there and a collision
  would make a manual grant look like a period that had already been issued.
  Nothing else is reserved; manual grants keep using any string. The risk of an
  existing host already using the prefix is small and real, which is why it is
  named here.

- **A reversal is written with `kind: :reverse`.** It was `kind: :debit,
  category: :reversal`, which put a refund and an ordinary debit in one
  reference namespace: the unique index is on `(kind, reference)`, so a host
  debit and a refund keyed by the same order id collided and the second was told
  `:duplicate_reference` for a write it had never made. They no longer collide.
  The category is unchanged, rows written before this release keep their shape
  for ever and still read as reversals through
  `AuroraMeter.Schema.CreditTransaction.reversal?/1`, `spend_history/2` and
  `spend_total/2` score by category and are unchanged, and `:reverse` joined
  `history/2`'s default kinds so the default view still shows refunds. **If you
  query the table directly for `kind = 'debit'` to find reversals, that query
  now misses new ones**: use `kind = 'reverse' OR category = 'reversal'`.
  `AuroraMeter.Credits.Series` rejects `:reverse` as a spend kind, with the
  message style `:grant` already used.
- **`AuroraMeter.Credits.grant/3` and `grant_with_status/3` answer
  `{:error, :duplicate_reference}` for a reference that belongs to another
  tenant**, instead of a raw `%Ecto.Changeset{}`. The in-transaction lookup is
  scoped to one tenant, so a cross-tenant collision only surfaces at the global
  unique index; `hold/4` and `debit/4` have always answered that way. Every
  other changeset error is unchanged, deliberately: a grant can still return a
  changeset for an `:expires_at` on a non-promotional category, and a caller
  needs to see that field rather than a collision that is not there.
- **The low-balance alert fires once per crossing, and the crossing is
  persisted.** The trigger figure is now `spendable` rather than
  `balance - held`, so a tenant whose only remaining funds sit on an expired lot
  is correctly seen as low. The crossing's identity is written to the balance row
  in the same transaction as the balance change, so five more debits below the
  line alert once, a redelivered webhook that moves nothing is not evaluated at
  all, a rolled-back write takes the crossing with it, and a recovery followed by
  a second genuine fall alerts again with a different `crossing_id`.
  `set_low_balance_threshold/2` recomputes the crossing under the row lock:
  lowering or clearing the threshold clears one the wallet is no longer below,
  and it never raises an alert by itself. The alert is **at most once**: the flag
  means the crossing has been decided, not that the alert was delivered.
- **The low-balance handler runs in a supervised watcher that the caller does
  not wait for**, with `:credits_low_balance_handler_timeout`. A handler that
  raises, exits or never returns is logged once and reported in the telemetry
  event's `handler` metadata, and it cannot fail, block or **delay** the ledger
  call. Not waiting is the point rather than an optimisation: a handler that
  reads the database needs its own connection and the caller may be holding one,
  so a caller that waited would wait for a handler waiting for it, until the
  connection pool gave up. `[:aurora_meter, :credits, :low_balance]` is therefore
  emitted after the ledger call returns, and carries `handler:`. The PubSub
  broadcast is unchanged and is still sent synchronously by the writer, so a
  consumer that wants an exact count of crossings counts those.
- The credits PubSub payload gains `spendable`, `debt` and `expired`; the
  low-balance payload gains `spendable` and `crossing_id`;
  `[:aurora_meter, :credits, kind]` gains a `spendable_after` measurement and
  `deferred` metadata. All additive.
- `AuroraMeter.Credits.expire_due/1`'s documentation no longer claims expiry
  assumes at most one live promotional grant. It never did: promotional spending
  is attributed soonest expiry first, so each grant's remainder is well defined.
  The sentence was wrong rather than the behaviour.

- `AuroraMeter.Oban.CreditExpiry` and `AuroraMeter.Oban.HoldReconciliation` run
  bounded batches from a checkpointed cursor and **return the run's report**
  rather than a bare count. A host that matched on `{:ok, n}` from `perform/1`
  matches on `report.counts["expired"]` now. Both cancel with `{:cancel, :paused}`
  when their operation is paused.
- `AuroraMeter.Credits.expire_due/1` counts a grant whose own transaction failed
  and carries on, rather than letting one grant fail the whole sweep. The grant
  is still due and the next run examines it again.
- `AuroraMeter.Clock` gained `db_now/0`. Comparisons against a persisted
  timestamp now take the database's clock, because a node clock and a database
  stamp are two clocks and comparing them is what blocker B01 was.
- `AuroraMeter.Credits.pending_holds/1` is ordered by `(inserted_at, id)` rather
  than by `inserted_at` alone, and takes `:tenant` and `:after`. The old order
  left two holds written in the same microsecond in no defined order, so a
  `:limit`ed page could repeat one and skip another for ever. A caller that
  relied on the previous order gets a deterministic one instead.
- `AuroraMeter.Credits.settle/3` and `release/1,2` take `:tenant`. With it, a
  hold belonging to any other tenant answers `{:error, :not_found}` and nothing
  is written, which is the assertion a recovery tool needs when the reference
  came from a listing rather than from the caller that took the hold. Without
  it, behaviour is exactly as before.
- `AuroraMeter.Credits.release/1` became `release/2` through a default argument.
  No caller changes.
- **`AuroraMeter.Storage` gained a required callback**, `list_subscriptions/2`.
  A custom adapter must add it. No third-party adapter is known to exist, and
  the alternative (an optional callback with a default that loads the whole
  table) would make the unbounded read the silent default for exactly the
  adapters nobody has reviewed.

### Fixed

- **A wallet that owes money no longer reports credit it will refuse to spend,
  and the refusal says why.** After a refund or a settlement above its hold, a
  wallet holding a promotion can owe money and hold visible credit at the same
  time: the promotion survives, because a promotion is never consumed to repay
  a debt. `balance/1` and `summary/1` went on reporting that credit as
  `spendable` and `promotional_spendable` while `hold/4` and `debit/4` refused
  every amount, so a host reading the figures told the customer one thing and
  the next call did another.

  Both figures now report what the ledger will actually accept, which is
  nothing while `debt` is outstanding. `spendable` is still not floored at
  zero: where the debt exceeds what is left it stays negative, because the
  depth of the shortfall is real. `available`, `balance`, `promotional`, `held`
  and `expired` are unchanged and still report what the wallet holds or owes;
  they are not claims about spending.

  **`hold/4`, `debit/4` and `with_credits/4` refuse with the new
  `{:error, :debt_outstanding}`** when the wallet owes money, instead of
  `{:error, :insufficient_credits}`, which is the same word the ledger uses for
  a wallet that was never funded. The two need different answers to a customer:
  one is "top this up" and the other is "this is frozen until a grant clears
  the debt, whatever it is holding".

  **Upgrade note.** The new term is returned only on a wallet that has been cut
  over to credit lots, which needs schema version 9 and
  `mix aurora_meter.credits.migrate_lots`; no published version can produce
  one, and a legacy wallet goes on refusing with `:insufficient_credits`
  including when its balance is negative. A caller that matches
  `{:error, :insufficient_credits}` should add `{:error, :debt_outstanding}`
  before cutting its first wallet over. The whole state, what puts a wallet
  there, what the figures read and what clears it (a grant of any category,
  and nothing else) is under "Debt" in `docs/credits.md`.

- **`plan_effective_at` is stamped by the database, not by the node that wrote
  the row.** A fresh `AuroraMeter.subscribe/3` used to take
  `AuroraMeter.Clock.now/0`; from this release the column is set with
  `clock_timestamp()` and the value is never read into Elixir. Nothing compared
  it before, and scheduled transitions do, so a node whose clock is minutes out
  would otherwise decide a plan change against a clock the rest of the fleet
  does not share.

- **`AuroraMeter.Credits.with_credits/4` no longer raises `MatchError` when its
  hold was closed by someone else, and no longer loses the cost of work that
  ran.** Its success branch asserted `{:ok, _txn} = settle(reference, actual)`.
  Nothing could close a hold behind a running `with_credits/4` before this
  release, so the match never failed; a reconciler that can release a hold makes
  it possible, and the raise was caught by the clause below it, released the hold
  a second time and re-raised, so the caller saw a `MatchError` instead of its
  result and the executed work was never charged. Now: a hold already settled by
  somebody else returns `{:ok, result}` with one `:settle` entry, and a hold
  released by somebody else returns `{:ok, result}` and records the executed cost
  as a debit referenced `settle_missed:<reference>`, idempotent on that reference
  and permitted to take the balance negative, because pretending settlement was
  not owed would hide a charge that really happened. A settle that fails for any
  other reason is returned to the caller rather than swallowed.

### Notes

This section accumulates. **Every unit that changes behaviour appends its own
entry here rather than leaving the whole changelog to be written from memory at
release time**, which is finding X86 in the other direction.

## [0.5.0] - 2026-09-15

The transition release. It warns about everything 1.0 will refuse and refuses
nothing itself, so an application can be upgraded, watched for a while and fixed
before the defaults change under it. **No schema change**
(`AuroraMeter.Migration.latest_version()` is 6, as in 0.4.0), nothing new is
written to your database, and rolling back to 0.4.x is as safe as rolling
forward. Read [docs/upgrading-to-1.0.md](docs/upgrading-to-1.0.md) first: it
lists every warning next to what 1.0 does instead.

One item is a behaviour change rather than a warning, and it leads the list on
purpose: a custom `:period_source` that returns an interval which cannot be
correct now raises at first use, naming the source module. The default calendar
source and Pro's subscription-aligned source both satisfy the contract.

### Added

- **`docs/guarantees.md`, the contract in one table.** Fifteen guarantees, each
  with the exact conditions that make it true, what voids it, the invariant it
  rests on and the test that proves it. Rows that 1.0 will deliver say "not yet
  proven" and name the phase, rather than describing the future in the present
  tense. The page states, and `test/aurora_meter/docs_claims_test.exs` enforces
  over the whole documentation tree, that no Aurora Meter document puts a fixed
  number on buffered loss or claims a delivery stronger than at-least-once.
  Buffered loss is everything not in an acknowledged flush batch, which is
  unbounded while the database is unreachable; usage export and scheduled work
  are at-least-once with idempotent effects. Some documentation said otherwise
  before this release, and the corrections are listed under Fixed below.
- **`docs/upgrading-to-1.0.md`**: every 0.5.x warning against what 1.0 does
  instead, the staged sequence for `undeclared_feature_policy` with the
  `mix aurora_meter.features --strict` step, the `:allow` escape for a host that
  wants to keep today's behaviour deliberately, and the statement that 0.5.0
  needs no migration.
- **`docs/api.md`**, the published API inventory: every public module and
  function with its stability class, the release it arrived in and what it
  returns, plus the list of internal modules nothing here covers.
- **`docs/support-policy.md`**: what SemVer covers and what it does not, the
  schema contract, and the supported Elixir, Erlang/OTP and PostgreSQL versions.
- **`docs/correctness.md`**: every invariant I01 to I22 with its prerequisites,
  its known limits and the tests that hold it, checked against the suite so an
  entry cannot name a test that does not exist.
- Decision records 0009 to 0015. Two of them describe behaviour that ships in
  this release and are published with it: 0010 (undeclared features and
  configuration strictness) and 0015 (the period contract and the clock seam).
- `AuroraMeter.LiveView` documents the broadcast contract: the topic, the
  message shape, the fact that a broadcast value includes units reserved but not
  yet committed, and that day buckets are never broadcast.
- **`AuroraMeter.Clock`, the clock seam.** Every instant and every date inside
  the library now comes from the module configured under `clock:` (default
  `AuroraMeter.Clock.System`), so a host can freeze time in its own tests with
  `AuroraMeter.Test.with_clock/2`, `travel/1` and `travel/2`. The behaviour has
  four readings because time gets asked four different questions: `now/0` (what
  period is this, what do I display, what goes in `inserted_at`), `today/0`,
  `monotonic_ms/0` (an in-memory elapsed span) and `db_now/0` (has enough time
  passed since something persisted). `now/0` is documented as making **no
  monotonicity promise**: no wall clock on any host does, so anything comparing
  against a persisted timestamp takes `db_now/0`, which reads
  `clock_timestamp()` from your repo. See the new [periods](docs/periods.md)
  guide.
- **`AuroraMeter.Period.current!/2`**, the validated period read, used by every
  call site inside the library. It checks that the configured `period_source`
  returned a half-open UTC interval `[start, end)` containing the instant it was
  resolved for, and raises `AuroraMeter.Period.InvalidPeriodError` naming the
  source module when it did not. `AuroraMeter.Period.current/2` is unchanged and
  still unvalidated, for hosts that call it directly.
- **`AuroraMeter.Period.containing/2`** and an optional `containing/2` callback
  on the `AuroraMeter.Period` behaviour: which period held this past instant.
  Sources that are a pure function of the instant (the calendar month is) need
  not implement it.
- **`:undeclared_feature_policy`** (`:allow | :warn | :deny | :raise`), the
  compatibility switch for a feature the tenant's plan does not declare. It
  applies to `check/2`, `allowed?/2`, `entitled?/2`, `feature_value/3`,
  `quota/2`, `remaining/2`, `reserve/2,3` and `with_quota/3,4`, and every one of
  them keeps its documented return shape under every policy. The default is
  `:warn` in this transition release and `:deny` from 1.0;
  `config :aurora_meter, undeclared_feature_policy: :allow` restores the 0.4.x
  behaviour exactly. `AuroraMeter.track/4` is outside the policy and keeps
  counting: metering is not entitlement. See
  [Configuration](docs/configuration.md) for the table and the upgrade sequence.
- `AuroraMeter.UndeclaredFeatureError`, raised under `:raise`, carrying the
  feature, the tenant key, the resolved plan, the entry point, and whether any
  other plan declares the feature.
- `AuroraMeter.Config.policy_for/1`, the seam every entry point consults.
- **`mix aurora_meter.features`**, the scanner to run before changing the
  policy. It lists declared features per plan, what your configuration
  references (`:durable_features`, and Pro's `:stripe_meters` when that
  application environment is present), anything referenced that no plan
  declares, and every feature declared on some plans and not others with the
  plans that would deny it. `--strict` exits 1 when either of the last two is
  not empty.
- `[:aurora_meter, :track]` and `[:aurora_meter, :reserve]` telemetry metadata
  gains `declared: boolean()`.
- `AuroraMeter.Credits.assert_currency!/0` and
  `AuroraMeter.Credits.CurrencyMismatchError`: every stored credit balance row
  must carry the configured `:credits_currency`. The check runs once per node at
  boot, from a new internal child at the end of the supervision tree, and is
  skipped with one `:info` line when the credit tables are absent or the repo is
  not running yet.
- `AuroraMeter.Config.validate!/0` now checks at boot that `tenant`, `storage`,
  `provider`, `period_source`, `clock` and `plans` name modules that exist and
  export every callback their behaviour declares and does not mark optional,
  raising an `ArgumentError` that names the key, the module and the missing
  callback. It also warns when `:default_plan` names no plan (an error from 1.0)
  and when a `metered` feature declares a float `unit_price` (integer minor
  units are the supported form).
- `docs/periods.md`: the half-open interval and why, the boundary rule, the four
  clock readings and what each is for, the `Period` behaviour with its exact
  validation rules, and complete daily and weekly period source recipes that are
  compiled and exercised by the test suite.

### Changed

- `AuroraMeter.Credits.expire_due/0` defaults its `now` to `db_now/0` rather
  than the node clock. It decides whether a tenant's credit is still theirs by
  comparing against a persisted `expires_at`, and every node running expiry
  should agree on "now". Passing an explicit instant is unchanged.
- `mix aurora_meter.bench` reports elapsed time in whole milliseconds; it now
  measures its own span with the monotonic reading rather than a wall clock.
- **`AuroraMeter.Config.validate!/0` reads the whole `:aurora_meter`
  environment.** It used to drop every key that was not in the schema before
  validating, so a typo such as `flush_intervall:` was ignored for the life of
  the install. An unknown key is now reported with the nearest known key named:
  a warning in this release, a refusal to boot in 1.0. `:ecto_repos`,
  `:included_applications` and repo configuration written under the same
  application (`config :aurora_meter, MyApp.Repo, ...`) are reserved and are
  never treated as Aurora Meter keys.
- **Feature names are atoms at the facade.** `AuroraMeter.track(org, "api")`
  kept a second in-memory counter that seeded from and flushed into the same
  database row as `:api`. A binary now warns once per name in this release and
  raises `ArgumentError` in 1.0; anything that is neither an atom nor a binary
  raises in both. `AuroraMeter.Storage` callbacks still accept
  `atom() | String.t()`, because stored rows carry strings.
- **A tenant resolver must return a non-empty binary.** `""` (which is also what
  the default resolver makes of `nil`) used to be a valid tenant key, so every
  tenant a resolver could not answer shared one set of counters. It warns once
  per node in this release and raises in 1.0; a non-binary raises in both. The
  error names the configured module and what it returned, never the term it was
  given.
- **`AuroraMeter.subscribe/2` validates the plan.** A plan id no plans module
  declares used to be written and then silently resolved to the default plan.
  It now warns and writes in this release, and returns `{:error, changeset}`
  with `plan_id: ["is not a known plan"]` in 1.0.
- The undeclared-feature warning is no longer compiled behind
  `Mix.env() == :dev`. That was the environment in which the **host** compiled
  the dependency, so a release build warned about nothing at all and a
  production install had no signal. It is a runtime policy now, logged once per
  feature per node in every build.
- `AuroraMeter.Entitlements.plan/1` asks
  `AuroraMeter.Schema.Subscription.entitled?/1` instead of repeating the
  entitled-status list. No behaviour change; there was one rule in two places.
- `mix aurora_meter.install` writes `undeclared_feature_policy: :deny`, so a new
  install denies from its first boot.

### Deprecated

- **`config :aurora_meter, durable_features: [...]`.** A non-empty list now logs
  one deprecation line per node at boot. The key still works and is kept until
  2.0; nothing changes in 0.5.x or 1.0. 1.0 introduces `feature_sources`, which
  says where a feature's commercial quantity comes from rather than bolting an
  event row onto a buffered count, and `AuroraMeter.record/4` for usage that
  must not be lost. An empty list, which is the default, warns about nothing.

### Fixed

Documentation that claimed more than the code delivers. None of these is a code
change; each is a promise being corrected, which matters more than a typo would.

- `docs/metering.md`, `docs/examples/concepts.md` and
  `docs/examples/allowance-and-overage.md` each bounded buffered loss at one
  flush interval ("at most one interval's worth", "up to five seconds"). Loss is
  everything not in an acknowledged flush batch, and during a database outage the
  pending set grows until the database returns or the VM stops. The README
  already said so; the guides did not.
- `docs/examples/allowance-and-overage.md` described metered usage reaching
  Stripe "exactly once". Export is at-least-once with provider-side
  idempotency: the identifier is what stops a retry billing the same window
  twice.
- `docs/examples/concepts.md` implied that a durable event row is what gets
  billed. It is not: usage reporting reads the persisted counters, and the event
  row is the audit record beside them.
- `docs/clustering.md` described a four-element counter row (it has six, and the
  two that were missing are the ones that explain reservations and gossip),
  named a schema version that has moved twice since, and documented a rolling
  upgrade from 0.2 instead of the upgrades anyone is actually facing.
- ADR 0003 said absolute-value upserts make the flusher idempotent. The flusher
  has applied deltas since ADR 0004, and idempotence comes from the flush
  receipt inside the transaction (ADR 0007). The ADR's original text is
  unchanged, with a dated note appended: a decision record says what was decided
  and when, and is not rewritten to match the present.

## [0.4.0] - 2026-09-11

The first release carrying code since 0.3.0 — 0.3.1 and 0.3.2 were
documentation and package metadata only. It brings the prepaid credit ledger,
the `counter` feature kind and the money series, together with a large body of
correctness work from auditing all three against a live Stripe sandbox.

**Schema versions 3 through 6.** Existing installs add one migration
(`mix aurora_meter.gen.migration -r MyApp.Repo --from 3` generates it):

```elixir
def up, do: AuroraMeter.Migration.up(from: 3)
def down, do: AuroraMeter.Migration.down(to: 3)
```

Version 3 is the credit ledger tables, version 4 adds `promotional_after` to
every ledger entry, version 5 a partial index for the open-hold sweep, and
version 6 idempotent flush receipts. All are required by this release.

- Database flushes now commit immutable batches and receipts atomically.
  Retrying an uncertain commit cannot count the same usage twice, even with
  concurrent writers or gossip. A pending batch survives a Flusher restart;
  later usage is flushed in a subsequent batch. `Flusher.flush/0` returns
  `{:error, reason}` on failure. Custom storage adapters need `flush_batch/3`.
- Promotional expiry replays consumption chronologically: spending before a
  later grant existed cannot consume that grant or shield it from expiry.

### Added

- **Prepaid credit ledger** — `AuroraMeter.Credits`: `grant/3` (idempotent per
  reference; `:paid`, `:promotional` or `:adjustment`), `hold/4`, `settle/3`,
  `release/1`, `debit/4`, `with_credits/4` (hold, run, settle or release —
  also on raise), `balance/1`, `available/1`, `sufficient?/2`, `history/2`,
  `set_low_balance_threshold/2`, `expire_due/1`, `subscribe/1` and `topic/1`.
  Amounts are integer micro-dollars; every write is a `FOR UPDATE` row lock
  plus an append-only `aurora_meter_credit_transactions` entry, so concurrent
  holds cannot overspend. Promotional credit is consumed first and can expire.
  Requires the Ecto storage. See [docs/credits.md](docs/credits.md) and ADR 0005.
- `AuroraMeter.Credits.Money` — `from_cents/1`, `to_cents/2`, `from_decimal/1`
  and `format/2` for converting at the edges of the ledger.
- **Integer features** in the plans DSL: `feature :seats, 5` declares a plan
  value (always entitled, never metered) read with
  `AuroraMeter.feature_value/3` or `AuroraMeter.Plans.feature_value/3`;
  `quota/2` reports them as `kind: :feature` with a `value`.
- Telemetry: `[:aurora_meter, :credits, kind]` for every ledger entry (with
  `duplicate` and `overrun` in the metadata) and
  `[:aurora_meter, :credits, :low_balance]` once per crossing; PubSub
  `{:aurora_meter, :credits, ...}` and `{:aurora_meter, :low_balance, ...}` on
  `AuroraMeter.Credits.topic/1`.
- Config: `:credits_currency`, `:credits_overdraft_tolerance`,
  `:credits_low_balance_threshold`, `:credits_low_balance_handler`.
- `AuroraMeter.Test` — `fund!/3`, `drain!/1`, `credit_balance/1`.
- `AuroraMeter.Schema.CreditBalance` and `AuroraMeter.Schema.CreditTransaction`.

- **`counter` feature kind** in the plans DSL: `counter :requests` declares a
  feature that is measured but **never blocked and never billed**, for products
  whose money lives in the credit ledger rather than in subscription overage.
  `check/2` is `:ok`, `entitled?/2` is `true`, `remaining/2` is `:unlimited`,
  and `reserve/3` admits unconditionally while still incrementing the counter.
  `AuroraMeter.quota/2` reports `kind: :counter` with **`limit: nil`,
  `included: nil` and `percent: nil`** — a counter has no denominator, so a
  renderer must treat `nil` as "no bar" and can never render "0% of 0".
  `AuroraMeter.Components.usage_meter/1` renders it as a bare count with no
  progress bar. Replaces `metered(included: 0, unit_price: 0)`, which made
  every unit read as overage against an allowance of zero. See ADR 0006 and
  [docs/plans.md](docs/plans.md).
- **Money series from the credit ledger** — `AuroraMeter.Credits.spend_history/2`
  returns `[%{date, spent, granted, net, balance_after}]`, **zero-filled across
  the whole range and sorted oldest first**, so a chart renders it with no gap
  handling. Options: `:days` (default 30) or `:from`/`:to`, `:bucket`
  (`:day` default, or `:month`) and `:kinds`. Buckets are UTC; `spent` and
  `granted` are positive magnitudes; `balance_after` is the balance at the last
  entry in the bucket and `nil` when the bucket has none. `:hold` and
  `:release` are excluded everywhere (they move `held`, not `balance`) and are
  rejected if passed in `:kinds`.
- `AuroraMeter.Credits.spend_total/2` — `%{spent, granted, net, from, to}` over
  the same range.
- `AuroraMeter.Credits.summary/1` — balance, held, promotional, currency,
  `spent_this_period` / `granted_this_period` over the configured period, and
  `daily_burn` / `runway_days` from the trailing 30 days. Both are `nil` when
  there is nothing honest to report (`runway_days` also when burn is zero).
- `AuroraMeter.Credits.Money.format_compact/1` — `"$1.2k"`, `"$0.07"`,
  `"$0.000015"` for short axis labels, never rounding a sub-cent amount away
  to `"$0.00"`.
- **Money components** (LiveView optional, as before):
  `AuroraMeter.Components.spend_chart/1` (attrs `:points`, `:height`,
  `:label`, `:show_grants`) and `AuroraMeter.Components.credit_summary/1`
  (attr `:summary`). Inline SVG, `<title>` tooltips, no JavaScript, and
  `currentColor` throughout so they inherit the host's design system. Amounts
  render as dollars via `Money.format/2`; a zero-spend bucket renders a
  baseline bar, never a gap.
- The `AuroraMeter.Plan` `feature_config` type gains `{:counter}`, and the DSL exports
  `counter: 1` for paren-free declarations via `import_deps: [:aurora_meter]`.

- `AuroraMeter.Credits.reverse/4` — takes credit back for money that has already
  left the payment provider (a refund, a chargeback). Unlike `debit/3` it is
  never refused for want of balance, because refusing would only make the ledger
  disagree with reality; the balance may go negative, which is the honest record
  of a debt. Still idempotent on the reference.
- `AuroraMeter.Credits.grant_with_status/3` — reports new-or-duplicate from
  inside the balance row's lock. Callers were probing for the reference
  beforehand and racing: two concurrent deliveries of one payment both found
  nothing, both called themselves new, and the host announced the payment twice.
- `AuroraMeter.Credits.pending_holds/1` — open holds older than `:older_than`,
  oldest first, optionally filtered by reference prefix. A hold is taken before
  the row that remembers it exists, and those two cannot be one write, so a
  process killed in between leaves money reserved against a tenant with nothing
  pointing at it. Only the host can tell such a hold from work that is still
  running, so the ledger's part is to list them.
- `AuroraMeter.Counter.remote_since_rebase/1`.
- `promotional_after` on every ledger entry (schema version 4), so the
  promotional figure can be rebuilt from the log like `balance` and `held`
  already could. It is consumed before paid credit and clamped to the balance
  after every entry, so it moves for reasons no single `amount` explains; with
  no snapshot the balance row was the only copy and nothing could tell a clamp
  from a bug.

### Changed

- `AuroraMeter.quota/2` maps gain a `value` key (`nil` except for integer
  features), and `kind` may now be `:feature` or `:counter`. Callers that
  already handled `percent: nil` (boolean, integer and undeclared features)
  need no change.

- `AuroraMeter.Entitlements.reserve/3` gains an optional fourth argument, the
  captured period start. `AuroraMeter.Counter.release/4` and `rebase/2` likewise
  gain optional arguments. The existing arities still work unchanged.
- `rebase/3` clears `remote` only for this node's own flush. A total announced by
  another node is a database total *that* node saw, and this one may have applied
  gossiped deltas since.
- Test-database migrations are pinned to the version they add. Unpinned, `up()`
  meant "everything known today", so a database created before a later version
  existed and one created after it ran the same migration and ended with
  different schemas — which is how the test database came to be missing the
  version 5 index.

### Fixed

The flusher, entitlement and plan-validation items affect code that shipped in
0.3.x. The rest concern the credit ledger, the money series and the `counter`
kind, all of which are new here — they are recorded because the behaviour is
worth knowing, not because a published version carried the bug.

- **A refusal no longer rolls back the caller's transaction.** Every refusal in
  the ledger — an already-settled hold, a duplicate reference, a balance that
  cannot cover a debit, a grant a hold has spoken for — is decided before
  anything is written, and every one of them answered with `repo.rollback/1`.
  In a nested transaction that marks the *whole* transaction, `mode: :savepoint`
  or not: Postgres aborts back to the outermost `BEGIN`. A host that wrapped a
  ledger call in its own transaction lost its own writes to a duplicate
  delivery, and its next statement on that connection failed too. Refusals
  return `{:error, reason}` and the transaction commits having done nothing,
  which is what rolling back a write-free transaction amounted to anyway. The
  returned tuples are unchanged, so callers that already matched on them need
  no edit.

  Worth knowing if you are testing this yourself: the bug is **invisible under
  an `Ecto.Adapters.SQL.Sandbox` DataCase**, because the sandbox holds a
  transaction of its own and the abort unwinds no further than its savepoint.
  The regression test lives in `credits_concurrency_test.exs`, unsandboxed, for
  that reason.
- **`with_quota/4` releases its reservation on an exit**, not only on a raise.
  An exit is how gated work usually fails — a `GenServer.call`, a `Task.await`
  or a database checkout all time out by exiting — and an exit unwinds straight
  past a `rescue`, so the reservation was counted for good and a hard limit
  ratcheted down every time a call timed out.
- **`reserve` and release now use the same billing period.** `with_quota/4`
  captured the period so work spanning a boundary released from the counter it
  reserved in, but only the release was given the captured value; `reserve`
  asked `Period.current/1` again on its own way in. The day bucket behind
  `bump_history/4` had the same fault against the clock.
- **A refund no longer eats promotional credit or reads as spend.** Reversals
  were written as plain negative debits, indistinguishable from spending: the
  sign-up bonus was quietly consumed, `expire_due/1` found nothing left to
  reclaim and the trial grant stayed live for ever, while the customer saw
  refunded money in their spend chart and in the burn rate the runway estimate
  divides by. Reversals carry `category: :reversal`, count against `granted`
  rather than spend, and leave `promotional` alone.
- **Expiry respects holds and grant boundaries.** A promotional grant expired
  credit a pending hold had reserved — taking the balance below `held`, so the
  settle that followed went negative, a debt the tenant silently repaid out of
  their next top-up. A grant now expires only its own remainder, with
  promotional spend attributed soonest-expiring-first.
- **The flusher no longer bills usage twice, or drops usage it counted.** Its
  two writes are no longer all-or-nothing under one `rescue` (a failure in the
  second restored deltas for both, including the batch that had already
  committed); exits are caught as well as exceptions; and a failed write is
  checked against what the row actually holds before its delta goes back, since
  a statement that times out client-side can have committed server-side a
  moment earlier. On a cluster that check only runs while no gossiped delta has
  moved this node's view, which `Counter.remote_since_rebase/1` now reports —
  without it, a clustered node discarded real usage on every flush failure.
- `Series.kinds/1` refuses `:grant`. A grant passed as a spend kind was scored
  twice with opposite signs: `spent` came back negative, which its own type
  forbids and which renders as a dollar amount with a minus sign.
- The `metered` plan validator guarded `unit_price` with `>= 0` alone, and every
  atom sorts above every number in Elixir — so `metered :x, included: 1000` with
  no price compiled and validated cleanly.

## [0.3.2] - 2026-09-08

Documentation and package metadata only; no code or schema changes.

### Changed

- Aurora Meter now has its own home at https://aurorameter.com. The package
  links, README, NOTICE and description point there for the product, pricing
  and Pro, and keep the PhxTemplates links for the templates built on the core.

## [0.3.1] - 2026-09-08

Documentation only; no code or schema changes.

### Changed

- Explained what the tenant argument (`org` in every example) is and what a
  good key looks like: in the README ("What `org` is"), the `AuroraMeter`
  and `AuroraMeter.Tenant` module docs, the metering and entitlements guides,
  the getting-started guide and the installer's quickstart output.

## [0.3.0] - 2026-09-07

**No migration required** (schema version stays 2).

### Added

- **Cluster-wide counters.** Every node still meters into its own ETS table,
  but the flusher now writes *deltas* (`value = value + Δ`) and re-bases on the
  total Postgres returns, so nodes add up instead of overwriting each other.
  Nodes exchange deltas over PubSub every `:broadcast_interval` and announce
  flushed totals every `:flush_interval`; a value read on any node is the true
  total minus at most the other nodes' last tick of increments. See
  [docs/clustering.md](docs/clustering.md) and ADR 0004.
- `AuroraMeter.Cluster` — the supervised process behind it; config
  `cluster_sync: true` (default).
- `AuroraMeter.Storage.add_counters/1` and `add_history/1` (new required
  callbacks on the behaviour) alongside the absolute `upsert_*`.
- `AuroraMeter.Test` — `reset!/0`, `flush!/0`, `broadcast!/0`,
  `unique_tenant/1`, `checkout/1`, `simulate_node/3`, `simulate_flush/2` and a
  `use AuroraMeter.Test` macro, replacing the boilerplate the testing guide
  used to ask hosts to copy.
- **One-step installer.** With `igniter` in your deps, `mix igniter.install
  aurora_meter` (or `mix aurora_meter.install`) writes the config, adds
  `AuroraMeter` to your supervision tree after the repo and PubSub, creates a
  starter plans module and generates the migration. Without Igniter the task
  keeps printing the steps.
- Telemetry: `[:aurora_meter, :cluster, :apply]` and
  `[:aurora_meter, :flush, :error]`; `[:aurora_meter, :flush]` gains
  `delta_sum`, `[:aurora_meter, :broadcast]` gains `deltas`.

### Changed

- ETS counter rows are now `{key, value, pending_flush, pending_gossip}`
  (anyone reading `:aurora_meter_counters` directly needs the new shape).
- With `cluster_sync` on, tenant usage broadcasts are node-local: each node
  informs its own LiveViews from its own converged view.
- A failed flush no longer crashes the flusher: taken deltas are restored and
  re-marked dirty, the error is logged and reported via telemetry.
- `AuroraMeter.check/2` is documented as advisory (a read then a compare); use
  `reserve/3` or `with_quota/4` to enforce a hard limit atomically.

## [0.2.0] - 2026-09-07

Schema version 2. Existing installs add one migration:

```elixir
def up, do: AuroraMeter.Migration.up(from: 2)
def down, do: AuroraMeter.Migration.down(to: 2)
```

(`mix aurora_meter.gen.migration -r MyApp.Repo --from 2` generates it.)

### Added

- **Usage history** — UTC day buckets are maintained next to the period counter
  (same ETS hot path, flushed to the new `aurora_meter_history` table) and read
  back with `AuroraMeter.history/3`, giving charts without durable events.
  Off with `config :aurora_meter, history: false`.
- **`AuroraMeter.quota/2`** — one dashboard-ready map per feature: kind, used,
  limit / included, remaining, overage, percent and the current period.
- **`AuroraMeter.period/1`** — the tenant's current billing window.
- **Subscription cache** — `AuroraMeter.Subscriptions` memoises the plan lookup
  in ETS (`:subscription_cache_ttl`, default 5 s) and evicts on every
  `Storage.put_subscription/1`, locally and across nodes via PubSub. `check/2`,
  `reserve/3` and `with_quota/4` no longer touch the database per call.
- **Versioned migrations** — `AuroraMeter.Migration.up/1` and `down/1` take
  `:version`, `:from` and `:to`; every version is idempotent.
- **Telemetry** — `[:aurora_meter, :reserve]` with `%{qty}` and the outcome
  (`:ok`, `:limit_exceeded`, `:not_entitled`) in metadata.
- `AuroraMeter.Schema.Subscription.entitled_statuses/0` and `entitled?/1`.

### Fixed

- The flusher now traps exits, so the final flush actually runs on shutdown; a
  deploy no longer drops up to one flush interval of usage.
- Live updates could be lost when a flush landed between a `track` and the next
  broadcast tick; the broadcaster now keeps its own touched set.
- A subscription in a non-entitled status (`canceled`, `unpaid`, `incomplete`,
  ...) kept granting its plan; it now falls back to the default plan.
- `mix aurora_meter.gen.migration` failed in a host app because the repo was
  never loaded; it now calls `Mix.Ecto.ensure_repo/2` first.
- `usage_meter/1` shows the included allowance and overage for metered features
  and the enabled state for boolean features instead of a bare count.

## [0.1.0] - 2026-07-11

Initial release of the free core.

### Added

- **Metering** — `AuroraMeter.track/4`, `usage/2`, `usage_all/1`. ETS-backed
  atomic counters (`:ets.update_counter`), never touching the database on the hot
  path; ~8M increments/sec aggregate. Interval `Flusher` persists absolute-value
  snapshots (idempotent); interval `Broadcaster` fans live values over PubSub.
  Per-feature `:durable` mode also writes a raw event row.
- **Entitlements** — `check/2`, `allowed?/2`, `entitled?/2`, `remaining/2`,
  `reserve/2,3`, and `with_quota/3,4` (atomic reserve + release-on-raise; correct
  hard-limit enforcement under concurrency). Hard limits block; metered features
  allow overage; undeclared features are permissive.
- **Plans** — a compile-time DSL (`use AuroraMeter.Plans`) with `plan`, `price`,
  `limit`, `metered`, and `feature`, validated at compile time.
- **Subscriptions** — local `subscribe/2` and `plan/1`, with a configurable
  default plan.
- **Billing seam** — `AuroraMeter.Billing.Provider` behaviour + `Noop` default +
  a `Billing` facade, so the core works standalone and Pro plugs in.
- **LiveView** — `usage_meter/1` and `usage_summary/1` components (behind the
  optional LiveView deps) and `AuroraMeter.LiveView.subscribe/1`.
- **Storage** — `AuroraMeter.Storage` behaviour + Ecto/Postgres adapter;
  `AuroraMeter.Migration` and `mix aurora_meter.gen.migration` / `install`.
- **Config** — `NimbleOptions`-validated configuration (fail fast at boot).
- **Telemetry** — `[:aurora_meter, :track | :flush | :broadcast]`.
- **Bench** — `mix aurora_meter.bench`.
