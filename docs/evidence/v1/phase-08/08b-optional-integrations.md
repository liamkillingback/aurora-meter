# 08b: optional integrations, and the I20 record

Build unit **08b**, tasks **08.03** (LiveDashboard pages), **08.04**
(OpenTelemetry bridge and provider spans) and **08.05** (alert examples).
Invariant **I20**, owner. Gates G08 bullet 2 and the core half of bullet 5.

| Item | Value |
|---|---|
| Core SHA at start | `92848660938076160a1c4e21e1dde803b159f49b` (`9284866`, `aurorameter-v1`) |
| Pro SHA at start | `58ce8a99475cccc92600dcf3f37660d5055c4788` (`58ce8a9`, `aurorameter-v1`) |
| Storefront SHA at start | `276ec550d50d149109dd4f6b777bd92c382c6f98` (`276ec55`, `aurorameter-v1`) |
| Elixir | 1.20.1 |
| Erlang/OTP | 29.0.1 |
| Database | Postgres 16.13 in `aurora-meter-pro-testdb`, `DB_PORT=5490` |
| Written | 2026-09-16 |

This is the I20 evidence file. The authorization contract is in
`08b-dashboard-authorisation.md`, the handler counts in `08b-handler-leaks.md`,
the alert derivations in `08b-alerts.md`, and Pro's three files are in
`pro:docs/evidence/v1/phase-08/`.

## 1. The optional dependencies, resolved

| Package | Dependency | Declared | Resolved | Guarded module |
|---|---|---|---|---|
| core | `phoenix_live_dashboard` | `>= 0.8.0 and < 0.9.0` | **0.8.7** | `AuroraMeter.LiveDashboard.Page` |
| Pro | `phoenix_live_dashboard` | `>= 0.8.0 and < 0.9.0` | **0.8.7** | `AuroraMeter.Pro.LiveDashboard.Page` |
| core | `opentelemetry_api` | `~> 1.2` | **1.5.0** | `AuroraMeter.OpenTelemetry` |
| core | `opentelemetry` (the SDK) | `~> 1.3`, `only: :test` | **1.7.0** | not shipped; this repository's `otel` leg only |

### 1a. Why the requirement is the 0.8 line and not `~> 0.8`

The build document says `~> 0.8`. For a two-segment requirement that means
`>= 0.8.0 and < 1.0.0`, which carries 0.9 as well: the first attempt at
`mix deps.get` resolved **0.9.1**. `Phoenix.LiveDashboard.PageBuilder`'s callback
set has changed across minor versions, and declaring a range wider than the
matrix resolves is a support claim nothing tests, which is what decision D12
forbids and what this unit's own risk section names as the mitigation. The
shipped requirement is the tested line.

### 1b. The `PageBuilder` callback set, confirmed against 0.8.7

Read from `deps/phoenix_live_dashboard/lib/phoenix/live_dashboard/page_builder.ex`
at version 0.8.7 in this tree, not from documentation:

| Callback | Optional? | Used here |
|---|---|---|
| `init(term()) :: {:ok, session} \| {:ok, session, requirements}` | no (`use` defines a default) | **yes**, and overridden: this is where `:authorized_by` is validated |
| `menu_link(session, capabilities) :: {:ok, text} \| {:disabled, text} \| {:disabled, text, url} \| :skip` | no | **yes** |
| `mount(params, session, socket)` | yes | **yes** |
| `render(assigns)` | no | **yes** |
| `handle_params(params, uri, socket)` | yes | no |
| `handle_event(event, params, socket)` | yes | **no, deliberately**: the pages are read-only |
| `handle_info(msg, socket)` | yes | no |
| `handle_refresh(socket)` | yes | **yes**, and it is where the authorization check is re-evaluated |

`capabilities` is a **map** (`%{applications:, dashboard_running?:, modules:,
processes:, system_info:}`), not a keyword list. Both `menu_link/2` specs said
`keyword()` on the first pass and Dialyzer refused them with
`callback_spec_arg_type_mismatch`. That is the only thing in this unit `mix
check` caught that `mix test` did not.

## 2. What is guarded and what deliberately is not

The split is the point of the design, and it is what makes the criteria
testable on a build with no optional dependency at all.

| Module | Guard | Compiled without the dependency? |
|---|---|---|
| `AuroraMeter.LiveDashboard.Page` | `Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)` | no |
| `AuroraMeter.Pro.LiveDashboard.Page` | same | no |
| `AuroraMeter.OpenTelemetry` | `Code.ensure_loaded?(:otel_tracer)` | no |
| `AuroraMeter.LiveDashboard.Sections` | **none** | **yes** |
| `AuroraMeter.LiveDashboard.Auth` | **none** | **yes** |
| `AuroraMeter.LiveDashboard.View` | `Code.ensure_loaded?(Phoenix.Component)` (LiveView, not LiveDashboard) | yes without LiveDashboard |
| `AuroraMeter.Pro.LiveDashboard.Sections` | **none** | **yes** |
| `AuroraMeter.Pro.LiveDashboard.View` | `Code.ensure_loaded?(Phoenix.Component)` | yes without LiveDashboard |
| `AuroraMeter.OpenTelemetry.Bridge` | **none** | **yes** |
| `AuroraMeter.OpenTelemetry.Tracer` | **none** | **yes** |

Every acceptance criterion about behaviour lands on a module in the unguarded
half. The guarded modules are adapters: `AuroraMeter.LiveDashboard.Page` is 50
lines of callback plus one private `load/2`, and `AuroraMeter.OpenTelemetry` is
`attach/1` and `detach/0,1` delegating to the bridge plus four `:otel_*` calls.

## 3. The switches, and X331

Three now, and the third is the finding.

| Switch | Removes | Keeps |
|---|---|---|
| `AURORA_HEADLESS=1` | every optional dependency in core | nothing optional |
| `AURORA_NO_METRICS=1` | `telemetry_metrics` **and `phoenix_live_dashboard`**, in both packages | Oban, LiveView, `phoenix_html`, Igniter |
| `AURORA_NO_DASHBOARD=1` | `phoenix_live_dashboard`, in both packages | everything else, including `telemetry_metrics` |
| `AURORA_NO_OTEL=1` | `opentelemetry_api` and the test-only `opentelemetry` SDK, in core | everything else, including `phoenix_live_dashboard` |

`AURORA_NO_METRICS` had to widen, and that is **X331**.
`phoenix_live_dashboard 0.8.7` declares `{:telemetry_metrics, "~> 0.6 or ~> 1.0",
optional: false}`: a **required** dependency. Had the dashboard been declared
without widening the switch, `AURORA_NO_METRICS=1` would have removed one
declaration and had the dependency pulled straight back in by the other. The leg
would have run, been green, and been asserting the presence of the module it is
named for removing. That is X327's shape one dependency further out, and the
general rule is in the finding: a switch removes a **declaration**, and whether
the dependency is in the build is a question about the resolved graph.

Both switches are asserted for **narrowness** rather than claimed to be narrow:
`AuroraMeter.OptionalIntegrationsTest` / `test I20 AURORA_NO_DASHBOARD removes
the dashboard dependency and nothing else` and its Pro twin each assert, on the
narrow leg, that `Oban`, `Phoenix.Component`, `Phoenix.LiveView`, `Igniter` and
`Telemetry.Metrics` are **still loaded**, and that
`AuroraMeter.LiveDashboard.Sections`, `AuroraMeter.LiveDashboard.Auth` and
`AuroraMeter.OpenTelemetry.Bridge` are still compiled and still answer.

**X337** is the same finding pointing the other way: core's I20 matrix test
asserted five modules against `AURORA_HEADLESS` alone, including
`Telemetry.Metrics`, so it could never have passed on an `AURORA_NO_METRICS`
leg. 08a ran that leg on Pro only, and Pro had no such test file at all. Core's
is now switch-aware and Pro has one.

## 4. The matrix legs

See section 8 for the numbers.

| Leg | Command | What it proves |
|---|---|---|
| `dashboard` (the ordinary build) | `08b-core-check.sh`, `08b-pro-check.sh` | both pages compiled, both page test files run |
| `headless` | not re-run by this unit | 08a's leg, unchanged except that `AURORA_HEADLESS` now also removes `phoenix_live_dashboard` |
| `no-dashboard` core | `08b-legs.sh core-no-dashboard` | `Phoenix.LiveDashboard.PageBuilder` and both page modules undefined; `Sections`, `Auth` and `Bridge` defined and tested; the other four optional dependencies present |
| `no-dashboard` Pro | `08b-legs.sh pro-no-dashboard` | the same, with Oban and LiveView asserted present |
| `otel` present (the ordinary build) | `08b-core-check.sh` | `AuroraMeter.OpenTelemetrySdkTest` runs against a real tracer provider and a real exporter |
| `otel` absent | `08b-legs.sh core-no-otel` | `:otel_tracer` and `AuroraMeter.OpenTelemetry` undefined, `Bridge` still compiled and still answering, the other five optional dependencies present |

Every leg deletes the dependency beams on the way **in and out** (X329): `mix
compile --force` forces the current project and never a path dependency, so a
leg that only cleans on the way in leaves the next full build inheriting a
partial core. That cost 08a two false failures in one afternoon.

## 5. Criterion 14, item by item

> With `phoenix_live_dashboard` and `opentelemetry_api` absent, both packages
> compile with `--warnings-as-errors` and the full suites pass, with the four
> guarded modules undefined and `AuroraMeter.LiveDashboard.Sections` defined and
> tested.

| Item | Status |
|---|---|
| both packages compile `--warnings-as-errors` | met, on the `no-dashboard` leg in both packages |
| full suites pass | met |
| `AuroraMeter.LiveDashboard.Page` undefined | met |
| `AuroraMeter.Pro.LiveDashboard.Page` undefined | met |
| `AuroraMeter.OpenTelemetry` undefined | met on the `core-no-otel` leg, and **present and exercised** on the ordinary build: both halves, which is what the criterion is for |
| `AuroraMeter.Pro.Live.Dashboard` undefined | **not exercised**: it is guarded on `Phoenix.LiveView`, which no switch in this unit removes and which Pro requires in practice. It is asserted in the presence direction by `AuroraMeter.Pro.OptionalIntegrationsTest` |
| `AuroraMeter.LiveDashboard.Sections` defined and tested | met: `sections_test.exs` carries no dashboard reference and runs on every leg |

## 6. The `otel` leg, and the defect a real SDK found

This section used to say the leg could not run. That was wrong, and the way it
was wrong is the finding (**X335**): `opentelemetry_api` was **never declared in
either `mix.exs`**, the author read the unit's "no network call" instruction as
covering `mix deps.get`, found no tarball in the local Hex cache and concluded
the dependency was unobtainable. Mix reaches Hex on this machine. The dependency
is now declared, the module compiles, and the leg runs in both directions.

### 6a. What is declared

```elixir
{:opentelemetry_api, "~> 1.2", optional: true},   # resolves 1.5.0
{:opentelemetry, "~> 1.3", only: :test}           # resolves 1.7.0
```

The **API** is the optional dependency a host installs. The **SDK** beside it is
`only: :test` and is not optional and not shipped: it exists so this
repository's own leg can assert the span shape against a real tracer provider,
rather than against `AuroraMeter.OpenTelemetry.Tracer`, which is this package's
own code. A consumer who wants spans installs `opentelemetry_api` and whichever
SDK and exporter they already run. Decision D11 is unchanged and is now
checkable: the four API calls below start no provider, no exporter and no
connection.

`config/config.exs` (test only) sets `span_processor: :simple` and
`traces_exporter: :none`: simple rather than the default batch processor,
because a batch processor exports on a timer and a test would be asserting on a
race. The test redirects the processor to `:otel_exporter_pid`, which ships in
the SDK for exactly this and sends each finished span to a pid. Both the
`mix.exs` entry and the configuration block are behind `AURORA_NO_OTEL`, because
a configuration block and the dependency it configures have to be removed by the
same switch or Mix warns about configuring an application that is not there.

### 6b. The OpenTelemetry API functions this package calls

Read from `deps/opentelemetry_api` at 1.5.0 in this tree, not from memory:

| Call | Used for |
|---|---|
| `:opentelemetry.get_tracer/1` | the tracer, named `:aurora_meter` |
| `:otel_tracer.start_span/3` | both paths; `%{attributes:, kind: :internal}` and, for a completed span, `start_time:` |
| `:otel_tracer.current_span_ctx/0` | capturing the parent before a span pair becomes current |
| `:otel_tracer.set_current_span/1` | making a span pair current, and putting the parent back |
| `:otel_span.set_attributes/2` | the stop half of a span pair |
| `:otel_span.set_status/3` | `:error` with an **empty** message |
| `:otel_span.end_span/1`, `:otel_span.end_span/2` | closing a pair, and closing a completed span at an explicit instant |

None starts a provider, an exporter, a batch processor or a connection.

### 6c. What first contact changed

Three things were checked against the source and were **right** as written:

* attribute values may be atoms (`otel_attributes`'s `?is_allowed_value` includes
  `is_atom`), so `result: :ok` and `kind: :error` survive rather than being
  dropped;
* `opentelemetry:timestamp/0` is `erlang:monotonic_time/0`, so the **native**
  units the bridge computes `end_time - duration` in are the units the API
  expects. `test a flat event's completed span carries the measured duration
  exactly` asserts `end_time - start_time == duration` on the recorded span,
  which is the assertion that would have failed had the units disagreed;
* `set_status/3` takes `:error` and a binary, and an empty binary is a valid
  message.

One thing was **wrong**, and it is the kind of thing only a real SDK shows.

`start_span/2` made the new span current and `end_span/3` never put the previous
one back. The **emitting** process was therefore left pointing at a span that
had ended. In a request-shaped system that is a leak until the request ends; here
the handlers run inside processes that live for ever (`AuroraMeter.Flusher`
flushes for ever), so every later span would have been parented to a finished
span, and the one after that to another finished span, for the life of the node.

The fix captures `:otel_tracer.current_span_ctx/0` **before** the new span
becomes current and restores it in `end_span/3`. The parent travels inside the
opaque span token the `Tracer` behaviour already returns, so the bridge did not
change at all.

Control **c19** restores the defect and fails `a span pair leaves the caller's
current span where it found it`:

```
code:  assert :otel_tracer.current_span_ctx() == before
left:  {:span_ctx, 202705090216052119153582030910690076331,
right: :undefined
```

### 6d. What the SDK leg asserts

`AuroraMeter.OpenTelemetrySdkTest`, 9 tests, all against the `#span{}` record a
real `otel_simple_processor` hands `otel_exporter_pid`:

| Test | What it fixes |
|---|---|
| `the public attach/1 attaches, and a flush span pair reaches a real exporter` | the **public** function, the only test that runs the four lines of delegation a host calls |
| `a flat event's completed span carries the measured duration exactly` | `end_time - start_time == duration`, the units |
| `B5 no attribute on a real span carries a tenant key, a reference, an event id or a provider ref` | **criterion 13 on the attribute map that actually leaves the process**, including `batch_id`, and asserting the map is not empty so the refutations are about redaction |
| `B5 an exception sets the status to error with no message, and carries error_class` | the status message is `""`, and the raise's text is nowhere |
| `a span pair leaves the caller's current span where it found it` | 6c, and that two spans are siblings rather than a chain |
| `the provider span name carries the operation, against a real tracer` | the span name |
| `attaching five times still produces one span per operation against a real tracer` | B3 end to end, not only as a handler count |
| `detach/0 stops the spans and leaves handlers attached by anything else alone` | B3's other half |
| `B4 the hot path produces no span against a real tracer either` | the hot path, against an SDK that would really have recorded one |

Criterion 13 is now asserted **twice**: through the seam, where the input is a
metadata map this unit wrote, and against a real exporter, where the input is
whatever the SDK decided to keep. The seam is this package's own code, and a
redaction proved only through it is a statement about the seam.

### 6e. Pro gets the absent half for free

`optional: true` dependencies of a **path** dependency are not fetched by the
parent, so `:otel_tracer` is absent in Aurora Meter Pro's build and the core
compiled inside `aurora_meter_pro/_build` has no `AuroraMeter.OpenTelemetry` in
it. That is a real deployment ("Pro installed, no OpenTelemetry API") rather than
an artefact, and Pro's suite passes in it with
`AuroraMeter.Pro.OptionalIntegrationsTest` asserting only that
`AuroraMeter.OpenTelemetry.Bridge` is compiled and answering, which it is. So the
absent half of criterion 14 holds in two builds made two different ways: core's
`AURORA_NO_OTEL` leg, and Pro's ordinary one.

## 7. The negative controls

`python3 tmp/v1/08b_controls.py`, 18 controls, one log each under
`tmp/v1/08b-logs/controls/`. The baseline is asserted before the first patch
(every anchor must occur exactly once in its target) and every restore is
verified against this run's own sha256 snapshot. **No `git checkout` anywhere**:
programme rule 4 means an author's tree is dirty by construction, so a checkout
would destroy the work on tracked files and do nothing at all on untracked ones
(**X326**).

See section 8 for the verdicts.

## 7a. The controls, one by one

18 controls, `tmp/v1/08b-logs/controls/<id>.log` each. **All 18 discriminated**,
three of them only after being rewritten, and two of those rewrites are findings
rather than tidying.

| Control | What it breaks | Verdict | Result |
|---|---|---|---|
| `c01-params-tenant-wins` | the shipped 0.3.0 `params["tenant"] \|\| session` line | discriminated | 0/6 |
| `c02-absent-session-falls-back` | only the raise on an absent session tenant | discriminated | 5/6 |
| `c03-subscribe-to-params` | only the live feed, not the snapshot | discriminated | 5/6 |
| `c04-nothing-is-ever-stale` | `stale?/2` never answers true | discriminated | 6/7 |
| `c05-unsampled-gauge-is-zero` | an unsampled gauge reports zeroes | **passed first**, then discriminated | 25/26 |
| `c06-workers-render-the-checkpoint-name` | the whole checkpoint name, tenant key and all | discriminated | 23/25 |
| `c07-truthy-is-authorized` | truthiness instead of exactly `true` | discriminated | 8/9 |
| `c08-authorized-by-has-a-default` | `:authorized_by` gains a default | discriminated | 8/9 |
| `c09-pro-accepts-host-route` | the Pro page accepts `:host_route` | discriminated | 16/17 |
| `c10-sections-read-before-the-check` | every section is read whatever the check said | discriminated | 6/9 |
| `c11-attach-does-not-detach-first` | `attach/1` stops removing its own handlers first | discriminated | 14/15 |
| `c12-hot-path-is-instrumented` | the hot path joins the default event list | discriminated | 11/15 |
| `c13-span-attributes-are-not-redacted` | raw metadata reaches the tracer | discriminated | 11/15 |
| `c14-flat-event-with-no-duration-gets-a-span` | a fabricated zero-length span | discriminated | 14/15 |
| `c15-uncertain-renders-the-error-body` | the provider's error text on an operator's screen | **harness error first**, then discriminated | 17/18 |
| `c16-provider-result-is-always-ok` | a failing provider call reports success | discriminated | 6/7 |
| `c17-provider-operations-are-open` | the closed operation set gains a name | discriminated | 6/7 |
| `c18-pro-unavailable-renders-an-empty-table` | an unavailable Pro section renders `0` and an empty table | **passed first**, then discriminated | 17/18 |

### The three that did not discriminate first time

**`c15` was a harness error, and it is X300's trap.** The control patched the
call site and orphaned `error_class/1`'s binary clause, so the file failed to
**compile** under `--warnings-as-errors`. That is not a control that
discriminated and not a control that passed: it tested nothing, and only the
harness's separate compile-failure check distinguishes the three. Rewritten to
invert the function's **body** (the split is still performed, both clauses stay
reachable), it discriminates.

**`c05` and `c18` each found a missing assertion.** This is the case the rule
"if a control passes, ask why" exists for, and both answers were the same shape:
the assertion existed against a **synthetic** input and never against the code.

* `c05` made `Sections.gauge/1` answer `%{measurements: %{}, age_ms: 0, stale?: false}`
  for a gauge nothing had sampled. The only test of "not sampled yet" handed
  `View.page/1` a hand-written `gauge: nil`, so it never called `gauge/1`. The
  new test restarts `AuroraMeter.Store` under its supervisor to get a process
  that has provably never sampled, and asserts `read(:metering).gauge == nil`.
* `c18` made an unavailable Pro section render an empty table and a zero. Core's
  `ViewUnavailableTest` scans the rendered DOM for both; **Pro had no such
  scan**. It does now.

### `c11` is worth reading for the opposite reason

`c11` removes the `detach(name)` that `attach/1` runs first, and it
**discriminated** on a test that is not the handler-count test. The count
assertions still pass, because `:telemetry.attach/4` refuses a duplicate id and
returns `{:error, :already_exists}`, so the second attach leaves the same 12
handlers whether or not the first were removed. What fails is
`B5 tenant: :digest puts a digest on the span and tenant: :raw is required for
the key`, which attaches twice with **different options** and asserts the second
set is in force:

```
code:  assert raw.attributes["aurora_meter.tenant_key"] == "org_secret_42"
left:  nil
```

So the property "attaching twice is attaching once" is guarded, and the test
that guards it is not the one whose name says so. A count of handlers cannot
distinguish "attach detaches first" from "telemetry refuses the second"; the
options assertion can.

## 8. Commands, exit codes and numbers

Every command through `tmp/v1/mixlane.sh`, which serialises Mix against one
`_build`. No two Mix tasks ran at once, and core and Pro never ran together.

| # | Command | Exit | Reading |
|---|---|---|---|
| 1 | `08b-core-check.sh` (`mix check`: format, compile `--warnings-as-errors --force`, credo `--strict`, dialyzer, test, docs `--warnings-as-errors`; core beams and the PLT deleted first) | **0** | **1963 passed (80 doctests, 20 properties, 1863 tests), 6 excluded**. Baseline 1900 |
| 2 | `08b-pro-check.sh` (Pro's PLT and the core beams in Pro's `_build` deleted first, X114 and X329) | **0** | **1135 passed (72 doctests, 1063 tests)**. Baseline 1098 |
| 3 | `08b-legs.sh core-no-dashboard` (`AURORA_NO_DASHBOARD=1`) | deps.get **0**, compile `--warnings-as-errors --force` **0**, suite **0** | **1943 passed**: nine fewer, the page test files compiling themselves away with the module |
| 4 | `08b-legs.sh pro-no-dashboard` | deps.get **0**, compile **0**, suite **0** | **1129 passed** |
| 4a | `08b-legs.sh core-no-otel` (`AURORA_NO_OTEL=1`) | deps.get **0**, compile `--warnings-as-errors --force` **0**, suite **0** | **1954 passed**. `:otel_tracer`, `:otel_simple_processor` and `AuroraMeter.OpenTelemetry` all **undefined**; `Bridge` still compiled, still answering, still six default events; Oban, `Phoenix.Component`, `Phoenix.HTML`, Igniter, `Telemetry.Metrics` and `Phoenix.LiveDashboard.PageBuilder` all asserted **present** |
| 4b | `mix test test/aurora_meter/open_telemetry_sdk_test.exs` (the `otel` leg present: a real tracer provider, a real `otel_simple_processor`, a real `otel_exporter_pid`) | **0** | **9 passed** |
| 4c | `python3 08b_controls.py c19-span-pair-does-not-restore-the-parent` | **0** | **discriminated**, `Result: 8/9 passed`. The defect the SDK found; section 6c |
| 5 | `python3 08b_controls.py` (18 controls) | **0** | all 18 discriminated; `restore verified` on every file. Section 7a |
| 6 | `08b-property-seeds.sh core` | **0** at each of 0, 1, 7, 42, 1337 | **11 files** selected by content; **217 passed (42 doctests, 20 properties, 155 tests)** at every seed |
| 7 | `08b-property-seeds.sh pro` | **1, which is the correct answer** | **0 files**: Pro declares no property (**X324**). The sweep refuses rather than expanding to a bare `mix test` and calling the whole suite a property sweep |
| 8 | `08b-pro-seeds.sh` (five full Pro suites at fixed seeds, named for what it is) | **0** at each seed | **1135 passed** at 0, 1, 7, 42 and 1337 |
| 9 | `mix run 08b_handler_leaks.exs` | **0** | 0, 12, 12 after five attaches, 12 and 12 under two names, 0 after each detach; the unrelated handler survives. See `08b-handler-leaks.md` |
| 10 | `08b-pro-explain.sh` (`EXPLAIN ANALYZE` over 2,100 seeded outbox items and 400 credit accounts, cleaned up by prefix and verified) | **0** | backlog aggregate 0.628 ms, pending payments 0.041 ms, uncertain detail 0.450 ms |

### 8a. The suite deltas

| Package | Before | After | Delta |
|---|---|---|---|
| core | 1900 | **1963** | +63 |
| Pro | 1098 | **1135** | +37 |

### 8b. Two things `mix check` caught that `mix test` did not

* **Dialyzer**: `menu_link/2`'s second argument was spec'd `keyword()` and the
  callback's type is a map (`callback_spec_arg_type_mismatch`). Both packages.
* **Credo `--strict`**: four "nested modules could be aliased" in new test files
  and three "function body is nested too deep" where a `provider_span/2` closure
  was written inline inside a `case` or a `with`. The three are now bound to a
  variable first, which reads better anyway.

## 8b2. Where each acceptance criterion is proved

The author does not tick these (programme rule 4). This table says where the
proof is, and it says plainly where the proof is not what the criterion asked
for.

| # | Criterion | Where | Note |
|---|---|---|---|
| 1 | `:authorized_by` absent fails at registration | `PageTest` / `init/1 raises ArgumentError...` in both packages | |
| 2 | Pro page refuses `:host_route` with a distinct error | `Pro.LiveDashboard.PageTest` / `I20 the Pro page refuses :host_route...` | asserts the **core** page accepts it in the same test, so the asymmetry is one assertion |
| 3 | Check false: no row, count, tenant key, provider ref or payment value; refusal panel names the check | core `ViewTest`, Pro `PageTest` | both **seed first** and assert the sections are populated before asserting the absence |
| 4 | Every core section with seeded data renders no tenant key, feature name, reference or event id | core `ViewTest` | four seeded identifiers, four `refute`s, preceded by four `assert`s that the sections have data |
| 5 | Database stopped: every affected section "unavailable" with a class, no `0` and no empty table | core `SectionsUnavailableTest` + `ViewUnavailableTest`, Pro `SectionsUnavailableTest` + `PageTest` | **the outage is a real `DBConnection.OwnershipError` from an unowned process, not a stopped Postgres.** The class is the one a connection failure produces; a stopped server is 11d's |
| 6 | A gauge older than three `metrics_interval`s renders stale with the sample age | core `ViewTest` | `AuroraMeter.Test.with_clock` plus `travel(60, :second)`, `metrics_interval: 10_000`, asserted at **exactly** `60_000` ms. Monotonic through `AuroraMeter.Clock`, never a wall clock (X100) |
| 7 | `params: other`, `session: mine` renders mine, subscribes to mine, never reads other | Pro `Live.DashboardTest`, four named tests | "never reads" is a **resolver that refuses**, not a string assertion |
| 8 | No session tenant raises `ArgumentError` | same file | three cases: absent, `nil`, `""` |
| 9 | Pro `CHANGELOG.md` records it as breaking with upgrade steps; `api-change-map.md` matches | Pro `CHANGELOG.md` Unreleased / Changed; `api-change-map.md` row reclassified | |
| 10 | Five attaches leave one handler per event; `detach/0` leaves zero and leaves others alone | core `OpenTelemetryTest` B3 trio, `08b-handler-leaks.md`, **and** `OpenTelemetrySdkTest` end to end against a real exporter | count computed from `default_events/0`, not written down |
| 11 | The hot path and every gauge produce zero spans | core `OpenTelemetryTest` B4 pair, **and** `OpenTelemetrySdkTest` against an SDK that would really have recorded one | the second half of the pair proves the escape hatch exists, so the first is not vacuous |
| 12 | A flush span pair is one span with the measured duration and a `result`; a `record` event is one completed span with the measured duration | core `OpenTelemetryTest` | **deviation, stated.** The flush pair is asserted to **bracket** the operation: the tracer's own elapsed time and `:telemetry.span/3`'s measured duration agree within 10 ms, over a 20 ms operation. `[:aurora_meter, :record]` is a **span triple** in the shipped catalogue (08a), not a flat event with a duration as the build document assumed, so "one completed span with the measured duration" is asserted against `[:aurora_meter, :replay, :batch]`, which is flat, with `span.duration == 4_321` exactly. X316's lesson applied: the catalogue is the switch |
| 13 | No span attribute carries a tenant key, reference, event id, provider ref or error message body | core `OpenTelemetryTest` (three B5 tests) **and** `OpenTelemetrySdkTest` (two), on the `#span{}` record a real exporter receives | asserted **twice**, because the seam is this package's own code. The SDK version emits five identifiers including `batch_id`, refutes each, and asserts the attribute map is not empty |
| 14 | Both dependencies absent: compile and suites pass, four guarded modules undefined, `Sections` defined and tested | section 5, and the `core-no-dashboard`, `pro-no-dashboard` and `core-no-otel` legs | one gap remains: `Pro.Live.Dashboard`'s absence is not exercised, because no switch removes LiveView and Pro requires it |
| 15 | Both `docs/alerts.md` exist with the banner, the derivations and a "do not alert on this" section | `08b-alerts.md` | the arithmetic itself is not mechanically checked, and that is named there |
| 16 | Every evidence file exists with commands, exit codes, seeds and UTC timestamps, and no identifier or secret | this file, sections 8, 8c; six more beside it | |

## 8c. UTC timestamps and seeds

Every command ran through `tmp/v1/mixlane.sh`, which prints
`started=<UTC> finished=<UTC>` on its own last line, so each log carries its own
stamps. The run as a whole:

| Step | Started (UTC) | Finished (UTC) |
|---|---|---|
| first `mix check`, core | 2026-09-16T07:21:38Z | 2026-09-16T07:31:1xZ |
| handler leaks, core property sweep | 2026-09-16T07:31:22Z | 2026-09-16T07:33:03Z |
| `core-no-dashboard` leg | 2026-09-16T07:33:0xZ | 2026-09-16T07:35:0xZ |
| `pro-no-dashboard` leg | 2026-09-16T07:36:1xZ | 2026-09-16T07:38:0xZ |
| Pro `EXPLAIN` | 2026-09-16T07:39:18Z | 2026-09-16T07:39:19Z |
| 18 negative controls | 2026-09-16T07:39:2xZ | 2026-09-16T07:40:1xZ |
| final `mix check`, Pro | 2026-09-16T07:56:10Z | 2026-09-16T07:57:51Z |
| Pro fixed-seed suites | 2026-09-16T07:46:31Z | 2026-09-16T07:48:05Z |
| core property sweep, re-run | 2026-09-16T07:48:05Z | 2026-09-16T07:49:44Z |

**Seeds.** Every `mix test` in a control run used `--seed 0`. The property sweep
and the Pro fixed-seed suites used 0, 1, 7, 42 and 1337. The `mix check` runs
used ExUnit's default random seed, which is what `mix check` does and what CI
does.

**No identifier and no secret.** Every tenant key in this unit's tests is a
synthetic prefix (`leakprobe`, `mine_`, `victim_`, `explain08b`), every Stripe
object id is a literal `pi_`/`cus_`/`acct_test` fixture, no key of any kind is
printed, no network call was made and no Docker container was created or
started.

## 8d. The G08 bullets

| Bullet | Owner | This unit |
|---|---|---|
| 1. Every invariant failure and recovery state has an observable signal and a runbook entry; no package sends data externally on its own | 08a | **Contributed.** Every dashboard section carries its runbook link and a test counts them (`test every section carries its runbook link`). D11 is re-asserted with **one** narrow exemption, for the bridge, and the exemption is checked in both directions: the allow-listed file must really attach, and nothing else in `lib/` may call `attach/1` on the host's behalf |
| 2. Optional dependencies absent/present both compile; attach/detach tests leave no telemetry handler leaks | **08b** | **Met, both halves and both dependencies.** The `core-no-dashboard`, `pro-no-dashboard` and `core-no-otel` legs each compile with `--warnings-as-errors --force` and pass their full suites with the guarded modules undefined and the other optional dependencies asserted present; the ordinary build compiles and exercises all three. Handler counts are in `08b-handler-leaks.md`, and "five attaches, one span" is asserted against a real tracer provider as well as against a handler count |
| 3. Load with database outage recovers to exact totals; backlog drains faster than arrival | 08c, 11d | Not this unit's, and not claimed |
| 4. New benchmark claims traceable to scripts and artifacts | 08c | Not this unit's, and not claimed. This unit publishes no throughput number |
| 5. Dashboard and sample hide cross-tenant operational data from ordinary tenant users | **08b** (dashboard), 09c (sample) | **Met for the dashboard half**, three ways: the core page renders no tenant-identifying value at all (seeded-then-refuted, section 3 of `08b-dashboard-authorisation.md`); the Pro page refuses `:host_route` and renders nothing at all when the check refuses; and `Pro.Live.Dashboard` takes its tenant from the session only, with a resolver that **refuses** the other tenant rather than an assertion about output. The sample half is 09c's |

## 9. What this unit could not prove

Named rather than implied.

1. **The live client's own HTTP call.** Pro's provider span is at the client seam, so a bug inside `AuroraMeter.Pro.Credits.StripeClient.Live` that never reaches the seam is invisible to these spans. 04f's real-mode harness is where that lives.
2. **A browser.** Neither page was opened in one. 09c mounts both in the sample
   and is the browser demonstration of G08 bullet 5.
3. **The alert arithmetic.** `docs/alerts.md` says "2 x flush_interval is
   10,000 ms" and nothing recomputes it. A test that duplicated the
   multiplication would pass whenever the page and the test made the same
   mistake; the mitigation is that every threshold names the configuration key
   it multiplies.
4. **`phoenix_live_dashboard` 0.9.** Declared out of range rather than tested,
   which is the honest form. `opentelemetry_api` is declared `~> 1.2` and
   resolves 1.5.0; the 1.x API surface this package uses is seven functions and
   they are listed in section 6b so an upgrade can be checked mechanically,
   which is a weaker guard than a tested range and is stated as one.
5. **The `handle_event/3` callback.** Not implemented, because the pages are
   read-only. A later unit adding a control has to implement it, and the "no
   button, no form, no `phx-click`" tests are what will tell it so.
