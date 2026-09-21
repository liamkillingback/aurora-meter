# Draft release record: `aurora_meter` 1.0.0

For step 12.07. Ready to paste. It leads with migration impact and the compatible range,
which G11 bullet 3 requires. The authoritative long form is the `[1.0.0]` section of
`CHANGELOG.md`; this is the release record that points at it.

---

## Aurora Meter 1.0.0

**Upgrading: read this before you deploy.**

`AuroraMeter.Migration.latest_version()` is now **10**. Both 0.4.0 and the 0.5.0 transition
release carried **6**, so an existing install has four schema versions to apply and two data
tasks to run between them. The full route, with what each step locks and what it does to
your data, is in [`docs/upgrading-to-1.0.md`](docs/upgrading-to-1.0.md). The short form:

1. Generate the bounded upgrade migrations, one file per version rather than one file that
   loops:
   `mix aurora_meter.gen.migration --upgrade -r MyApp.Repo`
2. Apply version 7, then run `mix aurora_meter.events.backfill` **before** version 8.
   Version 8 adds a unique index on `event_id` and validates six check constraints, and a
   legacy durable event has no `event_id`, so the index cannot be built until the backfill
   has given every row one. The backfill is idempotent.
3. Apply 8 and 9, then `mix aurora_meter.credits.migrate_lots`. **A wallet the task declines
   stays on the legacy writer and keeps working**, with the reason recorded on its
   checkpoint row.
4. Apply version 10 and call `MyApp.Plans.register!/0` once, which the installed supervisor
   child does at boot.

**Two quiescence points, and they are not advisory.**

- **Stop every writer that calls `AuroraMeter.record/4` or `track(..., durable: true)`
  before version 8.** The backfill and the unique index cannot agree while rows keep
  arriving without an identity. Measured rather than assumed: a 0.4.0 durable writer
  restarted after version 8 raises `ERROR 23502 not_null_violation` on `event_id`, five
  times out of five, while the buffered path in the same conditions completed every action
  with none raised.
- **Have every node on 1.0.0 before the wallet cutover.**

**Rollback boundary.** Rolling back to the previous image is safe after schema versions 7,
8 (with no `durable: true` writer), 9 and 10. **It is not safe after the wallet cutover:
after that, only a forward fix or a data restore applies.** Published Hex artifacts are
immutable; a defect is fixed with a new patch version, never a replaced tarball and never a
moved tag.

## Compatible versions

| | |
|---|---|
| Elixir | `~> 1.15` |
| Erlang/OTP | 26 or later |
| Postgres | tested on 16; declared floor 13 |
| `aurora_meter_pro` | `~> 1.0` pairs with this release. Older Pro versions do not |
| Optional | `phoenix_live_view ~> 1.0`, `phoenix_html ~> 3.3 or ~> 4.0`, `telemetry_metrics ~> 0.6 or ~> 1.0`, `phoenix_live_dashboard >= 0.8.0 and < 0.9.0`, `oban ~> 2.17`, `igniter ~> 0.8` |

Every optional integration stays optional: the package compiles and every core function
works with none of them present, which is invariant I20 and is proved by a CI leg that
builds with all of them absent.

## Install

```elixir
def deps do
  [{:aurora_meter, "~> 1.0"}]
end
```

```bash
mix aurora_meter.install
```

The installer writes the configuration, the supervisor child (after your Repo and PubSub),
a starter plans module and the migration.

```elixir
# count, gate and bill in one call
AuroraMeter.with_quota(tenant, :api_calls, fn ->
  do_the_work()
end)
```

## Known limits in this release

- **A wallet that has ever combined promotional credit with a hold may decline the lot
  migration.** The legacy `promotional` figure cannot see that a hold has reserved part of
  a promotion, so the two accounts genuinely disagree and the lots are the more accurate of
  the two. In generated histories this was the common case, not the rare one. Such a wallet
  blocks with `promotional_divergence`, keeps working on the legacy writer, and is listed in
  the per-wallet report. `docs/upgrading-to-lots.md` carries the reason and the advice.
  **There is no safe automatic answer; decide it with the customer's history in front of
  you.**
- **Usage recorded after a subscription ends is counted and settled by nobody.** A cancelled
  tenant's `track/4` buckets into the calendar month while the reporter reads the
  subscription's own window, so nothing is staged. Nobody is over-billed; the usage
  accumulates where nothing will settle it.
- **Flush receipt timestamps come from the node clock.** A node whose clock is badly skewed
  can misprune. A database default lands in a later schema version.
- **Cluster counters converge; they are not strict across nodes.** Single-node strictness
  and cross-node convergence are what is promised, and both were held over a 20 hour
  multi-node run under repeated node kills.
- An upgrade of an install with a 20 GB events table needs roughly **70 GB** of headroom.

## Evidence

Invariants I01 to I22 with their named tests and evidence, the migration matrix over every
published pairing, the interrupt and backup rehearsals, the rollback matrix and the soak are
in `docs/evidence/v1/` and in the storefront's cross-repository release manifest.

Every published schema pairing was populated with real money and upgraded end to end:
core 1 to 10, core 2 to 10, core 2 to 10 with Pro 1 to 11, and core 6 to 10 with Pro 9 to
11. **No pairing lost money and every pairing could be upgraded.**
