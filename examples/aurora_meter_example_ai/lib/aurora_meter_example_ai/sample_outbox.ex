defmodule AuroraMeterExampleAi.SampleOutbox do
  @moduledoc """
  A host-owned `AuroraMeter.Events.Outbox`: the free way to get durable events
  out of this application and into something that bills.

  Aurora Meter core ships no delivery at all. What it ships is this seam:
  `AuroraMeter.record/4` calls `enqueue/2` **inside** the transaction that
  writes the event row, so an export intent is staged in the same commit as the
  fact it describes. An intent cannot be lost and cannot exist for a fact that
  rolled back, and neither of those is true of anything that reads the events
  table afterwards.

  ## The one rule, and it is the reason this module is four lines long

  `enqueue/2` runs inside a financial transaction that also holds a lock on the
  projection checkpoint. It inserts rows and does nothing else. **No HTTP call
  belongs here.** A network call inside this callback holds a database
  transaction open across a network boundary and stalls every concurrent
  `record/4` on the node while it waits.

  Delivery is `AuroraMeterExampleAi.SampleOutbox.Drainer`'s, on its own
  connection, after the commit.

  ## Eligibility

  Core tells this callback what it already knows about each event. `:eligible`
  becomes a `pending` row. `{:ineligible, reason}` becomes a `skipped` row
  carrying the reason, and is never delivered: an event whose period could not
  be attributed, or whose plan could not be resolved, names no commercial
  contract, and guessing one is how a customer gets billed on a price they were
  not on. It is recorded rather than dropped, because a correction that quietly
  disappears is worse than one that is visible and unsent.

  ## How this differs from the real thing

  Aurora Meter Pro's outbox is this plus lease tokens, fencing, backoff
  schedules, a cutover watermark and provider mapping. This one is deliberately
  the smallest version that is still correct about the thing that matters: the
  intent is written in the same transaction as the fact.
  """

  @behaviour AuroraMeter.Events.Outbox

  alias AuroraMeter.Clock
  alias AuroraMeterExampleAi.SampleOutbox.Item

  @doc """
  Stages one row per event, inside the caller's transaction.

  Uses `context.repo`, which is the repo running that transaction. Checking out
  another connection here would put the write outside the commit that carries
  the fact, which is the one thing this seam exists to prevent.
  """
  @impl AuroraMeter.Events.Outbox
  @spec enqueue([AuroraMeter.Events.Outbox.item()], AuroraMeter.Events.Outbox.context()) ::
          :ok | {:error, term()}
  def enqueue(items, %{repo: repo} = context) do
    now = Clock.now()

    rows =
      Enum.map(items, fn %{event: event, eligibility: eligibility} ->
        %{
          id: Ecto.UUID.generate(),
          event_id: event.event_id,
          tenant_key: event.tenant_key,
          feature: to_string(event.feature),
          quantity: event.quantity,
          # `DateTime.truncate/2` rather than a bare copy: `period_start` is
          # already at second precision, and `recorded_at` is not.
          period_start: DateTime.truncate(event.period_start || event.recorded_at, :second),
          payload: payload(event),
          state: state_for(eligibility),
          attempts: 0,
          last_outcome: outcome_for(eligibility),
          next_attempt_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    # `on_conflict: :nothing` because `record/4` promises not to hand this
    # callback a duplicate identity, and a unique index plus `:nothing` is how
    # that promise is held rather than assumed.
    repo.insert_all(Item, rows,
      on_conflict: :nothing,
      conflict_target: [:tenant_key, :event_id],
      timeout: Map.get(context, :timeout, 15_000)
    )

    :ok
  end

  @doc """
  The payload an exporter would send. String keys and JSON-safe values only:
  Aurora Meter never looks inside it, and a provider adapter is not going to
  understand an atom.
  """
  @spec payload(AuroraMeter.Event.t()) :: map()
  def payload(event) do
    %{
      "identifier" => event.event_id,
      "tenant" => event.tenant_key,
      "feature" => to_string(event.feature),
      "quantity" => event.quantity,
      # `kind` is `"usage"` or `"correction"`, and it is here because without
      # it the quantity above is unreadable.
      #
      # A correction's `quantity` is the **magnitude of a reduction**, stored
      # as a positive integer exactly as a usage event's is. Two rows reading
      # `quantity: 4` therefore mean "four more" and "four fewer", and nothing
      # on the row said which. Summing the column over-counted every
      # correction twice: once for the original and once for the credit.
      #
      # Found by the real-provider proof run, which reconciled 587 staged
      # against 579 at Stripe and was right both times. See
      # `AuroraMeterExampleAi.Ops.net_quantity/2`.
      "kind" => to_string(event.kind),
      "original_event_id" => event.original_event_id,
      "occurred_at" => event.occurred_at && DateTime.to_iso8601(event.occurred_at),
      "dimensions" => event.dimensions,
      "plan_id" => event.plan_id,
      "plan_version" => event.plan_version
    }
  end

  @spec state_for(term()) :: String.t()
  defp state_for(:eligible), do: "pending"
  defp state_for({:ineligible, _reason}), do: "skipped"

  @spec outcome_for(term()) :: String.t() | nil
  defp outcome_for(:eligible), do: nil
  defp outcome_for({:ineligible, reason}), do: "ineligible:" <> to_string(reason)
end
