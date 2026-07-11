defmodule AuroraMeter do
  @moduledoc """
  Aurora Meter — real-time usage metering, plan entitlements, and Stripe-ready
  billing primitives for Phoenix.

  Count, gate, and bill on the BEAM: increments hit an in-memory ETS counter
  (microseconds, no database on the hot path), a flusher persists snapshots to
  Postgres on an interval, and a broadcaster fans live values out over
  `Phoenix.PubSub`.

  Add it to your host application's supervision tree — it validates configuration
  at boot and starts the metering runtime:

      children = [
        MyApp.Repo,
        {Phoenix.PubSub, name: MyApp.PubSub},
        AuroraMeter,
        MyAppWeb.Endpoint
      ]

  The public metering/entitlement API (`track/4`, `check/2`, `with_quota/4`,
  `usage/2`, `remaining/2`, `subscribe/2`) is added in later phases; see `plan.md`.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Period
  alias AuroraMeter.Storage
  alias AuroraMeter.Tenant

  @version Mix.Project.config()[:version]

  @doc """
  Returns the Aurora Meter version.

  ## Examples

      iex> is_binary(AuroraMeter.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Records `qty` usage of `feature` for `tenant` in the current period.

  Runs on the ETS hot path (no database round-trip) unless the feature is durable
  (`opts[:durable]` or configured in `:durable_features`), in which case a raw
  event row is also written. Options: `:durable` (boolean), `:metadata` (map).
  """
  @spec track(term(), atom(), integer(), keyword()) :: :ok
  def track(tenant, feature, qty \\ 1, opts \\ []) do
    tenant_key = Tenant.to_key(tenant)
    period_start = Period.current(tenant).start
    Counter.incr(tenant_key, feature, qty, period_start)
    maybe_write_event(tenant_key, feature, qty, opts)

    :telemetry.execute([:aurora_meter, :track], %{count: qty}, %{
      tenant_key: tenant_key,
      feature: feature
    })

    :ok
  end

  @doc "Returns `tenant`'s usage of `feature` in the current period."
  @spec usage(term(), atom()) :: integer()
  def usage(tenant, feature) do
    Counter.value(Tenant.to_key(tenant), feature, Period.current(tenant).start)
  end

  @doc "Returns a map of `feature => value` for `tenant`'s warm counters this period."
  @spec usage_all(term()) :: %{atom() => integer()}
  def usage_all(tenant) do
    Counter.all_for(Tenant.to_key(tenant), Period.current(tenant).start)
  end

  @doc "Assigns `plan_id` to `tenant` locally. See `AuroraMeter.Entitlements.subscribe/2`."
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, AuroraMeter.Schema.Subscription.t()} | {:error, Ecto.Changeset.t()}
  defdelegate subscribe(tenant, plan_id), to: AuroraMeter.Entitlements

  @doc "Returns `tenant`'s current plan. See `AuroraMeter.Entitlements.plan/1`."
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  defdelegate plan(tenant), to: AuroraMeter.Entitlements

  @doc "Checks whether `tenant` may use `feature`. See `AuroraMeter.Entitlements.check/2`."
  @spec check(term(), atom()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  defdelegate check(tenant, feature), to: AuroraMeter.Entitlements

  @doc "Whether `check/2` currently returns `:ok`."
  @spec allowed?(term(), atom()) :: boolean()
  defdelegate allowed?(tenant, feature), to: AuroraMeter.Entitlements

  @doc "Whether the plan grants access to `feature` (ignores quota)."
  @spec entitled?(term(), atom()) :: boolean()
  defdelegate entitled?(tenant, feature), to: AuroraMeter.Entitlements

  @doc "Remaining quota for a hard-limited feature, or `:unlimited`."
  @spec remaining(term(), atom()) :: non_neg_integer() | :unlimited
  defdelegate remaining(tenant, feature), to: AuroraMeter.Entitlements

  @doc "Atomically reserves usage against the plan. See `AuroraMeter.Entitlements.reserve/3`."
  @spec reserve(term(), atom()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  defdelegate reserve(tenant, feature), to: AuroraMeter.Entitlements

  @doc "Atomically reserves `qty` usage against the plan."
  @spec reserve(term(), atom(), pos_integer()) :: :ok | {:error, :limit_exceeded | :not_entitled}
  defdelegate reserve(tenant, feature, qty), to: AuroraMeter.Entitlements

  @doc "Gates, runs, and meters in one step. See `AuroraMeter.Entitlements.with_quota/4`."
  @spec with_quota(term(), atom(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  defdelegate with_quota(tenant, feature, fun), to: AuroraMeter.Entitlements

  @doc "Gates, runs, and meters `qty` in one step."
  @spec with_quota(term(), atom(), pos_integer(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  defdelegate with_quota(tenant, feature, qty, fun), to: AuroraMeter.Entitlements

  @spec maybe_write_event(String.t(), atom(), integer(), keyword()) :: :ok
  defp maybe_write_event(tenant_key, feature, qty, opts) do
    if durable?(feature, opts) do
      Storage.insert_events([
        %{
          tenant_key: tenant_key,
          feature: feature,
          quantity: qty,
          metadata: Map.new(Keyword.get(opts, :metadata, %{}))
        }
      ])
    end

    :ok
  end

  @spec durable?(atom(), keyword()) :: boolean()
  defp durable?(feature, opts) do
    Keyword.get(opts, :durable, false) or feature in Config.durable_features()
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Validates configuration and starts the Aurora Meter runtime supervisor.

  Raises `NimbleOptions.ValidationError` if the `:aurora_meter` configuration is
  missing a required key or has a value of the wrong type.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    AuroraMeter.Config.validate!()
    AuroraMeter.Supervisor.start_link(opts)
  end
end
