# Example: an allowance you may go over

**The product.** Inkwell is an AI writing assistant. $29 a month includes 1,000
generations. The 1,001st still works — it costs 2¢ and lands on the next
invoice. Nobody is ever blocked mid-sentence.

This is the `metered` feature kind. It is the right shape when *saying no*
costs you more than the work costs, and when your customers would rather be
billed than interrupted.

## 1. The plan

```elixir
defmodule Inkwell.Plans do
  use AuroraMeter.Plans

  plan :free do
    price 0
    limit :generations, 25, :hard        # free really does stop
  end

  plan :writer do
    price 2_900                          # $29.00
    metered :generations, included: 1_000, unit_price: 2   # 2¢ each after 1,000
  end

  plan :studio do
    price 9_900
    metered :generations, included: 5_000, unit_price: 1   # cheaper per unit
  end
end
```

`included` and `unit_price` are both integers, and `unit_price` is in **cents**.
`unit_price: 2` means two cents.

### What those two numbers are actually for

This surprises people, so it is worth being blunt:

> `included` and `unit_price` are for **your** estimates and **your** screens.
> When you bill through Stripe, Stripe's price tiers are the source of truth
> for what the customer is charged.

So these two numbers let you draw "you are 240 over, about $4.80" without
calling Stripe. They do not set the price. If you change `unit_price` here and
not in Stripe, your dashboard lies and the invoice is still right. Keep them in
step deliberately — the Pro package's **Usage reporting** guide covers the
Stripe side.

## 2. Counting

```elixir
AuroraMeter.track(org, :generations)
```

That is the whole hot path. It is an ETS counter increment — no database call —
so you can put it anywhere, including in a loop.

A background flusher writes totals to Postgres on the `:flush_interval` (five
seconds by default). That trade is the reason it is fast, and it has a
consequence you should decide about consciously: **if the node dies, every count
that is not yet in an acknowledged flush batch dies with it.** That is usually
the last interval. It is more than that whenever the database has been
unreachable, because the pending set keeps growing until the database comes back
or the VM stops.

For a 2¢ generation, losing a few is cheaper than the machinery that would keep
every one. If that is not true for you (say each unit is a dollar) move the
feature's quantity to durable events:

```elixir
config :aurora_meter, feature_sources: %{generations: :events}
```

and replace `AuroraMeter.track/4` with `AuroraMeter.record/4`, which takes an
identity from you and writes the fact in a transaction:

```elixir
AuroraMeter.record(org, :generations, 1, id: request_id, occurred_at: finished_at)
```

Slower, and a database write per call, in exchange for a fact that survives the
node and a retry that is recognised as a duplicate rather than charged twice.
Choose per feature, not globally; [billing from recorded
events](events-source.md) is the worked version, and [metering](../metering.md)
has the source table.

The older `config :aurora_meter, durable_features: [:generations]` still works
and is deprecated. It writes an extra row per increment with no caller identity,
and the counter remains what reporting reads, so it is an audit trail rather
than a second source.

### Counting more than one

A single request that generates five variants is five units:

```elixir
AuroraMeter.track(org, :generations, 5)
```

And a correction, if you overcounted, is a negative number:

```elixir
AuroraMeter.track(org, :generations, -1)
```

## 3. Gating (or rather, not)

```elixir
AuroraMeter.check(org, :generations)
# :ok — always, on :writer and :studio
```

A metered feature never refuses. That is the point. If you find yourself
wanting it to refuse at some ceiling, you want `limit … :hard`, or you want
both — a metered feature for the money and your own sanity check for abuse:

```elixir
defmodule Inkwell.Generation do
  @abuse_ceiling 50_000

  def run(org, prompt) do
    if AuroraMeter.usage(org, :generations) > @abuse_ceiling do
      {:error, :contact_support}
    else
      AuroraMeter.with_quota(org, :generations, fn -> Inkwell.AI.generate(prompt) end)
    end
  end
end
```

`with_quota/4` on a metered feature still counts, still releases on a crash,
and simply never refuses. Using it rather than bare `track/3` means you get the
crash-safety for free and the code reads the same as your gated features.

## 4. What the customer sees

```elixir
AuroraMeter.quota(org, :generations)
# %{feature: :generations, kind: :metered, used: 1_240, included: 1_000,
#   overage: 240, unit_price: 2, limit: nil, remaining: :unlimited, percent: 100,
#   enabled: true, period: %{start: ..., end: ..., source: :calendar}}
```

**`percent` is clamped to 100 and will never tell you they went over.** At 1,240
of 1,000 it reads `100`, and it reads `100` at 10,000 too. That is fine for
drawing a bar and useless for describing the situation, so read `overage` —
which is `240` here — and render the number next to the bar. A customer who is
1,240 into an allowance of 1,000 should not see the same screen as one who is
exactly at their limit.

```heex
<div class="quota">
  <p><%= @q.used %> of <%= @q.included %> generations</p>

  <p :if={@q.overage > 0}>
    <%= @q.overage %> over ·
    about <%= AuroraMeter.Credits.Money.format(@q.overage * @q.unit_price * 10_000) %>
    on your next invoice
  </p>
</div>
```

That `* 10_000` converts cents to micro-dollars, which is what `Money.format/2`
takes: 240 units × 2 cents = 480 cents = 4,800,000 µ$ → `"$4.80"`.

## 5. Charting it

`history/3` gives you daily buckets, already zero-filled, so a chart with a
quiet Sunday shows a gap at zero rather than skipping the day:

```elixir
AuroraMeter.history(org, :generations, days: 30)
# [%{date: ~D[2026-02-10], value: 41}, %{date: ~D[2026-02-11], value: 0}, ...]
```

History is on by default. If you do not want the extra table written, turn it
off with `config :aurora_meter, history: false` — `history/3` then returns an
empty list rather than raising.

## 6. Warning them before the invoice does

Nobody enjoys discovering an overage after it is charged. The Pro package fires
alerts as a tenant approaches and crosses their allowance:

```elixir
config :aurora_meter_pro, alert_handler: &Inkwell.Billing.quota_alert/1

defmodule Inkwell.Billing do
  def quota_alert(%{tenant_key: key, feature: feature, percent: percent}) do
    org = Inkwell.Orgs.get_by_key!(key)

    case percent do
      p when p >= 100 -> Inkwell.Mailer.overage_started(org, feature)
      p when p >= 80 -> Inkwell.Mailer.approaching_allowance(org, feature, p)
      _ -> :ok
    end
  end
end
```

Alerts are deduplicated per tenant, feature and period, so a customer sitting
at 81% for a fortnight is emailed once, not every ten minutes. If your handler
fails, the "already sent" record is rolled back and the next sweep tries again
— an alert that could not be delivered is not silently marked delivered.

## 7. Getting it onto the invoice

The core counts; it does not charge. To turn 240 units of overage into money
you need the Pro package, which reports usage to a Stripe Billing Meter on a
schedule:

```elixir
config :aurora_meter_pro,
  stripe_prices: %{writer: "price_flat_writer", studio: "price_flat_studio"},
  stripe_metered_prices: %{writer: ["price_writer_overage"]},
  stripe_meters: %{generations: "generations"}

config :inkwell, Oban,
  queues: [aurora_meter: 5],
  plugins: [{Oban.Plugins.Cron, crontab: [
    {"*/5 * * * *", AuroraMeter.Pro.UsageReporter},
    {"*/5 * * * *", AuroraMeter.Pro.Outbox.Deliverer}
  ]}]
```

In Stripe, give the metered price a **graduated** tier: the first 1,000 at $0,
everything above at 2¢. The reporter sends deltas of total usage; Stripe
applies the tiers. This is why `included` lives in two places, and why they have
to agree.

The full Stripe-side setup, including what happens when a send fails halfway,
is in the Pro package's **Usage reporting** guide.

## 8. Free tiers that actually stop

Notice that Inkwell's `:free` plan uses `limit … :hard`, not `metered`. That is
deliberate and worth copying. A metered free plan bills a customer who never
gave you a card, which means you cannot collect and they get the product for
nothing. Free tiers should hit a wall; paid tiers should bill.

The transition between them is one call:

```elixir
AuroraMeter.subscribe(org, :writer)
```

The same feature name, `:generations`, is a hard cap on one plan and a metered
allowance on the next. The counter carries across untouched — you are only
changing the rules that are read against it.

## The whole thing, end to end

```elixir
# A free user hits the wall at 25
AuroraMeter.with_quota(org, :generations, fn -> Inkwell.AI.generate(p) end)
# => {:error, :limit_exceeded}

# They subscribe
AuroraMeter.subscribe(org, :writer)

# Same call, now allowed, and it keeps being allowed past 1,000
AuroraMeter.with_quota(org, :generations, fn -> Inkwell.AI.generate(p) end)
# => {:ok, "..."}

# The dashboard is honest about the money
AuroraMeter.quota(org, :generations)
# %{used: 1_240, included: 1_000, overage: 240, unit_price: 2, percent: 124, ...}

# Once an hour, Pro reports the delta to Stripe under an identifier Stripe
# deduplicates on, so a retried send does not bill the units twice
```

Next: [Prepaid credits](prepaid-credits.md) for the other money shape, or
[Showing usage](showing-usage.md) to render this.
