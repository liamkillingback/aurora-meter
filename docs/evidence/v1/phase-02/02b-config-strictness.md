# 02b: configuration read whole, and checked

Build unit 02b, core `aurora_meter`. Open findings C1 (unknown keys dropped
before validation) and C10 (accessors restating defaults).

Source of every block below: `mix run tmp/v1/02b/config_report.exs`, exit 0,
log `tmp/v1/02b/logs/14-config-report.log`, plus
`mix test test/aurora_meter/config_strictness_test.exs`, exit 0, 20 passed,
log `tmp/v1/02b/logs/30-strictness-only.log`.

## Release strictness

```
mode/0 = :transition  (version 0.4.0)
default undeclared_feature_policy = :warn
```

`AuroraMeter.Config.Schema.mode/0` is derived from the package version at compile
time (`< 1.0.0-rc.0` is `:transition`), not from a configuration key. It is
computed through `mode/1` rather than returned as a literal, because a literal
lets the compiler prove every `mode() == :strict` branch dead and warn on it, and
this package compiles with `warnings_as_errors`. `mode/1` is also what lets the
suite exercise both halves without depending on the version.

## Every key in this package's own `:aurora_meter` test environment

This is the list the reserved-key rule had to survive: the package's own
`config/config.exs` puts two entries in `:aurora_meter` that are not Aurora Meter
settings, and a naive "reject everything outside the schema" would have refused
to boot the library's own test suite.

```
  AuroraMeter.TestRepo               RESERVED
  :broadcast_interval                schema key
  :default_plan                      schema key
  :ecto_repos                        RESERVED
  :flush_interval                    schema key
  :plans                             schema key
  :pubsub                            schema key
  :repo                              schema key

unknown candidate keys: []
```

| Key | Why it is reserved |
|---|---|
| `AuroraMeter.TestRepo` | A module key. Repo configuration is written under the same OTP application (`config :aurora_meter, AuroraMeter.TestRepo, [...]`, `config/config.exs`), so every host has at least one of these. The rule is the atom name starting with `"Elixir."`, which is what every module atom does. |
| `:ecto_repos` | The conventional key Ecto's own Mix tasks read out of an application, set at `config/config.exs` line 6. |
| `:included_applications` | Added to every application environment by OTP itself. It does not appear in the listing above because this application declares none, but `reserved?/1` covers it and the strictness suite asserts so. |

## The unknown-key report

Transition mode, one key:

```
config :aurora_meter: unknown key :flush_intervall (did you mean :flush_interval?). This version ignores it; Aurora Meter 1.0 will refuse to boot. Fix the spelling or remove the key.
```

Transition mode, two keys, one of which has no near neighbour:

```
config :aurora_meter: unknown keys :flush_intervall (did you mean :flush_interval?), :zzzz. This version ignores them; Aurora Meter 1.0 will refuse to boot. Fix the spelling or remove the key.
```

The nearest key is `String.jaro_distance/2` above 0.8, so a genuinely unrelated
key gets no guess rather than a misleading one.

Strict mode, same configuration, raised from `AuroraMeter.start_link/1`:

```
** (NimbleOptions.ValidationError) unknown options [:flush_intervall], valid options are: [:repo, :pubsub, :plans, :tenant, :default_plan, :storage, :provider, :period_source, :clock, :undeclared_feature_policy, :durable_features, :flush_interval, :broadcast_interval, :history, :subscription_cache_ttl, :cluster_sync, :credits_currency, :credits_overdraft_tolerance, :credits_low_balance_threshold, :credits_low_balance_handler]
```

Note for the reader: the build document expected `NimbleOptions` to produce its
own "did you mean" here. The version in the lock (`nimble_options 1.1.1`) does
not; it names the unknown key and lists every valid one. That is why the
transition-mode message computes the nearest key itself, and why the
`unknown_message/3` text is worth keeping when 1.0 flips the default.

## Module-typed keys, checked against the behaviour

Required callbacks are read from each behaviour's own `behaviour_info/1`, minus
its optional callbacks, so a callback added later is enforced without anyone
editing a list. `AuroraMeter.Clock` went from two callbacks to three to four
inside one day and a hand-copied list went stale both times.

```
  tenant         AuroraMeter.Tenant.Default
                 requires [to_key: 1]  -> ok
  storage        AuroraMeter.Storage.Ecto
                 requires [add_counters: 1, add_history: 1, flush_batch: 3, get_subscription: 1, insert_events: 1, load_counter: 3, load_history: 3, load_history_range: 4, put_subscription: 1, stream_counters: 1, upsert_counters: 1, upsert_history: 1]  -> ok
  provider       AuroraMeter.Billing.Noop
                 requires [billing_portal_url: 2, create_checkout_session: 2, report_usage: 1, sync_subscription: 1]  -> ok
  period_source  AuroraMeter.Period.Calendar
                 requires [current: 2]  -> ok
  clock          AuroraMeter.Clock.System
                 requires [db_now: 0, monotonic_ms: 0, now: 0, today: 0]  -> ok
  plans          AuroraMeter.TestPlans
                 requires [__aurora_plans__: 0]  -> ok
```

`period_source` requires `current/2` and not `containing/2`, because
`AuroraMeter.Period` marks `containing/2` optional; the checker subtracts
`behaviour_info(:optional_callbacks)` rather than hard-coding that.

A module that does not export its callback, in either mode:

```
** (ArgumentError) config :aurora_meter, tenant: AuroraMeter.Test.PolicyPlans does not export to_key/1. It must be a module implementing AuroraMeter.Tenant.
```

A module that cannot be loaded at all:

```
** (ArgumentError) config :aurora_meter, period_source: AuroraMeter.NoSuchPeriodSource could not be loaded. It must be a module implementing AuroraMeter.Period.
```

This raises in **both** modes on purpose: such a module would crash on first use
anyway, there is no false positive to weigh against, and boot is the honest place
for it to fail.

## Two boot checks that warn rather than fail

| Check | Transition | Strict (1.0) |
|---|---|---|
| `:default_plan` names no plan | warning naming the plans module and the known plan ids | `ArgumentError` |
| a `metered` feature declares a float `unit_price` | one warning per plan and feature | the same warning; never an error |

The float warning is a warning in both modes because `aurora_api` ships float
unit prices today (`api-change-map.md` section 1.4). Observed text, from
`AuroraMeter.Test.FloatPricePlans`:

```
config :aurora_meter, plans: plan :free declares :float_priced with a float unit_price (0.05). Integer minor units (cents) are the supported form; a float is kept for compatibility and may lose precision.
config :aurora_meter, plans: plan :pro declares :float_priced with a float unit_price (0.05). Integer minor units (cents) are the supported form; a float is kept for compatibility and may lose precision.
```

## Defaults are written once

Every optional key's default now lives in the `NimbleOptions` schema and is read
back by the accessors through one `Application.get_env/3` call:

```elixir
defp get(key), do: Application.get_env(:aurora_meter, key, Map.fetch!(@defaults, key))
```

`Map.fetch!/2` means an accessor for a key the schema does not declare fails at
its first call rather than inventing a value. The strictness suite asserts three
things about this: every accessor returns the schema default when the key is
unset, every schema key with a default has a zero-arity accessor, and the module
reads the environment with a fallback in exactly one place (matched by content,
not by line number, per `open-findings.md` X67).

```
  :broadcast_interval                1000
  :clock                             AuroraMeter.Clock.System
  :cluster_sync                      true
  :credits_currency                  "usd"
  :credits_low_balance_handler       nil
  :credits_low_balance_threshold     nil
  :credits_overdraft_tolerance       0
  :default_plan                      :free
  :durable_features                  []
  :flush_interval                    5000
  :history                           true
  :period_source                     AuroraMeter.Period.Calendar
  :provider                          AuroraMeter.Billing.Noop
  :storage                           AuroraMeter.Storage.Ecto
  :subscription_cache_ttl            5000
  :tenant                            AuroraMeter.Tenant.Default
  :undeclared_feature_policy         :warn
```

`:repo`, `:pubsub` and `:plans` are required and are absent from this map by
design: they keep `Application.fetch_env!/2` and have no default to drift.
