# Core: the data-loss list, the generator's new flag, and the cutover gate

Build unit **11a**, 2026-09-17. The fixture matrix these changes were found by
is in the storefront at `docs/evidence/v1/phase-11/migration-matrix.md`.

## The data-loss list (finding X362)

`schema-migration-map.md` section 3 is binding and names the versions whose
`down` destroys a commercial fact as **core 1, 3, 4, 7, 8, 9, 10**.
`AuroraMeter.Migration.data_loss_versions/0` returned `[7, 9, 10]`, and the
comment beside it said "11b adds the pre-existing versions 1, 3 and 4", naming
three where the map names four. Version 8 was in neither.

The list is now the map's seven, each with the map's own reason, and the reason
reaches the refusal:

```
** (AuroraMeter.Migration.DataLossError) the down step of Aurora Meter schema
version 8 destroys commercial state that no later step can rebuild. Version 8
drops the unique index on (tenant_key, event_id), which removes the identity
guarantee itself: after it, two rows may claim to be the same fact and nothing
in the database refuses them. A down step is not a rollback; the supported
recovery from a bad upgrade is the backup taken before it. Pass
`confirm_data_loss: true` if destroying it is what you mean to do.
```

Before this the message described version 7 whatever version was asked for,
which is part of how a wrong list stays invisible: the text read plausibly for
every version on it.

**Two tests in the suite had the old belief written into them as if it were a
decision**, and both failed when the list was corrected, which is how the change
was known to reach real behaviour rather than a constant:

- `test/aurora_meter/migration_test.exs`, "down/1 of a version that destroys
  nothing needs no confirmation", used version 8 with the reasoning "version 8's
  down drops an index and promotes nothing; it loses no fact". It now asserts
  the refusal, and the negative case moved to version 5, which really does only
  add a partial index.
- `test/mix/tasks/gen_migration_test.exs` asserted the generated concurrent file
  carried **no** `confirm_data_loss`. It asserts the opposite.
- `test/aurora_meter/migration_v8_test.exs` ran V8's `down` against a real
  database without the flag; it passes it now.

### The list against the map

`test/aurora_meter/migration_map_test.exs` compares three things in a chain:

    binding map  ->  a verbatim quotation  ->  data_loss_versions/0

The quotation is a literal so the test runs in a standalone clone of this
package, where the map is not on disk; a second test asserts the quotation is
still what the map says. That second test **does not go quiet when the map is
missing**: it goes quiet only when the storefront is missing too, which is the
one situation where the map's absence is legitimate. Moving the map inside the
monorepo fails it.

Controls, all watched failing before the tests were trusted passing
(`storefront:docs/evidence/v1/phase-11/controls/core.log`):

| Control | Broken | Required | Observed |
|---|---|---|---|
| C0 | nothing | pass | pass |
| C1 | version 8 removed from `@data_loss_reasons` | fail | fail |
| C2 | the map's sentence edited | fail | fail |
| C3 | the map moved away with the storefront present | fail | fail |
| C4 | nothing, after restoring | pass | pass |

## `--no-validate-checks` (finding X428)

`AuroraMeter.track/4` never rejected a non-positive quantity and never bounded
metadata, so a database written by 0.4.x can hold rows core schema version 8's
two late checks refuse. `mix aurora_meter.events.backfill` counts them and
prints the remedy: run version 8 with `validate_checks: false`.

Until this unit the generated file had no way to carry that option, so the only
route from the backfill's advice to a working upgrade was to hand-edit a
generated migration. Measured against a populated `core6_pro9` fixture holding
two non-positive quantities and one 16 KiB metadata row: the backfill gives all
53 rows identity and names both classes, and version 8 then fails with

    ERROR 23514 (check_violation) check constraint
    "aurora_meter_events_quantity_check" ... is violated by some row

leaving the database at core 7, mid-upgrade. With the flag, the same fixture
reaches core 10 / Pro 11 with every reconciliation check passing.

The emitted file:

```elixir
defmodule Fixture.Repo.Migrations.UpgradeAuroraMeterV8Concurrent do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true
  def up, do: AuroraMeter.Migration.up(from: 8, version: 8, validate_checks: false)
  def down, do: AuroraMeter.Migration.down(version: 8, to: 8, confirm_data_loss: true)
end
```

The option lands on the file covering version 8 and on no other file, because an
option a version never reaches is a word in a host's committed migration that
nothing reads. One of the three tests parses the emitted body and asserts the
keyword list is one `AuroraMeter.Migration.up/1` actually accepts, rather than a
string that looks right.

**What the flag actually switches off is six constraints, not the two the
backfill's message names** (`open-findings.md` X433).

## The cutover gate (finding X426)

`AuroraMeter.Credits.LotMigration.cutover_blocked/0` decides whether a wallet
may be moved onto credit lots. It is a behavioural probe: it asks whether
`AuroraMeter.Credits.reverse_lot/4` exists, so it would open itself when 06e
shipped that path and nothing else could open it.

It asked with a bare `function_exported?/3`, which answers **false for a module
that is merely not loaded**. Measured in a fixture host:

```
cold: %{loaded_before: false, function_exported_before: false, cutover_blocked_before: true}
warm: %{loaded_after: true,  function_exported_after: true,  cutover_blocked_after: false}
```

So in any host, `mix aurora_meter.credits.migrate_lots --no-shadow` refused
every cutover, printing finding X250, which repair unit R1 had closed. No
install could move a single wallet onto lots.

**Why the suite could not see it.** All three lot-cutover test files set
`Application.put_env(:aurora_meter_test, :allow_lot_cutover, true)`, and the
probe is `hatch or function_exported?(...)`. `or` short-circuits, so the branch
that decides this in production had never been evaluated by any test. That is
X360's lesson from the other side: an escape hatch every test takes is a branch
no test can reach.

`test/aurora_meter/credits/lot_cutover_gate_test.exs` clears the hatch and
unloads the module, which is the only way to ask the question a host asks. The
control put the bare probe back and watched it fail
(`storefront:docs/evidence/v1/phase-11/controls/cutover.log`).

## `Install.Plan` lost its `data_loss` flag

Pro gained a data-loss list and a guard in the same unit (see Pro's evidence
file), so both package specs became `data_loss: true` and the false branches of
`fresh_down/2` and `down/3` became unreachable. Dialyzer said so and they are
gone rather than left as a shape a reader might take for an option that still
exists. Whether a file carries the flag is decided per range by asking the
package's own `data_loss_versions/0`, which is the only question that was ever
being asked.

## Gate

`mix check`: **2299 passed**, 158 doctests, 22 properties, 8 excluded, exit 0.
The baseline this unit started from was 2288.
