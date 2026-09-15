# The whole namespace is compiled only when Oban is installed. There is no
# `else` branch on purpose: a host without Oban has no `AuroraMeter.Oban`
# module at all, and `Code.ensure_loaded?(AuroraMeter.Oban)` is the documented
# way to ask. Same shape as `lib/aurora_meter/components.ex` for
# `Phoenix.Component` (invariant I20, decision D03).
if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.ConfigError do
    @moduledoc """
    Raised by `AuroraMeter.Oban.validate!/1` when a host's Oban configuration
    cannot run Aurora Meter's workers.

    The message lists every problem found in one pass, because a host that fixes
    one line and boots again to find the next has been told half of what the
    check already knew.
    """

    defexception [:message, :problems]

    @typedoc "One problem, as a sentence naming the offending key."
    @type problem :: String.t()

    @type t :: %__MODULE__{message: String.t(), problems: [problem()]}
  end

  defmodule AuroraMeter.Oban do
    @moduledoc """
    Optional Oban workers for Aurora Meter's scheduled operations, and the
    recommended crontab for them.

    This module and everything under it exist **only when `oban` is installed**.
    Aurora Meter does not depend on Oban: every operation a worker here wraps is
    a public function a host can call from any scheduler, or from `iex`. See
    [the scheduler map](scheduler.md) for the direct-call recipes and
    for the Aurora Meter Pro half of the inventory.

        config :my_app, Oban,
          repo: MyApp.Repo,
          queues: [aurora_meter: 5],
          plugins: [{Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries()}]

    ## What a worker is, and what it is not

    A worker here is a `perform/1` that calls one operation and maps its result
    onto an Oban result. It opens no transaction, takes no lock, holds no state
    between runs and reads no clock to decide anything. Every guarantee lives in
    the operation.

    That is deliberate, and it is what makes running two of them safe. Aurora
    Meter does not assume a job runs a single time: a cron plugin can tick twice
    across a leader change, a rescued job runs again, and two nodes can both be
    told to sweep. What each operation guarantees instead is that a second run
    finds the work already done and says so. `AuroraMeter.Credits.expire_due/1`
    re-reads `expired_at` under the grant row's own `FOR UPDATE`;
    `AuroraMeter.Credits.reconcile_holds/1` re-reads `status` under the hold
    row's. Neither uses a lease, a fence or a duration, so neither can be
    inverted by a clock that steps backwards.

    The `unique` option on each worker is therefore defence in depth and not the
    guarantee. Removing it wastes work; it does not move money.

    ## Availability

    `cron_entries/1` returns an entry only for a worker whose operation is
    compiled into this build. Two of the six workers wrap operations that
    Aurora Meter 1.0 adds after this module: until those land, the worker exists
    (so a crontab written by hand cannot name a module that is missing), it is
    absent from `cron_entries/1`, and running it by hand cancels the job with
    `{:cancel, :not_implemented}` rather than failing it repeatedly.
    """

    alias AuroraMeter.Oban.ConfigError

    @queue :aurora_meter

    @pro_expiry "Elixir.AuroraMeter.Pro.Credits.Expirer"

    # The single source of truth for `cron_entries/1`, `validate!/1`, the
    # scheduler map's table (a test compares them) and build unit 05c's
    # installer. `{worker, {module, function, arity}, default schedule or nil,
    # description}`.
    #
    # A worker with no default schedule is one an operator starts, not one a
    # crontab runs. A projection rebuild is the example: it is a deliberate act
    # with a checkpoint, never something that should begin because a minute
    # elapsed.
    @registry [
      {AuroraMeter.Oban.CreditExpiry, {AuroraMeter.Credits, :expire_due, 1}, "*/30 * * * *",
       "Expires promotional grants whose expiry date has passed."},
      {AuroraMeter.Oban.HoldReconciliation, {AuroraMeter.Credits, :reconcile_holds, 1},
       "*/15 * * * *",
       "Asks the configured hold reconciler about holds still open past a cutoff."},
      {AuroraMeter.Oban.EventsReplay, {AuroraMeter.Events.Replay, :run, 1}, nil,
       "Rebuilds a projection generation from the event log. Operator run."},
      {AuroraMeter.Oban.RecurringGrants, {AuroraMeter.Credits.Recurrences, :run, 1}, "7 * * * *",
       "Issues recurring credit grants that have come due."},
      {AuroraMeter.Oban.PlanTransitions, {AuroraMeter.Subscriptions, :apply_due_transitions, 1},
       "*/5 * * * *", "Applies scheduled plan changes whose effective date has arrived."},
      {AuroraMeter.Oban.Retention, {AuroraMeter.Retention, :prune, 1}, "40 3 * * *",
       "Deletes the disposable operational rows the retention allow list names."}
    ]

    @typedoc "One crontab entry, in the shape `Oban.Plugins.Cron` accepts."
    @type cron_entry :: {String.t(), module()}

    @doc """
    The queue every Aurora Meter worker declares, core and Pro alike.

    One queue, because the two packages' workers are the same kind of work and a
    host that sizes one has sized both.

    ## Examples

        iex> AuroraMeter.Oban.queue()
        :aurora_meter

    """
    @spec queue() :: atom()
    def queue, do: @queue

    @doc """
    The recommended crontab entries for the workers this build can run.

    Pass the result straight to `Oban.Plugins.Cron`. An entry appears only when
    the operation behind it is compiled into this build and the worker has a
    schedule, so a crontab built from this can never name a job that will cancel
    itself.

    Options:

      * `:include`: only these workers. Each is a module or its short name
        (`:credit_expiry` for `AuroraMeter.Oban.CreditExpiry`).
      * `:exclude`: everything but these, in the same two forms.
      * `:schedules`: a map of worker (or short name) to cron expression,
        overriding the default. Naming a worker that has no default schedule
        here is how an operator deliberately schedules one; nothing else
        returns it.

    ## Examples

        iex> AuroraMeter.Oban.cron_entries()
        [
          {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry},
          {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation},
          {"40 3 * * *", AuroraMeter.Oban.Retention}
        ]

        iex> AuroraMeter.Oban.cron_entries(include: [:credit_expiry])
        [{"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}]

        iex> AuroraMeter.Oban.cron_entries(
        ...>   exclude: [AuroraMeter.Oban.HoldReconciliation, AuroraMeter.Oban.Retention],
        ...>   schedules: %{credit_expiry: "0 4 * * *"}
        ...> )
        [{"0 4 * * *", AuroraMeter.Oban.CreditExpiry}]

    """
    @spec cron_entries(keyword()) :: [cron_entry()]
    def cron_entries(opts \\ []) do
      include = normalise(Keyword.get(opts, :include))
      exclude = normalise(Keyword.get(opts, :exclude, []))
      schedules = schedules(Keyword.get(opts, :schedules, %{}))

      for {worker, operation, default, _description} <- @registry,
          schedule = Map.get(schedules, worker, default),
          is_binary(schedule),
          include == nil or worker in include,
          worker not in exclude,
          available?(operation),
          do: {schedule, worker}
    end

    @doc """
    Checks a host's Oban configuration against what these workers need, and
    raises `AuroraMeter.Oban.ConfigError` listing everything that is wrong.

    It reads **configuration**, never a running Oban instance, so it has no
    boot-ordering trap: call it from your `Application.start/2` before the
    children list, whether Oban starts before or after Aurora Meter.

        def start(_type, _args) do
          if Code.ensure_loaded?(AuroraMeter.Oban) do
            AuroraMeter.Oban.validate!(otp_app: :my_app)
          end

          Supervisor.start_link(children, opts)
        end

    Options: either `:config` (the host's Oban keyword list) or `:otp_app` with
    an optional `:name` (default `Oban`) to look it up, plus an optional
    `:queue` (default `#{inspect(@queue)}`) and an optional `:env` (default
    `Mix.env/0` where Mix exists, and `nil` in a release, where there is no
    environment to read).

    What it refuses:

      * `:repo` missing, or not the repo `AuroraMeter.Config.repo/0` returns;
      * the Aurora Meter queue absent from `:queues`, or its limit zero;
      * a `:crontab` entry naming an `AuroraMeter.Oban.*` module this build does
        not have;
      * a `:crontab` naming one worker twice, or naming both
        `AuroraMeter.Oban.CreditExpiry` and `AuroraMeter.Pro.Credits.Expirer`,
        which would sweep expiry twice for one result;
      * a `Oban.Plugins.Cron` `:timezone` that `DateTime.now/1` cannot resolve,
        which is the same test Oban itself applies, run early enough to name the
        key;
      * `:testing` set to `:inline` or `:manual` outside the test environment,
        which silently stops every scheduled job.

    It cannot see a second `Oban.Plugins.Cron` running under a different Oban
    instance name. That case is documented in the scheduler map.

    ## Examples

        config = [
          repo: MyApp.Repo,
          queues: [aurora_meter: 5],
          plugins: [{Oban.Plugins.Cron, crontab: AuroraMeter.Oban.cron_entries()}]
        ]

        :ok = AuroraMeter.Oban.validate!(config: config)

    """
    @spec validate!(keyword()) :: :ok
    def validate!(opts \\ []) do
      config = fetch_config!(opts)
      queue = Keyword.get(opts, :queue, @queue)

      env = Keyword.get(opts, :env, mix_env())

      problems =
        check_repo(config) ++
          check_queue(config, queue) ++
          check_crontab(config) ++ check_timezone(config) ++ check_testing(config, env)

      if problems == [] do
        :ok
      else
        raise ConfigError, message: message(problems), problems: problems
      end
    end

    # -- the registry ----------------------------------------------------------

    @doc false
    @spec __registry__() :: [{module(), mfa(), String.t() | nil, String.t()}]
    def __registry__, do: @registry

    @doc false
    # The one place a worker's `perform/1` turns an operation's return into an
    # Oban result, and the reason no `perform/1` in this namespace writes
    # `{:ok, _} = operation()`. A hard match makes a future `{:error, reason}`
    # crash the job with a `MatchError`; this fails it cleanly, so Oban retries
    # it and the reason reaches the job row. It lives here rather than in each
    # worker because a mapping written five times is a mapping that will differ
    # in five ways (lower-level invariant L05a-1).
    @spec result(term()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def result(:ok), do: :ok
    def result({:ok, value}), do: {:ok, value}
    def result({:error, reason}), do: {:error, reason}
    def result({:cancel, reason}), do: {:cancel, reason}
    def result(other), do: {:error, {:unexpected_return, other}}

    @doc false
    @spec short_name(module()) :: atom()
    def short_name(worker) do
      worker
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()
    end

    @doc false
    @spec available?(mfa()) :: boolean()
    def available?({module, function, arity}) do
      # `Code.ensure_loaded?/1` first, and it is not decoration:
      # `function_exported?/3` answers `false` for a module that is compiled but
      # not yet loaded, which would hide an operation that is present.
      Code.ensure_loaded?(module) and function_exported?(module, function, arity)
    end

    defp normalise(nil), do: nil

    defp normalise(names) when is_list(names) do
      lookup = Map.new(@registry, fn {worker, _, _, _} -> {short_name(worker), worker} end)
      Enum.map(names, fn name -> Map.get(lookup, name, name) end)
    end

    defp schedules(map) when is_map(map) do
      lookup = Map.new(@registry, fn {worker, _, _, _} -> {short_name(worker), worker} end)
      Map.new(map, fn {name, schedule} -> {Map.get(lookup, name, name), schedule} end)
    end

    # -- configuration ---------------------------------------------------------

    defp fetch_config!(opts) do
      case {Keyword.fetch(opts, :config), Keyword.fetch(opts, :otp_app)} do
        {{:ok, config}, _} when is_list(config) ->
          config

        {:error, {:ok, otp_app}} ->
          Application.get_env(otp_app, Keyword.get(opts, :name, Oban), [])

        _ ->
          raise ArgumentError,
                "AuroraMeter.Oban.validate!/1 needs :config (the host's Oban keyword " <>
                  "list) or :otp_app (to read it from), got: #{inspect(opts)}"
      end
    end

    defp check_repo(config) do
      configured = Application.get_env(:aurora_meter, :repo)

      case {Keyword.get(config, :repo), configured} do
        {_, nil} ->
          [
            "`config :aurora_meter, :repo` is not set, so there is nothing to compare " <>
              "the Oban `:repo` against. Configure Aurora Meter first."
          ]

        {nil, repo} ->
          ["the Oban configuration has no `:repo`. Aurora Meter needs #{inspect(repo)}."]

        {same, same} ->
          []

        {other, repo} ->
          [
            "the Oban `:repo` is #{inspect(other)} and Aurora Meter's is #{inspect(repo)}. " <>
              "Jobs would be enqueued in one database and the tenant data read from " <>
              "another."
          ]
      end
    end

    defp check_queue(config, queue) do
      case Keyword.get(config, :queues, []) do
        false ->
          ["`:queues` is `false`, so no job of any kind runs on this node."]

        queues when is_list(queues) ->
          check_limit(Keyword.get(queues, queue), queue)

        other ->
          ["`:queues` is #{inspect(other)}, which is not a keyword list."]
      end
    end

    defp check_limit(nil, queue) do
      ["`:queues` does not include #{inspect(queue)}. Add `#{queue}: 5` to it."]
    end

    defp check_limit(limit, queue) when is_integer(limit) do
      if limit > 0 do
        []
      else
        ["the #{inspect(queue)} queue's limit is #{limit}, so its jobs never start."]
      end
    end

    defp check_limit(opts, queue) when is_list(opts), do: check_limit(opts[:limit], queue)

    defp check_limit(other, queue) do
      ["the #{inspect(queue)} queue is configured as #{inspect(other)}, which has no limit."]
    end

    defp check_crontab(config) do
      workers = config |> crontabs() |> Enum.flat_map(&entry_workers/1)

      check_loaded(workers) ++ check_duplicates(workers) ++ check_conflict(workers)
    end

    defp crontabs(config) do
      config
      |> Keyword.get(:plugins, [])
      |> List.wrap()
      |> Enum.flat_map(fn
        {Oban.Plugins.Cron, plugin_opts} -> [Keyword.get(plugin_opts, :crontab, [])]
        _ -> []
      end)
    end

    defp entry_workers(crontab) do
      Enum.flat_map(crontab, fn
        {_expression, worker} -> [worker]
        {_expression, worker, _job_opts} -> [worker]
        _ -> []
      end)
    end

    defp check_loaded(workers) do
      for worker <- workers,
          String.starts_with?(Atom.to_string(worker), "Elixir.AuroraMeter.Oban."),
          not Code.ensure_loaded?(worker),
          do:
            "the `:crontab` names #{inspect(worker)}, which this build of Aurora Meter " <>
              "does not have. Build the crontab from `AuroraMeter.Oban.cron_entries/1`."
    end

    defp check_duplicates(workers) do
      for {worker, count} <- Enum.frequencies(workers),
          count > 1,
          do:
            "the `:crontab` names #{inspect(worker)} #{count} times, so every tick runs " <>
              "it #{count} times."
    end

    # Compared as a string, never as an alias: core must not reference a Pro
    # module, and this is a name a host wrote in its own configuration.
    defp check_conflict(workers) do
      names = MapSet.new(workers, &Atom.to_string/1)

      if MapSet.member?(names, "Elixir.AuroraMeter.Oban.CreditExpiry") and
           MapSet.member?(names, @pro_expiry) do
        [
          "the `:crontab` registers both AuroraMeter.Oban.CreditExpiry and " <>
            "AuroraMeter.Pro.Credits.Expirer. They expire the same grants, so the " <>
            "sweep runs twice for one result. Keep the core worker and remove the " <>
            "Pro entry, which is deprecated."
        ]
      else
        []
      end
    end

    # The same predicate Oban applies in `Oban.Validation`, run early enough to
    # name the key. A time zone other than "Etc/UTC" needs a time zone database
    # configured; without one this refuses, and so would Oban a moment later.
    defp check_timezone(config) do
      for {Oban.Plugins.Cron, plugin_opts} <- List.wrap(Keyword.get(config, :plugins, [])),
          timezone = plugin_opts[:timezone],
          not resolvable?(timezone),
          do:
            "the `Oban.Plugins.Cron` `:timezone` is #{inspect(timezone)}, which " <>
              "`DateTime.now/1` cannot resolve: #{inspect(resolution(timezone))}. Cron " <>
              "would not start."
    end

    defp resolvable?(timezone), do: is_binary(timezone) and match?({:ok, _}, resolution(timezone))

    defp resolution(timezone) when is_binary(timezone), do: DateTime.now(timezone)
    defp resolution(other), do: {:error, {:not_a_timezone, other}}

    # `Mix` is absent from a release, and then there is no environment to read
    # and nothing to say. Checking anyway would be a check that raises in the
    # one place it was meant to protect.
    defp check_testing(config, env) do
      testing = Keyword.get(config, :testing)

      if testing in [:inline, :manual] and env not in [nil, :test] do
        [
          "`:testing` is #{inspect(testing)} in the #{inspect(env)} environment. " <>
            "No queue runs and no plugin ticks; every scheduled operation stops."
        ]
      else
        []
      end
    end

    defp mix_env do
      if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0), do: Mix.env()
    end

    defp message(problems) do
      "Aurora Meter cannot run its workers with this Oban configuration:\n\n" <>
        Enum.map_join(problems, "\n", &("  * " <> &1)) <>
        "\n\nSee AuroraMeter.Oban.validate!/1 and the scheduler map."
    end
  end
end
