# 09a: the public surface this unit adds, and what the binding maps already said

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.

## 1. The two `api-change-map.md` amendments were already there

The build document's "Open questions" asks for two amendments to
`docs/v1/build-plans/api-change-map.md`, and its "Definition of done" says the
reviewing agent must write them. **Both are already present in that file**, and
were before this unit started. No edit was made to `api-change-map.md`.

| Amendment the build document asks for | Where it already is | Wording |
|---|---|---|
| 1.5 gains the `live_view_tenant` key, owned by 09a | `api-change-map.md` section 1.5, the row between `metrics_interval` and `Unknown keys` | ``| `live_view_tenant` | resolver `nil` | additive | 09a | How `on_mount` finds the tenant when the host does not pass one explicitly; there is no default resolver, because `Tenant.Default.to_key/1` maps `nil` to `""` and a silent empty tenant is worse than a raise |`` |
| 1.7's "existing unchanged" line gains `tenant_key` on the `:usage` payload | `api-change-map.md` section 1.7, second sentence | "the existing `{:aurora_meter, :usage, ...}` payload gains `tenant_key` (additive map key, `broadcaster.ex`). Without it a LiveView that switches tenants cannot tell whether an already in-flight message belongs to the tenant it just left" |

Section 1.2 already carries both new-module rows as well
(`AuroraMeter.Plug.EnsureEntitled`, additive, optional dep, 09a; and
`AuroraMeter.LiveView.{on_mount/4, unsubscribe/1, switch_tenant/2}`, additive,
09a).

**What this unit shipped that 1.2 does not name**, and which a reviewer should
decide about rather than have folded in silently:

| Shipped | In `api-change-map.md` 1.2? | Note |
|---|---|---|
| `AuroraMeter.LiveView.subscribe/2` | no | New arity. `subscribe/1` is unchanged and delegates to it with `topics: [:usage]`. |
| `AuroraMeter.LiveView.unsubscribe/2` | 1.2 names `unsubscribe/1` | `unsubscribe/1` delegates to it. |
| `AuroraMeter.LiveView.topics/1,2` | no | The canonical topic strings, so a host that runs its own `Phoenix.PubSub.subscribe/2` does not concatenate them. |
| `AuroraMeter.LiveView.handle_usage/2`, `handle_credits/2` | no | Named in `architecture-map.md` section 10 as "`handle_info` helpers"; 1.2's row lists only three of the functions. |
| `AuroraMeter.Config.live_view_tenant/0` | 1.5 has the key, 1.2 has no accessor row | Every other config key has an accessor; this follows the existing shape. |
| `AuroraMeter.Plug.EnsureEntitled`'s `:mode` and `:assign_quota` options | `architecture-map.md` section 10 lists `feature`, `tenant`, `on_missing_tenant`, `on_denied` | `:mode` comes from the build document's own option table; `:assign_quota` is the mitigation the build document's Risks section names for the quota read, brought forward because it costs nothing to add now and is a breaking default to change later. |

None of these is a narrowing, a rename or a removal.

## 2. The full added surface

### New module (optional dependency `plug`)

| Entry | Spec |
|---|---|
| `AuroraMeter.Plug.EnsureEntitled.init/1` | `(keyword()) :: map()` |
| `AuroraMeter.Plug.EnsureEntitled.call/2` | `(Plug.Conn.t(), map()) :: Plug.Conn.t()` |
| `t:AuroraMeter.Plug.EnsureEntitled.denial/0` | `:missing_tenant \| :not_entitled \| :limit_exceeded \| :unavailable` |

Compiled behind `if Code.ensure_loaded?(Plug.Conn) do`, the guard shape
`components.ex:1` established.

### `AuroraMeter.LiveView`, always compiled

| Entry | Spec | Guarded? |
|---|---|---|
| `subscribe/1` | `(term()) :: :ok \| {:error, term()}` | no (unchanged from 0.4.0) |
| `subscribe/2` | `(term(), keyword()) :: :ok \| {:error, term()}` | no |
| `unsubscribe/1` | `(term()) :: :ok` | no |
| `unsubscribe/2` | `(term(), keyword()) :: :ok` | no |
| `topics/2` (arity 1 through a default) | `(term(), keyword()) :: [{:usage \| :credits, String.t()}]` | no |
| `t:topic_name/0` | `:usage \| :credits` | no |
| `on_mount/4` | `(term(), map(), map(), Socket.t()) :: {:cont \| :halt, Socket.t()}` | `Phoenix.LiveView` |
| `switch_tenant/2` | `(Socket.t(), term()) :: Socket.t()` | `Phoenix.LiveView` |
| `handle_usage/2` | `(term(), Socket.t()) :: Socket.t()` | `Phoenix.LiveView` |
| `handle_credits/2` | `(term(), Socket.t()) :: Socket.t()` | `Phoenix.LiveView` |

**This is the first module in the package that is always compiled and puts only
*some* of its functions behind an optional-dependency guard.** Every previous
optional integration is a whole module (`Components`, the `Oban` namespace,
`LiveDashboard.Page`, `OpenTelemetry`, `Telemetry.Metrics`). Two guards in the
suite encoded the old shape and had to be taught the new one; see
`09a-optional-deps.md` section 4.

### Configuration

| Key | Type | Default |
|---|---|---|
| `live_view_tenant` | `{module, atom} \| nil` | `nil` |

Declared as `type: {:or, [{:tuple, [:atom, :atom]}, nil]}`, the shape
`credits_hold_reconciler` already uses. Accessor `Config.live_view_tenant/0`.

There is deliberately **no default resolver**. `Tenant.Default.to_key/1`
stringifies, so a fallback would map an unresolved tenant to `""`, and in the
0.5.x transition mode `Tenant.validate_key!/3` lets `""` through with a warning
(`open-findings.md` C12). `on_mount {AuroraMeter.LiveView, :subscribe}` raises
`ArgumentError` naming the key and both explicit forms instead.

### PubSub

`broadcaster.ex` `publish_usage/2`:

```
before: {:aurora_meter, :usage, %{feature: f, value: v, period_start: p}}
after:  {:aurora_meter, :usage, %{tenant_key: k, feature: f, value: v, period_start: p}}
```

Additive map key, the class `api-change-map.md` 1.7 already sanctions for the
credits payload. Two regression tests in `realtime_test.exs`: one asserts the new
key, one asserts that a clause matching **only** the three 0.4.0 keys still
matches. `Result: 14 passed`, log `logs/09a-broadcaster.log`. The only consumer in either other repository is Pro's
`lib/aurora_meter/pro/live/dashboard.ex:73`, which matches
`{:aurora_meter, :usage, _payload}`; Pro's suite was run and is unchanged (see
section 4).

### Optional dependency

```elixir
{:plug, "~> 1.15", optional: true}
```

**The floor and its stated reason (D12).** Nothing the plug calls is newer than
Plug 1.0: `Plug.Conn.assign/3`, `put_private/3`, `send_resp/3`, `halt/1` and the
`Plug` behaviour. There is therefore no API floor to state, and the comment in
`mix.exs` says so rather than inventing one. `~> 1.15` is the **tested** floor:
it is what `phoenix_live_view ~> 1.0` requires and what `aurora_meter_pro`
already declares at `mix.exs:88`, so it is the oldest line any build in either
repository resolves and no Pro host is asked to move. Declaring the wider range
the code would tolerate would be a support claim nothing tests.

`mix hex.info plug` answers on this machine (X335): resolved **1.20.3**, released
2026-07-09, Apache-2.0. Log: `logs/09a-hex-info-plug.log`.

## 3. Documentation

| File | Change |
|---|---|
| `docs/phoenix.md` | New. Added to `mix.exs` `docs[:extras]` in the `Guides` group (the existing `~r/docs\/[^\/]+$/` pattern captures it). Contains no em dash and no en dash. |
| `docs/api.md` | Section 1.9 gains eight `AuroraMeter.LiveView` rows; a new section 1.13a for the plug; section 1.10 gains `Config.live_view_tenant/0`; section 5's key table gains `:live_view_tenant`; section 7's `:usage` row gains `tenant_key`; the internal table's `AuroraMeter.LiveDashboard.View` row gains the dependency it needs (see `09a-optional-deps.md` section 5). |
| `docs/configuration.md` | The key table gains `:live_view_tenant`. |
| `docs/correctness.md` | I20's guarantee, known limits and test list. 58 new test bullets, generated from the guard's own reading of the tree rather than typed. |

## 4. Pro and the storefront (X252)

`grep` for `:aurora_meter, :usage` and `Broadcaster.topic` across
`aurora_meter_pro/lib`, `aurora_meter_pro/test`, `PhxTemplates/lib` and
`PhxTemplates/test`:

  * Pro `lib/aurora_meter/pro/live/dashboard.ex:73` matches
    `{:aurora_meter, :usage, _payload}` with a wildcard payload: unaffected by an
    added key.
  * Pro `test/aurora_meter/pro/live/dashboard_test.exs:75-128` builds its own
    `{:aurora_meter, :usage, %{feature: :requests, value: 1}}` messages and
    broadcasts them itself. They never pass through `Broadcaster.publish_usage/2`,
    so they are unaffected.
  * The storefront has no match at all: it carries no Aurora runtime.

**Pro's suite was run after the core change, and Pro rebuilt core.**
`bash tmp/v1/mixlane.sh pro mix test --seed 0`, log `logs/09a-pro-test.log`:
`Compiling 2 files (.ex)` then `Compiling 13 files (.ex)`, then
**`Result: 1157 passed (74 doctests, 1083 tests)`**, exit 0. Pro's
`_build/test/lib/aurora_meter/ebin/Elixir.AuroraMeter.Broadcaster.beam` carries a
timestamp later than the edit to `broadcaster.ex`, so the run exercised the new
payload rather than a cached one.

**The count is 1157, not the 1135 this unit was briefed to preserve.** The
difference is not this unit's: Pro's working tree carries build unit 09b's
in-flight work, including two test files Pro did not have
(`test/aurora_meter/pro/components_test.exs`,
`test/mix/tasks/gen_migration_test.exs`). This unit changed no file in the Pro
repository at all. What matters for X252 is asserted directly: **zero failures**.

## 5. Two defects in this unit's own documentation, and which guard caught each

  * **`AuroraMeter.release/4` does not exist.** `docs/phoenix.md` told a host
    that wanted not to bill a failed operation to "use `AuroraMeter.reserve/3`
    and `AuroraMeter.release/4` and take the lifecycle on yourself". There is no
    public release for a buffered reservation in this package at any arity.
    `AuroraMeter.ApiInventoryTest` did not catch it, because the inventory only
    contains what is written into it; `AuroraMeter.DocExamplesTest` did not catch
    it, because it parses **elixir code blocks** and the claim was in prose; and
    `mix docs --warnings-as-errors` did, because ExDoc autolinks a
    `Module.fun/arity` span wherever it appears. Corrected to name what actually
    exists: raise or throw out of the `with_quota/4` callback, which is the only
    way to tell it the work did not happen.
  * **Three references to `AuroraMeter.Tenant.Default.to_key/1`** in
    `docs/phoenix.md`, `docs/configuration.md` and `docs/correctness.md`. The
    function carries no `@doc`, so ExDoc treats it as hidden and warns on the
    autolink. Rewritten to name the module.

Both are the same shape and worth one line in a later unit's ADR if anyone wants
it: the API inventory guard proves that everything **listed** exists, and the doc
examples guard proves that everything **in a code block** exists. Neither reads
prose, and prose is where a confident wrong function name goes.
