# 02b: the upgrade note

Build unit 02b, core `aurora_meter`. Written so that build unit 02d can draft the
0.5.0 transition release notes from this file without reading source.

## The one line that keeps everything as it was

```elixir
# config/config.exs
config :aurora_meter, undeclared_feature_policy: :allow
```

That restores the 0.4.x entitlement behaviour exactly: a feature the tenant's
plan does not declare is permitted, everywhere, silently.

It does not turn off the other four transition behaviours below, because those
are not entitlement decisions and none of them changes what a correct 0.4.x
application does. All four warn in 0.5.x and none of them fails.

## The recommended sequence

1. **Scan.** `mix aurora_meter.features --strict`. It prints what your
   configuration references that no plan declares (usually a typo), and every
   feature declared on some plans and not others with the exact list of plans
   that would deny it. The second section is the one that matters: a gap is
   precisely what changes behaviour.
2. **Warn.** Leave `:undeclared_feature_policy` at its 0.5.x default of `:warn`
   for a release. Every undeclared feature logs once per feature per node, which
   catches the names the scanner cannot see because they exist only in a call at
   runtime. `[:aurora_meter, :track]` and `[:aurora_meter, :reserve]` telemetry
   also carry `declared: false`, so a metrics backend can count them.
3. **Fix.** Declare the features on the plans that should have them, or change
   the call sites.
4. **Deny.** Set `:deny`. This is the 1.0 default, and it is what
   `mix aurora_meter.install` writes into a new install.

Do not skip step 2. The scanner reads configuration, not source.

## What the policy changes

Only for a feature the tenant's **effective plan** does not declare. A feature
another plan declares is undeclared for this tenant, which is the case the policy
exists for: a `:free` tenant reaching a `:pro` only feature was answered `:ok`.

| Entry point | `:allow` | `:warn` | `:deny` | `:raise` |
|---|---|---|---|---|
| `check/2` | `:ok` | `:ok` plus one log | `{:error, :not_entitled}` | raises |
| `allowed?/2` | `true` | `true` plus one log | `false` | raises |
| `entitled?/2` | `true` | `true` plus one log | `false` | raises |
| `feature_value/3` | the default | the default plus one log | the default | raises |
| `quota/2` | `kind: :undeclared, enabled: true` | same plus one log | `kind: :undeclared, enabled: false` | raises |
| `remaining/2` | `:unlimited` | `:unlimited` plus one log | `0` | raises |
| `reserve/2,3` | counts, `:ok` | counts, `:ok`, one log | `{:error, :not_entitled}`, counter untouched | raises, counter untouched |
| `with_quota/3,4` | runs the function | runs it, one log | `{:error, :not_entitled}`, not run | raises, not run |
| `track/4` | counts | counts | counts | counts |

Every entry point keeps its documented return shape under every policy; only the
value inside it changes. Two choices worth stating:

- `remaining/2` returns `0` under `:deny`, not `:unlimited` and not an error. The
  documented return type is `non_neg_integer() | :unlimited`, and `0` is the
  honest number when nothing is entitled.
- `feature_value/3` returns the caller's default under `:deny` as well, because
  that is already what an undeclared feature yielded. The policy still applies:
  `:warn` logs, `:raise` raises.

`:raise` raises `AuroraMeter.UndeclaredFeatureError`, carrying `feature`,
`tenant_key`, `plan_id`, `entry_point` and `reason` (`:not_in_plan` when another
plan declares it, `:unknown_feature` when none does).

`track/4` is outside the policy by design. Metering is not entitlement, and a
host that meters a name before it reaches a plan is doing something reasonable.
It reports `declared:` in `[:aurora_meter, :track]` metadata instead. **That
field answers "does any plan declare this name", not "is this tenant entitled to
it"**: answering the second would mean resolving the tenant's subscription on the
hot path, and with `subscription_cache_ttl: 0` that is a database read per
`track/4`. `AuroraMeter.entitled?/2` answers the entitlement question.

## The five behaviours that differ between 0.5.x and 1.0

The mode is derived from the package's own version at compile time
(`AuroraMeter.Config.Schema.mode/0`, `:transition` below `1.0.0-rc.0`). There is
no configuration key for it, and no way to opt into 1.0 behaviour early. The
staged `:allow` to `:warn` to `:deny` sequence above covers the part of that a
host actually needs.

| Behaviour | 0.5.x | 1.0 | How to prepare |
|---|---|---|---|
| **Unknown configuration key.** `AuroraMeter.Config.validate!/0` now reads the whole `:aurora_meter` environment instead of taking only the keys it knows. | one warning per boot naming each unknown key and its nearest known key | `NimbleOptions.ValidationError` from `AuroraMeter.start_link/1`; the host's supervision tree does not start | read the boot log once. `:ecto_repos`, `:included_applications` and repo configuration written under `:aurora_meter` (`config :aurora_meter, MyApp.Repo, ...`) are reserved and are never reported |
| **Binary feature name.** `AuroraMeter.track(org, "api")` keeps a second in-memory counter that seeds from and flushes into the same database row as `:api`. | one warning per distinct name, then today's behaviour | `ArgumentError` at the facade | pass the atom. The stored row is already keyed by the string form, so the history is preserved exactly. Anything that is neither an atom nor a binary raises in both releases |
| **Empty tenant key.** A tenant module returning `""` (which is also what the default resolver makes of `nil`). | one warning per node, then today's behaviour | `ArgumentError` naming the configured module | return a non-empty binary, or refuse the term. A resolver returning a non-binary raises in both releases. The error names the module and what it returned, never the term it was given |
| **`subscribe/2` with an unknown plan.** Today the row is written and the tenant silently resolves to the default plan for the life of the install. | one warning naming the plan id and the known ones, then today's write | `{:error, changeset}` with `plan_id: ["is not a known plan"]`; the return type is unchanged | check the plan ids you pass to `AuroraMeter.subscribe/2` |
| **`:default_plan` names no plan.** | one warning at boot naming the plans module and the known ids | `ArgumentError` at boot | fix the key |

Two more changes are the same in both releases and are listed here so 02d does
not have to hunt for them:

- A module-typed key (`:tenant`, `:storage`, `:provider`, `:period_source`,
  `:clock`, `:plans`) naming a module that cannot be loaded, or that does not
  export a callback its behaviour declares, raises at boot. Such a module would
  crash on first use anyway.
- A `metered` feature with a float `unit_price` warns at boot, in both releases.
  Integer minor units are the supported form; floats keep working.

## How the 1.0 half of each of those five is tested today

The mode is a compile-time constant, so a build of 0.4.0 cannot be strict and no
test can produce one. Each of the five behaviours therefore takes the mode as an
argument, and its public entry point supplies `Schema.mode()`:

| Behaviour | Transition half, end to end | Strict half |
|---|---|---|
| unknown configuration key | `Config.validate!(:transition)` | `Config.validate!(:strict)` |
| `:default_plan` names no plan | `Config.validate!(:transition)` | `Config.validate!(:strict)` |
| binary feature name | `AuroraMeter.track(org, "api_calls")` | `AuroraMeter.feature!("api_calls", :strict)` |
| empty tenant key | `AuroraMeter.Tenant.to_key/1` with a resolver that returns `""` | `AuroraMeter.Tenant.validate_key!(module, "", :strict)` |
| `subscribe/2` unknown plan | `Entitlements.subscribe(tenant, :nope, :transition)` | `Entitlements.subscribe(tenant, :nope, :strict)` |

The arity-plus-one forms are public but `@doc false`. This is the technique the
build document specifies for the configuration half ("both modes exercised by
calling the underlying validator with an explicit mode argument, so the test does
not depend on the package version"), applied to all five. What it proves is that
the strict branch behaves as documented; what it does not prove is that
`Schema.mode/0` returns `:strict` in a 1.0 build. That last step is one
`Version.compare/2` and is asserted directly:
`Schema.mode("1.0.0-rc.0") == :strict` and `Schema.mode("0.4.0") == :transition`.

## Warnings are deduplicated, and bounded

Each transition warning is logged **once per distinct subject per node**, through
a `:persistent_term` registry. A node warns once about `:some_feature` however
many times it is asked. Two nodes each warn once; that is intended.

After 128 distinct subjects in one category a node logs one line saying further
warnings are suppressed and stops recording, so a host that generates feature
names dynamically cannot grow the registry without bound.

The old warning was compiled behind `if Mix.env() == :dev`, and that is the
environment in which the **host** compiled the dependency, so a release build
warned about nothing at all. It is a runtime policy now and fires in every build.

## What is not in 0.5.0

No schema change, no migration, no column, no backfill. The unit is code only, so
rolling the image back restores the previous behaviour exactly.
