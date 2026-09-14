# API inventory

Everything Aurora Meter (the free core) offers a host application, with a
stability class per entry. It is the authority for what the support policy
covers: see [Support policy](support-policy.md).

If something is not on this page, it is not part of the supported surface, even
when the module or function happens to be public in the compiled code.

`test/aurora_meter/api_inventory_test.exs` checks this page against the code on
every `mix test`. Every `Module.function/arity` below must exist, no internal
module may be listed, and every telemetry event and PubSub tag must appear
verbatim in `lib/`.

## How to read this page

| Class | Meaning | Change rule |
|---|---|---|
| `stable` | Part of the supported surface. | Covered by SemVer. No breaking change before 2.0. Additive change is allowed in a minor release. |
| `optional-dep` | Stable, but it only exists when an optional dependency is installed. | Same promise as `stable`. The dependency's absence is documented and is never a compile error. |
| `deprecated` | Still works, warns, and is removed in 2.0. | Never removed during 1.x. |
| `internal` | Not part of the supported surface. | May change in any release, including a patch. Callers get no warning. |

`Since` is the package version that introduced the entry. `0.5.0` marks an entry
that is written but not yet published; it ships in the transition release.

Test helpers (`AuroraMeter.Test`, `AuroraMeter.Clock.Fixed`) are `stable`, but
they are for host test suites. Nothing in production should depend on them, and
the support policy governs them under its own heading rather than by SemVer on
every helper name.

## 1. Facade functions

### 1.1 `AuroraMeter`

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.version/0` | `() :: String.t()` | stable | 0.1.0 | The compiled package version. |
| `AuroraMeter.start_link/1` | `(keyword()) :: Supervisor.on_start()` | stable | 0.1.0 | Validates configuration, then starts the runtime. Add `AuroraMeter` to the host supervision tree instead of calling it directly. Raises `NimbleOptions.ValidationError` on bad configuration. |
| `AuroraMeter.track/4` | `(tenant, atom(), integer(), keyword()) :: :ok` | stable | 0.1.0 | Arities 2 and 3 exist through defaults (`qty` 1, `opts` `[]`). Options `:durable`, `:metadata`. Counts an undeclared feature under every policy. |
| `AuroraMeter.usage/2` | `(tenant, atom()) :: integer()` | stable | 0.1.0 | Current period, warm ETS value. |
| `AuroraMeter.usage_all/1` | `(tenant) :: %{atom() => integer()}` | stable | 0.1.0 | Warm counters only. |
| `AuroraMeter.history/3` | `(tenant, atom(), keyword()) :: [AuroraMeter.Storage.history_point()]` | stable | 0.2.0 | Options `:days` (30), `:from`, `:to`. Zero-filled, oldest first. Needs `history: true` and schema version 2. |
| `AuroraMeter.period/1` | `(tenant) :: AuroraMeter.Period.t()` | stable | 0.2.0 | Delegates to `AuroraMeter.Period.current!/2`, so an invalid period source raises here. |
| `AuroraMeter.subscribe/2` | `(tenant, atom() \| String.t()) :: {:ok, Subscription.t()} \| {:error, Ecto.Changeset.t()}` | stable | 0.1.0 | An unknown plan id warns in 0.5.x and returns `{:error, changeset}` from 1.0. |
| `AuroraMeter.plan/1` | `(tenant) :: AuroraMeter.Plan.t() \| nil` | stable | 0.1.0 | Falls back to `:default_plan` for a non-entitled subscription. |
| `AuroraMeter.check/2` | `(tenant, atom()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Advisory: a read then a compare. Use `reserve/3` for a hard limit. Honours `undeclared_feature_policy`. |
| `AuroraMeter.allowed?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | `check/2 == :ok`. |
| `AuroraMeter.entitled?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | Ignores quota. |
| `AuroraMeter.remaining/2` | `(tenant, atom()) :: non_neg_integer() \| :unlimited` | stable | 0.1.0 | |
| `AuroraMeter.feature_value/3` | `(tenant, atom(), default) :: boolean() \| non_neg_integer() \| default` | stable | 0.4.0 | Arity 2 exists through a `nil` default. |
| `AuroraMeter.quota/2` | `(tenant, atom()) :: AuroraMeter.Entitlements.quota()` | stable | 0.2.0 | Dashboard snapshot. `kind` is `:hard`, `:metered`, `:feature`, `:counter`, `:boolean` or `:undeclared`. |
| `AuroraMeter.reserve/2` | `(tenant, atom()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Atomic on one node. |
| `AuroraMeter.reserve/3` | `(tenant, atom(), pos_integer()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | |
| `AuroraMeter.with_quota/3` | `(tenant, atom(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | Releases the reservation on a raise, throw or exit. |
| `AuroraMeter.with_quota/4` | `(tenant, atom(), pos_integer(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | Reserve and release use the same captured period. |

### 1.2 `AuroraMeter.Entitlements`

The facade delegates to this module and is the recommended entry point. The
functions are listed because they are public, documented and called directly by
existing hosts.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Entitlements.check/2` | `(tenant, atom()) :: check_result()` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.allowed?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.entitled?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.remaining/2` | `(tenant, atom()) :: non_neg_integer() \| :unlimited` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.feature_value/3` | `(tenant, atom(), default) :: boolean() \| non_neg_integer() \| default` | stable | 0.4.0 | |
| `AuroraMeter.Entitlements.quota/2` | `(tenant, atom()) :: quota()` | stable | 0.2.0 | |
| `AuroraMeter.Entitlements.reserve/4` | `(tenant, atom(), pos_integer(), DateTime.t() \| nil) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Arities 2 and 3 exist through defaults. The fourth argument is a captured period start (0.4.0). |
| `AuroraMeter.Entitlements.with_quota/3` | `(tenant, atom(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.with_quota/4` | `(tenant, atom(), pos_integer(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.subscribe/2` | `(tenant, atom() \| String.t()) :: {:ok, Subscription.t()} \| {:error, Ecto.Changeset.t()}` | stable | 0.1.0 | |
| `AuroraMeter.Entitlements.plan/1` | `(tenant) :: AuroraMeter.Plan.t() \| nil` | stable | 0.1.0 | |

### 1.3 `AuroraMeter.Credits`

Micro-dollar integers throughout. See [Credits](credits.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.balance/1` | `(tenant) :: balance()` | stable | 0.4.0 | `%{balance, held, available, promotional, currency}`. |
| `AuroraMeter.Credits.available/1` | `(tenant) :: integer()` | stable | 0.4.0 | `balance - held`. |
| `AuroraMeter.Credits.sufficient?/2` | `(tenant, integer()) :: boolean()` | stable | 0.4.0 | Advisory, like `check/2`. |
| `AuroraMeter.Credits.grant/3` | `(tenant, pos_integer(), keyword()) :: {:ok, txn()} \| {:error, Ecto.Changeset.t()}` | stable | 0.4.0 | Idempotent on `reference:`. Options `:reference`, `:category` (`:paid`, `:promotional`, `:adjustment`), `:expires_at`, `:metadata`. The error shape changes in 1.0: see section 4. |
| `AuroraMeter.Credits.grant_with_status/3` | `(tenant, pos_integer(), keyword()) :: {:ok, txn(), :new \| :duplicate} \| {:error, Ecto.Changeset.t()}` | stable | 0.4.0 | Reports new or duplicate from inside the balance row's lock. |
| `AuroraMeter.Credits.hold/4` | `(tenant, pos_integer(), String.t(), keyword()) :: {:ok, txn()} \| {:error, :insufficient_credits \| :duplicate_reference}` | stable | 0.4.0 | Arity 3 exists through an empty option list. |
| `AuroraMeter.Credits.settle/3` | `(String.t(), non_neg_integer(), keyword()) :: {:ok, txn()} \| {:error, :not_found \| :already_settled}` | stable | 0.4.0 | Keyed by the hold's reference, not by tenant. Arity 2 exists through defaults. |
| `AuroraMeter.Credits.release/1` | `(String.t()) :: {:ok, txn()} \| {:error, :not_found \| :already_settled}` | stable | 0.4.0 | |
| `AuroraMeter.Credits.debit/4` | `(tenant, pos_integer(), String.t(), map()) :: {:ok, txn()} \| {:error, :insufficient_credits \| :duplicate_reference}` | stable | 0.4.0 | Arity 3 exists through an empty metadata map. |
| `AuroraMeter.Credits.reverse/4` | `(tenant, pos_integer(), String.t(), map()) :: {:ok, txn()} \| {:error, :duplicate_reference}` | stable | 0.4.0 | Never refused for want of balance: the balance may go negative, which is the honest record of a debt. |
| `AuroraMeter.Credits.with_credits/4` | `(tenant, pos_integer(), String.t(), (-> {:ok, result, non_neg_integer()} \| {:error, term()})) :: {:ok, result} \| {:error, :insufficient_credits \| :duplicate_reference \| term()}` | stable | 0.4.0 | Holds, runs, then settles or releases, including on a raise. |
| `AuroraMeter.Credits.pending_holds/1` | `(keyword()) :: [txn()]` | stable | 0.4.0 | Options `:older_than`, `:reference_prefix`, `:limit`. Oldest first. |
| `AuroraMeter.Credits.history/2` | `(tenant, keyword()) :: [txn()]` | stable | 0.4.0 | Options `:limit` (50), `:kinds`. Holds and releases are hidden unless asked for. |
| `AuroraMeter.Credits.spend_history/2` | `(tenant, keyword()) :: [money_point()]` | stable | 0.4.0 | Options `:days` (30) or `:from`/`:to`, `:bucket` (`:day` or `:month`), `:kinds`. Zero-filled, oldest first. |
| `AuroraMeter.Credits.spend_total/2` | `(tenant, keyword()) :: money_total()` | stable | 0.4.0 | `%{spent, granted, net, from, to}`. |
| `AuroraMeter.Credits.summary/1` | `(tenant) :: summary()` | stable | 0.4.0 | `daily_burn` and `runway_days` are `nil` when there is nothing honest to report. |
| `AuroraMeter.Credits.set_low_balance_threshold/2` | `(tenant, integer() \| nil) :: {:ok, CreditBalance.t()}` | stable | 0.4.0 | Overrides `:credits_low_balance_threshold` for one tenant. |
| `AuroraMeter.Credits.expire_due/1` | `(DateTime.t()) :: {:ok, non_neg_integer()}` | stable | 0.4.0 | Arity 0 exists and defaults to `AuroraMeter.Clock.db_now/0`, because it compares against a persisted `expires_at`. |
| `AuroraMeter.Credits.subscribe/1` | `(tenant) :: :ok \| {:error, term()}` | stable | 0.4.0 | Subscribes the calling process to `topic/1`. |
| `AuroraMeter.Credits.topic/1` | `(String.t()) :: String.t()` | stable | 0.4.0 | `"aurora_meter:credits:" <> tenant_key`. Takes a resolved key, not a tenant term. |
| `AuroraMeter.Credits.assert_currency!/0` | `() :: :ok` | stable | 0.5.0 | Raises `AuroraMeter.Credits.CurrencyMismatchError` when a stored balance row carries a currency other than `:credits_currency`. Skipped with one `:info` line when the repo or the tables are absent. |

### 1.4 `AuroraMeter.Credits.Money`

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.Money.from_cents/1` | `(integer()) :: micro()` | stable | 0.4.0 | |
| `AuroraMeter.Credits.Money.to_cents/2` | `(micro(), keyword()) :: integer()` | stable | 0.4.0 | Option `:rounding` (`:round`, `:floor`, `:ceil`). Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Money.from_decimal/1` | `(Decimal.t()) :: micro()` | stable | 0.4.0 | Requires `Decimal`, which arrives transitively with Ecto. |
| `AuroraMeter.Credits.Money.format/2` | `(micro(), keyword()) :: String.t()` | stable | 0.4.0 | Option `:precision` (0 to 6). Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Money.format_compact/1` | `(micro()) :: String.t()` | stable | 0.4.0 | Never rounds a sub-cent amount away to `"$0.00"`. |

### 1.5 Plans

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Plans.all/0` | `() :: %{optional(atom()) => AuroraMeter.Plan.t()}` | stable | 0.1.0 | |
| `AuroraMeter.Plans.get/1` | `(atom()) :: AuroraMeter.Plan.t() \| nil` | stable | 0.1.0 | |
| `AuroraMeter.Plans.feature_config/2` | `(atom(), atom()) :: AuroraMeter.Plan.feature_config() \| nil` | stable | 0.1.0 | |
| `AuroraMeter.Plans.feature_value/3` | `(atom(), atom(), default) :: boolean() \| non_neg_integer() \| default` | stable | 0.4.0 | Arity 2 exists through a `nil` default. |
| `AuroraMeter.Plans.declared_anywhere?/1` | `(atom()) :: boolean()` | stable | 0.5.0 | Whether any plan declares the feature. Behind the `declared:` telemetry metadata. |
| `AuroraMeter.Plans.plan/2` | DSL macro | stable | 0.1.0 | Only inside a module that `use`s `AuroraMeter.Plans`. |
| `AuroraMeter.Plans.price/1` | DSL macro | stable | 0.1.0 | Minor units (cents), integer. |
| `AuroraMeter.Plans.limit/3` | DSL macro | stable | 0.1.0 | `limit :feature, count, :hard` or `:soft`. |
| `AuroraMeter.Plans.metered/2` | DSL macro | stable | 0.1.0 | Options `:included`, `:unit_price`. Integer `unit_price` is the supported form; a float warns at boot from 0.5.0. |
| `AuroraMeter.Plans.feature/2` | DSL macro | stable | 0.1.0 | Boolean or non-negative integer value. |
| `AuroraMeter.Plans.counter/1` | DSL macro | stable | 0.4.0 | Measured, never blocked, never billed. `quota/2` reports `limit`, `included` and `percent` as `nil`. |

### 1.6 Periods and the clock

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Period.current/2` | `(tenant, DateTime.t()) :: t()` | stable | 0.1.0 | Unvalidated. Arity 1 exists and defaults to `AuroraMeter.Clock.now/0`. |
| `AuroraMeter.Period.current!/2` | `(tenant, DateTime.t()) :: t()` | stable | 0.5.0 | The validated read every core call site uses. Raises `AuroraMeter.Period.InvalidPeriodError` naming the source module. |
| `AuroraMeter.Period.containing/2` | `(tenant, DateTime.t()) :: t()` | stable | 0.5.0 | The period that held a past instant. Uses the source's optional `c:AuroraMeter.Period.containing/2` when it exports one, `c:AuroraMeter.Period.current/2` with the instant otherwise. |
| `AuroraMeter.Clock.now/0` | `() :: DateTime.t()` | stable | 0.5.0 | Wall-clock shaped and cheap. **Promises no monotonicity and may step backwards.** |
| `AuroraMeter.Clock.today/0` | `() :: Date.t()` | stable | 0.5.0 | Derived from `now/0` in one reading. |
| `AuroraMeter.Clock.monotonic_ms/0` | `() :: integer()` | stable | 0.5.0 | In-memory elapsed spans only. Never persisted, never compared across nodes. |
| `AuroraMeter.Clock.db_now/0` | `() :: DateTime.t()` | stable | 0.5.0 | `clock_timestamp()` through the configured repo. The clock for anything compared against a persisted timestamp. Costs a round trip. |
| `AuroraMeter.Clock.System.now/0` | `() :: DateTime.t()` | stable | 0.5.0 | The production implementation. |
| `AuroraMeter.Clock.System.today/0` | `() :: Date.t()` | stable | 0.5.0 | |
| `AuroraMeter.Clock.System.monotonic_ms/0` | `() :: integer()` | stable | 0.5.0 | |
| `AuroraMeter.Clock.System.db_now/0` | `() :: DateTime.t()` | stable | 0.5.0 | |

### 1.7 Storage dispatchers

Each function dispatches to the configured `:storage` module. The callbacks are
in section 2.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Storage.upsert_counters/1` | `([counter_row()]) :: :ok` | stable | 0.1.0 | Absolute values. |
| `AuroraMeter.Storage.add_counters/1` | `([counter_delta()]) :: {:ok, [counter_total()]}` | stable | 0.3.0 | Deltas, returning the authoritative totals. |
| `AuroraMeter.Storage.add_history/1` | `([history_delta()]) :: {:ok, [history_total()]}` | stable | 0.3.0 | |
| `AuroraMeter.Storage.upsert_history/1` | `([history_row()]) :: :ok` | stable | 0.2.0 | |
| `AuroraMeter.Storage.flush_batch/3` | `(Ecto.UUID.t(), [counter_delta()], [history_delta()]) :: {:ok, [counter_total()]} \| {:error, term()}` | stable | 0.4.0 | Receipt plus both delta sets in one transaction. |
| `AuroraMeter.Storage.load_counter/3` | `(String.t(), atom() \| String.t(), DateTime.t()) :: integer() \| nil` | stable | 0.1.0 | Accepts a string feature, because stored rows carry strings. |
| `AuroraMeter.Storage.load_history/3` | `(String.t(), atom() \| String.t(), Date.t()) :: integer() \| nil` | stable | 0.2.0 | |
| `AuroraMeter.Storage.load_history_range/4` | `(String.t(), atom() \| String.t(), Date.t(), Date.t()) :: [history_point()]` | stable | 0.2.0 | |
| `AuroraMeter.Storage.get_subscription/1` | `(String.t()) :: Subscription.t() \| nil` | stable | 0.1.0 | |
| `AuroraMeter.Storage.put_subscription/1` | `(map()) :: {:ok, Subscription.t()} \| {:error, Ecto.Changeset.t()}` | stable | 0.1.0 | Evicts the subscription cache locally and across nodes. |
| `AuroraMeter.Storage.insert_events/1` | `([event_row()]) :: :ok` | stable | 0.1.0 | The legacy `durable: true` path. |
| `AuroraMeter.Storage.stream_counters/1` | `(DateTime.t()) :: [AuroraMeter.Schema.Counter.t()]` | stable | 0.1.0 | One exact `period_start`. A keyset variant over a period range arrives with the rollup rewrite. |

### 1.8 Subscriptions, flusher, live updates

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Subscriptions.get/1` | `(tenant) :: Subscription.t() \| nil` | stable | 0.2.0 | Cached for `:subscription_cache_ttl` milliseconds. |
| `AuroraMeter.Subscriptions.invalidate/1` | `(tenant) :: :ok` | stable | 0.2.0 | Evicts locally and broadcasts the eviction. |
| `AuroraMeter.Flusher.flush/0` | `() :: {:ok, non_neg_integer()} \| {:error, term()}` | stable | 0.1.0 | The operational "flush before you report" hook. An error retains the batch for an idempotent retry (0.4.0). |
| `AuroraMeter.Broadcaster.topic/1` | `(String.t()) :: String.t()` | stable | 0.1.0 | `"aurora_meter:tenant:" <> tenant_key`. The only entry of `AuroraMeter.Broadcaster` that is supported; the module itself is internal. Read the contract on `AuroraMeter.LiveView`. |
| `AuroraMeter.LiveView.subscribe/1` | `(tenant) :: :ok \| {:error, term()}` | stable | 0.1.0 | Subscribes the calling process to the tenant's usage topic. |

### 1.9 Configuration accessors

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Config.validate!/0` | `() :: keyword()` | stable | 0.1.0 | Called by `AuroraMeter.start_link/1`. Validates the whole application environment. |
| `AuroraMeter.Config.repo/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.pubsub/0` | `() :: atom()` | stable | 0.1.0 | |
| `AuroraMeter.Config.plans/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.tenant/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.default_plan/0` | `() :: atom()` | stable | 0.1.0 | |
| `AuroraMeter.Config.storage/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.provider/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.period_source/0` | `() :: module()` | stable | 0.1.0 | |
| `AuroraMeter.Config.clock/0` | `() :: module()` | stable | 0.5.0 | |
| `AuroraMeter.Config.undeclared_feature_policy/0` | `() :: :allow \| :warn \| :deny \| :raise` | stable | 0.5.0 | |
| `AuroraMeter.Config.policy_for/1` | `(atom()) :: :allow \| :warn \| :deny \| :raise` | stable | 0.5.0 | The seam every entitlement entry point consults. |
| `AuroraMeter.Config.durable_features/0` | `() :: [atom()]` | deprecated | 0.1.0 | Reads the deprecated `:durable_features` key. |
| `AuroraMeter.Config.flush_interval/0` | `() :: pos_integer()` | stable | 0.1.0 | |
| `AuroraMeter.Config.broadcast_interval/0` | `() :: pos_integer()` | stable | 0.1.0 | |
| `AuroraMeter.Config.history?/0` | `() :: boolean()` | stable | 0.2.0 | |
| `AuroraMeter.Config.subscription_cache_ttl/0` | `() :: non_neg_integer()` | stable | 0.2.0 | |
| `AuroraMeter.Config.cluster_sync?/0` | `() :: boolean()` | stable | 0.3.0 | |
| `AuroraMeter.Config.credits_currency/0` | `() :: String.t()` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_overdraft_tolerance/0` | `() :: non_neg_integer()` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_low_balance_threshold/0` | `() :: integer() \| nil` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_low_balance_handler/0` | `() :: (map() -> term()) \| nil` | stable | 0.4.0 | |

### 1.10 Billing seam

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Billing.checkout/3` | `(tenant, atom() \| String.t(), keyword()) :: {:ok, String.t()} \| {:error, term()}` | stable | 0.1.0 | Arity 2 exists through defaults. |
| `AuroraMeter.Billing.portal_url/2` | `(tenant, keyword()) :: {:ok, String.t()} \| {:error, term()}` | stable | 0.1.0 | Arity 1 exists through defaults. |
| `AuroraMeter.Billing.sync_subscription/1` | `(map()) :: {:ok, term()} \| {:error, term()}` | stable | 0.1.0 | |

### 1.11 Schema helpers

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Schema.Subscription.entitled?/1` | `(Subscription.t() \| nil) :: boolean()` | stable | 0.2.0 | |
| `AuroraMeter.Schema.Subscription.entitled_statuses/0` | `() :: [String.t()]` | stable | 0.2.0 | |
| `AuroraMeter.Schema.Subscription.changeset/2` | `(Subscription.t(), map()) :: Ecto.Changeset.t()` | stable | 0.1.0 | |
| `AuroraMeter.Schema.CreditBalance.changeset/2` | `(CreditBalance.t(), map()) :: Ecto.Changeset.t()` | stable | 0.4.0 | |
| `AuroraMeter.Schema.CreditTransaction.changeset/2` | `(CreditTransaction.t(), map()) :: Ecto.Changeset.t()` | stable | 0.4.0 | |
| `AuroraMeter.Schema.CreditTransaction.kinds/0` | `() :: [kind()]` | stable | 0.4.0 | |
| `AuroraMeter.Schema.CreditTransaction.categories/0` | `() :: [category()]` | stable | 0.4.0 | |

### 1.12 HEEx components (optional dependency)

Compiled only when `Phoenix.Component` is loaded. Without `phoenix_live_view`
and `phoenix_html` the module does not exist at all, which is not an error:
everything else in this inventory works headless.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Components.usage_meter/1` | HEEx component | optional-dep | 0.1.0 | Needs `phoenix_live_view` and `phoenix_html`. Attributes are declared with `attr/3` and render in the module docs. |
| `AuroraMeter.Components.usage_summary/1` | HEEx component | optional-dep | 0.1.0 | Needs `phoenix_live_view` and `phoenix_html`. |
| `AuroraMeter.Components.spend_chart/1` | HEEx component | optional-dep | 0.4.0 | Needs `phoenix_live_view` and `phoenix_html`. |
| `AuroraMeter.Components.credit_summary/1` | HEEx component | optional-dep | 0.4.0 | Needs `phoenix_live_view` and `phoenix_html`. |

## 2. Behaviours and their callbacks

A host or an extension implements these. Adding a required callback to one of
them is a breaking change for implementers and does not happen during 1.x.

<!-- inventory:modules -->

| Entry | Callbacks | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Tenant` | `to_key/1` | stable | 0.1.0 | Must return a non-empty binary, and **a binary must pass through unchanged**: Pro hands stored `tenant_key` values back to facade functions. |
| `AuroraMeter.Period` | `current/2` required, `containing/2` optional | stable | 0.1.0 | `containing/2` is optional from 0.5.0. |
| `AuroraMeter.Clock` | `now/0`, `today/0`, `monotonic_ms/0`, `db_now/0` | stable | 0.5.0 | Four readings, all required. |
| `AuroraMeter.Storage` | `upsert_counters/1`, `add_counters/1`, `upsert_history/1`, `add_history/1`, `flush_batch/3`, `load_counter/3`, `load_history/3`, `load_history_range/4`, `get_subscription/1`, `put_subscription/1`, `insert_events/1`, `stream_counters/1` | stable | 0.1.0 | 12 callbacks, none optional. |
| `AuroraMeter.Billing.Provider` | `create_checkout_session/2`, `billing_portal_url/2`, `sync_subscription/1`, `report_usage/1` | stable | 0.1.0 | Aurora Meter Pro implements it for Stripe. |

The implementations the core ships:

<!-- inventory:modules -->

| Entry | Implements | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Tenant.Default` | `AuroraMeter.Tenant` | stable | 0.1.0 | Binaries pass through, other terms are stringified. |
| `AuroraMeter.Period.Calendar` | `AuroraMeter.Period` | stable | 0.1.0 | UTC calendar month. |
| `AuroraMeter.Clock.System` | `AuroraMeter.Clock` | stable | 0.5.0 | The only implementation supported in production. |
| `AuroraMeter.Storage.Ecto` | `AuroraMeter.Storage` | internal | 0.1.0 | Configure it by name (it is the default); do not call it directly. |
| `AuroraMeter.Billing.Noop` | `AuroraMeter.Billing.Provider` | stable | 0.1.0 | The default provider. Every call returns `{:error, :not_configured}`. |

`AuroraMeter.Config.validate!/0` checks at boot that every module-typed key
names a module that exists and exports every callback its behaviour declares and
does not mark optional. The callback list is read from `behaviour_info/1`, never
copied.

## 3. Structs and public types

<!-- inventory:modules -->

| Entry | Shape | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Plan` | `%Plan{id, price, features}` | stable | 0.1.0 | Built by the DSL. `feature_config/0` is the per-feature union. |
| `AuroraMeter.Schema.Counter` | `aurora_meter_counters` row | stable | 0.1.0 | |
| `AuroraMeter.Schema.History` | `aurora_meter_history` row | stable | 0.2.0 | |
| `AuroraMeter.Schema.Event` | `aurora_meter_events` row | stable | 0.1.0 | The legacy durable-track row. |
| `AuroraMeter.Schema.Subscription` | `aurora_meter_subscriptions` row | stable | 0.1.0 | |
| `AuroraMeter.Schema.CreditBalance` | `aurora_meter_credit_balances` row | stable | 0.4.0 | |
| `AuroraMeter.Schema.CreditTransaction` | `aurora_meter_credit_transactions` row | stable | 0.4.0 | |
| `AuroraMeter.UndeclaredFeatureError` | exception | stable | 0.5.0 | Raised under `undeclared_feature_policy: :raise`. Fields `feature`, `tenant_key`, `plan_id`, `entry`, `reason`. |
| `AuroraMeter.Period.InvalidPeriodError` | exception | stable | 0.5.0 | Fields `source`, `tenant_key`, `period`, `instant`, `reason`. |
| `AuroraMeter.Credits.CurrencyMismatchError` | exception | stable | 0.5.0 | Fields `configured`, `stored`. |

Named types a host will meet in a spec: `t:AuroraMeter.Period.t/0`,
`t:AuroraMeter.Entitlements.quota/0` and `t:AuroraMeter.Entitlements.check_result/0`,
`t:AuroraMeter.Credits.balance/0`, `t:AuroraMeter.Credits.money_point/0`,
`t:AuroraMeter.Credits.money_total/0`, `t:AuroraMeter.Credits.summary/0` and
`t:AuroraMeter.Credits.txn/0`, `t:AuroraMeter.Credits.Money.micro/0`,
`t:AuroraMeter.Storage.counter_row/0`, `t:AuroraMeter.Storage.history_row/0`,
`t:AuroraMeter.Storage.history_point/0`, `t:AuroraMeter.Storage.event_row/0`,
`t:AuroraMeter.Storage.counter_delta/0`, `t:AuroraMeter.Storage.history_delta/0`,
`t:AuroraMeter.Storage.counter_total/0` and `t:AuroraMeter.Storage.history_total/0`,
`t:AuroraMeter.Plan.t/0` and `t:AuroraMeter.Plan.feature_config/0`,
`t:AuroraMeter.Clock.Fixed.unit/0`, and
`t:AuroraMeter.Schema.CreditTransaction.kind/0`,
`t:AuroraMeter.Schema.CreditTransaction.category/0` and
`t:AuroraMeter.Schema.CreditTransaction.status/0`.

## 4. Return values and error tuples

Aurora Meter 0.x grew three return families, and they are not uniform. Listing
them as if they were would be a false claim, so they are stated as they are,
with the one change 1.0 makes.

**Entitlement family.** `check/2` returns `:ok | {:error, :limit_exceeded |
:not_entitled}`. `allowed?/2` and `entitled?/2` return booleans. `remaining/2`
returns `non_neg_integer() | :unlimited`. `quota/2` returns the `quota()` map.
`reserve/2,3` returns the same shape as `check/2`. `with_quota/3,4` returns
`{:ok, result} | {:error, term()}`. Every one of these keeps its shape under
every `undeclared_feature_policy`; the policy changes the answer, never the
shape. Under `:raise` they raise `AuroraMeter.UndeclaredFeatureError` instead of
answering.

**Credits family.** `grant/3` and `grant_with_status/3` return
`{:error, Ecto.Changeset.t()}`, while `hold/4`, `settle/3`, `release/1`,
`debit/4`, `reverse/4` and `with_credits/4` return a bare atom reason
(`:insufficient_credits`, `:duplicate_reference`, `:not_found`,
`:already_settled`). **This inconsistency changes in 1.0**: the grant functions
move to the atom family, and the migration note will name the exact mapping. A
caller that matches `{:error, %Ecto.Changeset{}}` on a grant today should expect
to revisit it, and it is called out here rather than papered over.

Refusals never roll back the caller's transaction. Every refusal in the ledger
is decided before anything is written and returns `{:error, reason}`.

**Idempotency keys.** The credit ledger keys on `reference:` (a string).
Aurora Meter Pro's outbox payload uses `identifier` internally. There is one
rule and this page states it rather than inventing another: an idempotency key
option is named `reference:` for credits, and `id:` for events.

**Money.** Micro-dollar integers in the ledger, minor units (cents) at provider
boundaries through `AuroraMeter.Credits.Money`. A plan's `price` and a metered
`unit_price` are in cents. Financial values never round inside a transaction.

## 5. Configuration keys

Every key is validated by NimbleOptions at boot. An unknown key is reported with
the nearest known key named: a warning in 0.5.x, a refusal to boot in 1.0.
`:ecto_repos`, `:included_applications` and repo configuration written under the
same application (`config :aurora_meter, MyApp.Repo, ...`) are reserved and are
never treated as Aurora Meter keys.

<!-- inventory:config -->

| Key | Type and default | Class | Since | Notes |
|---|---|---|---|---|
| `:repo` | atom, required | stable | 0.1.0 | The host Ecto repo. |
| `:pubsub` | atom, required | stable | 0.1.0 | The host `Phoenix.PubSub` server name. |
| `:plans` | atom, required | stable | 0.1.0 | A module that `use`s `AuroraMeter.Plans`. |
| `:tenant` | atom, `AuroraMeter.Tenant.Default` | stable | 0.1.0 | Must implement `AuroraMeter.Tenant`. |
| `:default_plan` | atom, `:free` | stable | 0.1.0 | Naming no plan warns from 0.5.0 and is an error in 1.0. |
| `:storage` | atom, `AuroraMeter.Storage.Ecto` | stable | 0.1.0 | Must implement `AuroraMeter.Storage`. |
| `:provider` | atom, `AuroraMeter.Billing.Noop` | stable | 0.1.0 | Must implement `AuroraMeter.Billing.Provider`. |
| `:period_source` | atom, `AuroraMeter.Period.Calendar` | stable | 0.1.0 | Must implement `AuroraMeter.Period`. |
| `:clock` | atom, `AuroraMeter.Clock.System` | stable | 0.5.0 | Must implement `AuroraMeter.Clock`. `AuroraMeter.Clock.System` is the only value supported in production. |
| `:undeclared_feature_policy` | `:allow \| :warn \| :deny \| :raise`, `:warn` in 0.5.x and `:deny` from 1.0 | stable | 0.5.0 | `:allow` restores the 0.4.x behaviour exactly. `track/4` is outside the policy. |
| `:durable_features` | list of atoms, `[]` | deprecated | 0.1.0 | The legacy durable-track list. Kept and warned through 1.x, removed in 2.0. |
| `:flush_interval` | positive integer, `5_000` | stable | 0.1.0 | Milliseconds. |
| `:broadcast_interval` | positive integer, `1_000` | stable | 0.1.0 | Milliseconds. |
| `:history` | boolean, `true` | stable | 0.2.0 | UTC day buckets for `AuroraMeter.history/3`. |
| `:subscription_cache_ttl` | non-negative integer, `5_000` | stable | 0.2.0 | Milliseconds. `0` disables the cache. |
| `:cluster_sync` | boolean, `true` | stable | 0.3.0 | Delta gossip and total announcements between nodes. |
| `:credits_currency` | string, `"usd"` | stable | 0.4.0 | ISO 4217, stamped on new balance rows and checked at boot from 0.5.0. |
| `:credits_overdraft_tolerance` | non-negative integer, `0` | stable | 0.4.0 | Micro-dollars. |
| `:credits_low_balance_threshold` | integer or `nil`, `nil` | stable | 0.4.0 | Micro-dollars. A balance row's own threshold overrides it. |
| `:credits_low_balance_handler` | 1-arity function or `nil`, `nil` | stable | 0.4.0 | Called with `%{tenant_key, available, threshold}` after the crossing commits. |

## 6. Telemetry events

Event names, measurement keys and metadata keys are covered by SemVer. The
`Matched in lib/` column holds the exact source text the inventory test greps
for, so a renamed event fails the build.

<!-- inventory:literal -->

| Event | Measurements | Metadata | Class | Since | Matched in lib/ |
|---|---|---|---|---|---|
| `[:aurora_meter, :track]` | `count` | `tenant_key`, `feature`, `declared` | stable | 0.1.0 | `[:aurora_meter, :track]` |
| `[:aurora_meter, :reserve]` | `qty` | `tenant_key`, `feature`, `result`, `declared` | stable | 0.2.0 | `[:aurora_meter, :reserve]` |
| `[:aurora_meter, :flush]` | `count`, `delta_sum` | none | stable | 0.1.0 | `[:aurora_meter, :flush]` |
| `[:aurora_meter, :flush, :error]` | `count` | `error` | stable | 0.3.0 | `[:aurora_meter, :flush, :error]` |
| `[:aurora_meter, :broadcast]` | `count`, `deltas` | none | stable | 0.1.0 | `[:aurora_meter, :broadcast]` |
| `[:aurora_meter, :cluster, :apply]` | `count` | `kind`, `origin` | stable | 0.3.0 | `[:aurora_meter, :cluster, :apply]` |
| `[:aurora_meter, :credits, kind]` | `amount`, `balance_after`, `available_after` | `tenant_key`, `reference`, `category`, `duplicate`, `overrun` | stable | 0.4.0 | `[:aurora_meter, :credits, txn.kind]` |
| `[:aurora_meter, :credits, :low_balance]` | `available`, `threshold` | `tenant_key` | stable | 0.4.0 | `[:aurora_meter, :credits, :low_balance]` |

`declared` was added to the `track` and `reserve` metadata in 0.5.0, which is an
additive change: a handler matching on the old keys is unaffected.

`kind` in the credits event is one of `:grant`, `:hold`, `:settle`, `:release`,
`:debit` or `:expire`. `duplicate: true` marks an idempotent grant replay (with
`amount: 0`); `overrun: true` marks a settlement above its hold.

`tenant_key` is metadata, never a metric tag: the cardinality is unbounded.

## 7. PubSub messages

Message tags are covered by SemVer. Payload maps gain keys additively, so match
on the keys you need rather than on the whole map.

<!-- inventory:literal -->

| Message | Topic | Class | Since | Matched in lib/ |
|---|---|---|---|---|
| `{:aurora_meter, :usage, %{feature, value, period_start}}` | `AuroraMeter.Broadcaster.topic/1` | stable | 0.1.0 | `{:aurora_meter, :usage,` |
| `{:aurora_meter, :deltas, node(), [{key, delta}]}` | `"aurora_meter:cluster"` | internal | 0.3.0 | `{:aurora_meter, :deltas, node(), deltas}` |
| `{:aurora_meter, :totals, node(), [{key, total}]}` | `"aurora_meter:cluster"` | internal | 0.3.0 | `{:aurora_meter, :totals, node(), totals}` |
| `{:aurora_meter, :subscription_changed, tenant_key}` | `"aurora_meter:subscriptions"` | internal | 0.2.0 | `{:aurora_meter, :subscription_changed, key}` |
| `{:aurora_meter, :credits, %{tenant_key, balance, held, available}}` | `AuroraMeter.Credits.topic/1` | stable | 0.4.0 | `{:aurora_meter, :credits,` |
| `{:aurora_meter, :low_balance, %{tenant_key, available, threshold}}` | `AuroraMeter.Credits.topic/1` | stable | 0.4.0 | `{:aurora_meter, :low_balance, event}` |

The two cluster messages and the subscription invalidation are `internal`: they
are how nodes talk to each other, not an API. Subscribe to the tenant topic and
the credits topic; leave the other two alone.

**What `value` in the usage message means.** It is this node's converged view at
the moment of the tick, and it **includes units this node has reserved but not
yet committed** through `reserve/3` or `with_quota/4`. With `cluster_sync: true`
(the default) the message is node-local, so a browser connected to node B never
sees node A's slightly different number.

## 8. Mix tasks

<!-- inventory:modules -->

| Entry | Command | Class | Since | Notes |
|---|---|---|---|---|
| `Mix.Tasks.AuroraMeter.Install` | `mix aurora_meter.install` | optional-dep | 0.3.0 | With `igniter` present it writes the config, the supervision tree entry, a starter plans module and the migration. Without Igniter it prints the same steps and exits 0. |
| `Mix.Tasks.AuroraMeter.Gen.Migration` | `mix aurora_meter.gen.migration` | stable | 0.1.0 | Options `-r`, `--from`, `--version`, `--to`. |
| `Mix.Tasks.AuroraMeter.Features` | `mix aurora_meter.features` | stable | 0.5.0 | The scanner to run before changing `undeclared_feature_policy`. `--strict` exits 1 when anything referenced is undeclared or declared on only some plans. |
| `Mix.Tasks.AuroraMeter.Bench` | `mix aurora_meter.bench` | stable | 0.1.0 | Development only. Benchmark numbers are not covered by SemVer. |

## 9. Migration entry points

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Migration.latest_version/0` | `() :: pos_integer()` | stable | 0.2.0 | `6` in this release. |
| `AuroraMeter.Migration.up/1` | `(keyword()) :: :ok` | stable | 0.2.0 | Options `:version`, `:from`, `:to`. Arity 0 exists through defaults. Every version is idempotent. |
| `AuroraMeter.Migration.down/1` | `(keyword()) :: :ok` | stable | 0.2.0 | Options `:version`, `:from`, `:to`. Arity 0 exists through defaults. |

The schema-version contract: a host calls these from its own Ecto migration.
Versions are additive during 1.x. `AuroraMeter.Migration.V1` to `V6` are
implementation modules and are internal (section 11).

## 10. Test helpers

Supported, and shipped in the Hex tarball, so a host test suite may depend on
them. They are governed by the test-helper heading of the support policy rather
than by SemVer on every name, and nothing in production should call them.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Test.reset!/0` | `() :: :ok` | stable | 0.3.0 | Clears the ETS tables. |
| `AuroraMeter.Test.flush!/0` | `() :: non_neg_integer()` | stable | 0.3.0 | Flushes synchronously and returns the count. |
| `AuroraMeter.Test.broadcast!/0` | `() :: :ok` | stable | 0.3.0 | Forces a broadcaster tick. |
| `AuroraMeter.Test.unique_tenant/1` | `(String.t()) :: String.t()` | stable | 0.3.0 | Arity 0 exists through a `"org"` default. |
| `AuroraMeter.Test.checkout/1` | `(map()) :: :ok` | stable | 0.3.0 | Sandbox checkout honouring the `async` tag. Arity 0 exists through defaults. |
| `AuroraMeter.Test.simulate_node/3` | `(node(), [{term(), atom(), integer()}], DateTime.t() \| nil) :: :ok` | stable | 0.3.0 | Applies another node's gossiped deltas. |
| `AuroraMeter.Test.simulate_flush/3` | `(node(), [{term(), atom(), integer()}], DateTime.t() \| nil) :: :ok` | stable | 0.3.0 | Applies another node's announced totals. |
| `AuroraMeter.Test.fund!/3` | `(tenant, pos_integer(), keyword()) :: AuroraMeter.Credits.txn()` | stable | 0.4.0 | |
| `AuroraMeter.Test.drain!/1` | `(tenant) :: non_neg_integer()` | stable | 0.4.0 | |
| `AuroraMeter.Test.credit_balance/1` | `(tenant) :: AuroraMeter.Credits.balance()` | stable | 0.4.0 | |
| `AuroraMeter.Test.with_clock/2` | `(DateTime.t(), (-> result)) :: result` | stable | 0.5.0 | Freezes the clock for the duration of the function and restores the previous configuration afterwards. |
| `AuroraMeter.Test.travel/1` | `(DateTime.t()) :: :ok` | stable | 0.5.0 | Moves a frozen clock to an absolute instant. |
| `AuroraMeter.Test.travel/2` | `(integer(), AuroraMeter.Clock.Fixed.unit()) :: :ok` | stable | 0.5.0 | Moves a frozen clock by a relative amount. |
| `AuroraMeter.Clock.Fixed.start_link/1` | `(keyword()) :: Agent.on_start()` | stable | 0.5.0 | The agent behind `with_clock/2`. Prefer `AuroraMeter.Test`. |
| `AuroraMeter.Clock.Fixed.set/1` | `(DateTime.t()) :: :ok` | stable | 0.5.0 | |
| `AuroraMeter.Clock.Fixed.advance/2` | `(integer(), unit()) :: :ok` | stable | 0.5.0 | |
| `AuroraMeter.Clock.Fixed.stop/0` | `() :: :ok` | stable | 0.5.0 | Safe when the agent is not running. |
| `AuroraMeter.Clock.Fixed.running?/0` | `() :: boolean()` | stable | 0.5.0 | |

`use AuroraMeter.Test` in an `ExUnit.CaseTemplate` installs the checkout and
reset callbacks; see [Testing](testing.md).

## 11. Internal modules

These are compiled, public in the Erlang sense, and documented so the guides and
the ADRs can link to them. They are **not** part of the supported surface. Each
carries a stability banner at the top of its module docs, and each renders under
the "Internal" group in the generated documentation.

The inventory test holds this list as a module attribute and fails when a module
on it appears anywhere in the tables above, and when this list and the
`groups_for_modules` "Internal" group in `mix.exs` disagree.

<!-- inventory:internal -->

| Entry | Why it is internal |
|---|---|
| `AuroraMeter.BootChecks` | The boot-time child that runs `AuroraMeter.Credits.assert_currency!/0`. Call the public function. |
| `AuroraMeter.Broadcaster` | The PubSub fan-out process. Only `topic/1` is supported, and it is listed in section 1.8. |
| `AuroraMeter.Cluster` | The delta and total gossip protocol between nodes. `apply/3` stays documented because `AuroraMeter.Test.simulate_node/3` calls it; use the test helper, not this. |
| `AuroraMeter.Config.Schema` | The configuration conventions shared with Pro. Pro adopts them by passing its own schema, never by depending on this module. |
| `AuroraMeter.Counter` | The ETS row layout and the reserve or commit protocol. Hosts never touch ETS rows. |
| `AuroraMeter.Credits.Ledger` | The ledger implementation behind `AuroraMeter.Credits`. |
| `AuroraMeter.Credits.Promotions` | Promotional-remainder arithmetic for expiry. |
| `AuroraMeter.Credits.Series` | The money series queries behind `spend_history/2` and `spend_total/2`. |
| `AuroraMeter.Install.Templates` | The strings the installer writes. |
| `AuroraMeter.Migration.V1` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V2` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V3` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V4` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V5` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V6` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Schema.FlushReceipt` | The idempotent flush receipt row. Bookkeeping for the flusher. |
| `AuroraMeter.Storage.Ecto` | The bundled adapter. Configure it by name; the callbacks are section 2. |
| `AuroraMeter.Store` | Owns the ETS tables and the pending flush batch. |
| `AuroraMeter.Supervisor` | The runtime supervision tree. Add `AuroraMeter` to your own tree. |

A function carrying `@doc false` inside any module is internal for the same
reason, whether or not its module is on this list. The inventory test refuses to
let one appear in the tables above.

## 12. Consumed by Aurora Meter Pro

Aurora Meter Pro is built on exactly this public surface and nothing else. The
boundary is fixed in the V1 programme's `free-pro-boundary.md` section 2; it is
restated here because it is part of what this page promises. Pro may use:

- the facade: `usage/2`, `usage_all/1`, `history/3`, `period/1`, `plan/1`,
  `quota/2`, `check/2`, `entitled?/2`, `feature_value/3`
- `AuroraMeter.Storage` dispatchers: `load_counter/3`, `get_subscription/1`,
  `put_subscription/1`, `load_history_range/4`, `stream_counters/1`
- everything in `AuroraMeter.Credits` and `AuroraMeter.Credits.Money`
- `AuroraMeter.Plans.get/1`, `AuroraMeter.Plan`
- `AuroraMeter.Subscriptions.get/1` and `invalidate/1`
- `AuroraMeter.Period.current!/2` and `containing/2`, `AuroraMeter.Clock.now/0`
- `AuroraMeter.Flusher.flush/0`, `AuroraMeter.Test`
- the behaviours `AuroraMeter.Billing.Provider` and `AuroraMeter.Period`

Anything else in the core is internal to Pro as well, even where it is currently
public. Pro still reaches a handful of core tables directly; those accesses are
recorded in Pro's own inventory as internal coupling scheduled for removal, and
this page does not bless them.

This section names no Pro module, because the core never depends on Pro.
