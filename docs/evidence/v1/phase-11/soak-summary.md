# 11d soak: what it measured of this package, and where the evidence is

Build unit 11d, V1 tasks 11.12 and 11.13. The soak harness, the runs and all of
the evidence live in the storefront repository, because the harness is a
storefront artefact and this package is one of the two things it measures. This
file exists so that core's own phase-11 record is self describing.

## What was measured

| | |
|---|---|
| Package | `aurora_meter` |
| Revision | `1f3f806189920961678ea3a3949a259a7a124b42` |
| Version | `1.0.0-rc.1` (11c's candidate) |
| Tree sha256 | `22516fcc711d7f4b0945b08063e421e71bba365cee15169cb40b04952c3d6be8` |
| How it was pinned | `git archive` of that revision into a copy outside the working tree; the soak host resolves it as a `path:` dependency with `override: true` |

**Nothing in this package was changed by unit 11d.** The pin exists because
build unit 11b was editing this checkout throughout: at pin time it had one
modified path, and two hours later four modified files, one rename, two new
files and a new test. A soak host pointed at the working tree would have
compiled a different library every time a node restarted, and the run restarts
nodes every five minutes.

## Where the evidence is

In the storefront, `docs/evidence/v1/phase-11/`:

- `soak.md`: the runs, their durations, the chaos timelines and the verdicts.
- `soak-method.md`: how the harness is built, what is pinned, and every
  deviation from the build document with what it costs.
- `soak-acceptance.md`: reader by reader, how each absence would have been seen
  if it had happened, and the control that was watched failing first.
- `soak-sizing.md`: per table growth, which is the sizing evidence 05d's
  retention defaults and 10a's sizing section needed and did not have.
- `soak-failures.md`: everything that failed, in both runs and in the harness.

The harness itself is `scripts/v1/soak/` in the storefront, and the raw run
artifacts are under `tmp/v1/soak/<runid>/`.

## What this package's paths were driven through

Two real BEAM nodes, connected by distributed `Phoenix.PubSub`, against one
database, with a node killed every five minutes.

- `track/4` on a buffered counter feature, at the run's highest rate, so the
  flusher, the counter table and `AuroraMeter.Cluster`'s gossip and re-basing
  are under continuous cross-node pressure. The buffered loss at each kill is
  measured and reported rather than assumed away (SOAK-09).
- `with_quota/4` on a hard-limited feature, with 5 percent of callbacks raising,
  throwing or exiting, so I03's release-on-failure path runs continuously and
  the cross-node overshoot is measured against D09's guarantee (SOAK-08).
- `record/4` with deterministic ids, 3 percent exact re-sends and 1 percent
  conflicting re-sends, so `:duplicate` and `{:conflict, _}` are exercised by
  the thousand rather than by the unit test (SOAK-04).
- `correct/4` from both nodes against the same original, which is I09's
  concurrent partial correction.
- `Credits` grant, hold, settle above estimate, release, debit and reverse on a
  hot wallet from both nodes, with kills in between, checked against the lot and
  allocation conservation identities and against an attribution model that
  requires every transaction row to have a named cause (SOAK-01).
- `Credits.Recurrences.run/1`, `Credits.expire_due/1` and
  `Subscriptions.apply_due_transitions/1` scheduled from **both** nodes every
  minute, so duplicate execution is created by construction rather than
  simulated (I16, I17, I18).
- `AuroraMeter.Clock` replaced by a simulated implementation, which is what
  makes twelve monthly boundaries reachable in hours and what CLOCK-01 checks
  every writing path against.

## The findings this package owns

**The one that blocks a release is not core's**, it belongs to
`aurora_meter_pro` (X486). Two of the soak's findings are core's, and a first
draft of this file said none were, which was wrong:

- **X490: the whole credit ledger's `inserted_at` bypasses the configured
  clock, and the sweep that reads it takes its cutoff from
  `AuroraMeter.Clock.now/0`.** All **129,044 of 129,044**
  `aurora_meter_credit_transactions` rows, across all seven kinds, are stamped
  inside the two hours of **wall** clock the run occupied, while
  `aurora_meter_credit_lots.granted_at` in the same subsystem spans the full
  simulated year. `AuroraMeter.Oban.HoldReconciliation` documents that its
  cutoff is measured with `Clock.now/0` and passes it as `:older_than` to
  `Ledger.pending_holds/1`, whose predicate is `t.inserted_at < ^cutoff`. In
  this run those two clocks were **148 days apart**, so an hours-scale staleness
  filter would have matched every pending hold on its first sweep. The ledger's
  own comments already name this column as wrong to order by (open finding L20,
  and 06a moves the ordering onto `seq`); what the soak adds is the consequence
  for the clock seam, measured. `HoldReconciliation` did not run in this soak,
  so this is the precondition measured and the effect reasoned.
- **X489: the outbox is the fastest growing table in this schema by bytes**, at
  1,209 bytes per row and 3,009 bytes per tenant per simulated day, which is 44
  percent of the whole core schema's per-tenant growth. The retention key that
  governs it is Pro's and covers `confirmed` items only, of which this run
  produced none.

Everything else is listed in `docs/v1/build-plans/open-findings.md` and in the
storefront's `soak-failures.md`.

Three of core's own schema guarantees turned out to be stronger than the soak's
readers, and that is recorded because it changes what a guarantee table should
say:

- `aurora_meter_credit_transactions_kind_reference_index` makes a second
  transaction under one reference and kind impossible;
- `aurora_meter_events_tenant_event_id_index` makes one tenant's event id stored
  twice impossible.

The soak's controls had to drop each index before they could plant the thing
their reader looks for. Those readers are therefore second lines of defence and
the constraints are the guarantee.
