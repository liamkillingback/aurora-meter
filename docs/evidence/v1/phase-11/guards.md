# Core guards: the prefix that was silently ignored, and the down that is not a rollback

Build unit **11b**, tasks **11.05** and **11.07**, core half. Written
2026-09-17. Branch `aurorameter-v1`, nothing committed and no checkbox ticked
(rule 4).

## The defect, in one line

`AuroraMeter.Migration.up/1` read `:from` and `:version` and **dropped every
other option**, so `AuroraMeter.Migration.up(prefix: "tenant_a")` migrated the
repository's default schema and returned `:ok`. A host that believed it had
installed into `tenant_a` had a schema in one place, every query reading
another, and no error anywhere.

There is one fact underneath all of this and it is worth stating on its own:
**every query this package issues omits the prefix.** A repository-wide read of
`lib/` finds no `prefix:` passed to `table/2` or `index/2`, no
`@schema_prefix`, and no prefix on any `Storage.Ecto` call. So a prefix that
reached the migrations and not the queries would split the package from its own
tables, and the first symptom would be an empty ledger rather than an error.

V1 refuses a prefix in all three places a host can ask for one.

## 1. In the call: `ArgumentError`, naming the option

Verbatim, from the compiled code:

```
AuroraMeter.Migration.up/1 does not understand :prefix. Supported: :from,
:version, :concurrently, :validate_checks, :lock_timeout. :prefix is refused
rather than ignored: Aurora Meter V1 creates and reads its tables in the
repository's default schema only, and every query this package issues omits the
prefix, so a migration that honoured one would build the tables in a schema no
query would ever read. A non-default Postgres schema and a schema-per-tenant
layout are both unsupported in V1.
```

`down/1` is the same with its own option list (`:version, :to, :concurrently,
:validate_checks, :confirm_data_loss`). An option that is not `:prefix` gets the
first sentence and the list, without the prefix paragraph:

```
AuroraMeter.Migration.up/1 does not understand :nonsense. Supported: :from,
:version, :concurrently, :validate_checks, :lock_timeout.
```

The supported list is not a list someone remembered. It is
`@up_options`/`@down_options` in `lib/aurora_meter/migration.ex`, and it is
exactly the set the dispatcher and every version module read: `:from`,
`:version`, `:to`, `:concurrently`, `:validate_checks`, `:lock_timeout`,
`:confirm_data_loss`, found by reading every `Keyword.get(opts, ...)` in
`lib/aurora_meter/migration.ex` and `lib/aurora_meter/migration/v*.ex`. A test
runs every one of them through `up/1` against a real database, so a guard that
refused everything would fail rather than pass.

**This is a behaviour change for any host that passed an option this package
ignored.** No published example ever passed one; the documented forms are
`up()`, `up(from: n)` and `up(from: n, version: m)`.

## 2. In the repository: `AuroraMeter.Config.PrefixError` at boot

`Config.validate!/0` now reads the configured repository's own configuration.
Two settings are refused, and both are real Ecto features rather than invented
ones:

- `migration_default_prefix` (`ecto_sql`'s `Ecto.Migration` option, read by the
  migrator at `migration.ex:1762`), which decides where the tables are created;
- a `:prefix` returned by the repository's `default_options/1` callback for
  `:all`, `:insert_all` or `:update_all`, which decides where the queries go.
  Those three are the operations this package issues: `Storage.Ecto` reads with
  `all`, writes counters, events and receipts with `insert_all`, and the ledger
  updates balances with `update_all`.

```
config :my_app, MyApp.Repo, migration_default_prefix: "tenant_a" would migrate
Aurora Meter into the "tenant_a" schema, while every query this package issues
reads the repository's default schema. Remove :migration_default_prefix from
the repository Aurora Meter is configured with, or give Aurora Meter a
repository of its own that does not set it. Aurora Meter V1 stores its tables
in the repository's default schema; non-default Postgres schemas and
multi-tenant schema prefixes are not supported.
```

```
MyApp.Repo.default_options(:all) returns prefix: "tenant_a", which would send
every Aurora Meter query to the "tenant_a" schema, while its migrations create
the tables in the repository's default schema. Stop returning a :prefix from
MyApp.Repo.default_options/1, or give Aurora Meter a repository of its own that
does not. Aurora Meter V1 stores its tables in the repository's default schema;
non-default Postgres schemas and multi-tenant schema prefixes are not
supported.
```

`nil` and `"public"` are accepted for both, because naming the schema Aurora
Meter already uses is not a mistake. A module that exports neither `config/0`
nor `default_options/1` is **not inspected**: it is not an Ecto repository yet,
Ecto reports that far better than this check could, and guessing is how a check
ends up answering about something it cannot see. Both of those are tests, not
intentions.

The check runs from `AuroraMeter.start_link/1`, which is the earliest point in
the process where the host's mistake is visible.

## 3. On the migration runner: the same error, before anything runs

`mix ecto.migrate --prefix tenant_a` sets the prefix on the runner rather than
in the call, and neither of the first two guards can see it. `up/1` and `down/1`
read `Ecto.Migration.prefix/0` and refuse:

```
this migration is running with prefix "tenant_a" (from `mix ecto.migrate
--prefix` or the repository's migration_default_prefix). Aurora Meter V1
creates its tables in the repository's default schema only: `create table`
would honour the prefix, every `execute` in these versions and every runtime
query would not, and the result is a database half in one schema and half in
another. Nothing has been created; re-run without the prefix. ...
```

"Nothing has been created" is asserted rather than claimed: the test creates the
`tenant_a` schema, runs the migration under it, and then checks that no
`aurora_meter_%` table exists in either `tenant_a` or `public`. One table does
appear in `tenant_a`: Ecto's own `schema_migrations`, which the migrator creates
in the prefix before any migration runs. That is the migrator's bookkeeping and
not one of this package's tables, and it is excluded by name with that reason.

Outside a migration runner `Ecto.Migration.prefix/0` raises, which is how the
guard knows there is no prefix to read: `up/1` called from a test or a release
task is unaffected.

**Pro inherits all three.** Pro has no repository setting of its own: every
query it issues resolves through `AuroraMeter.Config.repo/0`. The 11b build
document asked for an assertion in `AuroraMeter.Pro.validate!/0` that the Pro
repo is core's repo; there is nothing that could differ, so the assertion is not
written and a **test** stands in its place, failing the day
`config :aurora_meter_pro, repo:` exists. See Pro's `guards.md`.

## 4. `down` is refused unless the loss is confirmed

11a landed `DataLossError` and the destructive-version list; this unit proved
the half nobody had run, which is that a refused `down` really does leave the
tables in place.

`AuroraMeter.Migration.down(version: 10, to: 1)` against a database at version
10 raises, names all seven destructive versions in the range with the reason for
each, and **changes nothing**: the test snapshots `pg_tables` before the call
and asserts it is unchanged after. With `confirm_data_loss: true` the same call
on a disposable database drops `aurora_meter_events`,
`aurora_meter_counters`, `aurora_meter_subscriptions`,
`aurora_meter_credit_balances` and `aurora_meter_credit_transactions`, which is
the negative control: a guard that refused every `down` would satisfy the first
test and make the second impossible.

`down(version: 6, to: 5)` needs no confirmation and leaves
`aurora_meter_events` in place while removing `aurora_meter_flush_receipts`, so
"destructive" means something narrower than "any down at all".

The list is `@data_loss_reasons` in `lib/aurora_meter/migration.ex` and is
compared with `schema-migration-map.md` section 3 by
`test/aurora_meter/migration_map_test.exs`, which 11a wrote.

## 5. Version 8 converges on one valid index

The invalid-index recovery is **03a's**, already in
`lib/aurora_meter/migration/v8.ex:135-146` (`drop_invalid_index/1`) and
`:168-186` (`verify_index/1`). This unit added the test that the recovery is
for the state Postgres actually leaves.

The existing test in `migration_v8_test.exs` produces an invalid index by
`UPDATE pg_index SET indisvalid = false`, which proves the guard reads the
catalogue but not that Postgres ever leaves that state. The new test produces it
for real: two rows claiming the same `(tenant_key, event_id)`, then
`CREATE UNIQUE INDEX CONCURRENTLY` by hand, which fails with a unique violation
and leaves the INVALID index behind. The test asserts that state exists before
going on, with the message

> Postgres is expected to leave an INVALID index behind; if it does not, the
> guard in version 8 is being tested against a state that cannot occur

then removes the duplicate and applies version 8, which drops the invalid index
and builds a valid one: exactly one index of that name, `indisvalid = true`.
Applying version 8 twice leaves the same.

## 6. A re-run of the whole history is a no-op, for core

`AuroraMeter.Migration`'s moduledoc says "Every version is idempotent
(`create_if_not_exists`), so `up/1` can safely run from version 1 each time".
Checked rather than trusted: `up(from: 1, version: 10, concurrently: false)`
twice against a disposable database raises nothing and produces a
byte-identical catalogue.

**The same is not true of Pro version 10**, which is a finding rather than a
fix here; see Pro's `guards.md` and `open-findings.md` X474.

## Tests

`test/aurora_meter/migration_guards_test.exs`, 22 tests, all tagged
`:migration`:

| Group | Tests |
|---|---|
| L-11b-1 unknown options | 7: `up`/`down` on an unknown key and on `:prefix`, a misspelled known key, a non-keyword argument, and the negative control that runs every supported option against a real database |
| L-11b-2 repository prefix | 7: `migration_default_prefix`, `default_options(:all)`, `default_options(:insert_all)`, `nil`, `"public"`, a module that is not a repository, and the suite's own repository |
| L-11b-2 runner prefix | 2: refused under `--prefix` with nothing created; the same migration with no prefix runs |
| L-11b-3 `down` | 3: refused and unchanged, a non-destructive range, and a confirmed `down` that really drops |
| I16 re-run | 1: the whole history twice, same catalogue |
| L-11b-4 version 8 | 2: after a real aborted concurrent create, and applied twice |

Plus `test/aurora_meter/migration_test.exs` gains one: **the test repo applies
versions in ascending order** (T11).

## T11: the test repo now applies versions in the order a customer does

Core's `priv/test_repo/migrations` applied version 6 before versions 4 and 5,
because the files were added in the order the versions were built rather than
in the order they run. One rename fixes it
(`20260911135608_upgrade_core_v6.exs` to `20260911235608_...`), and the new test
reads the applied sequence out of the filenames and asserts it is ascending and
complete.

The suite was green before and after, which is the point: an ordering defect is
invisible to a suite that only ever runs one order, and that order was not a
customer's. Pro's repo had two more (Pro 8 before 6 and 7; Pro 10 before core 9
and 10) and is renamed the same way; see Pro's `guards.md`.

The test databases were dropped and rebuilt so the renamed files applied from
scratch.

## Files changed

```
lib/aurora_meter/migration.ex                  option validation, runner prefix guard
lib/aurora_meter/config.ex                     check_repo_prefix!/1 in validate!/0
lib/aurora_meter/config/errors.ex              AuroraMeter.Config.PrefixError (new)
lib/aurora_meter/install/plan.ex               detect_from/2 and refuse_existing!/3 (X432)
lib/mix/tasks/aurora_meter.gen.migration.ex    --upgrade (X432)
priv/test_repo/migrations/...upgrade_core_v6   renamed (T11)
test/aurora_meter/migration_guards_test.exs    new
test/aurora_meter/migration_test.exs           the ascending-order test
test/mix/tasks/gen_migration_test.exs          the --upgrade tests
docs/upgrading-to-1.0.md                       the measured lock budget and the rollback matrix
```

No migration version number moved and no DDL changed.
