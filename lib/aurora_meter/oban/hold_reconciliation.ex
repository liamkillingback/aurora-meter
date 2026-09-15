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
    | `"limit"` | `200` | The most holds one run examines. |
    | `"reference_prefix"` | none | Narrow to one kind of work. |
    | `"tenant"` | none | Sweep one tenant. |

        %{"older_than_seconds" => 86_400, "reference_prefix" => "job:"}
        |> AuroraMeter.Oban.HoldReconciliation.new()
        |> Oban.insert()

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

    @default_older_than_seconds 3_600

    @doc """
    Reconciles one page of pending holds and returns `{:ok, report}`.

    Returns `{:error, reason}` when the listing itself fails, which fails the
    job and lets Oban retry it. It never raises on an operation error and never
    matches on the report's shape: a later release may add keys to it.

    ## Examples

        {:ok, report} =
          AuroraMeter.Oban.HoldReconciliation.perform(%Oban.Job{
            args: %{"older_than_seconds" => 3600}
          })

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      AuroraMeter.Oban.result(Credits.reconcile_holds(options(args)))
    end

    @doc false
    @spec options(map()) :: keyword()
    def options(args) when is_map(args) do
      seconds = Map.get(args, "older_than_seconds", @default_older_than_seconds)

      [older_than: DateTime.add(Clock.now(), -seconds, :second)]
      |> put("limit", Map.get(args, "limit"))
      |> put("reference_prefix", Map.get(args, "reference_prefix"))
      |> put("tenant", Map.get(args, "tenant"))
    end

    defp put(opts, _key, nil), do: opts
    defp put(opts, "limit", value), do: Keyword.put(opts, :limit, value)
    defp put(opts, "reference_prefix", value), do: Keyword.put(opts, :reference_prefix, value)
    defp put(opts, "tenant", value), do: Keyword.put(opts, :tenant, value)
  end
end
