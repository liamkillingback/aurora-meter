# 09a: the LiveView helpers

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.
Source: `test/aurora_meter/live_view_test.exs`, 26 tests plus 1 doctest,
`--seed 0`. Raw log: `logs/09a-live-view.log`.

## 0. How subscription is measured, and why it is not "did a message arrive"

Every assertion below counts **registrations**:

```elixir
Config.pubsub() |> Registry.lookup(topic) |> Enum.count(fn {pid, _} -> pid == self() end)
```

A message that fails to arrive is equally consistent with "not subscribed" and
with "nothing was broadcast", and only one of those is what these tests are
about. A registration count is also the only way to see a **duplicate**
registration, which delivers exactly the same messages as a single one until the
day it leaks.

## 1. `subscribe/1,2`, `unsubscribe/1,2`, `topics/1,2`

| Call | usage registrations | credits registrations | Return |
|---|---|---|---|
| `subscribe(t)` | 1 | **0** | `:ok` |
| `subscribe(t, topics: [:usage, :credits])` | 1 | 1 | `:ok` |
| `unsubscribe(t, topics: [:usage, :credits])` after the above | 0 | 0 | `:ok` |
| `unsubscribe(t)` after the above | 0 | **1** (it unsubscribes only what it was asked for) | `:ok` |
| `subscribe(nil)` | 0 on `""`'s topic | 0 on `""`'s topic | raises `ArgumentError`, "nil tenant" |
| `subscribe(t, topics: [:usage, :invoices])` | | | raises `ArgumentError`, ":topics must be a subset" |
| `topics(t)` | | | `[usage: "aurora_meter:tenant:<t>"]` |
| `topics(t, topics: [:usage, :credits])` | | | both, in the order asked |

`subscribe/1` is the 0.4.0 behaviour exactly, which matters because it has a live
consumer outside this repository (`aurora_api/lib/aurora_api/metering.ex:142`).

Both message families arrive on a real subscription: a `track/3` plus
`AuroraMeter.Test.broadcast!/0` delivers
`{:aurora_meter, :usage, %{feature: :requests, value: 3}}`, and a
`Credits.grant/3` delivers `{:aurora_meter, :credits, %{balance: 5_000}}`.

### The partial-failure rollback, and how it is driven honestly

`Phoenix.PubSub.subscribe/2` is spec'd `:ok | {:error, term()}` and delegates to
`Registry.register/3`. The local adapter's registry has **duplicate** keys and
therefore never returns an error, so there is no way to make the second topic
fail through the ordinary path. Rather than assert a code path nothing can
reach, the test points `:pubsub` at a `:unique` registry, where registering a key
this process already holds returns `{:error, {:already_registered, pid}}`:

```
Registry.register(registry, credits_topic, nil)        # take the second key first
LiveView.subscribe(t, topics: [:usage, :credits])      # => {:error, {:already_registered, _}}
Registry.lookup(registry, usage_topic)                 # => []   (rolled back)
```

Without the rollback that last line is `[{self(), nil}]`: a partial subscription
nobody asked for and nobody knows about. A non-local PubSub adapter can return an
error for its own reasons, which is why the rollback exists.

## 2. `on_mount/4`: the mount/switch/unmount sequence

Socket built by hand (`%Phoenix.LiveView.Socket{}`; connected means
`transport_pid: self()`), which is what Pro's dashboard test does for the same
reason: core adds no Phoenix endpoint.

| Step | Socket | Assigns after | usage topic registrations | credits |
|---|---|---|---|---|
| static mount, `{:subscribe, &org_from_session/2}` | `connected? == false` | `aurora_meter_tenant: t`, `aurora_meter_tenant_key: t`, `aurora_meter_topics: [:usage]` | **0** | 0 |
| connected mount, same hook | `connected? == true` | same three | **1** | 0 |
| connected mount, `{:subscribe, assign: :current_org}` | | same three, tenant from the assign an earlier hook set | 1 | 0 |
| connected mount, `{:subscribe, [assign: :current_org, topics: [:usage, :credits]]}` | | `aurora_meter_topics: [:usage, :credits]` | 1 | 1 |
| connected mount, resolver returns `nil` | | `{:halt, socket}`, `aurora_meter_denial: :missing_tenant`, **no** `aurora_meter_tenant` | 0 on `""`'s topic | 0 |
| `:subscribe` (bare), `live_view_tenant` unset | | raises `ArgumentError` | | |
| `:subscribe` (bare), `live_view_tenant: {M, :org_from_session}` | | the three assigns | 1 | 0 |
| an argument shape the hook does not know | | raises `ArgumentError`, "does not know :resubscribe" | | |

L09a-2 is the first two rows: the static mount assigns and does **not**
subscribe. Subscribing on both mounts registers twice for one socket.

The `ArgumentError` for the bare form contains, verbatim:

  * `live_view_tenant`
  * `{:subscribe, &MyApp.Accounts.org_for/2}`
  * `{:subscribe, assign: :current_org}`

and the last row above is its positive control: the raise is a fact about the key
being unset, not about the bare form being broken.

The hook **never redirects**. It does not know the host's login route and
guessing one is worse than letting the host's own `on_mount` chain decide, so it
returns `{:halt, socket}` with the reason in the assigns.

## 3. `switch_tenant/2` (L09a-3)

Socket mounted on `first` with `topics: [:usage, :credits]`, then switched to
`second`:

| | `usage(first)` | `credits(first)` | `usage(second)` | `credits(second)` |
|---|---|---|---|---|
| after mount | 1 | 1 | 0 | 0 |
| after `switch_tenant(socket, second)` | **0** | **0** | **1** | **1** |

Assigns after: `aurora_meter_tenant: second`, `aurora_meter_tenant_key: second`,
`aurora_meter_topics: [:usage, :credits]` (the same set, read back from the
socket rather than from the options, so a host that subscribed one set never has
another unsubscribed out from under it).

| Case | Result |
|---|---|
| `switch_tenant(socket, same_tenant)` | returns the socket **identical** (`==`), registrations stay at 1: no duplicate, no gap |
| `switch_tenant(socket, nil)` | raises `ArgumentError`, "nil tenant"; the old registration is still 1 and `""`'s topic still 0 |
| `switch_tenant/2` on a disconnected socket | re-assigns only; both tenants at 0 registrations, because nothing was subscribed |

## 4. `handle_usage/2` and `handle_credits/2`, and the dropped message

The two tenant keys, printed:

```
socket.assigns.aurora_meter_tenant_key = "org_1104"     (mine)
message payload tenant_key             = "org_1105"     (theirs)
```

| Sequence | `aurora_meter_usage` after |
|---|---|
| `%{tenant_key: mine, feature: :requests, value: 1}` | `%{requests: %{value: 1, period_start: nil}}` |
| then `%{tenant_key: theirs, feature: :requests, value: 999}` | **unchanged**: `%{requests: %{value: 1, period_start: nil}}` |
| `requests 4`, `ai_generations 9`, `requests 6` (all mine, period `2026-09-01`) | `%{requests: %{value: 6, period_start: ~U[2026-09-01 00:00:00Z]}, ai_generations: %{value: 9, period_start: ~U[2026-09-01 00:00:00Z]}}` |

**Acceptance criterion 7**, as one sequence: mount on `first`, switch to
`second`, then deliver one message from each.

```
mounted(first) |> switch_tenant(second)
handle_usage(%{tenant_key: first,  feature: :requests, value: 111}, socket)   # dropped
handle_usage(%{tenant_key: second, feature: :requests, value: 222}, socket)   # kept
=> %{requests: %{value: 222, period_start: nil}}
```

This is the whole reason `tenant_key` is on the payload.
`Phoenix.PubSub.unsubscribe/2` stops routing but does not empty a mailbox, so a
broadcast already in flight is delivered after the switch, and a usage value is
an absolute per-feature total, so a stale one would sit on screen until that
feature moved again.

`handle_credits/2`:

| Message | `aurora_meter_credits` after |
|---|---|
| `:credits` mine, `balance: 900, held: 100, available: 800` | `available: 800`, `held: 100`, `low_balance: false` |
| then `:low_balance` mine, `available: 800, threshold: 1_000` | `low_balance: true` |
| then `:credits` **theirs**, `available: 1` | **unchanged**: `available: 800` |
| `:low_balance` mine `available: 10, threshold: 1_000`, then `:credits` mine `available: 5_000` | `low_balance` goes `true` then back to `false` |

Both helpers return the socket unchanged for a message they do not recognise
(`{:aurora_meter, :event, ...}` to `handle_usage/2`, `:tick` to
`handle_credits/2`), so a host can route a whole `handle_info/2` clause into them
without a catch-all of its own.

## 5. Process death

Not asserted here and deliberately so: a LiveView process exiting has its PubSub
registrations reaped by the registry's monitor, which is `Phoenix.PubSub`'s
behaviour and not this package's. `docs/phoenix.md` states it so that hosts do
not write a `terminate/2` that unsubscribes.

## 6. What is not in this unit

Browser-level coverage of `on_mount/4`, `switch_tenant/2` and the live updates
belongs to build unit 09c's sample, which has a real endpoint, a real router and
`Phoenix.LiveViewTest`. This unit deliberately adds no Phoenix endpoint to core's
test support.
