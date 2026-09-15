# 06b: how long the wallet migration holds a balance row

Build unit 06b. The number an operator needs in order to size a maintenance
window, measured rather than guessed. The machine-readable form is
`06b-lock-durations.json`.

## What is measured

The **lock phase**, which is the whole of the migration's exclusive work on one
wallet: opening the transaction, taking `aurora_meter_credit_balances`
`FOR UPDATE`, re-reading `lots_enabled_at`, reading anything committed since the
snapshot, verifying the folded book against the locked row, inserting the lots
and allocations, backfilling `hold_transaction_id`, updating the balance row,
running the conservation check, and committing.

It is measured with `AuroraMeter.Clock.monotonic_ms/0`, which is the reading the
clock contract reserves for an in-memory span. Neither `now/0` nor `db_now/0`
would do: both are wall clocks and both step backwards, and a duration this
short is exactly the case `architecture-map.md` section 3 says a wall clock
cannot decide.

What is **not** in the number, deliberately: reading the wallet's history and
folding it. That is the expensive part and it holds no lock, which is the whole
reason the pass is split in two. A wallet with forty thousand rows costs the
live path one short lock rather than a minutes-long stall.

## The run

Fourteen fixture wallets (`i19-fixture-wallets.md`), migrated for real, on the
package's own test database: Postgres 16 in Docker on port 5490, one BEAM, no
other load. Two further wallets were blocked and took no lock at all.

| | ms |
|---|---|
| samples | 14 |
| minimum | 4 |
| median | 5 |
| maximum | **9** |

No lock in the run exceeded the recorded maximum, which is what the acceptance
criterion asks: the maximum **is** the observed maximum, read from the same
per-wallet numbers the table is computed from, not a separate claim.

## What the number is and is not

These wallets are small: three to six ledger rows and one to three lots each.
The figure is therefore the **floor**, the cost of the transaction's fixed work,
and it is genuinely useful as a floor because it says the fixed cost is
single-digit milliseconds rather than hundreds.

It is not a bound for a large wallet, and the shape of the growth is known.
Finding X248 measured the allocator's per-write cost against lot count: at 1 lot
a debit is about 6.1 ms, at 100 lots 7.4 ms, at 1000 lots 13.2 ms, because every
operation reads and locks the wallet's whole book. The migration's lock phase
does that work once, not once per row, but its lot insert, its conservation
check and its final projection all scale with the lot count, and a lot is
created per grant.

So the honest statement for an operator is:

- the fixed cost of cutting one wallet over is under 10 ms on this hardware;
- the per-wallet cost grows with the number of **grants** the wallet has ever
  received, not with the number of ledger rows, because the snapshot and the
  fold are outside the lock;
- `--max-rows` (default 50,000) bounds the fold rather than the lock, and a
  wallet above it is deferred and paused rather than attempted;
- **nobody has yet measured a wallet with thousands of lots**, and the
  distribution of lot counts across a real installed base is unknown. X248 asks
  this unit's report to supply that distribution and it cannot: these are
  synthetic wallets. It is 11a's populated fixtures, and ultimately the first
  real customer database, that will answer it.

## Reproducing it

    MIX_ENV=test mix run tmp/v1/06b-evidence.exs

writes `06b-lock-durations.json`, `06b-shadow.json`, `06b-migrate.json` and
`06b-fixture-wallets.json`. It is a script rather than a test, because a test
that writes committed evidence on every run rewrites its own evidence
(`open-findings.md` X135, X149).
