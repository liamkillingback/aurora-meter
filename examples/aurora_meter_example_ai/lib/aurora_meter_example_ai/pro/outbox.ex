if Code.ensure_loaded?(AuroraMeter.Pro) do
  defmodule AuroraMeterExampleAi.Pro.Outbox do
    @moduledoc """
    Both outboxes, in the one transaction: this application's own record, and
    Aurora Meter Pro's delivery queue.

    ## The thing this module exists to correct

    The obvious way to turn the Pro profile on is one line of configuration:

        config :aurora_meter, events_outbox: AuroraMeter.Pro.Outbox

    and that was the first thing tried here. It works, and it quietly takes
    something away. `AuroraMeter.record/4` calls **one** outbox, so pointing it
    at Pro's replaces the sample's own `sample_outbox_items` rows with Pro's
    `aurora_meter_outbox_items` rows, and everything this application built on
    its own table stops working:

      * `AuroraMeterExampleAi.Generations.recover/4`, the orphan path, which
        reads its own staged row to rebuild a `generations` row after a crash;
      * `AuroraMeterExampleAi.HoldPolicy`, which decides an open hold from the
        same row;
      * `mix sample.repair`, `AuroraMeterExampleAi.Ops.orphans/1` and four
        figures on `/ops`;
      * five of the eight recipes in `docs/failures.md`.

    Every one of those failed the moment the flag was set, which is how this
    module came to exist. The lesson is worth more than the module: **the
    outbox seam is where a host's own durable record of what it metered
    lives**, and a host that has built on it cannot hand the seam to somebody
    else without handing over that record too.

    ## What a host should do about it

    Write three lines. The seam takes one module; that module may call two.
    Both `enqueue/2` calls run inside the transaction that wrote the event, so
    the guarantee is unchanged: either the fact, this application's intent and
    Pro's intent all commit, or none of them does.

    The cost is one extra row per event. The alternative is to rewrite the five
    call sites above against Pro's tables, which means the sample's own code
    reads a commercial package's schema directly, and that is the dependency
    `architecture-map.md` rule 1 exists to prevent.

    ## Order

    This application's own first, Pro's second. Nothing depends on the order
    (they are two inserts in one transaction) and it is fixed anyway, because a
    reader tracing a failure should not have to wonder.
    """

    @behaviour AuroraMeter.Events.Outbox

    alias AuroraMeterExampleAi.SampleOutbox

    @impl AuroraMeter.Events.Outbox
    @spec enqueue([AuroraMeter.Events.Outbox.item()], AuroraMeter.Events.Outbox.context()) ::
            :ok | {:error, term()}
    def enqueue(items, context) do
      with :ok <- SampleOutbox.enqueue(items, context) do
        AuroraMeter.Pro.Outbox.enqueue(items, context)
      end
    end
  end
end
