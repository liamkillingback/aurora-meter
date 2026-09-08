# Aurora Meter — go-to-market drafts (NOT published)

Hand-off drafts for the owner to review, edit, and publish. Nothing here is live.

## One-liner

**Laravel Cashier + OpenMeter for Phoenix** — subscriptions, real-time usage
metering, and plan-gating as a few function calls, on the BEAM.

## Landing section (aurorameter.com; a shorter version links out from phxtemplates.com)

> ### Aurora Meter — the metering layer Phoenix was missing
> Every SaaS meters usage, gates features by plan, and bills for overage. On
> Phoenix you hand-roll all of it. Aurora Meter is a free, MIT library that does
> the three jobs — **count, gate, bill** — with an ETS hot path that sustains
> ~5.5M increments/sec and never touches your database on the write path.
>
> ```elixir
> AuroraMeter.track(org, :ai_generations)
> AuroraMeter.with_quota(org, :ai_generations, fn -> generate() end)
> ```
>
> Free core on Hex. **Aurora Meter Pro** adds Stripe checkout + webhook sync,
> metered usage reporting, hosted dashboards, and quota alerts.
>
> [Get the free core →]  [Aurora Meter Pro →]

## ElixirForum "Your Libraries / Projects" post (draft)

> **Aurora Meter — real-time usage metering + plan entitlements + Stripe billing for Phoenix**
>
> I kept re-building the same subscription/metering/plan-gating layer in every
> Phoenix SaaS, and there was no library for it (OpenMeter ships SDKs for
> Node/Python/Go but not Elixir). So I extracted Aurora Meter.
>
> - **Meter**: ETS-backed counters, ~5.5M incr/sec, nothing on the DB hot path.
> - **Entitle**: `check/2` and an atomic `with_quota/4` (correct hard limits under
>   concurrency).
> - **Plans**: a small compile-time DSL.
> - Free + MIT. A commercial Pro tier adds Stripe + dashboards.
>
> Docs: <hexdocs link> · Source: github.com/liamkillingback/aurora-meter
> Feedback very welcome.

## README badge

```markdown
[![Hex.pm](https://img.shields.io/hexpm/v/aurora_meter.svg)](https://hex.pm/packages/aurora_meter)
```

## Distribution notes (the shadcn/Oban playbook)

- Free core is the top-of-funnel, like Aurora UI. Optimize the README for
  copy-paste and AI-legibility.
- Lead with the ETS throughput number and the `with_quota` concurrency guarantee —
  they are the differentiators.
- Target the **newer** catalog products (Aurora Commerce, Data Agent — LiveView
  1.x) for the first real integration; the LV-0.19 SaaS Starter needs a LiveView
  bump before the components work.
