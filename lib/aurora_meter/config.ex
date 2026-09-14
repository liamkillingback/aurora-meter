defmodule AuroraMeter.Config do
  @moduledoc """
  Reads and validates Aurora Meter configuration from the `:aurora_meter`
  application environment.

  Configuration is validated once at boot by `validate!/0` (called from
  `AuroraMeter.start_link/1`), which fails fast on a missing required key, a
  wrong type, or a module-typed key naming a module that does not implement its
  behaviour. Typed accessors below return the effective value; every default is
  written once, in the schema, and read back from it.

  `validate!/0` sees the **whole** application environment, so a misspelled key
  is reported rather than silently discarded. In this release it is a warning;
  in Aurora Meter 1.0 it stops the boot. See
  [Configuration](configuration.md) for the upgrade sequence.
  """

  require Logger

  alias AuroraMeter.Config.Schema

  @schema NimbleOptions.new!(
            repo: [type: :atom, required: true, doc: "The host Ecto repo."],
            pubsub: [type: :atom, required: true, doc: "The host `Phoenix.PubSub` server name."],
            plans: [type: :atom, required: true, doc: "A module that `use`s `AuroraMeter.Plans`."],
            tenant: [type: :atom, default: AuroraMeter.Tenant.Default],
            default_plan: [type: :atom, default: :free],
            storage: [type: :atom, default: AuroraMeter.Storage.Ecto],
            provider: [type: :atom, default: AuroraMeter.Billing.Noop],
            period_source: [type: :atom, default: AuroraMeter.Period.Calendar],
            clock: [
              type: :atom,
              default: AuroraMeter.Clock.System,
              doc:
                "A module implementing `AuroraMeter.Clock`. The only value supported in " <>
                  "production is `AuroraMeter.Clock.System`; tests install " <>
                  "`AuroraMeter.Clock.Fixed` through `AuroraMeter.Test.with_clock/2`."
            ],
            undeclared_feature_policy: [
              type: {:in, [:allow, :warn, :deny, :raise]},
              default: Schema.default_undeclared_feature_policy(),
              doc:
                "What the entitlement functions do with a feature the tenant's plan does not " <>
                  "declare: `:allow` (0.4.x behaviour), `:warn` (allow and log once per " <>
                  "feature per node), `:deny` or `:raise`. The default is `:warn` in the " <>
                  "0.5.x transition release and `:deny` from 1.0. `AuroraMeter.track/4` " <>
                  "counts an undeclared feature under every policy."
            ],
            durable_features: [type: {:list, :atom}, default: []],
            feature_sources: [
              type: {:map, :atom, {:in, [:buffered, :events]}},
              default: %{},
              doc:
                "Where each feature's commercial quantity comes from: `:buffered` (the ETS " <>
                  "counter and its flushed rows) or `:events` (durable events recorded with " <>
                  "`AuroraMeter.record/4`). Anything not listed is `:buffered`."
            ],
            events_outbox: [
              type: :atom,
              default: nil,
              doc:
                "A module implementing `AuroraMeter.Events.Outbox`, called inside the " <>
                  "transaction that records an event so an export intent commits with the " <>
                  "fact. `nil` means no export intent is staged."
            ],
            events_future_tolerance: [
              type: :non_neg_integer,
              default: 300,
              doc:
                "Seconds an `occurred_at` may run ahead of the node clock before " <>
                  "`AuroraMeter.record/4` refuses it."
            ],
            record_timeout: [
              type: :pos_integer,
              default: 15_000,
              doc:
                "Milliseconds one durable write may take, applied to the transaction and to " <>
                  "every statement in it. A database that stops answering produces " <>
                  "`{:error, {:unavailable, :timeout}}` rather than an exit."
            ],
            record_max_concurrency: [
              type: :pos_integer,
              default: 64,
              doc:
                "How many callers may hold an open record transaction at once. Beyond it " <>
                  "`AuroraMeter.record/4` returns `{:error, {:unavailable, :overloaded}}`; it " <>
                  "never falls back to buffered tracking."
            ],
            flush_interval: [type: :pos_integer, default: 5_000],
            broadcast_interval: [type: :pos_integer, default: 1_000],
            history: [
              type: :boolean,
              default: true,
              doc: "Maintain UTC day buckets for `AuroraMeter.history/3`."
            ],
            subscription_cache_ttl: [
              type: :non_neg_integer,
              default: 5_000,
              doc: "Milliseconds a subscription lookup is cached; 0 disables the cache."
            ],
            cluster_sync: [
              type: :boolean,
              default: true,
              doc:
                "Exchange counter deltas and flushed totals between nodes over PubSub " <>
                  "so every node converges on the cluster-wide value."
            ],
            credits_currency: [
              type: :string,
              default: "usd",
              doc: "ISO 4217 code stamped on new `AuroraMeter.Credits` balance rows."
            ],
            credits_overdraft_tolerance: [
              type: :non_neg_integer,
              default: 0,
              doc:
                "Micro-dollars a hold or debit may take the available balance below zero " <>
                  "before `:insufficient_credits`."
            ],
            credits_low_balance_threshold: [
              type: {:or, [:integer, nil]},
              default: nil,
              doc:
                "Micro-dollars; when the available balance drops below it the low-balance " <>
                  "event fires. A balance row's own threshold overrides it."
            ],
            credits_low_balance_handler: [
              type: {:or, [{:fun, 1}, nil]},
              default: nil,
              doc:
                "Called with `%{tenant_key, available, threshold}` after a low-balance " <>
                  "crossing commits (a place to email or to auto-recharge)."
            ]
          )

  # One place a default is written. An accessor for a key the schema does not
  # declare fails at its first call rather than inventing a value, and the
  # strictness suite fails when an accessor and the schema disagree.
  @defaults Schema.defaults(@schema)

  # NimbleOptions can only say "this is an atom". A module-typed key also has to
  # name a module that exists and exports the callbacks the library will call,
  # or the failure lands on a caller at runtime instead of at boot. The required
  # callbacks are read from each behaviour rather than restated here.
  #
  # There is deliberately no probe call with a synthetic tenant: a custom period
  # source may legitimately raise for an unknown tenant, so a probe would invent
  # a boot failure.
  @module_contracts [
    {:tenant, {:behaviour, AuroraMeter.Tenant}},
    {:storage, {:behaviour, AuroraMeter.Storage}},
    {:provider, {:behaviour, AuroraMeter.Billing.Provider}},
    {:period_source, {:behaviour, AuroraMeter.Period}},
    {:clock, {:behaviour, AuroraMeter.Clock}},
    {:plans, {:exports, [{:__aurora_plans__, 0}], "a module that `use`s `AuroraMeter.Plans`"}}
  ]

  @doc """
  Validates the current `:aurora_meter` configuration, raising on any problem.

  Returns the validated options (with defaults applied) on success.

  ## Examples

      iex> is_list(AuroraMeter.Config.validate!())
      true

  """
  @spec validate!() :: keyword()
  def validate!, do: validate!(Schema.mode())

  @doc false
  # The mode is a parameter so the strictness suite can exercise both halves of
  # every transition behaviour without depending on the package's own version.
  @spec validate!(Schema.mode()) :: keyword()
  def validate!(mode) do
    env = Application.get_all_env(:aurora_meter)

    :aurora_meter
    |> Schema.validate!(env, @schema, mode)
    |> check_modules!()
    |> check_outbox!()
    |> check_plans!(mode)
    |> check_deprecations!()
  end

  @doc """
  The undeclared-feature policy in force for `feature`.

  In V1 every feature gets the global `:undeclared_feature_policy`. It is a
  function rather than a key read so that the durable-event writers arriving in
  1.0 (record and correct) consult one seam, and so a per-feature map later is a
  change in one place.

  ## Examples

      iex> AuroraMeter.Config.policy_for(:ai_generations) in [:allow, :warn, :deny, :raise]
      true

  """
  @spec policy_for(atom()) :: :allow | :warn | :deny | :raise
  def policy_for(_feature), do: undeclared_feature_policy()

  @doc "The configured host Ecto repo."
  @spec repo() :: module()
  def repo, do: Application.fetch_env!(:aurora_meter, :repo)

  @doc "The configured host `Phoenix.PubSub` server name."
  @spec pubsub() :: atom()
  def pubsub, do: Application.fetch_env!(:aurora_meter, :pubsub)

  @doc "The configured plans module."
  @spec plans() :: module()
  def plans, do: Application.fetch_env!(:aurora_meter, :plans)

  @doc "The configured tenant-resolution module."
  @spec tenant() :: module()
  def tenant, do: get(:tenant)

  @doc "The plan id used for tenants with no subscription."
  @spec default_plan() :: atom()
  def default_plan, do: get(:default_plan)

  @doc "The configured storage adapter."
  @spec storage() :: module()
  def storage, do: get(:storage)

  @doc "The configured billing provider."
  @spec provider() :: module()
  def provider, do: get(:provider)

  @doc "The configured period source."
  @spec period_source() :: module()
  def period_source, do: get(:period_source)

  @doc "The configured clock. Every instant and date in `lib/` comes from it."
  @spec clock() :: module()
  def clock, do: get(:clock)

  @doc "What the entitlement functions do with a feature the tenant's plan does not declare."
  @spec undeclared_feature_policy() :: :allow | :warn | :deny | :raise
  def undeclared_feature_policy, do: get(:undeclared_feature_policy)

  @doc "Features that also write a durable event row on every `track`."
  @spec durable_features() :: [atom()]
  def durable_features, do: get(:durable_features)

  @doc "Where each declared feature's commercial quantity comes from."
  @spec feature_sources() :: %{atom() => :buffered | :events}
  def feature_sources, do: get(:feature_sources)

  @doc """
  Where `feature`'s commercial quantity comes from: `:buffered` or `:events`.

  Anything the map does not name is `:buffered`, which is every feature in
  0.4.x and the default in 1.0. This is the one seam that answers the question:
  cold seeding, the record path's export eligibility and (from build unit 03c)
  the `track/4` guard all read it here rather than each consulting the map.

  ## Examples

      iex> AuroraMeter.Config.feature_source(:ai_generations)
      :buffered

  """
  @spec feature_source(atom()) :: :buffered | :events
  def feature_source(feature), do: Map.get(feature_sources(), feature, :buffered)

  @doc "The configured `AuroraMeter.Events.Outbox` implementation, or `nil` for none."
  @spec events_outbox() :: module() | nil
  def events_outbox, do: get(:events_outbox)

  @doc "Seconds an `occurred_at` may run ahead of the node clock before it is refused."
  @spec events_future_tolerance() :: non_neg_integer()
  def events_future_tolerance, do: get(:events_future_tolerance)

  @doc "Milliseconds one durable write may take before it is `{:unavailable, :timeout}`."
  @spec record_timeout() :: pos_integer()
  def record_timeout, do: get(:record_timeout)

  @doc "How many callers may hold an open record transaction at once."
  @spec record_max_concurrency() :: pos_integer()
  def record_max_concurrency, do: get(:record_max_concurrency)

  @doc "Milliseconds between durable flushes of dirty counters to the database."
  @spec flush_interval() :: pos_integer()
  def flush_interval, do: get(:flush_interval)

  @doc "Milliseconds between live PubSub broadcasts of touched counters."
  @spec broadcast_interval() :: pos_integer()
  def broadcast_interval, do: get(:broadcast_interval)

  @doc "Whether UTC day buckets are maintained for `AuroraMeter.history/3` (default `true`)."
  @spec history?() :: boolean()
  def history?, do: get(:history)

  @doc "Milliseconds a subscription lookup stays cached (default 5_000; `0` disables)."
  @spec subscription_cache_ttl() :: non_neg_integer()
  def subscription_cache_ttl, do: get(:subscription_cache_ttl)

  @doc "Whether nodes exchange deltas and totals so counters are cluster-wide (default `true`)."
  @spec cluster_sync?() :: boolean()
  def cluster_sync?, do: get(:cluster_sync)

  @doc "Currency code for new credit balance rows (default `\"usd\"`)."
  @spec credits_currency() :: String.t()
  def credits_currency, do: get(:credits_currency)

  @doc "Micro-dollars the available credit balance may go below zero on a hold or debit (default `0`)."
  @spec credits_overdraft_tolerance() :: non_neg_integer()
  def credits_overdraft_tolerance, do: get(:credits_overdraft_tolerance)

  @doc "Default low-balance threshold in micro-dollars, or `nil` for none."
  @spec credits_low_balance_threshold() :: integer() | nil
  def credits_low_balance_threshold, do: get(:credits_low_balance_threshold)

  @doc "The low-balance callback (`fun/1`), or `nil`."
  @spec credits_low_balance_handler() :: (map() -> term()) | nil
  def credits_low_balance_handler, do: get(:credits_low_balance_handler)

  @doc false
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc false
  @spec defaults() :: %{atom() => term()}
  def defaults, do: @defaults

  @doc false
  @spec module_contracts() :: [{atom(), Schema.contract()}]
  def module_contracts, do: @module_contracts

  @spec get(atom()) :: term()
  defp get(key), do: Application.get_env(:aurora_meter, key, Map.fetch!(@defaults, key))

  @spec check_modules!(keyword()) :: keyword()
  defp check_modules!(opts) do
    Enum.each(@module_contracts, fn {key, contract} ->
      Schema.ensure_exports!(:aurora_meter, key, opts[key], contract)
    end)

    opts
  end

  # `events_outbox` is module-typed but optional, and `nil` is the supported
  # value for "no export intent", so it cannot join @module_contracts: that list
  # checks every entry unconditionally and would refuse to boot a host that has
  # simply not configured one.
  @spec check_outbox!(keyword()) :: keyword()
  defp check_outbox!(opts) do
    case opts[:events_outbox] do
      nil ->
        opts

      module ->
        Schema.ensure_exports!(
          :aurora_meter,
          :events_outbox,
          module,
          {:behaviour, AuroraMeter.Events.Outbox}
        )

        opts
    end
  end

  # Warnings only, in both modes, for the two things a plans module can get
  # wrong that are not worth refusing to boot over: `aurora_api` ships float
  # unit prices today, and a `default_plan` naming no plan is an error in 1.0
  # but must not break an upgrade.
  @spec check_plans!(keyword(), Schema.mode()) :: keyword()
  defp check_plans!(opts, mode) do
    plans = opts[:plans].__aurora_plans__()

    for {plan_id, plan} <- plans,
        {feature, {:metered, _included, unit_price}} <- plan.features,
        is_float(unit_price) do
      Logger.warning(
        "config :aurora_meter, plans: plan #{inspect(plan_id)} declares " <>
          "#{inspect(feature)} with a float unit_price (#{unit_price}). Integer minor " <>
          "units (cents) are the supported form; a float is kept for compatibility and " <>
          "may lose precision."
      )
    end

    check_default_plan!(opts[:plans], plans, opts[:default_plan], mode)

    opts
  end

  # Deprecation notices, which warn in both modes and never raise: the key keeps
  # working until 2.0 (`api-change-map.md` section 5), so refusing to boot on one
  # would be a breaking change dressed up as a warning. `warn_once/3` makes it
  # one line per node however many times a host revalidates its configuration.
  #
  # `durable_features` is the only entry today. Build unit 03c adds
  # `feature_sources`, which is the replacement named here, and must not add a
  # second warning for the same key.
  @spec check_deprecations!(keyword()) :: keyword()
  defp check_deprecations!(opts) do
    case opts[:durable_features] do
      [] ->
        :ok

      nil ->
        :ok

      features ->
        Schema.warn_once(:deprecated_key, :durable_features, fn ->
          "config :aurora_meter, durable_features: #{inspect(features)} is deprecated. " <>
            "It still works, and will keep working until 2.0. Aurora Meter 1.0 replaces " <>
            "it with `feature_sources`, which says where each feature's commercial " <>
            "quantity comes from instead of bolting an event row onto a buffered count, " <>
            "and with `AuroraMeter.record/4` for usage that must not be lost. Nothing to " <>
            "do today: see docs/upgrading-to-1.0.md before you upgrade to 1.0."
        end)
    end

    opts
  end

  @spec check_default_plan!(module(), map(), atom(), Schema.mode()) :: :ok
  defp check_default_plan!(module, plans, default_plan, mode) do
    cond do
      Map.has_key?(plans, default_plan) ->
        :ok

      mode == :strict ->
        raise ArgumentError, unknown_default_plan(module, plans, default_plan)

      true ->
        Logger.warning(unknown_default_plan(module, plans, default_plan))
    end

    :ok
  end

  @spec unknown_default_plan(module(), map(), atom()) :: String.t()
  defp unknown_default_plan(module, plans, default_plan) do
    "config :aurora_meter, default_plan: #{inspect(default_plan)} is not declared by " <>
      "#{inspect(module)}. Known plans: #{inspect(Enum.sort(Map.keys(plans)))}. Every " <>
      "tenant without an entitled subscription would resolve to no plan at all."
  end
end
