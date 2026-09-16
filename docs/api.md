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
| `AuroraMeter.track/4` | `(tenant, atom(), integer(), keyword()) :: :ok` | stable | 0.1.0 | Arities 2 and 3 exist through defaults (`qty` 1, `opts` `[]`). Options `:durable`, `:metadata`. Counts an undeclared feature under every policy. Raises `ArgumentError` for a feature whose `:feature_sources` entry is `:events`, with or without `durable: true`, before anything is written. |
| `AuroraMeter.record/4` | `(tenant, atom(), pos_integer(), keyword()) :: {:ok, AuroraMeter.Event.t(), :inserted \| :duplicate} \| {:error, {:invalid, errors} \| {:conflict, AuroraMeter.Event.t()} \| {:unavailable, term()} \| {:unsupported, :durable_events}}` | stable | 1.0.0 | The durable path. Required options `:id` and `:occurred_at`; optional `:dimensions`, `:metadata`, `:future_tolerance`, `:timeout`. A retry with the same `:id` is a duplicate, never a second charge. No fallback to `track/4`. |
| `AuroraMeter.record_batch/2` | `([map()], keyword()) :: {:ok, [{AuroraMeter.Event.t(), :inserted \| :duplicate}]} \| {:error, {:invalid, errors} \| {:conflict, index, AuroraMeter.Event.t()} \| {:unavailable, term()} \| {:unsupported, :durable_events}}` | stable | 1.0.0 | One transaction for the whole batch; results in input order. Limits 500 elements and 1 MiB of encoded payload. |
| `AuroraMeter.correct/4` | `(tenant, String.t(), pos_integer(), keyword()) :: {:ok, AuroraMeter.Event.t(), :inserted \| :duplicate} \| {:error, {:invalid, errors} \| {:conflict, AuroraMeter.Event.t()} \| {:not_found, :original} \| {:unavailable, term()} \| {:unsupported, :corrections}}` | stable | 1.0.0 | Appends a correction reducing an earlier fact by a positive magnitude; no row is ever updated. Required option `:id`; optional `:metadata`. `:dimensions` and `:occurred_at` are refused, because changing either is `replace/4`. Cumulative corrections of one original can never exceed it, checked under a lock on the original row. |
| `AuroraMeter.replace/4` | `(tenant, String.t(), map(), keyword()) :: {:ok, %{correction: AuroraMeter.Event.t(), replacement: AuroraMeter.Event.t()}, :inserted \| :duplicate} \| {:error, {:invalid, errors} \| {:conflict, AuroraMeter.Event.t()} \| {:not_found, :original} \| {:unavailable, term()} \| {:unsupported, :corrections}}` | stable | 1.0.0 | A full reversal of the original plus one replacement, in one transaction. Required option `:id`, the correction's, at most 126 bytes; optional `:replacement_id`, default `id` followed by `~r`. `attrs` takes `:quantity`, `:occurred_at`, `:dimensions`, `:metadata` and optionally `:feature`, which must equal the original's. |
| `AuroraMeter.usage/2` | `(tenant, atom()) :: integer()` | stable | 0.1.0 | Current period, warm ETS value. |
| `AuroraMeter.usage_all/1` | `(tenant) :: %{atom() => integer()}` | stable | 0.1.0 | Warm counters only. |
| `AuroraMeter.history/3` | `(tenant, atom(), keyword()) :: [AuroraMeter.Storage.history_point()]` | stable | 0.2.0 | Options `:days` (30), `:from`, `:to`. Zero-filled, oldest first. Needs `history: true` and schema version 2. |
| `AuroraMeter.period/1` | `(tenant) :: AuroraMeter.Period.t()` | stable | 0.2.0 | Delegates to `AuroraMeter.Period.current!/2`, so an invalid period source raises here. |
| `AuroraMeter.subscribe/2` | `(tenant, atom() \| String.t()) :: {:ok, Subscription.t()} \| {:error, Ecto.Changeset.t()}` | stable | 0.1.0 | An unknown plan id warns in 0.5.x and returns `{:error, changeset}` from 1.0. The tenant gets the plan's effective version. |
| `AuroraMeter.subscribe/3` | `(tenant, atom() \| String.t(), keyword()) :: {:ok, Subscription.t()} \| {:error, Ecto.Changeset.t()}` | additive | 1.0.0 | Option `:version` pins one, including a version that is not yet effective: an explicit opt-in is not a future-dated version becoming active early. An unknown version is `{:error, changeset}` with `plan_version`. |
| `AuroraMeter.plan/1` | `(tenant) :: AuroraMeter.Plan.t() \| nil` | stable | 0.1.0 | The **version the subscription is pinned to**, from 1.0. Falls back to `:default_plan` for a non-entitled subscription, and to the plan's base version for a row with no `plan_version`. |
| `AuroraMeter.check/2` | `(tenant, atom()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Advisory: a read then a compare. Use `reserve/3` for a hard limit. Honours `undeclared_feature_policy`. |
| `AuroraMeter.allowed?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | `check/2 == :ok`. |
| `AuroraMeter.entitled?/2` | `(tenant, atom()) :: boolean()` | stable | 0.1.0 | Ignores quota. |
| `AuroraMeter.remaining/2` | `(tenant, atom()) :: non_neg_integer() \| :unlimited` | stable | 0.1.0 | |
| `AuroraMeter.feature_value/3` | `(tenant, atom(), default) :: boolean() \| non_neg_integer() \| default` | stable | 0.4.0 | Arity 2 exists through a `nil` default. |
| `AuroraMeter.quota/2` | `(tenant, atom()) :: AuroraMeter.Entitlements.quota()` | stable | 0.2.0 | Dashboard snapshot. `kind` is `:hard`, `:metered`, `:feature`, `:counter`, `:boolean` or `:undeclared`. |
| `AuroraMeter.reserve/2` | `(tenant, atom()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Atomic on one node. Raises `ArgumentError` for an `:events`-source feature: it bills what it reserves immediately. |
| `AuroraMeter.reserve/3` | `(tenant, atom(), pos_integer()) :: :ok \| {:error, :limit_exceeded \| :not_entitled}` | stable | 0.1.0 | Raises `ArgumentError` for an `:events`-source feature, as `reserve/2`. |
| `AuroraMeter.with_quota/3` | `(tenant, atom(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | Releases the reservation on a raise, throw or exit. |
| `AuroraMeter.with_quota/4` | `(tenant, atom(), pos_integer(), (-> result)) :: {:ok, result} \| {:error, term()}` | stable | 0.1.0 | Reserve and release use the same captured period. For an `:events`-source feature the reservation is released on success too: it is admission control, and the recorded event is the charge. |

### 1.2 `AuroraMeter.Events`

The read side of `AuroraMeter.record/4`, plus the one function a host needs when
it wraps a record in a transaction of its own. See [Metering](metering.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Events.get/2` | `(tenant, String.t()) :: {:ok, AuroraMeter.Event.t()} \| {:error, :not_found}` | stable | 1.0.0 | By the caller's own `event_id`. |
| `AuroraMeter.Events.total/3` | `(tenant, atom(), DateTime.t()) :: non_neg_integer()` | stable | 1.0.0 | The durable total for a period, from the active projection generation. Authoritative; `usage/2` is a view. |
| `AuroraMeter.Events.count/3` | `(tenant, atom(), DateTime.t()) :: %{quantity: non_neg_integer(), events: non_neg_integer()}` | stable | 1.0.0 | The total and the number of events behind it. |
| `AuroraMeter.Events.stream/1` | `(keyword()) :: Enumerable.t()` | stable | 1.0.0 | Keyset by `seq`, one bounded query per chunk. Options `:after_seq`, `:limit`, `:tenant`, `:feature`, `:from`, `:to`. |
| `AuroraMeter.Events.after_commit/1` | `([AuroraMeter.Event.t()] \| AuroraMeter.Event.t()) :: :ok` | stable | 1.0.0 | Applies the in-memory projection and publishes, for events recorded inside a host transaction. Call once, after your commit. |
| `AuroraMeter.Events.Replay.run/1` | `(keyword()) :: {:ok, map()} \| {:ok, :paused, map()} \| {:error, term()}` | stable | 1.0.0 | Rebuilds the projection into a new generation and activates it. Options `:batch_size`, `:compare`, `:activate`, `:resume`, `:generation`, `:compare_limit`, `:max_batches`, `:rehydrate`, `:timeout`. An operator action; nothing schedules it. |
| `AuroraMeter.Events.Replay.status/0` | `() :: map()` | stable | 1.0.0 | The active, building and previous generations, the watermark, the seed generation and the replay's own checkpoint. |
| `AuroraMeter.Events.Replay.prune/1` | `(integer()) :: {:ok, non_neg_integer()} \| {:error, term()}` | stable | 1.0.0 | Deletes a retired generation's rows in bounded slices. Refuses the active one and refuses while a replay holds its claim. |
| `AuroraMeter.Events.Replay.checkpoint_name/1` | `(integer()) :: String.t()` | stable | 1.0.0 | The `aurora_meter_checkpoints` row a build of that generation keeps. |
| `AuroraMeter.Events.Replay.claim_name/0` | `() :: String.t()` | stable | 1.0.0 | The advisory-lock claim every replay holds, whichever generation it builds. |

### 1.3 `AuroraMeter.Entitlements`

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

### 1.4 `AuroraMeter.Credits`

Micro-dollar integers throughout. See [Credits](credits.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.balance/1` | `(tenant) :: balance()` | stable | 0.4.0 | `%{balance, held, available, spendable, promotional, promotional_spendable, debt, expired, currency, low_balance_threshold}`. The last four arrived in 0.6.0 as additive keys; a legacy wallet reports `spendable == available`, `promotional_spendable == promotional`, `debt == 0` and `expired == 0`. |
| `AuroraMeter.Credits.available/1` | `(tenant) :: integer()` | stable | 0.4.0 | `balance - held`. |
| `AuroraMeter.Credits.sufficient?/2` | `(tenant, integer()) :: boolean()` | stable | 0.4.0 | Advisory, like `check/2`. |
| `AuroraMeter.Credits.grant/3` | `(tenant, pos_integer(), keyword()) :: {:ok, txn()} \| {:error, :duplicate_reference \| Ecto.Changeset.t()}` | stable | 0.4.0 | Idempotent on `reference:`. Options `:reference`, `:category` (`:paid`, `:promotional`, `:adjustment`), `:expires_at`, `:metadata`, `:source`. From 0.6.0 a reference already held by **another** tenant answers `{:error, :duplicate_reference}` instead of a raw changeset; every other changeset error is unchanged. |
| `AuroraMeter.Credits.grant_with_status/3` | `(tenant, pos_integer(), keyword()) :: {:ok, txn(), :new \| :duplicate} \| {:error, :duplicate_reference \| Ecto.Changeset.t()}` | stable | 0.4.0 | Reports new or duplicate from inside the balance row's lock. Same error change as `grant/3`. |
| `AuroraMeter.Credits.hold/4` | `(tenant, pos_integer(), String.t(), keyword()) :: {:ok, txn()} \| {:error, :insufficient_credits \| :debt_outstanding \| :duplicate_reference}` | stable | 0.4.0 | Arity 3 exists through an empty option list. |
| `AuroraMeter.Credits.settle/3` | `(String.t(), non_neg_integer(), keyword()) :: {:ok, txn()} \| {:error, :not_found \| :already_settled}` | stable | 0.4.0 | Keyed by the hold's reference, not by tenant. Arity 2 exists through defaults. Option `:tenant` from 0.6.0 asserts the hold belongs to that tenant; without it the behaviour is exactly as before. |
| `AuroraMeter.Credits.release/2` | `(String.t(), keyword()) :: {:ok, txn()} \| {:error, :not_found \| :already_settled}` | stable | 0.4.0 | Arity 1 exists through defaults and is unchanged. Option `:tenant` from 0.6.0 asserts the hold belongs to that tenant and answers `{:error, :not_found}` when it does not. |
| `AuroraMeter.Credits.debit/4` | `(tenant, pos_integer(), String.t(), map()) :: {:ok, txn()} \| {:error, :insufficient_credits \| :debt_outstanding \| :duplicate_reference}` | stable | 0.4.0 | Arity 3 exists through an empty metadata map. |
| `AuroraMeter.Credits.reverse/4` | `(tenant, pos_integer(), String.t(), map()) :: {:ok, txn()} \| {:error, :duplicate_reference}` | stable | 0.4.0 | Never refused for want of balance: the balance may go negative, which is the honest record of a debt. From 0.6.0 the entry is `kind: :reverse` (it was `kind: :debit, category: :reversal`), so a reversal and a debit no longer share a reference namespace. Existing rows are unchanged and still read as reversals through `AuroraMeter.Schema.CreditTransaction.reversal?/1`. |
| `AuroraMeter.Credits.with_credits/4` | `(tenant, pos_integer(), String.t(), (-> {:ok, result, non_neg_integer()} \| {:error, term()})) :: {:ok, result} \| {:error, :insufficient_credits \| :debt_outstanding \| :duplicate_reference \| term()}` | stable | 0.4.0 | Holds, runs, then settles or releases, including on a raise. |
| `AuroraMeter.Credits.pending_holds/1` | `(keyword()) :: [txn()]` | stable | 0.4.0 | Options `:older_than`, `:reference_prefix`, `:limit`, and from 0.6.0 `:tenant` and `:after`. Ordered by `(inserted_at, id)` from 0.6.0, oldest first; before that by `inserted_at` alone, which could skip a same-microsecond row when paging. |
| `AuroraMeter.Credits.reconcile_holds/1` | `(keyword()) :: {:ok, report()} \| {:error, term()}` | stable | 0.6.0 | Asks `:credits_hold_reconciler` about every hold older than `:older_than` and applies the answer. Options `:older_than` (required), `:limit`, `:tenant`, `:reference_prefix`, `:after`, `:reconciler`. Keeps every hold when nothing is configured. |
| `AuroraMeter.Credits.history/2` | `(tenant, keyword()) :: [txn()]` | stable | 0.4.0 | Options `:limit` (50), `:kinds`, `:before`, and from 0.6.0 `:cursor`. Holds and releases are hidden unless asked for; `:reverse` joined the default kinds in 0.6.0, which is what keeps the default view unchanged in content. `:before` filters on `inserted_at` and may skip a same-microsecond row; `:cursor` pages on the ordering key and cannot skip or repeat one. Giving both raises `ArgumentError`. |
| `AuroraMeter.Credits.cursor/1` | `(txn()) :: cursor()` | stable | 0.6.0 | The opaque `history/2` cursor for an entry. Do not compare, store or construct one. |
| `AuroraMeter.Credits.spend_history/2` | `(tenant, keyword()) :: [money_point()]` | stable | 0.4.0 | Options `:days` (30) or `:from`/`:to`, `:bucket` (`:day` or `:month`), `:kinds`. Zero-filled, oldest first. |
| `AuroraMeter.Credits.spend_total/2` | `(tenant, keyword()) :: money_total()` | stable | 0.4.0 | `%{spent, granted, net, from, to}`. |
| `AuroraMeter.Credits.summary/1` | `(tenant) :: summary()` | stable | 0.4.0 | `daily_burn` and `runway_days` are `nil` when there is nothing honest to report. Gains `balance/1`'s four new keys in 0.6.0. `runway_days` is still derived from `available`. |
| `AuroraMeter.Credits.set_low_balance_threshold/2` | `(tenant, integer() \| nil) :: {:ok, CreditBalance.t()}` | stable | 0.4.0 | Overrides `:credits_low_balance_threshold` for one tenant. From 0.6.0 it also recomputes the standing low-balance crossing under the row lock: lowering or clearing the threshold clears a crossing the wallet is no longer below. It never raises an alert by itself. |
| `AuroraMeter.Credits.expire_due/1` | `(DateTime.t()) :: {:ok, non_neg_integer()}` | stable | 0.4.0 | Arity 0 exists and defaults to `AuroraMeter.Clock.db_now/0`, because it compares against a persisted `expires_at`. |
| `AuroraMeter.Credits.subscribe/1` | `(tenant) :: :ok \| {:error, term()}` | stable | 0.4.0 | Subscribes the calling process to `topic/1`. |
| `AuroraMeter.Credits.topic/1` | `(String.t()) :: String.t()` | stable | 0.4.0 | `"aurora_meter:credits:" <> tenant_key`. Takes a resolved key, not a tenant term. |
| `AuroraMeter.Credits.after_commit/1` | `(keyword()) :: :ok` | stable | 0.6.0 | Runs the side effects of every ledger call this process made inside its own transaction. `discard: true` drops them, which is what the rollback branch calls. Arity 0 exists through defaults. A call that owns its transaction is unaffected. |
| `AuroraMeter.Credits.deferred_effects?/0` | `() :: boolean()` | stable | 0.6.0 | Whether this process has effects waiting for `after_commit/1`. Assert `false` to prove no path forgot the call. |
| `AuroraMeter.Credits.assert_currency!/0` | `() :: :ok` | stable | 0.5.0 | Raises `AuroraMeter.Credits.CurrencyMismatchError` when a stored balance row carries a currency other than `:credits_currency`. Skipped with one `:info` line when the repo or the tables are absent. |

### 1.5 `AuroraMeter.Credits.Money`

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.Money.from_cents/1` | `(integer()) :: micro()` | stable | 0.4.0 | |
| `AuroraMeter.Credits.Money.to_cents/2` | `(micro(), keyword()) :: integer()` | stable | 0.4.0 | Option `:rounding` (`:round`, `:floor`, `:ceil`). Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Money.from_decimal/1` | `(Decimal.t()) :: micro()` | stable | 0.4.0 | Requires `Decimal`, which arrives transitively with Ecto. |
| `AuroraMeter.Credits.Money.format/2` | `(micro(), keyword()) :: String.t()` | stable | 0.4.0 | Option `:precision` (0 to 6). Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Money.format_compact/1` | `(micro()) :: String.t()` | stable | 0.4.0 | Never rounds a sub-cent amount away to `"$0.00"`. |
| `AuroraMeter.Credits.Money.assert_range!/1` | `(term()) :: micro()` | stable | 0.6.0 | Raises `ArgumentError` for a non-integer or an amount beyond `max_micro/0`. Called by the six `AuroraMeter.Credits` write entry points before any database work. |
| `AuroraMeter.Credits.Money.max_micro/0` | `() :: pos_integer()` | stable | 0.6.0 | `9_000_000_000_000_000`, three orders of magnitude below the `bigint` ceiling so that sums cannot overflow either. |

### 1.6 Plans

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Plans.all/0` | `() :: %{optional(atom()) => AuroraMeter.Plan.t()}` | stable | 0.1.0 | The shape is unchanged; from 1.0 the content is the **effective** version of each plan at `AuroraMeter.Clock.now/0`. |
| `AuroraMeter.Plans.get/1` | `(atom()) :: AuroraMeter.Plan.t() \| nil` | stable | 0.1.0 | The plan id's effective version. |
| `AuroraMeter.Plans.get/2` | `(atom(), String.t()) :: AuroraMeter.Plan.t() \| nil` | additive | 1.0.0 | One named version: compiled first, then the registered snapshot, else `nil`. |
| `AuroraMeter.Plans.base/1` | `(atom()) :: AuroraMeter.Plan.t() \| nil` | additive | 1.0.0 | The version declaring no `effective_at`, which is what a subscription written before plan versions existed is on. |
| `AuroraMeter.Plans.effective_for/2` | `(term(), DateTime.t()) :: {:ok, {atom(), String.t()}} \| {:error, :unresolved}` | additive | 1.0.0 | The `{plan_id, version}` a tenant was on at an instant: the assignment for an instant inside it, the applied transition history for one before it, `{:error, :unresolved}` when nothing recorded covers it. The attribution question, not the entitlement one. |
| `AuroraMeter.Plans.versions/1` | `(atom()) :: [AuroraMeter.Plan.t()]` | additive | 1.0.0 | Every version, compiled and stored, oldest first. Includes a version whose block has been deleted from the plans module. |
| `AuroraMeter.Plans.plan_ids/0` | `() :: [atom()]` | additive | 1.0.0 | Every declared plan id, without resolving an effective version per id. |
| `AuroraMeter.Plans.register!/0` | `() :: :ok` | additive | 1.0.0 | Called by `AuroraMeter.start_link/1`. Registers the compiled snapshots, refuses an edited version, and names the contract of subscriptions written before core schema version 10. Idempotent; not to be called inside a transaction. |
| `AuroraMeter.Plans.feature_config/2` | `(atom(), atom()) :: AuroraMeter.Plan.feature_config() \| nil` | stable | 0.1.0 | |
| `AuroraMeter.Plans.feature_value/3` | `(atom(), atom(), default) :: boolean() \| non_neg_integer() \| default` | stable | 0.4.0 | Arity 2 exists through a `nil` default. |
| `AuroraMeter.Plans.declared_anywhere?/1` | `(atom()) :: boolean()` | stable | 0.5.0 | Whether any plan declares the feature. Behind the `declared:` telemetry metadata. |
| `AuroraMeter.Plans.plan/2` | DSL macro | stable | 0.1.0 | Only inside a module that `use`s `AuroraMeter.Plans`. |
| `AuroraMeter.Plans.plan/3` | DSL macro | additive | 1.0.0 | `plan :pro, version: "2", effective_at: ~U[...] do ... end`. Options `:version` (default `"1"`) and `:effective_at` (default `nil`, meaning from the beginning). Exactly one version of each plan id declares no `effective_at`. |
| `AuroraMeter.Plans.price/1` | DSL macro | stable | 0.1.0 | Minor units (cents), integer. |
| `AuroraMeter.Plans.limit/3` | DSL macro | stable | 0.1.0 | `limit :feature, count, :hard` or `:soft`. |
| `AuroraMeter.Plans.metered/2` | DSL macro | stable | 0.1.0 | Options `:included`, `:unit_price`. Integer `unit_price` is the supported form; a float warns at boot from 0.5.0. |
| `AuroraMeter.Plans.feature/2` | DSL macro | stable | 0.1.0 | Boolean or non-negative integer value. |
| `AuroraMeter.Plans.counter/1` | DSL macro | stable | 0.4.0 | Measured, never blocked, never billed. `quota/2` reports `limit`, `included` and `percent` as `nil`. |
| `AuroraMeter.Plans.recurring_credits/2` | DSL macro | stable | 0.6.0 | Options `:amount` (required, positive integer micro-dollars), `:category` (`:promotional`), `:rollover` (`0`), `:expires` (`:period_end`). Read by `AuroraMeter.Credits.Recurrences`. |

### 1.7 Periods and the clock

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

### 1.8 Storage dispatchers

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
| `AuroraMeter.Storage.capabilities/0` | `() :: [AuroraMeter.Storage.capability()]` | stable | 1.0.0 | The durable operations the configured adapter supports. |
| `AuroraMeter.Storage.supports?/1` | `(capability()) :: boolean()` | stable | 1.0.0 | |
| `AuroraMeter.Storage.record_events/2` | `([event_entry()], keyword()) :: {:ok, [{AuroraMeter.Event.t(), :inserted \| :duplicate}]} \| {:error, term()}` | stable | 1.0.0 | One transaction for the events, their totals and the outbox intent. |
| `AuroraMeter.Storage.record_correction/2` | `(correction_entry(), keyword()) :: {:ok, [{AuroraMeter.Event.t(), :inserted \| :duplicate}]} \| {:error, term()}` | stable | 1.0.0 | One correction, and optionally its replacement, in one transaction. The duplicate check precedes the cumulative bound, which is taken under a lock on the original. Options `:timeout`, `:outbox`, `:replacement`. |
| `AuroraMeter.Storage.load_event/2` | `(String.t(), String.t()) :: {:ok, AuroraMeter.Event.t()} \| {:error, :not_found \| {:unsupported, capability()}}` | stable | 1.0.0 | |
| `AuroraMeter.Storage.load_event_total/3` | `(String.t(), atom() \| String.t(), DateTime.t()) :: {:ok, %{quantity: non_neg_integer(), events: non_neg_integer()}} \| {:error, {:unsupported, capability()}}` | stable | 1.0.0 | Reads the active projection generation. |
| `AuroraMeter.Storage.stream_events/2` | `(non_neg_integer(), keyword()) :: {:ok, [AuroraMeter.Event.t()]} \| {:error, {:unsupported, capability()}}` | stable | 1.0.0 | Keyset by `seq`. |
| `AuroraMeter.Storage.write_projection_totals/2` | `(non_neg_integer(), [projection_total()]) :: :ok \| {:error, term()}` | stable | 1.0.0 | Absolute totals for a generation. Replay (03d) writes them. |
| `AuroraMeter.Storage.activate_projection/1` | `(non_neg_integer()) :: :ok \| {:error, term()}` | stable | 1.0.0 | Makes a generation the one reads see. |
| `AuroraMeter.Storage.begin_projection_generation/0` | `() :: {:ok, map()} \| {:error, term()}` | stable | 1.0.0 | Announces a building generation under `FOR UPDATE` on the projection row, reads the watermark and seeds the new generation from the active one. |
| `AuroraMeter.Storage.projection_state/0` | `() :: {:ok, map()} \| {:error, term()}` | stable | 1.0.0 | The active, building, previous and seed generations and the watermark. |
| `AuroraMeter.Storage.drain_projection_seed/2` | `(integer(), pos_integer()) :: {:ok, non_neg_integer()} \| {:error, term()}` | stable | 1.0.0 | Subtracts a bounded slice of a seed generation from the generation it seeded and deletes it. |
| `AuroraMeter.Storage.put_plan_version/1` | `(map()) :: {:ok, PlanVersion.t()} \| {:error, term()}` | additive | 1.0.0 | Insert or nothing. Never an update: a snapshot is immutable. Needs the `:plan_versions` capability. |
| `AuroraMeter.Storage.list_plan_versions/1` | `(String.t() \| :all) :: [PlanVersion.t()]` | additive | 1.0.0 | Needs the `:plan_versions` capability. |
| `AuroraMeter.Storage.assign_legacy_plan_versions/1` | `(pos_integer()) :: {:ok, %{assigned: non_neg_integer(), orphans: non_neg_integer()}} \| {:error, term()}` | additive | 1.0.0 | One bounded transaction of the legacy assignment, taken with `FOR UPDATE SKIP LOCKED`. `assigned: 0` means there is nothing left to do. Needs the `:plan_versions` capability. |

### 1.9 Subscriptions, flusher, live updates

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Subscriptions.get/1` | `(tenant) :: Subscription.t() \| nil` | stable | 0.2.0 | Cached for `:subscription_cache_ttl` milliseconds. |
| `AuroraMeter.Subscriptions.invalidate/1` | `(tenant) :: :ok` | stable | 0.2.0 | Evicts locally and broadcasts the eviction. |
| `AuroraMeter.Subscriptions.schedule_transition/3` | `(tenant, atom(), keyword()) :: {:ok, PlanTransition.t()} \| {:error, {tag, term()}}` | additive | 1.0.0 | One scheduled plan change. `:ref` required and idempotent per tenant; `:version`, `:effective_at` (default: the end of the tenant's period), `:replace` (default `true`), `:confirm` (`:local` or `:provider`), `:detail`. |
| `AuroraMeter.Subscriptions.cancel_transition/3` | `(tenant, String.t(), keyword()) :: {:ok, PlanTransition.t()} \| {:error, {tag, term()}}` | additive | 1.0.0 | Idempotent. An applied transition is a conflict. Arity 2 exists through a default `[]`. |
| `AuroraMeter.Subscriptions.preview_transition/3` | `(tenant, atom(), keyword()) :: {:ok, map()} \| {:error, {:invalid, term()}}` | additive | 1.0.0 | A pure read: no lock, no write. Returns `from`, `to`, `changes`, `effective_at`, `period` and `provider`. `price` is the plan's list price, never an invoice amount. |
| `AuroraMeter.Subscriptions.confirm_transition/3` | `(tenant, String.t(), keyword()) :: {:ok, PlanTransition.t()} \| {:error, {tag, term()}}` | additive | 1.0.0 | For a billing provider integration. `:provider_ref` required; `:effective_at` wins over the scheduled boundary. Idempotent under redelivery. |
| `AuroraMeter.Subscriptions.apply_due_transitions/1` | `(keyword()) :: {:ok, map()}` | additive | 1.0.0 | Applies every transition whose effective time has arrived, one transaction per tenant. Options `:limit`, `:after`, `:tenant`, `:now`. Safe from every node at once. |
| `AuroraMeter.Flusher.flush/0` | `() :: {:ok, non_neg_integer()} \| {:error, term()}` | stable | 0.1.0 | The operational "flush before you report" hook. An error retains the batch for an idempotent retry (0.4.0). |
| `AuroraMeter.Broadcaster.topic/1` | `(String.t()) :: String.t()` | stable | 0.1.0 | `"aurora_meter:tenant:" <> tenant_key`. The only entry of `AuroraMeter.Broadcaster` that is supported; the module itself is internal. Read the contract on `AuroraMeter.LiveView`. |
| `AuroraMeter.LiveView.subscribe/1` | `(tenant) :: :ok \| {:error, term()}` | stable | 0.1.0 | Subscribes the calling process to the tenant's usage topic. |
| `AuroraMeter.LiveView.subscribe/2` | `(tenant, keyword()) :: :ok \| {:error, term()}` | additive | 1.0.0 | `:topics` is a subset of `[:usage, :credits]`, default `[:usage]`, which is exactly what arity 1 does. A partial failure unsubscribes what the same call had subscribed. Raises on a `nil` tenant. |
| `AuroraMeter.LiveView.unsubscribe/1` | `(tenant) :: :ok` | additive | 1.0.0 | Stops routing on the usage topic. Messages already in the mailbox are still delivered, so filter on `tenant_key`. |
| `AuroraMeter.LiveView.unsubscribe/2` | `(tenant, keyword()) :: :ok` | additive | 1.0.0 | Same `:topics` option as `subscribe/2`. |
| `AuroraMeter.LiveView.topics/2` | `(tenant, keyword()) :: [{:usage \| :credits, String.t()}]` | additive | 1.0.0 | The canonical topic strings, for a host that runs its own `Phoenix.PubSub.subscribe/2`. Arity 1 exists through a default `[]`. |
| `AuroraMeter.LiveView.on_mount/4` | `(term(), map(), map(), Socket.t()) :: {:cont \| :halt, Socket.t()}` | optional-dep | 1.0.0 | Needs `phoenix_live_view`. `{:subscribe, fun}`, `{:subscribe, assign: :current_org}` or `:subscribe` with the `:live_view_tenant` config key. Subscribes only on the connected mount. A `nil` tenant halts with `:aurora_meter_denial` and never redirects. |
| `AuroraMeter.LiveView.switch_tenant/2` | `(Socket.t(), tenant) :: Socket.t()` | optional-dep | 1.0.0 | Needs `phoenix_live_view`. Unsubscribes exactly the topics recorded in `:aurora_meter_topics`. Idempotent for the tenant the socket already holds; raises on `nil`. |
| `AuroraMeter.LiveView.handle_usage/2` | `(term(), Socket.t()) :: Socket.t()` | optional-dep | 1.0.0 | Needs `phoenix_live_view`. Folds a usage message into `:aurora_meter_usage`, dropping a foreign `tenant_key`. Optional: matching the raw message is fully supported. |
| `AuroraMeter.LiveView.handle_credits/2` | `(term(), Socket.t()) :: Socket.t()` | optional-dep | 1.0.0 | Needs `phoenix_live_view`. Folds a credits or low-balance message into `:aurora_meter_credits`, dropping a foreign `tenant_key`. |

### 1.10 Configuration accessors

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
| `AuroraMeter.Config.plan_version_conflict/0` | `() :: :raise \| :warn` | additive | 1.0.0 | |
| `AuroraMeter.Config.policy_for/1` | `(atom()) :: :allow \| :warn \| :deny \| :raise` | stable | 0.5.0 | The seam every entitlement entry point consults. |
| `AuroraMeter.Config.durable_features/0` | `() :: [atom()]` | deprecated | 0.1.0 | Reads the deprecated `:durable_features` key. |
| `AuroraMeter.Config.feature_sources/0` | `() :: %{atom() => :buffered \| :events}` | additive | 1.0.0 | The `:feature_sources` map as declared. |
| `AuroraMeter.Config.feature_source/1` | `(atom()) :: :buffered \| :events` | additive | 1.0.0 | Where a feature's commercial quantity comes from, as in force on this node. Read once at boot; a runtime change to the key does not move it. |
| `AuroraMeter.Config.events_outbox/0` | `() :: module() \| nil` | additive | 1.0.0 | |
| `AuroraMeter.Config.events_future_tolerance/0` | `() :: non_neg_integer()` | additive | 1.0.0 | |
| `AuroraMeter.Config.record_timeout/0` | `() :: pos_integer()` | additive | 1.0.0 | |
| `AuroraMeter.Config.record_max_concurrency/0` | `() :: pos_integer()` | additive | 1.0.0 | |
| `AuroraMeter.Config.flush_interval/0` | `() :: pos_integer()` | stable | 0.1.0 | |
| `AuroraMeter.Config.broadcast_interval/0` | `() :: pos_integer()` | stable | 0.1.0 | |
| `AuroraMeter.Config.metrics_interval/0` | `() :: non_neg_integer()` | additive | 1.0.0 | Milliseconds between gauge samples. `0` means no internal timers. |
| `AuroraMeter.Config.metrics_feature_label?/0` | `() :: boolean()` | additive | 1.0.0 | Whether the presets tag on `:feature`. |
| `AuroraMeter.Config.metrics_scan_ceiling/0` | `() :: non_neg_integer()` | additive | 1.0.0 | The counters-table size above which `unreconciled_keys` is omitted. |
| `AuroraMeter.Config.flush_receipt_retention/0` | `() :: pos_integer()` | additive | 1.0.0 | Days. |
| `AuroraMeter.Config.replay_checkpoint_retention/0` | `() :: pos_integer()` | additive | 1.0.0 | Days. |
| `AuroraMeter.Config.flush_node_id/0` | `() :: String.t() \| nil` | additive | 1.0.0 | `nil` means `to_string(node())`; `AuroraMeter.Retention.node_id/0` resolves it. |
| `AuroraMeter.Config.history?/0` | `() :: boolean()` | stable | 0.2.0 | |
| `AuroraMeter.Config.subscription_cache_ttl/0` | `() :: non_neg_integer()` | stable | 0.2.0 | |
| `AuroraMeter.Config.cluster_sync?/0` | `() :: boolean()` | stable | 0.3.0 | |
| `AuroraMeter.Config.credits_currency/0` | `() :: String.t()` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_overdraft_tolerance/0` | `() :: non_neg_integer()` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_low_balance_threshold/0` | `() :: integer() \| nil` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_low_balance_handler/0` | `() :: (map() -> term()) \| nil` | stable | 0.4.0 | |
| `AuroraMeter.Config.credits_hold_reconciler/0` | `() :: module() \| {module(), atom()} \| (map() -> term()) \| nil` | stable | 0.6.0 | `nil` by default, which keeps every hold. |
| `AuroraMeter.Config.credits_hold_reconciler_timeout/0` | `() :: pos_integer()` | stable | 0.6.0 | Milliseconds. |
| `AuroraMeter.Config.live_view_tenant/0` | `() :: {module(), atom()} \| nil` | additive | 1.0.0 | The resolver `on_mount {AuroraMeter.LiveView, :subscribe}` calls, or `nil`. |

### 1.11 Billing seam

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Billing.checkout/3` | `(tenant, atom() \| String.t(), keyword()) :: {:ok, String.t()} \| {:error, term()}` | stable | 0.1.0 | Arity 2 exists through defaults. |
| `AuroraMeter.Billing.portal_url/2` | `(tenant, keyword()) :: {:ok, String.t()} \| {:error, term()}` | stable | 0.1.0 | Arity 1 exists through defaults. |
| `AuroraMeter.Billing.sync_subscription/1` | `(map()) :: {:ok, term()} \| {:error, term()}` | stable | 0.1.0 | |

### 1.12 Schema helpers

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
| `AuroraMeter.Schema.CreditRecurrence.changeset/2` | `(CreditRecurrence.t(), map()) :: Ecto.Changeset.t()` | stable | 0.6.0 | The engine is the only writer; the struct is public so support tooling can read a period back. |
| `AuroraMeter.Schema.CreditRecurrence.states/0` | `() :: [state()]` | stable | 0.6.0 | `[:granted, :issued_and_expired]`. |

### 1.13 HEEx components (optional dependency)

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

### 1.13a The entitlement plug

Compiled only when `Plug.Conn` is loaded. Without `plug` the module does not
exist at all, which is not an error. **It is advisory**: it takes no
reservation, so between its decision and the controller's work another request
on the same node can consume the last unit. The strict admission is
`AuroraMeter.with_quota/4` around the work itself, and no reserving plug is
shipped. See [Phoenix](phoenix.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Plug.EnsureEntitled.init/1` | `(keyword()) :: map()` | optional-dep | 1.0.0 | Needs `plug` (`~> 1.15`). Options `:feature` and `:tenant` are required; `:mode` (`:check \| :entitled?`), `:assign_quota`, `:on_missing_tenant`, `:on_denied`, `:on_unavailable`. Validated with NimbleOptions, so a bad option is a compile error in the host's router. |
| `AuroraMeter.Plug.EnsureEntitled.call/2` | `(Plug.Conn.t(), map()) :: Plug.Conn.t()` | optional-dep | 1.0.0 | Needs `plug`. 401 `:missing_tenant`, 403 `:not_entitled` or `:limit_exceeded`, 503 `:unavailable`, the reason in `conn.private[:aurora_meter_denial]`. Assigns `:aurora_meter_tenant` and `:aurora_meter_quota`. Reserves nothing and writes nothing. |

### 1.14 Retention

Deletes the operational rows the allow list names, and nothing else. Financial
history is never deleted, at any age, under any option. See
[Retention](retention.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Retention.plan/1` | `(keyword()) :: {:ok, map()} \| {:blocked, map(), [map()]}` | additive | 1.0.0 | Dry run. Writes nothing. Options `:only`, `:older_than`. |
| `AuroraMeter.Retention.prune/1` | `(keyword()) :: {:ok, map()} \| {:blocked, map(), [map()]}` | additive | 1.0.0 | Options `:only`, `:older_than`, `:batch_size`, `:max_items`. A table outside the allow list raises `ArgumentError`. |
| `AuroraMeter.Retention.status/1` | `(keyword()) :: map()` | additive | 1.0.0 | Every node's flush heartbeat, whether it blocks a receipt prune, and the package version each node runs. |
| `AuroraMeter.Retention.forget_node/2` | `(String.t(), keyword()) :: {:ok, map()} \| {:error, :not_found}` | additive | 1.0.0 | The only override of the receipt rule, for one named node that is genuinely gone. Logs at `:warning`. |
| `AuroraMeter.Retention.tables/0` | `() :: [atom()]` | additive | 1.0.0 | The allow-list keys. |
| `AuroraMeter.Retention.protected/0` | `() :: [String.t()]` | additive | 1.0.0 | The tables a prune must never delete a row from. |
| `AuroraMeter.Retention.operation/1` | `(atom()) :: String.t()` | additive | 1.0.0 | The `AuroraMeter.Operations` name one table's prune pauses under. |
| `AuroraMeter.Retention.node_id/0` | `() :: String.t()` | additive | 1.0.0 | This node's heartbeat identity: `:flush_node_id`, or `to_string(node())`. |

### 1.15 Oban workers (optional dependency)

Compiled only when `Oban` is loaded. Without it the whole `AuroraMeter.Oban`
namespace is absent, which is not an error: every operation these workers wrap
is a public function any scheduler can call. See
[the scheduler map](scheduler.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Oban.queue/0` | `() :: atom()` | optional-dep | 1.0.0 | Needs `oban`. The queue every Aurora Meter worker declares, core and Pro alike. |
| `AuroraMeter.Oban.cron_entries/1` | `(keyword()) :: [{String.t(), module()}]` | optional-dep | 1.0.0 | Needs `oban`. The recommended crontab, filtered to the workers this build can run. Options `:include`, `:exclude`, `:schedules`. |
| `AuroraMeter.Oban.validate!/1` | `(keyword()) :: :ok` | optional-dep | 1.0.0 | Needs `oban`. Raises `AuroraMeter.Oban.ConfigError` listing every problem in the host's Oban configuration. Options `:config` or `:otp_app` with `:name`, plus `:queue` and `:env`. |

<!-- inventory:modules -->

| Entry | Operation it wraps | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Oban.CreditExpiry` | `AuroraMeter.Credits.expire_due/1` | optional-dep | 1.0.0 | Needs `oban`. Recommended `"*/30 * * * *"`. |
| `AuroraMeter.Oban.HoldReconciliation` | `AuroraMeter.Credits.reconcile_holds/1` | optional-dep | 1.0.0 | Needs `oban`. Recommended `"*/15 * * * *"`. Job arguments `older_than_seconds`, `limit`, `reference_prefix`, `tenant`. |
| `AuroraMeter.Oban.EventsReplay` | `AuroraMeter.Events.Replay.run/1` | optional-dep | 1.0.0 | Needs `oban`. No schedule: a projection rebuild is an operator action, and `cron_entries/1` never returns it. |
| `AuroraMeter.Oban.RecurringGrants` | `AuroraMeter.Credits.Recurrences.run/1` | optional-dep | 1.0.0 | Needs `oban`. Recommended `"7 * * * *"`. Job arguments `limit`, `batch`, `max_periods`, `tenant`. |
| `AuroraMeter.Oban.PlanTransitions` | `AuroraMeter.Subscriptions.apply_due_transitions/1` | optional-dep | 1.0.0 | Needs `oban`. Recommended `"*/5 * * * *"`. Job arguments `limit`, `batches`, `tenant`. |
| `AuroraMeter.Oban.Retention` | `AuroraMeter.Retention.prune/1` | optional-dep | 1.0.0 | Needs `oban`. Recommended `"40 3 * * *"`. Job arguments `only`, `batch_size`, `max_items`. Do not schedule it until every node has written a flush heartbeat. |
| `AuroraMeter.Oban.ConfigError` | raised by `AuroraMeter.Oban.validate!/1` | optional-dep | 1.0.0 | Needs `oban`. Carries `:message` and `:problems`. |

### 1.16 `AuroraMeter.Credits.Lots`

The public read side of credit lots: what a grant is worth now, what moved it,
and which lots a payment funded. Read only, no locks, a snapshot. It is the only
supported route to lot data from outside `AuroraMeter.Credits`. See
[Credits](credits.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.Lots.list/2` | `(tenant, keyword()) :: [lot()]` | stable | 0.6.0 | Options `:states` (default `[:open]`, `:all` for every state), `:categories`, `:limit` (100, capped at 500), `:order` (`:spend` default, `:granted_at`), `:cursor` (the previous page's last lot, or its id). Spend order is fixed by the engine and no option changes it. Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Lots.get/2` | `(tenant, Ecto.UUID.t() \| String.t()) :: lot() \| nil` | stable | 0.6.0 | By lot id or by the reference of the grant that created it, which is what support has. |
| `AuroraMeter.Credits.Lots.allocations/2` | `(tenant, keyword()) :: [allocation()]` | stable | 0.6.0 | The movement trail, oldest first. Options `:lot_id`, `:transaction_id`, `:reference`, `:limit`, `:cursor`. Arity 1 exists through defaults. |
| `AuroraMeter.Credits.Lots.for_source/2` | `(tenant, map()) :: [lot()]` | stable | 0.6.0 | The lots whose `source` matches every key given. `:payment_intent_id` and `:recurrence_key` only; any other key raises `ArgumentError` rather than matching everything. |

A wallet that has not been cut over to lots has none, and every function here
answers `[]` or `nil` for it.

### 1.17 `AuroraMeter.Credits.LotMigration`

The wallet migration onto credit lots (schema step S5). Shadow by default, one
transaction per wallet, and it never cuts a wallet over unless the replay
reproduces that wallet's `balance`, `held` and `promotional` exactly. See
[Upgrading to lots](upgrading-to-lots.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.LotMigration.run/1` | `(keyword()) :: {:ok, summary()} \| {:error, term()}` | stable | 0.6.0 | Options `:repo`, `:shadow` (default `true`), `:tenant`, `:batch`, `:resume`, `:max_rows`, `:max_tail`, `:max_wallets`, `:retry_blocked`, `:report_only`, `:allow_cutover`. Arity 0 exists through defaults. |
| `AuroraMeter.Credits.LotMigration.status/1` | `(keyword()) :: map()` | stable | 0.6.0 | The aggregate cursor and one entry per wallet report. Options `:repo`, `:limit`. Arity 0 exists through defaults. |
| `AuroraMeter.Credits.LotMigration.checkpoint_name/1` | `(String.t()) :: String.t()` | stable | 0.6.0 | `"lot_migration:<tenant_key>"`, or `"lot_migration:sha256-<digest>"` when the key is not a legal `AuroraMeter.Operations` name. |
| `AuroraMeter.Credits.LotMigration.cutover_blocked/0` | `() :: map() \| nil` | stable | 0.6.0 | Non-nil while a real cutover is refused, carrying the finding and the reason. |
| `AuroraMeter.Credits.LotMigration.replay/2` | `([CreditTransaction.t()], String.t()) :: {:ok, map()} \| {:blocked, [map()]}` | stable | 0.6.0 | The pure fold: no repo, no clock, no configuration. |

### 1.18 `AuroraMeter.Credits.Recurrences`

Recurring credit allowances: one grant per tenant, entitlement, plan version and
period, with a capped rollover and a bounded catch-up after downtime. The policy
is a plan property (`AuroraMeter.Plans.recurring_credits/2`); a plan that
declares none grants nothing. Pause it with
`AuroraMeter.Operations.pause("credits_recurrences:global")`. See
[Credits](credits.md) and [Plans](plans.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Credits.Recurrences.run/1` | `(keyword()) :: {:ok, summary()} \| {:error, term()}` | stable | 0.6.0 | Options `:limit` (500), `:batch` (50), `:max_periods` (12), `:tenant`, `:now`, `:dry_run`. Arity 0 exists through defaults. A wallet not on the lot engine is skipped with `reason: :lots_disabled`. |
| `AuroraMeter.Credits.Recurrences.status/1` | `(keyword()) :: status()` | stable | 0.6.0 | The checkpoint, the pause flag, and a tenant's recurrence rows newest first. Options `:tenant`, `:limit`. Arity 0 exists through defaults. |
| `AuroraMeter.Credits.Recurrences.periods/4` | `(tenant, DateTime.t() \| nil, DateTime.t(), pos_integer()) :: {:ok, [period()], :complete \| :truncated \| :up_to_date} \| {:error, term()}` | stable | 0.6.0 | The period walk on its own, over the configured period source. No database. |
| `AuroraMeter.Credits.Recurrences.namespace/0` | `() :: String.t()` | stable | 0.6.0 | `"recurring:"`, the one reserved reference prefix. |
| `AuroraMeter.Credits.Recurrences.operation/0` | `() :: String.t()` | stable | 0.6.0 | `"credits_recurrences:global"`, the `AuroraMeter.Operations` name. |

### 1.19 `AuroraMeter.Telemetry`

The telemetry contract: the event catalogue as data, the closed tag allow list,
the redaction helper and the on-demand gauges. See [Telemetry](telemetry.md).

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Telemetry.events/0` | `() :: [AuroraMeter.Telemetry.event_doc()]` | stable | 1.0.0 | Every core event, with its real measurement and metadata keys, the tags a preset may use, the emitter and the version it arrived in. Checked against `lib/`, `docs/api.md` and `docs/telemetry.md` on every run. |
| `AuroraMeter.Telemetry.event_names/0` | `() :: [[atom()]]` | stable | 1.0.0 | Every concrete event name, with a family expanded and a span's three suffixes listed. |
| `AuroraMeter.Telemetry.tag_allow_list/0` | `() :: [atom()]` | stable | 1.0.0 | `[:result, :kind, :exporter, :state, :worker]`. Closed. |
| `AuroraMeter.Telemetry.feature_tag/0` | `() :: atom()` | stable | 1.0.0 | `:feature`, the opt-in tag behind `:metrics_feature_label`. |
| `AuroraMeter.Telemetry.forbidden_tags/0` | `() :: [atom()]` | stable | 1.0.0 | Names that must never be a metric tag, listed one by one. |
| `AuroraMeter.Telemetry.forbidden_tag_suffixes/0` | `() :: [String.t()]` | stable | 1.0.0 | `["_key", "_id", "_secret", "_token", "_ref"]`. |
| `AuroraMeter.Telemetry.tag_allowed?/2` | `(atom(), boolean()) :: boolean()` | stable | 1.0.0 | The second argument is whether the host has turned the `:feature` tag on. |
| `AuroraMeter.Telemetry.redact/2` | `(map(), keyword()) :: map()` | stable | 1.0.0 | A copy safe for a log line or a span attribute. Option `:tenant` is `:drop` (default), `:digest` or `:raw`. `error` becomes `error_class`; the message is never carried. |
| `AuroraMeter.Telemetry.emit_gauges/0` | `() :: :ok` | stable | 1.0.0 | Emits the store and cluster gauges once, synchronously. For a host running `metrics_interval: 0` and its own scheduler. A process that is not running contributes no sample rather than a zero. |
| `AuroraMeter.Telemetry.gauges/0` | `() :: [%{event: [atom()], measurements: map(), age_ms: non_neg_integer()}]` | stable | 1.0.0 | The most recent sample of each gauge with how long ago it was taken, **without** emitting one. For a dashboard that refreshes faster than the sampling interval. A gauge that has never sampled contributes no entry rather than a zero. `age_ms` is a monotonic span inside this node. |

### 1.20 `AuroraMeter.Telemetry.Metrics` (optional dependency)

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Telemetry.Metrics.metrics/1` | `(keyword()) :: [Telemetry.Metrics.t()]` | optional-dep | 1.0.0 | Needs `telemetry_metrics` (`~> 0.6 or ~> 1.0`). Options `:feature_label` and `:include`. Arity 0 exists through defaults. Every tag is on the allow list. |
| `AuroraMeter.Telemetry.Metrics.groups/0` | `() :: [atom()]` | optional-dep | 1.0.0 | Needs `telemetry_metrics`. The groups `:include` accepts. |

Without `telemetry_metrics` installed the module is not defined at all. Every
event is still emitted and `AuroraMeter.Telemetry` still works; nothing in
`lib/` references this module.

### 1.21 `AuroraMeter.LiveDashboard.Page` (optional dependency)

A `Phoenix.LiveDashboard` page showing what Aurora Meter is doing on this node.
It is registered with `additional_pages:` and it **requires** the
`:authorized_by` option: there is no default and no implicit allow. The three
accepted forms, and why the core page accepts `:host_route` while the Pro page
refuses it, are in `AuroraMeter.LiveDashboard.Auth`.

The page renders no tenant key, feature name, reference or event id: every
figure on it is a node-local aggregate, a checkpoint position or a
configuration value. A section it could not read renders the word "unavailable"
with an error class, never a `0` and never an empty table. A gauge-derived
figure whose last sample is older than three `:metrics_interval`s renders as
stale with the sample age.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.LiveDashboard.Page.init/1` | `(keyword()) :: {:ok, map()}` | optional-dep | 1.0.0 | Needs `phoenix_live_dashboard` (`>= 0.8.0 and < 0.9.0`). Raises `ArgumentError` naming the option and the three accepted forms when `:authorized_by` is absent or unrecognised. |
| `AuroraMeter.LiveDashboard.Page.menu_link/2` | `(map(), map()) :: {:ok, String.t()} \| {:disabled, String.t()}` | optional-dep | 1.0.0 | Needs `phoenix_live_dashboard`. Disabled with "Aurora Meter: not configured" when `AuroraMeter.Config.validate!/0` raises. |
| `AuroraMeter.LiveDashboard.Page.mount/3` | `(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}` | optional-dep | 1.0.0 | Needs `phoenix_live_dashboard`. Evaluates the configured check before reading anything. |
| `AuroraMeter.LiveDashboard.Page.handle_refresh/1` | `(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}` | optional-dep | 1.0.0 | Needs `phoenix_live_dashboard`. Re-evaluates the check, so a session that loses its marker stops seeing data without waiting for a remount. |
| `AuroraMeter.LiveDashboard.Page.render/1` | HEEx | optional-dep | 1.0.0 | Needs `phoenix_live_dashboard`. Read-only: no form, no button, no `phx-click`. |

### 1.22 `AuroraMeter.OpenTelemetry` (optional dependency)

Attaches `:telemetry` handlers that turn Aurora Meter's slow operations into
OpenTelemetry spans **in the host's own SDK**. It uses the OpenTelemetry API and
only the API: it starts no tracer provider, no exporter and no batch processor,
and opens no socket. With the API present and no SDK configured, the no-op
tracer swallows everything.

The span attributes are redacted (`AuroraMeter.Telemetry.redact/2`), so no
tenant key, reference, object id or provider reference reaches a tracer, and a
failure sets the span status with an **empty** message: a status message is
free-form text and there is nothing safe to put in it.

The hot path is not instrumented: `[:aurora_meter, :track]`,
`[:aurora_meter, :reserve]`, `[:aurora_meter, :broadcast]`,
`[:aurora_meter, :cluster, :apply]` and every gauge produce no span unless the
caller names them in `:events`.

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.OpenTelemetry.attach/1` | `(keyword()) :: :ok` | optional-dep | 1.0.0 | Needs `opentelemetry_api` (`~> 1.2`), the **API** only: no tracer provider, no exporter, no socket. Options `:name`, `:events`, `:tenant`, `:span_prefix`, `:include`. Arity 0 exists through defaults. Calling it n times leaves the handler set one call leaves. With the API present and no SDK configured the no-op tracer swallows everything, which is documented behaviour and not an error. |
| `AuroraMeter.OpenTelemetry.detach/0` | `() :: :ok` | optional-dep | 1.0.0 | Needs `opentelemetry_api`. Removes every handler attached under the default name and leaves handlers attached by anything else alone. |
| `AuroraMeter.OpenTelemetry.detach/1` | `(atom()) :: :ok` | optional-dep | 1.0.0 | Needs `opentelemetry_api`. The same for one `:name` namespace. |

## 2. Behaviours and their callbacks

A host or an extension implements these. Adding a required callback to one of
them is a breaking change for implementers and does not happen during 1.x.

<!-- inventory:modules -->

| Entry | Callbacks | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Tenant` | `to_key/1` | stable | 0.1.0 | Must return a non-empty binary, and **a binary must pass through unchanged**: Pro hands stored `tenant_key` values back to facade functions. |
| `AuroraMeter.Period` | `current/2` required, `containing/2` optional | stable | 0.1.0 | `containing/2` is optional from 0.5.0. |
| `AuroraMeter.Clock` | `now/0`, `today/0`, `monotonic_ms/0`, `db_now/0` | stable | 0.5.0 | Four readings, all required. |
| `AuroraMeter.Storage` | `upsert_counters/1`, `add_counters/1`, `upsert_history/1`, `add_history/1`, `flush_batch/3`, `load_counter/3`, `load_history/3`, `load_history_range/4`, `get_subscription/1`, `put_subscription/1`, `insert_events/1`, `stream_counters/1`, `capabilities/0`, `record_events/2`, `load_event/2`, `load_event_total/3`, `stream_events/2`, `write_projection_totals/2`, `activate_projection/1` | stable | 0.1.0 | 19 callbacks, none optional. The seven durable ones arrived in 1.0.0; an adapter that cannot do them declares nothing from `capabilities/0` and the dispatcher refuses the call on its behalf. See [Storage adapters](storage-adapters.md). |
| `AuroraMeter.Credits.HoldReconciler` | `decide/1` | stable | 0.6.0 | What the host says about a hold that is still open long after its work should have finished. It may be called more than once for one hold, and anything that is not a decision means `:keep`. |
| `AuroraMeter.Events.Outbox` | `enqueue/2` | stable | 1.0.0 | Called inside the transaction that records an event, so an export intent commits with the fact. Core ships no delivery; Aurora Meter Pro implements it. |
| `AuroraMeter.Billing.Provider` | `create_checkout_session/2`, `billing_portal_url/2`, `sync_subscription/1`, `report_usage/1`, and optionally `describe_plan_change/3` and `update_subscription_plan/3` | stable | 0.1.0 | Aurora Meter Pro implements it for Stripe. The two optional callbacks arrived in 1.0.0 for scheduled plan changes; `AuroraMeter.Config.validate!/0` checks only the required four, so a provider written before them still boots. |

The implementations the core ships:

<!-- inventory:modules -->

| Entry | Implements | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Tenant.Default` | `AuroraMeter.Tenant` | stable | 0.1.0 | Binaries pass through, other terms are stringified. |
| `AuroraMeter.Period.Calendar` | `AuroraMeter.Period` | stable | 0.1.0 | UTC calendar month. |
| `AuroraMeter.Clock.System` | `AuroraMeter.Clock` | stable | 0.5.0 | The only implementation supported in production. |
| `AuroraMeter.Storage.Ecto` | `AuroraMeter.Storage` | internal | 0.1.0 | Configure it by name (it is the default); do not call it directly. |
| `AuroraMeter.Billing.Noop` | `AuroraMeter.Billing.Provider` | stable | 0.1.0 | The default provider. Every call returns `{:error, :not_configured}`. |
| `AuroraMeter.Events.Outbox.Noop` | `AuroraMeter.Events.Outbox` | stable | 1.0.0 | The default. Stages nothing, successfully. |

`AuroraMeter.Config.validate!/0` checks at boot that every module-typed key
names a module that exists and exports every callback its behaviour declares and
does not mark optional. The callback list is read from `behaviour_info/1`, never
copied.

## 3. Structs and public types

<!-- inventory:modules -->

| Entry | Shape | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Plan` | `%Plan{id, version, price, features, recurring_credits, effective_at, fingerprint}` | stable | 0.1.0 | Built by the DSL. `version`, `effective_at` and `fingerprint` are additive in 1.0.0. `feature_config/0` is the per-feature union; `recurring_credit/0` is one allowance declaration, and the list is empty unless the plan declares `AuroraMeter.Plans.recurring_credits/2`. |
| `AuroraMeter.Schema.PlanVersion` | `aurora_meter_plan_versions` row | additive | 1.0.0 | One immutable snapshot of a plan version's commercial content. Written only by `AuroraMeter.Plans.register!/0`. |
| `AuroraMeter.Schema.PlanTransition` | `aurora_meter_plan_transitions` row | additive | 1.0.0 | The audit row for a scheduled plan change. The table ships in core schema version 10; nothing writes it in this release. |
| `AuroraMeter.Schema.Counter` | `aurora_meter_counters` row | stable | 0.1.0 | |
| `AuroraMeter.Schema.History` | `aurora_meter_history` row | stable | 0.2.0 | |
| `AuroraMeter.Schema.Event` | `aurora_meter_events` row | stable | 0.1.0 | The Ecto schema. Its `inserted_at` field is exposed as `recorded_at` on `AuroraMeter.Event`. |
| `AuroraMeter.Event` | read struct | stable | 1.0.0 | What the durable event API hands back. Hosts match on it; nothing outside the library builds one. |
| `AuroraMeter.Schema.Subscription` | `aurora_meter_subscriptions` row | stable | 0.1.0 | |
| `AuroraMeter.Schema.CreditBalance` | `aurora_meter_credit_balances` row | stable | 0.4.0 | |
| `AuroraMeter.Schema.CreditTransaction` | `aurora_meter_credit_transactions` row | stable | 0.4.0 | |
| `AuroraMeter.UndeclaredFeatureError` | exception | stable | 0.5.0 | Raised under `undeclared_feature_policy: :raise`. Fields `feature`, `tenant_key`, `plan_id`, `entry`, `reason`. |
| `AuroraMeter.PlanVersionConflictError` | exception | additive | 1.0.0 | A compiled plan version's commercial content differs from the snapshot registered for it. Field `conflicts`, a list of maps with `plan_id`, `version`, `stored_fingerprint` and `compiled_fingerprint`. Rescue it in a release task; never retry it. |
| `AuroraMeter.Period.InvalidPeriodError` | exception | stable | 0.5.0 | Fields `source`, `tenant_key`, `period`, `instant`, `reason`. |
| `AuroraMeter.Credits.CurrencyMismatchError` | exception | stable | 0.5.0 | Fields `configured`, `stored`. |
| `AuroraMeter.Migration.ConcurrentVersionError` | exception | stable | 1.0.0 | A version that must run outside a DDL transaction was given company. Fields `versions`, `concurrent`. |
| `AuroraMeter.Migration.DataLossError` | exception | stable | 1.0.0 | A `down` that destroys a commercial fact, without `confirm_data_loss: true`. Fields `versions`, `destructive`. |
| `AuroraMeter.Migration.BackfillIncompleteError` | exception | stable | 1.0.0 | Core schema version 8 refusing while an `event_id` is still null. Field `remaining`. |

Named types a host will meet in a spec: `t:AuroraMeter.Period.t/0`,
`t:AuroraMeter.Entitlements.quota/0` and `t:AuroraMeter.Entitlements.check_result/0`,
`t:AuroraMeter.Credits.balance/0`, `t:AuroraMeter.Credits.money_point/0`,
`t:AuroraMeter.Credits.money_total/0`, `t:AuroraMeter.Credits.summary/0` and
`t:AuroraMeter.Credits.txn/0`, `t:AuroraMeter.Credits.Money.micro/0`,
`t:AuroraMeter.Storage.counter_row/0`, `t:AuroraMeter.Storage.history_row/0`,
`t:AuroraMeter.Storage.history_point/0`, `t:AuroraMeter.Storage.event_row/0`,
`t:AuroraMeter.Storage.counter_delta/0`, `t:AuroraMeter.Storage.history_delta/0`,
`t:AuroraMeter.Storage.counter_total/0`, `t:AuroraMeter.Storage.correction_entry/0` and `t:AuroraMeter.Storage.history_total/0`,
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
(`:insufficient_credits`, `:debt_outstanding`, `:duplicate_reference`, `:not_found`,
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
| `:plan_version_conflict` | `:raise \| :warn`, `:warn` in 0.5.x and `:raise` from 1.0 | additive | 1.0.0 | What `AuroraMeter.Plans.register!/0` does when a compiled plan version's content differs from its registered snapshot. Neither setting reprices anybody: the tenant stays on the stored definition either way. |
| `:durable_features` | list of atoms, `[]` | deprecated | 0.1.0 | The legacy durable-track list. Kept and warned through 1.x, removed in 2.0. |
| `:feature_sources` | map of atom to `:buffered \| :events`, `%{}` | additive | 1.0.0 | Where each feature's commercial quantity comes from. Anything not listed is `:buffered`. |
| `:events_outbox` | atom or `nil`, `nil` | additive | 1.0.0 | Must implement `AuroraMeter.Events.Outbox`. Called inside the record transaction so an export intent commits with the fact. |
| `:events_future_tolerance` | non-negative integer, `300` | additive | 1.0.0 | Seconds an `occurred_at` may run ahead of the node clock before `AuroraMeter.record/4` refuses it. |
| `:record_timeout` | positive integer, `15_000` | additive | 1.0.0 | Milliseconds for one durable write, applied to the transaction and every statement in it. |
| `:record_max_concurrency` | positive integer, `64` | additive | 1.0.0 | Callers that may hold an open record transaction at once. Beyond it, `{:error, {:unavailable, :overloaded}}`; never a fallback to buffered tracking. |
| `:flush_interval` | positive integer, `5_000` | stable | 0.1.0 | Milliseconds. |
| `:broadcast_interval` | positive integer, `1_000` | stable | 0.1.0 | Milliseconds. |
| `:metrics_interval` | non-negative integer, `10_000` | additive | 1.0.0 | Milliseconds between gauge samples. `0` switches the internal timers off; drive `AuroraMeter.Telemetry.emit_gauges/0` yourself instead. |
| `:metrics_feature_label` | boolean, `false` | additive | 1.0.0 | Whether `AuroraMeter.Telemetry.Metrics.metrics/1` tags on `:feature`. One series per feature per metric, so the host prices it. |
| `:metrics_scan_ceiling` | non-negative integer, `50_000` | additive | 1.0.0 | The largest counters table the cluster lag gauge scans for `unreconciled_keys`. Above it the measurement is omitted, never zero. |
| `:flush_receipt_retention` | positive integer, `30` | additive | 1.0.0 | Days a flush receipt is kept before `AuroraMeter.Retention` may delete it. Floor 1 day, refused at boot below it. Age alone never deletes one. |
| `:replay_checkpoint_retention` | positive integer, `365` | additive | 1.0.0 | Days a finished `"events_replay:<generation>"` checkpoint row is kept. Floor 1 day. |
| `:flush_node_id` | string or `nil`, `nil` | additive | 1.0.0 | This node's identity in its `"flush:<node>"` heartbeat row. `nil` means `to_string(node())`. |
| `:history` | boolean, `true` | stable | 0.2.0 | UTC day buckets for `AuroraMeter.history/3`. |
| `:subscription_cache_ttl` | non-negative integer, `5_000` | stable | 0.2.0 | Milliseconds. `0` disables the cache. |
| `:cluster_sync` | boolean, `true` | stable | 0.3.0 | Delta gossip and total announcements between nodes. |
| `:credits_currency` | string, `"usd"` | stable | 0.4.0 | ISO 4217, stamped on new balance rows and checked at boot from 0.5.0. |
| `:credits_overdraft_tolerance` | non-negative integer, `0` | stable | 0.4.0 | Micro-dollars. |
| `:credits_low_balance_threshold` | integer or `nil`, `nil` | stable | 0.4.0 | Micro-dollars. A balance row's own threshold overrides it. |
| `:credits_low_balance_handler` | 1-arity function or `nil`, `nil` | stable | 0.4.0 | Called with `%{tenant_key, available, threshold}` after the crossing commits. |
| `:credits_hold_reconciler` | module, `{module, function}`, 1-arity function or `nil`; `nil` | stable | 0.6.0 | How `AuroraMeter.Credits.reconcile_holds/1` decides about a stale hold. `nil` keeps every hold, so upgrading and configuring nothing cannot release money. |
| `:credits_hold_reconciler_timeout` | positive integer, `5_000` | stable | 0.6.0 | Milliseconds one `decide/1` call may take before it is killed and the hold kept. |
| `:credits_low_balance_handler_timeout` | positive integer, `5_000` | stable | 0.6.0 | Milliseconds one `:credits_low_balance_handler` call may take before it is killed. The ledger write stands either way: the handler runs in a supervised watcher, so it cannot fail, block, delay or crash the caller. The caller does not wait for it, so `[:aurora_meter, :credits, :low_balance]` arrives after the ledger call returns. |
| `:live_view_tenant` | `{module, function}` or `nil`; `nil` | additive | 1.0.0 | How `on_mount {AuroraMeter.LiveView, :subscribe}` resolves the tenant, called with `(session, socket)`. No default resolver: the bare form raises without it, because a fallback would resolve an unresolved tenant to `""`. |

## 6. Telemetry events

Event names, measurement keys and metadata keys are covered by SemVer. The
`Matched in lib/` column holds the event name as `AuroraMeter.Test.TelemetryCensus`
reads it out of the parsed source, so a renamed event fails the build. A name
whose last segment is computed is written with the computed segment's own name
(`[:aurora_meter, :credits, kind]`), and the family it stands for is enumerated
by `AuroraMeter.Telemetry.events/0`.

<!-- inventory:literal -->

| Event | Measurements | Metadata | Class | Since | Matched in lib/ |
|---|---|---|---|---|---|
| `[:aurora_meter, :track]` | `count` | `tenant_key`, `feature`, `declared` | stable | 0.1.0 | `[:aurora_meter, :track]` |
| `[:aurora_meter, :reserve]` | `qty` | `tenant_key`, `feature`, `result`, `declared` | stable | 0.2.0 | `[:aurora_meter, :reserve]` |
| `[:aurora_meter, :flush]` | `count`, `delta_sum` | none | stable | 0.1.0 | `[:aurora_meter, :flush]` |
| `[:aurora_meter, :flush, :error]` | `count` | `error` | stable | 0.3.0 | `[:aurora_meter, :flush, :error]` |
| `[:aurora_meter, :flush, :start \| :stop \| :exception]` | `duration`, `count`, `delta_sum` | `batch_id`, `counter_rows`, `history_rows`, `result`, and `kind`, `reason`, `stacktrace` on `:exception` | stable | 1.0.0 | `[:aurora_meter, :flush]` |
| `[:aurora_meter, :broadcast]` | `count`, `deltas` | none | stable | 0.1.0 | `[:aurora_meter, :broadcast]` |
| `[:aurora_meter, :cluster, :apply]` | `count` | `kind`, `origin` | stable | 0.3.0 | `[:aurora_meter, :cluster, :apply]` |
| `[:aurora_meter, :cluster, :lag]` | `peers`, `since_last_message_ms`, `unreconciled_keys` | `node` | stable | 1.0.0 | `[:aurora_meter, :cluster, :lag]` |
| `[:aurora_meter, :store, :gauge]` | `dirty_keys`, `counter_keys`, `oldest_pending_age_ms`, `pending_batch_age_ms`, `pending_batch_items` | `node` | stable | 1.0.0 | `[:aurora_meter, :store, :gauge]` |
| `[:aurora_meter, :credits, kind]` | `amount`, `balance_after`, `available_after`, `spendable_after` | `tenant_key`, `reference`, `category`, `duplicate`, `overrun`, `deferred` | stable | 0.4.0 | `[:aurora_meter, :credits, kind]` |
| `[:aurora_meter, :credits, :low_balance]` | `available`, `spendable`, `threshold` | `tenant_key`, `crossing_id`, `handler` | stable | 0.4.0 | `[:aurora_meter, :credits, :low_balance]` |
| `[:aurora_meter, :credits, :hold_reconciliation]` | `amount`, `age_seconds`, `duration` | `tenant_key`, `reference`, `decision`, `outcome` | stable | 0.6.0 | `[:aurora_meter, :credits, :hold_reconciliation]` |
| `[:aurora_meter, :credits, :conservation_error]` | `balance_delta`, `held_delta`, `promotional_delta`, `expired_delta` | `tenant_key`, `operation`, `reference` | stable | 0.6.0 | `[:aurora_meter, :credits, :conservation_error]` |
| `[:aurora_meter, :credits, :lot_migration]` | `wallets`, `migrated`, `blocked`, `deferred`, `rows`, `duration_ms` | `shadow`, `state` | stable | 0.6.0 | `[:aurora_meter, :credits, :lot_migration]` |
| `[:aurora_meter, :credits, :recurrence]` | `amount`, `rollover_amount` | `tenant_key`, `name`, `plan_id`, `plan_version`, `period_start`, `result`, `reason` | stable | 0.6.0 | `[:aurora_meter, :credits, :recurrence]` |
| `[:aurora_meter, :plans, :transition]` | `count` | `tenant_key`, `ref`, `from_plan_id`, `from_version`, `to_plan_id`, `to_version`, `result` | stable | 1.0.0 | `[:aurora_meter, :plans, :transition]` |
| `[:aurora_meter, :events, :backfill, :batch]` | `scanned`, `updated`, `batches` | `cursor` | stable | 1.0.0 | `[:aurora_meter, :events, :backfill, :batch]` |
| `[:aurora_meter, :record, :start \| :stop \| :exception]` | `duration`, `count` | `result`, `kind`, `feature`, `batch_size`, `tenant_key`, `durability`, `projection` | stable | 1.0.0 | `[:aurora_meter, :record]` |
| `[:aurora_meter, :replay, :batch]` | `scanned`, `keys`, `duration` | `generation`, `cursor`, `phase` | stable | 1.0.0 | `[:aurora_meter, :replay, :batch]` |
| `[:aurora_meter, :replay, :phase]` | `duration` | `generation`, `phase`, and per phase `seeded`, `resumed`, `drained`, `differences` | stable | 1.0.0 | `[:aurora_meter, :replay, :phase]` |
| `[:aurora_meter, :operations, :batch]` | `items`, `duration_ms` | `name`, `result` | stable | 1.0.0 | `[:aurora_meter, :operations, :batch]` |
| `[:aurora_meter, :retention, :prune]` | `deleted`, `duration` | `table`, `blocked` | stable | 1.0.0 | `[:aurora_meter, :retention, :prune]` |

`declared` was added to the `track` and `reserve` metadata in 0.5.0, which is an
additive change: a handler matching on the old keys is unaffected.

`record` is a **span**, not a flat event: an OpenTelemetry bridge has to be able
to open it before the database work starts, so Ecto's own spans nest inside it,
and a span reconstructed after the fact cannot parent a child that was already
emitted. `:telemetry.span/3` emits `:start`, `:stop` and `:exception` under the
`[:aurora_meter, :record]` prefix; metrics presets read `:stop`, where `duration`
and `count` are the measurements. `result` is `:inserted`, `:duplicate` or the
error tag (`:invalid`, `:conflict`, `:unavailable`, `:unsupported`), and
`projection` is `:ok`, `:cold` or `:projection_failed`, which is how a committed
event whose in-memory view could not be updated stays visible without becoming
an error.

The backfill batch event is emitted once per committed batch of
`mix aurora_meter.events.backfill`. It is the only observable a long backfill
has, and `cursor` is the `seq` an interrupted run resumes from.

The two replay events are `AuroraMeter.Events.Replay.run/1`'s observables.
`[:aurora_meter, :replay, :batch]` fires once per committed batch with
`phase: :scan`, and its `cursor` is the `seq` an interrupted run resumes from.
`[:aurora_meter, :replay, :phase]` fires once for each of `:announce`,
`:drain`, `:compare` and `:activate`; `:announce` carries `seeded` (rows copied
into the building generation) and `resumed`, `:drain` carries `drained`, and
`:compare` and `:activate` carry `differences`. A replay that finds differences
under the default `compare: :require_match` emits `:compare` and no `:activate`,
which is the shape a dashboard should alert on.

`kind` in the credits event is one of `:grant`, `:hold`, `:settle`, `:release`,
`:debit` or `:expire`. `duplicate: true` marks an idempotent grant replay (with
`amount: 0`); `overrun: true` marks a settlement above its hold.

`tenant_key` is metadata, never a metric tag: the cardinality is unbounded. The
closed set of names a metric may tag on, the names it may never tag on and the
reason for each are in [Telemetry](telemetry.md), and
`AuroraMeter.Telemetry.tag_allowed?/2` answers the question in code.

The flush span sits alongside the flat `[:aurora_meter, :flush]` event rather
than replacing it: a host attached to the flat name is unaffected, and a host
that wants flush latency attaches to `[:aurora_meter, :flush, :stop]`. An
`{:error, reason}` from storage is `:stop` with `result: :error`; a raise is
`:exception`. Both are followed by the unchanged `[:aurora_meter, :flush, :error]`.

The two gauges are sampled every `:metrics_interval` inside `AuroraMeter.Store`
and `AuroraMeter.Cluster`. No gauge event is emitted when `metrics_interval` is
`0`, and none is emitted for the cluster when `cluster_sync` is `false`.
`unreconciled_keys` is omitted above `:metrics_scan_ceiling` rather than
reported as zero.

## 7. PubSub messages

Message tags are covered by SemVer. Payload maps gain keys additively, so match
on the keys you need rather than on the whole map.

<!-- inventory:literal -->

| Message | Topic | Class | Since | Matched in lib/ |
|---|---|---|---|---|
| `{:aurora_meter, :usage, %{tenant_key, feature, value, period_start}}` | `AuroraMeter.Broadcaster.topic/1` | stable | 0.1.0 | `{:aurora_meter, :usage,` |
| `{:aurora_meter, :deltas, node(), [{key, delta}]}` | `"aurora_meter:cluster"` | internal | 0.3.0 | `{:aurora_meter, :deltas, node(), deltas}` |
| `{:aurora_meter, :totals, node(), [{key, total}]}` | `"aurora_meter:cluster"` | internal | 0.3.0 | `{:aurora_meter, :totals, node(), totals}` |
| `{:aurora_meter, :subscription_changed, tenant_key}` | `"aurora_meter:subscriptions"` | internal | 0.2.0 | `{:aurora_meter, :subscription_changed, key}` |
| `{:aurora_meter, :credits, %{tenant_key, balance, held, available, spendable, debt, expired}}` | `AuroraMeter.Credits.topic/1` | stable | 0.4.0 | `{:aurora_meter, :credits,` |
| `{:aurora_meter, :event, %{tenant_key, feature, event_id, quantity, period_start, kind}}` | `AuroraMeter.Broadcaster.topic/1` | stable | 1.0.0 | `{:aurora_meter, :event,` |
| `{:aurora_meter, :plan_transition, %{tenant_key, ref, state}}` | `AuroraMeter.Broadcaster.topic/1` | stable | 1.0.0 | `{:aurora_meter, :plan_transition,` |
| `{:aurora_meter, :low_balance, %{tenant_key, available, spendable, threshold, crossing_id}}` | `AuroraMeter.Credits.topic/1` | stable | 0.4.0 | `{:aurora_meter, :low_balance, event}` |

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
| `Mix.Tasks.AuroraMeter.Events.Backfill` | `mix aurora_meter.events.backfill` | stable | 1.0.0 | Run between core schema versions 7 and 8. Options `-r`, `--batch-size`, `--max-batches`, `--dry-run`, `--force-resume`, `--stale-after`. |
| `Mix.Tasks.AuroraMeter.Credits.MigrateLots` | `mix aurora_meter.credits.migrate_lots` | stable | 0.6.0 | Run after core schema version 9, with every node already on a release that honours `lots_enabled_at`. Shadow by default. Options `-r`, `--shadow` / `--no-shadow`, `--tenant`, `--batch`, `--no-resume`, `--max-rows`, `--max-tail`, `--max-wallets`, `--retry-blocked`, `--report-only`. Exits non-zero when any wallet was blocked. |

## 9. Migration entry points

<!-- inventory:functions -->

| Entry | Signature and return | Class | Since | Notes |
|---|---|---|---|---|
| `AuroraMeter.Migration.latest_version/0` | `() :: pos_integer()` | stable | 0.2.0 | `8` in this release. |
| `AuroraMeter.Migration.concurrent_versions/0` | `() :: [pos_integer()]` | stable | 1.0.0 | Versions needing a host migration of their own, with `@disable_ddl_transaction true` and `@disable_migration_lock true`. |
| `AuroraMeter.Migration.data_loss_versions/0` | `() :: [pos_integer()]` | stable | 1.0.0 | Versions whose `down` needs `confirm_data_loss: true`. |
| `AuroraMeter.Migration.up/1` | `(keyword()) :: :ok` | stable | 0.2.0 | Options `:version`, `:from`, `:concurrently`, `:validate_checks`, `:lock_timeout`. Arity 0 exists through defaults. Every version is idempotent. |
| `AuroraMeter.Migration.down/1` | `(keyword()) :: :ok` | stable | 0.2.0 | Options `:version`, `:to`, `:confirm_data_loss`. Arity 0 exists through defaults. |
| `AuroraMeter.Checkpoints.get/1` | `(String.t()) :: map() \| nil` | stable | 1.0.0 | Where a bounded task got to. `nil` below core schema version 7, which is how a pre-V7 database is detected. |
| `AuroraMeter.Checkpoints.all/0` | `() :: [map()]` | stable | 1.0.0 | Every checkpoint, name order. |
| `AuroraMeter.Checkpoints.put/4` | `(String.t(), map(), map(), String.t()) :: :ok` | stable | 1.0.0 | |
| `AuroraMeter.Checkpoints.update/2` | `(String.t(), keyword()) :: :ok \| {:error, :not_found}` | stable | 1.0.0 | Merges `:cursor`, `:counts` or `:state`. |
| `AuroraMeter.Checkpoints.delete/1` | `(String.t()) :: :ok` | stable | 1.0.0 | |
| `AuroraMeter.Checkpoints.pause/1` | `(String.t()) :: :ok` | stable | 1.0.0 | The task stops at its next batch boundary. |
| `AuroraMeter.Checkpoints.resume/1` | `(String.t()) :: :ok` | stable | 1.0.0 | |
| `AuroraMeter.Checkpoints.paused?/1` | `(String.t()) :: boolean()` | stable | 1.0.0 | |
| `AuroraMeter.Checkpoints.heartbeat/2` | `(String.t(), keyword()) :: :ok \| {:error, :not_found}` | stable | 1.0.0 | Stamps `heartbeat_at` and `runner` into the cursor with the database's clock. A report for a human; nothing decides anything from it. |
| `AuroraMeter.Checkpoints.claim/3` | `(String.t(), (-> result), keyword()) :: {:ok, result} \| {:error, :already_running}` | stable | 1.0.0 | Runs the function under a Postgres session advisory lock on a pinned connection. The exclusion every bounded task uses, with no clock in it. |
| `AuroraMeter.Checkpoints.runner/0` | `() :: String.t()` | stable | 1.0.0 | The `<node>/<pid>` identity `heartbeat/2` stamps. |

The schema-version contract: a host calls these from its own Ecto migration.
Versions are additive during 1.x. `AuroraMeter.Migration.V1` to `V8` are
implementation modules and are internal (section 11).

Core schema version 8 is the one version that cannot share a host migration
file with any other: it creates a unique index `CONCURRENTLY`, which Postgres
refuses inside a transaction block. `mix aurora_meter.gen.migration` emits it
as its own file, and `up/1` raises `AuroraMeter.Migration.ConcurrentVersionError`
rather than let it run halfway. A fresh install passes `concurrently: false`
and builds the index inside the transaction, which is right for a table with
no rows in it.

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
| `AuroraMeter.StorageCase.entry/3` | `(map(), String.t(), pos_integer()) :: AuroraMeter.Storage.event_entry()` | stable | 1.0.0 | One canonical entry for the adapter conformance suite. |
| `AuroraMeter.StorageCase.correction/4` | `(map(), String.t(), String.t(), pos_integer() \| :remaining) :: AuroraMeter.Storage.correction_entry()` | stable | 1.0.0 | One correction entry for the adapter conformance suite. |
| `AuroraMeter.StorageCase.active_generation/0` | `() :: non_neg_integer()` | stable | 1.0.0 | The projection generation reads currently resolve to. |

`use AuroraMeter.StorageCase, adapter: MyApp.Storage` runs the adapter conformance
suite against a custom `AuroraMeter.Storage` implementation; see
[Storage adapters](storage-adapters.md).

`use AuroraMeter.Test` in an `ExUnit.CaseTemplate` installs the checkout and
reset callbacks; see [Testing](testing.md).

## 11. Internal modules

These are compiled, public in the Erlang sense, and documented so the guides and
the ADRs can link to them. They are **not** part of the supported surface. Each
that renders a page carries a stability banner at the top of its module docs and
appears under the "Internal" group in the generated documentation; the
`AuroraMeter.Bench.*` modules carry `@moduledoc false` instead and render no page
at all, because they are the benchmark's own machinery rather than anything a
guide links to. They are listed here for the same reason as the rest: a boundary
you cannot name is not a boundary.

The inventory test holds this list as a module attribute and fails when a module
on it appears anywhere in the tables above, and when this list and the
`groups_for_modules` "Internal" group in `mix.exs` disagree.

<!-- inventory:internal -->

| Entry | Why it is internal |
|---|---|
| `AuroraMeter.Bench.DelayStorage` | An `AuroraMeter.Storage` that delays every callback, for the `db_delay` bench mode. |
| `AuroraMeter.Bench.MemoryStorage` | An `AuroraMeter.Storage` holding one subscription and nothing else, so the micro bench modes have no database anywhere in their path. |
| `AuroraMeter.Bench.Mode` | The behaviour every bench mode implements, and the monotonic timer they share. |
| `AuroraMeter.Bench.Modes` | The bench mode table: name, kind, whether it reaches Postgres, and which module implements it. |
| `AuroraMeter.Bench.Modes.Cluster` | The `cluster_2` and `cluster_4` bench modes, on real peer nodes. |
| `AuroraMeter.Bench.Modes.Counters` | The `spread`, `hot` and `cluster_2_sim` bench modes. |
| `AuroraMeter.Bench.Modes.Durable` | The `record`, `record_batch`, `correct` and `replay` bench modes. |
| `AuroraMeter.Bench.Modes.Faults` | The `db_delay` and `db_recovery` bench modes. |
| `AuroraMeter.Bench.Modes.Flush` | The `flush_1k`, `flush_10k` and `flush_100k` bench modes. |
| `AuroraMeter.Bench.Modes.Quota` | The `reserve` and `with_quota` bench modes. |
| `AuroraMeter.Bench.Modes.Wallet` | The `credits_debit` and `credits_hot_wallet` bench modes. |
| `AuroraMeter.Bench.Plans` | The plans `mix aurora_meter.bench` measures against. Not a fixture a host should copy. |
| `AuroraMeter.Bench.Report` | The machine-readable record one bench run produces. |
| `AuroraMeter.Bench.Runner` | Sets a bench mode up, warms it, measures it, checks it and assembles its record. |
| `AuroraMeter.Bench.Stats` | Nearest-rank percentiles and medians for the bench. |
| `AuroraMeter.BootChecks` | The boot-time child that runs `AuroraMeter.Credits.assert_currency!/0`. Call the public function. |
| `AuroraMeter.Broadcaster` | The PubSub fan-out process. Only `topic/1` is supported, and it is listed in section 1.8. |
| `AuroraMeter.Cluster` | The delta and total gossip protocol between nodes. `apply/3` stays documented because `AuroraMeter.Test.simulate_node/3` calls it; use the test helper, not this. |
| `AuroraMeter.Config.Schema` | The configuration conventions shared with Pro. Pro adopts them by passing its own schema, never by depending on this module. |
| `AuroraMeter.Counter` | The ETS row layout and the reserve or commit protocol. Hosts never touch ETS rows. |
| `AuroraMeter.Credits.Allocator` | The single allocation engine behind every credit movement on a cut-over wallet. The planner is pure and the applier writes what it decided; neither is a supported entry point. |
| `AuroraMeter.Credits.Ledger` | The ledger implementation behind `AuroraMeter.Credits`. |
| `AuroraMeter.Credits.Promotions` | Promotional-remainder arithmetic for expiry. |
| `AuroraMeter.Credits.Reconciliation` | The run loop behind `AuroraMeter.Credits.reconcile_holds/1`: listing, the host callback and its timeout, applying the decision, telemetry. |
| `AuroraMeter.Credits.Series` | The money series queries behind `spend_history/2` and `spend_total/2`. |
| `AuroraMeter.Events.Backfill` | The implementation behind `mix aurora_meter.events.backfill`. Run the task. |
| `AuroraMeter.Events.Canonical` | The canonical payload encoding behind `payload_hash` (ADR 0009), and the validation `AuroraMeter.record/4` runs before any I/O. |
| `AuroraMeter.Events.Gate` | The admission counter that bounds concurrent durable writes. Configure `:record_max_concurrency`; there is nothing to call. |
| `AuroraMeter.Install.Options` | Parses and validates `--feature-policy` and `--events-source` for both definitions of the install task, so the Igniter-less fallback cannot silently ignore a switch. |
| `AuroraMeter.Install.Plan` | The host migration files an install or an upgrade has to become, for both packages. Both generators and both installers read it, so no two of them can emit a different file. |
| `AuroraMeter.Install.Templates` | The strings the installer writes. |
| `AuroraMeter.LiveDashboard.Auth` | The `:authorized_by` contract both dashboard pages are registered with. Register the page; the option is documented on it. |
| `AuroraMeter.LiveDashboard.NotStartedError` | Raised inside the section readers when a node-local table is absent, and converted into `{:unavailable, :not_started}`. It is never raised out of them. |
| `AuroraMeter.LiveDashboard.Sections` | The readers behind the core page. They answer `{:ok, data}` or `{:unavailable, class}` and never a zero in place of a value they could not read. |
| `AuroraMeter.LiveDashboard.View` | The HEEx the core page renders. It reads nothing. Needs `phoenix_live_view`: it opens with `if Code.ensure_loaded?(Phoenix.Component) do`, so on a build without LiveView it does not exist. |
| `AuroraMeter.Migration.V1` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V2` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V3` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V4` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V5` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V6` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V7` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V8` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V9` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.Migration.V10` | One schema version. Call `AuroraMeter.Migration.up/1`. |
| `AuroraMeter.OpenTelemetry.Bridge` | Everything the OpenTelemetry bridge does, with the tracer as a parameter, so the handler rules are compiled and tested in a build with no OpenTelemetry. Call `AuroraMeter.OpenTelemetry.attach/1`. |
| `AuroraMeter.OpenTelemetry.Tracer` | The three calls the bridge makes on a tracer. A seam, not a host extension point. |
| `AuroraMeter.Plans.Snapshot` | The canonical form a plan fingerprint is taken over, and the jsonb encoding of a stored definition. Read a plan through `AuroraMeter.Plans`. |
| `AuroraMeter.Schema.FlushReceipt` | The idempotent flush receipt row. Bookkeeping for the flusher. |
| `AuroraMeter.Storage.Ecto` | The bundled adapter. Configure it by name; the callbacks are section 2. |
| `AuroraMeter.Store` | Owns the ETS tables and the pending flush batch. |
| `AuroraMeter.Subscriptions.Preview` | The entitlement diff and the provider resolution behind `AuroraMeter.Subscriptions.preview_transition/3`. |
| `AuroraMeter.Subscriptions.Transitions` | The plan transition state machine: the locked reads, the conditional updates and the due scan. Call `AuroraMeter.Subscriptions`. |
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
