if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.RecurringGrants do
    @moduledoc """
    Issues recurring credit grants that have come due, by calling
    `AuroraMeter.Credits.Recurrences.run/1`.

    **That operation is not in this release.** The worker ships anyway, so that
    a crontab and an installer have the complete registry from the start and no
    host ever writes a module name that does not resolve. Until the operation
    lands:

      * `AuroraMeter.Oban.cron_entries/1` does not return it, so nothing
        schedules it;
      * running it by hand cancels the job with `{:cancel, :not_implemented}`,
        which is visible in the Oban dashboard and is not retried.

    Recommended schedule once it lands: `"7 * * * *"`. Hourly, and at seven
    minutes past rather than on the hour, because the hour boundary is where
    every other scheduled thing in a host already is.

    Nothing about this module needs editing when the operation appears: the
    availability check is evaluated at call time.
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: :infinity, states: @incomplete]

    @operation {AuroraMeter.Credits.Recurrences, :run, 1}

    @doc """
    Runs one recurrence sweep, or cancels with `:not_implemented` while the
    operation is absent.

    ## Examples

        {:cancel, :not_implemented} =
          AuroraMeter.Oban.RecurringGrants.perform(%Oban.Job{args: %{}})

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

    # Build unit 06d owns the argument mapping along with the operation. Until
    # then there is nothing to map and an empty option list is the honest
    # translation of "no arguments".
    defp options(_args), do: []
  end
end
