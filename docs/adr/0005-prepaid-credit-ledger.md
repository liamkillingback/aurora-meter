# 0005 — Prepaid credit ledger: integer micro-dollars, row lock, repo-direct

- Status: Accepted
- Date: 2026-09-10

## Context

Plan counters answer "how many of X this period"; a growing share of the
audience prices per unit instead (AI tokens, requests, gigabytes) and needs
"how much money is on account". That is a different data structure — a
balance with reservations and a log — with different guarantees: it must never
overspend under concurrency, must survive retried webhooks without double
funding, and must be auditable. It is also the thing Stripe top-ups (Pro) need
to land in.

## Options considered

1. **Units in cents.** Familiar, but a token costs thousandths of a cent, so
   every AI settlement would round to zero or need a float.
2. **Units as `Decimal`.** Exact, but slower, and `Decimal` in every hot
   struct and telemetry measurement; Postgres `numeric` arithmetic on the row
   lock path.
3. **Integer micro-dollars (1e-6 USD) as `bigint`.** Exact, cheap, and a
   `bigint` holds ±9.2 trillion dollars. Convert at the edges.
4. **Balance in ETS like the counters.** Fast, but money must not live in a
   buffer that a crash can lose, and the ETS substrate is per-node.
5. **Optimistic concurrency (`version` column, retry).** Works, but retries
   under contention and every caller needs a retry loop.
6. **`SELECT ... FOR UPDATE` on the tenant's balance row.** Serialises all of
   a tenant's writes on one lock; no retries; the transaction is a few
   statements long.
7. **Through the `Storage` behaviour.** Keeps the "never call Ecto outside an
   adapter" rule, but the callback would be "run this locked read-compute-write
   atomically", which only a SQL adapter can implement.

## Decision

- (3) Integer micro-dollars everywhere; `AuroraMeter.Credits.Money` converts
  cents, `Decimal` dollars and display strings.
- (6) Every write is one transaction: ensure the balance row (`insert_all ...
  on_conflict: :nothing`), lock it `FOR UPDATE`, check sufficiency against the
  locked row, append an `aurora_meter_credit_transactions` entry that
  snapshots `balance_after`/`held_after`, update the row. Settle and release
  also lock the hold row so two settlements of one hold serialise.
- (7 rejected) The ledger talks to the configured repo directly and is
  documented as requiring the Ecto storage. The rule in AGENTS.md exists so
  the metering path can be swapped; a ledger is not that path.
- Side effects (telemetry, PubSub, the low-balance handler) run after commit,
  never inside the transaction.
- `reference` is a caller-supplied idempotency key, unique per kind: a
  replayed grant returns the original entry, a replayed hold or debit is
  refused.
- Promotional credit is tracked as one figure per balance row with the
  invariant `0 <= promotional <= max(balance, 0)`, consumed before paid
  credit. Expiry removes `min(promotional, grant.amount)`, so it can never
  push a balance below zero.
- A settlement never fails for lack of credit; the balance may go negative and
  the overrun is reported. Refusing to settle would leave real cost unbilled.

## Consequences

- A tenant's ledger throughput is bounded by its row lock: hundreds of writes
  per second per tenant, which is far above any per-tenant billing rate and
  irrelevant across tenants.
- One `promotional` figure per row means overlapping promotional grants are
  not tracked separately (documented limitation; a per-grant remainder column
  is the upgrade path if it is ever needed).
- Credits are unavailable on a non-Ecto storage adapter, should one ever
  exist. Everything else in the core still works there.
- Pro's Stripe top-ups and auto-recharge are grants and a low-balance handler
  respectively; nothing in the core needs to change for them.
