# ADR 0008: Keep pending quota work out of billing

Status: accepted for the release candidate, 2026-09-12.

`with_quota` previously added billable usage before invoking the callback and
subtracted it on failure. A flush and report during that callback could send
usage to Stripe permanently even though the callback subsequently raised.

Pending work must occupy local quota without adding flushable or gossiped usage.
Store a reserved quantity in the same atomic ETS counter row. On successful
callback completion, convert it to pending usage. On failure, release only the
reservation. Rebase includes reserved units so an intervening flush cannot
erase the occupied quota. Public `reserve` retains its immediate-counting
semantics; the deferred lifecycle is internal to `with_quota`.

The billing reporter must read persisted completed usage rather than tentative
or gossiped live totals. Local reservations remain visible to quota checks and
dashboards. A VM crash can lose a reservation and unfinished buffered work; this
does not provide durable job execution or globally serialized cluster limits.

Regression evidence must include a callback that flushes and reports before
raising, successful work spanning a flush, and concurrent quota admission.
