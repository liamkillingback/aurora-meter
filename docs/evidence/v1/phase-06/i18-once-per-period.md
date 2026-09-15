# I18: two schedulers, one grant and one rollover per period

Build unit 06d, V1 task 06.05, gate G06 bullet 6. Raw output:
`logs/06d-evidence.txt`, section "i18-once-per-period", and
`test/aurora_meter/credits_recurrences_concurrency_test.exs`. Run on 2026-09-15,
core `011ac34` plus 06d's working tree, Postgres 16.13, Elixir 1.20.1 / OTP 29.

## The breadth run: fifty tenants, two schedulers

Fifty tenants on plan `:allowance` (`amount: 5_000_000, rollover: 1_000_000`),
each granted for September by one run and left unspent, so October owes each of
them an allowance **and** a rollover. Then one hundred `Recurrences.run/1` calls,
two per tenant, on independent real connections, all released together from a
barrier.

```
september, one scheduler: %{"granted" => 50, "duplicate" => 0}

october, two schedulers over 100 runs:
%{"examined" => 100, "tenants" => 100,
  "granted" => 50, "duplicate" => 50, "conflict" => 35,
  "issued_and_expired" => 0, "skipped" => 0, "failed" => 0, "catching_up" => 0,
  "amount" => 250000000, "rollover" => 50000000}

october recurrence rows: 50
october allowance lots: 50 totalling 250000000
october rollover lots:  50 totalling 50000000
spendable per tenant:   min 6000000 max 6000000
```

Fifty recurrence rows, fifty allowance lots, fifty rollover lots, zero duplicate
lots, and every one of the fifty tenants at exactly 6,000,000 micro-dollars.
That is criterion 2.

### The contended branch, counted

**35 of the 50 duplicates were `conflict`.** The engine counts `duplicate` and
`conflict` separately for exactly this reason (finding X214). A `duplicate` is a
run that read the period's own recurrence row before it opened a transaction and
short-circuited; a `conflict` is a run whose `INSERT ... ON CONFLICT DO NOTHING`
came back empty **inside the wallet's balance row lock**, which only happens when
the other scheduler was still inside its transaction when this one read. Asserting
`duplicate == 50` would have passed for a hundred runs executed strictly one
after another; asserting `conflict > 0` cannot.

The number is reported rather than pinned: the machine decides how many of the
fifty pairs really overlap. The test asserts `conflict > 0` with a message that
says what a zero would mean.

## The forced run: a rendezvous that guarantees the race

The breadth run measures whatever contention the machine happens to produce.
`test I18 a rendezvous that guarantees the race issues exactly one grant per
period` removes the chance: for each of six rounds, a third connection holds the
wallet's balance row `FOR UPDATE` while both runs queue behind it, and the
holder commits only once `pg_stat_activity` reports two backends with
`wait_event_type = 'Lock'`.

```
contended == 6 of 6 rounds
per round: granted == 1, conflict == 1, one recurrence row, one lot, 5,000,000 spendable
```

**A row-lock waiter is invisible to the obvious `pg_locks` query** (finding
X186): a backend queued behind a row lock waits on the holder's
`transactionid`, and a `transactionid` lock carries no `database`, so filtering
`pg_locks` by database removes exactly the rows being looked for.
`pg_stat_activity` sees it, and that is what the rendezvous polls.

## The negative controls

Both run under the same rendezvous, so they are measurements of the same race
rather than of a different one.

**Control 1: the recurrence guard removed, the ledger's index left.** Four
rounds, each two concurrent `Ledger.grant_with_status/3` calls with the period's
own reference and no recurrence row anywhere. Result: one `:new` and one
`:duplicate` per round, one lot per tenant. The two guards really are redundant,
and the ledger's `(kind, reference)` uniqueness alone still admits one grant,
decided inside the same balance row lock. `contended == 4 of 4`.

**Control 2: a reference that is not stable for the period.** The same four
rounds, the same rendezvous, with the one thing the engine exists to supply
removed: each run mints its own reference. Result: **two** `:new` per round and
two lots per tenant, 10,000,000 spendable where 5,000,000 was owed.
`contended == 4 of 4`. So the tests above are evidence about the key rather than
about the lock happening to serialise things: a host cron with its own reference
double-grants under precisely the conditions where the engine does not.

**Control 3: the build document's reference.** `logs/06d-controls.log`, control
D. The grant reference is the recurrence key exactly as 06d's build document
specifies it, with no tenant in it. Five of thirty tests fail, and the one that
names the defect is `test I18 two tenants on one plan reach the same period
without colliding`: `granted` is 1 where 2 were expected, because
`aurora_meter_credit_transactions` is `UNIQUE (kind, reference)` across every
tenant in the installation and the second tenant's grant is refused as a
duplicate of the first tenant's. The other four failures are the same defect
seen from four other angles (the scan, the kill-and-resume, the sweep-ordering
test and the reference assertion), which is itself worth recording: with that
reference, **any** two tenants on one plan in one period collide. Recorded as
finding X273; the shipped reference carries the tenant.

## A debit racing the recurrence

`test I18 a debit racing the recurrence leaves the carry computed from the
committed availability`, six rounds, `contended == 6 of 6`. In every round, and
in whichever order the two committed:

```
september.consumed + september.expired == september.amount
carry == min(september.amount - september.consumed, cap)
debt == 0
```

The identity holds in both orders because the carry is read under the same lock
the debit takes, so it is always computed from committed availability. The
observed carries are 0 or 1,000,000 depending on which side won, which is
reported rather than asserted: the machine decides the winner, and a flaky
assertion about that would be worse than the number.
