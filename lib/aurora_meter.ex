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

  ## Tenants: the first argument everywhere

  Every function takes a tenant first (`org` in the examples). It is whatever
  identifies the customer being metered: the organisation or account that owns
  the subscription, not the individual user. Strings, integers and atoms work
  as they are (`"org_42"`, `42`, `:acme`); to pass your own struct, configure a
  module that implements `AuroraMeter.Tenant`:

      defmodule MyApp.Tenant do
        @behaviour AuroraMeter.Tenant
        def to_key(%MyApp.Accounts.Org{id: id}), do: "org_\#{id}"
        def to_key(key) when is_binary(key), do: key
      end

      config :aurora_meter, tenant: MyApp.Tenant

  The resolved key must be stable and unique per customer: it is the key for the
  ETS counters, the persisted counter rows and the PubSub topics. Subscribe a
  plan (`subscribe/2`) with the same term you meter with.

  The public API: `track/4`, `usage/2`, `usage_all/1`, `history/3` (metering);
  `check/2`, `allowed?/2`, `entitled?/2`, `remaining/2`, `quota/2`,
  `feature_value/3`, `reserve/3`, `with_quota/4` (entitlements);
  `subscribe/2`, `plan/1`, `period/1` (plans).

  Prepaid balances live in `AuroraMeter.Credits`: `grant/3`, `hold/4`,
  `settle/3`, `release/1`, `debit/4` and `with_credits/4` keep a per-tenant
  ledger in micro-dollars, next to (not instead of) the plan counters above.
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

  `tenant` is any term that identifies the customer (a string, an id, or your
  own struct via a configured `AuroraMeter.Tenant`); see the module docs.

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

  @doc """
  Returns `tenant`'s daily usage of `feature` as a list of
  `%{date: Date.t(), value: integer()}` points, one per UTC day, oldest first.

  Options: `:days` (default 30, ending today), or explicit `:from` / `:to`
  dates. Days with no usage are present with a value of `0`. Requires
  `:history` (on by default) and schema version 2.

      AuroraMeter.history(org, :ai_generations, days: 7)
      #=> [%{date: ~D[2026-09-01], value: 12}, ..., %{date: ~D[2026-09-07], value: 3}]
  """
  @spec history(term(), atom(), keyword()) :: [Storage.history_point()]
  def history(tenant, feature, opts \\ []) do
    tenant_key = Tenant.to_key(tenant)
    to = Keyword.get(opts, :to, Date.utc_today())
    days = Keyword.get(opts, :days, 30)
    from = Keyword.get(opts, :from, Date.add(to, -(days - 1)))

    stored =
      tenant_key
      |> Storage.load_history_range(feature, from, to)
      |> Map.new(&{&1.date, &1.value})

    live = Counter.warm_day_values(tenant_key, feature)

    for date <- Date.range(from, to) do
      %{date: date, value: Map.get(live, date) || Map.get(stored, date, 0)}
    end
  end

  @doc "Returns the current billing period for `tenant` (`%{start:, end:, source:}`)."
  @spec period(term()) :: Period.t()
  def period(tenant), do: Period.current(tenant)

  @doc "Assigns `plan_id` to `tenant` locally. See `AuroraMeter.Entitlements.subscribe/2`."
  @spec subscribe(term(), atom() | String.t()) ::
          {:ok, AuroraMeter.Schema.Subscription.t()} | {:error, Ecto.Changeset.t()}
  defdelegate subscribe(tenant, plan_id), to: AuroraMeter.Entitlements

  @doc "Returns `tenant`'s current plan. See `AuroraMeter.Entitlements.plan/1`."
  @spec plan(term()) :: AuroraMeter.Plan.t() | nil
  defdelegate plan(tenant), to: AuroraMeter.Entitlements

  @doc """
  Checks whether `tenant` may use `feature`. See `AuroraMeter.Entitlements.check/2`.

  Advisory: this reads the counter and compares, so two concurrent callers can
  both see `:ok` at the cap. To enforce a hard limit atomically use
  `reserve/3` or `with_quota/4`.
  """
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

  @doc """
  The value of a `feature :name, value` declaration on `tenant`'s plan
  (a boolean or a non-negative integer), or `default` when the plan does not
  carry one. See `AuroraMeter.Entitlements.feature_value/3`.

      AuroraMeter.feature_value(org, :seats, 1)   # => 5
  """
  @spec feature_value(term(), atom(), default) :: boolean() | non_neg_integer() | default
        when default: term()
  defdelegate feature_value(tenant, feature, default \\ nil), to: AuroraMeter.Entitlements

  @doc "A dashboard-ready quota snapshot. See `AuroraMeter.Entitlements.quota/2`."
  @spec quota(term(), atom()) :: AuroraMeter.Entitlements.quota()
  defdelegate quota(tenant, feature), to: AuroraMeter.Entitlements

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
