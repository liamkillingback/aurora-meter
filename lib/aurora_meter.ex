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
