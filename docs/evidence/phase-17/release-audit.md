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
