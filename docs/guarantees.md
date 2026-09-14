# Guarantees and limits

This is the contract. Everything Aurora Meter promises is in the table below,
each promise with the condition that makes it true, the thing that takes it
away, the invariant it rests on and the test that proves it.

One rule governs the whole page, and it governs the rest of the documentation
too:

> A guarantee is written with the condition that makes it true, or it is not
> written.

That is why the **Proven by** column exists. A row with no test says "not yet
proven" and names the phase that will prove it. A guarantee nobody can point a
test at is not a guarantee yet, and hiding that behind confident wording is how
a customer finds out the expensive way.

Two phrases are deliberately absent from this page and from the rest of the
package documentation, and `test/aurora_meter/docs_claims_test.exs` fails the
build if either comes back. The first is a fixed loss window: buffered loss is
everything not in an acknowledged flush batch, and during a database outage
that is unbounded (G6). The second is a delivery promise stronger than
at-least-once: usage export and scheduled work are both at-least-once with
idempotent effects (G11, G12).

`docs/correctness.md` is the companion to this page: it lists every invariant
I01 to I22 with its prerequisites, its known limits and every test that holds
it. This page is the shorter, product-shaped view of the same facts.

## The table

| # | Guarantee | Exact conditions | What voids it | Invariant | Proven by |
|---|---|---|---|---|---|
| G1 | `check/2` is advisory | It reads the current local counter and returns a decision that is already stale by the time it returns. Nothing is reserved and nothing is written, so two callers can both be told `:ok` for the last unit. Use `reserve/2,3` or `with_quota/3,4` to hold capacity. | Nothing: it is advisory by design, and treating it as a gate is the mistake it cannot protect you from. | I04 (by contrast: this is the path that holds nothing) | `AuroraMeter.EntitlementsTest` / `test check/2 is advisory: two callers are both allowed the last unit and nothing is reserved` |
| G2 | `reserve` and `with_quota` are strict on one node | Admitting the work and counting it against the cap are one atomic ETS update. The cap counts completed plus pending work, and a refused reservation leaves the counter exactly as it was. | More than one node (G4). A caller killed with `:kill` (G5). | I04 | `AuroraMeter.EntitlementsTest` / `test I04 sixty concurrent with_quota calls against a limit of fifty admit exactly fifty on one node` |
| G3 | Failed tentative work is never billed | A raise, throw or exit inside a `with_quota` callback releases the reservation from the period the work was admitted in, including when the callback ran across a period boundary. Usage reporting reads persisted counters, never reservations. | The caller being killed with `:kill` (G5), which leaves the reservation but still bills nothing. | I03 | `AuroraMeter.EntitlementsTest` / `test I03 a callback that flushed and then raises is not billed` |
| G4 | Cluster counters converge, and hard caps can overshoot | Nodes exchange deltas every `:broadcast_interval` and re-base on the persisted total every `:flush_interval`. A hard cap is enforced against the local view, so a burst across N nodes can exceed the cap by what the other N minus 1 admitted within one `:broadcast_interval`, or within one `:flush_interval` when a gossip message was lost. There is no cluster-wide lock and no single serialization point for a quota decision. | A `Phoenix.PubSub` that is not distributed: every node then counts alone, and the overshoot is no longer bounded by anything. | I05 | `AuroraMeter.ClusterConvergenceTest` / `test I05 overshoot is bounded by what other nodes admitted between announcements` |
| G5 | A killed caller leaks its reservation on that node | `Process.exit(pid, :kill)` inside a `with_quota` callback leaves the reserved units occupying the cap on that node until the `Store` ETS table is rebuilt. No monitor is added, deliberately: releasing on process death could release work that is still running elsewhere. Nothing is billed, because a reservation is never persisted and never gossiped. | Nothing. This is the documented limit, not a promise, and it is stated here so it cannot be discovered in production. | I03, I04 | `AuroraMeter.KillTest` / `test I04 a killed caller's reservation continues to occupy the limit on that node` |
| G6 | Buffered loss is everything not in an acknowledged flush batch | Not one interval. Counters live in ETS and flush on the `:flush_interval` and once more on a clean shutdown. While the database is unreachable the pending set grows without bound until the database comes back or the VM stops. A `Flusher` restart keeps its pending batch, because the batch belongs to `Store`; a `Store` restart does not. | Nothing makes the window smaller. Mark the feature durable, and from 1.0.0 use `record/4`, when losing a count is not acceptable. | I01 | `AuroraMeter.KillTest` / `test I01 a Store killed before the flush loses the buffered deltas, as documented` |
| G7 | One flush batch has at most one durable effect | The flush receipt's primary key is inserted inside the same transaction as the counter and history deltas, so a batch redelivered after a lost response applies its deltas a single time. | Deleting flush receipts while a node could still retry a batch. Writing the counter tables by hand. | I01, I02 | `AuroraMeter.FlushBatchConcurrencyTest` / `test I01 twelve independent connections deliver one batch once` |
| G8 | Credit holds cannot spend the same funds twice | Every wallet write serialises on that wallet's balance row lock and sufficiency is checked under that lock, so conservation holds per wallet: the balance equals the sum of every transaction amount after every step. A refusal writes nothing and does not roll the caller's own transaction back. | Writing the ledger tables directly, which goes round the lock. | I10, I11 | `AuroraMeter.CreditsConcurrencyTest` / `test I11 fifty independent connections holding against one hot wallet admit exactly the funded count` |
| G9 | Grant expiry cannot consume unrelated funds | Expiry takes only what is left of the grant that is expiring, never below zero, and never credit that a hold has reserved. Today the proof is behavioural. The structural half, a database constraint that refuses a violating row at all, arrives with credit lots in phase 06. | Nothing in the behaviour. The limit is the strength of the proof, and it is named rather than implied. | I12 | `AuroraMeter.CreditsTest` / `test promotional credit I12 a grant expires only its own remainder` (behavioural; the structural proof is phase 06) |
| G10 | Durable recorded events are transactional | From 1.0.0. One persisted fact per `(tenant, event id)`, one projection effect, one export intent, and a conflicting payload under an identity already used is reported rather than quietly accepted. Today's `track(..., durable: true)` writes an event row and has none of those properties: it carries no identity, it is not deduplicated, and it is not what usage reporting reads. | Not applicable until it ships. Until then, read the row above as the description of what you have. | I06, I07, I09 | not yet proven (phase 03) |
| G11 | Export is at-least-once with provider-side idempotency | Requires `aurora_meter_pro`. Each send carries an identifier the provider deduplicates on, so a retry of the same window does not bill those units twice. A send whose answer never arrives leaves the item uncertain instead of being resent blindly past the provider's deduplication horizon, and an item older than that horizon is surfaced for a person rather than replayed. Aurora Meter never reports that a provider invoice was finalised or paid: it reports what it sent and what it heard back. | Editing the reporting ledger by hand. Reusing one identifier for a different window. | I15 | `pro:` `AuroraMeter.Pro.UsageReporterTest`, indexed under I15 in Pro's `docs/correctness.md` |
| G12 | Workers are at-least-once | No scheduled entry point assumes it runs a single time. Each is idempotent on its own state: a flush with nothing pending writes nothing, `expire_due/1` expires a grant once however often it runs, and `grant/3` is idempotent per reference. The host owns the scheduler; the core ships no job runner. | A scheduled job of your own that is not idempotent. Aurora Meter cannot make one so. | I16 | `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference` (the lease and checkpoint half is phase 05) |
| G13 | Periods are half-open UTC intervals | A period is `%{start: DateTime, end: DateTime, source: atom}` with both instants in `Etc/UTC`, `start` before `end`, and `start <= now < end`. An instant at `end` belongs to the next period, never to two. `Period.current!/2` validates every read and raises `AuroraMeter.Period.InvalidPeriodError` naming the source module when a custom source breaks the contract. | Nothing: an invalid period raises at first use rather than being counted into. | none (the 02c contract; see ADR 0015) | `AuroraMeter.PeriodTest` / `test P01: the interval is half-open [start, end) P01 cross-month: 2026-01-31T23:59:59.999999Z and 2026-02-01T00:00:00Z resolve to different periods whose boundary instants are equal` |
| G14 | Undeclared features follow the configured policy | `undeclared_feature_policy` is `:allow`, `:warn`, `:deny` or `:raise`. The 0.5.x default is `:warn` and the 1.0.0 default is `:deny`. It governs the entitlement functions. `track/4` keeps counting an undeclared feature, because metering is not entitlement, and says so with `declared: false` on its telemetry. `:warn` logs once per feature per node. | Setting `:allow`, which is the documented way for a legacy host to keep today's behaviour deliberately. | none (the 02b contract; see ADR 0010) | `AuroraMeter.FeaturePolicyTest` / `test B05 every entry point keeps its documented return shape under every policy` |
| G15 | Postgres only, through Ecto | Storage is `AuroraMeter.Storage.Ecto` against PostgreSQL, in the repo's default schema. PostgreSQL 13 is the floor, because the schema uses `gen_random_uuid()`, and 16.13 is the tested version with a second lane on 15.6. The supported Elixir and Erlang/OTP pairs are the ones CI runs on every push and are listed in `README.md`. | Any other database. A non-default Ecto `prefix:`, which is untested today and is rejected outright from 1.0. | none (the D12 support claim) | `AuroraMeter.MigrationTest` / `test the test database is migrated through every version`, run against PostgreSQL on every supported pair by the CI matrix; the `prefix:` rejection is not yet proven (phase 11) |

## What this page deliberately does not say

- It does not put a number on buffered loss. G6 explains why: the number would
  be true on a healthy database and false during the outage that is the only
  time anybody reads it.
- It does not claim any delivery is stronger than at-least-once. G11 and G12
  say what the idempotency actually rests on, which is a key the provider
  deduplicates on and an effect that is safe to repeat.
- It does not claim a cluster-wide hard quota. G4 gives the overshoot bound and
  names the interval it depends on. D09 in the V1 programme records that this is
  a decision, not an omission.
- It does not claim that a Stripe invoice was finalised or paid. Reconciliation
  reports differences; people resolve them.
- It states no service level and changes no commercial term. Compatibility
  promises are in [the support policy](support-policy.md); the API surface they
  apply to is [the API inventory](api.md).

## Reading the Proven by column

- A plain entry names a test that exists today, as
  `` `Module` / `test name` ``. The same convention as `docs/correctness.md`, so
  both can be checked mechanically.
- An entry beginning `pro:` is proven in `aurora_meter_pro`, whose own
  `docs/correctness.md` indexes it. Core cannot run Pro's suite, so core checks
  the shape and Pro's `AuroraMeter.Pro.CorrectnessIndexTest` checks the test.
- `not yet proven (phase NN)` means what it says. The row describes the 1.0
  contract and states, in its conditions, what today's code does instead.

`test/aurora_meter/docs_claims_test.exs` reads this table on every run and fails
when a named test does not exist, so a rename cannot quietly turn a proven row
into an unproven one.
