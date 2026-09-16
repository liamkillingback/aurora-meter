# 09a: the `EnsureEntitled` option matrix

Build unit 09a, core `aurora_meter` 0.5.0, branch `aurorameter-v1`.
Source: `test/aurora_meter/plug/ensure_entitled_test.exs`, 26 tests, `--seed 0`.
Raw log: `logs/09a-plug-matrix.log`.

## 1. The matrix

Every row records the feature's usage value immediately before the request and
immediately after it. **The two are equal on every row, including the rows where
the request passed.** That column is the unit, not a detail: the plug that this
build document refused to ship (one that reserved at the router) fails it on
every passing row, which is invariants I03 and I04 protected negatively.

Tenant plans: `:free` has `limit :ai_generations, 50, :hard` and
`feature :api_access, false`; `:pro` has `limit :ai_generations, 1_000, :hard`
and `feature :api_access, true`; `:policy` (from
`AuroraMeter.Test.PolicyPlans`) declares neither `:nowhere` nor anything like it.

| # | Options | Request | Status | `conn.private[:aurora_meter_denial]` | Assigns after | usage before | usage after |
|---|---|---|---|---|---|---|---|
| 1 | `feature: :ai_generations, tenant: {M, :no_tenant}` | resolver returns `nil` | **401** | `:missing_tenant` | none | n/a (no tenant) | n/a |
| 2 | same as 1 | resolver returns `nil` | **401** | `:missing_tenant` | none | `""` has no ETS row, no DB counter row, no subscription, no subscription-cache entry, before and after | unchanged (all four absent) |
| 3 | `feature: :api_access` on `:free` | boolean feature is `false` | **403** | `:not_entitled` | none, body `""` | n/a (boolean) | n/a |
| 4 | `feature: :ai_generations` on `:free`, usage 50 | at the hard cap | **403** | `:limit_exceeded` | none | 50 | 50 |
| 5 | `on_denied: {M, :denied_json}` on a denied `:api_access` | | **402** (the callback's own status) | `:not_entitled` | body `{"error":"not_entitled"}`, content type `application/json` | n/a | n/a |
| 6 | `on_denied: {M, :forgets_to_halt}` | callback returns an unhalted conn | **raises** `RuntimeError` naming `AuroraMeter.Plug.EnsureEntitledTest.forgets_to_halt/2` | `:not_entitled` was set before the callback ran | n/a | n/a | n/a |
| 7 | `on_denied: {M, :returns_rubbish}` | callback returns `:nope` | **raises** `RuntimeError` naming the callback and printing `:nope` | | | | |
| 8 | `feature: :ai_generations` on `:pro`, usage 7 | allowed | **nil** (unhalted) | none | `aurora_meter_tenant`, `aurora_meter_quota`; the quota equals `AuroraMeter.quota(tenant, :ai_generations)` field for field | 7 | 7 |
| 9 | `feature: :api_access` on `:pro`, tenant term is an **integer** | allowed | nil | none | `aurora_meter_tenant` is the integer, not its key | n/a | n/a |
| 10 | tenant term is `{:org, "org_1"}` (no `String.Chars`) | | **raises** `Protocol.UndefinedError` | none | none | n/a | n/a |
| 11 | `assign_quota: false` on `:pro` | allowed | nil | none | `aurora_meter_tenant` only; no `aurora_meter_quota` key at all | n/a | n/a |
| 12 | default, `:pro`, usage 3 | allowed | nil | none | both | 3 | **3** |
| 13 | default, `:free`, usage 49, **twelve consecutive requests** | all allowed | `[nil × 12]` | none | both, each time | 49 | **49** |
| 14 | `undeclared_feature_policy: :deny`, `feature: :nowhere` | undeclared | **403** | `:not_entitled` | none | n/a | n/a |
| 15 | `undeclared_feature_policy: :allow`, `feature: :nowhere` | undeclared | nil | none | `aurora_meter_quota.kind == :undeclared`, `enabled == true` | n/a | n/a |
| 16 | `undeclared_feature_policy: :raise`, `feature: :nowhere` | undeclared | **raises** `AuroraMeter.UndeclaredFeatureError` (not 503) | none | none | n/a | n/a |
| 17 | `mode: :entitled?, assign_quota: false` on `:pro`, usage 1_000 (at the cap) | allowed | nil | none | `aurora_meter_tenant` | 1_000 | 1_000, and `AuroraMeter.check/2` on the same tenant returns `{:error, :limit_exceeded}` |
| 18 | `mode: :entitled?` with `FailingSeedStorage` armed | allowed | nil | none | `aurora_meter_tenant` | `load_counter/3` call count **0** | 0 |
| 18c | **control**: `mode: :check`, same armed storage, same request | | **503** | `:unavailable` | none | `load_counter/3` call count **>= 1** | |
| 19 | default, `FailingSeedStorage` armed, cold counter | storage raises `DBConnection.ConnectionError` | **503** | `:unavailable` | none, and one `Logger.error` naming the feature and the exception class | n/a | n/a |
| 20 | `period_source: PeriodSources.NotAMap` | | **raises** `AuroraMeter.Period.InvalidPeriodError` (not 503) | none | none | n/a | n/a |
| 21 | `tenant:` a function that raises `ArgumentError` | | **raises** `ArgumentError` unchanged | none | none | n/a | n/a |

Row 18 and row 18c are one test, and the pair is the assertion. "`load_counter/3`
was not called" is worth nothing on its own: it is also what a plug that never
ran produces. The control arms the identical storage and runs the identical
request in `:check` mode, which must reach the adapter and fail.

## 2. `init/1`

| Options | Result |
|---|---|
| `feature: :ai_generations, tenant: {M, :f}, retry_after: 30` | `NimbleOptions.ValidationError`, "unknown options [:retry_after]" |
| `feature: :ai_generations` | `NimbleOptions.ValidationError`, "required :tenant option not found" |
| `feature: "ai_generations", tenant: {M, :f}` | `NimbleOptions.ValidationError`, "invalid value for :feature option" |
| `feature: :ai_generations, tenant: {M, :f}, mode: :reserve` | `NimbleOptions.ValidationError`, "invalid value for :mode option" |
| `tenant: {M, :f}` | accepted, frozen as a map |
| `tenant: &M.no_tenant/1` | accepted, a 1-arity function |

Phoenix expands a router `plug` call at compile time, so every row above is a
compile error in the host application rather than a first-request surprise.

## 3. Status mapping, and why `:limit_exceeded` is not 429

`:limit_exceeded` is an entitlement outcome for the current period, not a rate
limit that clears in seconds, so a `Retry-After` would be a lie. Both denial
reasons default to 403; the reason atom is carried in `conn.private` and passed
to a `{module, function}` callback, so a host that prefers 402 maps it in one
clause (row 5 does exactly that).

## 4. A defect this matrix found in the plug, before it shipped

Rows 6 and 7 failed on the first run with "Expected exception RuntimeError but
nothing was raised", and a 503 was returned instead.

`call/2` originally ran the decision **and** the response inside one
`try/rescue` whose "anything else" arm becomes 503. `assert_halted!/4`'s
`RuntimeError`, which exists to refuse a denial callback that would let a refused
request through, was raised inside that region and swallowed by it. The rule the
moduledoc states was therefore unenforceable at runtime, and a host whose
callback forgot `halt/1` would have seen a 503 with no explanation instead of a
message naming its own function.

Fixed by separating the two: `decide/2` is the classified region and returns
`{:ok, assigns} | {:denied, reason} | {:unavailable, error, stacktrace}`;
`respond/3` dispatches outside it. The same change is what lets row 10's
`Protocol.UndefinedError` propagate, because the tenant key is now resolved
before `decide/2` is entered.

Control `c8-denial-callback-need-not-halt` in `09a-controls.log` restores the
original defect and watches rows 6 and 7 fail, so the guard is known to
discriminate rather than assumed to (X153, X350).
