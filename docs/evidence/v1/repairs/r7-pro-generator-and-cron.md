# R7: a generator that could not run in any host, and two things we ship that could not boot together

Repair unit R7, 2026-09-17 (UTC). Findings X394, X395, X396 and X397.
Branch `aurorameter-v1`, nothing committed and no checkbox ticked (rule 4).

Core `aurora_meter` at 0.5.0, Pro `aurora_meter_pro` at 0.3.0. Elixir 1.20.1 /
OTP 29, Postgres 16.13 in the package container on port 5490.

> Pro's side of this unit is also written up in
> `pro:docs/evidence/v1/repairs/r7-usage-reporter-and-generator.md`. This page
> is the whole of it; that one is Pro's own copy of the two findings that are Pro's.

---

## 0. The headline

**Pro's migration generator works in a real host.** Built with both packages as
path dependencies, `mix aurora_meter_pro.gen.migration -r R7Host.Repo` run as
its own Mix invocation against an uncompiled host, then applied:

```
LEG A (repaired)                       LEG B (the call removed again)
  core gen        rc=0                   core gen        rc=0
  PRO GEN         rc=0                   PRO GEN         rc=1
  migration files 0 -> 2                 migration files 0 -> 1
  ecto.migrate    rc=0                   ecto.migrate    rc=0  (core's file only)
```

and leg B says, in a real host, the thing X394 says it says:

```
** (UndefinedFunctionError) function R7Host.Repo.config/0 is undefined
   (module R7Host.Repo is not available)
```

`tmp/v1/r7-host-proof.sh`, logs under `tmp/v1/r7/host/`.

**X395's answer is the reporter, not the crontab, and it was not mine to
choose.** Both binding maps had already decided it and the code was the only
thing that disagreed. Section 2.

---

## 1. X394: the generator, and the test that was missing

### 1.1 The one line, and why it is not the point

```
core/lib/mix/tasks/aurora_meter.gen.migration.ex:61   Mix.Ecto.ensure_repo(repo, args)
pro/lib/mix/tasks/aurora_meter_pro.gen.migration.ex   (absent)
```

`Mix.Ecto.parse_repo/1` turns `-r MyApp.Repo` into an atom and stops there.
`Mix.Ecto.ensure_repo/2` is what runs `Mix.Task.run("app.config", args)`, which
is what puts the host application's modules on the code path. Without it,
`gen_for_repo/2`'s first act, `Ecto.Migrator.migrations_path/1`, calls
`repo.config/0` on a module that is not there.

The fix is that call. The finding is the test.

### 1.2 Why neither suite could see it

Both packages' generator tests do the same two things, and each of them hides
this defect on its own:

| | core `gen_migration_test.exs` | Pro `gen_migration_test.exs` |
|---|---|---|
| the repo it passes | `AuroraMeter.TestRepo` | `AuroraMeter.Pro.TestRepo` |
| when that module is loaded | before any test runs | before any test runs |
| what every assertion is about | the text of the file written | the text of the file written |

A generator test that never runs the generator in the state a host is in is
testing a file writer. That is X374's sentence, one phase old, in the second
package.

### 1.3 The standing test

`Mix.Tasks.AuroraMeterPro.Gen.MigrationTest` now has
`describe "the migration the generator produces"`, modelled on the
`describe "the application the installer produces"` block R5 added to core's
`install_test.exs`. Four tests:

1. **an unresolvable repo is a named refusal, not an `UndefinedFunctionError`.**
   The repo is `Module.concat(["AuroraMeterR7", "UnloadedHost", "Repo"])`, built
   from strings rather than written as an alias, because a literal would be a
   compile-time module reference and `mix check` compiles this suite with
   `--warnings-as-errors`, so the test would fail the BUILD rather than run
   (X373). The test **makes the call that raised** first, directly
   (`Ecto.Migrator.migrations_path(repo)` must still raise
   `UndefinedFunctionError`), because if that ever stops being true the module
   has become loadable and everything after it measures nothing. Then it asserts
   the task answers with a `Mix.Error` naming the repo.
2. **core's generator answers the same repo identically.** Two implementations
   of one idea, one of which was wrong for two phases; this is the assertion
   that makes them one idea again.
3. **the generated file defines exactly the module its name promises**, by
   `Code.compile_string/1` rather than by matching a string. The expected name
   is read from `AuroraMeter.Install.Plan.files/1`, the same plan the generator
   reads, so adding a schema version cannot make the test wrong about a name it
   does not own.
4. **the compiled module is one `Ecto.Migrator` will run**: `__migration__/0`,
   `up/0` and `down/0` are exported.

### 1.4 What this test would and would not have caught

**Would.** Any way of reaching `gen_for_repo/2` without resolving the repo,
which is this defect and the whole family it belongs to: the call deleted, the
call moved below the first use, a refactor that takes the repo from somewhere
other than `ensure_repo/2`'s return. Any disagreement between the module the
generated file's **name** promises and the module it **defines**, which is
X374's shape applied to a generator rather than to an installer. Any generated
file that is not a migration `Ecto.Migrator` would accept.

**Would not.** It does not run `mix` in a host, so it cannot catch anything that
depends on a second Mix invocation: a `deps` resolution problem, a task that is
not registered in the archive, the ordering between the two packages'
generators, or a migration whose SQL is wrong at run time. It does not touch a
database, so it does not know whether the migration it compiled would apply.
Those are the real host's job and they are section 1.5, in a script rather than
in `mix check`, for exactly R5's reason: they need a second build and a second
database.

It also would not have caught this defect **if it had been written the obvious
way**, and that is measured rather than reasoned, because reasoning about a
runtime is the same mistake one level down. `tmp/v1/r7-unloaded-probe.exs`,
under the pro lane:

```
loaded before:        false
delete/1 returned:    false
loaded after purge:   false
beam still on path:   true
migrations_path/1:    {:ok, ".../priv/test_repo/migrations"}

absent module on path: false
migrations_path/1:     {:raised, UndefinedFunctionError}
```

A repo that is merely **unloaded** answers `repo.config/0` perfectly well: the
Erlang code server loads it on first call because its beam is on the path, so
the repaired and the broken generator behave identically against it and a test
built on that state measures nothing. The state that discriminates is a module
with **no beam anywhere**, which is the state a host's repo is in until
`app.config` runs. That is the version of this test I wrote first, and the probe
is why it is not the version that shipped.

### 1.5 The real host, twice

`tmp/v1/r7-host-proof.sh` builds a host project (its own `mix.exs`, an
`Ecto.Repo`, a supervision tree, a config naming the database) with both
packages as path dependencies, and **does not compile it** before running the
generators, because that is the state a host following
`pro:docs/getting-started.md` is in. It then applies what they produced with
`mix ecto.migrate` and asks the database for the Pro tables by name. Both legs
run against a database dropped and created fresh.

| | Leg A, repaired | Leg B, `ensure_repo` removed |
|---|---|---|
| `mix aurora_meter.gen.migration` | rc=0 | rc=0 |
| `mix aurora_meter_pro.gen.migration` | **rc=0** | **rc=1** |
| migration files written | 0 -> **2** | 0 -> **1** (core's only) |
| `mix ecto.migrate` | rc=0 | rc=0 |
| `aurora_meter_usage_reports` | present=**1** | present=**0** |
| `aurora_meter_outbox_items` | present=**1** | present=**0** |
| `aurora_meter_source_cutovers` | present=**1** | present=**0** |
| `aurora_meter_credit_accounts` | present=**1** | present=**0** |
| what the task said | nothing | `** (UndefinedFunctionError) function R7Host.Repo.config/0 is undefined (module R7Host.Repo is not available)` |

**Leg B's `ecto.migrate` exits 0 too**, and that is worth saying out loud rather
than leaving in a column: it applies core's migration, which was generated fine,
and there is no Pro migration for it to miss. A host reading only the exit status
of its install script would have seen four zeroes and no Pro schema. The exit
status does not discriminate; the tables do.

The migrations directory is fingerprinted before and after; the task file is
snapshotted by sha256 and restored on an EXIT trap (X326), never with git; the
whole two-leg cycle runs under one held lane and refuses to start outside one
(X371).

### 1.6 An instrument of mine that was wrong, towards failure

The first version of the table check ran every query against the container's
`postgres` maintenance database rather than against the host's, so it reported
`present=0` for four tables in a leg whose `mix ecto.migrate` had just
succeeded. Caught by disbelieving a number, not by a verdict. Split into
`psql_admin` and `psql_host`; recorded here rather than quietly fixed, because
the count of instruments in this programme that were wrong is the thing being
watched, and this one was wrong in the safe direction.

---

## 2. X395: the decision, and why it was not a decision

### 2.1 What the maps say

The brief said to check `free-pro-boundary.md` and `architecture-map.md` on I08
before choosing, because which component owns a feature's source is a design
question this programme has already settled. It has, and the answer is written
in three places:

- `architecture-map.md` section 4.4, last sentence: "Therefore an events-source
  feature never reaches the flush path or **the buffered reporter** (I08)."
- `architecture-map.md` section 5.5: "The reporter stages buffered windows only
  for periods **before the watermark**."
- `pro:docs/usage-reporting.md`, opening its own section on the subject since
  build unit 04c: "The reporter stages a window for a feature only when that
  feature's **reporting source** is `:buffered`."

So this is not a repair unit redeciding I08. It is a repair unit making the code
do what I08 already says. **The package's own documentation was right and the
code was wrong**, and nothing compared them.

### 2.2 Why the crontab is the wrong place to fix it

The row offered `cron_entries/1` excluding `UsageReporter` when any feature is
events sourced as an alternative. It is not equivalent and it is worse:

- `cron_entries/1` is a pure function over a compile-time registry. It reads no
  database and no watermark. It cannot know what it would have to know.
- A host commonly has several features. One events sourced and three buffered is
  the ordinary case, and dropping the worker would **silently stop reporting the
  three**. Trading a loud refusal to boot for a quiet loss of revenue is the
  wrong direction, and it is the direction this programme has spent a fortnight
  learning to refuse.

The third candidate, a better error message, treats a row that should never have
existed as a fact to be explained.

### 2.3 The defect, in one line

```elixir
# UsageReporter.at_or_after_cutover?/2, before
case Cutover.watermark(feature) do
  nil -> false
  watermark -> DateTime.compare(period_start, watermark) != :lt
end
```

and its declared complement:

```elixir
# Outbox.before_cutover?/1
case {Cutover.watermark(feature), period_start} do
  {nil, _start} -> false
  ...
```

The two are exact complements **exactly where a watermark exists**, and at `nil`
they are both `false`. `false` in the outbox means "not before a cutover, so
accept it"; `false` in the reporter means "not at or after a cutover, so stage
it". For an events-source feature with no watermark, both export paths fire for
one feature. The reporter's row is the half that then meets the boot check.

The fix reads the feature's configured source in the `nil` case, which is the
same partition with the implicit watermark at the beginning of time:

```elixir
  nil -> Config.feature_source(feature) == :events
```

A cutover drain is untouched. During one, `feature_sources` still says
`:buffered` and the watermark still decides, which is the second branch.

### 2.4 The documentation, and the guard that keeps it honest

`pro:docs/operations/scheduler.md` is the page that recommends the crontab and
the page a host pastes from. It now carries a
`<!-- scheduler:events-source -->` section saying, in the place the crontab is,
that taking it whole is safe whatever the reporting sources are, and why.

Three tests have to stay true together, which is the shape a rule needs when
nothing enforcing it means it is already being broken (X153):

| | Test | Fails when |
|---|---|---|
| the code | `AuroraMeter.Pro.CutoverTest` / `I08 running the recommended crontab leaves the application bootable` | the reporter stages for an events-source feature. It runs the reporter and then calls `AuroraMeter.Pro.start_link/1`, which is the finding end to end |
| the recommendation | `AuroraMeter.Pro.SchedulerMapTest` / `I08 the recommendation is unconditional...` | `cron_entries/0` stops returning the reporter, which is the other candidate answer |
| the page | `AuroraMeter.Pro.SchedulerMapTest` / `I08 the page that recommends the crontab says why...` | the section or its claims go away |

plus a fourth that pins `docs/usage-reporting.md`'s sentence, because that is the
one the code now agrees with, and a control (`I08 a buffered feature is still
staged`) so a reporter that staged nothing at all could not pass the other two.

### 2.5 The sample

`examples/aurora_meter_example_ai/config/pro.exs:239` passes
`AuroraMeter.Pro.cron_entries(exclude: [:usage_reporter])` with fourteen lines of
comment explaining why. **That workaround is now unnecessary.** The sample's tree
was not edited: it is 09d's and 09c's, and removing the exclusion and its
paragraph is theirs to do.

---

## 3. X396: two things called `amount`, and the decision not to rename

### 3.1 What is true

On a hold row the two money columns say different things:

| | `amount` | `held_delta` |
|---|---|---|
| what it is | the **balance** delta | the **reserved** figure |
| on a hold | `0`, always | the reservation |

`Credits.pending_holds/1` returns those raw rows (`@type txn ::
CreditTransaction.t()`). `Credits.reconcile_holds/1` maps the same row into the
callback's `hold`, and `Reconciliation.to_hold/2` is `amount: row.held_delta`.
So `amount` is the money in one half of one documented job and zero in the other.

### 3.2 Why nothing was renamed

`api-change-map.md` section 5: "money options are `amount:` in micro-USD in core
and `amount_cents:` at Stripe boundaries in Pro". The callback's `amount` **is**
micro-USD money in core, so it carries the name the map assigns it. Renaming it
would break the map's own rule rather than serve it.

The half that is actually wrong is `pending_holds/1` handing back a row instead
of the same map, and that is not this unit's to change: it is
`@spec pending_holds(keyword()) :: [txn()]`, it shipped in **0.4.0**, and the map
carries no row for changing it. Changing a published return type into 1.0 is
exactly what that map exists to decide. Filed as **X408** for its owner, with the
three shapes it could take.

### 3.3 What was done instead

- `pending_holds/1`'s docstring has a section naming both columns with the
  worked example (`hold.amount #=> 0`, `hold.held_delta #=> 460`) and pointing
  at the `reconciler: fn _ -> :keep end` dry run as the way to read reserved
  figures in the callback's shape.
- `HoldReconciler.hold/0`'s typedoc names the trap from the other side and says
  why the field is spelled `amount`.
- `docs/credits.md`'s `pending_holds/1` example prints `amount: 0,
  held_delta: 460` instead of `...`, with a paragraph beginning "Read those two
  columns again."
- Two tests pin the pair, so a change to either column, to `to_hold/2` or to the
  documentation has to face it.

---

## 4. X397: the death the release cannot clean up after

### 4.1 Do not add a mechanism, and there was none to add

The row said to find out first. Everything needed already ships:

| | Where |
|---|---|
| list the holds | `AuroraMeter.Credits.pending_holds/1`, since 0.4.0 |
| decide about one | `AuroraMeter.Credits.HoldReconciler`, a host behaviour |
| apply the decision | `AuroraMeter.Credits.reconcile_holds/1` |
| run it on a clock | `AuroraMeter.Oban.HoldReconciliation`, **already in** `AuroraMeter.Oban.cron_entries/1` on `*/15 * * * *`, added by `mix aurora_meter.install --oban` |
| the safe default | no `:credits_hold_reconciler` configured keeps every hold |

So an installer default would have changed nothing about safety and only about
discoverability, and a new recovery mechanism would have been a second way to do
what one already does.

### 4.2 What was actually missing, and it is worse than a gap

`with_credits/4`'s own docstring said, and `docs/credits.md` repeated:

> If `fun` raises, throws or exits, the hold is released and the error
> propagates.

That is true of an exit the calling process can be told about. It is **false for
the case that strands money**. `with_credits/4` releases from a `try` in the
calling process, so it needs that process to reach its own cleanup, and a
`Process.exit(pid, :kill)`, a supervisor shutdown past the timeout, a VM that
goes away and a node that loses power all skip it.

So the page a host reads made a promise the measured behaviour breaks. That is a
documentation defect of a different class from an omission, and it was found by
going looking for the omission.

### 4.3 The case that produces one

Not the case people picture. The kill lands **inside** the callback, after it
recorded a durable fact and before it returned:

| | before | after the kill | after recovery |
|---|---|---|---|
| balance | 5 000 000 | 5 000 000 | 4 999 840 |
| **held** | 0 | **460** | 0 |
| available | 5 000 000 | 4 999 540 | 4 999 840 |

09d measured that against the sample. R7 asserts it in core's own suite, twice:
that the hold survives untouched, and that `reconcile_holds/1` closes it for the
cost the host names.

Three things disagree afterwards and the documentation described two of them.
The event is committed; the host's own row is missing; the estimate is still
reserved. Rebuilding the row from the export intent, which is the recovery
`docs/metering.md` describes, fixes the first two.

### 4.4 What changed

`with_credits/4` (a section headed "The death this cannot clean up after"),
`docs/credits.md` (the promise itself, and the "Holds nothing will ever close"
section, which told the orphan story with only its first shape) and
`docs/metering.md` (a section where a reader of the events path learns what
survives a crash, which now says the hold is open too and links the answer).
None of them adds a mechanism and all of them name one that exists.

---

## 5. The two generators, end to end

The row asked for every other way they differ, on the grounds that two
implementations of one idea, one of them known wrong, is the comparison that
finds the next one. Seven differences and two shared defects. Four are filed.

| | Difference | Which is right | Filed |
|---|---|---|---|
| 1 | core calls `Mix.Ecto.ensure_repo/2`, Pro did not | core | **X394**, fixed |
| 2 | core factors the file list into a commented `files/1`; Pro inlines it into `gen_for_repo/2` | neither, cosmetic | no |
| 3 | core's moduledoc says "See `AuroraMeter.Migration` for the version list"; Pro's names versions 2 and 3 as though that were the list, at schema version **11**, and its `--from` example is `--from 3` | core, and for a structural reason: a pointer cannot go stale | **X407** |
| 4 | core's moduledoc explains the concurrent-version split at length because core has one (version 8); Pro's explains what would happen if it had one | both right, the asymmetry is real | no |
| 5 | Pro's `--from` refusal test asserts `files(path) == []`; core's asserts only the raise | Pro's, and core should copy it | no, one line for whoever next touches core's test |
| 6 | `embed_template(:migration, ...)` is byte identical in both and shared by neither | neither. The plan is shared and the template is copied, so a change to one emits different files from the other | no, folded into X405's note that these six lines want editing together |
| 7 | core emits `concurrently: false` and `confirm_data_loss: true`; Pro emits neither | both right; the difference is in `Install.Plan`, not in the tasks, and Pro has a test asserting the absence against the guard's absence | no |

Shared, in both, therefore invisible to any comparison of one against the other:

| | Defect | Filed |
|---|---|---|
| A | Neither has `--migrations-path`, and Pro's migrations legitimately live in a second directory in a two-package install. The sample had to move the generated file by hand | **X405** |
| B | Both `create_directory(path)` **before** validating `--from`, so a refused run leaves a directory it made. Neither suite can see it, because this repo's migrations path already exists | **X406** |
| C | Both `docs/api.md` rows say the task takes `--version` and `--to`. Neither task declares them; `OptionParser` puts them in `invalid` and both tasks discard it, so `--to 5` is **silently ignored** and the host gets the full range | **X404** |

C is the one worth reading twice. It is the same two words wrong in the same way
in two packages, it is a documented way to bound a migration that does not bound
it, and nothing in either suite compares a documented switch list against
`@switches`.

**The timestamp question, asked and answered.** Both tasks stamp
`:calendar.universal_time()` at second resolution, both default to the same
migrations directory, and `pro:docs/getting-started.md` puts the two commands on
consecutive lines. Two files with the same version prefix is a duplicate
migration version, which `Ecto.Migrator` refuses outright. Measured in the real
host: the two generated names are

```
  20260917020326_add_aurora_meter.exs
  20260917020327_add_aurora_meter_pro.exs
```

so on this machine the second Mix invocation's boot time is the margin. It is a
margin rather than a guarantee, and it is recorded here rather than filed,
because the fix for it is the same `--migrations-path` X405 is about.

---

## 6. Controls

Eight, in two harnesses, each inverting one thing this repair added, in the real
tree, under a held lane for the whole patch-run-restore cycle (X371), snapshotted
and restored by sha256 (X326), never with git. Both harnesses run a baseline leg
first and refuse to continue if it is not green, so a red baseline cannot be read
as a discrimination. Both separate **BUILD** from **TEST** and count only TEST
(X373).

### Pro, `tmp/v1/r7-controls-pro.py`

| | Control | Result |
|---|---|---|
| C1 | X394: the generator stops resolving the repo, which is the shipped defect restored | TEST, 9/11 |
| C2 | X394: the generated migration nests itself, X374's shape applied here | TEST, 9/11 |
| C3 | X395: the reporter reads the watermark and never the source | TEST, 20/22 |
| C4 | X395: the crontab page loses the section that explains itself | TEST, 11/12 |
| C5 | X395: `cron_entries/0` stops recommending the reporter, which is **the other candidate answer** | TEST, 11/12 |

### Core, `tmp/v1/r7-controls-core.py`

| | Control | Result |
|---|---|---|
| C6 | X396: the reconciler maps the row's `amount` column instead of `held_delta` | TEST, 29/33 |
| C7 | X397: the kill becomes a **trappable** exit, which `with_credits/4` does clean up | TEST, 31/33 |
| C8 | a new test is renamed and `docs/correctness.md` is not | TEST, 10/12 |

**8 of 8 discriminate.** C1 is written as a whole-clause replacement rather than
a line deletion so that the result compiles: a control that fails
`--warnings-as-errors` measures the build, which is R5's C4 and X373. C7 is a
control on the **instrument** rather than on the code, and it is the one that
matters most here, because the claim is about the exit `with_credits/4` cannot
clean up after and a test that passed with a trappable one would not be about it.
C5 is the alternative answer to X395: if excluding the reporter from the crontab
did not fail the test that pins the answer taken, that test would be decoration.

### An instrument of mine that was wrong, towards failure

Both harnesses' first run reported the **baseline** as `BUILD` and stopped. The
detector looked for ExUnit's default `N tests, M failures` line and these two
suites print a custom formatter's `Result: N passed`, which it found on neither a
green run nor a red one. It refused to continue rather than counting five
controls it had not measured, which is the direction an instrument should be
wrong in and is not the direction this programme keeps finding. Recorded rather
than quietly fixed. Together with section 1.6's table check, that is two of mine
this unit, both towards failure.

---

## 7. Gate state

| | core | Pro |
|---|---|---|
| `mix check` | **exit 2** | **exit 0** |
| `compile --warnings-as-errors` | clean | clean |
| `format --check-formatted` | clean | clean |
| `credo --strict` | 5003 mods/funs, found no issues | 2731 mods/funs, found no issues |
| `dialyzer` | `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` | `Total errors: 1, Skipped: 1, Unnecessary Skips: 0` (the skip is this package's standing one, not new) |
| `docs --warnings-as-errors` | clean | clean |
| ExUnit | `2286/2288 passed (158/158 doctests, 22/22 properties, 2106/2108 tests), 8 excluded` | `1214 passed (96 doctests, 1118 tests)` |
| failures | 2, both `AuroraMeter.CIContractTest`, neither R7's | **none** |

Run at 02:10Z to 02:15Z. The counts moved the way a repair that adds tests
should: core 2284 to 2288 (four new), Pro 1210 to 1214 (ten new, and this
package's suite had already grown by a neighbour's work in the same window).

**Two of mine failed this pair the first time round and are worth recording,
because both were caught by a gate step rather than by a test.**
`mix docs --warnings-as-errors` refused a CHANGELOG line in each package:
ExDoc turns a backticked name into a link, so
`` `AuroraMeter.Credits.HoldReconciler.hold/0` `` needed the `t:` prefix it gets
for a type, and `` `AuroraMeter.Pro.TestRepo` `` cannot be linked at all because
the module is hidden. Neither is in code and neither would have been caught by a
test; the docs step is the only thing in either gate that reads a CHANGELOG.

Every file this unit touched is formatted, by name. No project-wide `mix format`
was run.

### The baselines were contaminated, by me, and the gate above is what counts

Both baseline runs were launched and then edited over: this unit started
changing files while `mix test` was still going, which is the mistake X371 is
about turned inward, on its own tree rather than on a neighbour's. **Pro's
baseline red was entirely mine.** Its three failures were
`AuroraMeter.Pro.CorrectnessIndexTest` twice and `AuroraMeter.Pro.DocExamplesTest`
once, all three of them the CRLF encoding described in section 8 breaking the
line-anchored parsers those guards use, and all three green in the gate above.
The lesson is the obvious one and it is written here rather than implied: take
the baseline, read it, and only then touch anything.

### Core's suite is not green at HEAD, and two of its three failures are not mine

Core's baseline, same caveat about when it ran:

```
Result: 2281/2284 passed (158/158 doctests, 22/22 properties, 2101/2104 tests), 8 excluded
Failed: 3 tests
```

One was mine and is gone: a Windows `python3` rewrote `docs/credits.md` CRLF
encoded and `AuroraMeter.DocExamplesTest` parses its fenced blocks. That is X403
happening to somebody else, within the hour, and it is section 8.

The other two are `AuroraMeter.CIContractTest`, both introduced by commit
`78c4839`, which is **09d's own**, and both committed rather than in flight:
`.github/workflows/ci.yml` carries `mix hex.organization auth` (that test's
banned list) and sets `AURORA_SAMPLE_PRO`, which core's `mix.exs` never reads
because the switch is the **sample's**. Filed as **X409** and deliberately not
fixed here: a repair unit editing another unit's CI leg while that unit is under
review is how one thing gets fixed twice, differently. It matters because
`v1-release.md`'s gates read "`mix check` exit 0" and core's does not.

---

## 8. Things nobody asked for

1. **X403 happened again, to me, within the hour.** Every file this unit edited
   through `python3` came back **fully CRLF encoded**, because the Bash tool on
   this machine runs Git Bash's Windows `python3`, whose text-mode writer
   translates `\n` to `os.linesep`. Sixteen files, every line of each. It
   surfaced as `AuroraMeter.DocExamplesTest` failing to parse four fenced blocks
   in `docs/credits.md` with `invalid line break character in comment: \u000D`,
   which is a good guard finding a bad edit. Fixed by stripping the carriage
   returns and verified by `git diff --stat` showing only the intended
   insertions and no whitespace churn. **The lesson is narrower than "check line
   endings"**: X403 filed this as something that happened to `mixlane.sh`, and
   the actual hazard is any tool on this machine that writes a file from the
   Windows side. Every edit after the discovery went through WSL's `python3`.
   `tmp/v1/r7-crlf.sh` is the detector, and it takes a file list.

2. **`docs/api.md` documents two switches that do not exist, in both packages**
   (X404). Worth separating from the other generator differences because it is
   not a difference: it is one wrong row copied. A test comparing a documented
   switch list against `@switches` would have caught it in both at once, and
   there is no such test in either package.

3. **The reporter's documentation was right and its code was wrong, and nothing
   compared them.** `pro:docs/usage-reporting.md` has opened its source section
   with the rule since build unit 04c. That is not a documentation defect and it
   is not a code defect; it is the absence of the thing that makes the pair one
   fact, which is what X153 is about and what section 2.4 adds.

4. **Pro's `--from` refusal test is stronger than core's** and neither package
   knows. Pro asserts `files(path) == []` after the raise; core asserts only that
   it raises. Not filed, because it is one line and whoever next opens core's
   `gen_migration_test.exs` should just take it.
