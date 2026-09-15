# Changelog

All notable changes to Aurora Meter are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Everything below landed after the 0.5.0 transition release and is not in any
published version. The 0.5.0 section beneath is a historical record of that
release and is deliberately not rewritten, including its statement that the
schema version is 6: that was true of 0.5.0. **This branch carries schema 8.**

### Added

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

### Changed

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
