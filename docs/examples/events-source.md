# Billing from recorded events

A worked example of a feature whose commercial quantity is the sum of durable
events rather than an in-memory counter: an LLM gateway that gates a request on
an estimate, does the work, and then records the tokens it actually used.

Everything in this guide is compiled and executed by
`test/aurora_meter/examples_test.exs`.

## The problem

Token usage has two properties that buffered metering handles badly.

The quantity is not known until the work is finished, so you cannot count it up
front. And it is the number on the invoice, so losing the last few seconds of it
because a node went away is a refund conversation, not a rounding error.

The two halves want different tools. The gate wants the fast in-memory
reservation. The charge wants a row in a transaction.

## The plan

```elixir
defmodule Lumen.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :tokens, 100_000, :hard
  end

  plan :studio do
    price 9_900
    metered :tokens, included: 2_000_000, unit_price: 1
  end
end
```

Nothing about the plan changes for an events-source feature. The source says
where the quantity comes from; the plan still says what the customer is entitled
to and what it costs.

## The configuration

```elixir
config :aurora_meter,
  plans: Lumen.Plans,
  feature_sources: %{tokens: :events}
```

That one line moves `:tokens` off the buffered path. From here on:

  * `AuroraMeter.track(org, :tokens, n)` raises `ArgumentError`. So does
    `AuroraMeter.reserve/2,3`. Both would create a second, separately billable
    count.
  * `AuroraMeter.record/4` is how a token is counted.
  * `AuroraMeter.usage/2` and `AuroraMeter.quota/2` keep answering, from the
    durable total.
  * `AuroraMeter.history/3` returns zeros: there is no day bucket. Chart from
    `AuroraMeter.Events.stream/1`.

## The call site

```elixir
defmodule Lumen.Gateway do
  @moduledoc "Gate on an estimate, charge for what actually happened."

  @estimate 4_000

  def complete(org, prompt) do
    AuroraMeter.with_quota(org, :tokens, @estimate, fn ->
      response = Lumen.Model.run(prompt)

      {:ok, event, _outcome} =
        AuroraMeter.record(org, :tokens, response.tokens,
          id: response.request_id,
          occurred_at: response.finished_at,
          dimensions: %{"model" => response.model}
        )

      %{text: response.text, tokens: event.quantity}
    end)
  end
end
```

Three things are happening, and they are worth separating.

**`with_quota/4` is the gate and nothing more.** It reserves the estimate so
concurrent callers cannot all walk through a nearly full cap, and it releases the
estimate when the callback returns. For an events-source feature the release
happens on success as well as on failure: the estimate was never the charge.

**`record/4` is the charge.** The `id:` is yours, so a retry after a timeout you
never saw the answer to comes back `{:ok, event, :duplicate}` rather than
charging twice. Use something the request already has: a request id, a job id, a
provider's completion id.

**`occurred_at:` is when the usage happened**, not when you got round to
recording it. A batch that finishes at 09:00:02 and is recorded at 09:00:37
belongs to 09:00:02, and if that instant fell in the previous period it is
charged there.

The in-memory arithmetic over one successful call is `+4_000` at admission,
`+response.tokens` from the projection, `-4_000` at release. The net is the
recorded quantity, which is also the durable total.

## What a retry does

```elixir
{:ok, _event, :inserted}  = AuroraMeter.record(org, :tokens, 1_420, id: "req_9", occurred_at: at)
{:ok, _event, :duplicate} = AuroraMeter.record(org, :tokens, 1_420, id: "req_9", occurred_at: at)
```

The second call writes nothing: no row, no total, no export intent. Send the
same payload under the same id as often as you like.

Change the payload and reuse the id and you get
`{:error, {:conflict, existing}}` instead, with the event that is already
stored. That is deliberate: two different facts under one identity is a bug in
the caller, and silently keeping the first would hide it.

## Reading it back

```elixir
AuroraMeter.usage(org, :tokens)
#=> 1_420

AuroraMeter.Events.total(org, :tokens, AuroraMeter.period(org).start)
#=> 1_420
```

`usage/2` is the in-memory view and can lag by a broadcast interval on a
cluster. `Events.total/3` is what was committed. For a dashboard, use the first;
for anything that has to agree with an invoice, use the second.

## Moving an existing feature over

If `:tokens` has been buffered in production, do not simply add the
configuration line. That period's usage would end up split between a counter row
that stops growing and an event total that starts, and no part of the system
would add them up for you.

The order is: deploy the `record/4` calls first, while the feature is still
`:buffered`. The facts are stored and their export intents are marked
`{:ineligible, :feature_buffered}`, so you can look at what would have been sent
before anything is billed from it. Then schedule a cutover at a period boundary
in Aurora Meter Pro, and flip `feature_sources` and delete the `track/4` calls in
the same deploy. A call site you missed then raises on that node, which is a
great deal better than counting quietly.

See [metering](../metering.md) for the source table and
[entitlements](../entitlements.md) for what `with_quota/4` does on each path.
