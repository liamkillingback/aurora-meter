defmodule AuroraMeter.Plans do
  @moduledoc """
  Compile-time DSL for declaring billing plans, plus runtime lookups.

  Define a plans module:

      defmodule MyApp.Plans do
        use AuroraMeter.Plans

        plan :free do
          price 0
          limit :ai_generations, 50, :hard
          feature :api_access, false
        end

        plan :pro do
          price 2_000
          limit :ai_generations, 1_000, :hard
          feature :api_access, true
          feature :seats, 5
        end

        plan :scale do
          price 2_000
          metered :ai_generations, included: 1_000, unit_price: 2
          feature :api_access, true
        end

        plan :payg do
          price 0
          counter :requests
          feature :api_access, true
          recurring_credits :monthly_allowance, amount: 5_000_000, rollover: 1_000_000
        end
      end

  Then point `config :aurora_meter, plans: MyApp.Plans`. Definitions are validated
  at compile time (duplicate features, invalid modes, negative numbers all raise).
  """

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema, as: ConfigSchema
  alias AuroraMeter.Plan
  alias AuroraMeter.Plans.Snapshot
  alias AuroraMeter.PlanVersionConflictError
  alias AuroraMeter.Storage

  # The entitlement name and the plan id both become part of a recurrence key,
  # and a key is parsed by splitting on `:`. Validated where the string is
  # invented rather than where it is read (`open-findings.md` X272).
  @name_format ~r/^[a-z][a-z0-9_]*$/

  # A version is an opaque label a host chooses, so it is deliberately not
  # snake case: `"2"`, `"2026-10"` and `"v2_eu"` are all reasonable. What it
  # may not contain is either canonical-form separator, a `:` (it becomes part
  # of a recurrence key) or anything that would not survive a round trip
  # through a `text` column.
  @version_format ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,31}\z/

  @plan_options [:version, :effective_at]

  @recurring_keys [:amount, :category, :rollover, :expires]

  @categories [:promotional, :paid, :adjustment]

  # `:ok`, `:deferred` (the repo was not reachable at boot), `:unsupported`
  # (the storage adapter has no snapshot support) or absent (never run).
  @registry_key {AuroraMeter, :plan_registry}

  # `%{{plan_id_string, version} => Plan.t() | :missing}`. Negative entries are
  # cached deliberately: `:persistent_term.put/2` triggers a global GC scan, so
  # a persistently unknown version must cost one query and one put per node per
  # version ever, not one per call.
  @snapshots_key {AuroraMeter, :plan_snapshots}

  # And the negative half is bounded, because `get/2` is public and a caller can
  # ask for any string at all. Past this many entries the cache stops growing
  # and says so once.
  @snapshot_cache_limit 256

  @backfill_batch 5_000

  @doc false
  defmacro __using__(_opts) do
    quote do
      import AuroraMeter.Plans,
        only: [
          plan: 2,
          plan: 3,
          price: 1,
          limit: 3,
          metered: 2,
          counter: 1,
          feature: 2,
          recurring_credits: 2
        ]

      Module.register_attribute(__MODULE__, :aurora_plans, accumulate: true)
      @before_compile AuroraMeter.Plans
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # The first point at which every block in the module is visible, so it is
    # the only place the cross-block rules can be checked.
    entries = env.module |> Module.get_attribute(:aurora_plans, []) |> Enum.reverse()
    __validate_module__(env.module, entries)

    # Every feature name any plan declares, folded once at compile time and
    # embedded as a literal. `AuroraMeter.track/4` asks this on its hot path, so
    # it must not rebuild a set per call. It is the union over **every** version,
    # because a feature declared only by a future version is still a name the
    # plans module knows.
    features =
      entries
      |> Enum.flat_map(fn {_key, plan} -> Map.keys(plan.features) end)
      |> MapSet.new()
      |> Macro.escape()

    plans = entries |> Map.new() |> Macro.escape()
    index = entries |> __index__() |> Macro.escape()

    quote do
      @doc false
      @spec __aurora_plans__() :: %{optional({atom(), String.t()}) => AuroraMeter.Plan.t()}
      def __aurora_plans__, do: unquote(plans)

      @doc false
      @spec __aurora_plan_index__() :: %{
              optional(atom()) => [{DateTime.t() | nil, String.t()}]
            }
      def __aurora_plan_index__, do: unquote(index)

      @doc false
      @spec __aurora_features__() :: MapSet.t()
      def __aurora_features__, do: unquote(features)
    end
  end

  @doc """
  Declares a plan version. Contains `price`, `limit`, `metered`, `counter`,
  `feature` and `recurring_credits` calls.

      plan :pro do                                   # version "1", effective now
        price 2_000
        limit :ai_generations, 1_000, :hard
      end

      plan :pro, version: "2", effective_at: ~U[2026-10-01 00:00:00Z] do
        price 3_000
        limit :ai_generations, 2_000, :hard
      end

  Options:

    * `:version`: a short label, `"1"` by default. It is the tenant's contract
      and it is immutable: changing what a version declares is
      `AuroraMeter.PlanVersionConflictError`, not a price change.
    * `:effective_at`: the UTC instant from which `AuroraMeter.Plans.get/1`
      returns this version. Omitted means "from the beginning", and exactly one
      version of each plan id must omit it.

  `plan/2` is the form without options and `plan/3` the form with them: Elixir
  parses `plan :pro, version: "2" do ... end` as three arguments, the id, the
  keyword list and the `do` block, not as two. Existing plans modules are
  untouched, because a block with no options is still `plan/2` (finding X289).
  """
  defmacro plan(id, opts), do: __plan__(id, opts)

  @doc """
  Declares a plan version with options. See `plan/2`.
  """
  defmacro plan(id, opts, block) when is_list(opts) and is_list(block),
    do: __plan__(id, opts ++ block)

  defp __plan__(id, opts) do
    {block, options} = __split_options__(id, opts)

    quote do
      Module.delete_attribute(__MODULE__, :aurora_features)
      Module.register_attribute(__MODULE__, :aurora_features, accumulate: true)
      Module.delete_attribute(__MODULE__, :aurora_recurring_credits)
      Module.register_attribute(__MODULE__, :aurora_recurring_credits, accumulate: true)
      Module.put_attribute(__MODULE__, :aurora_price, 0)

      unquote(block)

      @aurora_plans AuroraMeter.Plans.__build__(
                      unquote(id),
                      unquote(options),
                      Module.get_attribute(__MODULE__, :aurora_price),
                      Module.get_attribute(__MODULE__, :aurora_features),
                      Module.get_attribute(__MODULE__, :aurora_recurring_credits)
                    )
    end
  end

  @doc false
  @spec __split_options__(term(), term()) :: {Macro.t(), Macro.t()}
  def __split_options__(id, opts) when is_list(opts) do
    case Keyword.pop(opts, :do) do
      {nil, _rest} ->
        raise ArgumentError,
              "plan #{Macro.to_string(id)} needs a do block: plan :pro do price 2_000 end"

      {block, rest} ->
        unknown = Keyword.keys(rest) -- @plan_options

        if unknown != [] do
          raise ArgumentError,
                "plan #{Macro.to_string(id)} has unknown option(s) #{inspect(unknown)}; " <>
                  "the options are #{inspect(@plan_options)}"
        end

        {block, rest}
    end
  end

  def __split_options__(id, opts) do
    raise ArgumentError,
          "plan #{Macro.to_string(id)} takes a keyword list and a do block, got: " <>
            Macro.to_string(opts)
  end

  @doc "Sets the plan's monthly price in minor units (cents)."
  defmacro price(amount) do
    quote do: Module.put_attribute(__MODULE__, :aurora_price, unquote(amount))
  end

  @doc "Declares a hard-capped feature: `limit :feature, n, :hard`."
  defmacro limit(feature, count, mode) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :aurora_features,
        {unquote(feature), {:limit, unquote(count), unquote(mode)}}
      )
    end
  end

  @doc "Declares a metered feature: `metered :feature, included: n, unit_price: cents`."
  defmacro metered(feature, opts) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :aurora_features,
        {unquote(feature), {:metered, unquote(opts)[:included], unquote(opts)[:unit_price]}}
      )
    end
  end

  @doc """
  Declares a counter feature: `counter :requests`.

  A counter is **measured but never billed and never blocked** — the thing to
  reach for when the money lives somewhere else (a prepaid credit ledger, a
  usage-based invoice built outside Aurora Meter) and the plan only wants a
  number on the dashboard. `check/2` is always `:ok`, `remaining/2` is
  `:unlimited`, and `quota/2` reports `kind: :counter` with `limit`, `included`
  and `percent` all `nil` — a counter has no denominator, so there is no bar to
  draw. See ADR 0006.
  """
  defmacro counter(feature) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :aurora_features,
        {unquote(feature), {:counter}}
      )
    end
  end

  @doc """
  Declares plain feature access or a plan-level value.

  `feature :api_access, true` grants (or, with `false`, denies) access with no
  quota behind it. `feature :seats, 5` declares a non-negative integer the plan
  carries for the host to read with `AuroraMeter.feature_value/3` (seats,
  retention days, projects); integer features are always entitled and never
  metered.
  """
  defmacro feature(name, value) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :aurora_features,
        {unquote(name), {:feature, unquote(value)}}
      )
    end
  end

  @doc """
  Declares a recurring credit allowance: `recurring_credits :monthly, amount: 5_000_000`.

  The allowance is granted once per tenant, entitlement, plan version and
  billing period by `AuroraMeter.Credits.Recurrences.run/1`. A plan that does
  not declare one grants nothing, which is what "recurring grants default to
  disabled" means.

  Options:

    * `:amount` — required, a positive **integer** of micro-dollars. A float is
      an error rather than a warning: this is new API and money is an integer.
    * `:category` — `:promotional` (default), `:paid` or `:adjustment`.
    * `:rollover` — a non-negative integer cap in micro-dollars, `0` (default)
      for no rollover. At most this much of one period's **unused** allowance is
      carried into the next period, as a new lot with its own reference. It does
      not accumulate: two idle periods carry the cap, not twice the cap.
    * `:expires` — `:period_end` (default), `:never` or `{:seconds, n}`.

  Three combinations are refused at compile time, each because the ledger or the
  arithmetic cannot honour it:

    * `rollover > 0` with anything but `expires: :period_end`. A rollover is
      defined as what the previous period's lot did not spend before it expired,
      so a lot that outlives the period boundary would be carried and still be
      spendable, and the tenant would hold the same micro-dollar twice.
    * an expiry on a non-promotional allowance. Only promotional grants expire
      (`AuroraMeter.Schema.CreditTransaction` refuses an `:expires_at` on any
      other category), which is also `v1-release.md` 10.1's rule that paid
      top-ups do not expire unless their own contract says so.
    * a name or a plan id that is not lower snake case. Both become part of the
      recurrence key, which is read by splitting on `:`.

  `expires: :never` on a promotional allowance is allowed and warned: a
  never-expiring monthly promotion accumulates for ever.
  """
  defmacro recurring_credits(name, opts) do
    quote do
      Module.put_attribute(
        __MODULE__,
        :aurora_recurring_credits,
        {unquote(name), unquote(opts)}
      )
    end
  end

  @doc false
  @spec __build__(atom(), keyword(), non_neg_integer(), [{atom(), Plan.feature_config()}], [
          {atom(), keyword()}
        ]) :: {{atom(), String.t()}, Plan.t()}
  def __build__(id, options, price, features_rev, recurring_rev) do
    features = Enum.reverse(features_rev)
    version = validate_version!(id, Keyword.get(options, :version, Plan.base_version()))
    effective_at = validate_effective_at!(id, version, Keyword.get(options, :effective_at))
    validate_no_duplicates!(id, features)
    Enum.each(features, &validate_feature!(id, &1))
    Enum.each(features, fn {name, _config} -> validate_renderable!(id, version, name) end)
    validate_price!(id, price)
    recurring = build_recurring!(id, Enum.reverse(recurring_rev || []))
    Enum.each(recurring, &validate_renderable!(id, version, &1.name))

    plan = %Plan{
      id: id,
      version: version,
      price: price,
      features: Map.new(features),
      recurring_credits: recurring,
      effective_at: effective_at
    }

    {{id, version}, %{plan | fingerprint: Snapshot.fingerprint(plan)}}
  end

  @doc false
  @spec __validate_module__(module(), [{{atom(), String.t()}, Plan.t()}]) :: :ok
  def __validate_module__(module, entries) do
    keys = Enum.map(entries, &elem(&1, 0))
    duplicates = keys -- Enum.uniq(keys)

    if duplicates != [] do
      raise ArgumentError,
            "#{inspect(module)} declares the same plan version twice: " <>
              Enum.map_join(Enum.uniq(duplicates), ", ", fn {id, version} ->
                "#{inspect(id)} version #{inspect(version)}"
              end) <>
              ". A plan version is an immutable identity; give the second block its own " <>
              ":version."
    end

    entries
    |> Enum.group_by(fn {{id, _version}, _plan} -> id end)
    |> Enum.each(fn {id, grouped} -> validate_plan_versions!(module, id, grouped) end)

    :ok
  end

  @doc false
  @spec __index__([{{atom(), String.t()}, Plan.t()}]) :: %{
          optional(atom()) => [{DateTime.t() | nil, String.t()}]
        }
  def __index__(entries) do
    entries
    |> Enum.group_by(fn {{id, _version}, _plan} -> id end)
    |> Map.new(fn {id, grouped} ->
      {id,
       grouped
       |> Enum.map(fn {{_id, version}, plan} -> {plan.effective_at, version} end)
       |> sort_versions()}
    end)
  end

  @doc """
  Returns the **effective** version of every plan as `%{id => Plan.t()}`.

  The shape is the one this function has always had. What changed in Aurora
  Meter 1.0 is that its content is time dependent: a plan id with a future-dated
  version answers with the version in force at `AuroraMeter.Clock.now/0`, and
  the future one appears here once its `effective_at` has passed. Use
  `versions/1` to see every version of one plan and `get/2` to pin one.
  """
  @spec all() :: %{optional(atom()) => Plan.t()}
  def all do
    module = plans_module()
    plans = module.__aurora_plans__()
    now = Clock.now()

    Map.new(module.__aurora_plan_index__(), fn {id, versions} ->
      {id, Map.fetch!(plans, {id, effective_version(versions, now)})}
    end)
  end

  @doc """
  Returns the plan id's effective version right now, or `nil` for an unknown id.

  "Effective" is the version with the greatest `effective_at` that is not in the
  future; a version with no `effective_at` sorts before every instant, and every
  plan id is required at compile time to have exactly one of those, so a known
  id always resolves.
  """
  @spec get(atom()) :: Plan.t() | nil
  def get(id) do
    module = plans_module()

    case Map.fetch(module.__aurora_plan_index__(), id) do
      {:ok, versions} ->
        Map.get(module.__aurora_plans__(), {id, effective_version(versions, Clock.now())})

      :error ->
        nil
    end
  end

  @doc """
  Returns one specific version of a plan, or `nil`.

  Compiled definitions first; then the snapshot registered in
  `aurora_meter_plan_versions`, which is what keeps a subscription readable
  after its version's block has been deleted from the plans module
  (`v1-release.md` 07.03). A version in neither is `nil`, and
  `AuroraMeter.Entitlements.plan/1` then falls back to the default plan and says
  so once.
  """
  @spec get(atom(), String.t()) :: Plan.t() | nil
  def get(id, version) when is_atom(id) and is_binary(version) do
    case Map.fetch(plans_module().__aurora_plans__(), {id, version}) do
      {:ok, plan} -> plan
      :error -> snapshot(id, version)
    end
  end

  def get(_id, _version), do: nil

  @doc """
  The version of `id` a subscription written before plan versions existed is on.

  It is the version whose block declares no `effective_at`, which is by
  definition the one that was in force before any other version of that id was
  written. A `plan_version` of NULL on a subscription row means "the base
  contract", never "whatever is current", which is what stops the window between
  the version 10 migration and the first `register!/0` from repricing anybody.
  """
  @spec base(atom()) :: Plan.t() | nil
  def base(id) do
    module = plans_module()

    with {:ok, versions} <- Map.fetch(module.__aurora_plan_index__(), id),
         {nil, version} <- List.first(versions, :none) do
      Map.get(module.__aurora_plans__(), {id, version})
    else
      _no_base -> nil
    end
  end

  @doc """
  Every known version of `id`, compiled and stored, oldest first.

  Ordered by `effective_at` with `nil` first, then by version string. A version
  that exists only as a stored snapshot (its block has been deleted from the
  plans module) is included, which is what makes this the list an admin screen
  can render without lying about history.
  """
  @spec versions(atom()) :: [Plan.t()]
  def versions(id) when is_atom(id) do
    module = plans_module()
    plans = module.__aurora_plans__()

    compiled =
      module.__aurora_plan_index__()
      |> Map.get(id, [])
      |> Enum.map(fn {_at, version} -> Map.fetch!(plans, {id, version}) end)

    known = MapSet.new(compiled, & &1.version)

    stored =
      id
      |> stored_versions()
      |> Enum.reject(&MapSet.member?(known, &1.version))

    (compiled ++ stored)
    |> Enum.map(&{&1.effective_at, &1.version, &1})
    |> Enum.sort(&version_order/2)
    |> Enum.map(&elem(&1, 2))
  end

  def versions(_id), do: []

  @doc """
  Every plan id the configured plans module declares.

  Cheaper than `Map.keys(all/0)`, which resolves an effective version per id
  only to throw it away.
  """
  @spec plan_ids() :: [atom()]
  def plan_ids, do: Map.keys(plans_module().__aurora_plan_index__())

  @doc """
  Whether **any** plan declares `feature`.

  Internal: it answers "is this a name the plans module knows at all", which is
  what separates `reason: :not_in_plan` from `reason: :unknown_feature` in
  `AuroraMeter.UndeclaredFeatureError` and what `AuroraMeter.track/4` reports as
  `declared:`. Whether a *tenant* is entitled to it is `AuroraMeter.entitled?/2`.

  A plans module compiled against an older Aurora Meter has no
  `__aurora_features__/0`; this folds over `all/0` for it instead.
  """
  @spec declared_anywhere?(atom()) :: boolean()
  def declared_anywhere?(feature) do
    module = plans_module()

    if Code.ensure_loaded?(module) and function_exported?(module, :__aurora_features__, 0) do
      MapSet.member?(module.__aurora_features__(), feature)
    else
      Enum.any?(all(), fn {_id, plan} -> Map.has_key?(plan.features, feature) end)
    end
  end

  @doc "Returns the feature config for `feature` in `plan_id`, or `nil`."
  @spec feature_config(atom(), atom()) :: Plan.feature_config() | nil
  def feature_config(plan_id, feature) do
    case get(plan_id) do
      nil -> nil
      plan -> Map.get(plan.features, feature)
    end
  end

  @doc """
  Returns the value of a `feature` declaration in `plan_id`, or `default`.

  Only `feature :name, value` declarations (booleans and integers) have a value;
  a `limit`, a `metered` feature, an undeclared feature or an unknown plan all
  return `default`. To resolve the plan from a tenant use
  `AuroraMeter.feature_value/3`.

  ## Examples

      iex> AuroraMeter.Plans.feature_value(:pro, :seats)
      5

      iex> AuroraMeter.Plans.feature_value(:free, :seats, 1)
      1

      iex> AuroraMeter.Plans.feature_value(:pro, :api_access)
      true

  """
  @spec feature_value(atom(), atom(), default) :: boolean() | non_neg_integer() | default
        when default: term()
  def feature_value(plan_id, feature, default \\ nil) do
    case feature_config(plan_id, feature) do
      {:feature, value} -> value
      _other -> default
    end
  end

  # -- the registry -----------------------------------------------------------

  @doc """
  Registers every compiled plan version and names the contract of every
  subscription written before plan versions existed.

  Called from `AuroraMeter.start_link/1` after the supervisor starts, and public
  so a host can run it from a release task before the rolling deploy when the
  subscriptions table is large. It is idempotent: a second run inserts nothing,
  compares the same fingerprints and assigns nothing.

  What it does, in order:

    1. inserts a snapshot for every compiled `{plan_id, version}` that has none,
       then **re-reads**, so a row another node inserted in between is observed
       rather than assumed;
    2. compares every stored fingerprint against the compiled one and raises
       `AuroraMeter.PlanVersionConflictError` for any that differ (or logs the
       same message when `plan_version_conflict: :warn`);
    3. assigns `plan_version` to rows that have none, in batches of
       #{@backfill_batch}, each batch its own transaction and each row taken
       with `FOR UPDATE SKIP LOCKED` so two booting nodes take disjoint batches
       instead of queueing behind each other. There is no checkpoint: the
       predicate `plan_version IS NULL` is its own checkpoint, so a `kill -9`
       between batches leaves a consistent prefix and the next run finishes the
       rest.

  It **never** changes a non-NULL `plan_id`, `plan_version` or
  `plan_fingerprint` (L17.4). Registration cannot move a tenant between
  contracts; only an explicit transition can, and that is a later release.

  Two things it refuses to fail on, because neither is a reason to stop a host
  from booting:

    * a storage adapter with no snapshot support, which logs one warning and
      leaves compiled code as the only authority (D12: reported, not silently
      ignored);
    * a repo that is not running yet, which logs one warning naming the
      boot-order requirement, flags the registry `:deferred` and retries once on
      the first snapshot miss.

  Do not call it inside a transaction of your own: the batch loop opens its own.
  """
  @spec register!() :: :ok
  def register! do
    compiled = compiled_snapshots()

    case list_stored(:all) do
      {:ok, stored} ->
        register(compiled, stored)

      {:error, {:unsupported, capability}} ->
        warn_unsupported(capability)
        mark(:unsupported)
        :ok

      {:error, :unavailable} ->
        warn_deferred()
        mark(:deferred)
        :ok
    end
  end

  @doc false
  # The registry's state on this node: `:ok`, `:deferred`, `:unsupported` or
  # `nil` when `register!/0` has never run here.
  @spec registry_state() :: :ok | :deferred | :unsupported | nil
  def registry_state, do: :persistent_term.get(@registry_key, nil)

  @doc false
  # Drops this node's registry state and snapshot cache. For the test suite and
  # for a host that swaps its plans module at runtime, which nothing supported
  # does.
  @spec reset_registry() :: :ok
  def reset_registry do
    :persistent_term.erase(@registry_key)
    :persistent_term.erase(@snapshots_key)
    :ok
  end

  defp register(compiled, stored) do
    stored_keys = MapSet.new(stored, &{&1.plan_id, &1.version})

    inserted =
      compiled
      |> Enum.reject(&MapSet.member?(stored_keys, {&1.plan_id, &1.version}))
      |> Enum.count(&insert_snapshot/1)

    # Re-read rather than assume: between the list and the insert another node
    # may have inserted the same row, and the fingerprint comparison has to be
    # made against what the database actually holds.
    {:ok, current} = list_stored(:all)

    compiled
    |> conflicts(current)
    |> report_conflicts!()

    report = assign_legacy()
    load_cache(current)
    mark(:ok)

    Logger.info(
      "AuroraMeter.Plans.register!: registered=#{inserted} known=#{length(current)} " <>
        "conflicts=0 assigned=#{report.assigned} orphan_plans=#{report.orphans}"
    )

    :ok
  end

  # A refused insert is reported rather than counted as a miss. Silently
  # registering nothing is the worst outcome available here: every entitlement
  # still resolves from compiled code, so nothing looks wrong until a version is
  # retired and a customer's contract turns out never to have been written down.
  defp insert_snapshot(attrs) do
    case Storage.put_plan_version(attrs) do
      {:ok, _row} ->
        true

      {:error, reason} ->
        Logger.error(
          "AuroraMeter.Plans.register!: could not register plan #{attrs.plan_id} version " <>
            "#{attrs.version}: #{inspect(reason)}. That version's definition is not stored, so " <>
            "deleting its block from the plans module would leave the tenants on it without a " <>
            "readable contract."
        )

        false
    end
  end

  defp compiled_snapshots do
    plans_module().__aurora_plans__()
    |> Enum.map(fn {{id, version}, plan} ->
      %{
        plan_id: Atom.to_string(id),
        version: version,
        fingerprint: plan.fingerprint,
        definition: Snapshot.encode(plan),
        effective_at: plan.effective_at
      }
    end)
    |> Enum.sort_by(&{&1.plan_id, &1.version})
  end

  defp conflicts(compiled, stored) do
    index = Map.new(stored, &{{&1.plan_id, &1.version}, &1})

    Enum.flat_map(compiled, fn attrs ->
      case Map.fetch(index, {attrs.plan_id, attrs.version}) do
        {:ok, row} -> compare(attrs, row)
        :error -> []
      end
    end)
  end

  defp compare(%{fingerprint: fingerprint}, %{fingerprint: fingerprint}), do: []

  defp compare(attrs, row) do
    stored_rendering = Snapshot.definition_version(row.definition)

    if stored_rendering != nil and stored_rendering != Snapshot.fingerprint_version() do
      # A change to the canonical form itself, not to the plan. It is logged
      # once and the row is left alone: reading it as a content conflict would
      # fail every host's boot on an Aurora Meter upgrade that changed nothing
      # commercial.
      ConfigSchema.warn_once(
        :plan_fingerprint_rendering,
        "#{attrs.plan_id}/#{attrs.version}",
        fn ->
          "AuroraMeter.Plans: the snapshot of plan #{attrs.plan_id} version #{attrs.version} " <>
            "was written with fingerprint_version #{stored_rendering} and this release " <>
            "renders version #{Snapshot.fingerprint_version()}. The stored definition is " <>
            "kept and the difference is not treated as a change to the plan."
        end
      )

      []
    else
      [
        %{
          plan_id: attrs.plan_id,
          version: attrs.version,
          stored_fingerprint: row.fingerprint,
          compiled_fingerprint: attrs.fingerprint
        }
      ]
    end
  end

  defp report_conflicts!([]), do: :ok

  defp report_conflicts!(conflicts) do
    case Config.plan_version_conflict() do
      :raise -> raise PlanVersionConflictError, conflicts: conflicts
      :warn -> Logger.error(PlanVersionConflictError.format(conflicts))
    end

    :ok
  end

  defp assign_legacy do
    Enum.reduce_while(Stream.cycle([:batch]), %{assigned: 0, orphans: 0}, fn _tick, acc ->
      case Storage.assign_legacy_plan_versions(@backfill_batch) do
        {:ok, %{assigned: 0}} ->
          {:halt, acc}

        {:ok, batch} ->
          {:cont,
           %{assigned: acc.assigned + batch.assigned, orphans: acc.orphans + batch.orphans}}

        {:error, reason} ->
          Logger.warning(
            "AuroraMeter.Plans.register!: assigning legacy plan versions stopped after " <>
              "#{acc.assigned} rows: #{inspect(reason)}. The next run resumes where this one " <>
              "stopped, because the predicate is `plan_version IS NULL`."
          )

          {:halt, acc}
      end
    end)
  end

  # -- snapshots --------------------------------------------------------------

  defp snapshot(id, version) do
    key = {Atom.to_string(id), version}

    case Map.fetch(snapshots(), key) do
      {:ok, :missing} -> nil
      {:ok, %Plan{} = plan} -> plan
      :error -> load_snapshot(key)
    end
  end

  defp snapshots, do: :persistent_term.get(@snapshots_key, %{})

  # A miss costs one query and one `:persistent_term.put/2` per node per
  # version, ever. Both halves matter: the put triggers a global GC scan, so a
  # version that is genuinely unknown is cached as `:missing` rather than
  # queried again on every entitlement read.
  defp load_snapshot({plan_id, _version} = key) do
    retry_deferred()

    loaded =
      case list_stored(plan_id) do
        {:ok, rows} -> Map.new(rows, &decoded/1)
        {:error, _reason} -> %{}
      end

    merged = Map.merge(snapshots(), loaded)
    merged = if Map.has_key?(merged, key), do: merged, else: negative(merged, key)

    :persistent_term.put(@snapshots_key, merged)

    case Map.get(merged, key) do
      %Plan{} = plan -> plan
      _missing -> nil
    end
  end

  defp negative(cache, key) when map_size(cache) < @snapshot_cache_limit,
    do: Map.put(cache, key, :missing)

  defp negative(cache, {plan_id, version}) do
    ConfigSchema.warn_once(:plan_snapshot_cache, "limit", fn ->
      "AuroraMeter.Plans: more than #{@snapshot_cache_limit} distinct plan versions have been " <>
        "asked for on this node (most recently #{plan_id} version #{version}) and none of them " <>
        "exists. The negative cache stops growing here, so those lookups query storage each " <>
        "time. A caller is almost certainly passing an unbounded version string to get/2."
    end)

    cache
  end

  defp load_cache(rows) do
    :persistent_term.put(@snapshots_key, Map.new(rows, &decoded/1))
    :ok
  end

  defp decoded(row) do
    case Snapshot.decode(
           row.plan_id,
           row.version,
           row.definition,
           row.effective_at,
           row.fingerprint
         ) do
      {:ok, plan, []} ->
        {{row.plan_id, row.version}, plan}

      {:ok, plan, dropped} ->
        warn_dropped(row, dropped)
        {{row.plan_id, row.version}, plan}

      {:error, _reason} ->
        {{row.plan_id, row.version}, :missing}
    end
  end

  defp warn_dropped(row, dropped) do
    ConfigSchema.warn_once(:plan_snapshot_dropped, "#{row.plan_id}/#{row.version}", fn ->
      "AuroraMeter.Plans: the stored snapshot of plan #{row.plan_id} version #{row.version} " <>
        "names #{inspect(dropped)}, which no atom on this node matches, so those entries are " <>
        "dropped from the resolved plan. Every entitlement function takes an atom, so no " <>
        "caller can ask about one of them; code that enumerates plan.features (the Pro usage " <>
        "reporter does, to decide what to bill) will not see them. Keep the module that " <>
        "declares the name loadable, or restore the plan version's block."
    end)
  end

  defp stored_versions(id) do
    plan_id = Atom.to_string(id)

    case list_stored(plan_id) do
      {:ok, rows} ->
        rows
        |> Enum.map(&decoded/1)
        |> Enum.flat_map(fn
          {_key, %Plan{} = plan} -> [plan]
          _missing -> []
        end)

      {:error, _reason} ->
        []
    end
  end

  # -- storage access ---------------------------------------------------------

  # `Storage.list_plan_versions/1` either answers, says the adapter cannot, or
  # cannot reach the database at all. Only the third is turned into a flag: a
  # host whose supervision tree starts Aurora Meter above its Repo used to get
  # no database work at boot at all, and gaining a hard boot-order dependency is
  # not something this unit is entitled to do to them.
  defp list_stored(scope) do
    if repo_ready?() do
      case Storage.list_plan_versions(scope) do
        {:error, {:unsupported, capability}} -> {:error, {:unsupported, capability}}
        rows when is_list(rows) -> {:ok, rows}
      end
    else
      {:error, :unavailable}
    end
  rescue
    error in [DBConnection.ConnectionError] ->
      Logger.debug("AuroraMeter.Plans: storage unreachable: #{Exception.message(error)}")
      {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp repo_ready? do
    case Config.repo() do
      repo when is_atom(repo) and not is_nil(repo) -> Process.whereis(repo) != nil
      _other -> false
    end
  end

  # One retry per node, guarded by the flag, so an unlucky supervision order
  # costs a warning and a single late registration rather than a failed boot.
  defp retry_deferred do
    if registry_state() == :deferred and repo_ready?() do
      mark(:retrying)
      register!()
    end

    :ok
  end

  defp mark(state), do: :persistent_term.put(@registry_key, state)

  defp warn_unsupported(capability) do
    ConfigSchema.warn_once(:plan_registry, "unsupported", fn ->
      "AuroraMeter.Plans.register!: the configured storage adapter " <>
        "#{inspect(Config.storage())} does not support #{inspect(capability)}, so plan " <>
        "definitions are not snapshotted. Compiled code is then the only authority: a plan " <>
        "version whose block is deleted becomes unreadable and the tenants on it fall back " <>
        "to the default plan. Keep every referenced version in code, or use an adapter that " <>
        "stores snapshots."
    end)
  end

  defp warn_deferred do
    ConfigSchema.warn_once(:plan_registry, "deferred", fn ->
      "AuroraMeter.Plans.register!: #{inspect(Config.repo())} is not running, so plan " <>
        "versions were not registered at boot. Entitlements resolve from compiled code and " <>
        "registration is retried once on the first lookup that needs a stored snapshot. " <>
        "Start AuroraMeter below your Repo in the supervision tree to register at boot."
    end)
  end

  # -- version resolution -----------------------------------------------------

  # The list is sorted ascending with `nil` first, so the last version whose
  # `effective_at` has passed is the effective one. A plan id is required at
  # compile time to have exactly one version with no `effective_at`, so the fold
  # always finds at least that one.
  defp effective_version(versions, now) do
    Enum.reduce(versions, nil, fn {at, version}, acc ->
      if effective?(at, now), do: version, else: acc
    end)
  end

  defp effective?(nil, _now), do: true
  defp effective?(%DateTime{} = at, now), do: DateTime.compare(at, now) != :gt

  defp sort_versions(versions) do
    Enum.sort(versions, fn {a, va}, {b, vb} -> version_order({a, va, nil}, {b, vb, nil}) end)
  end

  defp version_order({nil, va, _a}, {nil, vb, _b}), do: va <= vb
  defp version_order({nil, _va, _a}, {_at, _vb, _b}), do: true
  defp version_order({_at, _va, _a}, {nil, _vb, _b}), do: false

  defp version_order({a, va, _a}, {b, vb, _b}) do
    case DateTime.compare(a, b) do
      :lt -> true
      :gt -> false
      :eq -> va <= vb
    end
  end

  # -- compile-time validation ------------------------------------------------

  defp validate_version!(id, version) when is_binary(version) do
    if Regex.match?(@version_format, version) do
      version
    else
      raise ArgumentError,
            "plan #{inspect(id)} has invalid version #{inspect(version)}. A version is 1 to 32 " <>
              "characters matching #{inspect(@version_format)}: it is stored in a text column, " <>
              "quoted in operator messages and joined into a recurrence key, so it may not " <>
              "carry a separator."
    end
  end

  defp validate_version!(id, version) do
    raise ArgumentError,
          "plan #{inspect(id)} has invalid version #{inspect(version)}: a version is a string, " <>
            "for example version: \"2\"."
  end

  defp validate_effective_at!(_id, _version, nil), do: nil

  defp validate_effective_at!(_id, _version, %DateTime{time_zone: "Etc/UTC"} = at), do: at

  defp validate_effective_at!(id, version, at) do
    raise ArgumentError,
          "plan #{inspect(id)} version #{inspect(version)} has invalid :effective_at " <>
            "#{inspect(at)}. It is a UTC DateTime (for example " <>
            "~U[2026-10-01 00:00:00Z]) or nil, which means the version is effective from the " <>
            "beginning. Aurora Meter compares it against a UTC instant and does not convert " <>
            "time zones on a commercial boundary."
  end

  # What makes the canonical form in `AuroraMeter.Plans.Snapshot` unambiguous
  # rather than merely unlikely to collide. Checked where the name is declared.
  defp validate_renderable!(id, version, name) do
    if Snapshot.renderable?(Atom.to_string(name)) do
      :ok
    else
      raise ArgumentError,
            "plan #{inspect(id)} version #{inspect(version)} declares #{inspect(name)}, whose " <>
              "name contains an ASCII record or unit separator. Those two bytes separate the " <>
              "fields of the canonical form a plan fingerprint is taken over, so a name " <>
              "carrying one could make two different plans hash the same."
    end
  end

  defp validate_plan_versions!(module, id, grouped) do
    effective = Enum.map(grouped, fn {{_id, version}, plan} -> {plan.effective_at, version} end)

    duplicate_instants =
      effective
      |> Enum.map(&elem(&1, 0))
      |> then(&(&1 -- Enum.uniq(&1)))

    if duplicate_instants != [] do
      raise ArgumentError,
            "#{inspect(module)}: plan #{inspect(id)} has two versions effective at the same " <>
              "instant (#{inspect(hd(duplicate_instants))}). Which one a new subscription got " <>
              "would depend on declaration order, so it is refused here instead."
    end

    if not Enum.any?(effective, &match?({nil, _version}, &1)) do
      raise ArgumentError,
            "#{inspect(module)}: plan #{inspect(id)} has no base version. Give its earliest " <>
              "version no :effective_at. Without one, every tenant on #{inspect(id)} would " <>
              "resolve to the default plan until the earliest version's instant passed, and " <>
              "a subscription written before plan versions existed would have nothing to be " <>
              "assigned to."
    end

    :ok
  end

  @spec plans_module() :: module()
  defp plans_module, do: AuroraMeter.Config.plans()

  @spec validate_no_duplicates!(atom(), [{atom(), term()}]) :: :ok
  defp validate_no_duplicates!(id, features) do
    keys = Enum.map(features, &elem(&1, 0))
    dups = keys -- Enum.uniq(keys)

    if dups != [] do
      raise ArgumentError, "plan #{inspect(id)} declares duplicate feature(s): #{inspect(dups)}"
    end

    :ok
  end

  # One clause per valid shape, so the catch-all below is literally "anything
  # else is a mistake". Adding a feature kind means adding a clause here, which
  # is the point: an unvalidated kind would reach the runtime as a config no
  # `case` in the library matches.
  @spec validate_feature!(atom(), {atom(), term()}) :: :ok
  defp validate_feature!(_id, {_feature, {:limit, n, :hard}}) when is_integer(n) and n >= 0,
    do: :ok

  defp validate_feature!(_id, {_feature, {:metered, included, unit_price}})
       when is_integer(included) and included >= 0 and is_number(unit_price) and unit_price >= 0,
       do: :ok

  defp validate_feature!(_id, {_feature, {:counter}}), do: :ok

  defp validate_feature!(_id, {_feature, {:feature, value}}) when is_boolean(value), do: :ok

  defp validate_feature!(_id, {_feature, {:feature, value}})
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_feature!(id, {feature, config}),
    do: raise(ArgumentError, invalid_feature_message(id, feature, config))

  @spec invalid_feature_message(atom(), atom(), term()) :: String.t()
  defp invalid_feature_message(id, feature, config) do
    "plan #{inspect(id)} has invalid config for #{inspect(feature)}: #{inspect(config)}"
  end

  @spec validate_price!(atom(), term()) :: :ok
  defp validate_price!(_id, price) when is_integer(price) and price >= 0, do: :ok

  defp validate_price!(id, price),
    do: raise(ArgumentError, "plan #{inspect(id)} has invalid price: #{inspect(price)}")

  # -- recurring credits ------------------------------------------------------

  @spec build_recurring!(atom(), [{atom(), keyword()}]) :: [Plan.recurring_credit()]
  defp build_recurring!(_id, []), do: []

  defp build_recurring!(id, declarations) do
    validate_plan_name!(id)
    names = Enum.map(declarations, &elem(&1, 0))
    dups = names -- Enum.uniq(names)

    if dups != [] do
      raise ArgumentError,
            "plan #{inspect(id)} declares duplicate recurring_credits name(s): #{inspect(dups)}"
    end

    Enum.map(declarations, &build_recurring_credit!(id, &1))
  end

  defp build_recurring_credit!(id, {name, opts}) when is_list(opts) do
    validate_entitlement_name!(id, name)
    validate_keys!(id, name, opts)

    credit = %{
      name: name,
      amount: fetch_amount!(id, name, opts),
      category: fetch_category!(id, name, opts),
      rollover: fetch_rollover!(id, name, opts),
      expires: fetch_expires!(id, name, opts)
    }

    validate_combination!(id, credit)
    credit
  end

  defp build_recurring_credit!(id, {name, opts}) do
    raise ArgumentError,
          recurring_error(id, name, "takes a keyword list of options, got: #{inspect(opts)}")
  end

  defp validate_plan_name!(id) when is_atom(id) do
    if Regex.match?(@name_format, Atom.to_string(id)) do
      :ok
    else
      raise ArgumentError,
            "plan #{inspect(id)} declares recurring_credits, so its id becomes part of a " <>
              "recurrence key (\"recurring:<tenant>:<name>:<plan>:<version>:<period>\") and " <>
              "must be lower snake case, matching #{inspect(@name_format)}. A key is read by " <>
              "splitting on \":\", so an id carrying one cannot be read back."
    end
  end

  defp validate_entitlement_name!(id, name) when is_atom(name) and not is_nil(name) do
    if Regex.match?(@name_format, Atom.to_string(name)) do
      :ok
    else
      raise ArgumentError,
            recurring_error(
              id,
              name,
              "must be lower snake case, matching #{inspect(@name_format)}: the name becomes " <>
                "part of the recurrence key and a key is read by splitting on \":\""
            )
    end
  end

  defp validate_entitlement_name!(id, name),
    do: raise(ArgumentError, recurring_error(id, name, "must be an atom"))

  defp validate_keys!(id, name, opts) do
    case Keyword.keys(opts) -- @recurring_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              recurring_error(
                id,
                name,
                "has unknown option(s) #{inspect(unknown)}; the options are " <>
                  "#{inspect(@recurring_keys)}"
              )
    end
  end

  defp fetch_amount!(id, name, opts) do
    case Keyword.fetch(opts, :amount) do
      {:ok, amount} when is_integer(amount) and amount > 0 ->
        amount

      {:ok, other} ->
        raise ArgumentError,
              recurring_error(
                id,
                name,
                ":amount must be a positive integer of micro-dollars, got: #{inspect(other)}"
              )

      :error ->
        raise ArgumentError, recurring_error(id, name, "needs an :amount")
    end
  end

  defp fetch_category!(id, name, opts) do
    case Keyword.get(opts, :category, :promotional) do
      category when category in @categories ->
        category

      other ->
        raise ArgumentError,
              recurring_error(
                id,
                name,
                ":category must be one of #{inspect(@categories)}, got: #{inspect(other)}"
              )
    end
  end

  defp fetch_rollover!(id, name, opts) do
    case Keyword.get(opts, :rollover, 0) do
      rollover when is_integer(rollover) and rollover >= 0 ->
        rollover

      other ->
        raise ArgumentError,
              recurring_error(
                id,
                name,
                ":rollover must be a non-negative integer of micro-dollars, got: " <>
                  inspect(other)
              )
    end
  end

  defp fetch_expires!(id, name, opts) do
    case Keyword.get(opts, :expires, :period_end) do
      expires when expires in [:period_end, :never] ->
        expires

      {:seconds, seconds} when is_integer(seconds) and seconds > 0 ->
        {:seconds, seconds}

      other ->
        raise ArgumentError,
              recurring_error(
                id,
                name,
                ":expires must be :period_end, :never or {:seconds, n}, got: #{inspect(other)}"
              )
    end
  end

  defp validate_combination!(id, %{rollover: rollover, expires: expires, name: name})
       when rollover > 0 and expires != :period_end do
    raise ArgumentError,
          recurring_error(
            id,
            name,
            "declares rollover: #{rollover} with expires: #{inspect(expires)}. A rollover is " <>
              "what the previous period's lot did not spend before it expired, so it is " <>
              "defined only when the lot expires at the period boundary. With any other " <>
              "expiry the carried value would still be spendable on the old lot as well as " <>
              "granted again on the new one."
          )
  end

  defp validate_combination!(id, %{category: category, expires: expires, name: name})
       when category != :promotional and expires != :never do
    raise ArgumentError,
          recurring_error(
            id,
            name,
            "declares category: #{inspect(category)} with expires: #{inspect(expires)}. Only " <>
              "promotional grants expire: AuroraMeter.Schema.CreditTransaction refuses an " <>
              "`expires_at` on any other category, and v1-release.md 10.1 says paid top-ups " <>
              "do not expire unless their own contract says so. Use expires: :never."
          )
  end

  defp validate_combination!(id, %{category: :promotional, expires: :never, name: name}) do
    IO.warn(
      recurring_error(
        id,
        name,
        "is a promotional allowance that never expires, so every period's grant stays " <>
          "spendable for ever and the tenant accumulates them. That is legal and is almost " <>
          "always a mistake; use expires: :period_end, or category: :paid if the money is " <>
          "really theirs to keep."
      )
    )

    :ok
  end

  defp validate_combination!(_id, _credit), do: :ok

  defp recurring_error(id, name, detail),
    do: "plan #{inspect(id)}: recurring_credits #{inspect(name)} #{detail}"
end
