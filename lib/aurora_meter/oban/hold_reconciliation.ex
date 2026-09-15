if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.HoldReconciliation do
    @moduledoc """
    Asks the configured `AuroraMeter.Credits.HoldReconciler` about holds that
    are still open past a cutoff, and applies what it says.

    One call to `AuroraMeter.Credits.reconcile_holds/1` and nothing else.

        config :my_app, Oban,
          plugins: [{Oban.Plugins.Cron, crontab: [
            {"*/15 * * * *", AuroraMeter.Oban.HoldReconciliation}
          ]}]

    **With no `:credits_hold_reconciler` configured this worker keeps every
    hold**, which is the default and is why scheduling it changes nothing until
    a host writes a policy. Read
    `AuroraMeter.Credits.HoldReconciler` before configuring one: age is not
    evidence that work was abandoned.

    ## Job arguments

    | Key | Default | Meaning |
    |---|---|---|
    | `"older_than_seconds"` | `3600` | Only holds open longer than this are examined. |
    | `"limit"` | `200` | The most holds one **batch** examines. |
    | `"max_batches"` | `10` | Batches one job runs before returning. |
    | `"reference_prefix"` | none | Narrow to one kind of work. |
    | `"tenant"` | none | Sweep one tenant. |

        %{"older_than_seconds" => 86_400, "reference_prefix" => "job:"}
        |> AuroraMeter.Oban.HoldReconciliation.new()
        |> Oban.insert()

    **The cursor is never a job argument** (L05c-1). It lives in
    `aurora_meter_checkpoints` under `"hold_reconciliation:global"`, so two jobs
    for this worker read the same position rather than each carrying its own
    stale copy.

    ## Pausing

        AuroraMeter.Operations.pause("hold_reconciliation:global")

    The next batch boundary cancels the job with `{:cancel, :paused}`, leaving
    the cursor where the last batch left it.

    ## The cutoff is pinned for the length of a scan

    `older_than_seconds` selects the candidate set, and the set moves as time
    passes. A scan spanning several jobs stores the cutoff it started with in
    its checkpoint beside the cursor, so a resumed cursor points into the set it
    came from. When the scan completes, the cursor is cleared and the next run
    takes a fresh cutoff.

    ## The cutoff is a duration, and it is an hours-scale one

    `older_than_seconds` is the one duration in this worker. It **selects
    candidates and decides nothing**: having passed the cutoff makes a hold a
    hold the host is asked about, never a hold that is released. The default is
    an hour and the smallest value that makes sense is minutes, which is far
    outside the sub-second range in which a shared clock cannot be trusted to
    order two instants (`AuroraMeter.Clock`).

    The cutoff is measured with `AuroraMeter.Clock.now/0` rather than
    `db_now/0`, because the other side of the comparison is a hold row's
    `inserted_at`, and until the ledger's rows are stamped by the database that
    is a node's wall clock. Both sides of a time comparison come from the same
    clock, and which clock that is follows from where the other side came from.

    ## Running it twice

    Harmless, and the operation's doing rather than this worker's. Two nodes
    sweeping at the same instant both list a hold and both ask the host about
    it, and at most one terminal transition happens: the decision is applied
    through `AuroraMeter.Credits.settle/3` or `AuroraMeter.Credits.release/2`,
    which re-read
    `status = 'pending'` under the hold row's own `FOR UPDATE`. The loser is
    told `:already_closed` and counted. There is no lease and no fence, so there
    is nothing a clock could invert.

    A host callback that raises, hangs or answers nonsense keeps the hold, and
    so does a run this worker is killed in the middle of.

    Without Oban, call `AuroraMeter.Credits.reconcile_holds/1` from whatever
    scheduler you do have. See [the scheduler map](scheduler.md).
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 3,
      unique: [period: :infinity, states: @incomplete]

    alias AuroraMeter.Clock
    alias AuroraMeter.Credits
    alias AuroraMeter.Operations

    @operation "hold_reconciliation:global"

    @default_older_than_seconds 3_600
    @default_limit 200
    @default_max_batches 10

    @doc "The checkpoint name this worker pauses and resumes under."
    @spec operation() :: String.t()
    def operation, do: @operation

    @doc """
    Reconciles pending holds in bounded batches and returns `{:ok, report}`.

    `{:cancel, :paused}` when the operation is paused. `{:error, reason}` when
    the listing itself fails, which fails the job and lets Oban retry it. It
    never raises on an operation error and never matches on the report's shape:
    a later release may add keys to it.

    ## Examples

        {:ok, report} =
          AuroraMeter.Oban.HoldReconciliation.perform(%Oban.Job{
            args: %{"older_than_seconds" => 3600}
          })

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      max_batches = integer_arg(args, "max_batches", @default_max_batches)

      @operation
      |> Operations.run_batches([max_batches: max_batches], &batch(&1, args))
      |> result()
    end

    defp batch(cursor, args) do
      cutoff = pinned_cutoff(cursor, args)

      opts =
        args
        |> options()
        |> Keyword.put(:older_than, cutoff)
        |> Keyword.put(:after, keyset(cursor))

      case Credits.reconcile_holds(opts) do
        {:ok, report} ->
          {:ok, %{cursor: next_cursor(cutoff, report.cursor), counts: counts(report)}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @doc false
    @spec options(map()) :: keyword()
    def options(args) when is_map(args) do
      seconds = Map.get(args, "older_than_seconds", @default_older_than_seconds)

      [older_than: DateTime.add(Clock.now(), -seconds, :second), limit: @default_limit]
      |> put("limit", Map.get(args, "limit"))
      |> put("reference_prefix", Map.get(args, "reference_prefix"))
      |> put("tenant", Map.get(args, "tenant"))
    end

    # `Clock.now/0` at the start of a scan, and the scan's own stored cutoff for
    # every batch after that. `now/0` rather than `db_now/0` because the other
    # side of the comparison is a hold row's `inserted_at`, which Ecto stamps
    # from the node clock until 06a moves the ledger's own timestamps into the
    # database (`open-findings.md` X181). Both sides come from the same clock,
    # which is the rule.
    defp pinned_cutoff(%{"older_than" => iso}, _args) when is_binary(iso) do
      case DateTime.from_iso8601(iso) do
        {:ok, at, _offset} -> at
        _unparseable -> cutoff_from(nil)
      end
    end

    defp pinned_cutoff(_absent, args), do: cutoff_from(Map.get(args, "older_than_seconds"))

    # A negative value is accepted, and is not a mistake: it is a cutoff in the
    # future, which is how a caller says "every open hold, including the one
    # written a moment ago". 05a's tests use it and so does an operator draining
    # a backlog on purpose.
    defp cutoff_from(seconds) when is_integer(seconds),
      do: DateTime.add(Clock.now(), -seconds, :second)

    defp cutoff_from(_other),
      do: DateTime.add(Clock.now(), -@default_older_than_seconds, :second)

    defp keyset(%{"inserted_at" => at, "id" => id}) when is_binary(at) and is_binary(id) do
      case DateTime.from_iso8601(at) do
        {:ok, parsed, _offset} -> {parsed, id}
        _unparseable -> nil
      end
    end

    defp keyset(_absent), do: nil

    defp next_cursor(_cutoff, nil), do: nil

    defp next_cursor(cutoff, {inserted_at, id}) do
      %{
        "older_than" => DateTime.to_iso8601(cutoff),
        "inserted_at" => DateTime.to_iso8601(inserted_at),
        "id" => id
      }
    end

    defp counts(report) do
      Map.new(
        [:examined, :kept, :released, :settled, :already_closed, :failed],
        &{Atom.to_string(&1), Map.get(report, &1, 0)}
      )
    end

    defp result({:ok, report}), do: {:ok, report}
    defp result({:paused, _report}), do: {:cancel, :paused}
    defp result({:error, reason}), do: {:error, reason}

    # A job argument is an id or a bounded integer and nothing else (task 05.05).
    defp integer_arg(args, key, default) do
      case Map.get(args, key) do
        value when is_integer(value) and value > 0 -> value
        _absent_or_invalid -> default
      end
    end

    defp put(opts, _key, nil), do: opts
    defp put(opts, "limit", value), do: Keyword.put(opts, :limit, value)
    defp put(opts, "reference_prefix", value), do: Keyword.put(opts, :reference_prefix, value)
    defp put(opts, "tenant", value), do: Keyword.put(opts, :tenant, value)
  end
end
