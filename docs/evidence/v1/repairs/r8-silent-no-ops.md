# R8: a documented upgrade that did nothing and said it worked, and the probe that answers false about code that exists

Repair unit R8, 2026-09-17 (UTC). Findings X427 and X426, plus X444 to X447
raised here. Branch `aurorameter-v1`, nothing committed and no checkbox ticked
(rule 4).

Core `aurora_meter` at 0.5.0, Pro `aurora_meter_pro` at 0.3.0. Elixir 1.20.1 /
OTP 29 (erts 17.0.1), Postgres 16.13 in the package container on port 5490.
Build unit 11a's work was uncommitted in the tree throughout and was re-read
before every edit; nothing of it was reverted.

Two items, one kind: **shipped code that does the wrong thing and reports
success.**

---

## 0. The headline

**An operator following `docs/upgrading-to-lots.md` exactly as written, with no
extra flags, now migrates wallets.** Against the populated `core6_pro9` fixture,
run `migrations-20260917T061505Z-02a371`:

```
STEP 1  mix aurora_meter.credits.migrate_lots          STEP 4  ... --no-shadow
  wallets        16                                      wallets        16
  migrated        0   (shadow writes nothing)            migrated       14
  blocked         2                                      blocked         2
  resumed from    -                                      resumed from    -
  unexamined      0                                      unexamined      0
```

Before this unit, step 4 printed `wallets 0, migrated 0, blocked 0` and exited
**0**, with not one wallet cut over.

The matrix numbers did not move: `core6_pro9` still upgrades core 6 to 10 and
Pro 9 to 11 over 16 tenants with **R1 to R10 all `pass`**, 14 of 16 wallets cut
over, 26 lots, 35 allocations, the same two `expire_reserved_grant` wallets
declined. What changed is that the harness no longer passes `--no-resume`, so
the step is now the operator's own sequence rather than a workaround for it.

**The `function_exported?/3` sweep found no new live defect.** Nine call sites
ship across the two packages; eight are already written
`Code.ensure_loaded?(M) and function_exported?(M, f, a)`, and the ninth is
provably safe for a reason that is now written down and measured. The product of
the sweep is therefore the **guard**, not a list of fixes, and the guard is the
part that was missing: both sites the parent unit flagged as "look live" are
correct, and the reason nobody knew that is that nothing checked.

One thing the sweep turned up that nobody asked for: remove the
`Code.ensure_loaded?/1` from `AuroraMeter.Config.Schema.ensure_exports!/4` and
**the library does not boot**, for any host, with a message about a module that
plainly does export the function. Section 2.3.

---

## 1. X427: the cursor

### 1.1 The decision, stated before it was implemented

**Shadow and real keep separate cursors.** Rejected: a shadow run that writes no
cursor at all; `--no-shadow` refusing a cursor a shadow run wrote; resume off by
default.

`architecture-map.md` 7.4 is binding and says shadow mode "computes and reports
without writing". The per-wallet checkpoint rows are the report (the guide sends
the operator to `status/1` to read them and the blocked list is the whole of
step 2), so those stay. **The aggregate cursor is not a report. It is control
state the next run obeys**, and a rehearsal that changes what the real run does
is the writing 7.4 forbids. Separating the rows is the narrowest reading of that
sentence that keeps the report.

`schema-migration-map.md` section 4 says nothing about cursors; section 5
requires "S2 and S5 interrupted once (`kill -9` of the task at a checkpoint) and
resumed", so **resume must keep working for real runs, by default**. That rules
out making resume opt-in, which was the cheapest fix.

Why not "shadow writes no cursor": the guide's own "A large installation"
section documents paging with `--max-wallets` and does not distinguish mode. A
shadow run that never records progress cannot be paged, so rehearsing a 100,000
wallet install would re-walk the first page for ever. Separate cursors keep
paging for both modes.

### 1.2 Why this does not make 11b's job impossible, which was the constraint

11b owns interrupted runs. Under separate cursors an interrupted real run's
resume point cannot be read, advanced, or erased by any shadow run, before or
after it. Under the rejected "`--no-shadow` refuses a shadow-written cursor" the
shadow run still writes the shared row, so an operator who re-rehearses after an
interrupted real run **destroys the real run's resume point** and nothing says
so. That option is the one that would have hurt 11b, and it is the one that
looks cheapest.

Two supporting changes, both about not destroying progress, both of which 11b
needs:

- **A run that examines no wallet never overwrites a cursor.** `summary.cursor`
  is `nil` when the run stepped no wallet, and writing that `nil` over the row
  erased the resume point. That is the second half of X427 and the half that
  made the symptom alternate with how many times the task had been invoked. It
  also means an interrupted real run's cursor could be wiped by any later run
  that happened to examine nothing.
- **`--retry-blocked` starts from the first wallet and leaves the cursor alone.**
  That is X444, below.

**No conflict with 11b was found**, so this unit did not stop. If 11b needs an
interrupted run to resume from something a rehearsal wrote, that is a conflict
and this decision is the one to revisit.

### 1.3 The defect the summary could not express

The requirement was that a run migrating nothing because it had nothing to do be
distinguishable from a run migrating nothing because it skipped everything. Both
printed `wallets 0` and exited 0.

The summary now carries `resumed_from` (the cursor the scan started after) and
`unexamined` (wallets still on the legacy writer that this run did not look at
and that no run of this mode has recorded a verdict for), and a third state,
`skipped_by_cursor`, which the Mix task fails on.

`unexamined` is **measured against the tables, not deduced from the cursor**.
Once the cursors are separated it should always be zero, because a mode's cursor
only ever advances over wallets that mode examined. That is exactly why it is
counted: a report that derives "nothing was skipped" from the same invariant
that skipped everything cannot notice when that invariant breaks again, and this
one broke in production. Put the single shared cursor back and the number is 16.

A shadow run's verdicts deliberately do not count as verdicts for a real run.
`shadow_ok` means the replay reconciled, not that the wallet was cut over.
Letting it count would tell a real run that sixteen legacy wallets had been dealt
with when not one had, which is the sentence X427 is about.

### 1.4 The operator's seat

`scripts/v1/fixtures/matrix.sh` no longer passes `--no-resume`. It was passing it
because of X427, and a harness that keeps a workaround for a repaired defect
cannot notice the defect coming back. Full output in section 0; the comparator
verdicts are in
`storefront:tmp/v1/migrations-20260917T061505Z-02a371/core6_pro9-diff.json`,
`result: pass`, `exit_code: 0`.

---

## 2. X426's family: every `function_exported?/3` in shipped `lib/`

### 2.1 The disposition, site by site

Produced by AST, not by grep, so a comment naming the function is not counted as
a call. **Nine sites.**

| # | Site | Module comes from | Verdict |
|---|---|---|---|
| 1 | `core:lib/aurora_meter/config/schema.ex:177` | variable `module` | **bare, and safe.** The statement above it is `if not Code.ensure_loaded?(module), do: raise`, so the module is loaded by this line or the function has already stopped. Exempted by name with the reason, and **proved cold** in `config_schema_cold_test.exs` |
| 2 | `core:lib/aurora_meter/credits/lot_migration.ex:982` | literal `AuroraMeter.Credits` | guarded. 11a's fix for X426 itself |
| 3 | `core:lib/aurora_meter/exporter_case.ex:730` | variable `module` | guarded |
| 4 | `core:lib/aurora_meter/oban.ex:289` | variable `module` | guarded |
| 5 | `core:lib/aurora_meter/oban.ex:471` | literal `Mix` | guarded |
| 6 | `core:lib/aurora_meter/period.ex:178` | variable `source` | guarded |
| 7 | `core:lib/aurora_meter/plans.ex:688` | variable `module` | guarded |
| 8 | `core:lib/aurora_meter/subscriptions/preview.ex:203` | variable `module` | guarded |
| 9 | `pro:lib/aurora_meter/pro/dashboard.ex:146` | literal `AuroraMeter.Credits` | guarded. The `Code.ensure_loaded?` is on line **145**, which is why a grep of line 146 reads as bare |

Both sites the parent unit flagged as "look live" are in fact correct, and site 9
is a good illustration of why this had to be done by AST: `grep -n` reports the
line the call is on, and the guard is on the line above.

No `macro_exported?/3` anywhere in either package's `lib/`. No
`:erlang.function_exported/3`. `AuroraMeter.Pro.check_account!/1` has a local
variable called `exports?` that is about exported usage, not module exports, and
is not in this family.

### 2.2 The reach of the guard, which is where 09a's shape fell short

09a's detector recognised **only a literal module alias**. Six of core's eight
shipped sites pass the module in a **variable**, so the inherited detector saw
two of nine and would have called that a sweep. Every site that takes its module
from configuration takes it in a variable, and a host-configured module is the
**least likely one in the system to be loaded already**, so the shape 09a could
not see is the shape where the trap bites hardest.

The detector now reads variables and reports them as `{:var, :name}`.
`Code.ensure_loaded!/1` and `Code.ensure_compiled!/1` count as loaders, since
either raises rather than answering false. A `Code.ensure_loaded?/1` in a
**preceding statement** is deliberately **not** accepted: it cannot be proved
from one expression, so site 1 is reported and carries an exemption with a
stated reason, rather than being waved through by a rule that would also wave
through a reordering that broke it.

The file list is a **wildcard** over `lib/**/*.ex` in each package, not a list.
A list is a list of what someone remembered, which is how X426 survived: 09a
listed eight pre-existing sites "for their owners" and no owner was ever created.
A test asserts the wildcard reaches more than fifty files, so the guard cannot
pass by matching nothing.

Scope stays at shipped `lib/`. Test files keep 09a's narrow list, because
`credits/lot_cutover_gate_test.exs` contains three bare calls where asserting
that the bare form answers false **is the test**. The remaining unowned test
sites are X446.

### 2.3 What was found that nobody asked for

Control `c9` removed the `Code.ensure_loaded?/1` from
`Config.Schema.ensure_exports!/4`, expecting the cold test to fail. The
application did not start:

```
** (EXIT from #PID<0.95.0>) shutdown: failed to start child: AuroraMeter
    ** (ArgumentError) config :aurora_meter, tenant: AuroraMeter.Tenant.Default
       does not export to_key/1. It must be a module implementing AuroraMeter.Tenant.
        (aurora_meter 0.5.0) lib/aurora_meter/config/schema.ex:186
        (aurora_meter 0.5.0) lib/aurora_meter/config.ex:734: AuroraMeter.Config.check_modules!/1
        (aurora_meter 0.5.0) lib/aurora_meter.ex:667: AuroraMeter.start_link/1
```

`AuroraMeter.Tenant.Default` exports `to_key/1`. It is simply not loaded when
configuration is validated at boot, which is the earliest moment in the process
where nothing has referenced anything. So site 1 is not merely "safe by
argument": that one call is load-bearing to the point that the library cannot
start without it, in **every** host, and the failure would be immediate and
total rather than silent. X426 is the same defect at a place where it was
silent instead. Recorded as X445.

---

## 3. Controls: watched failing before they were trusted passing

Every control patches a tracked file under a held lane (X371:
`mixlane.sh hold core bash ...`), snapshots by sha256 and restores on an EXIT
trap (X326). No `git checkout --` anywhere. Harnesses:
`storefront:tmp/v1/r8-controls.sh`, `r8-controls-core2.sh`, `r8-controls-pro.sh`.

### 3.1 Item 1

| Control | What was broken | Required | Observed |
|---|---|---|---|
| `c1` | one shared cursor again | fail | fail: the two documented-sequence tests |
| `c2` | a zero-wallet run writes its null cursor again | fail | fail: the cursor-erasure test |
| `c3` | `--retry-blocked` resumes from the cursor again | fail | fail: both X444 tests |
| `c4` | `unexamined` blind (always 0) | fail | fail: "says so when it skipped everything" |
| `c5` | `unexamined` always non-zero | fail | fail: "says so when there was nothing to do" |
| `c6` | a retry sweep stamps its own last wallet | fail | fail: the backwards-cursor test |
| `c0` | nothing | pass | pass, 8 of 8 |

`c4` and `c5` are the two directions of the same measurement, and both are
needed: `c4` alone is satisfied by a guard that fires on everything.

### 3.2 Item 2

| Control | What was broken | Required | Observed |
|---|---|---|---|
| `c8` | X426 put back in the shipped cutover gate | fail | fail: the static guard **and** 11a's behavioural test, independently |
| `c9` | the exemption's reason removed | fail | **the library would not boot** (section 2.3) |
| `c10` | the exemption deleted, the code left correct | fail | fail: the lib guard, which proves it sees site 1 rather than missing it |
| `p1` | the bare form put back in Pro's dashboard | fail | fail: two of Pro's four guard tests |
| `c0`/`p0` | nothing | pass | pass, 12 of 12 and 4 of 4 |

`c10` is the one that stops the exemption being decorative. If the guard could
not see site 1 in the first place, removing its exemption would change nothing.

### 3.3 Three instruments of mine that were wrong first

Recorded because this programme's own count of instruments that returned a wrong
answer before a right one is the reason every control here exists.

1. **Two X444 tests passed with the fix reverted.** They ran `shadow: true`
   while seeding the **real** cursor, so they exercised nothing. `c3` caught it.
   Fixed by running them the way the defect occurs, as real runs.
2. **`c4` and `c5` did not compile.** Removing the call sites orphaned two
   private functions and the patch failed on `warnings_as_errors`, so both
   controls "failed" without ever running a test. The harness now greps for
   `Compilation failed` and says the control measured nothing, because an exit
   code cannot tell a refused patch from a caught defect.
3. **A cursor test sorted tenant keys in Elixir.** The scan is
   `order_by: [asc: b.tenant_key]`, which is the **database's** collation:
   `"lotcur_123" < "lotcur_45"` by bytes and the other way round under en_US.
   The test now reads its ordering from the table. Worth knowing for anyone
   writing a cursor assertion, which is 11b.

---

## 4. The baseline, and what moved

Established before anything was changed, with 11a's uncommitted work in the tree:

| | `mix test` before | `mix check` before | `mix test` after | `mix check` after |
|---|---|---|---|---|
| core | 2299 passed, 8 excluded | exit 0 | **2313** passed, 8 excluded | exit 0 |
| Pro | 1222 passed | exit 0 | **1226** passed | exit 0 |

Core gains 14 tests (8 in `lot_cursor_test.exs`, 3 in `config_schema_cold_test.exs`,
3 in `exported_idiom_test.exs`) and Pro 4. No test was deleted.

The parent unit's figures were 2288 and 1214; the difference is 11a's
uncommitted tests, which is why a baseline was taken rather than assumed.

Pro's dialyzer reports `Total errors: 1, Skipped: 1` and passes. That is
pre-existing, present in the before run, and **not attributable to this unit**.

Files changed, all re-read immediately before editing because 11a's work was
uncommitted:

```
core  lib/aurora_meter/credits/lot_migration.ex
core  lib/mix/tasks/aurora_meter.credits.migrate_lots.ex
core  lib/aurora_meter/config/schema.ex                       (a comment only)
core  docs/upgrading-to-lots.md
core  docs/correctness.md
core  test/aurora_meter/credits/lot_cursor_test.exs           (new)
core  test/aurora_meter/config_schema_cold_test.exs           (new)
core  test/support/aurora_meter/test/export_probes.ex         (new)
core  test/aurora_meter/exported_idiom_test.exs
core  test/aurora_meter/credits_lot_migration_test.exs        (one test, re-aimed)
pro   test/aurora_meter/pro/exported_idiom_test.exs           (new)
pro   docs/correctness.md
sf    scripts/v1/fixtures/matrix.sh, scripts/v1/fixtures/README.md
```

Nothing under the storefront's `lib/` or its templates was touched (10b owns
those). `mix format` was run on changed files only, never project wide.

One existing test changed meaning rather than being deleted:
`credits_lot_migration_test.exs` "I19 the scan resumes from the aggregate cursor"
seeded `"lot_migration"` and ran in shadow. It now seeds
`"lot_migration_shadow"`, which is the row a shadow run resumes from, and
asserts `resumed_from` as well. The case it used to cover, a shadow cursor
steering a real run, is now asserted not to happen, in `lot_cursor_test.exs`.

---

## 5. Notes for 11b

- The real cursor is `aurora_meter_checkpoints["lot_migration"]` and the
  rehearsal's is `["lot_migration_shadow"]`. Neither name can collide with a
  wallet's, because `checkpoint_name/1` always emits `"lot_migration:" <> key`
  and the wallet listing selects on that prefix.
- The aggregate cursor is written every `--batch` wallets (default **50**) and
  once at the end. A `kill -9` of a run over fewer than 50 wallets therefore
  leaves **no** cursor, and the resumed run restarts from the first wallet. That
  is correct but not free, and it is a property of `batch`, not of the fix.
- `summary.unexamined` is the number to assert on for "this run left work
  behind". It is `nil`, not 0, when the caller named tenants explicitly.
- **The package test database is not empty and is not rolled back.**
  `aurora_meter_test` holds 4 committed `aurora_meter_credit_balances` rows from
  headless legs, 1 of them still on the legacy writer. Any scan-mode test sees
  them. Every cursor these tests seed is read from the table for that reason
  (X447).
