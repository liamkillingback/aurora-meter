# 09b: C9, the LiveView requirement, and what the components actually render

Build unit 09b. Finding **C9**, decision **D12** ("never leave a false support
claim"). Captured 2026-09-16 (UTC).

## The decision

Both packages change

    {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true}

to

    {:phoenix_live_view, "~> 1.0", optional: true}

and the `liveview-0.20` CI leg goes with the clause it was there to test.

## Why, with the measurement that decided it

The build document offered two routes and set an exact bar for the second: keep
`~> 0.20` **only** if a single template body renders correctly under both 0.20
and 1.0, proved by a render on each version and not by a successful compile.

The route was chosen by measuring the size of the rewrite that bar would
require, rather than by assuming it. `tmp/v1/09b_curly_scan.py` walks every `~H`
sigil in both packages and reports `{...}` interpolations in **text position**
only. An attribute interpolation (`attr={expr}`) and an attribute spread
(`<div {@rest}>`) are valid in 0.20; a brace in an element body is not, and is
rendered there as the literal characters.

| File | Body interpolations |
|---|---|
| core `lib/aurora_meter/components.ex` | 17 |
| core `lib/aurora_meter/live_dashboard/view.ex` | 22 |
| Pro `lib/aurora_meter/pro/components.ex` | 81 |
| Pro `lib/aurora_meter/pro/live_dashboard/view.ex` | 52 |
| **total** | **172** |

Two things follow, and both were decisive.

**The build document underestimated C9's extent.** It names `components.ex` in
each package and treats the rewrite as a two-file job. The dashboards that 08b
shipped are written in the same syntax, so it is a four-file job, and two of
those files belong to a unit that has already been reviewed. A package compiles
as a whole: honouring a 0.20 floor in `components.ex` alone would leave a host
with both LiveView 0.20 and `phoenix_live_dashboard` rendering `{@data.pending}`
on its operator's screen, which is the same false claim in a different file.

**The formatter migrates the syntax back.** `Phoenix.LiveView.HTMLFormatter`
takes `migrate_eex_to_curly_interpolation: true` by default
(`deps/phoenix_live_view/lib/phoenix_live_view/html_algebra.ex:26`), and
`mix check` runs `format --check-formatted`. Keeping 172 `<%= %>` interpolations
would mean turning that option off in both packages and holding four template
files against the syntax the framework has moved to, for the life of the 0.20
floor.

D12's own test is whether a floor can be supported "without unsafe pinning".
This one can only be supported by freezing four template files, two of them
another unit's, against the framework's direction. So the claim is narrowed
rather than made true, which is exactly what D12 prescribes where a floor is
impossible: an explicit V1 breaking requirement with a documented upgrade route.

## What 0.20 actually did, kept rather than re-run

01f ran the leg and captured the failure
(`docs/evidence/v1/phase-01/ci.md` section 8.4): `phoenix_live_view 0.20.17`
resolved, `mix compile --warnings-as-errors` exited 1, and the two warnings were
`runway_text/1 is unused` and `burn_text/1 is unused`. That is the mechanical
shadow of C9: the interpolations that would have called those helpers are
literal text on 0.20, so the helpers are dead, and the compiler can see it.

01f wrote: "Widening the syntax must be checked against the rendered output, not
against the compiler falling silent." That instruction is what the render table
below answers, on the version this unit does claim.

This unit re-ran the 0.20 leg once, before deciding, and reproduced 01f's
failure exactly (`tmp/v1/09b/lv-core-0.20/`). It was not re-run after the
decision: `AURORA_LIVEVIEW=0.20` now raises from `mix.exs`, because a switch
that resolves a version the package does not claim is a leg that tests nothing.

## The upgrade route, for a host on LiveView 0.20

Two doors, and the second costs almost nothing:

1. Upgrade LiveView to 1.0. Phoenix's own migration guide covers it, and
   Aurora Meter needs nothing from the host in the process.
2. Remove the optional `phoenix_live_view` dependency and use Aurora Meter
   headless. Everything except `AuroraMeter.Components`,
   `AuroraMeter.Pro.Components` and the two LiveDashboard pages works without
   LiveView at all, including `AuroraMeter.LiveView.subscribe/1`, which is
   deliberately outside the guard. The `headless` leg proves it by running 1888
   tests on a build with no LiveView present.

A host on 0.20 that keeps the dependency hits a Hex resolution conflict before
anything is installed, which is a legible failure at the right moment. That is
strictly better than the previous behaviour, which was to install cleanly and
render `{@label}` to the host's own customers.

## The rendered output, on the version now claimed

Captured by `tmp/v1/09b_render.exs` through `mix run`, never from inside
`mix test` (a nested `mix` reaches into the same `_build` a running suite is
loading out of: `open-findings.md` X344). Files in `tmp/v1/09b/renders/`.

    resolved phoenix_live_view: 1.2.11
    resolved phoenix_html:      4.3.0
    declared requirement:       {:phoenix_live_view, "~> 1.0", [optional: true]}
    captured at:                2026-09-16T16:03:56.126897Z

| Component | Bytes | Contains `{` | Contains an em dash | Contains an en dash |
|---|---|---|---|---|
| `usage_meter/1` | 354 | false | false | false |
| `usage_summary/1` | 724 | false | false | false |
| `spend_chart/1` | 1576 | false | false | false |
| `spend_chart/1` (empty series) | 275 | false | false | false |
| `credit_summary/1` | 1502 | false | false | false |
| `credit_summary/1` (no burn) | 1092 | false | false | false |

`usage_meter/1`, verbatim:

```html
<div class="aurora-meter aurora-meter--hard">
  <span class="aurora-meter__label">ai_generations</span>
  <div class="aurora-meter__bar" role="progressbar" aria-label="ai_generations" aria-valuenow="37" aria-valuemax="50">
    <div class="aurora-meter__fill" style="width: 74%"></div>
  </div>
  <span class="aurora-meter__value">37 / 50</span>
</div>
```

`credit_summary/1` with no burn and no runway, verbatim, which is also the
X271 fix below:

```html
<dl class="aurora-credit-summary">
  <div class="aurora-credit-summary__item aurora-credit-summary__item--available">
    <dt class="aurora-credit-summary__label">Available</dt>
    <dd class="aurora-credit-summary__value">$12.00</dd>
  </div>
  <div class="aurora-credit-summary__item aurora-credit-summary__item--spent">
    <dt class="aurora-credit-summary__label">Spent this period</dt>
    <dd class="aurora-credit-summary__value">$4.25</dd>
  </div>
  <div class="aurora-credit-summary__item aurora-credit-summary__item--granted">
    <dt class="aurora-credit-summary__label">Added this period</dt>
    <dd class="aurora-credit-summary__value">$20.00</dd>
  </div>
  <div class="aurora-credit-summary__item aurora-credit-summary__item--burn">
    <dt class="aurora-credit-summary__label">Daily burn</dt>
    <dd class="aurora-credit-summary__value">not yet</dd>
  </div>
  <div class="aurora-credit-summary__item aurora-credit-summary__item--runway">
    <dt class="aurora-credit-summary__label">Runway</dt>
    <dd class="aurora-credit-summary__value">not yet</dd>
  </div>
</dl>
```

The zero rows are gone because `:if` evaluated, the money is formatted because
`Money.format/2` ran, and "not yet" is text because the interpolation
interpolated. A 0.20 host would have had `{Money.format(@summary.available)}` in
place of `$12.00`.

## The regression that keeps the claim true

`test/aurora_meter/components_test.exs` (eleven tests) and Pro's
`test/aurora_meter/pro/components_test.exs` (nine). Every test renders through
`Phoenix.LiveViewTest.render_component/2` and asserts twice over: positively,
that the interpolated value is in the HTML, so a component that rendered nothing
cannot pass; and negatively, that the output carries no `{` at all. None of these
components has any reason to emit a brace, so the absence of one is a statement
about the shape of the whole output rather than a search for one substring
(X325, X350). Pro's dashboard renders a stylesheet, which is the one place a
brace is legitimate, so the `<style>` block is removed before the check and the
removal is itself asserted, in both directions.

**The detectors were watched failing.** Each file carries two controls that
render exactly what the defect produces and assert that the detector refuses it:
a component whose body is the literal text `{@label}` (or `{@title}`), and one
that renders an em dash. Both are produced as strings, because under the
requirement now declared there is no LiveView left that would render a curly
body interpolation literally, and a control that cannot be built is not a
control.

Both packages also assert the requirement itself: `mix.exs` declares `~> 1.0`,
the resolved version satisfies it, `0.20.17` does not, and the dependency is
still `optional: true`.

## The second defect in the same file (X271)

Core's components rendered an em dash and an en dash into a host's page.
`burn_text(nil)` and `runway_text(nil)` returned `"—"` for "no honest
number to show", and `range_text/1` joined two dates with `"–"`, which also
reached the chart's `aria-label`. Pro had exactly this and closed it at four to
zero; core's three were still there.

Fixed the way Pro fixed it: "not yet" for the null cases, "to" for the range.
`AuroraMeter.RealtimeTest` had one assertion that read the character and now
reads the words. The rule is enforced on rendered output in both packages, in the
same helper as the brace check, because the source is where it was already fixed
once (X153).

## Consequences other units must carry

- **10a**: the release notes and `docs/supported-versions.md` say
  `phoenix_live_view ~> 1.0` **when LiveView is present**, and carry the
  two-door upgrade route above. `AuroraMeter.Install.Support.declared_deps/0`
  is the machine-readable source, and `install_test.exs` compares it against
  `mix.exs`, so the prose and the code cannot disagree.
- **10b**: the storefront's runtime-floor copy has to match. The storefront
  itself is on LiveView 0.19 and never installs the components, so nothing about
  the storefront changes (`09b-storefront-separation.md`).
- **01f**: the `liveview-0.20` leg is removed from both workflow files, with the
  reason in a comment beside the leg that remains. 01f's capture of the failure
  stays where it is.
