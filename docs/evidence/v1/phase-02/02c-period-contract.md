# 02c: the period contract

This file is the one build unit `03a` is meant to be able to implement the
legacy backfill's period resolution from, without reading anything else.
Nothing here depends on which primitive `Clock.now/0` reads.

Source: `lib/aurora_meter/period.ex`. Guide: `docs/periods.md`. Tests:
`test/aurora_meter/period_test.exs` (24 passing: 3 doctests and 21 tests) and
`test/support/period_sources.ex`.

## The interval

```elixir
@type t :: %{start: DateTime.t(), end: DateTime.t(), source: atom()}
```

A **half-open UTC interval** `[start, end)`. `start` belongs to the period,
`end` does not. The `end` of period N is the `start` of period N+1, so no
instant belongs to two periods and no instant belongs to none.

Two consequences that are load bearing elsewhere:

- The counter identity is `{tenant_key, feature, period_start}`. Two adjacent
  periods sharing a `start` would merge two periods' usage into one row and one
  invoice.
- `AuroraMeter.Schema.Counter.period_start` is `utc_datetime`, second precision.
  A custom source must therefore not produce two periods whose starts differ
  only in sub-second precision. `current!/2` does **not** enforce this: a single
  call sees one period and cannot compare two. `docs/periods.md` states it.

## The four validation rules

`Period.current!/2` resolves through the configured source and then checks,
**on every call**:

1. the result is a map carrying `:start`, `:end` and `:source`. Extra keys are
   allowed and ignored; a missing key is an error.
2. `start` and `end` are `DateTime` structs with `time_zone == "Etc/UTC"`.
3. `DateTime.compare(start, end) == :lt`.
4. `DateTime.compare(start, now) != :gt` and `DateTime.compare(now, end) == :lt`.

`Period.current/2` performs none of these and returns the source's map
unchanged. It is kept for hosts that call it directly (`aurora_api`'s
`plugs/api_meter.ex` does). Every core call site uses `current!/2`:
`aurora_meter.ex` `track/4`, `usage/2`, `usage_all/1` and `period/1`;
`entitlements.ex` `quota/2` and `period_start/1` (which serves `check/2`,
`remaining/2`, `reserve/2,3` and `with_quota/3,4`); `credits.ex:558`;
`test.ex`'s `keyed/2`.

## The six reasons, and the exact message each produces

`AuroraMeter.Period.InvalidPeriodError` carries `source`, `tenant_key`,
`period`, `instant` and `reason`. The message names the source module **first**,
because the source is what the operator has to fix, then explains, then restates
the contract, then dumps the five fields.

| `reason` | Raised when | The `explain` clause in the message |
|---|---|---|
| `:not_a_map` | the source returned something that is not a map | `did not return a map` |
| `:missing_key` | a map without all of `:start`, `:end`, `:source` | `returned a map without all of :start, :end and :source` |
| `:not_datetime` | `:start` or `:end` is not a `DateTime` struct | `returned a period whose :start or :end is not a DateTime` |
| `:not_utc` | `:start` or `:end` carries a zone other than `Etc/UTC` | `returned a period whose :start or :end is not in Etc/UTC` |
| `:inverted` | `end <= start` (both `==` and `<` produce this) | `returned a period whose :end is not after its :start` |
| `:not_containing` | the interval does not contain the instant | `returned a period that does not contain the instant asked about` |

Full shape, with a real example from the suite:

```
AuroraMeter.Test.PeriodSources.NonUtc returned a period whose :start or :end is not in
Etc/UTC. An AuroraMeter period is a half-open UTC interval [start, end): start belongs
to the period, end does not, and the interval must contain the instant it is resolved
for. reason=:not_utc tenant_key="org_period_contract"
instant=~U[2026-01-31 23:59:59.999999Z] period=%{end: ..., source: :calendar, start: ...}
```

One broken source per reason lives in `test/support/period_sources.ex`
(`NotAMap`, `MissingKey`, `NaiveStart`, `NonUtc`, `ZeroLength`, `Inverted`,
`FutureWindow`), and each has its own test asserting its own reason and that the
message names it.

Note for anyone writing a similar fixture: the three that break the callback's
**type** rather than its value (`NotAMap`, `MissingKey`, `NaiveStart`) must not
declare `@behaviour AuroraMeter.Period`, because Dialyzer proves the mismatch
and `mix check` fails on it. A module needs no behaviour attribute to be
configured as `period_source`, which is the hole runtime validation exists to
close.

## `containing/2`: the contract 03a and 03b build on

```elixir
@callback containing(tenant :: term(), instant :: DateTime.t()) :: t()
@optional_callbacks containing: 2

@spec containing(term(), DateTime.t()) :: t()
def containing(tenant, %DateTime{} = instant)
```

The dispatcher calls `source.containing/2` when the source exports it (checked
with `Code.ensure_loaded?/1` then `function_exported?/3`) and
`source.current(tenant, instant)` otherwise, then applies the same four rules
with `instant` in place of "now".

`AuroraMeter.Period.Calendar` deliberately has **no** `containing/2`: it is a
pure function of the instant it is given, so the fallback is already correct,
and leaving it out means the fallback path is exercised by the default
configuration rather than only by a fixture.

**The raise is the contract.** When the source cannot place the instant,
`containing/2` raises `InvalidPeriodError` with `reason: :not_containing`.
It does not return `nil`, it does not guess, and it does not fall back to a
calendar month of its own accord. A caller that must degrade rather than fail
rescues it:

```elixir
period =
  try do
    AuroraMeter.Period.containing(tenant, occurred_at)
  rescue
    AuroraMeter.Period.InvalidPeriodError -> nil    # record attribution = 'unresolved'
  end
```

That convention is written on `containing/2`'s own `@doc`, so `03a` and `03b`
are not inventing it. The public surface stays exactly what `api-change-map.md`
1.2 lists: `current!/2`, `containing/2`, the optional callback and the error. A
tuple-returning sibling would read better at those two call sites and was
deliberately not added for one internal caller.

`AuroraMeter.Period` is now the first behaviour in either package with an
optional callback (`investigation/08-api-inventory.md` recorded zero); `02a`'s
inventory should absorb that.

## The boot check

`Config.validate!/0` gains, after NimbleOptions has validated the types:

```elixir
ensure_exports!(:period_source, opts[:period_source], current: 2)
ensure_exports!(:clock, opts[:clock], now: 0, today: 0, monotonic_ms: 0, db_now: 0)
```

`Code.ensure_loaded?/1` then `function_exported?/3` per callback, raising
`ArgumentError` naming the configuration key, the module, the missing callback
and the behaviour it should implement. `containing/2` is optional and is never
required. There is no probe call with a synthetic tenant, because a custom
source may legitimately raise for a tenant it does not know.

**Deviation, flagged for the orchestrator:** the build document's section 5 and
its acceptance criterion both say to check `clock` for `now/0` and `today/0`.
The check above requires all **four** callbacks the behaviour declares. The
third and fourth were added by later corrections and that sentence was not
updated with them; a clock missing `monotonic_ms/0` crashes
`Subscriptions.get/1`, which is on a read path, and one missing `db_now/0`
crashes the auto top-up worker mid-charge. Failing at boot is strictly better in
both cases. Say the word and it drops to two.

Build unit `02b` generalises `ensure_exports!/3` into `Config.Schema`'s
module-behaviour checker for every module-typed key. It is written inline here,
in the shape 02b generalises, exactly as the plan's section 5 says.
