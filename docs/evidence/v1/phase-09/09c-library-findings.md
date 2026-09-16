# 09c: what the first real application found in the library

Build unit 09c is the first time Aurora Meter is used the way a customer will
use it: a real Phoenix application, built from `mix phx.new` output and the
package's own installer, rather than the package's own test suite. Six of the
findings below are things an in-package suite is structurally unable to see,
because the package always has its own optional dependencies present, always
has its plans module written by hand, never writes a host's table and never
renders a host's page.

**Nothing in this file was patched.** Every one is reported against the owning
unit. The sample works around finding 1 by writing its own plans module (which
it was going to do anyway) and around finding 5 in one fenced function with a
comment that says why.

## Where these live in `open-findings.md`

All nine are filed as rows in
`PhxTemplates/docs/v1/build-plans/open-findings.md`, appended 2026-09-17 from
X373. This file is the long form; those rows are what every later unit reads.

| Here | There | In one line |
|---|---|---|
| 1 | **X374** | the installer produces an application that cannot boot |
| 2 | **X378** | the free core warns in any host without Oban |
| 2a | **X375** | `--oban` crashes in a host without Oban (09b criterion 5 was narrow) |
| 3 | **X376** | `--dry-run` prints nothing unless stdin is at EOF (09b criterion 6 was narrow) |
| 3a | **X377** | the installer puts `AuroraMeter` after the endpoint |
| 4 | **X379** | `usage_meter/1` does not update under change tracking |
| 5 | **X380** | the credit lot engine is unreachable on a new installation |
| 6 | **X381** | `record/4`'s identity includes `occurred_at` |
| 7 | **X382** | the LiveView helpers are message-first and fail silently |

Two things in section 8 below are recorded inside those rows rather than as
rows of their own: `docs/getting-started.md` never naming
`mix aurora_meter.install` is in X374, and the ergonomic cost of raising out of
`with_quota/4` is in the documentation section further down.

Ordered by how much they would cost a reader.

---

## 1. `mix aurora_meter.install` produces an application that does not boot

**Severity: high. Owner: 09b. Reproduced twice, in the sample and in a fresh
throwaway host.**

`AuroraMeter.Install.Templates.plans_module/1` returns a complete
`defmodule ... do ... end`, and `Igniter.Project.Module.create_module/3` wraps
whatever body it is given in a `defmodule <name> do ... end` of its own. Elixir
prefixes a nested module name with the outer one, so the generated file

```elixir
defmodule Host.Plans do
  defmodule Host.Plans do
    use AuroraMeter.Plans
    plan :free do ... end
  end
end
```

defines `Host.Plans` (empty) and `Host.Plans.Host.Plans` (the real one). The
configuration the same task writes points at the empty one, so the application
refuses to start:

```
** (ArgumentError) config :aurora_meter, plans: AuroraMeterExampleAi.Plans does
   not export __aurora_plans__/0. It must be a module that `use`s `AuroraMeter.Plans`.
    (aurora_meter 0.5.0) lib/aurora_meter/config/schema.ex:178
    (aurora_meter 0.5.0) lib/aurora_meter.ex:667: AuroraMeter.start_link/1
```

Full log: `tmp/v1/09c/logs/09c-boot-installer-plans.log`.

**The boot check did its job perfectly** and names the key, the module and what
is missing. The defect is upstream of it.

**Discrimination** (`tmp/v1/09c-plans-nesting.sh`): the same probe was run
against the installer's file and against the same file with the outer
`defmodule` removed. `Code.ensure_loaded?(Host.Plans.Host.Plans)` is `true` for
the first and `false` for the second, so the probe distinguishes the two rather
than reporting the same thing about any tree. The file was snapshotted and
restored by copy, never by git (X326).

**Why the package's own suite cannot see it.** `09b`'s evidence
(`09b-install-matrix.md`) asserts `lib/demo/plans.ex | created | use
AuroraMeter.Plans with :free and :pro`, which is true: the file is created and
it does contain that text. Nothing started the application the task produced.

**The fix is one line** in `lib/aurora_meter/install/templates.ex`: return the
module body rather than a whole `defmodule`. Not made here.

---

## 2. The free core emits compiler warnings in any host that does not use Oban

**Severity: medium. Owner: 09b or the owner of `lib/aurora_meter/install/`.**

Compiling `aurora_meter` as a dependency of a host without `oban`:

```
warning: AuroraMeter.Oban.cron_entries/0 is undefined (module AuroraMeter.Oban
  is not available or is yet to be defined)
  lib/mix/tasks/aurora_meter.install.ex:251:34

warning: AuroraMeter.Oban.queue/0 is undefined (module AuroraMeter.Oban is not
  available or is yet to be defined)
  lib/aurora_meter/install/oban.ex:161:60
```

Both appear on **every** compile of the dependency, in dev and in test. They are
the first thing a new host sees.

`AuroraMeter.Oban` is compiled only when `Code.ensure_loaded?(Oban)`, and the
two call sites above are not guarded the same way. The package's own suite never
sees this because `oban` is in the package's own lockfile, so the module always
exists there.

### 2a. `mix aurora_meter.install --oban` crashes in that host

Same cause, worse symptom. The switch exists to wire Oban into a host, and in a
host that has not yet added the dependency it raises:

```
** (UndefinedFunctionError) function AuroraMeter.Oban.cron_entries/0 is undefined
   (module AuroraMeter.Oban is not available)
    (aurora_meter 0.5.0) lib/mix/tasks/aurora_meter.install.ex:251
    (aurora_meter 0.5.0) lib/mix/tasks/aurora_meter.install.ex:165
    (aurora_meter 0.5.0) lib/mix/tasks/aurora_meter.install.ex:95
```

Nothing is written, which is right, but the message names an internal module and
gives a host nothing to act on. What it should say is "add `{:oban, \"~> 2.17\"}`
to your deps and run this again".

**Filed as X375. 09b's criterion 5 was narrow rather than wrong.** It reads
"`--oban` adds the `:aurora_meter` queue and exactly the cron entries missing
from the host's config", and `09b-install-matrix.md` shows it verified against a
host that resolved `AuroraMeter.Oban`: the run produced `config :demo, Oban`
with the queue and five cron entries, and a host in which that module did not
exist could not have produced them. The criterion covers the case the task
handles. The case it does not handle is the natural reading order, someone
finding `--oban` in the documentation before they have added Oban, and it needs
a second leg asserting a message that names what to add.

---

## 3. `mix aurora_meter.install --dry-run` reports nothing at all

**Severity: medium. Owner: 09b.**

The task's own documentation says `--dry-run` "prints the diff the task would
apply and writes nothing". The second half is true. The first is not, in a
non-interactive shell.

**Filed as X376, and the cause was isolated after that row was written: it is
stdin, not the host.** Four legs against one untouched fresh host
(`tmp/v1/09c-dryrun-isolate.sh`), all dry runs, all writing nothing:

| Leg | Command | Lines printed |
|---|---|---|
| A | `--dry-run`, stdin inherited from the calling script | **1** (the bare `Igniter:` header) |
| B | `--dry-run < /dev/null` | **60** (the full diff, naming all three files) |
| C | leg B with a pre-existing `config/config.exs` | **59** |
| D | `--dry-run --yes` | **1** |

The host shape does not matter (B and C agree). A and D are
byte-indistinguishable, which is why this is easy to mistake for X367, and
X367's own text says `--dry-run` alone "with stdin closed" prints the full diff,
which leg B confirms. **So 09b's criterion 6 was narrow rather than wrong**: it
holds under one stdin condition and fails under another, and the failing
condition is the one a CI runner or any harness that redirects output into a
file without closing stdin will hit.

The original reproduction, before the isolation, was in a fresh throwaway host
(`tmp/v1/09c-dryrun-fresh.sh`), with the dry leg and the real leg run against
two byte-identical copies:

```
DRY leg:  rc=0, printed "Igniter:" and nothing else, wrote nothing
REAL leg: rc=0, wrote 3 files (config/config.exs, lib/host/plans.ex, the
          migration) and printed 2 notices
VERDICT: the dry run wrote nothing AND reported nothing, while the real run
         wrote 3 files and printed its notices
```

Logs: `tmp/v1/09c/logs/09c-fresh-dry.log`, `09c-fresh-real.log`.

Note that the **notices** are suppressed too, not just the diff, and Igniter
prints those itself in the real run. A host running `--dry-run` in CI, which is
the obvious place to run it, learns nothing whatsoever.

## 3a. A related, smaller one

`mix aurora_meter.install` appends `AuroraMeter` to the end of the host's
supervision children, **after** the Phoenix endpoint. `docs/getting-started.md`
says "after the Repo and PubSub", which is right, and the installer does not do
it: a request arriving in the window between the endpoint accepting connections
and Aurora Meter's ETS tables existing has no table to read. The sample moved
the line and says so in a comment.

---

## 4. `AuroraMeter.Components.usage_meter/1` does not update live

**Severity: medium, and it is a correctness problem in what a customer sees.
Owner: the owner of `lib/aurora_meter/components.ex`.**

`usage_meter/1` calls `AuroraMeter.quota/2` **inside itself**, from the tenant
it was given, so its rendered output depends on data that is not in its assigns.
LiveView's change tracking does not re-render a function component whose assigns
did not change. A socket that is subscribed correctly, is receiving the usage
broadcast, and is re-rendering will still show a stale meter.

`components.ex`'s own moduledoc says "Pair with `AuroraMeter.LiveView.subscribe/1`
for live usage updates", and pairing them is not enough.

**Discrimination.** `test/support/meter_probe_live.ex` is two minimal LiveViews
that differ in exactly one attribute. Both subscribe to the same tenant, both
receive the same broadcast, both re-render (a `#tick` counter moves in both).

| LiveView | `#tick` after the broadcast | meter after the broadcast | actual usage |
|---|---|---|---|
| `Stale` (no changing attribute) | `1` | `0 / 200` | 3 |
| `Fresh` (`data-usage={@tick}`) | `1` | `3 / 200` | 3 |

`test/aurora_meter_example_ai_web/live/usage_meter_change_tracking_test.exs`,
two tests, both green.

The sample's own `/generate` carries `data-usage={@usage_version}` for this
reason, with a comment. Without it the page is silently wrong, and it was
silently wrong in the browser until this was found.

**Suggested shape for the fix**, for whoever owns it: take an optional
`:quota` assign so a host can pass a value it has already computed, or document
the requirement loudly in `docs/phoenix.md` and in the moduledoc. A component
that reads the world behind change tracking's back cannot be made to work by the
host without the host knowing why.

---

## 5. There is no supported way for a new installation to reach the credit lot engine

**Severity: high for what V1 documents. Owner: 06b, or whoever owns X250.**

`lots_enabled_at` is null on every new wallet. `docs/credits.md` says so:
"which is every wallet until `mix aurora_meter.credits.migrate_lots` runs". That
task's real cutover is **refused**:

```
$ mix aurora_meter.credits.migrate_lots --no-shadow
aurora_meter.credits.migrate_lots will not cut a wallet over yet.
AuroraMeter.Credits.reverse/4 does not take the lot path yet ...
** (Mix) aurora_meter.credits.migrate_lots: the cutover is refused (X250).
```

So on a fresh install, for every wallet:

- `AuroraMeter.Credits.Lots.list/2` and `allocations/2` return `[]`;
- `debt` and `expired` are permanently `0`, so repair unit R3's
  `:debt_outstanding` state and the honest-figures work behind it are
  unreachable;
- the plan DSL's `recurring_credits` grants nothing, because
  `AuroraMeter.Credits.Recurrences` only scans wallets where `lots_enabled_at`
  is set (`recurrences.ex:82`, `:844`);
- D07's credit priority (promotional before paid, earliest expiry first) is not
  observable at all.

The only function that sets the flag is
`AuroraMeter.Credits.Ledger.enable_lots!/1`, which is **not** on the public
`AuroraMeter.Credits` facade, is not named in `docs/credits.md` or
`docs/upgrading-to-lots.md` as a new-install path, and whose own docstring says
it is "all this unit needs and all it permits".

**Discrimination** (`tmp/v1/09c-lots-probe2.sh`):

| Leg | Result |
|---|---|
| `enable_lots!` on a wallet with no ledger rows | accepted; three grants and one debit then produce 3 lots and 2 allocation rows, and the spend draws the earlier-expiring promotional lot first |
| `enable_lots!` on a wallet that already has rows | refused by name, which is correct and is what makes the first leg meaningful |
| `Lots.list/2` on a wallet without the flag | `[]`, and `allocations/2` `[]` |

**What the sample does.** `mix sample.seed` calls `enable_lots!/1` before the
first grant, in a function of its own, under a twenty-line comment saying that
it is not public API, why it is there, and that when there is a public way this
function becomes that call. The README repeats it. Without it the sample's
operations page shows two empty tables and the acceptance criterion about
allocation order cannot be met at all.

**What V1 should decide.** Either a public `AuroraMeter.Credits.enable_lots/1`
for a wallet with no history, documented as the thing a new installation calls
once, or a statement in `docs/credits.md` that lots are an upgrade-only feature
in 1.0 and that everything resting on them is too. The current position is
neither: the feature is documented as if it were on, and nothing turns it on.

---

## 6. `record/4`'s identity includes `occurred_at`, so "retry with the same id" needs the whole payload

**Severity: low as a defect, high as a documentation gap. Owner: 03b, or the
owner of `docs/metering.md`.**

`AuroraMeter.record/4`'s documentation says:

> **An unknown outcome is retryable with the same `id`, never with a fresh
> one.** Every `{:error, {:unavailable, _}}` means "this may or may not have
> committed"; repeating the call with the same identity is the only safe answer,
> and it is always safe.

The payload hash covers `occurred_at` to the microsecond
(`lib/aurora_meter/events/canonical.ex:246`, `:274`). A caller that retries with
the same id and stamps a fresh `DateTime.utc_now()` therefore gets
`{:error, {:conflict, existing}}`, not `{:ok, event, :duplicate}`.

That is correct behaviour and the right answer to the question it was asked. It
is also not what the sentence above leads a host to build, and it is exactly
what the sample's first recovery path did. The constraint is real: **a caller
that did not persist the payload before the call cannot reproduce it after a
crash**, so "retry with the same id" is only available to a caller that kept the
whole option list.

`test/aurora_meter_example_ai/record_identity_test.exs` pins the whole boundary
down from a host's side, including the half that is easy to miss: **the prompt is
not part of the identity**, because customer content is not in the event at all,
so two different customer requests with the same token count, model and instant
are one fact to the metering system. Deciding they are different requests is the
host's job, every time.

**Suggested wording**: "repeating the call with the same identity **and the same
payload** is the only safe answer. Persist the payload before you call, or keep
your own record of what you recorded: the `Events.Outbox` seam gives you one."

---

## 7. `AuroraMeter.LiveView.handle_usage/2` and `handle_credits/2` take the message first

**Severity: low, but it fails silently. Owner: 09a.**

Every other socket function in Phoenix is socket-first (`assign/3`,
`put_flash/3`, `update/3`). These two are message-first, so the natural

```elixir
socket |> AuroraMeter.LiveView.handle_usage(message)
```

is wrong. It does not raise: it falls through to the helpers' catch-all clause
`def handle_usage(_other, socket), do: socket`, which returns its second
argument, so the pipe yields **the message** instead of the socket. The failure
surfaces wherever that value is next used, which in the sample was a
`BadMapError` in an unrelated function three lines later:

```
** (BadMapError) expected a map, got:
    {:aurora_meter, :credits, %{balance: 26994390, ...}}
    lib/aurora_meter_example_ai_web/live/generate_live.ex:190: ... refresh_credits/1
```

The catch-all is there for a good reason (dropping another tenant's message),
and it is what turns an argument-order mistake into a silent wrong-type return.
A clause that matched a `Phoenix.LiveView.Socket` first argument and raised with
a message naming the order would cost nothing and save the ten minutes this
cost.

---

## 8. Smaller things found on the way

**`docs/getting-started.md` does not mention `mix aurora_meter.install`.** It
offers `mix igniter.install aurora_meter` and `mix aurora_meter.gen.migration`,
and says nothing about the task 09b built, its four switches, or the fact that
the Igniter route is what runs it. A reader following that page never meets
`--events-source` or `--feature-policy`.

**`docs/examples/` now holds six walkthroughs, not five.** `events-source.md`
was added after 09c's build document was written. Minor, recorded because the
build document's baseline was nine phases old and this is one of the things that
moved.

**`aurora_meter-0.5.0.tar` is sitting untracked in the package root**, from
someone's earlier `mix hex.build`. `.gitignore` carries `*.ez` but not `*.tar`,
so a `git add -A` would take it. It predates this unit; this unit's own archive
build wrote to `/tmp` precisely to avoid adding a second one. X365's family.

**Credit grant references are unique globally, not per tenant.** The unique
index is on `(kind, reference)`. Two tenants cannot both have a grant referenced
`"welcome"`. This is almost certainly deliberate (a payment id is global) but it
is not stated anywhere a host would look, and it cost one probe run here.

---

---

## What happened when the documentation was followed

The brief asked specifically whether `docs/phoenix.md` and
`docs/getting-started.md` survive being followed. They were, by building the
sample from them.

### `docs/phoenix.md`: survives, and is good

Everything in it was used and everything worked as written.

| Recipe | Used at | Worked |
|---|---|---|
| `plug AuroraMeter.Plug.EnsureEntitled, feature:, tenant:` in a pipeline | `router.ex`, the `:metered_api` pipeline | yes |
| `tenant: {Module, :function}` form | `{AuroraMeterExampleAiWeb.ApiAuth, :org}` | yes |
| `on_denied: {Module, :function}` rendering JSON, must return a halted conn | `ApiErrors.denied/2`, mapping `:limit_exceeded` to 402 | yes, exactly as the page's example |
| `conn.assigns.aurora_meter_tenant` and `aurora_meter_quota` on a passing request | read back in the controller and asserted in a test | yes |
| `{AuroraMeter.LiveView, {:subscribe, assign: :current_org, topics: [...]}}` after the host's hook | two `live_session` blocks | yes |
| "the plug is advisory, and `with_quota/4` is where the money is" | the whole `/api/generate` design | yes, and the `{:error, :limit_exceeded}` clause it says is not defensive programming is reached by a test |
| "if a failure should not be billed, raise or throw out of the callback" | `Generations.Refused` | yes, and this is the sharpest edge in the integration. See below |

The one paragraph that turned out to matter more than its length suggests is
this one:

> `with_quota/4` commits the reservation on **any** normal return, including
> `{:error, :whatever}` from your own code. **If a failure should not be billed,
> raise or throw out of the callback.**

It is correct, it is prominent, and it still costs a host a small piece of
machinery: a business refusal that happens inside the callback has to be turned
into an exception and back into a tuple outside. `Generations.Refused` is nine
lines and a paragraph of comment, and every host that gates anything with a
quota will write it. It is worth considering whether `with_quota/4` should take
a fifth shape, something like `{:refuse, reason}`, that releases and returns,
so the host does not have to use the exception system for a control-flow answer
the library already understands.

The recipe under "An events-source feature" is also worth a second look. It
shows `AuroraMeter.with_quota(org, :tokens, estimate, ...)` wrapping a
`record/4`, and the release-on-success behaviour that makes the arithmetic net
out. The sample gates tokens with **credit** rather than with a quota, so it did
not use that shape, and the page does not say which of the two a host should
reach for first. A sentence pointing at the credit ledger for "can this customer
afford it" and at `with_quota/4` for "does this plan allow it" would help.

### `docs/getting-started.md`: does not survive being followed

Step 2 offers `mix igniter.install aurora_meter` or
`mix aurora_meter.gen.migration`. It never mentions `mix aurora_meter.install`,
its four switches, or the fact that the Igniter route runs that task. A reader
following this page never meets `--events-source` or `--feature-policy`, which
are the two decisions that are hardest to change later: the task's own
documentation says both are "created and never changed".

And a reader who does find the task gets finding 1 above: an application that
does not boot.

Step 4 says "`application.ex` after the Repo and PubSub", which is right, and
the installer does not do it (finding 3a).

Step 5's `AuroraMeter.subscribe(org, :free)` / `track` / `check` sequence works
exactly as written.

### One more thing about the page's audience

Neither page tells a new host that the credit lot engine is off, which is
finding 5. `docs/credits.md` does, in one clause inside a `@type` doc, and that
is not where a host starting out will find it.

## What this says about the phase-09 gate

G09's browser-test bullet is met by this unit
(`09c-browser-matrix.md`). G08 bullet 5's sample half, owed here by finding
X352, is met by `isolation_test.exs` in the shape X352 asked for: the forbidden
tenant is unresolvable, and the proof is over the run rather than over a
rendered string.

Findings 1, 2, 3 and 3a are against `09b`, which is marked `REVIEWED`. Finding 4
is against the components module. Finding 5 is a V1 scope question rather than a
bug. Findings 6 and 7 are documentation and ergonomics. None of them was
patched from this unit.
