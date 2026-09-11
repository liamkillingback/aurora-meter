# Example: putting it on screen

Counting is half the job. This page is the other half: the billing page, the
live counter, the chart, and the events you hang your own metrics off.

It assumes you have read [Concepts](concepts.md) and at least one of the three
product examples.

## 1. One call per card

`quota/2` returns everything a dashboard card needs, for any feature kind:

```elixir
AuroraMeter.quota(org, :generations)
# %{feature: :generations, kind: :metered, used: 1_240, included: 1_000,
#   overage: 240, unit_price: 2, limit: nil, remaining: :unlimited, percent: 100,
#   enabled: true, period: %{start: ..., end: ..., source: :calendar}}
```

The `kind` tells you how to draw it, and the six kinds do **not** all draw the
same way:

| `kind` | What it is | How to draw it |
|---|---|---|
| `:hard` | a cap | bar, clamped at 100% |
| `:metered` | an allowance you may exceed | bar **plus `overage`**; `percent` stops at 100 |
| `:counter` | measured, no denominator | a bare number. **No bar** |
| `:boolean` | a switch | a tick or a cross |
| `:feature` | an integer plan value, in `value` | the number |
| `:undeclared` | you never declared it | nothing, or a developer warning |

### Two rules that matter

**`percent: nil` means "no bar". Never render it as `0`.**

A `:counter` has nothing to be a percentage of, so `limit`, `included` and
`percent` are all `nil` on purpose. Turn that `nil` into a zero and your page
tells a paying customer they have used "0% of 0" and are presumably out — which
is exactly the reading this kind exists to prevent.

**`percent` never exceeds 100, so it cannot tell you about overage.** It is
clamped, which is right for a bar and wrong for a sentence. When
`kind == :metered`, read `overage` to find out whether they went past, and by
how much.

```heex
<div class="quota-card">
  <h3><%= @q.feature %></h3>

  <%= if @q.percent do %>
    <.bar percent={@q.percent} />
    <p><%= @q.used %> of <%= @q.included || @q.limit %></p>
  <% else %>
    <p class="count"><%= @q.used %> this period</p>
  <% end %>

  <p :if={@q.kind == :metered and @q.overage > 0} class="overage">
    <%= @q.overage %> over · about
    <%= AuroraMeter.Credits.Money.format(@q.overage * @q.unit_price * 10_000) %>
    on your next invoice
  </p>
</div>
```

If you would rather not write that, the built-in component already has these
rules in it:

```heex
<AuroraMeter.Components.usage_meter quota={@quota} />
```

It draws a counter as a bare count with no bar, shows a metered feature's
overage as a figure rather than pretending the bar can express it, and inherits
your colours through `currentColor` — there is no stylesheet to import and no
JavaScript.

## 2. Live, without polling

Usage totals are broadcast about once a second over `Phoenix.PubSub`.

```elixir
defmodule InkwellWeb.UsageLive do
  use InkwellWeb, :live_view

  def mount(_params, _session, socket) do
    org = socket.assigns.current_org
    if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)

    {:ok, assign(socket, org: org, quota: AuroraMeter.quota(org, :generations))}
  end

  def handle_info({:aurora_meter, :usage, %{feature: :generations, value: _value}}, socket) do
    {:noreply, assign(socket, quota: AuroraMeter.quota(socket.assigns.org, :generations))}
  end

  def handle_info({:aurora_meter, :usage, _other}, socket), do: {:noreply, socket}
end
```

Two things worth copying from that.

**Subscribe only when `connected?/1`.** A LiveView mounts twice — once for the
static render, once for the socket. Subscribing in the first gives you a
subscription belonging to a process that is about to die.

**Have a catch-all clause.** You are subscribed to the tenant, so you receive
every feature they use, not only the one you are drawing. Without the second
`handle_info/2` an unrelated feature crashes the view.

A broadcast only carries keys that were *touched* since the last one, so an idle
tenant produces no messages at all.

### Live balance

The credit ledger has its own subscription, which fires after each entry
commits:

```elixir
AuroraMeter.Credits.subscribe(org)

def handle_info({:aurora_meter, :credits, %{balance: balance, held: held, available: available}}, socket) do
  {:noreply, assign(socket, balance: available, held: held, settled: balance)}
end

def handle_info({:aurora_meter, :low_balance, %{available: available, threshold: _}}, socket) do
  {:noreply, put_flash(socket, :warning, "Balance is down to #{Money.format(available)}")}
end
```

`available` is what the customer can still spend — `balance` minus anything
currently held. Show `available`; show `held` separately if you show it at all
("$0.30 reserved for work in progress"), because a customer who sees only
`balance` will wonder where the difference went.

## 3. Charts

Daily buckets, already zero-filled and sorted oldest first, so there is no gap
handling to write:

```elixir
AuroraMeter.history(org, :generations, days: 30)
# [%{date: ~D[2026-02-10], value: 41}, %{date: ~D[2026-02-11], value: 0}, ...]
```

For money, the ledger's own series:

```elixir
AuroraMeter.Credits.spend_history(org, days: 30)
# [%{date: ~D[2026-03-01], spent: 210_000, granted: 0, net: -210_000,
#    balance_after: 24_998_500}, ...]

AuroraMeter.Credits.spend_history(org, from: ~D[2026-01-01], to: ~D[2026-03-31], bucket: :month)
```

`spent` and `granted` are positive magnitudes; `net` is the balance delta.
`balance_after` is the balance at the last entry in the bucket, and `nil` for a
bucket with no entries — another `nil` to render rather than zero.

Refunds count against `granted`, not as spend, so `granted` can go negative in a
window whose refunds exceeded its top-ups. That is correct and your chart should
allow it.

```heex
<AuroraMeter.Components.spend_chart points={@spend} height={120} label="Last 30 days" show_grants />
<AuroraMeter.Components.credit_summary summary={@summary} />
```

Both are inline SVG with `<title>` tooltips and no JavaScript.

## 4. The whole billing page, with Pro

If you have the Pro package, one call assembles everything:

```elixir
def mount(_params, _session, socket) do
  org = socket.assigns.current_org
  {:ok, assign(socket, org: org, dashboard: AuroraMeter.Pro.Dashboard.load(org))}
end
```

```heex
<AuroraMeter.Pro.Components.usage_dashboard tenant={@org} data={@dashboard} money={true} />
```

That renders the money section first when the tenant has a ledger — balance,
spend this period, runway, spend chart — then quota cards, daily charts and
monthly history. A product with no credit ledger simply gets no money section;
you do not need to branch.

Pass `money={false}`, or `Dashboard.load(org, credits: false)`, to leave money
out of a page that should not show it.

## 5. Numbers for humans

```elixir
alias AuroraMeter.Credits.Money

Money.format(1_500_000)              # => "$1.50"
Money.format(0)                      # => "$0.00"
Money.format(1_500)                  # => "$0.00"     <- two decimal places
Money.format(1_500, precision: 6)    # => "$0.001500"

Money.format_compact(1_234_000_000)  # => "$1.2k"
Money.format_compact(1_234_000)      # => "$1.23"
Money.format_compact(70_000)         # => "$0.07"
Money.format_compact(1_500)          # => "$0.0015"
Money.format_compact(0)              # => "$0"
```

The two are for different jobs. `format/2` renders a **balance**, to two decimal
places unless you ask for more. `format_compact/1` renders a **number on a
chart or a unit price**: it shortens thousands to `"$1.2k"` and, at the other
end, refuses to round a sub-cent amount away to `"$0.00"`. Render a per-request
price of 1,500 µ$ with `format/2` and your pricing page says it is free.

## 6. Exports (Pro)

```elixir
AuroraMeter.Pro.Export.usage_csv(org, days: 90)
AuroraMeter.Pro.Export.daily_csv(org, :generations, days: 30)
```

```elixir
def export(conn, _params) do
  csv = AuroraMeter.Pro.Export.usage_csv(conn.assigns.current_org, days: 90)

  conn
  |> put_resp_content_type("text/csv")
  |> put_resp_header("content-disposition", ~s(attachment; filename="usage.csv"))
  |> send_resp(200, csv)
end
```

## 7. Your own metrics

Everything emits telemetry. The full table is in [Telemetry](../telemetry.md);
the ones you will actually want:

```elixir
def metrics do
  [
    Telemetry.Metrics.sum("aurora_meter.track.count", tags: [:feature]),
    Telemetry.Metrics.counter("aurora_meter.reserve.qty", tags: [:feature, :result]),
    Telemetry.Metrics.sum("aurora_meter.credits.settle.amount", tags: [:tenant_key]),
    Telemetry.Metrics.counter("aurora_meter.credits.low_balance.available"),
    Telemetry.Metrics.summary("aurora_meter.flush.count")
  ]
end
```

Two of those are worth alerting on rather than graphing:

- **`[:aurora_meter, :flush, :error]`** — the database write failed and the
  deltas are still pending. One is noise; a stream of them means usage is piling
  up in memory and will be lost if the node restarts.
- **`[:aurora_meter, :credits, :settle]` with `overrun: true`** — a job cost more
  than it reserved. A few are normal. Many means your estimates are wrong and
  customers are going negative.

```elixir
:telemetry.attach("overruns", [:aurora_meter, :credits, :settle], fn
  _event, %{amount: amount}, %{overrun: true, tenant_key: key, reference: ref}, _cfg ->
    Logger.warning("overrun #{ref} for #{key}: #{amount}")

  _event, _measure, _meta, _cfg ->
    :ok
end, nil)
```

## 8. Testing your screens

```elixir
defmodule InkwellWeb.UsageLiveTest do
  use InkwellWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    AuroraMeter.Test.reset!()
    :ok
  end

  test "shows the overage", %{conn: conn} do
    org = org_fixture()
    AuroraMeter.subscribe(org, :writer)
    AuroraMeter.track(org, :generations, 1_240)
    AuroraMeter.Test.flush!()

    {:ok, _live, html} = live(conn, ~p"/usage")
    assert html =~ "1,240"
    assert html =~ "240 over"
  end
end
```

`AuroraMeter.Test.reset!/0` clears the ETS counters between tests and
`flush!/0` forces the pending deltas to Postgres rather than waiting five
seconds for the timer. For money, `fund!/3` puts credit on an account and
`credit_balance/1` reads it back. The full set is in
[Testing](../testing.md).

---

That is every surface: gate it, count it, charge for it, and show it. If you
came here from one of the product examples, the last thing worth reading is
[Testing](../testing.md) — most of the mistakes in this library's own history
were tests that could not fail.
