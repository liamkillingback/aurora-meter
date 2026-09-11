# Changelog

All notable changes to Aurora Meter are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-09-11

The first release carrying code since 0.3.0 — 0.3.1 and 0.3.2 were
documentation and package metadata only. It brings the prepaid credit ledger,
the `counter` feature kind and the money series, together with a large body of
correctness work from auditing all three against a live Stripe sandbox.

**Schema versions 3, 4 and 5.** Existing installs add one migration
(`mix aurora_meter.gen.migration -r MyApp.Repo --from 3` generates it):

```elixir
def up, do: AuroraMeter.Migration.up(from: 3)
def down, do: AuroraMeter.Migration.down(to: 3)
```

Version 3 is the credit ledger tables, version 4 adds `promotional_after` to
every ledger entry, and version 5 a partial index for the open-hold sweep. All
three are required: the ledger writes `promotional_after` on every entry.

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
