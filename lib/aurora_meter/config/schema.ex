defmodule AuroraMeter.Config.Schema do
  @moduledoc false
  # The conventions every Aurora Meter configuration schema follows, in one
  # place so the core schema and (from build unit 04c) the Pro schema cannot
  # drift apart. Nothing here is public: Pro adopts the conventions by passing
  # its own `NimbleOptions` schema and its own OTP application name, never by
  # depending on this module.
  #
  # Four things live here.
  #
  #   * `mode/0`, the release strictness constant. Two behaviours (unknown
  #     configuration keys, and the transition-era warnings the facade emits)
  #     have to warn in the 0.5.x transition release and fail in 1.0. There is
  #     deliberately no configuration key for it: the mode is derived from the
  #     package's own version at compile time, so cutting 1.0.0 flips every one
  #     of them in a single, reviewable diff.
  #   * `reserved?/1` and `validate!/4`, the whole-environment validator. Before
  #     this, `Keyword.take/2` discarded every key that was not in the schema,
  #     so a typo was ignored for ever (open finding C1).
  #   * `ensure_exports!/4` and `required_callbacks/1`, the module-behaviour
  #     check. A behaviour's own `behaviour_info/1` is read rather than a
  #     hand-written list: the clock's callback list grew twice in one day and
  #     a copied list went stale both times.
  #   * `warn_once/3`, the per-node warn-once registry the transition-mode
  #     warnings share, with a bounded `:persistent_term` footprint.

  require Logger

  @version Mix.Project.config()[:version]
  @strict_from "1.0.0-rc.0"
  @policy if Version.compare(@version, @strict_from) == :lt, do: :warn, else: :deny

  # Above this many distinct entries in one warning scope, a node logs one
  # suppression line and stops writing terms. A host that generates feature
  # names dynamically therefore cannot grow the registry without bound.
  @warn_limit 128

  # `:included_applications` is added to every application environment by OTP
  # itself. `:ecto_repos` is the conventional key Ecto's own mix tasks read out
  # of the same application. Anything whose atom name starts with "Elixir." is
  # a module key, which is how repo configuration is written under the host's
  # (or, in this package's own test environment, the library's) application:
  # `config :aurora_meter, AuroraMeter.TestRepo, [...]`.
  @reserved [:included_applications, :ecto_repos]

  @typedoc "Release strictness: warn in the transition release, fail in 1.0."
  @type mode :: :transition | :strict

  @typedoc "What a module-typed key has to export."
  @type contract :: {:behaviour, module()} | {:exports, [{atom(), arity()}], String.t()}

  @doc """
  The strictness this build was compiled at.

  It is computed from `@version`, which `Mix.Project.config/0` fixed in the beam
  file when the dependency was compiled, rather than returned as a literal. A
  literal would let the compiler prove every `mode() == :strict` branch dead and
  warn on it, which in a package built with `warnings_as_errors` means the
  transition branches could not be written at all.
  """
  @spec mode() :: mode()
  def mode, do: mode(@version)

  @doc false
  @spec mode(String.t()) :: mode()
  def mode(version) do
    if Version.compare(version, @strict_from) == :lt, do: :transition, else: :strict
  end

  @doc "The package version `mode/0` was derived from."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The default `undeclared_feature_policy`, which is one of two mode-dependent defaults."
  @spec default_undeclared_feature_policy() :: :warn | :deny
  def default_undeclared_feature_policy, do: @policy

  @doc """
  The default `plan_version_conflict`.

  The other mode-dependent default, and the same argument: refusing to boot
  because a plan definition was edited is the right answer, and it is not the
  right answer to spring on a host in a patch release. 0.5.x warns, 1.0 raises.
  """
  @spec default_plan_version_conflict() :: :warn | :raise
  def default_plan_version_conflict,
    do: if(Version.compare(@version, @strict_from) == :lt, do: :warn, else: :raise)

  @doc "How many distinct entries one warning scope records before it suppresses the rest."
  @spec warn_limit() :: pos_integer()
  def warn_limit, do: @warn_limit

  @doc "Whether `key` belongs to something other than Aurora Meter's own schema."
  @spec reserved?(atom()) :: boolean()
  def reserved?(key) when is_atom(key) do
    key in @reserved or String.starts_with?(Atom.to_string(key), "Elixir.")
  end

  @doc "Splits an application environment into `{reserved, candidate}`."
  @spec split_reserved(keyword()) :: {keyword(), keyword()}
  def split_reserved(env), do: Enum.split_with(env, fn {key, _value} -> reserved?(key) end)

  @doc "The candidate keys `schema` does not declare."
  @spec unknown_keys(keyword(), NimbleOptions.t()) :: [atom()]
  def unknown_keys(candidate, schema), do: Keyword.keys(candidate) -- Keyword.keys(schema.schema)

  @doc """
  Validates the whole application environment of `app` against `schema`.

  Reserved keys are set aside first. In `:strict` mode an unknown key is left in
  the list, so `NimbleOptions` itself rejects it with its own "did you mean";
  in `:transition` mode it is reported once and dropped, so a 0.5.x upgrade
  warns rather than refusing to boot.
  """
  @spec validate!(atom(), keyword(), NimbleOptions.t(), mode()) :: keyword()
  def validate!(app, env, schema, mode) do
    {_reserved, candidate} = split_reserved(env)

    case {mode, unknown_keys(candidate, schema)} do
      {_mode, []} ->
        NimbleOptions.validate!(candidate, schema)

      {:strict, _unknown} ->
        NimbleOptions.validate!(candidate, schema)

      {:transition, unknown} ->
        Logger.warning(unknown_message(app, unknown, schema))
        candidate |> Keyword.drop(unknown) |> NimbleOptions.validate!(schema)
    end
  end

  @doc """
  The default of every optional key in `schema`, as a map.

  An accessor reads its default from here, so a default is written once (in the
  schema) and cannot drift from what the reader returns (open finding C10).
  """
  @spec defaults(NimbleOptions.t()) :: %{atom() => term()}
  def defaults(schema) do
    schema.schema
    |> Enum.reject(fn {_key, opts} -> Keyword.get(opts, :required, false) end)
    |> Map.new(fn {key, opts} -> {key, Keyword.get(opts, :default)} end)
  end

  @doc "The transition-mode report for unknown keys, naming the nearest schema key for each."
  @spec unknown_message(atom(), [atom()], NimbleOptions.t()) :: String.t()
  def unknown_message(app, unknown, schema) do
    known = Keyword.keys(schema.schema)

    "config #{inspect(app)}: unknown " <>
      pluralise(length(unknown), "key", "keys") <>
      " " <>
      Enum.map_join(unknown, ", ", &describe_unknown(&1, known)) <>
      ". This version ignores " <>
      pluralise(length(unknown), "it", "them") <>
      "; Aurora Meter 1.0 will refuse to boot. Fix the spelling or remove the key."
  end

  @doc """
  Raises unless `module` is loadable and exports everything `contract` requires.

  This raises in both modes on purpose. A module that does not export a callback
  the library calls would crash on first use anyway, there is no false positive
  to weigh against, and boot is the honest place for it to fail.
  """
  @spec ensure_exports!(atom(), atom(), module(), contract()) :: :ok
  def ensure_exports!(app, key, module, contract) do
    {callbacks, requirement} = expand(contract)

    if not Code.ensure_loaded?(module) do
      raise ArgumentError,
            "config #{inspect(app)}, #{key}: #{inspect(module)} could not be loaded. " <>
              "It must be #{requirement}."
    end

    # **Safe without its own `Code.ensure_loaded?/1`, and here is why**, because
    # the next person will ask (repair unit R8, and `open-findings.md` X426 for
    # what happens when the answer is no).
    #
    # `function_exported?/3` answers false for a module that merely has not been
    # loaded, and a host-configured module is the least likely one in the system
    # to be loaded already: nothing has referenced it when `AuroraMeter.Config`
    # validates it at boot. The load happens in the statement above, which
    # **raises** when it fails, so by this line the module is loaded or this
    # function has already stopped. The guard is the preceding statement rather
    # than the same expression, which is the one shape the AST guard in
    # `AuroraMeter.ExportedIdiomTest` cannot see, so it is listed there by name
    # with this reason. `config_schema_cold_test.exs` proves it from a process
    # that has never touched the module, in both directions.
    Enum.each(callbacks, fn {fun, arity} ->
      if not function_exported?(module, fun, arity) do
        raise ArgumentError,
              "config #{inspect(app)}, #{key}: #{inspect(module)} does not export " <>
                "#{fun}/#{arity}. It must be #{requirement}."
      end
    end)
  end

  @doc """
  The callbacks `behaviour` declares and does not mark optional.

  Read from the behaviour rather than restated at the call site: `AuroraMeter.Clock`
  went from two callbacks to three to four inside one day, and both times a
  hand-copied list was the thing that went stale.
  """
  @spec required_callbacks(module()) :: [{atom(), arity()}]
  def required_callbacks(behaviour) do
    Enum.sort(
      behaviour.behaviour_info(:callbacks) -- behaviour.behaviour_info(:optional_callbacks)
    )
  end

  @doc """
  Logs `message` the first time `key` is seen in `scope` on this node.

  The dedupe lives in `:persistent_term`, so a read costs nothing on the check
  path, a write happens at most once per distinct key, and the memory survives a
  `AuroraMeter.Store` restart. After `warn_limit/0` distinct keys one scope logs
  a single suppression line and stops writing.
  """
  @spec warn_once(atom(), term(), (-> String.t())) :: :ok
  def warn_once(scope, key, message) when is_function(message, 0) do
    seen = {__MODULE__, :warn_once, scope, key}

    if :persistent_term.get(seen, nil) == nil, do: record_warning(scope, seen, message)

    :ok
  end

  @doc "Forgets every `warn_once/3` entry on this node. For tests."
  @spec reset_warnings!() :: :ok
  def reset_warnings! do
    Enum.each(:persistent_term.get(), fn {key, _value} ->
      if warning_key?(key), do: :persistent_term.erase(key)
    end)
  end

  @spec record_warning(atom(), tuple(), (-> String.t())) :: :ok
  defp record_warning(scope, seen, message) do
    counter = {__MODULE__, :warn_count, scope}
    count = :persistent_term.get(counter, 0)

    cond do
      count < @warn_limit ->
        :persistent_term.put(seen, true)
        :persistent_term.put(counter, count + 1)
        Logger.warning(message.())

      count == @warn_limit ->
        :persistent_term.put(counter, count + 1)
        Logger.warning(suppression_message(scope))

      true ->
        :ok
    end
  end

  @spec warning_key?(term()) :: boolean()
  defp warning_key?({__MODULE__, :warn_once, _scope, _key}), do: true
  defp warning_key?({__MODULE__, :warn_count, _scope}), do: true
  defp warning_key?(_other), do: false

  @spec suppression_message(atom()) :: String.t()
  defp suppression_message(scope) do
    "AuroraMeter: further #{scope} warnings are suppressed on this node after " <>
      "#{@warn_limit} distinct entries. Run `mix aurora_meter.features` to list " <>
      "what a configuration references but no plan declares."
  end

  @spec expand(contract()) :: {[{atom(), arity()}], String.t()}
  defp expand({:behaviour, behaviour}) do
    {required_callbacks(behaviour), "a module implementing #{inspect(behaviour)}"}
  end

  defp expand({:exports, callbacks, requirement}), do: {callbacks, requirement}

  @spec describe_unknown(atom(), [atom()]) :: String.t()
  defp describe_unknown(key, known) do
    case nearest(key, known) do
      nil -> inspect(key)
      match -> "#{inspect(key)} (did you mean #{inspect(match)}?)"
    end
  end

  @spec nearest(atom(), [atom()]) :: atom() | nil
  defp nearest(key, known) do
    name = Atom.to_string(key)

    known
    |> Enum.map(&{&1, String.jaro_distance(name, Atom.to_string(&1))})
    |> Enum.filter(fn {_candidate, distance} -> distance > 0.8 end)
    |> Enum.max_by(fn {_candidate, distance} -> distance end, fn -> nil end)
    |> case do
      nil -> nil
      {candidate, _distance} -> candidate
    end
  end

  @spec pluralise(non_neg_integer(), String.t(), String.t()) :: String.t()
  defp pluralise(1, singular, _plural), do: singular
  defp pluralise(_count, _singular, plural), do: plural
end
