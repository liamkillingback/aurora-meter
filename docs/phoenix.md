# Phoenix

Aurora Meter ships two optional Phoenix helpers: a plug that refuses a request
the plan does not allow, and LiveView helpers that keep a socket subscribed to
one tenant's live figures. **The plug is advisory.** It refuses the clearly
disallowed request early and cheaply, and it holds nothing: between the moment
it decides and the moment your controller does the work, another request on the
same node can take the last unit. **No reserving plug is shipped, and that is a
decision rather than an omission.** A reservation has to be released when the
work fails; `AuroraMeter.with_quota/4` releases it because it runs your work
inside its own `try/catch` and can see what happened; a plug returns before your
controller runs and can see neither the return value nor a raise. A plug that
reserved would hold quota it could never give back on every failed action, and
would admit N concurrent requests whose controllers then each reserved again on
top of it. So: the plug for the early refusal and the clear 403, and
`with_quota/4` where the money is.

Both are free, MIT, part of the core package, and neither needs Aurora Meter
Pro.

Everything here is optional in the dependency sense too.
`AuroraMeter.Plug.EnsureEntitled` is compiled only when `plug` is present and
`AuroraMeter.LiveView`'s socket functions only when `phoenix_live_view` is. A
host with neither still gets every counter, entitlement and credit function in
the package. If you add `plug` or LiveView to an application that already
compiled `aurora_meter`, run `mix deps.compile aurora_meter --force`:
`Code.ensure_loaded?/1` is asked once, at compile time, and a stale build is the
one way these modules go missing. `mix aurora_meter.install --check-support`
reports the mismatch.

## The quota recipe

This is the whole of it, and the order matters.

```elixir
defmodule MyAppWeb.Router do
  pipeline :metered do
    plug AuroraMeter.Plug.EnsureEntitled,
      feature: :ai_generations,
      tenant: &MyAppWeb.Tenancy.current_org/1
  end
end

defmodule MyAppWeb.GenerationController do
  use MyAppWeb, :controller

  def create(conn, params) do
    org = conn.assigns.aurora_meter_tenant

    case AuroraMeter.with_quota(org, :ai_generations, fn -> Generator.run(params) end) do
      {:ok, generation} ->
        render(conn, :show, generation: generation)

      {:error, :limit_exceeded} ->
        conn |> put_status(:forbidden) |> render(:quota_exhausted)

      {:error, :not_entitled} ->
        conn |> put_status(:forbidden) |> render(:upgrade_required)
    end
  end
end
```

The `{:error, :limit_exceeded}` clause is not defensive programming. The plug
said yes and `with_quota/4` said no, which is exactly the window the first
paragraph describes, and under concurrency it happens. **A host that checks only
in the plug will over-serve by roughly the number of requests it had in flight
when the cap was reached.** The plug is there so that a tenant with no
entitlement at all never reaches your controller, and so that the 403 is one
line in a pipeline instead of one line in every action.

`with_quota/4` commits the reservation on **any** normal return, including
`{:error, :whatever}` from your own code. **If a failure should not be billed,
raise or throw out of the callback**: `with_quota/4` catches `:error`, `:throw`
and `:exit` alike, releases the reservation and re-raises, and that is the only
way to tell it the work did not happen. There is no public release for a
buffered reservation to pair with `AuroraMeter.reserve/2,3`; `reserve/2,3` is the
bill-immediately primitive and `with_quota/4` owns the lifecycle.

### An events-source feature

For a feature declared `feature_sources: %{tokens: :events}`, the billable fact
is the event `AuroraMeter.record/4` committed, never the counter. The counter is
a display and gating value. Record inside the callback:

```elixir
AuroraMeter.with_quota(org, :tokens, estimate, fn ->
  {:ok, result} = Completions.run(prompt)

  {:ok, _event, _outcome} =
    AuroraMeter.record(org, :tokens, result.tokens,
      id: result.request_id,
      occurred_at: result.finished_at
    )

  result
end)
```

`+estimate` at admission, `+result.tokens` from the projection, `-estimate` at
release: the in-memory value nets to the durable total, and while the callback
runs every other caller sees the estimate held.

## The plug

```elixir
plug AuroraMeter.Plug.EnsureEntitled,
  feature: :ai_generations,
  tenant: &MyAppWeb.Tenancy.current_org/1
```

| Option | Default | Meaning |
|---|---|---|
| `:feature` | required | The feature to check. An atom: the package never calls `String.to_atom/1`. |
| `:tenant` | required | `(conn -> tenant \| nil)` or `{module, function}`. No default. |
| `:mode` | `:check` | `:check` consults usage and sees hard limits. `:entitled?` consults only the plan shape and reads no counter. |
| `:assign_quota` | `true` | Assign `:aurora_meter_quota` on a passing request. |
| `:on_missing_tenant` | `:unauthorized` | 401, reason `:missing_tenant`. |
| `:on_denied` | `:forbidden` | 403, reason `:not_entitled` or `:limit_exceeded`. |
| `:on_unavailable` | `:service_unavailable` | 503, reason `:unavailable`. |

Options are validated in `init/1`, and Phoenix expands a router `plug` call at
compile time, so a typo is a compile error in your application rather than a
surprise on the first request.

A passing request gets `conn.assigns.aurora_meter_tenant`, the term your
resolver returned (the term, not the key: if you meter a struct you get your
struct back), and `conn.assigns.aurora_meter_quota`, exactly
`AuroraMeter.quota(tenant, feature)`. The quota costs one extra ETS read and one
period computation; pass `assign_quota: false` on a hot path that does not
render it.

### It is not authorization

The plug answers "does this tenant's plan allow this feature". It does not
answer "is this request allowed to act for this tenant", and it never will. That
is why `:tenant` is required with no default and why the resolver is yours:

```elixir
defmodule MyAppWeb.Tenancy do
  # From the session, through your own authentication. Never from params:
  # a tenant read out of the URL is an IDOR with a metering call attached.
  def current_org(conn), do: conn.assigns[:current_user] && conn.assigns.current_user.org
end
```

A resolver that returns `nil` gets **401 and nothing else happens**. No counter
is read, no counter row is created, no subscription is loaded. An unresolved
tenant is not the default tenant: `AuroraMeter.Tenant.Default` stringifies what
it is given, so `nil` would become `""`, and every tenant your application failed
to resolve would then share one set of counters. The plug refuses before that can
happen.

### Refusals

By default a refusal sends an empty body with the status and halts, with the
reason atom in `conn.private[:aurora_meter_denial]`. The plug picks no content
type and writes no body, because it does not know what your clients read. Render
it yourself with `{module, function}`:

```elixir
plug AuroraMeter.Plug.EnsureEntitled,
  feature: :ai_generations,
  tenant: {MyAppWeb.Tenancy, :current_org},
  on_denied: {MyAppWeb.Errors, :quota_json}

defmodule MyAppWeb.Errors do
  import Plug.Conn

  def quota_json(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status_for(reason), Jason.encode!(%{error: reason}))
    |> halt()
  end

  defp status_for(:limit_exceeded), do: 402
  defp status_for(:not_entitled), do: 403
end
```

Your callback **must return a halted conn**. One that does not raises a
`RuntimeError` naming it, because an unhalted conn after a refusal is a request
that was refused and then served anyway, and nothing else would have noticed.

**Why 403 and not 429.** `:limit_exceeded` is an entitlement outcome for the
current period, not a rate limit that clears in seconds, so a `Retry-After`
header would be a lie. Both denial reasons default to 403 and the reason atom
reaches your callback, so mapping `:limit_exceeded` to 402 is the one clause
above.

### What becomes a 503 and what does not

| Situation | Result |
|---|---|
| Your `:tenant` resolver raises | propagates unchanged to your error handler |
| Your `AuroraMeter.Tenant` module refuses the term | propagates unchanged (a configuration fault, not an outage) |
| `AuroraMeter.UndeclaredFeatureError` under `undeclared_feature_policy: :raise` | propagates unchanged |
| `AuroraMeter.Period.InvalidPeriodError` from your period source | propagates unchanged |
| The database is unreachable during a cold counter seed | 503, `:unavailable`, one `Logger.error` |

The first four are things you fix in your application, and a 503 would send
whoever is on call to look at a database that is perfectly well. The last is an
outage, it retries on the next request, and it is never silent.

### Mounting it twice

Harmless and pointless. The decision is idempotent, consumes nothing and writes
nothing, so a plug mounted in a pipeline and again in a controller takes the
decision twice and assigns twice.

## LiveView

```elixir
live_session :dashboard, on_mount: [
  MyAppWeb.UserAuth,
  {AuroraMeter.LiveView, {:subscribe, assign: :current_org}}
] do
  live "/usage", MyAppWeb.UsageLive
end
```

Your authentication hook runs first and puts `:current_org` on the socket from
the session; the Aurora Meter hook reads that assign. Three forms:

| Form | Resolver |
|---|---|
| `{AuroraMeter.LiveView, {:subscribe, &MyApp.Accounts.org_for/2}}` | your function, called with `(session, socket)` |
| `{AuroraMeter.LiveView, {:subscribe, assign: :current_org}}` | `socket.assigns.current_org`, set by an earlier hook |
| `{AuroraMeter.LiveView, :subscribe}` | the `:live_view_tenant` config key, a `{module, function}` pair called with `(session, socket)` |

Any of them takes `topics:` as well:
`{:subscribe, [assign: :current_org, topics: [:usage, :credits]]}`.

The hook assigns `:aurora_meter_tenant`, `:aurora_meter_tenant_key` and
`:aurora_meter_topics`. **It does not subscribe on the static mount.** LiveView
mounts twice, once to render HTML with `connected?(socket) == false` and once
for the socket; the static mount has no channel to deliver to, so subscribing
there only registers something nothing will read. You do not need a
`terminate/2` that unsubscribes either: the PubSub registry monitors
subscribers, so a LiveView process that exits has its registrations reaped with
it.

When the resolver returns `nil` the hook halts with
`socket.assigns.aurora_meter_denial == :missing_tenant` and subscribes to
nothing. It does **not** redirect: it does not know your login route, and
guessing one is worse than letting your own hook chain decide. Put your
authentication hook before it and it will never see a `nil`.

The bare `{AuroraMeter.LiveView, :subscribe}` form raises at mount when
`:live_view_tenant` is unset, naming the key and the two explicit forms. It does
not fall back to anything, for the reason the plug does not: a fallback would
either subscribe to the empty-string tenant or silently subscribe to nothing.

```elixir
config :aurora_meter, live_view_tenant: {MyApp.Accounts, :org_for_session}
```

### Handling the messages

Match them yourself. This is the supported contract and it is three lines:

```elixir
def handle_info({:aurora_meter, :usage, %{feature: feature, value: value}}, socket) do
  {:noreply, assign(socket, :"#{feature}_used", value)}
end
```

Or fold them into an assign with the helpers, which also drop a message
belonging to another tenant:

```elixir
def handle_info({:aurora_meter, :usage, _} = message, socket) do
  {:noreply, AuroraMeter.LiveView.handle_usage(message, socket)}
end

def handle_info({:aurora_meter, tag, _} = message, socket) when tag in [:credits, :low_balance] do
  {:noreply, AuroraMeter.LiveView.handle_credits(message, socket)}
end
```

`handle_usage/2` maintains `socket.assigns.aurora_meter_usage`, a
`%{feature => %{value: integer, period_start: DateTime.t()}}` map.
`handle_credits/2` maintains `socket.assigns.aurora_meter_credits`, the last
credits payload plus a `:low_balance` boolean.

Match on the keys you need rather than on the whole map. Payload maps gain keys
additively across releases, so a three-key match keeps working where a whole-map
match breaks.

### Switching tenant

```elixir
def handle_event("switch_org", %{"id" => id}, socket) do
  org = MyApp.Accounts.get_org_for_user!(socket.assigns.current_user, id)
  {:noreply, AuroraMeter.LiveView.switch_tenant(socket, org)}
end
```

Note `get_org_for_user!/2`: whether this user may see that organisation is your
decision and `switch_tenant/2` does not take it.

It unsubscribes exactly the topics recorded in `:aurora_meter_topics` for the
old key and subscribes the same set for the new one. Switching to the tenant the
socket already holds returns the socket unchanged, so a re-render that calls it
is neither a duplicate registration nor a gap in delivery.

**One message can still arrive from the tenant you just left.**
`Phoenix.PubSub.unsubscribe/2` stops routing; it does not empty your mailbox, so
a broadcast that was already in flight is delivered after the switch. A usage
value is an absolute per-feature total, so a stale one would sit on screen until
that feature moved again. That is why the usage payload carries `tenant_key`,
and why `handle_usage/2` and `handle_credits/2` drop a message whose key is not
the socket's. If you match the raw messages yourself and you support switching,
compare `tenant_key` against `socket.assigns.aurora_meter_tenant_key`.

### Topics, if you want to subscribe yourself

```elixir
AuroraMeter.LiveView.topics(org, topics: [:usage, :credits])
#=> [usage: "aurora_meter:tenant:org_42", credits: "aurora_meter:credits:org_42"]
```

The prefixes are part of the supported API; the way they are assembled is not,
so build them with `topics/2`, `AuroraMeter.Broadcaster.topic/1` or
`AuroraMeter.Credits.topic/1` rather than by string concatenation.

## What the numbers mean before you render them

Three properties, all of them from [guarantees](guarantees.md) and worth knowing
before a figure goes in front of a customer.

  * **`value` includes units this node has reserved but not yet committed.** A
    `reserve/3` or `with_quota/4` call occupies quota immediately, so a meter
    can tick up and then stay put when the reserved work commits.
  * **`value` is this node's converged view, not a database read.** With
    `cluster_sync: true` (the default) the broadcast is node-local: a browser
    connected to node B sees node B's view, other nodes' increments arrive
    within one `:broadcast_interval`, and a flush re-bases every node on the
    database total within one `:flush_interval`. Quotas are strict on one node
    and convergent across nodes, and nothing stronger.
  * **For an events-source feature the counter is a display and gating value.**
    The billable fact is the committed event. See
    [metering](metering.md) and [correctness](correctness.md).

## Related

  * [Entitlements](entitlements.md): `check/2`, `quota/2`, `with_quota/4` and the
    undeclared-feature policy the plug's denial vocabulary comes from.
  * [Showing usage](examples/showing-usage.md): the HEEx components.
  * [Guarantees](guarantees.md): what is promised and under what condition.
  * [Configuration](configuration.md): `:live_view_tenant` and everything else.
