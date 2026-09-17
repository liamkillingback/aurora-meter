if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.PlanTransitions do
    @moduledoc """
    Applies scheduled plan changes whose effective date has arrived, by calling
    `AuroraMeter.Subscriptions.apply_due_transitions/1`.

    Recommended schedule `"*/5 * * * *"`, which is what
    `AuroraMeter.Oban.cron_entries/1` returns. **That interval is the delay a
    host is choosing between a plan change's effective time and its
    application**, and between the two the tenant is entitled under the old
    plan: conservative for a downgrade, visible to the customer for an upgrade.
    A host that wants a tighter bound registers a more frequent entry or calls
    the operation directly. See [Plans](plans.md) for the measured lag.

    Job arguments, all optional, all mapping onto the operation's options:

      * `"limit"`: tenants per batch (default 500);
      * `"batches"`: batches per job (default 10, after which the remainder is
        left for the next tick);
      * `"tenant"`: force one tenant.

    Running two of these at once, from two nodes, applies each transition once:
    every effect in the operation is an update conditional on the transition
    still being `pending` (invariant I16). The `unique` option below reduces
    duplicate work and is never the guarantee.
    """

    @incomplete Oban.Job.states() -- [:completed, :discarded, :cancelled]

    # Fifteen minutes: twice the documented `*/5 * * * *` schedule, rounded up
    # to the next quarter hour.
    #
    # It was `:infinity`, and `@incomplete` contains `:executing`, so a job left
    # `executing` by a node that died deduplicated every future enqueue for ever
    # (`open-findings.md` X486). This worker's bound is the one a customer
    # notices: it is added to the lag between an effective date and the change
    # landing, and only when a node dies mid-run. At most 20 minutes, the
    # fifteen of the period plus up to five waiting for the next `*/5` tick,
    # because the uniqueness lapsing is not itself an enqueue. Every effect is
    # conditional on
    # the transition still being `pending` (invariant I16), so an admitted
    # duplicate applies each transition exactly once.
    use Oban.Worker,
      queue: :aurora_meter,
      max_attempts: 5,
      unique: [period: 900, states: @incomplete]

    @operation {AuroraMeter.Subscriptions, :apply_due_transitions, 1}

    @default_batches 10

    @doc """
    Applies due transitions in at most `"batches"` pages, newest cursor first.

    Returns `{:ok, summary}`; a run that stops at the batch bound reports
    `stopped: :partial`, which is what an alert on a backlog that never drains
    watches.

    ## Examples

        AuroraMeter.Oban.PlanTransitions.perform(%Oban.Job{args: %{"limit" => 100}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      if AuroraMeter.Oban.available?(@operation) do
        AuroraMeter.Oban.result(run(args))
      else
        {:cancel, :not_implemented}
      end
    end

    # The loop is here rather than in the operation because it is a scheduling
    # policy, not a correctness property: `apply_due_transitions/1` is one
    # bounded page and says whether there is more, and a caller decides how much
    # of a backlog one tick should drain.
    defp run(args) do
      {module, function, _arity} = @operation
      options = options(args)
      batches = max(Map.get(args, "batches", @default_batches), 1)

      Enum.reduce_while(1..batches, {:ok, blank()}, fn batch, {:ok, acc} ->
        case apply(module, function, [Keyword.put(options, :after, acc.cursor)]) do
          {:ok, page} -> continue(acc, page, batch, batches)
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp continue(acc, page, batch, batches) do
      merged = merge(acc, page)

      cond do
        page.cursor == :done -> {:halt, {:ok, %{merged | stopped: :complete}}}
        batch == batches -> {:halt, {:ok, %{merged | stopped: :partial}}}
        true -> {:cont, {:ok, merged}}
      end
    end

    defp blank, do: %{applied: 0, skipped: 0, failed: 0, batches: 0, cursor: nil, stopped: nil}

    defp merge(acc, page) do
      %{
        acc
        | applied: acc.applied + page.applied,
          skipped: acc.skipped + page.skipped,
          failed: acc.failed + page.failed,
          batches: acc.batches + 1,
          cursor: page.cursor
      }
    end

    defp options(args) do
      Enum.reduce([{"limit", :limit}, {"tenant", :tenant}], [], fn {key, option}, acc ->
        case Map.fetch(args, key) do
          {:ok, value} -> Keyword.put(acc, option, value)
          :error -> acc
        end
      end)
    end
  end
end
