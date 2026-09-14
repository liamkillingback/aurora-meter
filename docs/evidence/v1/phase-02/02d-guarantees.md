# 02d: the guarantee table

Build unit 02d, 2026-09-15. Task 02.05. The published table is
[`docs/guarantees.md`](../../../guarantees.md); this file records what it says,
what it changed, and how the "Proven by" column is kept honest.

## 1. The table as published

Fifteen rows, five columns: **Guarantee**, **Exact conditions**, **What voids
it**, **Invariant**, **Proven by**. One rule governs the page and is written at
the top of it: a guarantee is written with the condition that makes it true, or
it is not written.

| # | Guarantee | Invariant | Proven by |
|---|---|---|---|
| G1 | `check/2` is advisory | I04 (by contrast) | `AuroraMeter.EntitlementsTest` / `test check/2 is advisory: two callers are both allowed the last unit and nothing is reserved` |
| G2 | `reserve` and `with_quota` are strict on one node | I04 | `AuroraMeter.EntitlementsTest` / `test I04 sixty concurrent with_quota calls against a limit of fifty admit exactly fifty on one node` |
| G3 | Failed tentative work is never billed | I03 | `AuroraMeter.EntitlementsTest` / `test I03 a callback that flushed and then raises is not billed` |
| G4 | Cluster counters converge, and hard caps can overshoot | I05 | `AuroraMeter.ClusterConvergenceTest` / `test I05 overshoot is bounded by what other nodes admitted between announcements` |
| G5 | A killed caller leaks its reservation on that node | I03, I04 | `AuroraMeter.KillTest` / `test I04 a killed caller's reservation continues to occupy the limit on that node` |
| G6 | Buffered loss is everything not in an acknowledged flush batch | I01 | `AuroraMeter.KillTest` / `test I01 a Store killed before the flush loses the buffered deltas, as documented` |
| G7 | One flush batch has at most one durable effect | I01, I02 | `AuroraMeter.FlushBatchConcurrencyTest` / `test I01 twelve independent connections deliver one batch once` |
| G8 | Credit holds cannot spend the same funds twice | I10, I11 | `AuroraMeter.CreditsConcurrencyTest` / `test I11 fifty independent connections holding against one hot wallet admit exactly the funded count` |
| G9 | Grant expiry cannot consume unrelated funds | I12 | `AuroraMeter.CreditsTest` / `test promotional credit I12 a grant expires only its own remainder` (behavioural; the structural proof is phase 06) |
| G10 | Durable recorded events are transactional | I06, I07, I09 | **not yet proven (phase 03)** |
| G11 | Export is at-least-once with provider-side idempotency | I15 | `pro:` `AuroraMeter.Pro.UsageReporterTest`, indexed under I15 in Pro's `docs/correctness.md` |
| G12 | Workers are at-least-once | I16 | `AuroraMeter.CreditsTest` / `test grant/3 credits the balance and is idempotent per reference` (the lease and checkpoint half is phase 05) |
| G13 | Periods are half-open UTC intervals | none (02c; ADR 0015) | `AuroraMeter.PeriodTest` / `test P01: the interval is half-open [start, end) P01 cross-month: ...` |
| G14 | Undeclared features follow the configured policy | none (02b; ADR 0010) | `AuroraMeter.FeaturePolicyTest` / `test B05 every entry point keeps its documented return shape under every policy` |
| G15 | Postgres only, through Ecto | none (D12) | `AuroraMeter.MigrationTest` / `test the test database is migrated through every version`, with the `prefix:` rejection **not yet proven (phase 11)** |

Every "Proven by" entry above is a test that exists today, except G10, which
says so.

## 2. The rows that changed a previously published claim

Four. Everything else restates what 0.4.0 already said, or states for the first
time something the code always did.

| Row | What 0.4.0's documentation said | What the table says |
|---|---|---|
| G6 | `docs/metering.md` and both worked examples bounded buffered loss at one flush interval ("at most one interval's worth", "up to five seconds") | Loss is everything not in an acknowledged flush batch, unbounded while the database is unreachable. The README already said this; the guides contradicted it |
| G11 | `docs/examples/allowance-and-overage.md` said Pro tells Stripe about the delta "exactly once" | At-least-once with provider-side idempotency, an uncertainty window that is a state rather than a retry, and no claim that an invoice was finalised |
| G10 | `docs/examples/concepts.md` implied the durable event row is the billing source | Today's `track(..., durable: true)` carries no identity, is not deduplicated, and is not what usage reporting reads. The transactional contract arrives in 1.0 |
| G4 | The README described the overshoot bound correctly; nothing said there is no cluster-wide serialization point | Stated, with D09 named as the decision rather than left as an omission |

The corrections themselves, with before and after text, are in
`02d-claims-sweep.md`.

## 3. How the column is kept honest

`test/aurora_meter/docs_claims_test.exs` parses the table on every run and fails
when a "Proven by" cell does not resolve. A cell may be:

- `` `Module` / `test name` ``, which must exist in the test tree;
- `pro:` followed by an `AuroraMeter.Pro.*` module **and** a reference to Pro's
  own `correctness.md`, which Pro's `CorrectnessIndexTest` checks;
- `not yet proven (phase NN)`.

Anything else fails as "unrecognised". The test also fails if any row's
conditions, "what voids it" or invariant cell is empty or too short to be saying
anything, and if no row at all says "not yet proven", on the grounds that a
column with no honest row in it has started flattering the code.

**The test tree is parsed into AST, not grepped.** This is
`open-findings.md` X84: 02a's first version of "the documented thing exists in
the source" grepped raw sources, and its negative control passed, because the
renamed telemetry event still appeared in a moduledoc two lines above the emit.
A check of that shape validates the documentation against itself.

The negative control for this one was run twice, and the second run is the
interesting one:

| Control | Result |
|---|---|
| Rename the test G6 cites | fails: "G6: AuroraMeter.KillTest / test I01 a Store killed before the flush loses the buffered deltas, as documented does not exist in test/" |
| Rename it **and** put the old name in the test module's own `@moduledoc` | **still fails, with the same message.** A grep would have passed |

A permanent version of the same control is in the test file: a fixture that
names two tests it does not define, one in a moduledoc and one in a comment, and
defines exactly one real test. The parser sees one test; the assertions that
follow show a textual search finds all three.

## 4. What the page deliberately does not say

- No number on buffered loss. The number would be true on a healthy database and
  false during the outage that is the only time anybody reads it.
- No delivery promise stronger than at-least-once, for export or for workers.
- No cluster-wide hard quota. G4 gives the bound and names the interval it
  depends on.
- No claim that a Stripe invoice was finalised or paid.
- No service level and no commercial term (D02).

The first two are enforced, not merely intended: the same test file fails the
build if either phrase family reappears anywhere in the documentation tree.

## 5. Where it is linked from

- `README.md`'s "Guarantees and limits" section is now a summary whose first
  line points at the page.
- `mix.exs` lists it in `docs()` extras under Guides, so it renders on hexdocs.
- Pro's `README.md` and `docs/usage-reporting.md` link to
  `https://hexdocs.pm/aurora_meter/guarantees.html` rather than restating the
  export and worker rows, and a Pro test fails if either link goes or if a Pro
  document grows its own guarantee table.
- ADR 0003's appended note points at it for the current contract.

`10a` and `10b` quote this page. They do not paraphrase it: a paraphrase is a
second copy of a contract, and the copy a customer reads is always the stale one.

## 6. Rows that will need revisiting, and by whom

| Row | Trigger | Owner |
|---|---|---|
| G10 | `record/4` and the durable event tables ship | 03b, which promotes "not yet proven (phase 03)" to a real test name |
| G9 | the credit lots land and the conservation constraint becomes structural | 06a |
| G12 | worker leases and checkpoints land | 05c |
| G15 | `prefix:` rejection lands | 11b |
| G14 | 1.0 flips the default to `:deny` | the 1.0 release |
| G11 | the outbox replaces the reporting ledger | 04b |

Each is a row whose conditions are already written for the 1.0 contract and
whose proof column is honest about today. None of them needs the row rewritten,
only the column filled in.
