# 02c: the boundary cases, with the instants used and the rows they produced

Core; Pro's period branches are in
`aurora_meter_pro/docs/evidence/v1/phase-02/02c-pro-period.md`. Every case below
ran green in `mix check` at 2026-09-14T12:54:01Z
(`tmp/v1/02c/logs/core-check.txt`) and again at seed 7
(`tmp/v1/02c/logs/core-seed7.txt`).

The clock is frozen with `AuroraMeter.Test.with_clock/2` and moved with
`travel/1` and `travel/2`, so none of these wait on real time and none of them
depend on when the suite happens to run.

## P01: the calendar period is half-open

`test/aurora_meter/period_test.exs`, `describe "P01: the interval is half-open [start, end)"`.

| Frozen instant | `Period.current!/2` returns | Assertion |
|---|---|---|
| `2026-01-31T23:59:59.999999Z` | `start 2026-01-01T00:00:00Z`, `end 2026-02-01T00:00:00Z`, `source :calendar` | the last representable microsecond of January is still January |
| `travel(1, :microsecond)` to `2026-02-01T00:00:00.000000Z` | `start 2026-02-01T00:00:00Z` | the boundary instant belongs to the **next** period |
| both | | `january.end == february.start` exactly |
| `2026-02-28T23:59:59.999999Z` | `start 2026-02-01T00:00:00Z`, `end 2026-03-01T00:00:00Z` | one microsecond before `end` is in the current period, and `now < end` |

## P01: leap day

| Frozen instant | Result |
|---|---|
| `2028-02-29T12:00:00Z` | `start 2028-02-01T00:00:00Z`, `end 2028-03-01T00:00:00Z` |
| `travel(~U[2028-03-01 00:00:00Z])` | `start 2028-03-01T00:00:00Z` |

## P01 and P03: `track/4` at the boundary, and the day bucket beside it

`test/aurora_meter/metering_test.exs`, `describe "the period boundary"`.

| Step | Clock | Call | Counter row | Day bucket |
|---|---|---|---|---|
| 1 | `2026-01-31T23:59:59.999999Z` | `track(tenant, :ops, 2)` | `{tenant, :ops, 2026-01-01T00:00:00Z} = 2` | `2026-01-31 = 2` |
| 2 | `2026-02-01T00:00:00Z` (travelled) | `track(tenant, :ops, 5)` | `{tenant, :ops, 2026-02-01T00:00:00Z} = 5` | `2026-02-01 = 5` |

January's counter stays at 2 and February's is 5: the boundary instant counted
into the new period, not the old one. The day bucket moved with the period, from
the **same** clock read, which is invariant P03. Before this unit,
`counter.ex:63` took its date from a second, independent `Date.utc_today()`.

## P04: work that crosses a period boundary

`test/aurora_meter/entitlements_test.exs`, `describe "P04 work that crosses a period boundary"`.
Tenant on the `:pro` plan, `with_quota(tenant, :ai_generations, 3, fun)`.

| Case | Admitted at | Callback finishes at | Counter `2026-01-01T00:00:00Z` | Counter `2026-02-01T00:00:00Z` | Day `2026-01-31` | Day `2026-02-01` |
|---|---|---|---|---|---|---|
| returns normally | `2026-01-31T23:59:59Z` | `2026-02-01T00:00:01Z` | **3** | 0 | **3** | 0 |
| raises | `2026-01-31T23:59:59Z` | `2026-02-01T00:00:01Z` | 0 | 0 | 0 | 0 |

Inside the first callback, after travelling, the test also asserts
`Period.current!(tenant).start == 2026-02-01T00:00:00Z`, so the clock really had
moved on while the reservation stayed in January. That is P04: work admitted in
period P is committed to period P and to the UTC day of admission, however long
it takes to finish.

The raising case is the release half: three were reserved in January and three
came back out of January. Nothing is left counted in either period and no day
bucket moved, because a deferred reservation never touches one until it commits.

`with_quota/4`'s capture-once behaviour was already correct before this unit
(`entitlements.ex:272-278` records why it was written that way). What changed is
only where its two values come from: `Period.current!/2` and `Clock.today()`.
What is new is that the crossing can now be **tested** rather than reasoned
about. The pre-existing test that expressed the same claim by passing the period
and the day in by hand is still there, still passing, and its "partial until
02c" comment now has its companion.

## Custom sources at a boundary

| Source | Frozen instant | Period |
|---|---|---|
| `PeriodSources.Weekly` | `2026-02-01T12:00:00Z` (a Sunday) | `2026-01-26T00:00:00Z` to `2026-02-02T00:00:00Z`, `source :weekly` |
| `MyApp.DailyPeriod` (the `docs/periods.md` recipe, verbatim) | `2026-02-10T09:30:00Z` | `2026-02-10T00:00:00Z` to `2026-02-11T00:00:00Z`, `source :daily` |
| `MyApp.WeeklyPeriod` (the recipe, verbatim) | `2026-02-10T09:30:00Z` (a Tuesday) | `2026-02-09T00:00:00Z` to `2026-02-16T00:00:00Z`, `source :weekly` |

The weekly case is chosen deliberately: 2026-02-01 is a Sunday inside the week
that began Monday 2026-01-26, and it is also the instant a calendar source calls
a new period. A source that quietly deferred to the calendar month would answer
`2026-02-01` and fail.

`containing/2` one period back, same sources:

| Source | Instant | Period returned |
|---|---|---|
| `MyApp.DailyPeriod` | `2026-02-09T23:59:59Z` | starts `2026-02-09T00:00:00Z` |
| `MyApp.WeeklyPeriod` | `2026-02-08T23:59:59Z` | starts `2026-02-02T00:00:00Z` |
| `PeriodSources.WeeklyWithContaining` (exports the callback) | `2025-12-10T09:00:00Z` | `2025-12-08` to `2025-12-15`, `source :weekly_containing` |
| `PeriodSources.Weekly` (no callback, falls back to `current/2`) | `2025-12-10T09:00:00Z` | `2025-12-08` to `2025-12-15`, `source :weekly` |
| `AuroraMeter.Period.Calendar` (the default) | `2025-06-10T09:00:00Z` | `2025-06-01` to `2025-07-01`, `source :calendar` |
| `PeriodSources.IgnoresInstant` | `2025-06-10T09:00:00Z` | raises `InvalidPeriodError`, `reason: :not_containing`, message names the source |

The two `:weekly` rows are the same window from two different code paths, which
is what proves the dispatcher actually calls `containing/2` when it exists
rather than always falling back.
