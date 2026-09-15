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

  alias AuroraMeter.Plan

  # The entitlement name and the plan id both become part of a recurrence key,
  # and a key is parsed by splitting on `:`. Validated where the string is
  # invented rather than where it is read (`open-findings.md` X272).
  @name_format ~r/^[a-z][a-z0-9_]*$/

  @recurring_keys [:amount, :category, :rollover, :expires]

  @categories [:promotional, :paid, :adjustment]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import AuroraMeter.Plans,
        only: [
          plan: 2,
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
    # Every feature name any plan declares, folded once at compile time and
    # embedded as a literal. `AuroraMeter.track/4` asks this on its hot path, so
    # it must not rebuild a set per call.
    features =
      env.module
      |> Module.get_attribute(:aurora_plans, [])
      |> Enum.flat_map(fn {_id, plan} -> Map.keys(plan.features) end)
      |> MapSet.new()
      |> Macro.escape()

    quote do
      @doc false
      @spec __aurora_plans__() :: %{optional(atom()) => AuroraMeter.Plan.t()}
      def __aurora_plans__, do: @aurora_plans |> Enum.reverse() |> Map.new()

      @doc false
      @spec __aurora_features__() :: MapSet.t()
      def __aurora_features__, do: unquote(features)
    end
  end

  @doc "Declares a plan. Contains `price`, `limit`, `metered`, `counter` and `feature` calls."
  defmacro plan(id, do: block) do
    quote do
      Module.delete_attribute(__MODULE__, :aurora_features)
      Module.register_attribute(__MODULE__, :aurora_features, accumulate: true)
      Module.delete_attribute(__MODULE__, :aurora_recurring_credits)
      Module.register_attribute(__MODULE__, :aurora_recurring_credits, accumulate: true)
      Module.put_attribute(__MODULE__, :aurora_price, 0)

      unquote(block)

      @aurora_plans AuroraMeter.Plans.__build__(
                      unquote(id),
                      Module.get_attribute(__MODULE__, :aurora_price),
                      Module.get_attribute(__MODULE__, :aurora_features),
                      Module.get_attribute(__MODULE__, :aurora_recurring_credits)
                    )
    end
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
  @spec __build__(atom(), non_neg_integer(), [{atom(), Plan.feature_config()}], [
          {atom(), keyword()}
        ]) :: {atom(), Plan.t()}
  def __build__(id, price, features_rev, recurring_rev) do
    features = Enum.reverse(features_rev)
    validate_no_duplicates!(id, features)
    Enum.each(features, &validate_feature!(id, &1))
    validate_price!(id, price)
    recurring = build_recurring!(id, Enum.reverse(recurring_rev || []))

    {id,
     %Plan{
       id: id,
       price: price,
       features: Map.new(features),
       recurring_credits: recurring
     }}
  end

  @doc "Returns all plans as `%{id => Plan.t()}` from the configured plans module."
  @spec all() :: %{optional(atom()) => Plan.t()}
  def all, do: plans_module().__aurora_plans__()

  @doc "Returns a single plan by id, or `nil`."
  @spec get(atom()) :: Plan.t() | nil
  def get(id), do: Map.get(all(), id)

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
