if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.RecurringGrants do
    @moduledoc """
    Issues recurring credit grants that have come due, by calling
    `AuroraMeter.Credits.Recurrences.run/1`.

    Scheduled `"7 * * * *"` by `AuroraMeter.Oban.cron_entries/1`: hourly, and at
    seven minutes past rather than on the hour, because the hour boundary is
    where every other scheduled thing in a host already is. Hourly is frequent
    enough that a period boundary is picked up within the hour, and the run is
    a sequence of no-ops for every tenant whose period has already been granted.

    ## Arguments

    `%{"limit" => 5_000}`, and any of `"batch"`, `"max_periods"` and `"tenant"`.
    Ids and scalars only, never a policy and never an amount
    (`architecture-map.md` section 6): the entitlement is read from the plan at
    run time, or from the period's stored policy snapshot, so a job that sat in
    a queue across a deploy cannot grant yesterday's amount from its own
    arguments.

    Size `"limit"` so one period's worth of runs visits every entitled tenant
    at least once. The default of 500 is a safe floor, not a recommendation:

        crontab: [{"7 * * * *", AuroraMeter.Oban.RecurringGrants, args: %{"limit" => 5_000}}]

    A host without Oban calls `AuroraMeter.Credits.Recurrences.run/1` from its
    own scheduler and loses nothing.
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    # An hour, which is the documented `7 * * * *` schedule rather than twice
    # it: the rule the other workers follow is capped at an hour, and this one
    # reaches the cap.
    #
    # It was `:infinity`, and `@incomplete` contains `:executing`, so a job left
    # `executing` by a node that died deduplicated every future enqueue for ever
    # (`open-findings.md` X486). At the cap the period and the schedule coincide,
    # which is the worst ratio of any worker in either package: the tick landing
    # exactly at the lapse is still refused, so one node death costs **two**
    # skipped hours rather than one. It is survivable because a grant is due
    # from its period and never from the run that noticed it, so the third tick
    # issues everything the first two would have.
    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: 3_600, states: @incomplete]

    @operation {AuroraMeter.Credits.Recurrences, :run, 1}

    @doc """
    Runs one recurrence sweep, or cancels with `:not_implemented` on a build
    that does not have the operation.

    ## Examples

        :ok = AuroraMeter.Oban.RecurringGrants.perform(%Oban.Job{args: %{"limit" => 100}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      if AuroraMeter.Oban.available?(@operation) do
        {module, function, _arity} = @operation
        AuroraMeter.Oban.result(apply(module, function, [options(args)]))
      else
        {:cancel, :not_implemented}
      end
    end

    # Only the keys the operation declares, and only when the job carries them,
    # so an argument map a host wrote by hand cannot smuggle in an option the
    # schema would reject and fail every tick. An unknown key is ignored here
    # rather than raising, for the same reason: a job that cannot be fixed by
    # editing the crontab is a job that fails until somebody finds it.
    defp options(args) when is_map(args) do
      for key <- [:limit, :batch, :max_periods, :tenant],
          value = Map.get(args, Atom.to_string(key)),
          do: {key, value}
    end

    defp options(_args), do: []
  end
end
