# Configuration

All configuration lives under the `:aurora_meter` application key and is
validated at boot by `AuroraMeter.Config.validate!/0` (called from
`AuroraMeter.start_link/1`), which raises on a missing required key, a wrong
type, or a module-typed key naming a module that does not implement its
behaviour.

Validation reads the **whole** `:aurora_meter` environment. A key that is not in
the table below is reported, with the nearest known key named for you: in this
release that is a warning at boot, and in Aurora Meter 1.0 it stops the boot.
`:ecto_repos`, `:included_applications` and repo configuration written under this
application (`config :aurora_meter, MyApp.Repo, ...`) are reserved and are never
treated as Aurora Meter keys.

| Key | Type | Required | Default |
|---|---|---|---|
| `:repo` | Ecto repo module | ✅ | — |
| `:pubsub` | `Phoenix.PubSub` server name | ✅ | — |
| `:plans` | module using `AuroraMeter.Plans` | ✅ | — |
| `:tenant` | `AuroraMeter.Tenant` impl | — | `AuroraMeter.Tenant.Default` |
| `:default_plan` | atom | — | `:free` |
| `:storage` | `AuroraMeter.Storage` impl | — | `AuroraMeter.Storage.Ecto` |
| `:provider` | `AuroraMeter.Billing.Provider` impl | — | `AuroraMeter.Billing.Noop` |
| `:period_source` | `AuroraMeter.Period` impl | — | `AuroraMeter.Period.Calendar` (see [periods](periods.md) for the contract) |
| `:clock` | `AuroraMeter.Clock` impl | — | `AuroraMeter.Clock.System`, the only value supported in production |
| `:undeclared_feature_policy` | `:allow \| :warn \| :deny \| :raise` | — | `:warn` in 0.5.x, `:deny` from 1.0. What the entitlement functions do with a feature the tenant's plan does not declare (see below) |
| `:plan_version_conflict` | `:raise \| :warn` | — | `:warn` in 0.5.x, `:raise` from 1.0. What `AuroraMeter.Plans.register!/0` does when a compiled plan version's commercial content differs from the snapshot registered for it (see below) |
| `:durable_features` | list of atoms | — | `[]`. **Deprecated**: the legacy durable-track list, see [metering](metering.md) |
| `:feature_sources` | map of atom to `:buffered \| :events` | — | `%{}`. Where each feature's commercial quantity comes from; anything not listed is `:buffered` (see below) |
| `:events_outbox` | `AuroraMeter.Events.Outbox` impl or `nil` | — | `nil`. Called inside the transaction that records an event, so an export intent commits with the fact |
| `:events_future_tolerance` | seconds | — | `300`. How far ahead of the node clock an `occurred_at` may be before `AuroraMeter.record/4` refuses it |
| `:record_timeout` | ms | — | `15_000`. How long one durable write may take before it is `{:error, {:unavailable, :timeout}}` |
| `:record_max_concurrency` | positive integer | — | `64`. How many callers may hold an open record transaction at once |
| `:flush_interval` | ms | — | `5_000` |
| `:broadcast_interval` | ms | — | `1_000` |
| `:metrics_interval` | ms | | `10_000`. How often the store and cluster gauges are sampled; `0` switches the internal timers off and you drive `AuroraMeter.Telemetry.emit_gauges/0` yourself ([telemetry](telemetry.md)) |
| `:metrics_feature_label` | boolean | | `false`. Whether `AuroraMeter.Telemetry.Metrics.metrics/1` tags on `:feature`. One time series per feature per metric, so it is opt-in |
| `:metrics_scan_ceiling` | rows | | `50_000`. The largest counters table the cluster lag gauge scans for `unreconciled_keys`; above it the measurement is omitted rather than reported as zero |
| `:history` | boolean | — | `true` — keep UTC day buckets for `AuroraMeter.history/3` |
| `:subscription_cache_ttl` | ms | — | `5_000` — how long a plan lookup is cached; `0` disables |
| `:cluster_sync` | boolean | — | `true` — exchange deltas and flushed totals between nodes so counters are cluster-wide ([clustering](clustering.md)) |
| `:credits_currency` | string | — | `"usd"` — stamped on new credit balance rows ([credits](credits.md)) |
| `:credits_overdraft_tolerance` | micro-dollars | — | `0` — how far below zero a hold or debit may take the available balance |
| `:credits_low_balance_threshold` | micro-dollars or `nil` | — | `nil` — fire the low-balance event when the available balance drops below it; a tenant's own threshold overrides it |
| `:credits_low_balance_handler` | `fun/1` or `nil` |  | `nil`. Called with `%{tenant_key, available, spendable, threshold, crossing_id}` after a low-balance crossing commits, in a supervised task, once per crossing |
| `:credits_low_balance_handler_timeout` | positive integer |  | `5_000`. Milliseconds one handler call may take before it is killed. The caller never waits for it, so the write is neither failed nor delayed |
| `:live_view_tenant` | `{module, function}` or `nil` | | `nil`. How `on_mount {AuroraMeter.LiveView, :subscribe}` finds the tenant, called with `(session, socket)`. There is no default resolver and the bare form raises without this key: `AuroraMeter.Tenant.Default` stringifies what it is given, so it maps `nil` to `""` and a fallback would put every unresolved tenant on one set of counters ([Phoenix](phoenix.md)) |

```elixir
config :aurora_meter,
  repo: MyApp.Repo,
  pubsub: MyApp.PubSub,
  plans: MyApp.Plans,
  default_plan: :free,
  undeclared_feature_policy: :deny,
  feature_sources: %{tokens: :events},
  flush_interval: 5_000,
  broadcast_interval: 1_000
```

## `:feature_sources`

Where each feature's commercial quantity comes from: `:buffered` (the ETS
counter, flushed to `aurora_meter_counters`) or `:events` (the sum of the
durable events `AuroraMeter.record/4` writes). Anything the map does not name is
`:buffered`, which is every feature in 0.4.x, so adding the key changes nothing
until you name a feature in it.

A feature has exactly one source, and two boot checks hold that line:

| Configuration | What happens at boot |
|---|---|
| a feature in both `:durable_features` and `:feature_sources` as `:events` | `ArgumentError` naming the feature; `AuroraMeter.start_link/1` does not return |
| a value that is neither `:buffered` nor `:events` | `NimbleOptions.ValidationError` naming the key |
| a feature declared `:events` that no plan declares | one warning per feature per node: the events are stored, but nothing will bill them |

Three call-time consequences, all covered in [metering](metering.md):
`AuroraMeter.track/4` and `AuroraMeter.reserve/2,3` raise `ArgumentError` for an
`:events` feature, `AuroraMeter.with_quota/4` releases its reservation instead of
committing it, and `AuroraMeter.history/3` returns zeros.

The source is read once, at boot. Rewriting the key at runtime with
`Application.put_env/3` changes the declaration and not the behaviour: a source
that could change between two calls inside one period is precisely the double
count the key exists to prevent, so changing a source is a deploy.

## `:undeclared_feature_policy`

A feature the tenant's **effective plan** does not declare is not a question
Aurora Meter can answer, and until 0.5.0 it answered it permissively anyway. The
policy says what to do instead. A feature some *other* plan declares counts as
undeclared here: a `:free` tenant reaching a `:pro` only feature is exactly the
case this exists for.

| Entry point | `:allow` | `:warn` | `:deny` | `:raise` |
|---|---|---|---|---|
| `AuroraMeter.check/2` | `:ok` | `:ok` plus one log | `{:error, :not_entitled}` | raises |
| `allowed?/2`, `entitled?/2` | `true` | `true` plus one log | `false` | raises |
| `feature_value/3` | the default | the default plus one log | the default | raises |
| `quota/2` | `kind: :undeclared, enabled: true` | same plus one log | `kind: :undeclared, enabled: false` | raises |
| `remaining/2` | `:unlimited` | `:unlimited` plus one log | `0` | raises |
| `reserve/2,3` | counts, `:ok` | counts, `:ok`, one log | `{:error, :not_entitled}`, counter untouched | raises, counter untouched |
| `with_quota/3,4` | runs the function | runs it, one log | `{:error, :not_entitled}`, not run | raises, not run |
| `track/4` | counts | counts | counts | counts |

Every entry point keeps its documented return shape under every policy; only the
value inside it changes. `:warn` behaves exactly as `:allow` and logs once per
feature per node. `:raise` raises `AuroraMeter.UndeclaredFeatureError`, which
carries the feature, the tenant key, the plan and the entry point.

`track/4` is deliberately outside the policy and keeps counting: metering is not
entitlement, and metering a name before it reaches a plan is a reasonable thing
to do. It reports the condition as `declared:` in `[:aurora_meter, :track]`
telemetry metadata instead. `declared:` there answers "does any plan declare this
name", because answering "is this tenant entitled to it" would mean resolving the
tenant's subscription on the hot path. `AuroraMeter.entitled?/2` answers the
entitlement question.

### Upgrading from 0.4.x

```elixir
# Keep the old behaviour exactly, and decide later:
config :aurora_meter, undeclared_feature_policy: :allow
```

The recommended sequence, in this order:

1. Run `mix aurora_meter.features --strict`. It lists what your configuration
   references that no plan declares, and every feature declared on some plans and
   not others, with the plans that would deny it.
2. Set `:warn` (the default in 0.5.x) and leave it for a release. Each undeclared
   feature logs once per node, which catches the names only reachable at runtime.
3. Fix the plans or the call sites, then set `:deny`.

A new install generated by `mix aurora_meter.install` starts at `:deny`.

## `:plan_version_conflict`

A plan version is immutable. `AuroraMeter.Plans.register!/0` runs at boot,
stores a snapshot of each compiled version, and compares the fingerprint of
every version it has seen before. Editing a price, a limit, a metered included
count or unit price, a feature value or a recurring credit **inside an existing
version** is a conflict.

```elixir
config :aurora_meter, plan_version_conflict: :raise   # the 1.0 default
config :aurora_meter, plan_version_conflict: :warn    # the 0.5.x default
```

`:raise` fails the boot with `AuroraMeter.PlanVersionConflictError`, naming the
plan, the version, both fingerprints and the remedy. `:warn` logs the same
message through `Logger.error/1` and continues.

**Neither setting reprices anybody.** A tenant is pinned to the version their
subscription names and resolves that version's stored definition either way;
the setting decides whether the host finds out at boot or in the log. The remedy
is always to publish the change as a new version:

```elixir
plan :pro, version: "2", effective_at: ~U[2026-10-01 00:00:00Z] do
  price 3_000
end
```

### Upgrading from 0.4.x

Leave it at the 0.5.x default of `:warn` for one release. If the log is quiet,
set `:raise`. If it is not, you have found a plan block somebody edited in
place, and the stored definitions are in `aurora_meter_plan_versions`:

```sql
SELECT plan_id, version, encode(fingerprint, 'hex'), definition
FROM aurora_meter_plan_versions ORDER BY plan_id, version;
```

`AuroraMeter.Plans.register!/0` is public, so a release task can run it (and
rescue the exception) before the rolling deploy starts, which is also what you
want when the subscriptions table is large enough that the first-boot assignment
would be long. Do not call it inside a transaction of your own.

## Module-typed keys with contracts

`:tenant`, `:storage`, `:provider`, `:period_source`, `:clock` and `:plans` are
all checked at boot: the module must be loadable and must export every callback
its behaviour declares and does not mark optional, or
`AuroraMeter.Config.validate!/0` raises an `ArgumentError` naming the key, the
module and the missing callback. The required callbacks are read from the
behaviour itself, so a new one is enforced without anyone updating a list. There
is deliberately no probe call with a synthetic tenant, because a custom period
source may legitimately raise for a tenant it does not know.

Two further boot checks are warnings rather than failures, because an existing
install must still start: a `:default_plan` that no plan declares (an error from
1.0), and a `metered` feature whose `unit_price` is a float (integer minor units
are the supported form).

One more check runs after the supervision tree is up, because it needs the
database: every row in `aurora_meter_credit_balances` must carry
`:credits_currency` (`AuroraMeter.Credits.assert_currency!/0`, which a host may
also call from its own health check). A mismatch raises
`AuroraMeter.Credits.CurrencyMismatchError` and the tree does not start; an
absent table, or a repo that is not running yet, logs one `:info` line and boots.

`:period_source` must export `current/2`. `containing/2` is optional. What it
returns is checked on **every** call by `AuroraMeter.Period.current!/2`: a
half-open UTC interval `[start, end)` containing the instant it was resolved
for, or an `AuroraMeter.Period.InvalidPeriodError` naming the source module. The
full contract, the error reasons and two recipes are in [periods](periods.md).

`:clock` must export `now/0`, `today/0`, `monotonic_ms/0` and `db_now/0`. The
only value supported in production is `AuroraMeter.Clock.System`; tests install
`AuroraMeter.Clock.Fixed` through `AuroraMeter.Test.with_clock/2`, which is the
supported way to freeze time. The four readings answer four different questions
and are not interchangeable: in particular `now/0` makes no monotonicity promise
and `db_now/0` is the one to compare against a persisted timestamp. See
[periods](periods.md).

## Subscription cache

`AuroraMeter.plan/1` (and therefore every `check`, `reserve` and `with_quota`)
resolves the tenant's subscription through `AuroraMeter.Subscriptions`, an ETS
cache with a short TTL. Every write through `AuroraMeter.Storage.put_subscription/1`
evicts the entry locally and broadcasts the eviction on the configured PubSub,
so other nodes drop it too. If you write to `aurora_meter_subscriptions` some
other way, call `AuroraMeter.Subscriptions.invalidate/1` afterwards (or set the
TTL to `0`).

## Tenants

A tenant can be any term; it is resolved to a stable string key by the configured
`AuroraMeter.Tenant` implementation (`to_string/1` by default). For structs,
provide your own:

```elixir
defmodule MyApp.MeterTenant do
  @behaviour AuroraMeter.Tenant
  @impl true
  def to_key(%MyApp.Org{id: id}), do: "org:#{id}"
end

config :aurora_meter, tenant: MyApp.MeterTenant
```
