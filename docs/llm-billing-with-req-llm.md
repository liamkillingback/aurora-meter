# Charge customers for LLM tokens with ReqLLM

[ReqLLM](https://hexdocs.pm/req_llm) calls the model; Aurora Meter decides
whether the customer may make the call and what it cost them. The pattern is the
one `AuroraMeter.Credits.with_credits/4` exists for:

1. **Hold an estimate** of the most the call can cost, before you call.
2. **Call the model** inside the hold.
3. **Settle from the usage the response reports**, which releases the rest of
   the hold.
4. **Refuse at zero**: a tenant without the estimate available is refused
   before any request leaves your server.

This guide uses ReqLLM 1.29 and Aurora Meter's free core. Nothing here needs
Aurora Meter Pro; the last section says what Pro adds.

## Prices in micro-dollars

Every amount in `AuroraMeter.Credits` is an integer number of micro-dollars
(`1_000_000` is one dollar; `AuroraMeter.Credits.Money` converts). Set your own
price per token, which is your margin decision, not the provider's list price:

```elixir
defmodule MyApp.AIPricing do
  # Micro-dollars per token: $3 per million input tokens, $15 per million output.
  @input_rate 3
  @output_rate 15

  # The most a call can cost: a rough input count plus the max_tokens cap.
  def estimate(prompt, max_tokens) when is_binary(prompt) do
    input_tokens = div(byte_size(prompt), 4) + 1
    input_tokens * @input_rate + max_tokens * @output_rate
  end

  # What the call did cost, from the usage map on the response. ReqLLM's usage
  # can be nil, and its keys vary by provider, so a missing figure falls back
  # to the estimate rather than to zero.
  def charge(nil, estimate), do: estimate

  def charge(usage, estimate) when is_map(usage) do
    case {Map.get(usage, :input_tokens), Map.get(usage, :output_tokens)} do
      {input, output} when is_integer(input) and is_integer(output) ->
        input * @input_rate + output * @output_rate

      _incomplete ->
        estimate
    end
  end
end
```

Price from tokens rather than from ReqLLM's `total_cost`. That figure is the
provider's cost computed by ReqLLM from its model metadata: it is a float in
dollars, it is an estimate, and it can be `nil` when ReqLLM has no pricing for
the model. It is useful for checking your margin, not as the amount you bill.

## Hold, call, settle

```elixir
defmodule MyApp.AI do
  alias AuroraMeter.Credits
  alias MyApp.AIPricing

  @model "anthropic:claude-haiku-4-5"
  @max_tokens 1_024

  # `request_id` is your own id for this request, so a retry reuses the hold's
  # reference and is refused as :duplicate_reference instead of charged twice.
  def complete(org, prompt, request_id) do
    estimate = AIPricing.estimate(prompt, @max_tokens)

    Credits.with_credits(org, estimate, "llm:" <> request_id, fn ->
      case ReqLLM.generate_text(@model, prompt, max_tokens: @max_tokens) do
        {:ok, response} ->
          cost = AIPricing.charge(ReqLLM.Response.usage(response), estimate)
          {:ok, ReqLLM.Response.text(response), cost}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end
end
```

What each outcome does:

| `MyApp.AI.complete/3` returns | What happened to the money |
|---|---|
| `{:ok, text}` | The hold was settled for `cost`; the rest of the estimate is available again. |
| `{:error, :insufficient_credits}` | Nothing was held and **the model was not called**. This is the refusal at zero. |
| `{:error, :debt_outstanding}` | The tenant owes money from an earlier overrun; nothing was called. |
| `{:error, :duplicate_reference}` | A hold with this reference exists already; nothing was called twice. |
| `{:error, reason}` from ReqLLM | The hold was released in full. The customer pays nothing for a failed call. |

If the model call raises, the hold is released and the exception propagates. If
the process is killed mid-call, the hold stays open until your hold reconciler
closes it: see [Holds nothing will ever close](credits.md#holds-nothing-will-ever-close).

A settled cost above the estimate is not refused: the balance goes negative by
the difference and the settle is flagged `overrun: true` in telemetry. Keep the
estimate an upper bound, which is what the `max_tokens` term above is for.

Refusing in the controller or LiveView is ordinary pattern matching:

```elixir
case MyApp.AI.complete(org, prompt, request_id) do
  {:ok, text} -> {:ok, text}
  {:error, :insufficient_credits} -> {:error, "Your balance is too low. Top up to continue."}
  {:error, reason} -> {:error, reason}
end
```

Show the balance with `AuroraMeter.Credits.balance/1` or the
`AuroraMeter.Components.credit_summary/1` component, and subscribe to the
credits topic (`AuroraMeter.LiveView.subscribe(org, topics: [:usage, :credits])`)
to update it live.

## Observability with ReqLLM's telemetry

ReqLLM emits `[:req_llm, :request, :stop]` when a request finishes, with
`usage`, `model` and `provider` in the metadata. It is the right place for
dashboards and alerts:

```elixir
:telemetry.attach(
  "my-app-llm-usage",
  [:req_llm, :request, :stop],
  &MyApp.LLMTelemetry.handle_event/4,
  nil
)

defmodule MyApp.LLMTelemetry do
  require Logger

  def handle_event([:req_llm, :request, :stop], measurements, metadata, _config) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("llm #{inspect(metadata.provider)} #{ms}ms usage=#{inspect(metadata.usage)}")
  end
end
```

It is **not** the place to bill, for three reasons:

- **A telemetry handler cannot hold or refuse.** It runs after the request has
  been made, so by the time it fires the tokens are spent. Only a hold taken
  before the call can refuse a tenant at zero.
- **The tenant is not in that event's metadata.** ReqLLM does not know who your
  customer is, so the handler would have to recover the tenant from somewhere
  else (a process dictionary, a conversation id) and get it right every time.
- **Cost is an estimate and may be `nil`.** The usage map's cost figures are
  computed by ReqLLM from model metadata and are absent for models it cannot
  price.

Settle from the response inside `with_credits/4`, as above, and use the event
to watch.

## Top-ups with Aurora Meter Pro

The free core keeps the ledger; it does not take payments. Grant credit
yourself after a payment you processed, idempotently by payment reference:

```elixir
AuroraMeter.Credits.grant(org, AuroraMeter.Credits.Money.from_cents(2_000),
  reference: "stripe:pi_123"
)
```

Charging for it: Aurora Meter Pro adds Stripe checkout, top-ups, auto-recharge
and metered invoicing: https://aurorameter.com/pro

With Pro, a Stripe Checkout payment grants credit through its webhook, a
low-balance threshold can trigger an automatic recharge of a saved card, and
refunds and disputes reverse the credit they granted. The hold, call and settle
code above does not change.
