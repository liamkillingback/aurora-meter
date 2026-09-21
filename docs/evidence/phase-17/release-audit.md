# Release audit evidence (in progress)

Candidate: Aurora Meter 0.4.0. Host: Northdoc in the WSL devcontainer.
This is intermediate evidence, not release approval.

## Reproduced and corrected

- Promotional expiry: consumption before a later grant existed must not be
  attributed to that grant. Chronological replay regression passes.
- Ambiguous database commit: local delta 5, committed response lost, another
  writer adds 3. Old recovery produced 13; receipt-based retry produces 8.
  An additional local 2 during recovery subsequently produces exactly 10.
- Cluster gossip cannot establish commit status. Updated the old test that
  explicitly accepted double counting; retry now persists exactly 6 once.
- Batch atomicity: a failing history write rolls back its prior counter write
  and receipt. Retrying succeeds. Verified outside the SQL sandbox transaction.
- Twelve independent database connections delivering the same batch yield one
  5-unit counter and one 5-unit day bucket.
- Pending `with_quota` work is separated from flushable usage. Pro integration
  regression reproduces an old 100-unit charge for a callback that raised;
  the corrected implementation reports no usage. Successful work reports 100
  only after completion. Existing concurrent hard-limit tests remain green.

## Checks

`mix check`: 234 passed (35 doctests, 4 properties, 195 tests), formatting,
warnings-as-errors compile, strict Credo, Dialyzer, and docs passed.

Schema 6 generated migrations applied in core and Pro test databases and the
Northdoc development database. No publishing or commits performed.

## Remaining release gates

Finish the full Stripe, currency, dispute, subscription and invoice audit in
Pro; verify host flows and final package builds; update all release docs and
vendor copies. Receipt retention is intentionally indefinite, and a Store/VM
loss can still lose buffered usage. See ADR 0007 and ADR 0008.

---

## Closing note, added by build unit 11e on 2026-09-21

**Added, not edited.** Nothing above this line has been changed. This record is historical:
its counts came from a different commit and a different machine (host Northdoc) and are not
comparable with the V1 numbers, so they are left as written rather than restated.

The "Remaining release gates" paragraph above is closed as follows.

| Item left open above | Where it was closed |
|---|---|
| "Finish the full Stripe, currency, dispute, subscription and invoice audit in Pro" | phase 04, against a **real Stripe account in test mode** rather than a fake: `aurora_meter_pro:docs/evidence/v1/phase-04/` holds `stripe-cancellation.json`, `stripe-credits-refund.json`, `stripe-decline-cutoff.json`, `stripe-meter-invoice.json` and `stripe-payment-refusals.json`, and invariants I13, I14, I15 and I22 rest on them |
| "verify host flows" | phase 09: the scripted quickstart and the clean-room installation, `docs/evidence/v1/phase-09/09c-packaging.md` and `09e-clean-room-core.md`, plus the storefront's `docs/evidence/v1/phase-11/clean-room.md` |
| "final package builds" | phase 11: `docs/evidence/v1/phase-11/package-audit.md` and `.json` audit the bytes of the archive rather than `mix.exs`, and record the uncompressed contents hash and the Hex inner checksum rather than the tarball hash, because Hex archives are not byte reproducible across toolchains (finding B19) |
| "update all release docs and vendor copies" | phase 10 for the documents; vendoring is step 12.08 of the owner's runbook and is deliberately **after** publication, because it is what moves every install snippet on the storefront |
| "Receipt retention is intentionally indefinite" | still true, and now configurable: phase 05d added retention controls, `docs/retention.md` |
| "a Store/VM loss can still lose buffered usage" | still true, measured rather than asserted, and stated in `docs/guarantees.md`. The buffered path is buffered by design; `track(..., durable: true)` and `record/4` are the durable paths |

The V1 record that supersedes this document is the cross-repository release manifest at
`PhxTemplates:docs/evidence/v1/release-manifest.md`, Part B, and the defect review at
`PhxTemplates:docs/evidence/v1/phase-11/defect-review.md`.
