# 09b: every migration file the two packages generate

Build unit 09b, finding **S1** ("generated host migrations are unbounded",
BLOCKS V1), invariant **I19**. Captured 2026-09-16 (UTC) by
`tmp/v1/09b-generate.sh`; the files themselves are in `tmp/v1/09b/migrations/`.

## What was wrong

Four things generate a host migration: `mix aurora_meter.install`,
`mix aurora_meter.gen.migration`, `mix aurora_meter_pro.install` and
`mix aurora_meter_pro.gen.migration`. **Three of the four emitted an unbounded
call.**

    def up, do: AuroraMeter.Migration.up()
    def down, do: AuroraMeter.Migration.down()

`Migration.up/1` defaults `from` to 1 and `version` to the latest the installed
package knows, so a committed file runs to whatever version is installed **on
the day it is applied**. Two databases built from the same file, one today and
one after the next release, end up with different schemas, and a host's
migration history stops being a record of anything. It is also the precondition
for 11a's fixtures: an unbounded `up()` in a fixture applies V10 while claiming
to be a V2 host.

Core's **generator** had already been fixed (05c, against `Migration.ranges`-like
private helpers). Core's **installer** had not. So the two supported ways of
installing one package produced two different files, and only one of them was
reproducible. That is the shape worth remembering: a fix applied to one of two
code paths is not a fix, and nothing compared them.

## What generates them now

One module, `AuroraMeter.Install.Plan` (core `lib/`, `@moduledoc false`), read by
all four callers. Pro's tasks reach it across the package boundary the same way
they already reach `AuroraMeter.Install.Oban` (X201: a hundred lines of Sourceror
copied across a boundary is a copy that will drift). Two tests assert the
installer and the generator emit the same body, one per package, so the four
cannot drift apart again.

`Plan.files/1` reads `AuroraMeter.Migration.ranges/1` and
`AuroraMeter.Pro.Migration.ranges/1`, both new and both public, which split a
version range into the files it has to become: a contiguous run of ordinary
versions travels in one file, and a concurrent version travels alone, because
`@disable_ddl_transaction` and `@disable_migration_lock` are file-level
attributes and would otherwise apply to every version sharing the file.

    iex> AuroraMeter.Migration.ranges(from: 7)
    [
      %{from: 7, to: 7, concurrent: false},
      %{from: 8, to: 8, concurrent: true},
      %{from: 9, to: 10, concurrent: false}
    ]

## Core, a fresh install

One file. `concurrently: false`, because the database is empty and V8's index
has no rows to lock, so it can be built inside the transaction like any other
statement. `confirm_data_loss: true` on the `down`, because undoing an install is
exactly the case where dropping the tables is what was asked for.

```elixir
defmodule AuroraMeter.TestRepo.Migrations.AddAuroraMeter do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 1, version: 10, concurrently: false)
  def down, do: AuroraMeter.Migration.down(version: 10, to: 1, confirm_data_loss: true)
end
```

## Core, `--from 7`

Three files, one second apart so the timestamp order is the order they have to
run in.

```elixir
# 20260916160403_upgrade_aurora_meter_v7.exs
defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV7 do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 7, version: 7)
  def down, do: AuroraMeter.Migration.down(version: 7, to: 7, confirm_data_loss: true)
end
```

```elixir
# 20260916160404_upgrade_aurora_meter_v8_concurrent.exs
defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV8Concurrent do
  use Ecto.Migration

  # This version creates a unique index CONCURRENTLY, which Postgres refuses
  # inside a transaction block and which cannot hold the Ecto migration lock
  # either. Both attributes are required; without them
  # AuroraMeter.Migration.up/1 raises rather than fail halfway through.
  @disable_ddl_transaction true
  @disable_migration_lock true
  def up, do: AuroraMeter.Migration.up(from: 8, version: 8)
  def down, do: AuroraMeter.Migration.down(version: 8, to: 8)
end
```

```elixir
# 20260916160405_upgrade_aurora_meter_v9_to_v10.exs
defmodule AuroraMeter.TestRepo.Migrations.UpgradeAuroraMeterV9ToV10 do
  use Ecto.Migration

  def up, do: AuroraMeter.Migration.up(from: 9, version: 10)
  def down, do: AuroraMeter.Migration.down(version: 10, to: 9, confirm_data_loss: true)
end
```

Version 8 is alone in its file, it carries **both** attributes, and no
transactional version shares that file. The file name says so, and it sorts
between the two it has to run between. The comment in it is generated, not
written by hand into a host's tree afterwards, because the attribute is easy to
merge away and the failure it prevents is a half-applied migration.

## Pro, a fresh install and `--from 9`

```elixir
defmodule AuroraMeter.Pro.TestRepo.Migrations.AddAuroraMeterPro do
  use Ecto.Migration

  def up, do: AuroraMeter.Pro.Migration.up(from: 1, version: 11)
  def down, do: AuroraMeter.Pro.Migration.down(version: 11, to: 1)
end
```

```elixir
defmodule AuroraMeter.Pro.TestRepo.Migrations.UpgradeAuroraMeterProV9ToV11 do
  use Ecto.Migration

  def up, do: AuroraMeter.Pro.Migration.up(from: 9, version: 11)
  def down, do: AuroraMeter.Pro.Migration.down(version: 11, to: 9)
end
```

Two deliberate differences from core, both recorded rather than left to be
noticed:

- **No `concurrently: false`.** `AuroraMeter.Pro.Migration.concurrent_versions/0`
  is `[]`, so there is no option to pass. It is a list rather than an assumption:
  when 11a adds a version that builds an index concurrently, it goes in that list
  and everything else follows, and a test asserts the list is empty today so the
  day it stops being empty is loud.
- **No `confirm_data_loss: true`.** `AuroraMeter.Pro.Migration.down/1` has no
  data-loss guard yet; that guard is build unit 11b's. Emitting the option now
  would put a word in a host's committed file that nothing reads, which reads as
  a guarantee and is not one. A test asserts the absence **against the absence of
  the guard**, so it fails the day 11b adds one.

## What no generated file contains

Asserted in both packages, by shape rather than by spelling: no
`Migration.up(` or `Migration.down(` with an empty argument list, in any file,
for a fresh install or an upgrade, matched with `~r/\.up\(\s*\)/` so a
reintroduced `up( )` would be caught too. Core additionally refutes an unpinned
`up(from: n)` with no `version:` after it.

## A discrepancy between the map and the code, for 11b

`schema-migration-map.md` section 3 lists the versions whose `down` destroys a
commercial fact as **core 1, 3, 4, 7, 8, 9, 10**.
`AuroraMeter.Migration.data_loss_versions/0` returns **[7, 9, 10]**, and the
comment beside it says "11b adds the pre-existing versions 1, 3 and 4".

**Version 8 is in the map's list and in neither the code nor that comment.** The
map's reason is stated: dropping the unique index on `(tenant_key, event_id)`
removes the identity guarantee itself. The visible consequence is in the V8 file
above: its `down` carries no `confirm_data_loss: true` while its neighbours do.

Not changed here. Adding a version to that list changes what
`AuroraMeter.Migration.down/1` does at run time, which belongs to the unit that
owns the guard (11b), and a generator that emitted the flag for a version the
runtime does not guard would be the same false guarantee this file refuses to
emit for Pro. Recorded so 11b adds four versions rather than three.

## The committed migrations directories

Both generators write into the repository's own `priv/test_repo/migrations`,
which is committed. The capture snapshots the directory listing by sha256,
moves out exactly what appears, and compares:

| Package | Listing sha256 before | After |
|---|---|---|
| core | `d814f5a3fb661c8c899f923c4303cb461913a7d6f645c91fa3d273b0078df7fc` | identical, twice |
| Pro | `cdf69bcfa609dbfa2a8e0798369dcbe835cba4e51a3bd1d0e10225fd98ef1d0c` | identical, twice |

Restored by moving the files this run created, from the loop that created them,
and **never** with `git checkout --`: that reverts tracked files to `HEAD`, which
in a wave where another unit is working uncommitted in the same tree takes their
work with it, and it fails silently on untracked paths (X326). The generated
files are untracked, so `git checkout --` would have done nothing at all and said
nothing about it.
