defmodule AuroraMeter.Entitlements do
  @moduledoc """
  Plan resolution and the entitlement gate.

  Semantics (see plan.md D12 and ADR 0010): a `:hard` limit blocks at its cap; a
  `:metered` feature is always allowed (overage is billed); a `:counter` is
  always allowed and never billed (ADR 0006); a `{:feature, false}` is denied.
  `with_quota/4` reserves atomically so hard limits are correct under
  concurrency, releasing the reservation if the wrapped function raises.

  ## Features the plan does not declare

  A feature the tenant's **effective plan** does not declare follows
  `:undeclared_feature_policy` (`AuroraMeter.Config.policy_for/1`). A feature
  another plan declares counts as undeclared here: that is the case the policy
  exists for.

  | Entry point | `:allow` | `:warn` | `:deny` | `:raise` |
  |---|---|---|---|---|
  | `check/2` | `:ok` | `:ok` plus one log | `{:error, :not_entitled}` | raises |
  | `allowed?/2`, `entitled?/2` | `true` | `true` plus one log | `false` | raises |
  | `feature_value/3` | `default` | `default` plus one log | `default` | raises |
  | `quota/2` | `kind: :undeclared, enabled: true` | same plus one log | `kind: :undeclared, enabled: false` | raises |
  | `remaining/2` | `:unlimited` | `:unlimited` plus one log | `0` | raises |
  | `reserve/2,3` | counts, `:ok` | counts, `:ok`, one log | `{:error, :not_entitled}`, counter untouched | raises, counter untouched |
  | `with_quota/3,4` | runs the function | runs it, one log | `{:error, :not_entitled}`, not run | raises, not run |

  Every entry point keeps its documented return shape under every policy; only
  the value inside it changes. `:warn` behaves exactly as `:allow` and logs once
  per feature per node. `AuroraMeter.track/4` is deliberately outside all of
  this and keeps counting: metering is not entitlement.

  The default is `:warn` in the 0.5.x transition release and `:deny` from 1.0;
  `config :aurora_meter, undeclared_feature_policy: :allow` restores the 0.4.x
  behaviour exactly.

  Plans resolve through `AuroraMeter.Subscriptions` (cached), and only a
  subscription in an entitled status (`AuroraMeter.Schema.Subscription.entitled_statuses/0`)
  grants its plan; anything else gets the default plan.
  """

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.Counter
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Tenant
  alias AuroraMeter.UndeclaredFeatureError

  @typedoc "Result of an entitlement check."
  @type check_result :: :ok | {:error, :limit_exceeded | :not_entitled}

  @typedoc """
  A dashboard-ready view of one feature's quota. `kind` is `:hard`, `:metered`,
  `:counter`, `:boolean`, `:feature` (an integer plan value, carried in `value`)
  or `:undeclared`; `limit` is set for hard caps, `included` for metered
  allowances; `percent` is used relative to whichever applies (nil when neither
  does, which includes every `:counter`; see ADR 0006).
  """
  @type quota :: %{
          feature: atom(),
          kind: :hard | :metered | :counter | :boolean | :feature | :undeclared,
          enabled: boolean(),
          value: non_neg_integer() | nil,
          used: integer(),
          limit: non_neg_integer() | nil,
          included: non_neg_integer() | nil,
          unit_price: number() | nil,
          remaining: non_neg_integer() | :unlimited,
          overage: non_neg_integer(),
          percent: non_neg_integer() | nil,
          period: Period.t()
        }

  # What a feature resolved to on the tenant's plan.
  @typep resolution :: {:ok, AuroraMeter.Plan.feature_config()} | :undeclared

  @doc """
  Assigns `plan_id` to `tenant` locally (no billing provider).

  The plan has to exist. A plan id no plans module declares used to be written
  and then silently resolved to the default plan for the life of the install; in
  the transition release it is written with a warning, and from 1.0 it is
  `{:error, changeset}` with `plan_id: ["is not a known plan"]`.
  """
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(tenant, plan_id), do: subscribe(tenant, plan_id, [])

  @doc """
  Assigns a specific version of `plan_id` to `tenant`.

  Options:

    * `:version`: the plan version to pin. Without it the tenant gets the
      version effective at `AuroraMeter.Clock.now/0`, which is what "new
      subscriptions select the intended effective version" means. With it, the
      named version is pinned even when it is not yet effective: an explicit
      opt-in is not the same thing as a future-dated version becoming active
      early, because the caller asked for it.
    * `:mode`: undocumented, for the suite, so both halves of the transition
      can be exercised without depending on the package's own version.

  A version the plan does not have, in code or in the registry, is
  `{:error, changeset}` with `plan_version: ["is not a known version of this plan"]`.

  The row records the version, its fingerprint and the instant the assignment
  started, so a later deploy of a new version cannot change what this tenant was
  sold (D05).
  """
  @spec subscribe(term(), atom() | String.t(), keyword() | :strict | :transition) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(tenant, plan_id, opts) when is_list(opts) do
    mode = Keyword.get(opts, :mode, ConfigSchema.mode())
    version = Keyword.get(opts, :version)

    attrs = %{
      tenant_key: Tenant.to_key(tenant),
      plan_id: to_string(plan_id),
      status: "active"
    }

    cond do
      known_plan?(plan_id) ->
        subscribe_known(attrs, plan_id, version)

      # An explicit version of a plan that does not exist is refused in both
      # modes: the transition-era leniency is about a plan id an older install
      # has been writing for years, and nobody has been writing a version.
      version != nil or mode == :strict ->
        {:error, unknown_plan_changeset(attrs)}

      true ->
        warn_unknown_plan(plan_id)
        Storage.put_subscription(attrs)
    end
  end

  # The 0.4.x arity-3 form took the mode positionally. Kept so a host that
  # copied it, and the suite's own transition tests, keep working.
  def subscribe(tenant, plan_id, mode) when mode in [:strict, :transition],
    do: subscribe(tenant, plan_id, mode: mode)

  defp subscribe_known(attrs, plan_id, version) do
    id = plan_atom(to_string(plan_id))

    case resolve_version(id, version) do
      {:ok, plan} ->
        Storage.put_subscription(
          Map.merge(attrs, %{
            plan_version: plan.version,
            plan_fingerprint: plan.fingerprint,
            # **Stamped by the database, not by this node** (finding X288,
            # closed by build unit 07b). `:db_now` tells
            # `AuroraMeter.Storage.put_subscription/1` to set the column from
            # `clock_timestamp()` rather than from a value computed here: from
            # 07b this instant is compared against the database's clock, and
            # comparing a node's stamp against the database's is the defect
            # `architecture-map.md` section 3 names. The value is never read
            # into Elixir at all, so no future caller has to remember to use
            # the right clock.
            plan_effective_at: :db_now
          })
        )

      :error ->
        {:error, unknown_version_changeset(attrs, version)}
    end
  end

  defp resolve_version(id, nil) do
    case Plans.get(id) do
      nil -> :error
      plan -> {:ok, plan}
    end
  end

  defp resolve_version(id, version) when is_binary(version) do
    case Plans.get(id, version) do
      nil -> :error
      plan -> {:ok, plan}
    end
  end

  defp resolve_version(_id, _version), do: :error

  @doc """
  Returns the plan for `tenant`: the **version its subscription is pinned to**
  when the subscription is in an entitled status, else the default plan.

  The pin is what makes a plan deploy safe. A tenant on `:pro` version `"1"`
  keeps version 1's limits, feature values, price and recurring credits when
  version 2 becomes effective, and keeps them when version 1's block is deleted
  from the plans module, because the definition is resolved from the registered
  snapshot (`v1-release.md` 07.03, invariant I17).

  A row with no `plan_version` at all (written before core schema version 10 and
  not yet named by `AuroraMeter.Plans.register!/0`) resolves to the plan's
  **base** version, never to whatever is current: the migration and the
  registration are not simultaneous, and a tenant must not be repriced in the
  window between them.
  """
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  def plan(tenant) do
    default = Plans.get(Config.default_plan())

    case Subscriptions.get(tenant) do
      %Subscription{} = subscription ->
        # One copy of the entitled-status rule, on the schema that owns it.
        if Subscription.entitled?(subscription),
          do: pinned_plan(subscription) || default,
          else: default

      _none ->
        default
    end
  end

  defp pinned_plan(%Subscription{plan_id: plan_id, plan_version: version}) do
    case plan_atom(plan_id) do
      nil -> nil
      id -> pinned_plan(id, version)
    end
  end

  defp pinned_plan(id, nil), do: Plans.base(id)

  defp pinned_plan(id, version) do
    case Plans.get(id, version) do
      nil ->
        warn_unknown_version(id, version)
        nil

      plan ->
        plan
    end
  end

  @doc "Checks whether `tenant` may use `feature` right now."
  @spec check(term(), atom()) :: check_result()
  def check(tenant, feature) do
    case resolve(tenant, feature) do
      {:ok, config} ->
        check_declared(tenant, feature, config)

      :undeclared ->
        case undeclared(tenant, feature, :check) do
          :allow -> :ok
          :deny -> {:error, :not_entitled}
        end
    end
  end

  @doc "Whether `check/2` currently returns `:ok`."
  @spec allowed?(term(), atom()) :: boolean()
  def allowed?(tenant, feature) do
    case resolve(tenant, feature) do
      {:ok, config} -> check_declared(tenant, feature, config) == :ok
      :undeclared -> undeclared(tenant, feature, :allowed?) == :allow
    end
  end

  @doc "Whether the tenant's plan grants access to `feature` at all (ignores quota)."
  @spec entitled?(term(), atom()) :: boolean()
  def entitled?(tenant, feature) do
    case resolve(tenant, feature) do
      {:ok, {:feature, false}} -> false
      {:ok, _other} -> true
      :undeclared -> undeclared(tenant, feature, :entitled?) == :allow
    end
  end

  @doc """
  The value of a `feature :name, value` declaration on `tenant`'s plan, or
  `default` when the plan does not declare it (or declares it as a limit or a
  metered feature). Booleans and non-negative integers are both values:

      AuroraMeter.feature_value(org, :seats, 1)       # 5 on :pro, 1 on :free
      AuroraMeter.feature_value(org, :api_access)     # true | false | nil

  `default` is also what an undeclared feature yields under `:allow`, `:warn`
  and `:deny`; under `:raise` it raises `AuroraMeter.UndeclaredFeatureError`.
  """
  @spec feature_value(term(), atom(), default) :: boolean() | non_neg_integer() | default
        when default: term()
  def feature_value(tenant, feature, default \\ nil) do
    case resolve(tenant, feature) do
      {:ok, {:feature, value}} ->
        value

      {:ok, _other} ->
        default

      :undeclared ->
        # The policy still applies (the `:warn` log, the `:raise`), but `default`
        # is what an undeclared feature already yielded, so `:deny` changes
        # nothing here.
        _decision = undeclared(tenant, feature, :feature_value)
        default
    end
  end

  @doc """
  Remaining quota for a hard-limited feature, or `:unlimited`, which is what a
  metered feature, a counter and a plain feature all report, because none of
  them has a cap to count down from.

  An undeclared feature reports `:unlimited` under `:allow` and `:warn`, and
  `0` under `:deny`: the documented return type is `non_neg_integer() |
  :unlimited`, and `0` is the honest number when nothing is entitled.
  """
  @spec remaining(term(), atom()) :: non_neg_integer() | :unlimited
  def remaining(tenant, feature) do
    case resolve(tenant, feature) do
      {:ok, {:limit, n, :hard}} ->
        max(0, n - usage(tenant, feature))

      {:ok, _other} ->
        :unlimited

      :undeclared ->
        case undeclared(tenant, feature, :remaining) do
          :allow -> :unlimited
          :deny -> 0
        end
    end
  end

  @doc """
  A dashboard-ready snapshot of `feature` for `tenant`: kind, usage, cap or
  allowance, remaining, overage, percentage and the current period.
  """
  @spec quota(term(), atom()) :: quota()
  def quota(tenant, feature) do
    case resolve(tenant, feature) do
      {:ok, config} ->
        declared_quota(tenant, feature, config)

      :undeclared ->
        # The key set never changes: only `enabled` moves, so a renderer written
        # against `quota()` keeps working under every policy.
        enabled = undeclared(tenant, feature, :quota) == :allow
        %{base_quota(tenant, feature) | enabled: enabled}
    end
  end

  @doc """
  Atomically reserves `qty` of `feature` against the plan (increments the
  counter).

  `period_start` names the period to count it against; without it the current
  one is used. A caller that will release the reservation later has to hold on
  to the period it reserved in; see `with_quota/4`.

  Raises `ArgumentError` for a feature configured
  `feature_sources: %{name => :events}`. This is the bill-immediately primitive:
  it writes the quantity straight into the pending flush, so it would put
  reserved units into `aurora_meter_counters` for a feature whose commercial
  quantity is its recorded events. Use `with_quota/4`, whose reservation stays
  in memory, or `check/2` to ask without reserving.
  """
  @spec reserve(term(), atom(), pos_integer(), DateTime.t() | nil) ::
          :ok | {:error, :limit_exceeded | :not_entitled}
  def reserve(tenant, feature, qty \\ 1, period_start \\ nil) do
    buffered_source!(feature)
    do_reserve(tenant, feature, qty, period_start, false, :reserve)
  end

  # I08, the second half of the `track/4` guard in `AuroraMeter`. The public
  # `reserve` takes the non-deferred path, which reaches `Counter.reserve/6`
  # with `deferred: false`, which calls `bump/2`, which writes `pending_flush`
  # and marks the key dirty. That is the flush path, and for an events-source
  # feature it is the double count.
  #
  # `with_quota/4` is deliberately NOT guarded: its reservation is deferred, and
  # `Counter.reserve_pending/2` writes only `value` and `reserved`, neither of
  # which the flusher can see.
  @spec buffered_source!(term()) :: :ok
  defp buffered_source!(feature) do
    if Config.feature_source(feature) == :events do
      raise ArgumentError,
            "#{inspect(feature)} is an events-source feature; AuroraMeter.reserve/2,3 " <>
              "bills what it reserves immediately, which would count it a second time " <>
              "alongside the events recorded for it. Use AuroraMeter.with_quota/4, whose " <>
              "reservation never leaves memory, or AuroraMeter.check/2 to ask without " <>
              "reserving."
    end

    :ok
  end

  # `entry_point` is `:reserve` or `:with_quota`: it reaches the log and the
  # exception only, and names the function the caller actually called.
  defp do_reserve(tenant, feature, qty, period_start, deferred, entry_point) do
    tenant_key = Tenant.to_key(tenant)
    period = period_start || period_start(tenant)

    # The policy branch sits in front of the reservation, so a denial never
    # reaches `Counter.reserve/6` and the arithmetic I04 measures is untouched
    # (ADR 0010).
    {result, declared} =
      case resolve(tenant, feature) do
        {:ok, config} ->
          {reserve_declared(tenant_key, feature, qty, period, deferred, config), true}

        :undeclared ->
          case undeclared(tenant, feature, entry_point) do
            :allow -> {Counter.reserve(tenant_key, feature, qty, period, nil, deferred), false}
            :deny -> {{:error, :not_entitled}, false}
          end
      end

    :telemetry.execute([:aurora_meter, :reserve], %{qty: qty}, %{
      tenant_key: tenant_key,
      feature: feature,
      result: result_tag(result),
      declared: declared
    })

    result
  end

  @doc """
  Gates, runs, and meters in one atomic step.

  Reserves `qty` of `feature`; if allowed, runs `fun` and returns `{:ok, result}`
  (the reservation is the usage). If the reservation is denied, returns
  `{:error, reason}` without running `fun`. If `fun` raises, the reservation is
  released and the error re-raised.

  ## Over an events-source feature

  For a feature configured `feature_sources: %{name => :events}` the gate still
  works and the reservation is still strict on this node, but the reservation is
  **released** on success instead of being committed. It is admission control
  and nothing else: the billable fact is whatever `AuroraMeter.record/4`
  committed, and committing the reservation as well would charge the estimate on
  top of the recorded quantity.

  The recipe, and the arithmetic it produces, is to record inside the callback:

      AuroraMeter.with_quota(org, :tokens, estimate, fn ->
        {:ok, result} = do_work()
        {:ok, _event, _outcome} =
          AuroraMeter.record(org, :tokens, result.tokens,
            id: result.request_id, occurred_at: result.finished_at)
        result
      end)

  `+estimate` at admission, `+result.tokens` from the projection, `-estimate` at
  release: the in-memory value nets to the durable total, and while the callback
  runs every other caller sees the estimate held. Unlike a buffered feature,
  nothing here can reach a flush batch.
  """
  @spec with_quota(term(), atom(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, fun) when is_function(fun, 0),
    do: with_quota(tenant, feature, 1, fun)

  @spec with_quota(term(), atom(), pos_integer(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, qty, fun) when is_function(fun, 0) do
    # Capture the period once, and reserve *and* release against that one.
    # Recomputing it meant that work spanning a period boundary — a
    # long-running call started at 23:59:59 on the last of the month —
    # released the reservation from the new period's counter, leaving the old
    # one permanently over-counted and the new one under. Passing it only to
    # the release left the same asymmetry one call deeper, because `reserve/3`
    # asked `Period.current/1` again on its own way in.
    period_start = period_start(tenant)
    on = Clock.today()

    # Read once, beside the period and the day, and for the same reason. A
    # source read after the callback could differ from the one the reservation
    # was taken under, and the two halves of one call would then be settled by
    # different rules: exactly the double count `:feature_sources` exists to
    # prevent, arriving through the mechanism meant to prevent it.
    source = Config.feature_source(feature)

    case do_reserve(tenant, feature, qty, period_start, true, :with_quota) do
      :ok ->
        # `catch`, not just `rescue`: an exit is the common failure in gated
        # work — a `GenServer.call`, a `Task.await`, a database checkout all
        # time out by exiting rather than raising — and it unwound straight
        # past a `rescue`, leaving the reservation counted for good. The two
        # siblings in this codebase were both taught this already
        # (`Credits.run_held/2`, `Flusher.flush_batch/3`).
        result =
          try do
            fun.()
          catch
            kind, reason ->
              Counter.release_work(Tenant.to_key(tenant), feature, qty, period_start)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        settle(source, Tenant.to_key(tenant), feature, qty, period_start, on)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What a successful callback does with its reservation, and the only thing
  # this unit changed about `with_quota/4`.
  #
  # A buffered feature commits: the reservation becomes pending flush, pending
  # gossip and a day bucket, which is what makes it billable, and this clause is
  # the same call with the same arguments it has always been.
  #
  # An events-source feature releases, which is identical to the failure path.
  # Committing would write `pending_flush` for a quantity that is already
  # committed as an event, and the flusher would put it in
  # `aurora_meter_counters` on top of the event total (I08). The reservation
  # gated the work; the recorded event is the charge.
  @spec settle(:buffered | :events, String.t(), atom(), pos_integer(), DateTime.t(), Date.t()) ::
          :ok
  defp settle(:events, tenant_key, feature, qty, period_start, _on),
    do: Counter.release_work(tenant_key, feature, qty, period_start)

  defp settle(:buffered, tenant_key, feature, qty, period_start, on),
    do: Counter.commit_work(tenant_key, feature, qty, period_start, on)

  @doc false
  # The one seam every non-entitlement caller applies the policy through.
  # `AuroraMeter.record/4` needs the same decision the entitlement functions
  # take, including the `:raise` branch and the once-per-node warning, and a
  # second copy of that logic is how two paths end up disagreeing about what
  # "undeclared" means.
  @spec feature_policy(term(), atom(), atom()) :: :allow | :deny
  def feature_policy(tenant, feature, entry_point) do
    case resolve(tenant, feature) do
      {:ok, _config} -> :allow
      :undeclared -> undeclared(tenant, feature, entry_point)
    end
  end

  @spec resolve(term(), atom()) :: resolution()
  defp resolve(tenant, feature) do
    with %AuroraMeter.Plan{} = plan <- plan(tenant),
         {:ok, config} <- Map.fetch(plan.features, feature) do
      {:ok, config}
    else
      _undeclared -> :undeclared
    end
  end

  # Applies `:undeclared_feature_policy` and returns the branch the caller takes.
  # `entry_point` is for the log, the exception and telemetry only.
  @spec undeclared(term(), atom(), atom()) :: :allow | :deny
  defp undeclared(tenant, feature, entry_point) do
    case Config.policy_for(feature) do
      :allow ->
        :allow

      :warn ->
        warn_undeclared(feature, entry_point)
        :allow

      :deny ->
        :deny

      :raise ->
        raise UndeclaredFeatureError,
          feature: feature,
          tenant_key: Tenant.to_key(tenant),
          plan_id: plan_id(tenant),
          entry_point: entry_point,
          reason: undeclared_reason(feature)
    end
  end

  # Once per feature per node, in every Mix environment the library was compiled
  # in. The previous warning sat behind `if Mix.env() == :dev`, and that is the
  # environment the *host* compiled the dependency in, so a release build warned
  # about nothing at all (open findings C2 and C16).
  @spec warn_undeclared(atom(), atom()) :: :ok
  defp warn_undeclared(feature, entry_point) do
    ConfigSchema.warn_once(:undeclared_feature, feature, fn ->
      "AuroraMeter: feature #{inspect(feature)} is not declared on the tenant's plan " <>
        "(first seen from #{entry_point}). :undeclared_feature_policy is :warn, so it " <>
        "is allowed; Aurora Meter 1.0 denies it. Declare it on the plan, run " <>
        "`mix aurora_meter.features` to find every other one, or set " <>
        "`config :aurora_meter, undeclared_feature_policy: :allow`."
    end)
  end

  @spec undeclared_reason(atom()) :: :not_in_plan | :unknown_feature
  defp undeclared_reason(feature) do
    if Plans.declared_anywhere?(feature), do: :not_in_plan, else: :unknown_feature
  end

  @spec plan_id(term()) :: atom() | nil
  defp plan_id(tenant) do
    case plan(tenant) do
      %AuroraMeter.Plan{id: id} -> id
      nil -> nil
    end
  end

  @spec check_declared(term(), atom(), AuroraMeter.Plan.feature_config()) :: check_result()
  defp check_declared(tenant, feature, config) do
    case config do
      {:feature, false} ->
        {:error, :not_entitled}

      {:feature, _true_or_integer} ->
        :ok

      {:limit, n, :hard} ->
        if usage(tenant, feature) >= n, do: {:error, :limit_exceeded}, else: :ok

      {:metered, _included, _unit_price} ->
        :ok

      {:counter} ->
        :ok
    end
  end

  @spec reserve_declared(
          String.t(),
          atom(),
          pos_integer(),
          DateTime.t(),
          boolean(),
          AuroraMeter.Plan.feature_config()
        ) :: :ok | {:error, :limit_exceeded | :not_entitled}
  defp reserve_declared(tenant_key, feature, qty, period, deferred, config) do
    case config do
      {:feature, false} ->
        {:error, :not_entitled}

      {:limit, n, :hard} ->
        Counter.reserve(tenant_key, feature, qty, period, n, deferred)

      {:counter} ->
        # Explicit rather than falling through: a counter must keep counting
        # (no cap argument) and must never be turned into a gate later.
        Counter.reserve(tenant_key, feature, qty, period, nil, deferred)

      _other ->
        Counter.reserve(tenant_key, feature, qty, period, nil, deferred)
    end
  end

  @spec base_quota(term(), atom()) :: quota()
  defp base_quota(tenant, feature) do
    %{
      feature: feature,
      kind: :undeclared,
      enabled: true,
      value: nil,
      used: usage(tenant, feature),
      limit: nil,
      included: nil,
      unit_price: nil,
      remaining: :unlimited,
      overage: 0,
      percent: nil,
      period: Period.current!(tenant)
    }
  end

  @spec declared_quota(term(), atom(), AuroraMeter.Plan.feature_config()) :: quota()
  defp declared_quota(tenant, feature, config) do
    base = base_quota(tenant, feature)
    used = base.used

    case config do
      {:limit, n, :hard} ->
        %{
          base
          | kind: :hard,
            limit: n,
            included: n,
            remaining: max(0, n - used),
            percent: percent(used, n)
        }

      {:metered, included, unit_price} ->
        %{
          base
          | kind: :metered,
            included: included,
            unit_price: unit_price,
            overage: max(0, used - included),
            percent: percent(used, included)
        }

      {:counter} ->
        # ADR 0006: a counter has no denominator, so `limit`, `included` and
        # `percent` stay `nil` rather than collapsing to `0`. A renderer that
        # treats `percent: nil` as "no bar" is correct; one that treats it as
        # `0` would draw "0% of 0", which is the bug this kind exists to avoid.
        %{base | kind: :counter}

      {:feature, enabled} when is_boolean(enabled) ->
        %{base | kind: :boolean, enabled: enabled}

      {:feature, value} when is_integer(value) ->
        %{base | kind: :feature, value: value}
    end
  end

  @spec known_plan?(atom() | String.t()) :: boolean()
  defp known_plan?(plan_id) when is_atom(plan_id), do: plan_id in Plans.plan_ids()

  defp known_plan?(plan_id) when is_binary(plan_id) do
    case plan_atom(plan_id) do
      nil -> false
      atom -> atom in Plans.plan_ids()
    end
  end

  @spec unknown_plan_changeset(map()) :: Ecto.Changeset.t()
  defp unknown_plan_changeset(attrs) do
    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Ecto.Changeset.add_error(:plan_id, "is not a known plan")
    |> Map.put(:action, :insert)
  end

  @spec unknown_version_changeset(map(), String.t() | nil) :: Ecto.Changeset.t()
  defp unknown_version_changeset(attrs, version) do
    %Subscription{}
    |> Subscription.changeset(Map.put(attrs, :plan_version, version))
    |> Ecto.Changeset.add_error(:plan_version, "is not a known version of this plan")
    |> Map.put(:action, :insert)
  end

  # One line per `(plan_id, version)` per node. The tenant keeps paying and
  # resolves to the default plan, which is the old behaviour for an unreadable
  # plan, and the message says what would restore their entitlements.
  @spec warn_unknown_version(atom(), String.t()) :: :ok
  defp warn_unknown_version(id, version) do
    ConfigSchema.warn_once(:unknown_plan_version, "#{id}/#{version}", fn ->
      "AuroraMeter.Entitlements.plan/1: a subscription is pinned to plan #{inspect(id)} " <>
        "version #{inspect(version)}, which is in neither the compiled plans module nor " <>
        "aurora_meter_plan_versions, so the tenant resolves to the default plan. Restore the " <>
        "version's block, or register its snapshot, before the next billing run."
    end)
  end

  @spec warn_unknown_plan(atom() | String.t()) :: :ok
  defp warn_unknown_plan(plan_id) do
    ConfigSchema.warn_once(:unknown_plan, to_string(plan_id), fn ->
      "AuroraMeter.subscribe/2: #{inspect(plan_id)} is not declared by " <>
        "#{inspect(Config.plans())} (known: #{inspect(Enum.sort(Plans.plan_ids()))}). " <>
        "The subscription is written and the tenant resolves to the default plan; " <>
        "Aurora Meter 1.0 returns {:error, changeset} with plan_id: \"is not a known plan\"."
    end)
  end

  @spec usage(term(), atom()) :: integer()
  defp usage(tenant, feature),
    do: Counter.value(Tenant.to_key(tenant), feature, period_start(tenant))

  @spec period_start(term()) :: DateTime.t()
  defp period_start(tenant), do: Period.current!(tenant).start

  @spec percent(integer(), non_neg_integer()) :: non_neg_integer()
  defp percent(_used, 0), do: 0
  defp percent(used, total), do: max(0, min(100, div(used * 100, total)))

  @spec result_tag(:ok | {:error, atom()}) :: atom()
  defp result_tag(:ok), do: :ok
  defp result_tag({:error, reason}), do: reason

  @spec plan_atom(String.t()) :: atom() | nil
  defp plan_atom(plan_id) do
    String.to_existing_atom(plan_id)
  rescue
    ArgumentError -> nil
  end
end
