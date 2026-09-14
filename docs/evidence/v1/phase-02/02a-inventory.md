# 02a: the core API inventory, and the counts behind it

Package: `aurora_meter` at `1434084` (0.4.0, schema 6), the tree 02c and 02b left.
Everything below was read from source on 2026-09-14 by reflection over the
compiled beam files, not copied from an earlier document.

Artefacts this unit produced in this package:

| File | What it is |
|---|---|
| `docs/api.md` | The inventory: 12 sections, every entry with a stability class and a `Since`. |
| `docs/support-policy.md` | The eight numbered points, plus the test-helper heading. |
| `test/aurora_meter/api_inventory_test.exs` | A01 to A05, 16 tests, `async: true`, no database. |
| `mix.exs` | `groups_for_modules`, a `Reference` extras group, `skip_code_autolink_to`. |
| `README.md` | A "Reference" block linking both new pages. |
| `docs/telemetry.md` | The `declared` metadata key, and where the Pro events live. |

## 1. Module population (measured, and the finding it corrects)

| Fact | Core | How it was measured |
|---|---|---|
| `.ex` files under `lib/` | 45 | `find lib -name '*.ex' \| wc -l` |
| Modules compiled from `lib/` | 56 | `:application.get_key(:aurora_meter, :modules)` filtered to those whose `module_info(:compile)[:source]` starts with the project's `lib/` |
| Modules carrying `@moduledoc false` | 14 | `grep -rc '@moduledoc false' lib`, summed |
| Behaviours (modules declaring `@callback`) | 5 | `Storage` 12, `Clock` 4, `Billing.Provider` 4, `Period` 2, `Tenant` 1 |
| `@optional_callbacks` | 1 (`Period.containing/2`) | `grep -rn '@optional_callbacks' lib` |
| `:telemetry.execute` sites | 8 | `grep -rc ':telemetry.execute' lib`, summed |
| PubSub call sites | 7, carrying 6 distinct message shapes | `grep -rn 'PubSub.broadcast(\|PubSub.local_broadcast('` |
| Mix tasks | 4 | `ls lib/mix/tasks` |
| Migration entry points | `Migration.latest_version/0` (`@latest 6`), `up/1`, `down/1` | read |

**`investigation/08-api-inventory.md`'s "72 modules, 11 `@moduledoc false`" does
not reproduce, and neither does 02a's own build document.** The build document
recorded 40 `.ex` files, 47 modules, 12 `@moduledoc false` and 4 behaviours,
which were the numbers before 02c and 02b landed. The table above is what the
tree holds now. All three sets of numbers are recorded rather than quietly
replaced, because a reader meeting the old ones somewhere else needs to know
which is current and why they differ:

| Source | `.ex` files | Modules | `@moduledoc false` | Behaviours |
|---|---|---|---|---|
| `investigation/08-api-inventory.md` | not stated | 72 (both packages) | 11 (both packages) | not stated |
| 02a's build document, written 2026-09-14 before wave 2 merged | 40 | 47 | 12 | 4 |
| Measured here, after 02c and 02b | 45 | 56 | 14 | 5 |

The difference between the build document and this table is exactly what 02c and
02b added: `clock.ex` (three modules), `errors.ex` (two), `config/schema.ex`,
`boot_checks.ex`, `mix/tasks/aurora_meter.features.ex`, plus
`Period.InvalidPeriodError` in `period.ex`. The extra two `@moduledoc false`
entries are `Config.Schema` and `BootChecks`. The fifth behaviour is `Clock`.

The 56 figure counts every module compiled from `lib/`, including the eleven
that carry `@moduledoc false` and the four Mix tasks. The build document's 47
counted `defmodule` declarations in the source text, which is a different thing:
it misses nothing, but the two numbers are not comparable and the beam-derived
one is the one the test uses.

`AuroraMeter.Clock`'s callback list was read with `behaviour_info(:callbacks)`,
never copied: `[db_now: 0, monotonic_ms: 0, now: 0, today: 0]`, four of them, all
required. That list has gone stale twice already (`open-findings.md` X75), which
is why nothing in this unit writes it out by hand.

## 2. Telemetry sites (verified, by symbol)

Eight, all in `lib/`, all documented in `docs/api.md` section 6 with the exact
emitted text in a `Matched in lib/` column:

`[:aurora_meter, :track]`, `[:aurora_meter, :reserve]`, `[:aurora_meter, :flush]`,
`[:aurora_meter, :flush, :error]`, `[:aurora_meter, :broadcast]`,
`[:aurora_meter, :cluster, :apply]`, `[:aurora_meter, :credits, txn.kind]`,
`[:aurora_meter, :credits, :low_balance]`.

The seventh is documented as `[:aurora_meter, :credits, kind]` for a human and
matched as `[:aurora_meter, :credits, txn.kind]` against the source, because
that is what the code says. The file:line pairs the build document recorded are
deliberately **not** repeated here: `open-findings.md` X67 settled that an audit
excludes and cites by content, never by position, and the A05 check greps the
emitted text.

A05 matches against `lib/` with heredocs and whole-line comments stripped, and a
telemetry literal must be an **emit site**, not merely text. That is not
belt-and-braces: the first version matched raw sources, and the negative control
that renamed the event passed, because the old name survived in a moduledoc two
lines above the emit. The control is recorded in section 5 as N7.

## 3. PubSub shapes (verified)

Six distinct messages over seven call sites:

| Message | Topic | Sites |
|---|---|---|
| `{:aurora_meter, :usage, %{feature, value, period_start}}` | `Broadcaster.topic/1` | 2 (`local_broadcast` when `cluster_sync` is on, `broadcast` otherwise) |
| `{:aurora_meter, :deltas, node(), [{key, delta}]}` | `"aurora_meter:cluster"` | 1 |
| `{:aurora_meter, :totals, node(), [{key, total}]}` | `"aurora_meter:cluster"` | 1 |
| `{:aurora_meter, :subscription_changed, key}` | `"aurora_meter:subscriptions"` | 1 |
| `{:aurora_meter, :credits, %{tenant_key, balance, held, available}}` | `Credits.topic/1` | 1 |
| `{:aurora_meter, :low_balance, %{tenant_key, available, threshold}}` | `Credits.topic/1` | 1 |

Three of the six are classed `internal` in `docs/api.md`: the two cluster
messages and the subscription invalidation are how nodes talk to each other, not
an API a host subscribes to.

## 4. The internal set, and why each is on it

19 modules. The list lives in three places and the test asserts all three are the
same list: `@internal_modules` in `test/aurora_meter/api_inventory_test.exs`,
the "Internal modules" section of `docs/api.md`, and
`groups_for_modules[:Internal]` in `mix.exs`.

| Module | `@moduledoc false` already? | Why |
|---|---|---|
| `AuroraMeter.BootChecks` | yes | The boot child that runs `Credits.assert_currency!/0`. |
| `AuroraMeter.Broadcaster` | no, banner added | The PubSub fan-out process. `topic/1` is the one supported entry. |
| `AuroraMeter.Cluster` | no, banner added | The gossip protocol between nodes. |
| `AuroraMeter.Config.Schema` | yes | Configuration conventions shared with Pro by copying the pattern, not the module. |
| `AuroraMeter.Counter` | no, banner added | The ETS row layout and the reserve or commit protocol. |
| `AuroraMeter.Credits.Ledger` | yes | The ledger behind `AuroraMeter.Credits`. |
| `AuroraMeter.Credits.Promotions` | yes | Promotional-remainder arithmetic. |
| `AuroraMeter.Credits.Series` | yes | The money series queries. |
| `AuroraMeter.Install.Templates` | yes | The strings the installer writes. |
| `AuroraMeter.Migration.V1` to `V6` | yes | One schema version each. |
| `AuroraMeter.Schema.FlushReceipt` | yes | Flusher bookkeeping. |
| `AuroraMeter.Storage.Ecto` | no, banner added | The bundled adapter. |
| `AuroraMeter.Store` | no, banner added | Owns the ETS tables. |
| `AuroraMeter.Supervisor` | yes | The runtime tree. Add `AuroraMeter` to your own. |

The five that had real module docs keep them and carry a banner instead of
losing their page, for the reason 02a's build document records: four guides and
two ADRs link to `AuroraMeter.Counter` and `AuroraMeter.Cluster`, and `mix docs`
runs inside `mix check`.

`AuroraMeter.Subscriptions` and `AuroraMeter.Flusher` are **not** on the list.
`api-change-map.md` 1.8 says "`Subscriptions` internals", and the two functions a
host calls (`get/1`, `invalidate/1`) are the whole public surface of that module
today, so marking the module internal would withdraw a promise from the only
thing in it. `Flusher.flush/0` is likewise the module's only public entry.

The fourteen modules that carry `@moduledoc false` render no page, so ExDoc warns
on every reference to them. `mix.exs` lists them under `skip_code_autolink_to`,
which says "do not try to link to this" and is exactly true. That also silences
two references that were warning before this unit touched anything
(`docs/testing.md:267` and `test/support/aurora_meter/test/kill.ex:98`, both
naming `AuroraMeter.Supervisor`). Recorded as a cross-unit touch.

## 5. The inventory test, and the negative controls that prove it bites

16 tests, `async: true`, no database, no processes started. Every mutation below
was applied to a byte copy of the tree, run, and reverted; the tree was
confirmed green afterwards each time. Logs under `tmp/v1/02a/negatives/`.

| Control | Mutation | Result |
|---|---|---|
| N1 | A row for `AuroraMeter.no_such_function/2` | fails A01, naming `docs/api.md:40` |
| N2 | A row for `AuroraMeter.Counter.incr/4` (internal module) | fails A02, naming the row |
| N3 | A row for `AuroraMeter.child_spec/1` (`@doc false`) | fails A02, naming the row |
| N4 | Delete `Schema.CreditTransaction.categories/0` | fails A01, naming `docs/api.md:245` |
| N5 | `@moduledoc false` on `AuroraMeter.Period` | fails A03, naming the module |
| N6 | Delete the `@spec` on `Period.current!/2` | fails A04, naming module, function and arity |
| N7 | Rename `[:aurora_meter, :track]` at its **emit site** | fails A05, naming the event |
| N8 | Drop `AuroraMeter.Store` from `mix.exs`'s Internal group | fails, naming the disagreement |
| N9 | Document a PubSub tag nothing emits | fails A05, naming the tag |

The  positions above are what those runs printed. The file was
edited afterwards (the type references and the callback references were
rewritten to stop  warning), so re-running a control today prints a
different number. The row the message names is the part that matters, and it is
why the message names the row and not only the line.

The `docs/api.md:NNN` positions above are what those runs printed. The file
was edited afterwards (the type and callback references were rewritten so
`mix docs` stops warning), so re-running a control today prints a different
number. The row the message names is the part that matters, and it is why the
message names the row and not only the line.

N4 and N7 were each wrong on their first attempt, and both failures are worth
recording because they are the same mistake in two guises.

- N4 first deleted `AuroraMeter.version/0`, which broke compilation under
  `warnings_as_errors` before the test could run: exit 1, but from the compiler,
  not from the guard. A negative control must fail the thing it is testing.
  `Schema.CreditTransaction.categories/0` is called from nowhere in `lib/`, so
  deleting it compiles and only the inventory notices.
- N7 first replaced the **first** occurrence of the event name in
  `aurora_meter.ex`, which is a mention in a `@doc`, not the emit. The test
  passed, which was correct at the time and useless. That exposed a real gap in
  A05, which is now fixed: it strips heredocs and comments, and a telemetry
  literal must match an emit site.

## 6. Headless leg

`AURORA_HEADLESS=1` removes `phoenix_live_view`, `phoenix_html` and `igniter`
from `deps/0`, which is the switch the `headless` CI leg uses. Built into its own
`MIX_BUILD_PATH` and `MIX_DEPS_PATH` so the ordinary build is untouched.
`mix.lock` is not redirected by those variables (`open-findings.md` X57), so it
is hashed before and after: `70e0f2b8...` both times, unchanged.

Observed: `Phoenix.Component loaded?: false`, `AuroraMeter.Components loaded?:
false`, and the inventory test passes 16 of 16. The four `optional-dep` rows in
`docs/api.md` section 1.12 are skipped, and the test asserts that at least one
skip happened **because** this is a headless build. On an ordinary build it
asserts the opposite: nothing was skipped. Neither leg can pass by accident.

Log: `tmp/v1/02a/core-headless-final.log`.

## 7. What this inventory does not claim

- It does not claim the 0.x return shapes are uniform. Section 4 of
  `docs/api.md` states the two families as they are and names the one that
  changes in 1.0 (`Credits.grant/3` moving from a changeset to an atom reason,
  06c).
- It does not classify anything by line number. Every check matches text or a
  symbol.
- It records `:durable_features` as `deprecated`, which is the class it carries
  from the transition release onwards. The runtime warning is 02d's and 03c's,
  and this page does not pretend it already exists.
