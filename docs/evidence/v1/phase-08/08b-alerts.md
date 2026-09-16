# 08b: the alert examples, and where every number comes from

Build unit **08b**, task **08.05**. Core SHA at start `9284866`
(`aurorameter-v1`), Pro `58ce8a9`. Toolchain: Elixir 1.20.1 on Erlang/OTP
29.0.1. Written 2026-09-16.

Two pages ship: `core:docs/alerts.md` (five examples) and
`pro:docs/alerts.md` (six). Both open with the same statement, and it is the
point of the task rather than a disclaimer on it:

> **These are worked deployment examples, not service level objectives, not
> defaults, and not thresholds this project can set for your load.**

The reason a threshold cannot be a default is that every one of them is a
multiple of a configuration value the host owns. The pages therefore show the
derivation rather than the number, and each page's opening table lists the
defaults its arithmetic assumes.

## 1. The configuration each threshold depends on

Read from `AuroraMeter.Config` on this tree, not from memory:

| Key | Default | Source |
|---|---|---|
| `flush_interval` | 5,000 ms | `docs/configuration.md`, `AuroraMeter.Config.flush_interval/0` |
| `broadcast_interval` | 1,000 ms | `AuroraMeter.Config.broadcast_interval/0` |
| `metrics_interval` | 10,000 ms | `AuroraMeter.Config.metrics_interval/0` (08a) |
| `uncertainty_horizon_seconds` | 82,800 (23 h) | `AuroraMeter.Pro.Config.uncertainty_horizon_seconds/0` |

Note the test environment sets `metrics_interval: 0` (08a, X320). That is a test
configuration, not the default, and the pages quote the default.

## 2. Core, five examples

| # | Signal | Threshold | Derived from | Severity | Runbook |
|---|---|---|---|---|---|
| 1 | `aurora_meter.store.gauge.oldest_pending_age_ms` | `> 2 x flush_interval`, sustained 3 sampling intervals | a healthy node empties the dirty set every `flush_interval`, so twice it cannot be crossed by one slow flush; three samples at `metrics_interval` cannot fire on one unlucky reading. Defaults: 10,000 ms for 30 s | warning | `operations.md#4-when-the-database-is-unavailable` |
| 2 | `[:aurora_meter, :flush, :error]`, or `pending_batch_age_ms` | 3 consecutive `flush_interval` windows, or age `> 60,000 ms` | one failure during a database restart is normal and the batch is retried under the same receipt; the **same** batch a minute later is a retry that is not converging. 60 s is twelve `flush_interval`s at the default, and the page says to use a multiple of your own | page | same |
| 3 | pending holds older than 24 h | `> 0` | 24 h is the age at which `reconcile_holds/1`'s default policy still says `:keep`, so a non-zero count means nobody has decided | warning | `operations.md#3-recovering-stale-holds` |
| 4 | `aurora_meter.cluster.lag.since_last_message_ms` while `peers > 0` | `> 10 x broadcast_interval` | gossip converges in one `broadcast_interval` and heals through totals in one `flush_interval`; ten intervals of silence from a node that **has** peers is PubSub not delivering. Defaults: 10,000 ms | warning | `clustering.md#guarantees` |
| 5 | `[:aurora_meter, :record, :stop]` with `result: :conflict` | any non-zero rate | two different payloads claimed one event id. Always a caller defect, never self-healing, so there is nothing to tune | warning | `operations.md#9-a-health-check-worth-having` |

`peers > 0` in rule 4 is part of the signal rather than decoration: a
single-node deployment has nobody to hear from and would otherwise alert for
ever.

## 3. Pro, six examples

| # | Signal | Threshold | Derived from | Severity | Runbook |
|---|---|---|---|---|---|
| 1 | `aurora_meter.pro.outbox.gauge.oldest_pending_age_seconds` | `> 2 x` the deliverer's cron interval | the deliverer empties the due items every run | warning | `outbox.md` |
| 2 | `aurora_meter.pro.outbox.gauge.uncertain` | `> 0` | an uncertain item is by definition one no automated retry can resolve | page in hours | `recovery.md` |
| 3 | `[:aurora_meter, :pro, :reconciliation, :difference]` | any non-zero `observed - expected` | a difference is a bug in the export path or a change made in the provider's own dashboard; both end up on an invoice | page | `reconciliation.md` |
| 4 | `aurora_meter.pro.outbox.gauge.quarantined` | **increasing**, not a level | quarantine is a mapping, mode or window problem and never clears itself, so a level that is not moving is a backlog somebody has already seen | warning | `operations.md` |
| 5 | a credit account pending longer than `uncertainty_horizon_seconds` | the horizon itself | past it, money may have left a card with no credit granted | page | `recovery.md` |
| 6 | `[:aurora_meter, :pro, :provider, :stop]` duration by `result` | **none: it is a chart** | one span is one HTTP attempt, so the distribution is the provider's latency and not Pro's retry policy. A slow provider that is keeping up is not an incident | n/a | n/a |

Pro rule 1 carries a second half that is not a threshold: **alert on the
absence** of `[:aurora_meter, :pro, :outbox, :gauge]`. The gauge is emitted only
when the aggregate query succeeds (04b, reaffirmed by 08a), so a paused
deliverer emits nothing rather than a zero, and a zero backlog from a queue that
is not running is the most misleading number the package could produce.

## 4. The "do not alert on this" sections

Core:

* buffered usage lost with a node: a documented property of the buffered path
  (`guarantees.md`), which is why the dashboard page calls the buffer a loss
  window rather than pending work;
* a single flush error: the batch is retained and retried under the same
  receipt;
* throughput on one hot key: ETS row serialisation by design;
* `result: :duplicate`: idempotent replay is the feature working.

Pro:

* a retryable delivery failure;
* a `:duplicate` webhook;
* a non-zero quarantine level that is not moving (rule 4 is the rate);
* a single `[:aurora_meter, :pro, :provider, :exception]`.

## 5. What holds these pages to the code

Both files are in the docs extras (`mix.exs`), so `mix docs --warnings-as-errors`
fails on a broken reference in either. Both are under `docs/`, so both are read
by `DocsClaimsTest` (G01: no page claims a bounded loss window, exactly-once
delivery or a global quota guarantee) and by `DocExamplesTest` (every `elixir`
block parses and every `AuroraMeter*` name it uses exists).

What is **not** mechanically checked is the arithmetic. "2 x flush_interval is
10,000 ms" is a sentence, and nothing in the suite recomputes it. That is a
named gap rather than an oversight: the alternative is a test that duplicates
the multiplication, which would pass whenever the page and the test made the
same mistake. The mitigation is that every threshold names the configuration
key it multiplies, so a reader with `docs/configuration.md` open can check it in
one step.
