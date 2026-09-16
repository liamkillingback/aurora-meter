# R5: the installer produces an application that cannot boot

Repair unit R5, 2026-09-17 (UTC). Findings X374, X375, X376, X378 and X366.
Branch `aurorameter-v1`, nothing committed (rule 4).

**The installed application boots.** A real `mix phx.new` project, installed into
with `mix aurora_meter.install`, starts, carries the plans the installer wrote,
and meters an event:

```
  install exit=0
  plans file: lib/r5_host/plans.ex with 1 defmodule line(s)
  ecto.migrate exit=0
  BOOT OK  supervisor=#PID<0.529.0>
  plans in force: [:free, :pro]
  metered one event: used=1 limit=100 remaining=99
  check/2: :ok

  the generated config, evaluated (not grepped):
    repo: R5Host.Repo
    pubsub: R5Host.PubSub
    plans: R5Host.Plans
    undeclared_feature_policy: :deny
    R5Host.Plans exports __aurora_plans__/0: true
    modules the generated file defines: [R5Host.Plans]
```

`tmp/v1/r5-final.sh`, logs under `tmp/v1/r5/logs/final-*.log`.

---

## 0. The two questions the orchestrator asked first

### 09b's criterion 5 (`--oban`): **narrow**, and 09c's reading of it is right

> `--oban` adds the `:aurora_meter` queue and exactly the cron entries missing
> from the host's config, and adds none that are already present.

Everything the criterion says is true and was measured. What differs between the
two hosts is **one dependency**:

| | 09b's host (`tmp/v1/09b-host.sh`) | 09c's host, and R5's |
|---|---|---|
| `oban` in the host's deps | **yes**, and it must have been: the run produced `config :demo, Oban` with the queue and five cron entries, and the entries come from `AuroraMeter.Oban.cron_entries/0`, which is a module that does not exist in a build without Oban | **no**: `mix phx.new` with nothing added but `aurora_meter` and `igniter` |
| `--oban` | merged correctly, twice, byte identical | `** (UndefinedFunctionError) function AuroraMeter.Oban.cron_entries/0 is undefined` |

So the criterion describes the merge, the merge is correct, and the population it
was measured on excluded the only case in which the switch does not reach the
merge at all. **Narrow, not wrong.** What it needs is a second leg: the same
switch on a host that has not added the dependency, asserting a message that
names what to add.

There is a structural reason this could not have been caught from inside the
package, and it is worth more than the defect: **`oban` is in this package's own
lockfile**, so `Code.ensure_loaded?(Oban)` is `true` in every test this suite
will ever run. `AuroraMeter.Install.Support.oban_switch/2` now takes the two
answers as arguments rather than asking for them, so the suite can be in a state
the suite can never be in.

### 09b's criterion 6 (`--dry-run`): **narrow**, and the mechanism in X376 needs correcting

> `--dry-run` creates no file and prints the same change set the real run applies.

The first half is unconditionally true. The second half is true when, and only
when, `Igniter.Mix.Task.tty?/0` answers `true`, and it was `true` for 09b's run
and `false` for 09c's. **Narrow, not wrong**, for the same shape of reason as
criterion 5: the claim holds in the condition it was measured under and the
condition it fails under is the one a host runs it in.

**X376 says the variable is stdin, which is right, and describes it as "unless
stdin is at EOF", which is not the mechanism.** What Igniter reads is the
**file type** of `/dev/stdin`:

```elixir
# deps/igniter/lib/mix/task.ex:312
def tty? do
  case :file.read_file_info("/dev/stdin") do
    {:ok, info} -> elem(info, 2) == :device
    _ -> true
  end
rescue
  _ -> true
end
```

and `set_yes/2` (`:187`) puts `yes: true` into the options of any run where that
is `false`, while `display_diff/2` (`igniter.ex:1471`) is `if !opts[:yes]`.

Measured (`tmp/v1/r5-tty.sh`):

| stdin | `/dev/stdin` stats as | `tty?` | `--dry-run` printed |
|---|---|---|---|
| `< /dev/null` | `:device` | **true** | the full diff |
| `<&-` (closed) | `:device` | **true** | the full diff |
| a pipe | `:other` | false | one line, `Igniter:` |
| a regular file | `:regular` | false | one line, `Igniter:` |
| inherited from a script | `:other` | false | one line, `Igniter:` |

`/dev/null` is a **character device**, so redirecting from it is classified as a
terminal. That is the opposite of "at EOF", and it is why 09b's run, which did
not close stdin at all in its script but was launched with one of these shapes,
saw a full diff. The practical consequence for 09e and 11c is unchanged
(`< /dev/null` works) but the reason matters, because "close stdin" and
"redirect from /dev/null" are not the same act and only one of them is a device.

**R5 does not leave them to know that.** A dry run writes nothing and returns
before the confirmation is reached, so the `--yes` Igniter infers has nothing to
agree to and its only effect is to hide the answer; `AuroraMeter.Install.Shell.report_dry_run/1`
drops it. An explicit `--yes` is left alone.

---

## 1. X374, the defect: the generated plans module is nested inside itself

`Igniter.Project.Module.create_module/3` wraps the contents it is given
(`deps/igniter/lib/igniter/project/module.ex:151`), and
`AuroraMeter.Install.Templates.plans_module/1` returned a whole `defmodule`, so
the generated file defined `MyApp.Plans.MyApp.Plans` with an empty `MyApp.Plans`
in front of it, and the configuration the same task wrote named the empty one.

**Reproduced independently, in a real `mix phx.new` application** (09c reproduced
it in the sample and in a `mix new --sup` host; this is the third):

```
configured plans module: R5Host.Plans
ensure_loaded?: true
exports __aurora_plans__/0: false
nested name R5Host.Plans.R5Host.Plans loaded?: true

[notice] Application r5host exited: R5Host.Application.start(:normal, []) returned an error:
  shutdown: failed to start child: AuroraMeter
    ** (EXIT) ** (ArgumentError) config :aurora_meter, plans: R5Host.Plans does not export
       __aurora_plans__/0. It must be a module that `use`s `AuroraMeter.Plans`.
```

`tmp/v1/r5/logs/before-phx-boot.log`.

**The fix** is `plans_module/0` returning the module body, and the call site
passing it to `create_module/3` unchanged.

### The transferable defect, and what was done about it

09b's acceptance criteria assert that the installer **wrote the right files**.
Not one of them asserts that the application it produced would run. An installer
test that never boots the result is testing a file writer.

`Mix.Tasks.AuroraMeter.InstallTest` now has a `describe "the application the
installer produces"` block that takes the task's two outputs and does this:

1. **evaluates** the generated `config/config.exs` with `Config.Reader.eval!/2`,
   rather than matching a string in it, and reads `plans:` from the result;
2. **compiles** the generated plans file with `Code.compile_string/1` and
   asserts the set of modules it defines is exactly `[that module]`;
3. runs **the boot check itself**,
   `AuroraMeter.Config.Schema.ensure_exports!/4` with the contract read from
   `AuroraMeter.Config.module_contracts/0`, which is the call
   `AuroraMeter.start_link/1` makes and the one that raised;
4. asserts the plans in the compiled module are `[:free, :pro]`.

Beside it is a permanent control that builds the nested form from **today's**
template (so it cannot go stale), asserts it really does define both modules,
and asserts each of the three checks above fails on it.

**What this would have caught, and what it would not.** It catches any
disagreement between the module the configuration names and the module the
generated file defines, which is exactly the defect and the whole family it
belongs to (a rename, a prefix change, a template that stops being a body). It
does **not** start an OTP application: this suite has one `AuroraMeter`
supervisor of its own and one global `:aurora_meter` configuration, and a second
is not something a test project can be handed, so it would not catch a defect in
the supervision-tree placement, in the migration's contents at run time, or in
anything that needs a database. **X377 is an example of something it does not
catch**, and R5 reproduced X377 too: see section 6. The real
`mix phx.new` host is the harness for those, and it is `tmp/v1/r5-final.sh`
rather than a test in `mix check`, because it needs `mix phx.new`, the network
and a database.

---

## 2. X375 and X378: `--oban` in a host with no Oban

Two symptoms of one cause. `AuroraMeter.Oban` is compiled only under
`Code.ensure_loaded?(Oban)`; two call sites were not guarded the same way.

**The crash** (`install.ex:251`) is now a refusal, checked with `Options.parse/1`
before anything is computed, so the tree is untouched:

```
  exit=1  tree unchanged
  * --oban was passed and this application does not have Oban.

    Add it to your deps in mix.exs and run this task again:

        {:oban, "~> 2.17"}

    Aurora Meter does not depend on Oban. Every operation its workers wrap is a
    public function you can call from any scheduler, so you can also skip the
    switch entirely and schedule them yourself: see the scheduler map in the
    documentation.

    Nothing was written.
```

The version comes from `AuroraMeter.Install.Support.floor_for(:oban)`, the same
table `--check-support` prints, so it cannot drift from the floor. There is a
second message for the state that looks the same to a host and needs the opposite
answer: Oban installed, `aurora_meter` compiled before it was added, answered
with `mix deps.compile aurora_meter --force`, which is the `:stale_build` verdict
`Support.rows/1` already reports.

**The two warnings** (X378) are gone. A forced clean recompile of the dependency
in a `mix phx.new` host with no Oban:

```
  exit=0  warnings naming AuroraMeter.Oban: 0  total warnings: 0
```

before this repair, the same command printed

```
warning: AuroraMeter.Oban.queue/0 is undefined       lib/aurora_meter/install/oban.ex:161:60
warning: AuroraMeter.Oban.cron_entries/0 is undefined lib/mix/tasks/aurora_meter.install.ex:251:34
```

(`tmp/v1/r5/logs/mkhost-phx-compile.log`, from building the host at HEAD.)

- `oban.ex:161` asked `AuroraMeter.Oban` for the queue name. It now asks
  `AuroraMeter.Install.Templates.queue/0`, which is always compiled. That is a
  copy of a constant, so `AuroraMeter.InstallShellTest` asserts the two agree on
  a build that has Oban, and a control that makes them disagree fails it (C5).
  It also removes a **second** hard-coded `aurora_meter` literal that was already
  in `Templates.oban_config/2` and agreed with nothing.
- `install.ex:251` is now `apply(AuroraMeter.Oban, :cron_entries, [])`, reached
  only after the refusal above has established the module is there. `apply/3`
  and not a compile-time branch, deliberately: with a branch, removing the
  refusal would silently write an empty crontab; with `apply/3` it raises, which
  is the behaviour this repair is replacing and the loud direction to fail in.
  Registered in `AuroraMeter.NoOutboundIoTest`'s `@dynamic_targets` with what
  bounds it, which is that test's whole point.

---

## 3. X376: `--dry-run` in a script

Measured from a script whose stdin is a pipe, in a real `mix phx.new` host:

```
  exit=0
  wrote nothing: the file inventory is identical
  it named: Update: config/config.exs
  it named: Create: lib/r5_host/plans.ex
  it named: Update: lib/r5host/application.ex
  it named: Create: priv/repo/migrations/20260916230113_add_aurora_meter.exs
  diff lines printed: 44

  the real run, same arguments, in an identical copy:
  it created: lib/r5_host/plans.ex
  it created: priv/repo/migrations/20260916230116_add_aurora_meter.exs
  (config/config.exs and lib/r5host/application.ex already existed and were updated)
```

Both halves of criterion 6, in the condition it used to fail in. The dry run
names four paths; the real run creates the two that did not exist and updates the
two that did.

`--dry-run --yes` still prints nothing, and that is X367's documented shape
rather than a regression: an operator who types `--yes` has asked for the quiet
form. It is the control that shows the change is narrow rather than "always
print":

```
  and --dry-run --yes, the combination X367 names, still prints nothing:
  exit=0  diff lines printed: 0
```

The notices are still suppressed in a dry run with changes: `do_or_dry_run/2`
calls `display_notices/1` only on the no-changes branch and after a real write
(`igniter.ex:1186`, `:1259`). That is Igniter's behaviour, it is not what
criterion 6 asks for, and R5 did not change it.

---

## 4. X366: an Igniter refusal now exits 1

Taken, and the reason is the one the finding gives: 09e's clean room will be a
script that checks `$?`, and today every refusal in both packages is
indistinguishable from a success to one.

**Every refusal path in both packages was checked.** There are exactly two
Igniter tasks in the two repositories (`grep -rn 'use Igniter.Mix.Task'`):
`mix aurora_meter.install` and `mix aurora_meter_pro.install`. Every
`Igniter.add_issue/2` call site is in those two (core: one, the parse/oban
refusal; Pro: two, both the expiry conflict). Both tasks now wrap their own
`run/1` through `AuroraMeter.Install.Shell.halt_on_issues/1`.
`Igniter.Mix.Task.__using__/1` ends with `defoverridable run: 1`, so this is the
framework's own seam rather than a fight with it, and the issues have already
been displayed by the time the status is set.

Measured on disk, every refusal the core task has:

```
  --feature-policy bogus               exit=1  files written: none
  --events-source tokens:bogus         exit=1  files written: none
  --events-source tokens               exit=1  files written: none
  --events-source Tokens.Bad:events    exit=1  files written: none
  --oban                               exit=1  files written: none
  a run that succeeds                  exit=0  (the control: the status is not a constant)
  a second, idempotent run             exit=0
```

Pro's refusal is asserted in its own suite through the shared function; it was
not measured on disk, because building a Pro host is a unit of work of its own
and the wiring is one line identical to core's. Said plainly rather than implied.

---

## 5. Controls

### In suite, seven, every one watched failing (`tmp/v1/r5_controls.py`)

Each inverts one behaviour this repair added, in the real tree, under
`mixlane.sh hold core` for the whole patch-run-restore cycle (X371), snapshotted
and restored by copy with sha256 verified (X326), never with git.

The detector separates **BUILD** from **TEST** and counts only TEST, and it
requires the failing test to be the one the control is about. That is X373, which
is one day old, and it earned its keep on the first run:

| | Control | First run | Final |
|---|---|---|---|
| C1 | the installer hands `create_module/3` a whole `defmodule` again | TEST | TEST |
| C2 | the nesting control stops nesting, so it is no longer a control | TEST | TEST |
| C3 | a refusal goes back to exiting 0 | TEST | TEST |
| C4 | a dry run keeps the `--yes` Igniter inferred | **BUILD** | TEST |
| C5 | the installer's copy of the queue name drifts from `AuroraMeter.Oban`'s | TEST | TEST |
| C6 | `--oban` stops refusing a host that has no Oban | TEST | TEST |
| C7 | the version the refusal asks for stops coming from the support matrix | TEST | TEST |

**7 of 7 discriminate. One of them did not on its first attempt and the harness
said so instead of counting it.** C4's first inversion was
`if is_nil(options) && ...`, chosen precisely because the compiler cannot fold it
the way it folds `false`; Elixir 1.20's type checker then inferred `options` as
`nil` from the guard and refused `Keyword.put(nil, :yes, false)`, so the build
failed and no test ran. Rewritten as a replacement of the whole function body,
which inverts the behaviour with no warning. A detector matching only
`CompileError` would have recorded that run as 7 of 7.

A baseline leg runs first and asserts the suite is green before any control, so a
red baseline cannot be read as a discrimination.

### On disk, three paired legs, real `mix phx.new` host (`tmp/v1/r5_disk_controls.py`)

The same three legs with the repair reverted and with it in place:

| Leg | Reverted | Repaired |
|---|---|---|
| L1 install, then **boot** | install rc=0, boot rc=1, `ArgumentError: plans module does not export __aurora_plans__/0` | install rc=0, boot rc=0, `BOOT OK [:free, :pro]` |
| L2 `--oban` with no Oban | exit=1, `UndefinedFunctionError` naming `AuroraMeter.Oban`, wrote nothing | exit=1, refused naming `{:oban, "~> 2.17"}`, wrote nothing |
| L3 a refusal's exit status | refusal exit=**0**, a run that succeeds exit=0 | refusal exit=**1**, a run that succeeds exit=0 |

**L2's exit status does not discriminate and the message does.** An uncaught
`UndefinedFunctionError` exits 1 too, so the pair differs only in what the host
is told, which is the whole of the finding; recorded here rather than left for a
reader to notice that two 1s are in the same column.

### Two instruments of mine that were wrong, both towards failure

Recorded because the programme's count of instruments failing towards success is
the thing being watched, and these are the other direction.

1. The first boot probe asserted `AuroraMeter.plans()`, which does not exist, so
   the first post-fix run reported `boot rc=1` on an application that had
   booted. Caught by reading the log rather than the verdict.
2. The final verification's configuration probe called `function_exported?/3` on
   a module in a `mix run --no-start` VM, where it is not loaded, and printed
   `exports __aurora_plans__/0: false` for a module that does. `Code.ensure_loaded/1`
   first. Both were fixed before anything in this page rested on them.

---

## 6. Reproduced but not fixed, because it is not this unit's

**X377 is real and R5 reproduced it.** In a real `mix phx.new` application the
installer appends `AuroraMeter` to the **end** of the child list:

```elixir
children = [
  R5HostWeb.Telemetry,
  R5Host.Repo,
  {DNSCluster, ...},
  {Phoenix.PubSub, name: R5Host.PubSub},
  # Start to serve requests, typically the last entry
  R5HostWeb.Endpoint,
  AuroraMeter
]
```

`IgniterApp.add_new_child(AuroraMeter, after: fn mod -> mod in [repo, Phoenix.PubSub] end)`
places it after the last matching child, and in a Phoenix application that is not
before the endpoint. Left to 09b, whose row it is. `docs/getting-started.md` now
tells a reader to check where it landed and to move it above the endpoint, so a
host following the page is not misled while the row is open.

---

## 7. What changed

Core:

| File | Why |
|---|---|
| `lib/aurora_meter/install/templates.ex` | `plans_module/0` returns the body (X374); `queue/0` added and used in `oban_config/2` (X378); `oban_missing/1` and `oban_not_compiled/0` (X375) |
| `lib/aurora_meter/install/oban.ex` | `queues/1` uses `Templates.queue/0` (X378) |
| `lib/aurora_meter/install/support.ex` | `floor_for/1` and `oban_switch/2` (X375) |
| `lib/aurora_meter/install/shell.ex` | new, internal: `halt_on_issues/1` (X366) and `report_dry_run/1` (X376) |
| `lib/mix/tasks/aurora_meter.install.ex` | the body-not-defmodule call, the `--oban` refusal, `run/1`, the dry-run report, and the moduledoc for all of it |
| `mix.exs`, `docs/api.md`, `test/aurora_meter/api_inventory_test.exs` | the new internal module registered in the three places that must agree |
| `test/aurora_meter/install_shell_test.exs` | new, 12 tests, the three states this suite can otherwise never be in |
| `test/mix/tasks/install_test.exs` | the boot block and its control, and one `defmodule` count on the plain run |
| `test/aurora_meter/telemetry/no_outbound_io_test.exs` | the new `apply/3` target and what bounds it |
| `docs/correctness.md` | six I20 bullets |
| `docs/getting-started.md` | the task, its four switches, what a refusal does, and where the child lands (X374's related half, and X377) |
| `CHANGELOG.md` | five entries under Fixed |

Pro: `lib/mix/tasks/aurora_meter_pro.install.ex` (`run/1` and the dry-run
report), `test/mix/tasks/pro_install_test.exs`, `CHANGELOG.md`.

## 8. Gate state

| | Result |
|---|---|
| core `mix check` | **exit 0**. `credo --strict` no issues, `dialyzer` `Total errors: 0`, **2179 passed** (82 doctests, 22 properties, 2075 tests) with 8 excluded, `docs --warnings-as-errors` clean, `compile --warnings-as-errors --force` with **0** warnings |
| Pro `mix check` | **exit 0**, **1159 passed** (74 doctests, 1085 tests) |

Both green, at 23:23Z and 23:24Z. Every file this unit touched is formatted, by
name; no project-wide `mix format` was run.

**A failure I did not cause, which was red for part of this unit and is not any
more.** Between 22:27Z and 23:08Z core's `format --check-formatted` was red on
three files, all of them another unit's work in flight:
`lib/aurora_meter/credits/recurrences.ex` (modified),
`test/aurora_meter/credits_new_wallet_test.exs` and
`test/aurora_meter/components_change_tracking_test.exs` (both untracked). The
first two belong to the unit implementing X380/X283/X255 (a wallet born on the
allocator); `lib/aurora_meter/credits/ledger.ex` carries its comment naming that
decision. The third belongs to the unit taking X379. All three are formatted
now. Recorded because it is what a neighbour's in-flight tree looks like from
inside another unit, and because the R4 file the brief warned about was no longer
among them.

**A neighbour's work was also visible in two test failures during this unit**, and
this is X371's other half: at 22:20 core's `examples_test.exs` failed on
`{:error, :debt_outstanding}` where it expected `:insufficient_credits`, and
Pro's `credits_lots_test.exs` failed asserting `lots_enabled_at` was null. Both
are the born-on-lots change landing, both were theirs, both are green in the runs
above. Checked rather than reported as flakes.

## 9. The sample

`examples/aurora_meter_example_ai/` was not touched.

Its plans module is its own hand-written one, which is what 09c used to work
around this defect and which its own moduledoc explains; with X374 fixed that
file is a choice rather than a workaround and needs no change. **The fenced
function in `lib/mix/tasks/sample.seed.ex` is not this repair's**: it works
around X380 (`Ledger.enable_lots!/1` being the only way to reach the lot engine),
which is the born-on-lots unit's, and it stays until that decision lands.

## 10. Things nobody asked for

1. **X376's mechanism is not "stdin at EOF"** (section 0). `/dev/null` is a
   character device and is therefore classified as a terminal; a pipe and a
   regular file are not. Worth correcting in the row, because the advice that
   rests on it ("redirect stdin from `/dev/null`") is right for a reason that
   will surprise whoever next reads it, and `<&-` works for the same accidental
   reason.
2. **`AuroraMeter.EvidenceWritesTest` matches on prose.** It calls a test file a
   writer of committed evidence if the source contains both `docs/evidence` and
   `File.write!`, anywhere, in any order. `test/mix/tasks/install_test.exs` has
   carried the first since 09b, in a comment; adding a `File.write!` of a
   **temporary** file made it a writer. It cost ten minutes and the fix was to
   stop writing a temp file at all (`Config.Reader.eval!/2` takes the contents),
   which is better code, so nothing was changed in the guard. Recorded because
   the next unit will not be so lucky, and because a guard that can be tripped by
   a comment is a guard whose next false positive gets an entry added to its
   allow list.
3. **Pro's dialyzer PLT does not notice a new module in core.** Adding
   `AuroraMeter.Install.Shell` to the free package left Pro's `mix check` failing
   with `Function AuroraMeter.Install.Shell.halt_on_issues/1 does not exist`,
   because the PLT keys on the app version and core is still `0.5.0`.
   `tmp/v1/07c-plt-reset.sh` fixes it and already exists, which means this has
   been met before (X114). Anything that adds a module to core and then runs
   Pro's gate needs it, and nothing says so outside that script's own comment.
