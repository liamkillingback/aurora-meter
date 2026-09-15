if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.Retention do
    @moduledoc """
    Deletes the disposable operational rows `AuroraMeter.Retention` allows, in
    bounded batches.

    The work is `AuroraMeter.Retention.prune/1` and nothing else. The worker
    opens no transaction, takes no lock and reads no clock: every cutoff is
    computed by the database inside the statement that uses it.

        config :my_app, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [
            {"40 3 * * *", AuroraMeter.Oban.Retention}
          ]}]

    Recommended schedule `"40 3 * * *"`, which is what
    `AuroraMeter.Oban.cron_entries/1` returns. Nothing depends on the frequency
    for correctness: a row that is still eligible tomorrow is deleted tomorrow.

    > #### Do not schedule this until every node writes a heartbeat {: .warning}
    >
    > A flush receipt is deleted only when every node's `"flush:<node>"`
    > heartbeat proves no node can still retry a batch from before the cutoff,
    > and a fleet that has not been upgraded yet writes none. Deploy first,
    > confirm one row per node with `AuroraMeter.Retention.status/0`, then add
    > the crontab entry. `AuroraMeter.Retention` refuses rather than guessing if
    > you do it in the other order, which is the safe direction, but the refusal
    > is easier to read before it is a surprise.

    ## Job arguments

    | Key | Default | Meaning |
    |---|---|---|
    | `"only"` | every allow-list table | Which tables to consider, by name. Narrows; never widens. |
    | `"batch_size"` | `#{1_000}` | Rows per `DELETE` statement. |
    | `"max_items"` | `#{50_000}` | Rows one job removes per table before returning. |

    Every one is a bounded integer or an allow-list name, and neither a cursor
    nor a cutoff is a job argument. `"only"` is validated against the allow list
    by `AuroraMeter.Retention`, so a name outside it fails the job rather than
    widening what may be deleted.

    ## Pausing

        AuroraMeter.Operations.pause("retention:flush_receipts")
        AuroraMeter.Operations.pause("retention:replay_checkpoints")

    One operation per table, because pausing receipt pruning while leaving the
    replay rows alone is a thing an operator actually wants. A paused table is
    reported as a `:paused` reason and the job still returns `{:ok, report}`:
    the other tables were pruned, and a pause is not a failure to retry.

    ## Running it twice

    Harmless. A `DELETE` is idempotent: the second run's statement finds the
    rows gone and removes nothing. There is no cursor to get stale, because the
    scan advances by doing the work rather than by remembering a position.

    Without Oban, call `AuroraMeter.Retention.prune/1` from whatever scheduler
    you do have. See [the scheduler map](scheduler.md) and
    [Retention](retention.md).
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: 3_600, states: @incomplete]

    alias AuroraMeter.Retention

    @doc """
    The checkpoint names this worker pauses and resumes under, one per table.

    ## Examples

        iex> AuroraMeter.Oban.Retention.operations()
        ["retention:flush_receipts", "retention:replay_checkpoints"]

    """
    @spec operations() :: [String.t()]
    def operations, do: Enum.map(Retention.tables(), &Retention.operation/1)

    @doc """
    Prunes and returns `{:ok, report}`.

    `{:ok, {:blocked, report, reasons}}` when a table could not be pruned: a
    node's heartbeat says it may still hold an old batch, or an operator paused
    the operation. Neither is a failure, so neither fails the job, and both are
    in the return for an operator reading Oban's completed jobs.

    `{:error, reason}` only when the mechanism itself failed, which Oban
    retries.

    ## Examples

        {:ok, _} = AuroraMeter.Oban.Retention.perform(%Oban.Job{args: %{}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      args |> opts() |> Retention.prune() |> map_result()
    end

    @doc false
    # Exported and widely typed, which is `AuroraMeter.Pro.Credits.Expirer`'s
    # shape and L05a-1's rule: no `perform/1` hard-matches its operation's
    # return. A shape this function does not know fails the job cleanly rather
    # than crashing the executor with a `MatchError` nobody mapped.
    @spec map_result(term()) :: {:ok, term()} | {:error, term()}
    def map_result({:ok, report}), do: {:ok, report}
    def map_result({:blocked, report, reasons}), do: {:ok, {:blocked, report, reasons}}
    def map_result(other), do: {:error, {:unexpected_return, other}}

    # A job argument is a bounded integer or an allow-list name and nothing
    # else (task 05.05). Anything that is not a positive integer falls back to
    # the default, so a malformed argument cannot make a batch unbounded or a
    # window wider.
    @spec opts(map()) :: keyword()
    defp opts(args) do
      [only: only(args)] ++
        integer_arg(args, "batch_size", :batch_size) ++
        integer_arg(args, "max_items", :max_items)
    end

    defp only(args) do
      names = Map.new(Retention.tables(), &{to_string(&1), &1})

      case Map.get(args, "only") do
        list when is_list(list) ->
          # An unknown name is **kept** rather than dropped, so
          # `AuroraMeter.Retention` raises on it and the job fails loudly. A
          # silently narrowed list would look like a successful prune of
          # nothing.
          Enum.map(list, &Map.get(names, to_string(&1), &1))

        _absent ->
          Retention.tables()
      end
    end

    defp integer_arg(args, key, option) do
      case Map.get(args, key) do
        value when is_integer(value) and value > 0 -> [{option, value}]
        _absent_or_invalid -> []
      end
    end
  end
end
