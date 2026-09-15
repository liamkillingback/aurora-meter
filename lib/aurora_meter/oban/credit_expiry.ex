if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.CreditExpiry do
    @moduledoc """
    Expires promotional credit grants whose date has passed, on a schedule.

    One call to `AuroraMeter.Credits.expire_due/1` and nothing else. The worker
    opens no transaction, takes no lock and reads no clock: `expire_due/1` takes
    the database's own clock, because the other side of the comparison is a
    persisted `expires_at`.

        config :my_app, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [
            {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}
          ]}]

    Recommended schedule `"*/30 * * * *"`, which is what
    `AuroraMeter.Oban.cron_entries/1` returns. Nothing depends on the frequency
    for correctness: a grant expires the first time a run sees it is due, and
    the delay between the date passing and the run is the schedule's period.

    ## Running it twice

    Harmless, and that is the operation's doing rather than this worker's. Two
    ticks of one minute, a rescued job, or two nodes sweeping at the same
    instant all call `expire_due/1` twice. Each expiry re-reads `expired_at`
    under the grant row's own `FOR UPDATE` and refuses when it is already set,
    so the second caller expires nothing and returns `{:ok, 0}`.

    The `unique` option below is defence in depth and not the guarantee. It
    saves the duplicate run's work; it is not what keeps the ledger right.

    Without Oban, call `AuroraMeter.Credits.expire_due/1` from whatever
    scheduler you do have. See [the scheduler map](scheduler.md).
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: :infinity, states: @incomplete]

    alias AuroraMeter.Credits

    @doc """
    Expires every due grant and returns `{:ok, count}`.

    Takes no job arguments. A fault in the database raises, which fails the job
    and lets Oban retry it; a re-run is the duplicate case above.

    ## Examples

        {:ok, count} = AuroraMeter.Oban.CreditExpiry.perform(%Oban.Job{args: %{}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{}), do: AuroraMeter.Oban.result(Credits.expire_due())
  end
end
