# 02b: `mix aurora_meter.features`

Build unit 02b, core `aurora_meter`. The scanner an operator runs before moving
`:undeclared_feature_policy` to `:deny`.

## What it reads, and what it cannot see

It reads **configuration**, not source: the plans module, `:durable_features`,
`:feature_sources` (skipped while the key is absent, which it is until build unit
03c), and, when an `:aurora_meter_pro` application environment is present, its
`:stripe_meters`. Pro's environment is read by application name only, so core
names no Pro module and gains no dependency on Pro.

A feature named only in a call at runtime (`AuroraMeter.check(org, :something)`)
is invisible to it. The runtime answer to that is the `declared:` metadata on
`[:aurora_meter, :track]` and the one-per-feature log the `:warn` policy emits,
which is why the documented upgrade sequence is scan, then run on `:warn` for a
release, then deny.

Deliberately **not** read: `:aurora_meter_pro`'s `:stripe_metered_prices`. The
build document lists it beside `:stripe_meters`, but its keys are plan ids, not
features (`Pro.Config.metered_prices_for/1` looks them up by plan), so treating
them as features would report every plan id as an undeclared feature. Recorded as
a proposed finding for `open-findings.md`.

## Against the package's own test plans

`mix aurora_meter.features`, exit 0, log `tmp/v1/02b/logs/16-scanner-ok.log`:

```
Aurora Meter features, from AuroraMeter.TestPlans

1. Declared features per plan
  free (price 0)
    ai_generations: hard limit, 50
    api_access: feature, denied
    seats: feature value, 1

  payg (price 0)
    api_access: feature, granted
    requests: counter
    seats: feature value, 25

  pro (price 2000)
    ai_generations: hard limit, 1000
    api_access: feature, granted
    seats: feature value, 5

  scale (price 2000)
    ai_generations: metered, 1000 included, 2
    api_access: feature, granted
    seats: feature value, 25

2. Features referenced by configuration
  (none)

3. Undeclared references
  (none)

4. Plan gaps
  :ai_generations: declared on :free, :pro, :scale; would be denied on :payg
  :requests: declared on :payg; would be denied on :free, :pro, :scale
```

Section 2 is `(none)` because this package's `config/config.exs` sets neither
`:durable_features` nor `:feature_sources`. An **absent** key is skipped rather
than reported as an empty reference, which is the difference between "nothing is
configured" and "something is configured and it is empty".

`mix aurora_meter.features --strict` on the same configuration: **exit 1**, log
`tmp/v1/02b/logs/17-scanner-strict.log`. The plan gaps in section 4 are enough on
their own, which is the point: `:requests` is a counter on `:payg` and nothing at
all on the other three, so a `:free` tenant calling it is answered permissively
today and refused under `:deny`.

## Against a deliberately broken configuration

`mix run tmp/v1/02b/scanner_broken.exs`, which sets
`durable_features: [:policy_hard, :not_a_feature]` and
`config :aurora_meter_pro, stripe_meters: %{policy_metered: "m1", never_declared: "m2"}`
against `AuroraMeter.Test.PolicyPlans`, then runs the task with `--strict`.
**Exit 1**, log `tmp/v1/02b/logs/18-scanner-broken.log`:

```
2. Features referenced by configuration
  config :aurora_meter, :durable_features: :not_a_feature, :policy_hard
  config :aurora_meter_pro, :stripe_meters: :never_declared, :policy_metered

3. Undeclared references
  :not_a_feature is referenced by config :aurora_meter, :durable_features and declared by no plan
  :never_declared is referenced by config :aurora_meter_pro, :stripe_meters and declared by no plan

4. Plan gaps
  :elsewhere: declared on :policy_other; would be denied on :free, :policy
  :policy_boolean_false: declared on :policy; would be denied on :free, :policy_other
  :policy_boolean_true: declared on :policy; would be denied on :free, :policy_other
  :policy_counter: declared on :policy; would be denied on :free, :policy_other
  :policy_hard: declared on :policy; would be denied on :free, :policy_other
  :policy_integer: declared on :policy; would be denied on :free, :policy_other
  :policy_metered: declared on :policy; would be denied on :free, :policy_other

** (Mix) aurora_meter.features --strict: the configuration references features no plan declares, or declares a feature on some plans and not others. See the sections above.
```

`:policy_hard` and `:policy_metered` are referenced and declared, so they appear
in section 2 and not in section 3. That is the distinction section 3 is for.

## Exit codes

| Situation | `mix aurora_meter.features` | with `--strict` |
|---|---|---|
| clean (no undeclared reference, no plan gap) | 0 | 0 |
| an undeclared reference | 0 | 1 |
| a plan gap | 0 | 1 |

`--strict` exits 1 through `Mix.raise/1`, which is how every other Mix task in
this package reports a failure and what the `mix` CLI turns into status 1. The
exit codes above are the real ones, recorded by the shell in
`02b-commands.txt`, not an assertion about `Mix.raise/1`.

Unit tests: `test/mix/tasks/features_test.exs`, 10 tests, run together with
`test/mix/tasks/install_test.exs` (3 tests), 13 passed, log
`tmp/v1/02b/logs/09-tasks.log`.
