# 0006 — `counter`: a feature kind for "measured, never billed"

- Status: Accepted
- Date: 2026-09-11

## Context

A product that bills from the prepaid credit ledger (ADR 0005) still wants the
request count on its dashboard. Until 0.5 the only way to say "count this and
never block it" was:

```elixir
metered :requests, included: 0, unit_price: 0
```

That expression is a lie in three places, and every one of them surfaces in
the UI:

1. **`quota/2` reports `included: 0` and `overage: used`.** Every single
   request is overage, so a dashboard renders `6 / 0` and "6 over the included
   allowance".
2. **`percent/2` divides by the included allowance.** With `included: 0` the
   guard clause returns `0`, so a bar renders at 0% forever — a bar that is
   both meaningless and *wrong*, since there is no denominator to be 0% of.
3. **`unit_price: 0` says "billed at zero", not "not billed".** Pro's
   dashboard reads a metered feature as a subscription-overage line and adds
   "billed at period end". For a prepaid product nothing is billed at period
   end; the money already left the ledger when the request ran.

The cost of leaving it alone is that every host has to special-case
`included == 0` in its own renderer, and the special case is invisible — it
looks like a working configuration until a customer reads the dashboard.

## Options considered

1. **Keep `metered(included: 0, unit_price: 0)` and fix the renderers.** The
   plan declaration still says "metered"; every current and future renderer
   (core components, Pro dashboard, each host's own UI) has to independently
   rediscover the `included == 0` convention. A convention that must be
   re-derived at every call site is not a convention.
2. **`limit :requests, :infinity, :hard`.** Reuses a kind, but an infinite hard
   cap is a cap that never fires, and `remaining/2` would have to invent
   `:infinity - used`. The `:hard` machinery (the compare-and-roll-back in
   `Counter.reserve/5`) would run on every request for nothing.
3. **A `:soft` limit mode.** A third mode on `limit/3` implies a number, and a
   counter has none.
4. **`metered` with `unit_price: nil` meaning "not billed".** Cheaper to add,
   but keeps the `included` denominator and so keeps the `6 / 0` bar. It also
   makes `nil` and `0` mean different things on the same field.
5. **A new `counter/1` kind.** One more arm in the DSL, the feature-config
   type, `check/2`, `quota/2` and the renderers.

## Decision

(5) A new feature kind, `counter(:feature)` → `{:counter}`.

- `check/2` is `:ok`, `entitled?/2` is `true`, `remaining/2` is `:unlimited`,
  and `reserve/3` admits unconditionally while still incrementing the counter —
  a counter that stopped counting under load would be worse than useless.
- `quota/2` returns `kind: :counter` with **`limit: nil`, `included: nil` and
  `percent: nil`**, and `overage: 0`.

`percent: nil` is the load-bearing part of this ADR. `0` would be a number a
renderer can draw, and it would draw a bar that says "you have used 0% of your
allowance" to a customer who has no allowance. `nil` is not drawable, so a
renderer has to decide what to do, and the only correct decision — no bar — is
also the easy one. The same argument applies to `limit` and `included`: `nil`
cannot be formatted into `"6 / 0"` by accident.

Every clause in this package that matches on a feature config or a quota `kind`
has an explicit counter arm, including `AuroraMeter.Components.usage_meter/1`,
which renders the bare count and no `role="progressbar"` element at all. A
missing clause here is a `FunctionClauseError` in a host's dashboard, which is
why the arms are explicit rather than relying on a catch-all.

## Consequences

- Hosts that were expressing a counter as `metered(included: 0, unit_price: 0)`
  should switch. Nothing breaks if they do not — the metered semantics are
  unchanged for products that genuinely bill overage — but they keep the
  misleading wording.
- `quota/2`'s `percent` was already `integer() | nil` (`nil` for boolean and
  integer features and undeclared ones), so callers that already handled `nil`
  need no change. A caller that assumed `percent` was non-nil whenever `used`
  was meaningful now has one more case, and that case was always latent.
- A counter is not a billing primitive. It deliberately carries no price, and
  Pro will not report it to Stripe. Money for a counted resource lives in the
  credit ledger, and the money series (`AuroraMeter.Credits.spend_history/2`)
  is what a credit-billed dashboard should chart.
- Adding a kind is a one-way door for the `feature_config` type: every future
  consumer must handle `{:counter}`. That is the point — the type is where the
  compiler can tell a host it has missed a case.
