# Upgrading: 0.4.x to 0.5.0, and 0.5.x to 1.0

0.5.0 exists to warn you. It is the release that tells a running application
everything 1.0 will refuse, while refusing nothing itself. Upgrade to it, read
your logs for a while, fix what it names, and the 1.0 upgrade is a version bump.
Skip it and 1.0 is a boot failure you meet for the first time in production.

Two facts before anything else:

- **0.5.0 changes no schema.** `AuroraMeter.Migration.latest_version()` is 6 in
  0.4.0 and 6 in 0.5.0. There is no migration to run and nothing new is written
  to your database, so rolling back to 0.4.x is as safe as rolling forward.
- **0.5.0 adds no commercial term and no service level.** It is a compatibility
  release.

## Install it

```elixir
def deps do
  [{:aurora_meter, "~> 0.5"}]
end
```

Aurora Meter Pro 0.3.1 accepts either core, `~> 0.4 or ~> 0.5`, so the two can
be upgraded in whichever order suits your deploy.

## What 0.5.0 warns about, and what 1.0 does instead

Every row below logs once per node (or once per node per feature where that is
noted) and changes no behaviour in 0.5.x.

| What you will see in 0.5.x | What 1.0.0 does | What to do |
|---|---|---|
| `config :aurora_meter, <key>: ...` is not a key Aurora Meter knows, with the nearest key it does know | Refuses to boot. `AuroraMeter.Config.validate!/0` validates the whole application environment, so a typo cannot be silently dropped any more | Fix the spelling, or delete the key. A key that belongs to another library belongs under that library's own `config` |
| `feature :x is not declared on the tenant's plan`, once per feature per node | The entitlement functions deny it: `check/2` and friends return `{:error, :not_entitled}`, `allowed?/2` and `entitled?/2` return `false`, and `quota/2` answers `kind: :undeclared, enabled: false`. `track/4` still counts it, because metering is not entitlement | Declare the feature on the plans that should have it. Run `mix aurora_meter.features` to see every reference your configuration makes and every plan gap |
| `subscribe/2` was given a plan id no plans module declares, and the tenant was written anyway | Raises, naming the plan id and the plans it does know | Fix the plan id, or declare the plan |
| `default_plan: :x is not declared by MyApp.Plans` | Raises at boot | Point `:default_plan` at a plan that exists. Every tenant without an entitled subscription resolves through it |
| A feature name arrived as a binary rather than an atom, once per name | Raises `ArgumentError` | Pass the atom. Aurora Meter never calls `String.to_atom/1` on a feature name, and it never will: that is how a host turns user input into an unbounded atom table |
| Your `AuroraMeter.Tenant` implementation returned `""` from `to_key/1`, once per module | Raises `ArgumentError` | Return a non-empty binary. An empty key is one shared counter row for every tenant that produces it |
| A plan declares a metered feature with a float `unit_price` | Warns, exactly as 0.5.x does. This one does not become an error in 1.0 | Move to integer minor units (cents) when you can; a float is kept for compatibility and can lose precision |
| `durable_features: [...]` is deprecated | Still works. It is kept until 2.0 | Nothing today. The replacement is already here and additive: `feature_sources` says where a feature's commercial quantity comes from, and `AuroraMeter.record/4` records usage that must not be lost. Moving a feature that is already being billed needs a cutover; see [metering](metering.md) |

## The one thing 0.5.0 changes rather than warns about

A custom `:period_source` that returns an invalid period now raises
`AuroraMeter.Period.InvalidPeriodError` at first use, naming the source module.
"Invalid" means an interval that cannot be correct: a value that is not a map,
a missing `:source`, a `NaiveDateTime` instead of a `DateTime`, a zone that is
not `Etc/UTC`, an `end` at or before `start`, or a window that does not contain
the instant being resolved. The default calendar source and Pro's
subscription-aligned source both satisfy it.

If you wrote your own period source, run your suite against 0.5.0 before you
deploy it. The error names the module, the tenant key, the instant and the
period it was handed, so there is nothing to guess.

`AuroraMeter.Config.validate!/0` also checks at boot that the configured
`:period_source` and `:clock` modules load and export what the behaviour
requires, so a module that is simply missing fails the deploy rather than the
first request.

## The staged sequence for `undeclared_feature_policy`

The policy is the one setting whose 1.0 default (`:deny`) can change what your
application answers. Move through it deliberately.

1. **Upgrade to 0.5.0 and change nothing.** The default is `:warn`, which
   behaves exactly like 0.4.x and logs once per feature per node.

2. **Read what the configuration already knows**, which needs no traffic:

   ```bash
   mix aurora_meter.features
   ```

   Section 3 lists references your configuration makes that no plan declares,
   which are almost always typos. Section 4 lists plan gaps: a feature some
   plans declare and others do not, with the plans that would start denying it.
   Section 4 is the one that changes behaviour.

3. **Let it run.** The task reads configuration, not source, so a feature named
   only in a call site (`AuroraMeter.check(org, :something)`) is invisible to
   it. The `:warn` log and the `declared: false` metadata on
   `[:aurora_meter, :track]` telemetry are what find those. A week of real
   traffic is worth more here than any amount of reading.

4. **Make it fail in CI** once the log is quiet:

   ```bash
   mix aurora_meter.features --strict
   ```

   It exits 1 on an undeclared reference or a plan gap.

5. **Turn it on in staging**, then production:

   ```elixir
   config :aurora_meter, undeclared_feature_policy: :deny
   ```

   Do this while still on 0.5.x. Then 1.0 changes nothing, because you are
   already running its default.

If you would rather keep 0.4.x behaviour through the 1.0 upgrade and deal with
it later, that is a supported choice and it is one line:

```elixir
config :aurora_meter, undeclared_feature_policy: :allow
```

`:allow` is explicit, it is documented, and it will not be removed in 1.x. What
1.0 refuses is not the behaviour; it is inheriting the behaviour by accident.

During the transition, `:raise` is useful in `:test` and nowhere else: it turns
an undeclared feature into a failing test with the feature, the tenant key, the
plan id and the entry point in the exception.

## What is not in 0.5.0

`plan_version_conflict` is not a key in this release, on purpose. Detecting that
a compiled plan definition changed under a version tenants are already on means
comparing it against a stored fingerprint, and that table arrives with the 1.0
schema. Shipping the key inert would teach an operator to trust a check that is
not running, which is worse than not shipping it. It arrives with the plan
versioning work in 1.0.

## The schema route, 0.4.x or 0.5.x to 1.0

Everything above is about configuration and behaviour. This is the part that
touches your data. `AuroraMeter.Migration.latest_version()` is **6** in both
0.4.0 and 0.5.0 and **10** in 1.0, so there are four versions to apply and two
data tasks to run between them.

```bash
mix aurora_meter.gen.migration --upgrade -r MyApp.Repo
```

`--upgrade` reads the installed version from
`aurora_meter_checkpoints["schema:core"]` and writes **one file per version**
with explicit bounds, rather than one file that loops from wherever it finds
itself. Read the generated files before you run them.

| Order | Step | What it does | Reversible |
|---|---|---|---|
| 1 | Version 7 | Adds the columns the event identity needs | Yes |
| 2 | `mix aurora_meter.events.backfill` | Gives every legacy durable event an `event_id`. Idempotent: a second run scans and updates nothing | Yes |
| 3 | Version 8 | Unique index on `event_id`, `bigint` widening, six check constraints validated. Runs outside a transaction | Yes |
| 4 | Version 9 | Credit lots and allocations | Yes |
| 5 | `mix aurora_meter.credits.migrate_lots` | Moves each wallet onto lots. A wallet it declines stays on the legacy writer and keeps working, with the reason on its checkpoint row | **No** |
| 6 | Version 10 | Plan version snapshots and fingerprints | Yes |
| 7 | `MyApp.Plans.register!/0` | Assigns `plan_version` to existing subscriptions. The installed supervisor child does this at boot | Yes |

**Stop durable writers before step 3.** Anything calling `AuroraMeter.record/4`
or `track(..., durable: true)` must be quiet from step 2 until step 3 finishes:
the backfill and the unique index cannot agree while rows are still arriving
without an identity.

**Have every node on 1.0 before step 5.** A 0.4.x node writing through the
legacy balance while the lots are being built is the one interleaving the
cutover cannot repair.

**Step 5 is the rollback boundary.** Everything before it can be rolled back.
After it, roll forward.

The route was rehearsed against all four published states a host can be in
(core 1, core 2, core 2 with Pro 1, and core 6 with Pro 9), with money in the
ledger written by the published releases themselves rather than by hand. The
numbers are in the storefront's `docs/evidence/v1/phase-11/migration-matrix.md`.
**What is not measured yet** is how long each step takes and what it locks on a
production sized table; that is build unit 11b's, and this section will carry
its figures when it has them. Until then, rehearse on a copy of your own data.

If you run Aurora Meter Pro, its migrations come **after** all of this. See
Pro's `docs/upgrading.md`.

## After the upgrade

The contract you are upgrading into is [the guarantee page](guarantees.md): one
row per guarantee, each with the condition that makes it true and the test that
proves it. [The support policy](support-policy.md) says what SemVer covers, and
[the API inventory](api.md) is the surface it covers.
