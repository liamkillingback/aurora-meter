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

**If a step dies, the next run of it will refuse, and that is the interlock
rather than a failure.** Both data tasks hold a Postgres advisory lock for the
length of a run and leave `state = "running"` on their checkpoint row. A
process that is killed releases the lock with its connection but cannot clear
the row, so the next invocation sees `"running"` with the lock free and stops:

```
** (Mix) a previous run of this task was killed ... pass --force-resume to
   continue from seq <n>.
```

Check that no other copy of the task is running, then re-run it with
`--force-resume`. It continues from the last committed batch and re-processing
a batch is a no-op, so nothing is counted twice. This was proved by killing the
task with `kill -9` inside an open transaction at three different points and
comparing the end state against an uninterrupted run: identical on all 25
tables, every time
(`docs/evidence/v1/phase-11/interrupt.md` in the storefront).

**Have every node on 1.0 before step 5.** A 0.4.x node writing through the
legacy balance while the lots are being built is the one interleaving the
cutover cannot repair.

**Step 5 is the rollback boundary.** Everything before it can be rolled back.
After it, roll forward.

The route was rehearsed against all four published states a host can be in
(core 1, core 2, core 2 with Pro 1, and core 6 with Pro 9), with money in the
ledger written by the published releases themselves rather than by hand. The
numbers are in the storefront's `docs/evidence/v1/phase-11/migration-matrix.md`.

## What it locks, and for how long

Measured on **1,000,000 events**, on Postgres **16.13**, four times, on one
machine that was busy. The full record, including the spread between runs, is
`docs/evidence/v1/phase-11/locks.md` in the storefront.

| Step | What it holds | A reader was blocked for | Per 1,000,000 rows |
|---|---|---|---|
| Version 7 | ACCESS EXCLUSIVE on `aurora_meter_events` for the whole rewrite | **3.3 to 8.7 seconds** | 4.2 to 9.6 seconds of wall time |
| `events.backfill` | nothing: no ACCESS EXCLUSIVE lock was ever observed | **1.4 ms** | 37 to 55 seconds |
| Version 8 | nothing for the index (it is built `CONCURRENTLY`); ACCESS EXCLUSIVE for 0.5 to 2.1 seconds for the three `NOT NULL` promotions | **0.15 to 1.83 seconds** | 4.6 to 12.5 seconds |
| Versions 9 and 10 | nothing on `aurora_meter_events` | **1.1 ms** | 1 to 2 seconds |

**Version 7 is the outage.** Between 115,000 and 300,000 rows a second across
four runs, so plan with the low figure: **budget one second of full-table
outage per 100,000 events**, round up, and add the time it takes to get the
lock. Ten million events is somewhere between half a minute and a minute and a
half of every query on that table waiting.

Above roughly **fifty million events**, or wherever that budget stops being an
acceptable maintenance window, the alternative is the ordinary one: add a new
`bigint` column, dual-write to both, backfill in batches, and swap. Aurora
Meter does not do this for you in V1, and the threshold is a number about your
tolerance rather than about the database.

**Version 7 fails fast rather than queueing.** It sets `SET LOCAL lock_timeout`
(default `"5s"`, overridable with `AuroraMeter.Migration.up(lock_timeout:
"30s")`), so a rewrite that cannot get the lock is cancelled rather than
waiting, because everything arriving behind it in the lock queue waits too.
Measured behind a held `SHARE` lock: it fails after the timeout with
`ERROR 55P03 (lock_not_available) canceling statement due to lock timeout`, the
table is **unchanged** (6 columns before, 6 after), and Ecto has not recorded
the version, so the next `mix ecto.migrate` runs the same file again. A
`lock_timeout` failure is a safe failure; find the transaction that is holding
the table and retry in a quieter minute.

Before version 8, check for long-running transactions. `CREATE INDEX
CONCURRENTLY` takes no exclusive lock but it waits for every transaction that
was open when it started:

```sql
SELECT pid, state, xact_start, left(query, 120)
FROM pg_stat_activity
WHERE datname = current_database()
  AND state <> 'idle'
  AND xact_start < now() - interval '1 minute'
ORDER BY xact_start;
```

## How much disk it needs, which is more than you would guess

**Three and a half times** the current total size of `aurora_meter_events`,
free, before you start:

| | Before version 7 | After version 10 |
|---|---|---|
| table | 126 MB | 426 MB |
| indexes | 50 MB | 196 MB |
| total relation | **176 MB** | **623 MB** |

Most of that is data that is supposed to be there: `event_id`, `payload_hash`,
`occurred_at`, `period_start`, `period_source`, `attribution`, `kind`,
`dimensions` and `seq` on every row, plus two new indexes. Some of it is the
dead tuples the backfill's `UPDATE` leaves behind, and **a plain `VACUUM` does
not give that back**: measured at 426 MB before the vacuum and 426 MB after.
Vacuum makes the space reusable, not free. `VACUUM FULL` would return it and
would take exactly the exclusive lock the rest of this section is about keeping
short, so do not run one as part of the upgrade.

## What an 0.4.0 node can do while this is happening

Measured with a real 0.4.0 node running against the database throughout, in its
own OS process, doing `track`, `flush`, `usage` and `history` every 700 ms
(`docs/evidence/v1/phase-11/rolling.md` in the storefront).

| After | An 0.4.0 node's buffered `track`, `flush`, `usage` and `history` | An 0.4.0 node's `track(durable: true)` |
|---|---|---|
| version 7 | works, unchanged | works |
| the backfill | works, unchanged | works; the rows it writes after the scan has passed them stay without an identity, and the next backfill pass takes them |
| version 8 | **works, unchanged** | **raises** `ERROR 23502 not_null_violation` on `event_id` |
| versions 9 and 10 | works, unchanged | (still raises) |

So the quiescence point before version 8 is narrower than draining the fleet:
**only the durable writers have to stop.** Most installs have none.

One detail worth knowing if you have them: `track/4` bumps the in-memory
counter **before** it inserts the durable row, so a call that fails this way
still counted. Measured: `usage` went from 31 to 32 on a call whose insert
raised. You lose the durable record of that call, not the count.

If you run Aurora Meter Pro, its migrations come **after** all of this. See
Pro's `docs/upgrading.md`.

## Rolling back

`down` is **never** a rollback. It destroys the facts a rollback exists to
preserve: version 7's `down` removes `event_id` and `payload_hash`, which are
the identity of every recorded fact, and drops `aurora_meter_event_totals` and
`aurora_meter_checkpoints` with them. `AuroraMeter.Migration.down/1` refuses a
range containing any such version unless you pass `confirm_data_loss: true`,
and it names each one and what it destroys.

Rollback means putting the previous image back and leaving the schema where it
is. What that is safe after:

| After | Previous image | Why |
|---|---|---|
| version 7 | **safe** | additive; every new column is nullable or defaulted, and old code neither reads nor writes them |
| the backfill | **safe** | data only, in columns old code does not read |
| version 8 | **safe if nothing calls `track(..., durable: true)` or `record/4`**; not safe if something does | the old durable insert violates `event_id NOT NULL`. Its buffered path is unaffected |
| version 9 | **safe** | the lot tables exist but `lots_enabled_at` is null on every wallet, so the legacy writer is still the only writer |
| `credits.migrate_lots` | **not safe. Forward fix only** | a rolled-back node ignores `lots_enabled_at` and writes legacy arithmetic over the lots. The next allocator write refuses with a conservation error, so it is caught, but the wallet is already wrong |
| version 10 | **safe until a transition is scheduled** | an 0.4.0 node's subscription upsert leaves the new columns alone, because Ecto builds its replace list from that binary's own schema and the new columns are not in it. Measured, not assumed |

**After version 10, roll forward.** After the wallet migration, the only options
are a forward fix or a point-in-time restore, and a restore loses every write
since the backup.

Take the backup before version 7, and test it. A `pg_dump -Fc` taken before the
upgrade, restored into a fresh database and upgraded again, produced an
identical reconciliation document and identical per-table checksums on all 25
tables, and a replay of the restored copy reproduced its projection exactly
(`docs/evidence/v1/phase-11/backup-restore.md` in the storefront).

## Schemas and prefixes

Aurora Meter V1 stores its tables in the repository's default schema.
Non-default Postgres schemas and schema-per-tenant prefixes are **not
supported**, and V1 refuses them rather than half-honouring them:

- `AuroraMeter.Migration.up(prefix: "tenant_a")` raises `ArgumentError`;
- a repository that sets `migration_default_prefix`, or whose
  `default_options/1` returns a `:prefix`, fails to boot with
  `AuroraMeter.Config.PrefixError`, naming the key;
- `mix ecto.migrate --prefix tenant_a` raises the same error before any version
  runs, and creates nothing.

The reason is one fact: every query this package issues omits the prefix. A
prefix that reached the migrations and not the queries would put the tables in
one schema and read from another, and the first symptom would be an empty
ledger rather than an error.

## After the upgrade

The contract you are upgrading into is [the guarantee page](guarantees.md): one
row per guarantee, each with the condition that makes it true and the test that
proves it. [The support policy](support-policy.md) says what SemVer covers, and
[the API inventory](api.md) is the surface it covers.
