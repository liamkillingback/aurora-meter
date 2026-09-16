# 09c: the G09 browser matrix

> **G09**: "Browser tests cover authentication, organization isolation,
> double-click actions, quota denial, holds/settlement and live updates.
> Automated provider tests use fakes."

Every row names the test and the assertion that carries it. All of them are
`Phoenix.LiveViewTest` against the sample's real router, real hooks and real
domain code. No provider exists in the core profile; every export assertion goes
through `AuroraMeter.Exporter.Journal`, the deterministic reference exporter.

## 1. Authentication

| Test | The assertion that proves it |
|---|---|
| `generate_live_test.exs` "an unauthenticated visitor to /generate is sent to the log in page" | `{:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/generate")` |
| `generate_live_test.exs` "an unauthenticated visitor to /ops is sent to the log in page" | the same for `/ops` |
| `generate_live_test.exs` "a signed-in member is refused the operational pages" | a signed-in user whose role is `member` is redirected to `/generate` from both `/ops` and `/dev/tools` |
| `generate_live_test.exs` "a signed-in owner is not" | the discrimination: the same routes mount for an owner. Without it the two rows above would pass against routes that are broken for everyone |
| `api/generation_controller_test.exs` "no bearer token is 401 and nothing is metered" | `json_response(conn, 401)` **and** `Repo.aggregate(Generation, :count) == 0` |

The host's hook runs first in every `live_session`, and `AuroraMeter.LiveView`
runs after it and only subscribes. That ordering is asserted structurally by the
isolation tests below and stated in a comment in the router.

## 2. Organization isolation

Proved three ways in `isolation_test.exs`, because one way is not enough and
because finding X352 asks for a specific shape: make the forbidden tenant
unresolvable, so that "never read" is a property of the run rather than of a
rendered string that could coincide.

| Layer | Test | The assertion |
|---|---|---|
| structural | "no module in lib/ reads an organisation or a tenant out of request parameters" | walks the **parsed AST** of every file under `lib/`, looking for `Access.get` with a key in `org, org_id, tenant, tenant_key, organisation, organization` |
| structural, control | "the scan can fail" | the same scan over a planted module containing `Orgs.get_org!(params["org_id"])` returns a finding |
| structural, control | "the scan does not fire on prose about the defect" | a module whose `@moduledoc` warns against `params["tenant"]` returns nothing. The first version of this scan read lines and reported `tenancy.ex`'s own documentation; walking the AST is why it no longer can |
| structural, floor | "the scan sees every source file" | more than 15 files scanned, so a wildcard that matched nothing cannot pass the three above |
| behavioural | "another organisation's generation is not reachable by id" | `assert_raise Ecto.NoResultsError` on `/history/<their id>` from my session |
| behavioural, control | "the same id IS reachable from its own organisation's session" | the same id renders their prompt for them |
| behavioural | "the domain funnel refuses it too, not just the page" | `Generations.get(mine, their_id) == nil`, `Generations.get(theirs, their_id) != nil` |
| behavioural | "the history list never carries another organisation's prompt" | `refute html =~ "their private prompt"` |
| **over the run** | "serving one organisation resolves that organisation's key and no other" | a telemetry probe on `[:aurora_meter_example_ai, :tenant, :resolved]` records **every** key resolved while `/generate`, a submit, `/ops` and `/history` are served, and asserts `Enum.uniq(keys) == [mine_key]` |
| over the run, control | "the probe can see a forbidden key when one really is resolved" | resolving the other organisation's key deliberately puts it in the probe's list |
| over the run, floor | same test | `assert keys != []` before the negative, so a probe that recorded nothing cannot pass |
| route shape | "there is no organisation switcher and no organisation parameter on any route" | every entry of `Router.__routes__()` is checked for `:org` or `:tenant` in its path |
| route shape | "a tenant parameter in the query string changes nothing" | `/ops?tenant=<theirs>&org_id=<theirs>` renders the same **visible text** as `/ops`, and does not contain their key |

The probe exists because a rendered page cannot prove a negative: the other
organisation's figure might happen to be zero, or happen to match. A run in which
their tenant key was never resolved cannot have read their data.

`AuroraMeterExampleAi.Tenancy.org!/1` has one clause and it matches a scope
carrying an organisation. Handing it request parameters, a string id or `nil`
raises `FunctionClauseError`, so the property is enforced by the shape of the
function rather than by everyone remembering.

## 3. Double-click actions

| Test | The assertion |
|---|---|
| `generate_live_test.exs` "a double-click submit of one form produces one generation, one event and one hold" | two `render_submit/2` calls with the same `request_id`; then `Repo.aggregate(Generation, :count) == 1`, one `sample_outbox_items` row, and exactly one `:hold` in the credit ledger for that reference. The second render carries "had already been run" |
| `generations_test.exs` "twelve concurrent submits of one request id on independent connections produce one of everything" | twelve `Task.async_stream` submits of one id; every result is `{:ok, generation, outcome}` naming the same id, one `generations` row, one hold, one settle, one outbox row |
| `api/generation_controller_test.exs` "the same request_id twice is one generation and one charge" | over HTTP, on two connections: 201 then 200, one row, and `available` unchanged after the second |

Which of the twelve returns `:created` is a race and is deliberately not
asserted: the winner of the credit hold does the work, and a caller recovering
from the outbox row can reach the `generations` insert before it does. What is
asserted is that there is one of everything and that no caller was told
something false.

## 4. Quota denial

| Test | The assertion |
|---|---|
| `generate_live_test.exs` "a free organisation's sixth image is denied, and the denial names the limit and the period end" | five submits through the form, `AuroraMeter.usage(org, :images) == 5`, then the sixth renders "allows 5 images this period" and "The period ends", and usage is **still 5** |
| `generate_live_test.exs` "an organisation with no credit is refused before any work runs" | "Not enough credit" and `Repo.aggregate(Generation, :count) == 0` |
| `generations_test.exs` "a refusal for want of credit does NOT consume an image slot" | the one that catches the mistake `with_quota/4` invites. `usage(org, :images) == 0` after a refusal inside the quota callback |
| `api/generation_controller_test.exs` "the plug says yes and with_quota says no at the boundary" | five 201s, then 402 with `{"error": "limit_exceeded", "advisory": true}`, and usage still 5 |

## 5. Holds and settlement

| Test | The assertion |
|---|---|
| `generations_test.exs` "a settled generation reduces available by the ACTUAL cost, not the estimate" | `after.available == before.available - actual`, `held == 0`, and `estimate > actual` asserted explicitly so the test cannot pass when the two coincide |
| `generations_test.exs` "the ledger shows one hold and one settlement, not two debits" | the kinds for that reference are exactly `[:hold, :settle]` and the settle amount is `-cost_micros` |
| `generations_test.exs` "a generation whose work raises leaves the balance and the quota exactly as they were" | available unchanged, held zero, images unchanged, no settled row |
| `generate_live_test.exs` "a submit settles, and the page shows the estimate and the actual" | through the form, in the browser layer |
| `ops_live_test.exs` "I10 granted minus spent minus held equals available after a scripted sequence" | ten settled generations, one refused, one open hold; the ledger's summed `amount` and `held_delta` equal the summary's `balance` and `held`, and `balance - held == available` |

## 6. Live updates

| Test | The assertion |
|---|---|
| `generate_live_test.exs` "a generation in one session moves the meter and the balance in a second session for the same organisation" | two live sockets for one user; a submit in one, `AuroraMeter.Test.broadcast!()`, then the watcher's html differs **and** its image meter reads `1 / 200` |
| `generate_live_test.exs` "a generation in one organisation changes nothing in another organisation's session" | the watcher's html is byte-identical after another organisation's generation, and then **does** change after its own, so "nothing changed" is not "nothing ever changes here" |
| `usage_meter_change_tracking_test.exs` (two tests) | why the meter needs a changing attribute at all: see `09c-library-findings.md` finding 4 |
| the browser | a second tab, never touched, moved from `images 3 / 200` to `4 / 200` and `tokens 561` to `592` after a submit in the first |

The broadcast is driven with `AuroraMeter.Test.broadcast!()` rather than waited
for. A test that sleeps until a timer fires is a test that fails on a slow
machine.

## 7. Provider fakes

The core profile has no provider. `AuroraMeter.Exporter.Journal` is the
deterministic reference implementation and every export assertion uses it:
`sample_outbox_test.exs` scripts each of the five documented outcomes plus a
term nobody planned for, and asserts the resulting row state. No HTTP client is
configured and `test/aurora_meter_example_ai/profile_test.exs` asserts that no
source in the sample makes a network call, with a control proving the grep can
match.
