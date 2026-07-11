defmodule AuroraMeter.Entitlements do
  @moduledoc """
  Plan resolution and the entitlement gate.

  Semantics (see plan.md D12): a `:hard` limit blocks at its cap; a `:metered`
  feature is always allowed (overage is billed); a `{:feature, false}` is denied;
  an undeclared feature is permissive. `with_quota/4` reserves atomically so hard
  limits are correct under concurrency, releasing the reservation if the wrapped
  function raises.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Period
  alias AuroraMeter.Plans
  alias AuroraMeter.Storage
  alias AuroraMeter.Tenant

  @typedoc "Result of an entitlement check."
  @type check_result :: :ok | {:error, :limit_exceeded | :not_entitled}

  @doc "Assigns `plan_id` to `tenant` locally (no billing provider)."
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, AuroraMeter.Schema.Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(tenant, plan_id) do
    Storage.put_subscription(%{
      tenant_key: Tenant.to_key(tenant),
      plan_id: to_string(plan_id),
      status: "active"
    })
  end

  @doc "Returns the plan for `tenant` (its subscription's plan, else the default)."
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  def plan(tenant) do
    case Storage.get_subscription(Tenant.to_key(tenant)) do
      nil ->
        Plans.get(Config.default_plan())

      subscription ->
        Plans.get(plan_atom(subscription.plan_id)) || Plans.get(Config.default_plan())
    end
  end

  @doc "Checks whether `tenant` may use `feature` right now."
  @spec check(term(), atom()) :: check_result()
  def check(tenant, feature) do
    case feature_config(tenant, feature) do
      {:feature, false} ->
        {:error, :not_entitled}

      {:feature, true} ->
        :ok

      {:limit, n, :hard} ->
        if usage(tenant, feature) >= n, do: {:error, :limit_exceeded}, else: :ok

      {:metered, _included, _unit_price} ->
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

  @doc "Remaining quota for a hard-limited feature, or `:unlimited`."
  @spec remaining(term(), atom()) :: non_neg_integer() | :unlimited
  def remaining(tenant, feature) do
    case feature_config(tenant, feature) do
      {:limit, n, :hard} -> max(0, n - usage(tenant, feature))
      _other -> :unlimited
    end
  end

  @doc "Atomically reserves `qty` of `feature` against the plan (increments the counter)."
  @spec reserve(term(), atom(), pos_integer()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  def reserve(tenant, feature, qty \\ 1) do
    case feature_config(tenant, feature) do
      {:feature, false} ->
        {:error, :not_entitled}

      {:limit, n, :hard} ->
        Counter.reserve(Tenant.to_key(tenant), feature, qty, period_start(tenant), n)

      _other ->
        Counter.reserve(Tenant.to_key(tenant), feature, qty, period_start(tenant), nil)
    end
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
