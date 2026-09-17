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
            plan_version_conflict: [
              type: {:in, [:raise, :warn]},
              default: Schema.default_plan_version_conflict(),
              doc:
                "What `AuroraMeter.Plans.register!/0` does when a compiled plan version's " <>
                  "commercial content differs from the snapshot already registered for it: " <>
                  "`:raise` refuses the boot with " <>
                  "`AuroraMeter.PlanVersionConflictError`, `:warn` logs the same message and " <>
                  "continues. The default is `:warn` in the 0.5.x transition release and " <>
                  "`:raise` from 1.0, so the first exposure to an edited plan version is a " <>
                  "log line rather than a failed deploy. Neither setting reprices anybody: " <>
                  "a tenant stays on the stored definition either way."
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
            metrics_interval: [
              type: :non_neg_integer,
              default: 10_000,
              doc:
                "Milliseconds between gauge samples (`[:aurora_meter, :store, :gauge]` and " <>
                  "`[:aurora_meter, :cluster, :lag]`). `0` switches the internal timers off " <>
                  "entirely; call `AuroraMeter.Telemetry.emit_gauges/0` from your own " <>
                  "scheduler instead."
            ],
            metrics_feature_label: [
              type: :boolean,
              default: false,
              doc:
                "Whether `AuroraMeter.Telemetry.Metrics.metrics/1` tags on `:feature`. Off by " <>
                  "default: the bound on its value set is the host's own plan definitions, " <>
                  "and one time series per feature per metric is a cost only the host can price."
            ],
            metrics_scan_ceiling: [
              type: :non_neg_integer,
              default: 50_000,
              doc:
                "The largest counters table `[:aurora_meter, :cluster, :lag]` will scan for " <>
                  "`unreconciled_keys`. Above it the measurement is **omitted**, never " <>
                  "reported as zero. `0` omits it always."
            ],
            flush_receipt_retention: [
              type: {:custom, __MODULE__, :retention_days, [:flush_receipt_retention]},
              default: 30,
              doc:
                "Days a flush receipt is kept before `AuroraMeter.Retention` may delete it. " <>
                  "Age alone never deletes one: every node's flush heartbeat must also prove " <>
                  "no node still holds a batch from before the cutoff. The floor is 1 day " <>
                  "and it is a correctness floor, not a taste: see `AuroraMeter.Retention`."
            ],
            replay_checkpoint_retention: [
              type: {:custom, __MODULE__, :retention_days, [:replay_checkpoint_retention]},
              default: 365,
              doc:
                "Days a finished `\"events_replay:<generation>\"` checkpoint row is kept " <>
                  "before `AuroraMeter.Retention` may delete it. The generations named by " <>
                  "the live projection row are never deleted, at any age."
            ],
            flush_node_id: [
              type: {:or, [:string, nil]},
              default: nil,
              doc:
                "This node's identity in its `\"flush:<node>\"` heartbeat row. Defaults to " <>
                  "`to_string(node())`, which is `\"nonode@nohost\"` on an unnamed VM: set it " <>
                  "per node when several unnamed VMs share one database, or their heartbeats " <>
                  "collapse into one row that cannot tell one node from ten."
            ],
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
                "Called with `%{tenant_key, available, spendable, threshold, crossing_id}` " <>
                  "after a low-balance crossing commits (a place to email or to " <>
                  "auto-recharge). It runs in a supervised watcher that the caller does not " <>
                  "wait for, so it can neither fail nor delay the ledger call, and it takes " <>
                  "its own database connection if it needs one."
            ],
            credits_low_balance_handler_timeout: [
              type: :pos_integer,
              default: 5_000,
              doc:
                "Milliseconds one `:credits_low_balance_handler` call may take before the " <>
                  "ledger kills it. The write it followed stands either way: the handler runs " <>
                  "in a supervised task, so it cannot fail, block or crash the caller."
            ],
            credits_hold_reconciler: [
              type: {:or, [:atom, {:fun, 1}, {:tuple, [:atom, :atom]}, nil]},
              default: nil,
              doc:
                "How `AuroraMeter.Credits.reconcile_holds/1` decides what to do with a stale " <>
                  "hold: a module implementing `AuroraMeter.Credits.HoldReconciler`, a " <>
                  "`{module, function}` pair of arity 1, a one-argument function, or `nil`. " <>
                  "`nil` is the default and means every hold is kept, so a host that upgrades " <>
                  "and configures nothing cannot have money released on its behalf."
            ],
            credits_hold_reconciler_timeout: [
              type: :pos_integer,
              default: 5_000,
              doc:
                "Milliseconds one `decide/1` call may take before the reconciler kills it and " <>
                  "keeps the hold."
            ],
            live_view_tenant: [
              type: {:or, [{:tuple, [:atom, :atom]}, nil]},
              default: nil,
              doc:
                "How `on_mount {AuroraMeter.LiveView, :subscribe}` finds the tenant when the " <>
                  "host passes no resolver: a `{module, function}` pair of arity 2, called " <>
                  "with the LiveView session and the socket. There is deliberately no " <>
                  "default. `AuroraMeter.Tenant.Default.to_key/1` maps `nil` to `\"\"`, so a " <>
                  "fallback would put every tenant the host could not resolve on one set of " <>
                  "counters; the bare form raises at mount instead, naming this key and the " <>
                  "two explicit forms."
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
  # The set of features whose commercial quantity comes from durable events,
  # cached here because `AuroraMeter.track/4` and `AuroraMeter.reserve/2,3`
  # consult it on every call and a live read is the most expensive thing that
  # would be on that path.
  #
  # Measured on this machine, 2,000,000 iterations each, net of the loop:
  # `Application.get_env/3` plus `Map.get/3` is 75.2 ns, `:persistent_term.get/1`
  # plus `MapSet.member?/2` is 15.5 ns. `track/4` already makes five
  # configuration reads (`tenant`, `period_source`, `history`,
  # `durable_features`, `plans`), so a sixth live read would have been the
  # single most expensive one on the hot path, for the one question that is
  # asked on every call and answered the same way for the life of the node.
  #
  # `feature_source/1` reads the **same** term rather than the environment, and
  # that is the point rather than an optimisation: the reporting source is one
  # fact, and two readers of one fact is how the guard and the cold seed end up
  # disagreeing about which source a feature has. A cached guard beside a live
  # seed would let `track/4` bump a key into the flush path while
  # `Counter.stored_value/1` seeded the same key from `load_event_total/3`,
  # which is exactly the double count I08 forbids.
  @events_features_term {__MODULE__, :events_features}

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
    |> check_hold_reconciler!()
    |> check_plans!(mode)
    |> check_deprecations!()
    |> check_sources!()
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

  @doc """
  Whether an edited plan version refuses the boot or logs.

  ## Examples

      iex> AuroraMeter.Config.plan_version_conflict() in [:raise, :warn]
      true

  """
  @spec plan_version_conflict() :: :raise | :warn
  def plan_version_conflict, do: get(:plan_version_conflict)

  @doc "Features that also write a durable event row on every `track`."
  @spec durable_features() :: [atom()]
  def durable_features, do: get(:durable_features)

  @doc """
  The `:feature_sources` map as configured.

  This is the **declaration**. `feature_source/1` is what is in force on this
  node, which is the declaration as it stood at the last `validate!/0`; the two
  differ only for a host that rewrites the key at runtime, which is documented
  in [Metering](metering.md) as unsupported.
  """
  @spec feature_sources() :: %{atom() => :buffered | :events}
  def feature_sources, do: get(:feature_sources)

  @doc """
  Where `feature`'s commercial quantity comes from: `:buffered` or `:events`.

  Anything the configuration does not name is `:buffered`, which is every
  feature in 0.4.x and the default in 1.0. This is the one seam that answers the
  question: the `AuroraMeter.track/4` and `AuroraMeter.reserve/2,3` guards, the
  `AuroraMeter.with_quota/4` commit rule, cold seeding and the record path's
  export eligibility all read it here rather than each consulting the map.

  The source is a **boot-time** property. It is read from the cache
  `validate!/0` fills, so changing `:feature_sources` at runtime changes nothing
  on this node until it is validated again. That is deliberate: a source that
  could change between two calls in one period is precisely the double-count
  this key exists to prevent.

  ## Examples

      iex> AuroraMeter.Config.feature_source(:ai_generations)
      :buffered

  """
  @spec feature_source(atom()) :: :buffered | :events
  def feature_source(feature) do
    if MapSet.member?(events_features(), feature), do: :events, else: :buffered
  end

  @doc false
  # The hot-path form of `feature_source/1`, for a caller that is about to ask
  # about several features or that wants the set itself. Not public: a host asks
  # about one feature at a time and `feature_source/1` is the readable way to do
  # that (`api-change-map.md` section 5).
  #
  # An unset term means `validate!/0` has not run on this node yet (a host that
  # calls an accessor before starting the supervisor, or a doctest). It falls
  # back to the declaration rather than to "everything is buffered", because a
  # silent `:buffered` for a feature the host declared `:events` is the one
  # wrong answer this seam must never give.
  @spec events_features() :: MapSet.t(atom())
  def events_features do
    case :persistent_term.get(@events_features_term, :unset) do
      :unset -> declared_events_features() || MapSet.new()
      set -> set
    end
  end

  @doc false
  # Rebuilds the events-source cache from the current environment. Called by
  # `validate!/0`, and by this repository's test harness
  # (`AuroraMeter.Test.Config`) around every configuration region, so a test that
  # overrides `:feature_sources` sees its override and the next test does not.
  #
  # It writes only when the set actually changed. `:persistent_term.put/2` scans
  # every process for references to the value it replaces, so an unconditional
  # write on every test region would be a real cost for no effect: the
  # overwhelming majority of regions do not touch this key.
  @spec refresh!() :: :ok
  def refresh! do
    case declared_events_features() do
      nil ->
        :ok

      set ->
        if :persistent_term.get(@events_features_term, :unset) != set do
          :persistent_term.put(@events_features_term, set)
        end

        :ok
    end
  end

  # `nil` means the declaration is not a map and no set can be derived from it.
  # The schema refuses anything else at boot, so this is reached only when
  # something has written the key directly: a host bypassing validation, or this
  # repository's strictness suite, which walks every key through a placeholder
  # value on its way to deleting it. Refusing to rebuild is the conservative
  # answer, because the alternative (an empty set) would quietly turn an
  # events-source feature back into a trackable one on the strength of a value
  # that will not survive the next boot.
  #
  # It reads the raw configured value through `get/1` rather than through
  # `feature_sources/0`: that accessor's spec promises a map, and this function
  # exists for the case where the environment does not hold one, which is a
  # runtime possibility the spec cannot express.
  @spec declared_events_features() :: MapSet.t(atom()) | nil
  defp declared_events_features do
    case get(:feature_sources) do
      sources when is_map(sources) ->
        for {feature, :events} <- sources, into: MapSet.new(), do: feature

      _not_a_map ->
        nil
    end
  end

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

  @doc """
  Milliseconds between gauge samples, or `0` for no internal timers.

  Returns whatever the host configured. The default is `10_000`, and this
  repository's own test configuration sets `0`, which is why the figure is
  stated here rather than shown as an example: an example that asserts a
  configured value is a test of the configuration it happens to run under.
  """
  @spec metrics_interval() :: non_neg_integer()
  def metrics_interval, do: get(:metrics_interval)

  @doc """
  Whether the metrics presets tag on `:feature` (default `false`).

  ## Examples

      iex> AuroraMeter.Config.metrics_feature_label?()
      false

  """
  @spec metrics_feature_label?() :: boolean()
  def metrics_feature_label?, do: get(:metrics_feature_label)

  @doc """
  The largest counters table the cluster lag gauge will scan for
  `unreconciled_keys`; above it the measurement is omitted rather than zeroed.

  ## Examples

      iex> AuroraMeter.Config.metrics_scan_ceiling()
      50_000

  """
  @spec metrics_scan_ceiling() :: non_neg_integer()
  def metrics_scan_ceiling, do: get(:metrics_scan_ceiling)

  @doc """
  Days a flush receipt is kept before `AuroraMeter.Retention` may delete it
  (default 30, floor 1 day).

  ## Examples

      iex> AuroraMeter.Config.flush_receipt_retention()
      30

  """
  @spec flush_receipt_retention() :: pos_integer()
  def flush_receipt_retention, do: get(:flush_receipt_retention)

  @doc """
  Days a finished replay checkpoint row is kept (default 365, floor 1 day).

  ## Examples

      iex> AuroraMeter.Config.replay_checkpoint_retention()
      365

  """
  @spec replay_checkpoint_retention() :: pos_integer()
  def replay_checkpoint_retention, do: get(:replay_checkpoint_retention)

  @doc """
  The configured identity for this node's `"flush:<node>"` heartbeat row, or
  `nil` when nothing is configured.

  `nil` means "use `to_string(node())`", which `AuroraMeter.Retention.node_id/0`
  resolves. It is not resolved here because a default is written once, in the
  schema, and `node()` is not a value a compile-time schema can hold.

  On an unnamed VM `node()` is `:nonode@nohost` for every node, so several
  unnamed VMs sharing one database write **one** heartbeat row between them,
  which cannot distinguish one node from ten. `AuroraMeter.Retention` logs a
  warning when it sees that name.

  ## Examples

      iex> AuroraMeter.Config.flush_node_id()
      nil

  """
  @spec flush_node_id() :: String.t() | nil
  def flush_node_id, do: get(:flush_node_id)

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

  @doc """
  Milliseconds one `:credits_low_balance_handler` call may take before it is
  killed.

  ## Examples

      iex> AuroraMeter.Config.credits_low_balance_handler_timeout()
      5000

  """
  @spec credits_low_balance_handler_timeout() :: pos_integer()
  def credits_low_balance_handler_timeout, do: get(:credits_low_balance_handler_timeout)

  @doc """
  How `AuroraMeter.Credits.reconcile_holds/1` decides about a stale hold.

  `nil`, the default, means every hold is kept. That is the value a host that
  has never heard of this key has, and it is why upgrading cannot release money.

  ## Examples

      iex> AuroraMeter.Config.credits_hold_reconciler()
      nil

  """
  @spec credits_hold_reconciler() ::
          module() | {module(), atom()} | (map() -> term()) | nil
  def credits_hold_reconciler, do: get(:credits_hold_reconciler)

  @doc """
  Milliseconds one `c:AuroraMeter.Credits.HoldReconciler.decide/1` call may take.

  ## Examples

      iex> AuroraMeter.Config.credits_hold_reconciler_timeout()
      5000

  """
  @spec credits_hold_reconciler_timeout() :: pos_integer()
  def credits_hold_reconciler_timeout, do: get(:credits_hold_reconciler_timeout)

  @doc """
  The `{module, function}` pair `on_mount {AuroraMeter.LiveView, :subscribe}`
  calls to resolve the tenant, or `nil` when the host passes a resolver at the
  mount instead.

  ## Examples

      iex> AuroraMeter.Config.live_view_tenant()
      nil

  """
  @spec live_view_tenant() :: {module(), atom()} | nil
  def live_view_tenant, do: get(:live_view_tenant)

  @doc false
  # The retention floor, and it is a correctness floor rather than a taste.
  #
  # A retention window is compared against a stored timestamp, and two of the
  # three stamps involved are written by a node's wall clock while the cutoff
  # comes from the database's. `open-findings.md` X100 measured the shared clock
  # stepping backwards by up to 439 ms and X59 measured a node's by up to
  # 2.6472 s, so the comparison is sound only while the window is enormous
  # relative to those numbers. At one day it is roughly 30,000 times the worst
  # combined step; at one minute it is 20 times, and at one second the argument
  # is simply gone. So the small value is refused **at boot**, where an operator
  # can still read the message, rather than silently producing a deletion that
  # cannot be undone.
  #
  # One day is also far longer than any legitimate use: a host that wants its
  # receipts gone sooner than a day wants a different mechanism, not a smaller
  # number here.
  @spec retention_days(term(), atom()) :: {:ok, pos_integer()} | {:error, String.t()}
  def retention_days(days, _key) when is_integer(days) and days >= 1, do: {:ok, days}

  def retention_days(days, key) when is_integer(days) do
    {:error,
     "#{inspect(key)} is #{days} days, and the floor is 1 day. A retention window is " <>
       "compared against a stored timestamp, and the clocks that write those timestamps " <>
       "step backwards by up to a few seconds (open-findings.md X59, X100). A window of " <>
       "a day is about thirty thousand times that; a window of minutes is not, and this " <>
       "decision deletes data that cannot be recovered. Pass a one-off " <>
       ":older_than to AuroraMeter.Retention.prune/1 if you need a narrower cutoff once."}
  end

  def retention_days(other, key),
    do:
      {:error, "#{inspect(key)} is a number of days (a positive integer), got: #{inspect(other)}"}

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

  # `credits_hold_reconciler` is four shapes in one key, so it cannot join
  # @module_contracts either: only two of the four are modules. Both of those
  # are checked here, at boot, because the alternative is discovering a typo at
  # the moment a stale hold is being decided, which is the worst moment this
  # library has.
  #
  # A function value is not checked beyond its arity, which NimbleOptions has
  # already done: there is nothing else to know about it before it is called.
  @spec check_hold_reconciler!(keyword()) :: keyword()
  defp check_hold_reconciler!(opts) do
    case opts[:credits_hold_reconciler] do
      nil ->
        opts

      {module, function} when is_atom(module) and is_atom(function) ->
        Schema.ensure_exports!(
          :aurora_meter,
          :credits_hold_reconciler,
          module,
          {:exports, [{function, 1}], "a module exporting #{function}/1"}
        )

        opts

      module when is_atom(module) ->
        Schema.ensure_exports!(
          :aurora_meter,
          :credits_hold_reconciler,
          module,
          {:behaviour, AuroraMeter.Credits.HoldReconciler}
        )

        opts

      _function ->
        opts
    end
  end

  # Warnings only, in both modes, for the two things a plans module can get
  # wrong that are not worth refusing to boot over: `aurora_api` ships float
  # unit prices today, and a `default_plan` naming no plan is an error in 1.0
  # but must not break an upgrade.
  @spec check_plans!(keyword(), Schema.mode()) :: keyword()
  defp check_plans!(opts, mode) do
    # Keyed by `{plan_id, version}` since core schema version 10: a plan id has
    # as many definitions as it has versions and each of them is checked.
    plans = opts[:plans].__aurora_plans__()

    for {{plan_id, version}, plan} <- plans,
        {feature, {:metered, _included, unit_price}} <- plan.features,
        is_float(unit_price) do
      Logger.warning(
        "config :aurora_meter, plans: plan #{inspect(plan_id)} version #{inspect(version)} " <>
          "declares #{inspect(feature)} with a float unit_price (#{unit_price}). Integer minor " <>
          "units (cents) are the supported form; a float is kept for compatibility and " <>
          "may lose precision."
      )
    end

    ids = plans |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    check_default_plan!(opts[:plans], ids, opts[:default_plan], mode)

    opts
  end

  # Deprecation notices, which warn in both modes and never raise: the key keeps
  # working until 2.0 (`api-change-map.md` section 5), so refusing to boot on one
  # would be a breaking change dressed up as a warning. `warn_once/3` makes it
  # one line per node however many times a host revalidates its configuration.
  #
  # `durable_features` is the only entry. `feature_sources`, the replacement it
  # names, arrived in build unit 03c and deliberately adds no second warning for
  # the same key: one deprecated key, one notice.
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

  # Reporting sources (build unit 03c, invariant I08).
  #
  # One feature, one source. A feature listed in the legacy `durable_features`
  # AND declared `:events` is asking for its usage to be counted twice in two
  # places, which is the failure the whole unit exists to prevent, so it is a
  # boot error in both modes rather than a warning: there is no reading of that
  # configuration under which the host gets what it asked for.
  #
  # An `:events` feature no plan declares is only a warning. It cannot be
  # billed, because a reporter stages a feature the plan declares; but metering
  # a name before it reaches a plan is legitimate (the same reasoning that keeps
  # `track/4` outside `:undeclared_feature_policy`), so it is reported, not
  # refused.
  #
  # There is deliberately no check for "this feature already has counter rows".
  # Core cannot know whether those rows were ever reported to a provider, and a
  # refusal that cannot tell a fresh install from a mid-period migration would
  # fire on the wrong one. That check belongs to Pro, which knows about
  # `usage_reports`, and lands with the cutover watermark in build unit 04c.
  @spec check_sources!(keyword()) :: keyword()
  defp check_sources!(opts) do
    sources = opts[:feature_sources] || %{}

    Enum.each(opts[:durable_features] || [], fn feature ->
      if Map.get(sources, feature) == :events do
        raise ArgumentError, dual_source_message(feature)
      end
    end)

    warn_undeclared_sources(sources, opts[:plans])

    # The cache the guards read is filled from the configuration that has just
    # been validated, and only after the dual declaration has been refused: a
    # rejected configuration must not reach the hot path even for the instant
    # between the raise and the supervisor giving up.
    refresh!()

    opts
  end

  @spec dual_source_message(atom()) :: String.t()
  defp dual_source_message(feature) do
    "config :aurora_meter: feature #{inspect(feature)} is declared both as a legacy " <>
      "durable feature (in :durable_features) and as an events-source feature (in " <>
      ":feature_sources). A feature has exactly one reporting source. Either remove " <>
      "#{inspect(feature)} from :durable_features and record it with " <>
      "`AuroraMeter.record/4`, or remove its :events entry from :feature_sources and " <>
      "keep tracking it. Leaving both would count the same usage twice, once as a " <>
      "buffered counter and once as a durable event."
  end

  # `AuroraMeter.Plans.declared_anywhere?/1` is reused rather than reimplemented
  # here: it already handles both the compiled feature set and the fold over
  # plans for a module that predates it, and it calls `Code.ensure_loaded?/1`
  # before `function_exported?/3` (`open-findings.md` X113). It resolves the
  # module from the environment, which during `validate!/1` is the same module
  # `opts[:plans]` names; the argument is carried for the message only.
  @spec warn_undeclared_sources(map(), module()) :: :ok
  defp warn_undeclared_sources(sources, plans_module) do
    for {feature, :events} <- sources,
        not AuroraMeter.Plans.declared_anywhere?(feature) do
      Schema.warn_once(:events_source_undeclared, feature, fn ->
        "config :aurora_meter, feature_sources: #{inspect(feature)} is declared as an " <>
          "events-source feature, but no plan in #{inspect(plans_module)} declares it. " <>
          "Recording it works and the totals are kept, but nothing will ever bill it: a " <>
          "reporter stages the features a plan declares. Declare it on a plan, or run " <>
          "`mix aurora_meter.features` to see every other name a configuration " <>
          "references and no plan declares."
      end)
    end

    :ok
  end

  @spec check_default_plan!(module(), [atom()], atom(), Schema.mode()) :: :ok
  defp check_default_plan!(module, ids, default_plan, mode) do
    cond do
      default_plan in ids ->
        :ok

      mode == :strict ->
        raise ArgumentError, unknown_default_plan(module, ids, default_plan)

      true ->
        Logger.warning(unknown_default_plan(module, ids, default_plan))
    end

    :ok
  end

  @spec unknown_default_plan(module(), [atom()], atom()) :: String.t()
  defp unknown_default_plan(module, ids, default_plan) do
    "config :aurora_meter, default_plan: #{inspect(default_plan)} is not declared by " <>
      "#{inspect(module)}. Known plans: #{inspect(Enum.sort(ids))}. Every " <>
      "tenant without an entitled subscription would resolve to no plan at all."
  end
end
