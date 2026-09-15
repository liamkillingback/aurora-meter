# 05a: the optional core Oban integration

Build unit 05a, V1 tasks **05.01** (scheduler map) and **05.02** (optional core
integration). Decisions D03, D12, D13. Invariants I16, I20, I11, I12.

## Identity

| Item | Value |
|---|---|
| Core SHA at start of work | `8fa7128b5f6b5b6e1197ea11e811bd692c5cdd50` (`v0.4.0-18-g8fa7128`, `aurorameter-v1`) |
| Pro SHA at start of work | `80306baa4896af3a9b2dc83ef93ed7b13a59d025` (`v0.3.0-20-g80306ba`) |
| Storefront SHA | `730fea4963cf09b0396dac8197fb2a8f8074fbd1` |
| Core package version | 0.5.0, unchanged |
| Core schema `@latest` | **8**, unchanged. This unit creates, alters and reads no table. |
| Pro package version | 0.3.0 on this branch, unchanged |
| Pro schema `@latest` | **10**, unchanged |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (`erts-17.0.1`) |
| OS | Ubuntu 24.04 under WSL2 |
| Postgres | 16.13, container `aurora-meter-pro-testdb`, port 5490 |
| Oban resolved in core | 2.24.1 (optional) |
| Oban resolved in Pro | 2.23.0 (required, unchanged) |

## Test counts

| Package | Before | After | Note |
|---|---|---|---|
| core | 1252 passed, 3 excluded | **1303 passed, 4 excluded** | +51. The extra exclusion is the new `:headless` test. |
| core, headless leg | not previously run for this unit | **1244 passed** with `--include headless` | the `AuroraMeter.Oban*` test files compile to nothing there, by the same guard as the code |
| Pro | 863 | **874** | +11 |

## New public surface

| Entry | Why public |
|---|---|
| `AuroraMeter.Oban.queue/0` | a host sizes the queue and needs its name |
| `AuroraMeter.Oban.cron_entries/1` | the recommended crontab; 05c's installer and a hand-managed host both read it |
| `AuroraMeter.Oban.validate!/1` | called from the host's `Application.start/2` |
| `AuroraMeter.Oban.ConfigError` | what `validate!/1` raises |
| `AuroraMeter.Oban.CreditExpiry` | named in a host's crontab |
| `AuroraMeter.Oban.HoldReconciliation` | named in a host's crontab |
| `AuroraMeter.Oban.EventsReplay` | enqueued by an operator |
| `AuroraMeter.Oban.RecurringGrants` | named in a crontab from 06d |
| `AuroraMeter.Oban.PlanTransitions` | named in a crontab from 07b |

`__registry__/0`, `result/1`, `available?/1`, `short_name/1`, `options/1` and
`translate/1` are `@doc false`. **No new configuration key**: `validate!/1`
takes the host's Oban configuration as an argument rather than reading one, so
02b's "unknown keys fail at boot" rule is untouched.

## Commands

Every command, its exit code and its log is in `05a-commands.txt`. The two that
matter:

| Command | Exit | Log |
|---|---|---|
| `mix check` (core) | **0** | `05a-core-check.log` |
| `AURORA_HEADLESS=1 mix compile --warnings-as-errors --force` then `mix run -e ...` then `mix test --include headless` | **0**, and `headless ok` | `05a-headless.log` |

## I16: two nodes running the same schedule

**Nothing in this unit provides mutual exclusion, and nothing needs to.**

Each `perform/1` is one call to an operation plus a mapping of its result. No
worker opens a transaction, takes a lock, holds state between runs, or reads a
clock to decide anything. Two nodes running one worker is therefore exactly two
callers of the operation, which is a case the operation already answers:

* `Credits.expire_due/1` locks each grant row `FOR UPDATE` and re-reads
  `expired_at` inside the lock, refusing `:already_expired`.
* `Credits.reconcile_holds/1` applies each decision through `settle/3` or
  `release/2`, which lock the hold row and re-read `status = 'pending'` inside
  it, reporting `:already_closed` to the loser.

There is no lease, no fence and no duration in either, which matters here rather
than being a stylistic preference: finding **X100** measured `clock_timestamp()`
stepping backwards up to 439 ms on a 32.5 second cadence on this hardware, so a
sub-second duration comparison could be inverted. A row lock has no clock in it.

The one duration this unit introduces is `HoldReconciliation`'s
`older_than_seconds`, default **3600**. It selects candidates and decides
nothing: a hold past the cutoff is one the host is **asked about**, never one
that is released. The bound being relied on is minutes to hours against a
measured worst step of 439 ms, four orders of magnitude apart.

`unique` on each worker is **defence in depth**. Measured, not assumed: see the
X125 control below.

## X125: which layer answered, and the control that says so

The duplicate-run property has two candidate guards: Oban's job uniqueness and
the ledger's row-lock re-read. A test of one that leaves the other in place
proves nothing about either.

`AuroraMeter.ObanConcurrencyTest.UnguardedExpiry` is
`AuroraMeter.Oban.CreditExpiry` with `unique` removed and nothing else changed.
Run through the same forced race, its result is **identical**: one `:expire`
row, `{:ok, 1}` to the winner and `{:ok, 0}` to the loser.

**So this unit's concurrency tests do not test Oban's uniqueness, and the
evidence says so rather than recording a pass for it.** What answered is the
`expired_at` re-read inside the grant row's `FOR UPDATE`, which is the layer the
loser's `{:ok, 0}` comes from. Uniqueness saves a duplicate run's work; it is
not what keeps the ledger right, and there is no Oban instance in these tests
for it to act in.

A second, smaller control is in `validate!/1`'s conflict check: a crontab
carrying both `AuroraMeter.Oban.CreditExpiry` and
`AuroraMeter.Pro.Credits.Expirer` names **two different modules**, so the
duplicate-entry check cannot be what refuses it, and the test asserts the
message names the conflict and **not** the duplicate, plus that exactly one
problem was reported. The paired positive control is that either worker alone is
accepted.

## X182: how often the branch actually ran

The assertion that matters, "the losing run expired nothing", lives in a branch
only one side of a race reaches. Left to chance it **never runs**.

Measured over ten seeds, `05a-race-distribution.log`:

| Test | Rendezvous | Branch executions |
|---|---|---|
| volume: 12 grants, two runs, no rendezvous | none | **0 of 10 seeds** produced a split. Every seed was `[12, 0]` or `[0, 12]`: one run took the whole batch and the other found nothing to do. |
| `the CreditExpiry run that loses the grant row lock expires nothing` | forced | **10 of 10**, `waiters: 2, winner: 1, loser: 0` |
| `the same is true with Oban's uniqueness removed` | forced | **10 of 10**, identical |

The rendezvous: a third connection holds the grant row `FOR UPDATE`; both runs
select it as due (they must, because nothing can set `expired_at` while that
lock is held) and queue behind it; the holder is released **only after Postgres
itself reports two backends waiting on a lock**. "Both runs listed this grant"
is therefore observed, not hoped for, and the loser's `{:ok, 0}` is the
`already_expired` branch answering once per call.

One measurement was needed to build it: `pg_locks` filtered by `database`
counts **zero** waiters, because a backend queued behind a row lock waits on the
holder's `transactionid` and a `transactionid` lock carries no `database`. The
first version of the rendezvous timed out at fifteen seconds for that reason.
`pg_stat_activity` with `wait_event_type = 'Lock'` is what works.

## D12 and I20: core without Oban

`oban` joins `phoenix_live_view`, `phoenix_html` and `igniter` in core's
`optional_deps/0`, which `AURORA_HEADLESS=1` empties. On that build:

* `mix compile --warnings-as-errors --force` exits 0;
* `Code.ensure_loaded?(AuroraMeter.Oban)` and each of the five workers and the
  exception are **false**, while `AuroraMeter.Credits.expire_due/1`,
  `reconcile_holds/1` and `AuroraMeter.Events.Replay.run/1` are all still
  exported;
* `mix test --include headless` passes, 1244 tests.

Both directions are asserted inside the suite as well as in the script:
`AuroraMeter.OptionalIntegrationsTest` asserts the namespace is present exactly
when `Oban` is, on every leg, and `AuroraMeter.HeadlessTest` asserts its absence
on the one leg where absence is true.

## What this unit did not do

* **No job controls**: no batching, no cursor, no pause flag, no `max_attempts`
  tuning beyond the table above, and no installer. All 05c.
* **No retention**, which is 05d, and **no operational runbook**, which is 05e.
* **No change to `AuroraMeter.Credits`, `AuroraMeter.Credits.Ledger`,
  `AuroraMeter.Credits.Reconciliation` or any Pro worker's `perform/1` other
  than the deprecated Expirer.** 06a owns the ledger and 05c owns Pro's workers.
* **No telemetry**: the workers emit nothing of their own. 08a adds the gauges.
* **No real provider call**, and no Stripe traffic of any kind.
