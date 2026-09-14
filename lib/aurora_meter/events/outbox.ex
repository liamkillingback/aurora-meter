defmodule AuroraMeter.Events.Outbox do
  @moduledoc """
  The one seam between a recorded event and anything that delivers it.

  `AuroraMeter.record/4` calls `c:enqueue/2` **inside** the transaction that
  writes the event row and its projection delta. That is the whole point: an
  export intent that is staged in the same commit as the fact cannot be lost,
  and cannot exist for a fact that was rolled back. Configure it with

      config :aurora_meter, events_outbox: MyApp.Outbox

  Core ships `AuroraMeter.Events.Outbox.Noop`, which is the default and does
  nothing. Core has no delivery of its own and knows nothing about Stripe,
  customers, meters or modes; Aurora Meter Pro implements this behaviour and
  owns every provider-shaped decision.

  ## The contract an implementation must keep

    * **Use the repo you are given.** `context.repo` is the repo running the
      open transaction. Checking out another connection puts your write outside
      the commit that carries the fact, which is the one thing this seam exists
      to prevent.
    * **Be fast and do no I/O off the database.** You are inside a financial
      transaction that also holds a shared lock on the projection checkpoint
      row. A network call here stalls every concurrent `record/4`.
    * **Reserve errors for storage failures.** Returning `{:error, reason}` or
      raising rolls the caller's `record/4` back and the caller sees
      `{:error, {:unavailable, {:outbox, reason}}}`. Anything you can express
      as a quarantined item should be enqueued as one and reported later, not
      turned into a refusal to record the usage.

  ## Eligibility

  Each item carries what **core** knows about whether the event is a candidate
  for delivery, and nothing else:

    * `:eligible`
    * `{:ineligible, :feature_buffered}` when the feature reports from the
      buffered counter rather than from events (build unit 03c)
    * `{:ineligible, :attribution_unresolved}` when the period source could not
      place `occurred_at`, so the period on the row is an approximation
    * `{:ineligible, :original_ineligible}` on a **correction** whose original
      carried an unresolved attribution. The correction of an unattributed fact
      cannot be attributed either, and the reason names which of the two rows is
      the problem.

  Mapping, customer, mode, meter, cutover watermark and timestamp window are
  the implementation's decisions, taken at enqueue time from its own
  configuration.

  A correction is **never dropped**. Core stages every one of them, with a
  reason attached when core can already tell delivery is not possible, because
  a correction that quietly disappears is a customer credited nothing and told
  otherwise (I09).
  """

  alias AuroraMeter.Event

  @typedoc "Why core believes an event is not a candidate for delivery."
  @type ineligibility :: :feature_buffered | :attribution_unresolved | :original_ineligible

  @typedoc "One export intent."
  @type item :: %{
          event: Event.t(),
          eligibility: :eligible | {:ineligible, ineligibility()}
        }

  @typedoc "What the record transaction hands the implementation."
  @type context :: %{repo: module(), timeout: timeout()}

  @doc """
  Stages the export intent for every accepted event, inside the caller's
  transaction.

  Duplicates are not passed: an identity that was already recorded produced its
  intent when it was first recorded.
  """
  @callback enqueue([item()], context()) :: :ok | {:error, term()}
end

defmodule AuroraMeter.Events.Outbox.Noop do
  @moduledoc """
  The default `AuroraMeter.Events.Outbox`: it does nothing, successfully.

  Core ships no delivery, so this is what a host that has not configured one
  gets. Recording still works, the events and their totals are still durable,
  and nothing is staged for export.
  """

  @behaviour AuroraMeter.Events.Outbox

  @doc """
  Ignores every item and returns `:ok`.

  ## Examples

      iex> AuroraMeter.Events.Outbox.Noop.enqueue([], %{repo: nil, timeout: 1000})
      :ok

  """
  @impl AuroraMeter.Events.Outbox
  @spec enqueue([AuroraMeter.Events.Outbox.item()], AuroraMeter.Events.Outbox.context()) :: :ok
  def enqueue(_items, _context), do: :ok
end
