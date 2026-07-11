# Aurora Meter — end-to-end autonomous build plan

> **Working name:** Aurora Meter · **Core package:** `aurora_meter` (MIT) · **Pro package:** `aurora_meter_pro` (commercial)
> **One line:** *Laravel Cashier + OpenMeter for Phoenix* — subscriptions, real-time usage metering, and plan-gating as a few function calls, on the BEAM.
>
> This document is the **single source of truth** for building Aurora Meter to completion. It is written so that autonomous agents can execute it phase by phase with **no decisions left open**. If something here is ambiguous, that is a bug in this plan — fix the plan first (add an ADR), then build.

---

## 0. How to use this plan (agent execution protocol)

Read this section in full before touching any code. It is binding.

1. **Work one phase at a time, in order.** Do not start Phase _N+1_ until Phase _N_'s **Verification Gate** is green. Phases are dependency-ordered.
2. **Never skip a gate.** A phase is "done" only when every checkbox is ticked *and* the gate commands pass with the stated expected result. If a gate fails, fix it; do not proceed.
3. **Write evidence.** For every phase, save proof under `docs/evidence/phase-NN/` (test output, benchmark numbers, screenshots, `mix check` logs). The gate references the evidence file it expects.
4. **One commit per completed task, one tag per released phase.** Commit messages: `phase-NN: <task>`. Conventional, present tense.
5. **Obey the contract.** `AGENTS.md` (created in Phase 0, content in [Appendix H](#appendix-h--agentsmd-contract-verbatim)) governs module/style/quality rules. `CLAUDE.md` points to it. Re-read `AGENTS.md` before writing code in any phase.
6. **No scope creep.** The [Non-Goals](#3-scope--non-goals-hard-boundaries) list is a hard boundary. If a task tempts you outside it, stop and leave it for a post-v1 ADR. Aurora Meter's predecessor project died of scope creep; scope discipline is the top priority.
7. **Determinism over cleverness.** Every public function gets a `@spec` and a `@doc` with an `## Examples`. Prefer boring, tested code.
8. **Ask nothing, assume nothing.** All decisions are pre-made in [§2](#2-resolved-decisions-no-open-questions). If a genuinely new fork appears, record it as an ADR under `docs/adr/` with a decision and rationale, then continue.

**Definition of Done (applies to _every_ phase):**
`mix check` is green (format + compile-warnings-as-errors + credo --strict + dialyzer + test + docs), new code has specs + docs + tests, evidence is written, work is committed.

---

## 1. What we are building (the whole thing, restated)

A Phoenix/Elixir library that lives **inside** the host app (a dependency, not a hosted service; the host owns its data). It does three tightly-coupled jobs:

| Job | Free core | What it means |
|---|---|---|
| **Meter** | ✅ | Record billable events at high throughput; aggregate in real time. |
| **Entitle** | ✅ | Gate actions on `plan + live usage` (hard limits block; metered allowed). |
| **Bill** | Pro | Sync plans/usage to Stripe; report metered overage; hosted dashboards. |

The **moat** is the meter: increments hit an in-memory ETS counter (microseconds, lock-free, no DB on the hot path), a Flusher persists snapshots to Postgres on an interval, and a Broadcaster fans live values out over `Phoenix.PubSub`. This is native on the BEAM and awkward everywhere else.

Developer surface (the entire public API a consumer touches):

```elixir
AuroraMeter.track(tenant, :ai_generations, 1)                       # meter
AuroraMeter.check(tenant, :ai_generations)                          # :ok | {:error, :limit_exceeded | :not_entitled}
AuroraMeter.with_quota(tenant, :ai_generations, fn -> work() end)   # gate + run + meter, atomically
AuroraMeter.usage(tenant, :ai_generations)                          # current-period integer
AuroraMeter.remaining(tenant, :ai_generations)                      # integer | :unlimited
AuroraMeter.subscribe(tenant, :pro)                                 # assign a plan (local)
# Pro:
AuroraMeter.Billing.checkout(tenant, :pro, success_url: url)        # -> {:ok, stripe_url}
AuroraMeter.Billing.portal_url(tenant)                              # -> {:ok, url}
# HEEx:
# <.usage_meter tenant={@org} feature={:ai_generations} />
```

---

## 2. Resolved decisions (NO open questions)

Every fork is decided here. Deviations require an ADR.

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Package split | `aurora_meter` (MIT) + `aurora_meter_pro` (commercial), separate git repos | Oban/Oban-Pro model |
| D2 | Namespace | `AuroraMeter.*` (core), `AuroraMeter.Pro.*` (pro) | Brand family |
| D3 | Storage | Ecto + Postgres **only** in v1, behind `AuroraMeter.Storage` behaviour | One datastore; door left open |
| D4 | Billing provider | Stripe **only** in v1 (Pro), behind `AuroraMeter.Billing.Provider` behaviour | One provider; door left open |
| D5 | Plans | **Code-first DSL** (`use AuroraMeter.Plans`); no DB-editable plans in v1 | Simple, versioned with the app |
| D6 | Tenant identity | Any term → `AuroraMeter.Tenant.to_key/1` → stable `String.t()`; default impl `to_string/1` | Works with any host id scheme |
| D7 | Counter substrate | **ETS** `:set` + `:ets.update_counter/4` (atomic), **not** a GenServer-per-tenant | Lock-free, no mailbox bottleneck |
| D8 | Durability | `:buffered` default (≤ flush-interval loss window); `:durable` **per-feature** opt-in appends to `events` | Fast by default, exact where money needs it |
| D9 | DB flush interval | `5_000 ms` default (`:flush_interval`) | Cheap DB write cadence |
| D10 | Broadcast interval | `1_000 ms` default (`:broadcast_interval`), decoupled from DB flush | Live feel without DB churn |
| D11 | Billing period | Free core: **calendar month, UTC**. Pro: subscription-aligned when a subscription exists, else calendar. Counter keyed by `period_start :: DateTime` | Deterministic; reset is implicit via the period key |
| D12 | Limit semantics | `limit f, n, :hard` → **block** at cap; `metered f, included:, unit_price:` → **allow + bill**; feature not declared in the plan → `:ok` (permissive) + `Logger.warning` in `:dev` | Predictable, documented |
| D13 | Concurrency | `with_quota`/`reserve` use **atomic reserve** (increment → compare → roll back on breach or on `fun` raise) | Correct hard-limit enforcement under load |
| D14 | PubSub topic | `"aurora_meter:tenant:" <> tenant_key`; message `{:aurora_meter, :usage, %{feature:, value:, period_start:}}` | Stable contract for components |
| D15 | Components | Ship in core behind **optional** `:phoenix_live_view`/`:phoenix_html` deps | Core usable headless |
| D16 | Money | Minor units (integer cents). `unit_price`/`included` are **local estimate + gating display only**; Stripe is the billing source of truth | Never reimplement Stripe pricing |
| D17 | Stripe metered | Stripe **Billing Meters** (`meter_events`) via a periodic idempotent reporter backed by a `usage_reports` ledger | Modern API; legacy usage records are deprecated |
| D18 | Elixir floor | `~> 1.15`; CI matrix `1.15/OTP25` and `1.18/OTP27` | Broad support, matches sibling repos |
| D19 | Table PKs | `aurora_meter_*` tables, `binary_id` PKs, `tenant_key :string` | No collision with host schema |
| D20 | Config validation | `NimbleOptions` schema validated at boot; **fail fast** | No silent misconfig |
| D21 | Default plan | `config :aurora_meter, default_plan: :free` used when a tenant has no subscription row | Deterministic gating from day one |
| D22 | Reset job | **None.** New `period_start` in the counter key naturally starts at 0; old rows are retained as history | No destructive jobs |

---

## 3. Scope & non-goals (hard boundaries)

**In scope (v1):** the three jobs above, Stripe, Postgres, code-defined plans, LiveView usage components, a hosted Pro dashboard, quota alerts, telemetry.

**Explicitly OUT of v1 (do NOT build; leave for a future ADR):**
- Tax/VAT (Stripe Tax's job) · dunning/retry UI (Stripe's job).
- Non-Stripe providers (behaviour only, no second adapter) · non-Postgres storage (behaviour only).
- DB-editable plans / a plans admin UI · a general CRUD admin panel (that is Backpex's job).
- General product analytics / BI / funnels.
- A pricing-page builder.
- **Anything AI or agent-related.** (This is the trap the predecessor fell into.)
- SSO/SAML/SCIM, RBAC beyond plan entitlements.

---

## 4. Dev environment & commands (this machine)

Elixir/mix run inside **WSL (Ubuntu-24.04)** with Homebrew not on the default PATH. Every `mix` invocation from the Windows-side agent must be wrapped:

```bash
wsl.exe -d ubuntu-24.04 bash -lc \
  'export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"; cd ~/src/PhxTemplates/product-workspaces/aurora_meter && mix <task>'
```

**Dedicated test Postgres** (do not reuse phxtemplates' 5470/5480). Start once:

```bash
docker run -d --name aurora-meter-testdb -e POSTGRES_PASSWORD=postgres -p 5490:5432 postgres:16
```

`config/test.exs` points `AuroraMeter.TestRepo` at `localhost:5490` (see [Appendix A](#appendix-a--canonical-migration)). Run the suite:

```bash
MIX_ENV=test mix test          # sandbox-isolated; DB on 5490
mix check                      # the full gate (see §5)
```

Canonical commands (also in `AGENTS.md`):

```bash
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
mix check          # runs all of the above in order
```

---

## 5. Quality gates & CI

`mix check` alias (defined in `mix.exs`, Phase 0) runs, in order and failing fast:

```
format --check-formatted → compile --warnings-as-errors --force → credo --strict → dialyzer → test → docs
```

CI (`.github/workflows/ci.yml`, mirrors the sibling `free_ui_kit` repo) adds a Postgres service, `deps.unlock --check-unused`, `mix hex.audit`, `mix deps.audit` (mix_audit), and a **gitleaks** secret-scan job. Matrix: `{1.15/25, 1.18/27}`. Full YAML in [Appendix F](#appendix-f--ci-workflow-core).

**Global Definition of Done** (repeated from §0): green `mix check`, specs + docs + tests on new code, evidence written under `docs/evidence/phase-NN/`, committed.

---

## 6. Repository layout (target end state, core)

```
aurora_meter/
├── AGENTS.md                    # build contract (Appendix H)
├── CLAUDE.md                    # points to AGENTS.md
├── README.md  CHANGELOG.md  LICENSE  NOTICE.md
├── mix.exs  .formatter.exs  .credo.exs  .gitignore
├── .github/workflows/ci.yml
├── lib/
│   ├── aurora_meter.ex                       # public API facade + supervisor entry
│   ├── aurora_meter/
│   │   ├── application.ex? (NO — host-mounted; provide child_spec/1)
│   │   ├── config.ex                         # NimbleOptions schema + accessors
│   │   ├── supervisor.ex                     # Registry + Store + Flusher + Broadcaster
│   │   ├── store.ex                          # ETS table owner
│   │   ├── counter.ex                        # ETS ops: incr/reserve/value/mark_dirty
│   │   ├── flusher.ex                         # interval DB upsert of dirty counters
│   │   ├── broadcaster.ex                     # interval PubSub of live values
│   │   ├── period.ex                          # current/2 → %{start,end,source}
│   │   ├── tenant.ex                          # behaviour + Default (to_key/1)
│   │   ├── plans.ex                           # `use` DSL + runtime lookups
│   │   ├── plan.ex                            # %Plan{} struct
│   │   ├── entitlements.ex                    # check/allowed?/remaining/entitled?/with_quota/reserve
│   │   ├── billing.ex                         # Provider behaviour + facade (checkout/portal delegate)
│   │   ├── billing/noop.ex                    # default provider (core works without Pro)
│   │   ├── storage.ex                         # behaviour
│   │   ├── storage/ecto.ex                    # default adapter
│   │   ├── schema/{subscription,counter,event}.ex
│   │   ├── components.ex                      # <.usage_meter>, <.usage_summary> (optional deps)
│   │   └── telemetry.ex                       # event docs + helpers
│   └── mix/tasks/aurora_meter.{install,gen.migration,bench}.ex
├── priv/
│   ├── templates/migration.eex               # installer output
│   └── test_repo/migrations/*.exs
├── test/ (mirrors lib/) + test/support/{test_repo.ex,plans_fixture.ex,data_case.ex}
├── docs/{getting-started,configuration,metering,entitlements,plans,telemetry,testing}.md
├── docs/adr/000N-*.md
├── docs/evidence/phase-NN/*
└── demo/                                      # Phoenix app depending on the lib by path
```

`aurora_meter_pro/` mirrors this shape (Phases 8–13).

---

# The build — phased checklist

Each phase: **Goal → Tasks (checkboxes with exact paths/signatures) → Tests → Verification Gate.**

## Phase 0 — Repository & tooling scaffold

**Goal:** an empty, CI-green library repo that compiles, formats, lints, and runs zero tests.

- [ ] `mix new aurora_meter` (library; **no** `--sup`). Set project root at `product-workspaces/aurora_meter/`.
- [ ] `mix.exs`: `@version "0.0.1"`, `@source_url "https://github.com/liamkillingback/aurora-meter"`, `elixir: "~> 1.15"`, `elixirc_options: [warnings_as_errors: true]`, `elixirc_paths` splitting `test/support`, `test_coverage: [summary: [threshold: 0]]`, `deps/0` ([Appendix B deps](#appendix-b--config--deps-reference)), `package/0` (`licenses: ["MIT"]`, `maintainers: ["Liam Killingback"]`, links GitHub/Docs/PHXTemplates, `files` list), `docs/0`, and the `check` alias (§5) plus `test.setup`/`db.reset` aliases.
- [ ] `.formatter.exs`: `import_deps: [:ecto, :ecto_sql]`, `inputs: ["*.{ex,exs}", "{lib,test,priv}/**/*.{ex,exs}"]`. (Add `:phoenix`, `:phoenix_live_view` + the HTMLFormatter plugin in Phase 6.)
- [ ] `.credo.exs` — strict config.
- [ ] Dialyzer: `dialyzer: [plt_add_apps: [:ex_unit, :mix], flags: [:error_handling, :extra_return, :missing_return, :underspecs]]` in `mix.exs`; cache PLT in CI.
- [ ] `LICENSE` (MIT, "Liam Killingback"), `NOTICE.md`, `CHANGELOG.md` (Keep a Changelog, `Unreleased`), `README.md` skeleton (headline + "not yet released").
- [ ] `AGENTS.md` — copy verbatim from [Appendix H](#appendix-h--agentsmd-contract-verbatim). `CLAUDE.md` — 6 lines pointing to it.
- [ ] `.gitignore` — `/deps /_build /doc erl_crash.dump *.ez /priv/plts /.elixir_ls`.
- [ ] `.github/workflows/ci.yml` — [Appendix F](#appendix-f--ci-workflow-core).
- [ ] `docs/adr/0001-resolved-decisions.md` — record D1–D22 (§2) as the founding ADR. Add `0002-ets-counter-substrate.md` and `0003-buffered-vs-durable.md` capturing D7/D8 with rationale.
- [ ] `git init`; initial commit `phase-00: scaffold`.

**Verification Gate 0:**
```
mix deps.get && mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix test
```
Expect: compiles clean, 0 test failures (0 tests), credo 0 issues. Save the terminal log to `docs/evidence/phase-00/gate.txt`.

## Phase 1 — Config, boot, tenant resolution

**Goal:** `AuroraMeter` starts under a host supervision tree, validates config, and owns its ETS tables.

- [x] `AuroraMeter.Config` — `NimbleOptions` schema ([Appendix B](#appendix-b--config--deps-reference)); `validate!/0` reads `Application.get_all_env(:aurora_meter)`, raises on invalid; typed accessors `repo/0 pubsub/0 plans/0 tenant/0 flush_interval/0 broadcast_interval/0 default_plan/0 storage/0 provider/0`.
- [x] `AuroraMeter.Tenant` behaviour: `@callback to_key(term) :: String.t()`. `AuroraMeter.Tenant.Default` → `to_string/1` (raise on non-`String.Chars`). `AuroraMeter.Tenant.to_key/1` dispatches via config.
- [x] `AuroraMeter.Store` — a tiny GenServer that **owns** two named ETS tables created in `init/1`: `:aurora_meter_counters` (`:set, :public, read_concurrency: true, write_concurrency: true`) and `:aurora_meter_dirty` (`:set, :public, write_concurrency: true`). Never a bottleneck — it only owns tables; readers/writers hit ETS directly.
- [x] `AuroraMeter.Supervisor` (`use Supervisor`): children = `[{Registry, keys: :unique, name: AuroraMeter.Registry}, AuroraMeter.Store, AuroraMeter.Flusher, AuroraMeter.Broadcaster]`. (Flusher/Broadcaster are stubs until Phase 3/6.)
- [x] `AuroraMeter.child_spec/1` + `start_link/1` delegating to the Supervisor, so a host adds `AuroraMeter` (or `{AuroraMeter, opts}`) to its tree. `AuroraMeter.start_link/1` calls `Config.validate!/0` first.
- [x] `test/support/test_repo.ex` (Ecto Postgres repo), `test/support/data_case.ex` (sandbox), `test/test_helper.exs`: `Application.put_env` test config, `ExUnit.start()`, start `AuroraMeter` via `start_supervised!/1` in the case template.

**Tests:** config validation (valid boots; missing `:repo`/`:pubsub`/`:plans` raises with a clear message); `Tenant.to_key/1` for binary/integer/struct-with-`String.Chars`; Store creates both ETS tables; Supervisor starts and children are alive.

**Verification Gate 1:** `mix check` green; `docs/evidence/phase-01/gate.txt`. ≥ 6 tests.

## Phase 2 — Persistence layer

**Goal:** schemas, the Storage behaviour + Ecto adapter, the installer migration, and the test-repo migration — all sandbox-tested.

- [x] Schemas (`binary_id`): `AuroraMeter.Schema.Subscription`, `.Counter`, `.Event` — fields per [Appendix A](#appendix-a--canonical-migration). Each with `@type t`, changeset, and validations.
- [x] `AuroraMeter.Storage` behaviour: `upsert_counters(rows) :: :ok`, `load_counter(tenant_key, feature, period_start) :: integer | nil`, `get_subscription(tenant_key) :: Subscription.t | nil`, `put_subscription(attrs) :: {:ok, Subscription.t} | {:error, changeset}`, `insert_events(rows) :: :ok`, `stream_counters(period_start) :: Enumerable.t` (for Pro rollups).
- [x] `AuroraMeter.Storage.Ecto` — implements it against `Config.repo/0`. `upsert_counters/1` = `Repo.insert_all(Counter, rows, on_conflict: {:replace, [:value, :updated_at]}, conflict_target: [:tenant_key, :feature, :period_start])`. `put_subscription/1` upserts on `conflict_target: [:tenant_key]`.
- [x] `priv/templates/migration.eex` — canonical migration ([Appendix A](#appendix-a--canonical-migration)). `Mix.Tasks.AuroraMeter.Gen.Migration` / `AuroraMeter.Install` — copies it into the host `priv/repo/migrations` with a timestamp; prints post-install config snippet.
- [x] `priv/test_repo/migrations/*_create_aurora_meter.exs` — same DDL for the library's own test DB; `test.setup` alias runs `ecto.create` + `ecto.migrate` for `TestRepo`.

**Tests:** adapter round-trips (upsert then load; conflict replaces not duplicates); subscription upsert idempotent; `insert_events` writes rows; migration applies cleanly on the test DB.

**Verification Gate 2:** `mix check` green; `mix test.setup && mix test` from clean DB; `docs/evidence/phase-02/gate.txt`. ≥ 10 new tests.

## Phase 3 — Metering core (the moat)

**Goal:** correct, fast, real-time counting with durable flush and rehydration.

- [x] `AuroraMeter.Period` — `current(tenant, now \\ DateTime.utc_now()) :: %{start: DateTime.t(), end: DateTime.t(), source: :calendar}`. Free core: month bounds, UTC, `start` = `~T[00:00:00]` on day 1, truncated `:second`. (Pro overrides `source` in Phase 10 via `Config.period_source/0`.)
- [x] `AuroraMeter.Counter` — pure ETS ops (no GenServer):
  - `incr(tenant_key, feature, qty, period_start) :: integer` → `:ets.update_counter(:aurora_meter_counters, key, {2, qty}, {key, 0})` then `mark_dirty(key)`; returns new value.
  - `reserve(tenant_key, feature, qty, period_start, limit) :: :ok | {:error, :limit_exceeded}` → increments, marks dirty, and **if `limit != nil and new > limit`** rolls back (`update_counter … {2, -qty}`) and returns error. (Atomic-enough: the check reads the post-increment return value.)
  - `release(...)` → `update_counter {2, -qty}` + mark dirty (rollback on `fun` raise).
  - `value(tenant_key, feature, period_start) :: integer` → ETS lookup; on miss, `Storage.load_counter/3`; if found seed ETS with `:ets.insert_new` (no double count) and return; else 0.
  - `mark_dirty(key)` → `:ets.insert(:aurora_meter_dirty, {key})`.
- [x] `AuroraMeter.track(tenant, feature, qty \\ 1, opts \\ [])` — resolves tenant_key + period, calls `Counter.incr`, emits `[:aurora_meter, :track]` telemetry. If the feature is `:durable` (per plan/config), also `Storage.insert_events/1` synchronously. Returns `:ok`.
- [x] `AuroraMeter.usage/2`, `usage_all/1` (map of feature→value for current period from ETS + DB fallback).
- [x] `AuroraMeter.Flusher` (GenServer) — every `flush_interval`: **snapshot** dirty keys (`:ets.tab2list`), then **per key**: `:ets.delete(:aurora_meter_dirty, key)`, read current value, build row; `Storage.upsert_counters/1` in one batch. Per-key delete (not `delete_all_objects`) so keys marked mid-sweep survive to the next cycle. Idempotent (absolute-value upsert). Emits `[:aurora_meter, :flush]` with count. On terminate, do a final flush.
- [x] `Mix.Tasks.AuroraMeter.Bench` — spawns N processes × M increments, measures throughput and post-flush DB correctness; writes `docs/evidence/phase-03/bench.md`. (This proves the moat claim; target ≥ 100k incr/s single-node — record the real number regardless.)

**Tests:**
- Unit: incr/value/reserve/release; rehydrate-from-DB seeds ETS once (no double count).
- **Property (StreamData):** K async tasks each incr J times → `usage == K*J` after flush; DB row equals ETS.
- Durable mode writes one event per `track`.
- Flusher idempotency: two flushes with no new incr leave the DB value unchanged; a mid-sweep incr is captured next cycle (assert eventual consistency).

**Verification Gate 3:** `mix check` green; property test passes with ≥ 200 runs; `bench.md` present with real numbers; `docs/evidence/phase-03/gate.txt`. ≥ 15 new tests.

## Phase 4 — Plans DSL

**Goal:** compile-time, validated plan definitions.

- [ ] `AuroraMeter.Plan` — `%Plan{id, price, features: %{atom => feature_cfg}}` where `feature_cfg` is `{:limit, n, :hard}` | `{:metered, included, unit_price}` | `{:feature, boolean}`. `@type`.
- [ ] `AuroraMeter.Plans` — `defmacro __using__/1` accumulating via module attrs; macros `plan/2`, `price/1`, `limit/3` (`limit :f, n, :hard`), `metered/2` (`metered :f, included: i, unit_price: p`), `feature/2`. Compiles to `__aurora_plans__/0 :: %{atom => Plan.t}`. **Compile-time validation**: duplicate feature in a plan → raise; unknown limit mode → raise; negative numbers → raise.
- [ ] Runtime helpers: `AuroraMeter.Plans.all/0`, `get/1`, `feature_config/2` (plan_id, feature), reading the module from `Config.plans/0`.

**Tests:** a `test/support/plans_fixture.ex` with free/pro/scale (matching the spec); `get/1`, `feature_config/2`, `all/0`; compile-error tests via `Code.eval_string` asserting raises.

**Verification Gate 4:** `mix check` green; `docs/evidence/phase-04/gate.txt`. ≥ 8 new tests.

## Phase 5 — Entitlements + local subscriptions + billing behaviour

**Goal:** the gate, plan resolution, atomic `with_quota`, and the provider seam (so core works standalone and Pro can plug in).

- [ ] `AuroraMeter.subscribe(tenant, plan_id) :: {:ok, Subscription.t} | {:error, _}` — `Storage.put_subscription/1` with `status: "active"`, `plan_id`, no provider fields (local).
- [ ] `AuroraMeter.plan(tenant) :: Plan.t` — subscription's plan, else `Config.default_plan/0`.
- [ ] `AuroraMeter.Entitlements`:
  - `check(tenant, feature) :: :ok | {:error, :limit_exceeded | :not_entitled}` per **D12**: `{:feature, false}` → `:not_entitled`; `{:limit, n, :hard}` → `usage >= n` ? `:limit_exceeded` : `:ok`; `{:metered, _, _}` → `:ok`; undeclared → `:ok` (+ dev warning).
  - `allowed?/2` (bool), `entitled?/2` (feature access only), `remaining/2 :: non_neg_integer | :unlimited`.
  - `reserve(tenant, feature, qty \\ 1)` → resolves hard `limit` (nil for metered/undeclared) then `Counter.reserve/5`.
  - `with_quota(tenant, feature, qty \\ 1, fun)` → `case reserve: :ok -> try fun; on raise release + reraise; return {:ok, result}` ; `{:error, e} -> {:error, e}`. **No separate `track` call** — `reserve` already incremented (avoids double count).
- [ ] `AuroraMeter.Billing.Provider` behaviour (defined in **core**): `create_checkout_session(tenant, opts)`, `billing_portal_url(tenant, opts)`, `sync_subscription(payload)`, `report_usage(entries)`. `AuroraMeter.Billing.Noop` implements all as `{:error, :not_configured}` and is the default `Config.provider/0`.
- [ ] `AuroraMeter.Billing.checkout/3`, `portal_url/2` — thin facades delegating to `Config.provider/0`.

**Tests:** hard-limit blocks exactly at cap; metered always `:ok`; undeclared permissive; `remaining` math (incl. `:unlimited`); `with_quota` **concurrency** (K tasks racing a cap of n → exactly n succeed, K−n get `:limit_exceeded`, final usage == n); `release` on `fun` raising restores the counter; Noop provider returns `:not_configured`.

**Verification Gate 5:** `mix check` green; the concurrency test is mandatory and must be deterministic (use `Task.async_stream` + assert counts); `docs/evidence/phase-05/gate.txt`. ≥ 14 new tests.

## Phase 6 — Real-time + LiveView components

**Goal:** live usage over PubSub and drop-in HEEx meters.

- [ ] Add optional deps `:phoenix_live_view` / `:phoenix_html` (D15); update `.formatter.exs` (`import_deps: [..., :phoenix, :phoenix_live_view]`, add `Phoenix.LiveView.HTMLFormatter` plugin).
- [ ] `AuroraMeter.Broadcaster` (GenServer) — every `broadcast_interval`, for each tenant/feature touched since last tick, `Phoenix.PubSub.broadcast(pubsub, topic, {:aurora_meter, :usage, %{feature:, value:, period_start:}})` (D14). Track "touched" via the dirty set snapshot (read-only; does not clear it — Flusher owns clearing). Emits `[:aurora_meter, :broadcast]`.
- [ ] `AuroraMeter.Components` (`use Phoenix.Component`): `usage_meter/1` (attrs `tenant`, `feature`, optional `label`; renders current/limit + a bar) and `usage_summary/1` (all plan features). Typed `attr`s; `attr :rest, :global`.
- [ ] `AuroraMeter.LiveView.on_mount/4` (or `subscribe/1` helper) — subscribes the LiveView to the tenant topic and handles the `{:aurora_meter, :usage, _}` message to update assigns. Document the 3-line wiring in `docs/liveview` (Phase 7).

**Tests:** Floki render tests for both components (roles, values, `aria` on the bar via `role="progressbar"` + `aria-valuenow/max`); a PubSub test asserting a subscribed process receives a `:usage` message within `2 * broadcast_interval` after a `track`.

**Verification Gate 6:** `mix check` green; component tests render without warnings; `docs/evidence/phase-06/gate.txt`. ≥ 8 new tests.

## Phase 7 — Free core hardening + **release `v0.1.0`** (the wedge)

**Goal:** a polished, documented, publishable free core — the adoption front door.

- [ ] Typespecs on **every** public function; `@moduledoc`/`@doc` with `## Examples`; doctests where cheap. `mix dialyzer` clean (0 warnings).
- [ ] `README.md` — headline, install, 60-second quickstart (the 3 jobs), config table, "what's free vs Pro", links. Optimize for **AI-legibility** (the shadcn lesson): plain, copy-pasteable, self-explaining.
- [ ] Guides in `docs/`: `getting-started`, `configuration`, `metering`, `entitlements`, `plans`, `telemetry` ([Appendix C](#appendix-c--telemetry-events)), `testing`. Wire `extras`/`groups_for_extras` in `mix.exs` `docs/0`.
- [ ] `demo/` — a Phoenix 1.7+ app depending on `{:aurora_meter, path: ".."}`, with a plans module, one gated action, and a `/usage` LiveView using `<.usage_meter>`. Proves the install story end to end. README documents booting it.
- [ ] `CHANGELOG.md` → `0.1.0`; bump `@version`; verify `package.files`; `mix hex.build` (dry run) clean; `mix docs` builds.
- [ ] **Manual step (flag, do not automate):** `mix hex.publish` and pushing the GitHub repo — leave a `docs/RELEASE.md` checklist; a human runs it. Tag `v0.1.0` locally.

**Verification Gate 7:** `mix check` green on the full matrix locally (1.15 + 1.18); `demo` boots and the `/usage` page updates live (screenshot → `docs/evidence/phase-07/usage.png`); `mix docs` output archived; `git tag v0.1.0`.

---

> **Checkpoint:** Free core is shippable and self-contained. Everything below is Pro. It can proceed in parallel with real-world adoption of the free core.

---

## Phase 8 — Pro package scaffold (`aurora_meter_pro`)

**Goal:** a second repo that compiles against the core via a path dep.

- [ ] `product-workspaces/aurora_meter_pro/` — `mix new`, namespace `AuroraMeter.Pro`. `mix.exs`: **commercial** `package` (or unpublished), `LICENSE.commercial` (all-rights-reserved + per-app commercial grant, Sidekiq-Pro-style), `@version "0.0.1"`.
- [ ] Deps: `{:aurora_meter, path: "../aurora_meter"}` (dev) / `"~> 0.1"` (release), `{:oban, "~> 2.17"}`, `{:stripity_stripe, "~> 3.2"}`, `{:plug, "~> 1.15"}`, `{:phoenix_live_view, "~> 0.20 or ~> 1.0"}`, dev/test: `ex_doc credo dialyxir stream_data`.
- [ ] `AGENTS.md` (Pro variant — same contract + "never call the real Stripe API in tests; use the fake"), `CLAUDE.md`, `.credo.exs`, `.formatter.exs`, `.github/workflows/ci.yml` (no Stripe secrets — tests use the fake provider), `.gitignore`.
- [ ] `docs/adr/0001-pro-scope.md` (D4/D16/D17).
- [ ] `git init`; `phase-08: scaffold pro`.

**Verification Gate 8:** Pro `mix check` green with the path dep resolved; 0 tests; `docs/evidence/phase-08/gate.txt`.

## Phase 9 — Pro Stripe provider + webhook + checkout/portal

**Goal:** real Stripe subscription lifecycle, kept truthful by webhooks; local counters unchanged.

- [ ] `AuroraMeter.Pro.Stripe` implements `AuroraMeter.Billing.Provider`: `create_checkout_session/2` (maps `plan_id`→Stripe price via config; returns `{:ok, url}`), `billing_portal_url/2`, `sync_subscription/1` (Stripe sub payload → `AuroraMeter.Storage` upsert: status, `provider_*`, `current_period_start/end`), `report_usage/1` (Phase 10).
- [ ] Config: `config :aurora_meter_pro, stripe_prices: %{pro: "price_...", scale: "price_..."}, stripe_meters: %{ai_generations: "event_name"}, webhook_secret: {:system, "STRIPE_WEBHOOK_SECRET"}`.
- [ ] `AuroraMeter.Pro.Webhook` (a `Plug`) — `Stripe.Webhook.construct_event/3` signature verify; dispatch `checkout.session.completed`, `customer.subscription.updated`, `customer.subscription.deleted` → `sync_subscription/1`. Returns 200/400 appropriately. Host mounts via `forward "/webhooks/stripe", AuroraMeter.Pro.Webhook`.
- [ ] `AuroraMeter.Pro.Stripe.Fake` — deterministic in-memory provider for tests (no network), plus fixtures of real Stripe event JSON.
- [ ] Point `config :aurora_meter, provider: AuroraMeter.Pro.Stripe` in the Pro demo/test.

**Tests (fake only, never network):** checkout returns a URL; each webhook event upserts the subscription correctly; a **signature-verification** test using `Stripe.Webhook` with a known secret (valid passes, tampered 400); unknown event types are ignored with 200.

**Verification Gate 9:** Pro `mix check` green; webhook signature test mandatory; `docs/evidence/phase-09/gate.txt`. ≥ 12 tests.

## Phase 10 — Pro usage reporting (Oban) + subscription-aligned periods

**Goal:** metered overage flows to Stripe exactly once; periods align to the subscription.

- [ ] Migration: `aurora_meter_usage_reports` (`tenant_key, feature, period_start, last_reported bigint, updated_at`; unique `[tenant_key, feature, period_start]`). Ship as a Pro installer migration + Pro test-repo migration.
- [ ] `AuroraMeter.Pro.UsageReporter` (Oban worker): for each active tenant × metered feature: `delta = usage - last_reported`; if `> 0`, `Stripe` meter-events call (`stripe_meters[feature]`, tenant's `provider_customer_id`, `value: delta`, idempotency key `=(tenant,feature,period,ts_bucket)`); then update `last_reported`. Idempotent and crash-safe (delta ledger).
- [ ] Oban cron plugin config: run every 5 min + a boundary run. Document the host's `Oban` config requirement (Pro requires the host to run Oban).
- [ ] `AuroraMeter.Pro.Period` + set `config :aurora_meter, period_source: AuroraMeter.Pro.Period` so `Period.current/2` returns subscription bounds when a subscription exists, else calendar (D11). Core's `Period` must call the configured source (add a 1-line indirection in Phase 3's `Period` — noted in ADR 0003; the seam is `Config.period_source/0` defaulting to `AuroraMeter.Period.Calendar`).

> ⚠️ **Back-edit note:** Phase 3 must ship `Period` with a `Config.period_source/0` seam (default `Calendar`). If Phase 3 was built without it, add the seam here and re-run Phase 3's gate before proceeding.

**Tests (fake provider):** delta computed correctly across two runs (second run reports only the new delta); zero-delta run makes no call; idempotency key stable within a bucket; subscription-aligned period selected when a subscription exists.

**Verification Gate 10:** Pro `mix check` green; idempotency + delta tests mandatory; `docs/evidence/phase-10/gate.txt`. ≥ 10 tests.

## Phase 11 — Pro rollups + hosted dashboard + CSV export

**Goal:** history and a UI worth paying for.

- [ ] Migration: `aurora_meter_rollups` (`tenant_key, feature, bucket_kind ("day"|"month"), bucket_start date, value bigint`; unique `[tenant_key, feature, bucket_kind, bucket_start]`).
- [ ] `AuroraMeter.Pro.Rollup` (Oban daily): aggregate `counters` → day and month buckets via `Storage.stream_counters/1`; upsert rollups.
- [ ] `AuroraMeter.Pro.Live.Dashboard` — a mountable LiveView: per-tenant current usage (live via the core PubSub topic) + historical bars from rollups; an admin overview across tenants. Keep charts dependency-free (inline SVG bars); **do not** add a charting dep in v1.
- [ ] `AuroraMeter.Pro.Export` — a controller action / function producing CSV of a tenant's usage for a range.

**Tests:** rollup aggregation correctness (seed counters across days → assert day+month buckets); dashboard renders live + historical (Floki); CSV shape.

**Verification Gate 11:** Pro `mix check` green; `docs/evidence/phase-11/dashboard.png`; `docs/evidence/phase-11/gate.txt`. ≥ 10 tests.

## Phase 12 — Pro quota alerts + reconciliation

**Goal:** proactive limit alerts and drift detection.

- [ ] Migration: `aurora_meter_alerts` (`tenant_key, feature, period_start, threshold int, notified_at`; unique — dedupe per period/threshold).
- [ ] Alert hook: on flush/broadcast, when `usage/limit` crosses configured thresholds (default `[80, 100]`), emit `[:aurora_meter, :alert]` telemetry and, if `config :aurora_meter_pro, alert_webhook:` set, POST a signed JSON payload once per (tenant, feature, period, threshold).
- [ ] `AuroraMeter.Pro.Reconcile` (Oban, optional/off by default): best-effort compare local period totals vs Stripe meter summaries; log/telemetry drift beyond a tolerance. Never mutates.

**Tests:** threshold fires exactly once per period/threshold (dedupe); webhook payload shape + signature; reconcile flags injected drift (fake provider).

**Verification Gate 12:** Pro `mix check` green; dedupe test mandatory; `docs/evidence/phase-12/gate.txt`. ≥ 8 tests.

## Phase 13 — Pro hardening + **release `v0.1.0`**

**Goal:** documented, licensed, distributable Pro.

- [ ] Dialyzer/credo clean; specs+docs on all public Pro functions.
- [ ] `README.md` (install from the private hex repo, Oban requirement, config, the free↔Pro boundary table), `docs/` guides (billing, usage-reporting, dashboard, alerts), `CHANGELOG.md` → `0.1.0`.
- [ ] `docs/RELEASE.md` — **manual** steps: set up a private hex repo (`mix hex.repo add` / org repo, oban.pro-style), publish, license-key issuance. Flag as human-run business ops; do not automate credentials.
- [ ] Pro `demo/` (or extend the core demo behind a flag) exercising checkout → webhook → metered reporting with the fake provider in CI and real Stripe test keys locally (human-run, documented).

**Verification Gate 13:** Pro `mix check` green on the matrix; end-to-end fake-provider flow test (subscribe → track over included → reporter sends delta → dashboard shows it) passes; `git tag v0.1.0`; `docs/evidence/phase-13/gate.txt`.

## Phase 14 — Integration proof + launch handoff

**Goal:** prove the "extracted from production" moat and hand marketing a real story.

- [ ] Wire `aurora_meter` into a **real** product in the catalog (PHX SaaS Starter *or* the AI Document Starter): add the dep, define plans, gate one real feature with `with_quota`, add a `/usage` page. Document under `docs/evidence/phase-14/` with screenshots. (Follow the storefront's product-workspace workflow — this is a change in *that* product repo, not the storefront.)
- [ ] Draft the go-to-market assets (do **not** publish — hand to the owner): a landing page section, an ElixirForum "Show & Tell" post, and a README badge. Note the free core is the top-of-funnel like Aurora UI.
- [ ] Storefront catalog: leave a **flagged TODO** (separate storefront change, per `product-workspaces/README.md`) to add Aurora Meter Pro to `lib/phx_templates/catalog.ex` and a product page — a human decides pricing.

**Verification Gate 14:** the real product boots with live metering (screenshot evidence); GTM drafts saved; `docs/evidence/phase-14/gate.txt`. **Project complete.**

---

# Appendices

## Appendix A — Canonical migration

`priv/templates/migration.eex` (core) creates (all `binary_id`, `timestamps(type: :utc_datetime_usec)`):

```elixir
create table(:aurora_meter_subscriptions, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :tenant_key, :string, null: false
  add :plan_id, :string, null: false
  add :status, :string, null: false, default: "active"     # active|trialing|past_due|canceled
  add :provider, :string
  add :provider_customer_id, :string
  add :provider_subscription_id, :string
  add :current_period_start, :utc_datetime
  add :current_period_end, :utc_datetime
  timestamps(type: :utc_datetime_usec)
end
create unique_index(:aurora_meter_subscriptions, [:tenant_key])

create table(:aurora_meter_counters, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :tenant_key, :string, null: false
  add :feature, :string, null: false
  add :period_start, :utc_datetime, null: false
  add :value, :bigint, null: false, default: 0
  timestamps(type: :utc_datetime_usec)
end
create unique_index(:aurora_meter_counters, [:tenant_key, :feature, :period_start])

create table(:aurora_meter_events, primary_key: false) do            # :durable features only
  add :id, :binary_id, primary_key: true
  add :tenant_key, :string, null: false
  add :feature, :string, null: false
  add :quantity, :integer, null: false, default: 1
  add :metadata, :map, null: false, default: %{}
  add :inserted_at, :utc_datetime_usec, null: false
end
create index(:aurora_meter_events, [:tenant_key, :feature, :inserted_at])
```

Pro adds (Phases 10–12): `aurora_meter_usage_reports`, `aurora_meter_rollups`, `aurora_meter_alerts` (columns per those phases). `config/test.exs` → `AuroraMeter.TestRepo`, `hostname: "localhost", port: 5490, database: "aurora_meter_test", pool: Ecto.Adapters.SQL.Sandbox`.

## Appendix B — Config & deps reference

**`NimbleOptions` schema (`AuroraMeter.Config`):**

| Key | Type | Required | Default |
|---|---|---|---|
| `:repo` | `atom` (Ecto repo) | ✅ | — |
| `:pubsub` | `atom` (PubSub server) | ✅ | — |
| `:plans` | `atom` (module using `AuroraMeter.Plans`) | ✅ | — |
| `:tenant` | `atom` (impl of `AuroraMeter.Tenant`) | — | `AuroraMeter.Tenant.Default` |
| `:default_plan` | `atom` | — | `:free` |
| `:storage` | `atom` (impl of `AuroraMeter.Storage`) | — | `AuroraMeter.Storage.Ecto` |
| `:provider` | `atom` (impl of `AuroraMeter.Billing.Provider`) | — | `AuroraMeter.Billing.Noop` |
| `:period_source` | `atom` | — | `AuroraMeter.Period.Calendar` |
| `:flush_interval` | `pos_integer` (ms) | — | `5_000` |
| `:broadcast_interval` | `pos_integer` (ms) | — | `1_000` |

**Core deps (`mix.exs`):** `ecto_sql ~> 3.10`, `postgrex >= 0.0.0`, `phoenix_pubsub ~> 2.1`, `telemetry ~> 1.2`, `nimble_options ~> 1.1`, `jason ~> 1.4`, `phoenix_live_view "~> 0.20 or ~> 1.0"` *(optional: true)*, `phoenix_html "~> 3.3 or ~> 4.0"` *(optional: true)*. Dev/test: `ex_doc` (dev, runtime: false), `credo` (dev/test, runtime: false), `dialyxir` (dev, runtime: false), `stream_data` (test), `mix_audit` (dev/test, runtime: false), `floki` (test).

## Appendix C — Telemetry events

`[:aurora_meter, :track]` `%{count}` `%{tenant_key, feature, qty}` · `[:aurora_meter, :flush]` `%{count, duration}` `%{}` · `[:aurora_meter, :broadcast]` `%{count}` `%{}` · `[:aurora_meter, :reserve]` `%{}` `%{tenant_key, feature, result}` · Pro: `[:aurora_meter, :usage_report]` `%{delta}` `%{tenant_key, feature}` · `[:aurora_meter, :alert]` `%{threshold}` `%{tenant_key, feature, period_start}`.

## Appendix D — Public API reference (signatures)

**Core:** `track/2,3,4 :: :ok` · `usage/2 :: non_neg_integer` · `usage_all/1 :: %{atom => non_neg_integer}` · `remaining/2 :: non_neg_integer | :unlimited` · `check/2 :: :ok | {:error, :limit_exceeded | :not_entitled}` · `allowed?/2 :: boolean` · `entitled?/2 :: boolean` · `with_quota/3,4 :: {:ok, term} | {:error, :limit_exceeded | :not_entitled}` · `reserve/2,3 :: :ok | {:error, :limit_exceeded}` · `subscribe/2 :: {:ok, Subscription.t} | {:error, term}` · `plan/1 :: Plan.t`. **Billing facade:** `Billing.checkout/2,3`, `Billing.portal_url/1,2` → `{:ok, String.t} | {:error, term}`. All take `tenant :: term` as arg 1.

## Appendix E — Stripe mapping

`checkout.session.completed` → create/verify subscription (set `provider_customer_id`, `provider_subscription_id`) · `customer.subscription.updated` → status + period bounds · `customer.subscription.deleted` → `status: "canceled"`. Metered: `stripe_meters[feature] => meter event_name`; reporter posts `billing/meter_events` with `{event_name, payload: %{stripe_customer_id, value: delta}, identifier: idempotency_key}`.

## Appendix F — CI workflow (core)

Mirror `product-workspaces/free_ui_kit/.github/workflows/ci.yml`, with: a `postgres:16` service (`ports: 5432:5432`, health-checked; `config/test.exs` uses `System.get_env("DB_PORT", "5432")` so CI uses 5432 and local uses 5490), steps `deps.get → format --check-formatted → compile --warnings-as-errors --force → deps.unlock --check-unused → credo --strict → dialyzer → test → docs (1.18 only) → mix hex.audit → mix deps.audit`; matrix `{1.15/25, 1.18/27}`; a `gitleaks` secret-scan job. Cache `deps` + `_build` + `priv/plts` keyed on `mix.lock`.

## Appendix G — ADR index & glossary

**ADRs:** `0001-resolved-decisions` (D1–D22), `0002-ets-counter-substrate` (D7), `0003-buffered-vs-durable-and-period-seam` (D8/D11). **Glossary:** *tenant* = the billable entity (org/user/account) resolved to a `tenant_key`; *feature* = a metered/gated capability (an atom); *period* = the billing window a counter belongs to; *reserve* = atomic increment-then-check used by hard limits; *buffered* = ETS-first, flushed to DB on interval; *durable* = also event-logged synchronously.

## Appendix H — AGENTS.md contract (verbatim)

Copy this into `AGENTS.md` in Phase 0.

```markdown
# AGENTS.md — Aurora Meter build & contribution contract

Authoritative for anyone (human or agent) changing Aurora Meter. CLAUDE.md points here. Read fully before writing code.

## What Aurora Meter is
A Phoenix/Elixir library that meters usage, enforces plan entitlements, and (Pro) bills via Stripe — living inside the host app, which owns its data. The moat is ETS-backed real-time metering. Follow plan.md phase by phase; never skip a Verification Gate.

## Commands
mix deps.get · mix compile --warnings-as-errors · mix credo --strict · mix dialyzer · mix test · mix format --check-formatted · mix check (all of the above). Do not run mix inside a parallel task sharing _build.

## Module conventions
- One responsibility per module; namespace AuroraMeter.* (core), AuroraMeter.Pro.* (pro).
- Every public function: a @spec, a @doc with a purpose line and an ## Examples block. @type t on every struct.
- snake_case verbs/nouns. No stringly-typed options — validate with NimbleOptions.
- The hot path (track/reserve) never touches the database. ETS only; the DB is written by the Flusher on an interval.
- Tenants are opaque terms resolved via AuroraMeter.Tenant.to_key/1 — never assume they are strings/integers.
- Storage and Billing.Provider are behaviours; never call Ecto or Stripe directly outside their adapters.

## Definition of done (every change)
1. mix check is green (format, warnings-as-errors, credo --strict, dialyzer, test, docs).
2. New public functions have specs, docs, and tests. Money/limit logic has a concurrency test.
3. Evidence saved under docs/evidence/phase-NN/.
4. No scope creep beyond plan.md §3. New forks become an ADR under docs/adr/ before coding.

## Prohibited shortcuts
- No calling the real Stripe API in tests — use AuroraMeter.Pro.Stripe.Fake.
- No GenServer-per-tenant counters (use ETS update_counter). No DB writes on the hot path.
- No secrets in the repo. No telemetry/tracking that phones home. No email gate on source.
- No swallowing errors to make a gate pass. Fix the cause.
```
