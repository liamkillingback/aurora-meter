defmodule AuroraMeter.Subscriptions.Transitions do
  @moduledoc false

  # The plan transition state machine (build unit 07b).
  #
  # `AuroraMeter.Subscriptions` is the documented facade; everything that takes
  # a lock, writes a row or decides a precedence question lives here.
  #
  # ## Three rules this module is built on
  #
  # **Every effect is a conditional update.** Not one is predicated on "I read
  # this a moment ago": each `UPDATE` carries `transition_ref = $ref AND
  # transition_state = 'pending'` (or the audit row's `state = 'pending'`) in
  # its `WHERE`, so a second writer affects zero rows and is told so rather than
  # overwriting the first writer's work. That is what makes two nodes, an Oban
  # retry and a duplicated cron tick all safe (invariant I16).
  #
  # **Every instant compared against a stored one comes from the database.**
  # `AuroraMeter.Clock.db_now/0` for a reading and `clock_timestamp()` in the
  # statement for a stamp, so a node whose clock is minutes out can neither
  # apply a transition early nor refuse one that is due (`architecture-map.md`
  # section 3, finding X288). Ordering never takes a clock at all: the due scan
  # is a keyset over `(scheduled_effective_at, tenant_key)`, which is a filter
  # plus a cursor on one index and not a sort by time.
  #
  # **Nothing is announced before commit.** Every write returns its effects as
  # data; the facade invalidates the cache, emits telemetry and broadcasts once
  # the transaction has returned. A cache invalidated inside the transaction
  # publishes a state a rollback then erases, and every node that reloaded in
  # that window would cache the old row again for a full TTL.

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.PlanTransition
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  # The only place the database's own clock is named, so a grep for it finds
  # every stamp this unit writes.
  @db_now "clock_timestamp() AT TIME ZONE 'UTC'"

  @empty %{applied: 0, skipped: 0, failed: 0}

  @default_limit 500
  @max_ref_bytes 128

  @typedoc "One post-commit announcement: the row that moved and how."
  @type effect :: {PlanTransition.t(), atom()}

  @typedoc "A write's outcome before its effects have been announced."
  @type outcome ::
          {:ok, PlanTransition.t(), [effect()]}
          | {:idempotent, PlanTransition.t(), [effect()]}
          | {:error, {atom(), term()}}

  @typedoc """
  What `schedule/3`, `cancel/3` and `confirm/3` return, **after** `transact/1`
  has announced the effects and dropped them.

  It is deliberately not `t:outcome/0`, which is the shape the inner functions
  hand to `transact/1` and whose success arms are three-tuples. Spec'ing these
  three as `outcome()` said they return a three-tuple on success, and
  `AuroraMeter.Subscriptions`' own specs say two. Dialyzer intersects the two
  and concludes the success arm is impossible, so **every caller that matches
  `{:ok, _}` on `schedule_transition/3`, `cancel_transition/3` or
  `confirm_transition/3` is a `pattern_match` error**. Nothing in this package's
  `lib/` matches on one, which is why the core's own dialyzer was green and
  Aurora Meter Pro's was not (`open-findings.md` X304).
  """
  @type result :: {:ok, PlanTransition.t()} | {:error, {atom(), term()}}

  # -- schedule ---------------------------------------------------------------

  @doc false
  @spec schedule(term(), atom() | String.t(), keyword()) :: result()
  def schedule(tenant, to_plan, opts) do
    key = Tenant.to_key(tenant)

    with {:ok, ref} <- validate_ref(opts[:ref]),
         {:ok, confirm} <- validate_confirm(Keyword.get(opts, :confirm, :local)) do
      params = %{
        ref: ref,
        confirm: confirm,
        version: opts[:version],
        effective_at: opts[:effective_at],
        replace: Keyword.get(opts, :replace, true),
        detail: Keyword.get(opts, :detail, %{})
      }

      transact(fn -> do_schedule(tenant, key, to_plan, params) end)
    end
  end

  defp do_schedule(tenant, key, to_plan, params) do
    with {:ok, subscription} <- locked(key, :registration),
         {:ok, target} <- resolve_target(tenant, subscription, to_plan, params),
         {:ok, replaced} <- check_existing(key, params, target) do
      insert_transition(subscription, params, target, replaced)
    end
  end

  # The rolling-upgrade guard, narrowed to the row it is about.
  #
  # `schema-migration-map.md` section 4 asks that a fleet still carrying 0.4.0
  # nodes not schedule transitions, and 07b's build document proposed an
  # `EXISTS (... WHERE plan_version IS NULL)` over the whole table for it. That
  # is a sequential scan with no index to serve it, and it makes every schedule
  # depend on a row some unrelated tenant happens to have. The condition that
  # actually makes a transition unsafe is *this* tenant's row having no named
  # contract, and it is free under a lock already held. The fleet-wide half
  # stays what `schema-migration-map.md` calls it: documented, in
  # `docs/plans.md`.
  defp locked(key, guard) do
    case repo().one(from(s in Subscription, where: s.tenant_key == ^key, lock: "FOR UPDATE")) do
      nil ->
        {:error, {:not_found, :subscription}}

      %Subscription{plan_version: nil} when guard == :registration ->
        {:error, {:unavailable, :registration_incomplete}}

      subscription ->
        {:ok, subscription}
    end
  end

  defp resolve_target(tenant, subscription, to_plan, params) do
    with {:ok, plan_id} <- validate_plan_id(to_plan),
         {:ok, effective_at} <- resolve_effective_at(tenant, params[:effective_at]),
         {:ok, plan} <- resolve_plan(plan_id, params[:version], effective_at),
         :ok <- refuse_current(subscription, plan) do
      {:ok, %{plan: plan, effective_at: effective_at}}
    end
  end

  # "What period is it now" is a wall-clock question, so the default takes
  # `Clock.now/0`; the answer is a boundary the period source computed, a month
  # (or a subscription period) away, which is many orders of magnitude larger
  # than any clock error this programme has measured.
  defp resolve_effective_at(tenant, nil) do
    {:ok, truncate(Period.current!(tenant, Clock.now()).end)}
  end

  # "Is this instant still in the future" is asked about a value that is about
  # to be persisted and will be compared against the database's clock by every
  # later run, so it is asked of the database's clock now.
  defp resolve_effective_at(_tenant, %DateTime{time_zone: "Etc/UTC"} = at) do
    at = truncate(at)

    if DateTime.compare(at, Clock.db_now()) == :gt do
      {:ok, at}
    else
      {:error, {:invalid, [effective_at: "must be in the future"]}}
    end
  end

  defp resolve_effective_at(_tenant, _other) do
    {:error, {:invalid, [effective_at: "must be a UTC DateTime"]}}
  end

  defp resolve_plan(plan_id, version, effective_at) do
    case {Plans.versions(plan_id), version} do
      {[], _any} -> {:error, {:invalid, [to_plan: "is not a known plan"]}}
      {versions, nil} -> effective_version(versions, effective_at)
      {_versions, named} -> named_version(plan_id, named)
    end
  end

  # The version in force at the transition's effective time, which is what makes
  # "schedule the upgrade for the first of next month" select a version that
  # becomes effective on the first of next month, and refuse one that becomes
  # effective later.
  defp effective_version(versions, effective_at) do
    versions
    |> Enum.filter(fn plan ->
      is_nil(plan.effective_at) or DateTime.compare(plan.effective_at, effective_at) != :gt
    end)
    |> List.last()
    |> case do
      nil -> {:error, {:invalid, [to_plan: "has no version effective at that time"]}}
      plan -> {:ok, plan}
    end
  end

  defp named_version(plan_id, version) when is_binary(version) do
    case Plans.get(plan_id, version) do
      nil -> {:error, {:invalid, [to_plan_version: "is not a known version of this plan"]}}
      plan -> {:ok, plan}
    end
  end

  defp named_version(_plan_id, _version) do
    {:error, {:invalid, [to_plan_version: "must be a string"]}}
  end

  defp refuse_current(%Subscription{plan_id: id, plan_version: version}, plan) do
    if to_string(plan.id) == id and plan.version == version do
      {:error, {:invalid, [to_plan: "is the current plan and version"]}}
    else
      :ok
    end
  end

  defp check_existing(key, params, target) do
    case load(key, params.ref) do
      nil -> check_pending(key, params)
      transition -> compare_existing(transition, params, target)
    end
  end

  # L17.7: a reference is immutable. The same one with the same parameters is
  # the caller's retry; with different parameters it is a different intention
  # wearing the same name, and both sides are named in the error.
  defp compare_existing(transition, params, target) do
    submitted = canonical(params, target)

    if canonical(transition) == submitted do
      {:idempotent, transition, []}
    else
      {:error,
       {:conflict, %{ref: params.ref, stored: canonical(transition), submitted: submitted}}}
    end
  end

  defp check_pending(key, params) do
    case pending(key) do
      nil -> {:ok, []}
      %PlanTransition{ref: ref} when ref == params.ref -> {:ok, []}
      %PlanTransition{} = other -> replace_or_refuse(other, params)
    end
  end

  defp replace_or_refuse(%PlanTransition{} = other, %{replace: true} = params) do
    detail = %{"reason" => "replaced", "replaced_by" => params.ref}

    case cancel_rows(other.tenant_key, other.ref, detail) do
      {:ok, cancelled} -> {:ok, [{cancelled, :replaced}]}
      :already_settled -> {:ok, []}
    end
  end

  defp replace_or_refuse(%PlanTransition{ref: ref}, _params) do
    {:error, {:conflict, %{pending_ref: ref}}}
  end

  defp insert_transition(subscription, params, target, replaced) do
    attrs = %{
      tenant_key: subscription.tenant_key,
      ref: params.ref,
      from_plan_id: subscription.plan_id,
      from_version: subscription.plan_version,
      to_plan_id: to_string(target.plan.id),
      to_version: target.plan.version,
      effective_at: target.effective_at,
      state: "pending",
      confirm: Atom.to_string(params.confirm),
      detail: stringify(params.detail)
    }

    case repo().insert(PlanTransition.changeset(%PlanTransition{}, attrs)) do
      {:ok, transition} -> mirror(transition, replaced)
      {:error, changeset} -> {:error, {:invalid, changeset_errors(changeset)}}
    end
  end

  # The queryable mirror on the subscription row. Its predicate refuses to
  # overwrite somebody else's pending reference, which the row lock already
  # makes impossible; zero rows therefore means something nobody understands has
  # happened, and the transaction rolls back rather than leaving an audit row
  # with no mirror.
  defp mirror(%PlanTransition{} = transition, replaced) do
    query =
      from(s in Subscription,
        where:
          s.tenant_key == ^transition.tenant_key and
            (is_nil(s.transition_state) or s.transition_state != "pending" or
               s.transition_ref == ^transition.ref),
        update: [
          set: [
            scheduled_plan_id: ^transition.to_plan_id,
            scheduled_plan_version: ^transition.to_version,
            scheduled_effective_at: ^transition.effective_at,
            transition_ref: ^transition.ref,
            transition_state: "pending",
            transition_confirm: ^transition.confirm,
            transition_applied_at: nil,
            updated_at: fragment(@db_now)
          ]
        ]
      )

    case repo().update_all(query, []) do
      {1, _} -> {:ok, transition, replaced ++ [{transition, :scheduled}]}
      {0, _} -> {:error, {:conflict, :concurrent_schedule}}
    end
  end

  # -- cancel -----------------------------------------------------------------

  @doc false
  @spec cancel(term(), String.t(), map()) :: result()
  def cancel(tenant, ref, detail \\ %{}) do
    key = Tenant.to_key(tenant)

    transact(fn ->
      with {:ok, _subscription} <- locked(key, :none) do
        do_cancel(key, ref, detail)
      end
    end)
  end

  defp do_cancel(key, ref, detail) do
    case load(key, ref) do
      nil -> {:error, {:not_found, :transition}}
      %PlanTransition{state: "cancelled"} = t -> {:idempotent, t, []}
      %PlanTransition{state: "pending"} -> cancelled(key, ref, detail)
      %PlanTransition{state: state} -> {:error, {:conflict, %{state: state}}}
    end
  end

  defp cancelled(key, ref, detail) do
    merged = Map.merge(%{"reason" => "cancelled"}, stringify(detail))

    case cancel_rows(key, ref, merged) do
      {:ok, transition} -> {:ok, transition, [{transition, :cancelled}]}
      :already_settled -> {:error, {:conflict, %{state: "applied"}}}
    end
  end

  # The one place a transition becomes `cancelled`, used by the explicit cancel,
  # by `replace: true` and by both provider precedence rules, so the audit row
  # and the mirror can never disagree about how it ended.
  #
  # The `scheduled_*` columns are deliberately left in place: the due scan
  # filters on `transition_state = 'pending'`, so they are inert, and they keep
  # the row readable for an operator asking what was cancelled.
  defp cancel_rows(key, ref, detail) do
    query =
      from(t in PlanTransition,
        where: t.tenant_key == ^key and t.ref == ^ref and t.state == "pending",
        update: [set: [state: "cancelled", detail: ^detail, updated_at: fragment(@db_now)]],
        select: t
      )

    case repo().update_all(query, []) do
      {1, [transition]} ->
        clear_mirror(key, ref, "cancelled")
        {:ok, transition}

      {0, _} ->
        :already_settled
    end
  end

  defp clear_mirror(key, ref, state) do
    repo().update_all(
      from(s in Subscription,
        where:
          s.tenant_key == ^key and s.transition_ref == ^ref and s.transition_state == "pending",
        update: [set: [transition_state: ^state, updated_at: fragment(@db_now)]]
      ),
      []
    )
  end

  # -- confirm ----------------------------------------------------------------

  @doc false
  @spec confirm(term(), String.t(), keyword()) :: result()
  def confirm(tenant, ref, opts) do
    key = Tenant.to_key(tenant)

    with {:ok, provider_ref} <- validate_provider_ref(opts[:provider_ref]) do
      now = Keyword.get(opts, :now) || Clock.db_now()
      transact(fn -> locked_confirm(key, ref, provider_ref, opts, now) end)
    end
  end

  defp locked_confirm(key, ref, provider_ref, opts, now) do
    with {:ok, _subscription} <- locked(key, :none) do
      do_confirm(key, ref, provider_ref, opts, now)
    end
  end

  defp do_confirm(key, ref, provider_ref, opts, now) do
    case load(key, ref) do
      nil -> {:error, {:not_found, :transition}}
      %PlanTransition{state: "pending"} = t -> record_provider(t, provider_ref, opts, now)
      %PlanTransition{provider_ref: ^provider_ref} = t -> {:idempotent, t, []}
      %PlanTransition{provider_ref: stored} -> {:error, {:conflict, %{provider_ref: stored}}}
    end
  end

  defp record_provider(%PlanTransition{} = transition, provider_ref, opts, now) do
    effective_at = provider_effective_at(transition, opts[:effective_at])
    detail = confirm_detail(transition, effective_at, opts)

    query =
      from(t in PlanTransition,
        where: t.id == ^transition.id and t.state == "pending",
        update: [
          set: [
            provider_ref: ^provider_ref,
            effective_at: ^effective_at,
            detail: ^detail,
            updated_at: fragment(@db_now)
          ]
        ],
        select: t
      )

    {1, [confirmed]} = repo().update_all(query, [])
    sync_scheduled_at(confirmed)
    apply_if_due(confirmed, now)
  end

  defp provider_effective_at(%PlanTransition{effective_at: stored}, nil), do: stored
  defp provider_effective_at(_transition, %DateTime{} = supplied), do: truncate(supplied)

  # Stripe is authoritative for the paid boundary (task 07.05), so a provider
  # supplied instant wins, and the instant it replaced is kept in the audit
  # row's detail rather than being lost.
  defp confirm_detail(%PlanTransition{} = transition, effective_at, opts) do
    base = Map.merge(transition.detail || %{}, stringify(Keyword.get(opts, :detail, %{})))

    if DateTime.compare(transition.effective_at, effective_at) == :eq do
      base
    else
      Map.put(base, "provider_effective_at_changed", DateTime.to_iso8601(transition.effective_at))
    end
  end

  defp sync_scheduled_at(%PlanTransition{} = transition) do
    repo().update_all(
      from(s in Subscription,
        where:
          s.tenant_key == ^transition.tenant_key and s.transition_ref == ^transition.ref and
            s.transition_state == "pending",
        update: [
          set: [scheduled_effective_at: ^transition.effective_at, updated_at: fragment(@db_now)]
        ]
      ),
      []
    )
  end

  defp apply_if_due(%PlanTransition{} = transition, now) do
    if DateTime.compare(transition.effective_at, now) == :gt do
      {:ok, transition, [{transition, :confirmed}]}
    else
      confirm_applied(transition, now)
    end
  end

  defp confirm_applied(%PlanTransition{} = transition, now) do
    case apply_locked(transition.tenant_key, now) do
      {:applied, applied} -> {:ok, applied, [{applied, :applied}]}
      _other -> {:ok, transition, [{transition, :confirmed}]}
    end
  end

  # -- apply ------------------------------------------------------------------

  @doc false
  @spec apply_due(keyword()) :: {:ok, map()}
  def apply_due(opts) do
    now = Keyword.get(opts, :now) || Clock.db_now()

    case Keyword.get(opts, :tenant) do
      nil -> apply_batch(now, opts)
      tenant -> {:ok, Map.put(apply_tenant(Tenant.to_key(tenant), now), :cursor, :done)}
    end
  end

  defp apply_batch(now, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    {rows, next} = due_page(now, limit, Keyword.get(opts, :after))

    counts =
      Enum.reduce(rows, @empty, fn row, acc -> merge(acc, apply_tenant(row.tenant_key, now)) end)

    {:ok, Map.put(counts, :cursor, next || :done)}
  end

  defp due_page(now, limit, cursor) do
    Storage.list_subscriptions(cursor,
      limit: limit,
      transition_state: "pending",
      scheduled_before: now,
      order: :scheduled_effective_at
    )
  end

  defp apply_tenant(key, now) do
    key
    |> transact_apply(now)
    |> count()
  end

  defp transact_apply(key, now) do
    repo().transaction(fn -> apply_locked(key, now) end)
  end

  # Everything below runs inside one transaction with the subscription row
  # locked, so the `transition_state` it reads is the one the conditional update
  # a few lines later tests against. Twelve callers therefore serialise on the
  # row: one applies and eleven observe `applied` and count a skip, which is the
  # contended branch the concurrency evidence counts.
  defp apply_locked(key, now) do
    case repo().one(from(s in Subscription, where: s.tenant_key == ^key, lock: "FOR UPDATE")) do
      nil -> :nothing
      %Subscription{transition_ref: nil} -> :nothing
      subscription -> apply_transition(subscription, now)
    end
  end

  defp apply_transition(%Subscription{} = subscription, now) do
    case load(subscription.tenant_key, subscription.transition_ref) do
      %PlanTransition{state: "pending"} = transition -> apply_pending(transition, now)
      _settled -> :skipped
    end
  end

  defp apply_pending(%PlanTransition{} = transition, now) do
    cond do
      DateTime.compare(transition.effective_at, now) == :gt -> :skipped
      transition.confirm == "provider" and is_nil(transition.provider_ref) -> :skipped
      true -> resolve_and_apply(transition)
    end
  end

  defp resolve_and_apply(%PlanTransition{} = transition) do
    case target_plan(transition) do
      nil -> {:failed, fail(transition)}
      plan -> commit_apply(transition, plan)
    end
  end

  # `plan_effective_at` is the transition's effective time and never the apply
  # time: the commercial boundary is when the change took effect, not when a
  # worker noticed, and 07c's attribution walks exactly this column.
  defp commit_apply(%PlanTransition{} = transition, plan) do
    query =
      from(s in Subscription,
        where:
          s.tenant_key == ^transition.tenant_key and s.transition_ref == ^transition.ref and
            s.transition_state == "pending",
        update: [
          set: [
            plan_id: ^transition.to_plan_id,
            plan_version: ^transition.to_version,
            plan_fingerprint: ^plan.fingerprint,
            plan_effective_at: ^transition.effective_at,
            transition_state: "applied",
            transition_applied_at: fragment(@db_now),
            updated_at: fragment(@db_now)
          ]
        ]
      )

    case repo().update_all(query, []) do
      {0, _} -> :skipped
      {1, _} -> {:applied, mark_applied(transition)}
    end
  end

  defp mark_applied(%PlanTransition{} = transition) do
    {1, [applied]} =
      repo().update_all(
        from(t in PlanTransition,
          where: t.id == ^transition.id and t.state == "pending",
          update: [
            set: [state: "applied", applied_at: fragment(@db_now), updated_at: fragment(@db_now)]
          ],
          select: t
        ),
        []
      )

    applied
  end

  # A terminal failure, and only a deterministic one: the target version
  # resolves through neither compiled code nor a registered snapshot, so the
  # next run would decide exactly the same thing. A transient database error
  # never reaches here; it rolls the transaction back and leaves the row
  # `pending` for the next run.
  defp fail(%PlanTransition{} = transition) do
    detail =
      Map.merge(transition.detail || %{}, %{
        "error" => "target version not found",
        "to_plan_id" => transition.to_plan_id,
        "to_version" => transition.to_version
      })

    {1, [failed]} =
      repo().update_all(
        from(t in PlanTransition,
          where: t.id == ^transition.id and t.state == "pending",
          update: [set: [state: "failed", detail: ^detail, updated_at: fragment(@db_now)]],
          select: t
        ),
        []
      )

    clear_mirror(transition.tenant_key, transition.ref, "failed")
    failed
  end

  defp count({:ok, {:applied, transition}}) do
    announce(transition, :applied)
    %{@empty | applied: 1}
  end

  defp count({:ok, {:failed, transition}}) do
    announce(transition, :failed)
    %{@empty | failed: 1}
  end

  defp count({:ok, :skipped}), do: %{@empty | skipped: 1}
  defp count({:ok, :nothing}), do: @empty
  defp count({:error, _reason}), do: %{@empty | skipped: 1}

  defp merge(acc, counts) do
    %{
      applied: acc.applied + counts.applied,
      skipped: acc.skipped + counts.skipped,
      failed: acc.failed + counts.failed
    }
  end

  # -- the provider precedence path -------------------------------------------

  @doc false
  @spec provider_write(Subscription.t(), (-> {:ok, Subscription.t()} | {:error, term()})) ::
          {:ok, Subscription.t()} | {:error, term()}
  def provider_write(%Subscription{} = previous, fun) do
    outcome =
      repo().transaction(fn ->
        case fun.() do
          {:ok, written} -> react(previous, written)
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case outcome do
      {:ok, {subscription, effects}} -> announce_all(subscription, effects)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec catch_up(Subscription.t() | nil, {:ok, Subscription.t()} | {:error, term()}) ::
          {:ok, Subscription.t()} | {:error, term()}
  # The window the pre-read cannot close on its own: a transition scheduled
  # between that read and the upsert. The upsert returns the row's *current*
  # transition columns (they are outside the replace list), so `pending` here
  # means the schedule landed inside the window, and the reaction runs in its
  # own transaction rather than being skipped. Rare, self-healing, and it costs
  # an ordinary sync nothing, because an ordinary sync has no pending
  # transition and never reaches this clause.
  def catch_up(%Subscription{} = previous, {:ok, %Subscription{transition_state: "pending"}}) do
    provider_write(previous, fn -> {:ok, Storage.get_subscription(previous.tenant_key)} end)
  end

  def catch_up(_previous, result), do: result

  defp react(%Subscription{} = previous, %Subscription{} = written) do
    locked =
      repo().one(
        from(s in Subscription, where: s.tenant_key == ^written.tenant_key, lock: "FOR UPDATE")
      )

    case locked do
      %Subscription{transition_state: "pending"} = current -> decide(previous, written, current)
      _settled -> {written, []}
    end
  end

  # The precedence rules core can observe, in the order they are tested.
  #
  # The status test comes first and the build document numbers it last. A
  # provider write that both moves the plan to the scheduled target and ends the
  # subscription must not apply the transition: a tenant who is no longer
  # entitled has no plan to move to, and applying it would leave the row naming
  # a contract nobody is paying for.
  defp decide(previous, written, current) do
    cond do
      not Subscription.entitled?(written) ->
        settle(written, current, "subscription_not_entitled", %{"status" => written.status})

      scheduled_target?(written, current) ->
        apply_early(written, current)

      plan_changed?(previous, written) ->
        settle(written, current, "provider_override", observed(written))

      true ->
        {written, []}
    end
  end

  # Strict pair equality, deliberately. A provider that names a plan id without
  # naming a version has said nothing about which contract it means, and
  # inventing one on its behalf would move the tenant onto a version nobody
  # asked for. See finding X296 and 07c, which sends the pair.
  defp scheduled_target?(%Subscription{} = written, %Subscription{} = current) do
    written.plan_id == current.scheduled_plan_id and
      written.plan_version == current.scheduled_plan_version
  end

  defp plan_changed?(%Subscription{} = previous, %Subscription{} = written) do
    {previous.plan_id, previous.plan_version} != {written.plan_id, written.plan_version}
  end

  defp observed(%Subscription{} = written) do
    %{"observed" => %{"plan_id" => written.plan_id, "plan_version" => written.plan_version}}
  end

  defp settle(written, current, reason, extra) do
    detail = Map.merge(%{"reason" => reason}, extra)

    case cancel_rows(written.tenant_key, current.transition_ref, detail) do
      {:ok, transition} -> {reread(written.tenant_key), [{transition, :cancelled}]}
      :already_settled -> {written, []}
    end
  end

  # The provider moved the tenant to exactly what was scheduled, before the
  # applier reached the boundary. Applying rather than cancelling keeps one
  # audit row for one commercial change, which is what 07c's attribution reads.
  defp apply_early(written, current) do
    case load(written.tenant_key, current.transition_ref) do
      %PlanTransition{state: "pending"} = transition -> early(written, transition)
      _settled -> {written, []}
    end
  end

  defp early(written, %PlanTransition{} = transition) do
    detail = Map.put(transition.detail || %{}, "reason", "provider_applied_early")
    fingerprint = fingerprint_of(transition)

    {1, [applied]} =
      repo().update_all(
        from(t in PlanTransition,
          where: t.id == ^transition.id and t.state == "pending",
          update: [
            set: [
              state: "applied",
              applied_at: fragment(@db_now),
              detail: ^detail,
              updated_at: fragment(@db_now)
            ]
          ],
          select: t
        ),
        []
      )

    mark_mirror_applied(written.tenant_key, transition, fingerprint)
    {reread(written.tenant_key), [{applied, :applied}]}
  end

  # The provider wrote the plan id and version; it did not write the
  # fingerprint, because a billing provider has no opinion about a definition
  # hash. Leaving the previous plan's fingerprint on the row would make the
  # subscription name one contract and carry another one's hash, so the early
  # apply supplies it from the version it has just landed on.
  defp fingerprint_of(%PlanTransition{} = transition) do
    case target_plan(transition) do
      nil -> nil
      plan -> plan.fingerprint
    end
  end

  defp mark_mirror_applied(key, %PlanTransition{} = transition, fingerprint) do
    repo().update_all(
      from(s in Subscription,
        where:
          s.tenant_key == ^key and s.transition_ref == ^transition.ref and
            s.transition_state == "pending",
        update: [
          set: [
            plan_fingerprint: ^fingerprint,
            plan_effective_at: ^transition.effective_at,
            transition_state: "applied",
            transition_applied_at: fragment(@db_now),
            updated_at: fragment(@db_now)
          ]
        ]
      ),
      []
    )
  end

  defp reread(key), do: repo().one(from(s in Subscription, where: s.tenant_key == ^key))

  defp announce_all(subscription, effects) do
    Enum.each(effects, fn {transition, result} -> announce(transition, result) end)
    {:ok, subscription}
  end

  # -- reads ------------------------------------------------------------------

  @doc false
  @spec load(String.t(), String.t() | nil) :: PlanTransition.t() | nil
  def load(key, ref) when is_binary(ref) do
    repo().one(from(t in PlanTransition, where: t.tenant_key == ^key and t.ref == ^ref))
  end

  def load(_key, _ref), do: nil

  @doc false
  @spec pending(String.t()) :: PlanTransition.t() | nil
  def pending(key) do
    repo().one(
      from(t in PlanTransition, where: t.tenant_key == ^key and t.state == "pending", limit: 1)
    )
  end

  @doc false
  @spec target_plan(PlanTransition.t()) :: AuroraMeter.Plan.t() | nil
  def target_plan(%PlanTransition{to_plan_id: id, to_version: version}) do
    case plan_atom(id) do
      nil -> nil
      atom -> Plans.get(atom, version)
    end
  end

  @doc false
  @spec plan_atom(String.t()) :: atom() | nil
  def plan_atom(id) when is_binary(id) do
    String.to_existing_atom(id)
  rescue
    ArgumentError -> nil
  end

  # -- announcements ----------------------------------------------------------

  @doc false
  @spec announce(PlanTransition.t(), atom()) :: PlanTransition.t()
  def announce(%PlanTransition{} = transition, result) do
    if result != :idempotent do
      Subscriptions.invalidate(transition.tenant_key)
      broadcast(transition)
    end

    # The event name at the call site, which is a readability choice and no
    # longer a requirement. It was written out longhand because the inventory
    # guard matched a literal and an attribute hid the name from it
    # (`open-findings.md` X222); 08a's census resolves attributes, so this is
    # now simply where a name used once is clearest.
    :telemetry.execute(
      [:aurora_meter, :plans, :transition],
      %{count: 1},
      metadata(transition, result)
    )

    transition
  end

  defp broadcast(%PlanTransition{} = transition) do
    PubSub.broadcast(
      Config.pubsub(),
      Broadcaster.topic(transition.tenant_key),
      {:aurora_meter, :plan_transition,
       %{
         tenant_key: transition.tenant_key,
         ref: transition.ref,
         state: String.to_existing_atom(transition.state)
       }}
    )
  end

  defp metadata(%PlanTransition{} = transition, result) do
    %{
      tenant_key: transition.tenant_key,
      ref: transition.ref,
      from_plan_id: transition.from_plan_id,
      from_version: transition.from_version,
      to_plan_id: transition.to_plan_id,
      to_version: transition.to_version,
      result: result
    }
  end

  # -- plumbing ---------------------------------------------------------------

  # `{:idempotent, value, effects}` is a success the caller must not treat as a
  # change: nothing moved, so the cache is not invalidated and nothing is
  # broadcast. It still emits telemetry, because the number of callers that
  # found the work already done is exactly what a concurrency test counts.
  defp transact(fun) do
    case repo().transaction(fn -> unwrap(fun.()) end) do
      {:ok, {:ok, value, effects}} -> announced({:ok, value}, effects)
      {:ok, {:idempotent, value, effects}} -> announced({:ok, value}, effects ++ idem(value))
      {:error, reason} -> {:error, reason}
    end
  end

  defp idem(%PlanTransition{} = transition), do: [{transition, :idempotent}]

  defp announced(result, effects) do
    Enum.each(effects, fn {transition, outcome} -> announce(transition, outcome) end)
    result
  end

  defp unwrap({:ok, value, effects}), do: {:ok, value, effects}
  defp unwrap({:idempotent, value, effects}), do: {:idempotent, value, effects}
  defp unwrap({:error, reason}), do: repo().rollback(reason)

  defp validate_ref(ref) when is_binary(ref) do
    if byte_size(ref) in 1..@max_ref_bytes do
      {:ok, ref}
    else
      {:error, {:invalid, [ref: "must be between 1 and #{@max_ref_bytes} bytes"]}}
    end
  end

  defp validate_ref(_ref), do: {:error, {:invalid, [ref: "is required"]}}

  defp validate_confirm(confirm) when confirm in [:local, :provider], do: {:ok, confirm}

  defp validate_confirm(_confirm),
    do: {:error, {:invalid, [confirm: "must be :local or :provider"]}}

  defp validate_provider_ref(ref) when is_binary(ref) and byte_size(ref) > 0, do: {:ok, ref}
  defp validate_provider_ref(_ref), do: {:error, {:invalid, [provider_ref: "is required"]}}

  defp validate_plan_id(id) when is_atom(id) and not is_nil(id), do: {:ok, id}

  defp validate_plan_id(id) when is_binary(id) do
    case plan_atom(id) do
      nil -> {:error, {:invalid, [to_plan: "is not a known plan"]}}
      atom -> {:ok, atom}
    end
  end

  defp validate_plan_id(_id), do: {:error, {:invalid, [to_plan: "is not a known plan"]}}

  defp canonical(%PlanTransition{} = transition) do
    %{
      to_plan_id: transition.to_plan_id,
      to_version: transition.to_version,
      effective_at: transition.effective_at,
      confirm: transition.confirm
    }
  end

  defp canonical(params, target) do
    %{
      to_plan_id: to_string(target.plan.id),
      to_version: target.plan.version,
      effective_at: target.effective_at,
      confirm: Atom.to_string(params.confirm)
    }
  end

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp repo, do: Config.repo()
end
