# 08b: the dashboard authorization contract, and what the core page may show

Build unit **08b**, tasks **08.03**, **08.04**, **08.05**. Invariant **I20**
(owner). Core SHA at start `9284866` (`aurorameter-v1`), Pro `58ce8a9`.
Toolchain: Elixir 1.20.1 on Erlang/OTP 29.0.1, Postgres on `DB_PORT=5490`.
Written 2026-09-16.

This file is the authorization half. The optional-dependency matrix, the
resolved versions and every command with its exit code are in
`08b-optional-integrations.md`; the handler counts are in `08b-handler-leaks.md`.

## 1. What a library page can and cannot enforce

`architecture-map.md` section 9 says both pages "require the host to mount them
inside an authenticated dashboard route". That is a statement about the host,
and a library cannot enforce it: a page mounted inside `Phoenix.LiveDashboard`
cannot inspect the host's router pipelines and cannot know who is signed in.

So two things are enforced instead, and the limit is written down rather than
implied away.

**It refuses to exist until the host states a decision.**
`AuroraMeter.LiveDashboard.Auth.validate!/2` takes `:authorized_by` and there is
no default and no implicit allow. Three forms are accepted and nothing else:

| Value | Meaning | Allowed on |
|---|---|---|
| `{module, function, args}` | `module.function(socket, args)` must return exactly `true` | core, Pro |
| `{:assign, key}` | `socket.assigns[key] == true` | core, Pro |
| `:host_route` | the route itself is authenticated and node-local aggregates may be shown | **core only** |

**It re-reads that decision on every refresh.** `handle_refresh/1` evaluates the
check again before reading anything, so a session that loses its marker stops
seeing data without waiting for a remount.

**The residual risk** is the host's own `on_mount` hook, and the mitigation that
does not depend on the host is section 3: the core page renders no tenant data
at all.

## 2. The refusal, as rendered

`AuroraMeter.LiveDashboard.PageTest` / `test I20 dashboard page refuses without
host auth: a check returning false renders the refusal panel and no section
data` mounts with `{:assign, :operator?}` and `operator?: false`, and asserts:

* `socket.assigns.aurora_allowed?` is `false`;
* `socket.assigns.aurora_readings` is `[]`, so **no section query ran at all**:
  the check is evaluated before anything is read, not after;
* the rendered output contains "not authorized" and names the configured check;
* `Floki.find(document, "table")` and `Floki.find(document, "dl")` are both `[]`.

The panel, rendered:

```html
<div class="aurora-dash__refused">
  <h3>Aurora Meter: not authorized</h3>
  <p>
    This session is not authorized to see Aurora Meter's operational data:
    the assign :operator? is not exactly true. Nothing is shown rather than a
    partial view.
  </p>
  <p>
    The check is configured with the page's <code>:authorized_by</code>
    option. See <a href="...">AuroraMeter.LiveDashboard.Auth</a>.
  </p>
</div>
```

The Pro half of criterion 3 is `AuroraMeter.Pro.LiveDashboard.PageTest` / `test
I20 the Pro page renders no outbox row, tenant key or provider ref when the
check returns false`, recorded in `pro:docs/evidence/v1/phase-08/08b-pro-dashboard-authorisation.md`.
**It seeds an uncertain outbox item first and asserts the section is populated
before it asserts the refusal renders nothing**, because a refusal over an empty
database proves nothing.

## 3. The core page renders no tenant-identifying value

This is the substantive control, and it is what lets the core page accept
`:host_route` while the Pro page refuses it.

`AuroraMeter.LiveDashboard.ViewTest` / `test rendering every section with seeded
data produces no tenant key, feature name, reference or event id` seeds one
distinctive value of each kind and then asserts the rendered page carries none
of them.

| Kind | Seeded as | How |
|---|---|---|
| tenant key | `leakprobe<n>` | `AuroraMeter.subscribe/2` plus `track/3`, so it is in the counter table, the credit ledger and a checkpoint name |
| feature name | `:ai_generations` | tracked and recorded durably |
| reference | `leakref<n>` | `Credits.grant/3`'s reference, and `"<ref>:hold"` on a pending hold |
| event id | `leakevt<n>` | `AuroraMeter.Events.record/4` with an explicit `id:` |

**The test asserts the sections are populated before it asserts what is
missing**, because a page that rendered nothing at all would pass every
`refute html =~ ...`:

```elixir
assert Enum.all?(readings, &match?({_name, {:ok, _data}}, &1))
assert {:ok, {:ok, metering}} = Keyword.fetch(readings, :metering)
assert metering.counter_keys >= 1
assert {:ok, {:ok, credits}} = Keyword.fetch(readings, :credits)
assert credits.holds >= 1
assert {:ok, {:ok, workers}} = Keyword.fetch(readings, :workers)
assert workers.operations != []
assert {:ok, {:ok, events}} = Keyword.fetch(readings, :durable_events)
assert events.generations != [] or events.projection != nil
```

Then, and only then, the four `refute`s.

### 3a. The one place this nearly failed, and the fix is in the query

`aurora_meter_checkpoints` names a row `"<operation>:<scope>"`, and for a
per-tenant operation the scope **is a tenant key**: `"lot_migration:org_42"`.
A workers section that listed checkpoint names would put a tenant key on the
free core page, behind a marker assign, on every host that has ever run the lot
migration.

`AuroraMeter.LiveDashboard.Sections.read(:workers)` therefore groups on
`split_part(name, ':', 1)` **in SQL** and never returns a whole name. Grouping
in the database also bounds the result: the row count is operations times
states, not one per tenant. `AuroraMeter.LiveDashboard.SectionsTest` / `test the
workers section groups on the operation and never returns a whole checkpoint
name` plants `"lot_migration:<tenant>"` and asserts the tenant key is absent
from `inspect(data)`, which is stronger than asserting it is absent from the
rendered HTML: it is absent from the reading.

Recorded as **X336** in `open-findings.md`, because the same hazard applies to
anything else that renders a checkpoint name, and 09c mounts this page in the
sample.

## 4. Every named case

| Test | What it fixes to |
|---|---|
| `I20 dashboard page refuses without host auth: init/1 raises ArgumentError when :authorized_by is absent` | the message names the option and all three accepted forms |
| `I20 dashboard page refuses without host auth: an unrecognised form raises and names the three` | `authorized_by: true` is refused, not treated as "allow" |
| `I20 dashboard page refuses without host auth: a check returning false renders the refusal panel and no section data` | section 2 |
| `I20 dashboard page refuses without host auth: a check that raises is treated as false and logs a warning` | a buggy host function closes the page, it does not open it |
| `I20 {:assign, key} requires the assign to be exactly true, not truthy` | `"yes"`, `1`, `:ok` and `%{}` are each refused in turn |
| `I20 the core page accepts :host_route, because it renders no tenant-identifying value` | the asymmetry, from the core side |
| `I20 the Pro page refuses :host_route with a distinct error` (Pro) | the asymmetry, from the Pro side, asserting **both** in one test |
| `the check is re-evaluated on refresh, so a session that loses its marker stops seeing data` | `handle_refresh/1`, not only `mount/3` |
| `an authorized mount reads every section and the page renders no mutation control` | no `<form>`, no `<button>`, no `phx-click` |

## 5. What this does not prove

* The host's `on_mount` hook is the host's. Nothing here can check it.
* `:host_route` is honest about what it is: a statement, not a check. It is
  accepted only on the page that renders no tenant data, and the Pro page's
  refusal message says so in the words a host will read.
* Neither page was mounted in a browser in this unit. The browser demonstration
  of G08 bullet 5 is 09c's, which mounts both pages in the sample behind its own
  admin marker.
