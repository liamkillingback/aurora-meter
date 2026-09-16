defmodule AuroraMeter.Subscriptions do
  @moduledoc """
  Cached subscription lookups, and the scheduled plan change.

  Resolving a tenant's plan on every `check/2` or `reserve/3` would otherwise
  cost one database query per request. `get/1` memoises the storage lookup in
  ETS for `:subscription_cache_ttl` milliseconds (default 5s, `0` disables), and
  every write through `AuroraMeter.Storage.put_subscription/1` evicts the entry
  locally and broadcasts the eviction over PubSub so other nodes drop it too.

  The cache is transparent: it only ever holds what storage returned.

  ## Moving a tenant between plans

  A plan change is **explicit and scheduled**. Redeploying a plan definition
  never moves anybody (decision D05, invariant I17); a tenant moves because
  somebody scheduled it, at an instant they chose, with a reference they can
  cancel or retry.

      {:ok, transition} =
        AuroraMeter.Subscriptions.schedule_transition("org_1", :scale, ref: "upgrade-8412")

  With no `:effective_at` that is the end of the tenant's current period, from
  the tenant's own period source: the first of next month under the calendar
  default, `current_period_end` under `AuroraMeter.Pro.Period`, the end of the
  week under a weekly host source. Until that instant the tenant is entitled
  under the old plan, and nothing about the change is visible to `check/2`.

  `apply_due_transitions/1` is what moves them, and a host runs it from
  whatever scheduler it already has (`AuroraMeter.Oban.PlanTransitions` when
  that is Oban). It is safe to run from every node at once: every effect is a
  conditional update, so one run applies the change and the others report a
  skip.

  See [Plans](plans.md) for the lifecycle, the precedence table, the lag the
  default schedule implies and how to tighten it.

  ## Core never prorates

  `preview_transition/3` reports each plan's **declared list price**, never an
  invoice amount. Aurora Meter computes no proration of any kind: the billing
  provider is authoritative for what a customer is charged, and the provider
  section of a preview is the only place a price id or a proration mode
  appears.
  """

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Subscriptions.Preview
  alias AuroraMeter.Subscriptions.Transitions
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  @typedoc """
  What one `apply_due_transitions/1` call did.

  `cursor` is `:done` when the page came back shorter than `:limit`, and
  otherwise the value to pass as `:after` for the next page.
  """
  @type applied :: %{
          applied: non_neg_integer(),
          skipped: non_neg_integer(),
          failed: non_neg_integer(),
          cursor: String.t() | :done
        }

  @typedoc """
  An error from the transition API.

  `:invalid` carries a keyword list of field and message; `:conflict` carries a
  map naming what disagreed; `:not_found` names `:subscription` or
  `:transition`; `:unavailable` names why the operation cannot run yet.
  """
  @type error :: {:invalid | :conflict | :not_found | :unavailable, term()}

  @doc """
  Returns the tenant's subscription (or `nil`), served from the cache when warm.

  ## Examples

      iex> AuroraMeter.Subscriptions.get("nobody_#{System.unique_integer([:positive])}")
      nil

  """
  @spec get(term()) :: Subscription.t() | nil
  def get(tenant) do
    key = Tenant.to_key(tenant)
    ttl = Config.subscription_cache_ttl()
    table = Store.subscription_cache_table()

    if ttl == 0 or :ets.whereis(table) == :undefined do
      Storage.get_subscription(key)
    else
      now = Clock.monotonic_ms()

      case :ets.lookup(table, key) do
        [{^key, subscription, expires_at}] when expires_at > now ->
          subscription

        _cold ->
          subscription = Storage.get_subscription(key)
          :ets.insert(table, {key, subscription, now + ttl})
          subscription
      end
    end
  end

  @doc """
  Drops the cached subscription for `tenant` on this node and announces the
  change so every other node drops it as well.

  ## Examples

      iex> AuroraMeter.Subscriptions.invalidate("org_1")
      :ok

  """
  @spec invalidate(term()) :: :ok
  def invalidate(tenant) do
    key = Tenant.to_key(tenant)
    table = Store.subscription_cache_table()

    if :ets.whereis(table) != :undefined, do: :ets.delete(table, key)

    PubSub.broadcast(
      Config.pubsub(),
      Store.invalidation_topic(),
      {:aurora_meter, :subscription_changed, key}
    )

    :ok
  end

  @doc """
  Schedules one plan change for `tenant`, effective at a period boundary.

  Options:

    * `:ref` (**required**): the caller's idempotency reference, 1 to 128
      bytes, unique per tenant. Submitting the same reference with the same
      parameters returns the existing transition; with different parameters it
      is a conflict naming both. This is the same identity rule `record/4`
      applies to events, deliberately.
    * `:version`: the plan version to move to. Without it, the version in force
      at `:effective_at`, which is what makes "upgrade at the boundary" pick up
      a version that becomes effective at that boundary and refuse one that
      becomes effective later.
    * `:effective_at`: a UTC `DateTime` in the future. Defaults to the end of
      the tenant's current period, from the tenant's own period source.
    * `:replace` (default `true`): cancel an existing pending transition in the
      same transaction. With `false`, a second reference is a conflict.
    * `:confirm` (default `:local`): `:provider` keeps the transition pending
      and visible until a billing provider confirms it with
      `confirm_transition/3`, which is how a paid upgrade is ordered "provider
      first, local second" (task 07.07).
    * `:detail`: a map merged into the audit row's `detail`.

  Errors are `{:error, {:invalid, [field: message]}}`,
  `{:error, {:conflict, map}}`, `{:error, {:not_found, :subscription}}` (a
  tenant with no subscription is on the default plan and has nothing to move
  from) and `{:error, {:unavailable, :registration_incomplete}}` (the tenant's
  row has no `plan_version` yet, so `AuroraMeter.Plans.register!/0` has not run
  since the upgrade to core schema version 10).

  ## Examples

      AuroraMeter.Subscriptions.schedule_transition("org_1", :scale, ref: "upgrade-8412")
      #=> {:ok, %AuroraMeter.Schema.PlanTransition{state: "pending"}}

  """
  @spec schedule_transition(term(), atom() | String.t(), keyword()) ::
          {:ok, PlanTransition.t()} | {:error, error()}
  def schedule_transition(tenant, to_plan, opts \\ []) do
    Transitions.schedule(tenant, to_plan, opts)
  end

  @doc """
  Cancels the pending transition `ref` for `tenant`.

  Idempotent: cancelling an already cancelled transition returns it unchanged.
  An applied transition is `{:error, {:conflict, %{state: "applied"}}}`, and an
  unknown reference is `{:error, {:not_found, :transition}}`.

  ## Examples

      AuroraMeter.Subscriptions.cancel_transition("org_1", "upgrade-8412")
      #=> {:ok, %AuroraMeter.Schema.PlanTransition{state: "cancelled"}}

  """
  @spec cancel_transition(term(), String.t(), keyword()) ::
          {:ok, PlanTransition.t()} | {:error, error()}
  def cancel_transition(tenant, ref, opts \\ []) do
    Transitions.cancel(tenant, ref, Keyword.get(opts, :detail, %{}))
  end

  @doc """
  What a transition would change, without writing anything.

  A pure read: no lock, no transaction, no row. Safe to call from a LiveView
  render, and the dry run task 07.09 asks for.

  Returns `from` and `to` (each `%{plan_id, version, price, features,
  recurring_credits}`), a `changes` list, the `effective_at` the transition
  would carry, the tenant's current `period`, and a `provider` section.

  `price` is the plan's **declared list price** in cents and never an invoice
  amount: core computes no proration (decision D05). The `provider` section
  comes from the optional `c:AuroraMeter.Billing.Provider.describe_plan_change/3`
  callback and is `%{status: :not_configured, detail: %{}}` on a core-only
  installation, `%{status: :error, detail: %{reason: ...}}` for a provider that
  errors or raises, and the provider's own map otherwise. The entitlement diff
  is returned either way, because that half is core's and is right whatever the
  provider says.

  Each change carries a `direction` of `:increase`, `:decrease`, `:added`,
  `:removed` or `:changed`.

  ## Examples

      {:ok, preview} = AuroraMeter.Subscriptions.preview_transition("org_1", :scale)
      preview.provider.status
      #=> :not_configured

  """
  @spec preview_transition(term(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def preview_transition(tenant, to_plan, opts \\ []) do
    Preview.build(tenant, to_plan, opts)
  end

  @doc """
  Records a billing provider's confirmation of `ref`, and applies it if due.

  **For a billing provider integration.** Aurora Meter Pro calls this after the
  retrieved provider subscription shows the new price; a host scheduling local
  plan changes never needs it.

  Options: `:provider_ref` (**required**), `:effective_at` (the provider's own
  boundary, which wins over the scheduled one because the provider is
  authoritative for the paid boundary, with the replaced instant recorded in
  `detail.provider_effective_at_changed`) and `:detail`.

  Idempotent under redelivery: the same `provider_ref` on an already applied
  transition returns it unchanged, and a different one is
  `{:error, {:conflict, %{provider_ref: stored}}}`.

  ## Examples

      AuroraMeter.Subscriptions.confirm_transition("org_1", "upgrade-8412",
        provider_ref: "sub_123")

  """
  @spec confirm_transition(term(), String.t(), keyword()) ::
          {:ok, PlanTransition.t()} | {:error, error()}
  def confirm_transition(tenant, ref, opts \\ []) do
    Transitions.confirm(tenant, ref, opts)
  end

  @doc """
  Applies every transition whose effective time has arrived.

  Call it from any scheduler, or from `iex`. It opens one transaction per
  tenant, not one for the batch: a batch-wide transaction would hold hundreds
  of row locks for the length of the run and one poisoned row would discard the
  others' work.

  Options: `:limit` (default 500), `:after` (the `cursor` from a previous call),
  `:tenant` (force one tenant) and `:now` (the instant to treat as now; defaults
  to the **database's** clock, because the instants it is compared against are
  stored in the database).

  Running it twice, from two nodes, at any interleaving, is safe: each effect is
  an update predicated on `transition_state = 'pending'` and the transition's
  reference, so exactly one caller applies and the rest count a skip
  (invariant I16).

  A transition whose target version resolves through neither compiled code nor a
  registered snapshot is counted `failed` and is never retried automatically: an
  automatic retry of a target that does not exist loops forever. An operator
  cancels it and schedules a new one.

  ## Examples

      AuroraMeter.Subscriptions.apply_due_transitions(limit: 100)
      #=> {:ok, %{applied: 1, skipped: 0, failed: 0, cursor: :done}}

  """
  @spec apply_due_transitions(keyword()) :: {:ok, applied()}
  def apply_due_transitions(opts \\ []), do: Transitions.apply_due(opts)
end
