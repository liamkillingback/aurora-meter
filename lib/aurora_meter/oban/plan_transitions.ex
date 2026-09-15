if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.PlanTransitions do
    @moduledoc """
    Applies scheduled plan changes whose effective date has arrived, by calling
    `AuroraMeter.Subscriptions.apply_due_transitions/1`.

    **That operation is not in this release.** `AuroraMeter.Subscriptions`
    itself is, which is why the availability check asks whether the *function*
    is exported and not only whether the module is loaded: a module that exists
    without the function it is wanted for is exactly this case, and
    `Code.ensure_loaded?/1` alone would answer yes.

    Until the operation lands:

      * `AuroraMeter.Oban.cron_entries/1` does not return it, so nothing
        schedules it;
      * running it by hand cancels the job with `{:cancel, :not_implemented}`.

    Recommended schedule once it lands: `"*/5 * * * *"`. A plan change that has
    come due is a change to what a customer is allowed to do, so the delay
    between its effective time and its application is what a host is choosing
    here.

    Nothing about this module needs editing when the operation appears.
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: :infinity, states: @incomplete]

    @operation {AuroraMeter.Subscriptions, :apply_due_transitions, 1}

    @doc """
    Applies one batch of due transitions, or cancels with `:not_implemented`
    while the operation is absent.

    ## Examples

        {:cancel, :not_implemented} =
          AuroraMeter.Oban.PlanTransitions.perform(%Oban.Job{args: %{}})

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

    # Build unit 07b owns the argument mapping along with the operation.
    defp options(_args), do: []
  end
end
