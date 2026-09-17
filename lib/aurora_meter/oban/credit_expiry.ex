if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.CreditExpiry do
    @moduledoc """
    Expires promotional credit grants whose date has passed, in bounded batches.

    The work is `AuroraMeter.Credits.expire_due/2` and nothing else. The worker
    opens no transaction, takes no lock and reads no clock to decide anything:
    `expire_due/2` compares against a persisted `expires_at`, so the instant it
    compares with comes from the database (`AuroraMeter.Clock`).

        config :my_app, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [
            {"*/30 * * * *", AuroraMeter.Oban.CreditExpiry}
          ]}]

    Recommended schedule `"*/30 * * * *"`, which is what
    `AuroraMeter.Oban.cron_entries/1` returns. Nothing depends on the frequency
    for correctness: a grant expires the first time a run sees it is due, and
    the delay between the date passing and the run is the schedule's period.

    ## Job arguments

    | Key | Default | Meaning |
    |---|---|---|
    | `"batch_size"` | `#{200}` | Grants examined per batch. |
    | `"max_batches"` | `#{10}` | Batches one job runs before returning. |

    Both are bounded integers and neither is a cursor. **The cursor is never a
    job argument** (L05c-1): it lives in `aurora_meter_checkpoints` under
    `"credit_expiry:global"`, so two jobs for this worker read the same position
    and the second one resumes where the first got to rather than restarting
    from a stale copy of its own.

    ## Pausing

        AuroraMeter.Operations.pause("credit_expiry:global")

    The next batch boundary cancels the job with `{:cancel, :paused}`, leaving
    the cursor where the last committed batch left it.
    `AuroraMeter.Operations.resume/1` and the next tick carry on from there.

    ## The scan's instant is pinned

    The candidate set is `expires_at <= now`, which moves. A scan that spans
    several jobs stores the `now` it started with in its checkpoint beside the
    cursor and hands the same one back until the scan finishes, so a resumed
    cursor points into the set it came from. When the scan completes the cursor
    is cleared and the next run takes a fresh instant.

    ## Running it twice

    Harmless, and that is the operation's doing rather than this worker's. Two
    ticks of one minute, a rescued job, or two nodes sweeping at the same
    instant all call `expire_due/2` twice. Each expiry re-reads `expired_at`
    under the grant row's own `FOR UPDATE` and refuses when it is already set,
    so the second caller expires nothing and counts it as skipped.

    The `unique` option below is defence in depth and not the guarantee. It
    saves the duplicate run's work; it is not what keeps the ledger right.

    Without Oban, call `AuroraMeter.Credits.expire_due/2` from whatever
    scheduler you do have, or drive the same loop with
    `AuroraMeter.Operations.run_batches/3`. See [the scheduler
    map](scheduler.md).
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    # An hour: twice the documented `*/30 * * * *` schedule.
    #
    # It was `:infinity`, and `@incomplete` contains `:executing`, so a job left
    # `executing` by a node that died deduplicated every future enqueue for ever
    # (`open-findings.md` X486). One node death now costs at most 90 minutes:
    # the hour of the period, plus up to half an hour waiting for the next
    # `*/30` tick, because the uniqueness lapsing is not itself an enqueue. A
    # second run inside the period is still refused; admitting one past it costs
    # nothing at all, for the reason the paragraph above gives, which is the
    # same reason removing the option entirely would be safe.
    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: 3_600, states: @incomplete]

    alias AuroraMeter.Clock
    alias AuroraMeter.Credits
    alias AuroraMeter.Operations

    @operation "credit_expiry:global"

    @default_batch_size 200
    @default_max_batches 10

    @doc "The checkpoint name this worker pauses and resumes under."
    @spec operation() :: String.t()
    def operation, do: @operation

    @doc """
    Expires due grants in bounded batches and returns `{:ok, report}`.

    `{:cancel, :paused}` when the operation is paused; `{:error, reason}` when
    the listing or the checkpoint write fails, which fails the job and lets Oban
    retry it.

    ## Examples

        {:ok, report} = AuroraMeter.Oban.CreditExpiry.perform(%Oban.Job{args: %{}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      batch_size = integer_arg(args, "batch_size", @default_batch_size)
      max_batches = integer_arg(args, "max_batches", @default_max_batches)

      @operation
      |> Operations.run_batches([max_batches: max_batches], &batch(&1, batch_size))
      |> result()
    end

    # One batch: read the pinned instant and the keyset position out of the
    # cursor, run one bounded page, and hand back the next position.
    #
    # A `rescue` rather than an `{:error, reason}` clause, and the reason is
    # measured rather than stylistic. `AuroraMeter.Credits.expire_due/2` returns
    # `{:ok, report}` and only that: it counts a failing grant and carries on,
    # so the only way it ends badly is a raise from the listing query itself.
    # Elixir 1.20's type checker and Dialyzer both prove the `{:error, _}` clause
    # unreachable and refuse it (`open-findings.md` X197), so the mapping L05a-1
    # asks for goes here: a raise, including a `MatchError` should the return
    # widen later, fails the job cleanly and Oban retries it, rather than
    # crashing the executor with a stack trace nobody mapped.
    defp batch(cursor, batch_size) do
      now = pinned_instant(cursor)

      {:ok, report} = Credits.expire_due(now, limit: batch_size, after: keyset(cursor))

      {:ok, %{cursor: next_cursor(now, report.cursor), counts: counts(report)}}
    rescue
      exception -> {:error, exception}
    end

    # `db_now/0` at the start of a scan, and the scan's own stored instant for
    # every batch after that. Not `now/0`: the other side of the comparison is a
    # persisted `expires_at`, so the clock is the database's.
    defp pinned_instant(%{"now" => iso}) when is_binary(iso) do
      case DateTime.from_iso8601(iso) do
        {:ok, at, _offset} -> at
        _unparseable -> Clock.db_now()
      end
    end

    defp pinned_instant(_absent), do: Clock.db_now()

    defp keyset(%{"expires_at" => at, "id" => id}) when is_binary(at) and is_binary(id) do
      case DateTime.from_iso8601(at) do
        {:ok, parsed, _offset} -> {parsed, id}
        _unparseable -> nil
      end
    end

    defp keyset(_absent), do: nil

    defp next_cursor(_now, nil), do: nil

    defp next_cursor(now, {expires_at, id}) do
      %{
        "now" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(expires_at),
        "id" => id
      }
    end

    defp counts(report) do
      %{
        "examined" => report.examined,
        "expired" => report.expired,
        "skipped" => report.skipped,
        "failed" => report.failed
      }
    end

    defp result({:ok, report}), do: {:ok, report}
    defp result({:paused, _report}), do: {:cancel, :paused}
    defp result({:error, reason}), do: {:error, reason}

    # A job argument is an id or a bounded integer and nothing else (task 05.05).
    # Anything that is not a positive integer is not coerced: it falls back to
    # the default, so a malformed argument cannot make a batch unbounded.
    defp integer_arg(args, key, default) do
      case Map.get(args, key) do
        value when is_integer(value) and value > 0 -> value
        _absent_or_invalid -> default
      end
    end
  end
end
