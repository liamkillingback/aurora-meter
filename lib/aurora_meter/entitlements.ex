defmodule AuroraMeter.Entitlements do
  @moduledoc """
  Plan resolution and the entitlement gate.

  Semantics (see plan.md D12): a `:hard` limit blocks at its cap; a `:metered`
  feature is always allowed (overage is billed); a `:counter` is always allowed
  and never billed (ADR 0006); a `{:feature, false}` is denied; an undeclared
  feature is permissive. `with_quota/4` reserves atomically so hard
  limits are correct under concurrency, releasing the reservation if the wrapped
  function raises.

  Plans resolve through `AuroraMeter.Subscriptions` (cached), and only a
  subscription in an entitled status (`AuroraMeter.Schema.Subscription.entitled_statuses/0`)
  grants its plan; anything else gets the default plan.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Subscriptions
  alias AuroraMeter.Tenant

  @typedoc "Result of an entitlement check."
  @type check_result :: :ok | {:error, :limit_exceeded | :not_entitled}

  @typedoc """
  A dashboard-ready view of one feature's quota. `kind` is `:hard`, `:metered`,
  `:counter`, `:boolean`, `:feature` (an integer plan value, carried in `value`)
  or `:undeclared`; `limit` is set for hard caps, `included` for metered
  allowances; `percent` is used relative to whichever applies (nil when neither
  does, which includes every `:counter` — see ADR 0006).
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

  @doc "Assigns `plan_id` to `tenant` locally (no billing provider)."
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(tenant, plan_id) do
    Storage.put_subscription(%{
      tenant_key: Tenant.to_key(tenant),
      plan_id: to_string(plan_id),
      status: "active"
    })
  end

  @doc """
  Returns the plan for `tenant`: its subscription's plan when the subscription is
  in an entitled status, else the default plan.
  """
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  def plan(tenant) do
    default = Plans.get(Config.default_plan())

    case Subscriptions.get(tenant) do
      %Subscription{status: status, plan_id: plan_id}
      when status in ~w(active trialing past_due) ->
        Plans.get(plan_atom(plan_id)) || default

      _none_or_inactive ->
        default
    end
  end

  @doc "Checks whether `tenant` may use `feature` right now."
  @spec check(term(), atom()) :: check_result()
  def check(tenant, feature) do
    case feature_config(tenant, feature) do
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

      nil ->
        warn_undeclared(feature)
        :ok
    end
  end

  @doc "Whether `check/2` currently returns `:ok`."
  @spec allowed?(term(), atom()) :: boolean()
  def allowed?(tenant, feature), do: check(tenant, feature) == :ok

  @doc "Whether the tenant's plan grants access to `feature` at all (ignores quota)."
  @spec entitled?(term(), atom()) :: boolean()
  def entitled?(tenant, feature) do
    case feature_config(tenant, feature) do
      {:feature, false} -> false
      _other -> true
    end
  end

  @doc """
  The value of a `feature :name, value` declaration on `tenant`'s plan, or
  `default` when the plan does not declare it (or declares it as a limit or a
  metered feature). Booleans and non-negative integers are both values:

      AuroraMeter.feature_value(org, :seats, 1)       # 5 on :pro, 1 on :free
      AuroraMeter.feature_value(org, :api_access)     # true | false | nil
  """
  @spec feature_value(term(), atom(), default) :: boolean() | non_neg_integer() | default
        when default: term()
  def feature_value(tenant, feature, default \\ nil) do
    case feature_config(tenant, feature) do
      {:feature, value} -> value
      _other -> default
    end
  end

  @doc """
  Remaining quota for a hard-limited feature, or `:unlimited` — which is what a
  metered feature, a counter, a plain feature and an undeclared feature all
  report, because none of them has a cap to count down from.
  """
  @spec remaining(term(), atom()) :: non_neg_integer() | :unlimited
  def remaining(tenant, feature) do
    case feature_config(tenant, feature) do
      {:limit, n, :hard} -> max(0, n - usage(tenant, feature))
      _other -> :unlimited
    end
  end

  @doc """
  A dashboard-ready snapshot of `feature` for `tenant`: kind, usage, cap or
  allowance, remaining, overage, percentage and the current period.
  """
  @spec quota(term(), atom()) :: quota()
  def quota(tenant, feature) do
    used = usage(tenant, feature)
    period = Period.current(tenant)

    base = %{
      feature: feature,
      kind: :undeclared,
      enabled: true,
      value: nil,
      used: used,
      limit: nil,
      included: nil,
      unit_price: nil,
      remaining: :unlimited,
      overage: 0,
      percent: nil,
      period: period
    }

    case feature_config(tenant, feature) do
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

      nil ->
        base
    end
  end

  @doc "Atomically reserves `qty` of `feature` against the plan (increments the counter)."
  @spec reserve(term(), atom(), pos_integer()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  def reserve(tenant, feature, qty \\ 1) do
    tenant_key = Tenant.to_key(tenant)

    result =
      case feature_config(tenant, feature) do
        {:feature, false} ->
          {:error, :not_entitled}

        {:limit, n, :hard} ->
          Counter.reserve(tenant_key, feature, qty, period_start(tenant), n)

        {:counter} ->
          # Explicit rather than falling through: a counter must keep counting
          # (no cap argument) and must never be turned into a gate later.
          Counter.reserve(tenant_key, feature, qty, period_start(tenant), nil)

        _other ->
          Counter.reserve(tenant_key, feature, qty, period_start(tenant), nil)
      end

    :telemetry.execute([:aurora_meter, :reserve], %{qty: qty}, %{
      tenant_key: tenant_key,
      feature: feature,
      result: result_tag(result)
    })

    result
  end

  @doc """
  Gates, runs, and meters in one atomic step.

  Reserves `qty` of `feature`; if allowed, runs `fun` and returns `{:ok, result}`
  (the reservation is the usage). If the reservation is denied, returns
  `{:error, reason}` without running `fun`. If `fun` raises, the reservation is
  released and the error re-raised.
  """
  @spec with_quota(term(), atom(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, fun) when is_function(fun, 0),
    do: with_quota(tenant, feature, 1, fun)

  @spec with_quota(term(), atom(), pos_integer(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_quota(tenant, feature, qty, fun) when is_function(fun, 0) do
    case reserve(tenant, feature, qty) do
      :ok ->
        try do
          {:ok, fun.()}
        rescue
          exception ->
            Counter.release(Tenant.to_key(tenant), feature, qty, period_start(tenant))
            reraise exception, __STACKTRACE__
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec feature_config(term(), atom()) :: AuroraMeter.Plan.feature_config() | nil
  defp feature_config(tenant, feature) do
    case plan(tenant) do
      nil -> nil
      plan -> Map.get(plan.features, feature)
    end
  end

  @spec usage(term(), atom()) :: integer()
  defp usage(tenant, feature),
    do: Counter.value(Tenant.to_key(tenant), feature, period_start(tenant))

  @spec period_start(term()) :: DateTime.t()
  defp period_start(tenant), do: Period.current(tenant).start

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

  # Compile-time switch: warn only in :dev builds, without a runtime dead branch.
  if Mix.env() == :dev do
    require Logger

    @spec warn_undeclared(atom()) :: :ok
    defp warn_undeclared(feature) do
      Logger.warning(
        "AuroraMeter: feature #{inspect(feature)} is not declared in the plan; allowing it (permissive)."
      )

      :ok
    end
  else
    @spec warn_undeclared(atom()) :: :ok
    defp warn_undeclared(_feature), do: :ok
  end
end
