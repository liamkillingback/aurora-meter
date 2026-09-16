# Phase 3 — metering throughput benchmark

> **Historical.** Measured against the 0.3 four-column counter row
> `{key, value, pending_flush, pending_gossip}`, which 0.4.0 replaced with a six
> column row when it added `remote` and `reserved`. The task that produced these
> figures then crashed at its own summary line in every release afterwards,
> because it seeded the old row shape and read the new one (`open-findings.md`
> C7), so nothing on this page has been reproducible since 0.4.0. The figures
> here are **not** current results, and they are quoted nowhere that makes a
> claim.
>
> Superseded by `docs/evidence/v1/phase-08/` (build unit 08c), which measures
> every path on a named machine and toolchain and labels every figure micro or
> end to end. This page is kept rather than deleted because it is the clearest
> surviving explanation of why the old number existed and why it no longer
> applies.


Machine: WSL Ubuntu-24.04 (dev laptop) · Elixir 1.20 / OTP 29 (Homebrew).
Command: `mix aurora_meter.bench 8 500000`

## Result — distinct key per worker (realistic)

Load spread across many `{tenant, feature, period}` counters, as in production:

```
procs:        8
per proc:     500000
total incrs:  4000000
sum of keys:  4000000  (correct: true)
elapsed:      504.1 ms
throughput:   7935406 incr/s   (~7.9M/s)
```

## Result — single hot key (pathological worst case)

All 8 workers incrementing **one** counter row:

```
throughput:   ~53000 incr/s
```

## Interpretation

Aggregate metering throughput is millions of increments/second because real load
spreads across many counter keys. A single counter is bounded by ETS single-row
write serialization (~50k/s) — still far above any one tenant's realistic event
rate. The hot path is pure ETS (`update_counter` + dirty-mark); the database is
touched only by the interval flusher and the one-time cold-key seed. This is the
BEAM-metering moat, measured.

## 0.3 re-run (2026-09-07) — cluster-wide counter rows

Same machine class (WSL Ubuntu-24.04 dev laptop, Elixir 1.20 / OTP 29), same
command: `mix aurora_meter.bench 8 500000`, `history: false` so only the period
counter path is measured (day buckets would seed from the absent database).

```
procs:        8
per proc:     500000
total incrs:  4000000
sum of keys:  4000000  (correct: true)
elapsed:      726.5 ms
throughput:   5505759 incr/s   (~5.5M/s)
```

0.3 rows are `{key, value, pending_flush, pending_gossip}` and every bump is one
`:ets.update_counter/3` over three positions (plus the dirty/touched marks, as
before). That is the whole cost of cluster-wide counting: roughly 30% of the 0.2
figure, still millions of increments per second and still zero database writes
on the hot path. The README quotes this number, not the 0.2 one.
