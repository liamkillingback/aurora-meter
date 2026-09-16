# Repair unit R6: a wallet created after this release is born on lots, and `usage_meter/1` updates live

Two items, one decision taken by the orchestrator and one shipped component that
was silently wrong in a browser.

- **Item 1**, findings X380, X283, X255, X277: on a new installation no wallet
  could reach the credit lot engine at all, so lots, the allocation trail, D07's
  credit priority, `debt`, `expired`, `:debt_outstanding` and the plan DSL's
  `recurring_credits` were implemented, tested, documented and unreachable.
- **Item 2**, finding X379: `AuroraMeter.Components.usage_meter/1` read the
  world from inside itself, so LiveView's change tracking never re-rendered it
  and a correctly subscribed page showed a figure that never moved again.

Repository `product-workspaces/aurora_meter` at `0b6b48c`, branch
`aurorameter-v1`; Pro at `da00e37`. Nothing is committed: evidence, dirty tree,
stop (rule 4). No checkbox is ticked by this unit.

## 0. The decision, checked against the binding maps before it was implemented

### What was decided, and by whom

The orchestrator, on 2026-09-17, deciding X380:

> A wallet created after this release is born on lots. A wallet that predates it
> changes only through the explicit migration.

R6 was asked to check that against `architecture-map.md` 7.2 and 7.4 and to stop
rather than implement around the map. **The map does not forbid it, it is silent
on it, and one sentence in 7.4 needed rewording rather than amending.** The
reasoning is below, and the proposed wording is in section 6, loudly, and was
**not** folded into the map by this unit.

### Why the objection that stopped three units before this one does not apply

06b's acceptance criterion asked `Ledger.locked_row/2` to stamp `lots_enabled_at`
"when the INSERT actually inserts". 06b, 06e and repair unit R1 each declined,
for one reason (X255, X283): `architecture-map.md` 7.4 makes the flag the output
of a **verified replay**, paired with a per-wallet checkpoint report and an
explicit `allow_cutover`, so a flag stamped in the ledger would mint cut-over
wallets with no report and no operator decision, arriving on `mix deps.update`
rather than on a choice.

**Every word of that objection is about wallets that already exist.** The line
R6 writes cannot reach one:

```elixir
repo.insert_all(
  CreditBalance,
  [%{..., lots_enabled_at: DateTime.truncate(now, :second), ...}],
  on_conflict: :nothing,
  conflict_target: [:tenant_key]
)
```

`ON CONFLICT DO NOTHING` on `tenant_key` means the statement either inserts a
wallet that did not exist a moment ago or writes nothing at all. There is no
path by which it updates a row. So:

- no wallet with a history to replay is moved, and 7.4's requirement holds for
  every wallet 7.4 is about;
- a new wallet has no history to reconcile, so the replay it would be asked for
  is vacuous, which is R2's own observation and X255's original requirement
  stated outright: "a genuinely new wallet is born on the lot path".

That property is not left as an argument. It is **section 4.2**, a test that
drives every writing entry point on the facade over a pre-release wallet and
re-reads the flag after each one, and **control C2**, which turns the
`on_conflict` into an upsert and watches exactly that test fail.

### What 7.2 and 7.4 actually say

**7.2 (allocation engine)** describes what the allocator does with a wallet it
owns. It says nothing about which wallets it owns, so it is untouched by this
decision, and section 4.1 shows the engine behaving exactly as 7.2 specifies on
a wallet created by a host: promotional before paid, earliest expiry first,
oldest paid grant next, a refund finding the payment that funded it and sparing
the promotional lots, and `debt` where the refund reaches spent value.

**7.4 (migration of existing wallets)** is scoped by its own title and its own
first clause. Its load-bearing sentence is a constraint on the migration task:
`mix aurora_meter.credits.migrate_lots` "sets `lots_enabled_at` only when the
replay reconciles exactly". Read in context that constrains **the migration**,
which is what the section is about. Read out of context, as "nothing anywhere
may set this column except a reconciled replay", it would forbid the decision.
The section does not say the second thing and its scope is the first, so R6
implemented the decision and proposes the clarifying wording in section 6 rather
than leaving a reader to pick between the two readings.

**The one thing 7.4 now under-describes** is the sentence "While
`lots_enabled_at` is null the ledger keeps today's arithmetic (legacy writer)".
That is still true. What is no longer true is the implicature a reader draws
from 7.1's "null = legacy wallet not yet cut over" plus 7.4: that the only route
to a non-null flag is the migration. There are now two, and section 6 is the
text that says so.

### What the decision costs, stated rather than discovered

An installation that upgrades holds two kinds of wallet until the migration has
run, and **two tenants of one installation can be told different things by the
same API**. That is not a new problem, it is the state the migration task exists
to resolve, but it arrives for a population rather than for a wallet an operator
chose. Nine differences are now listed in a table in `docs/credits.md` under
"Which wallets are on lots" and in `docs/upgrading-to-lots.md` under "Who needs
this page", the four a support engineer meets first being:

- a refund larger than the paid credit left clamps `promotional` down on an old
  wallet and keeps the promotion whole while raising `debt` on a new one;
- an overspent wallet refuses with `:insufficient_credits` on an old wallet and
  `{:error, :debt_outstanding}` on a new one;
- `recurring_credits` grants the allowance on a new wallet and nothing on an old
  one (`reason: :lots_disabled`);
- credit past its `expires_at` is spendable on an old wallet until the sweep
  runs and not spendable on a new one.

### What the decision deliberately does not do

- It does **not** migrate anything. No existing wallet moves, no replay runs,
  no checkpoint row is written, and the migration task is unchanged and
  unreached by R6 (section 4.5 re-measures it rather than asserting it).
- It does **not** add a public `AuroraMeter.Credits.enable_lots/1`. X380's
  option (a) is unnecessary once a wallet is born on lots, and a public function
  that cuts a wallet over without a replay would be the thing 7.4 forbids.
  `Ledger.enable_lots!/1` stays internal, stays refusing a wallet with rows, and
  is now needed only by the suite.
- It does **not** add a configuration switch to turn the new behaviour off. An
  installation that wants one behaviour throughout runs the migration; that is
  what it is for, and `docs/upgrading-to-lots.md` says so in those words.
- It does **not** touch `architecture-map.md`. Section 6 proposes the text.

## 1. Files

**R6's, in core** (`aurora_meter`):

| File | What changed |
|---|---|
| `lib/aurora_meter/credits/ledger.ex` | `locked_row/2` stamps `lots_enabled_at` on the insert that creates a wallet, with the reasoning above it |
| `lib/aurora_meter/credits/recurrences.ex` | `lots?/1` answers "will the allocator own this wallet when the grant writes to it", which admits a tenant with no wallet yet |
| `lib/aurora_meter/components.ex` | `usage_meter/1` and `usage_summary/1` take the data as an assign; the two forms are exclusive and an ambiguous call raises |
| `lib/aurora_meter/live_view.ex` | `quotas/1`, `assign_quota/4`, `assign_quotas/2` |
| `docs/credits.md`, `docs/upgrading-to-lots.md`, `docs/examples/prepaid-credits.md` | the split population, and the refusal term the example asserted wrongly |
| `test/support/aurora_meter/test/ledger_fixtures.ex` | `legacy_wallet!/1`: a wallet that predates the release |
| `test/support/aurora_meter/test/ledger_commands.ex` | the flat cross-oracle's driver builds a pre-release wallet |
| `test/test_helper.exs` | the `deferred` sweep prefix (section 5.2) |
| `test/aurora_meter/credits_new_wallet_test.exs` | new, 8 tests |
| `test/aurora_meter/components_change_tracking_test.exs` | new, 5 tests |
| 18 existing test files | each says which writer it is about (section 5.5) |

**R6's, in Pro** (`aurora_meter_pro`): `test/aurora_meter/pro/credits_lots_test.exs`
only, which needed its own `legacy_wallet!/1` because core's `test/support` is
not shipped in the package.

**Not R6's, and in the same dirty tree**: `test/aurora_meter/bench/report_test.exs`
and `test/aurora_meter/kill_test.exs` (repair unit R4); `lib/aurora_meter/install/*`,
`lib/mix/tasks/aurora_meter.install.ex`, `test/aurora_meter/api_inventory_test.exs`,
`test/aurora_meter/telemetry/no_outbound_io_test.exs`, `test/mix/tasks/install_test.exs`
and `lib/aurora_meter/install/shell.ex` (repair unit R5); `examples/` and
`docs/evidence/v1/phase-09/09c-*` (unit 09c). R6 edited none of them.

**The independent oracle is untouched.** `test/support/aurora_meter/test/ledger_model.ex`
is byte-identical to `HEAD`, sha256 `4d1d583059c20d4b72ff2cdc53ca1247a43a8c7c5df8d76d676a2dd8b5d4ba05`,
and `git diff` on it is empty. The exclusion predicate in `credits_model_test.exs`
(`comparable_history/0` and the two exclusions beside it) is unchanged; what
changed in that file is `with_wallet/1`, which now states that the wallet it
hands the flat model is a pre-release one, because the flat model is the legacy
writer's arithmetic and always was.

## 2. Environment

Core and Pro test databases on `aurora-meter-pro-testdb`, port 5490. Elixir
1.20.1, Erlang/OTP 29. Every Mix command through `tmp/v1/mixlane.sh`; every
harness that patched a tracked file ran under a **held** lane
(`mixlane.sh hold core ...`, X371), and every one snapshotted by sha256 and
restored on an `atexit` handler rather than by `git checkout` (X326).

## 3. Baselines

Taken before any R6 edit, on this machine, in this tree:

| | before | after |
|---|---|---|
| core `mix test` | **2152 passed**, 8 excluded | **2179 passed**, 8 excluded |
| Pro `mix test` | **1158 passed** | **1159 passed** |
| core `mix check` | exit 0 | exit 0 |
| Pro `mix check` | exit 0 | exit 0 |

Core rises by 27: R6's 13 new tests (8 + 5) and 14 from repair unit R5, which
landed its installer work in this tree while R6 was running. Pro rises by 1,
also R5's (`test/mix/tasks/pro_install_test.exs`). R6 added no Pro test.

## 4. Results

### 4.1 The money, per lot, on a wallet a host could really have

`credits_new_wallet_test.exs` / `test X380 a wallet created the way a host
creates one keeps a per-lot trail through grant, hold, settle and refund`.
**Nothing in that file calls `Ledger.enable_lots!/1`**, which is the whole point:
every other lot test in the suite does, and `enable_lots!/1` is not on the public
facade.

The wallet is four grants, made out of spend order on purpose:

| Grant | Amount | Category | Expires |
|---|---|---|---|
| `pi_old` | 10 USD | paid | never |
| `promo_late` | 4 USD | promotional | 2026-12-01 |
| `promo_soon` | 3 USD | promotional | 2026-11-01 |
| `pi_new` | 5 USD | paid | never |

Seven things are then true that were unavailable on every wallet of every
installation before this change:

1. **There are lots at all**: four, one per grant (X380 consequence 1).
2. **D07's credit priority is observable**: `Lots.list/2` returns
   `["promo_soon", "promo_late", "pi_old", "pi_new"]`, promotional before paid,
   earliest expiry first, oldest paid grant next (X380 consequence 3).
3. **It is the order a real spend takes.** A 5 USD hold reserves 3 USD from
   `promo_soon` and 2 USD from `promo_late` and nothing from either paid lot.
4. **A settle below its hold consumes and hands back, per lot**: `promo_soon`
   ends `consumed: 3 USD, available: 0`, `promo_late` ends
   `consumed: 1 USD, available: 3 USD`.
5. **The allocation trail exists and names the ledger row that caused each
   movement** (X380 consequence 2), asserted as an ordered list rather than a
   count:

   ```
   {:reserve,   3 USD, hold.id}
   {:reserve,   2 USD, hold.id}
   {:consume,   3 USD, settle.id}
   {:consume,   1 USD, settle.id}
   {:unreserve, 1 USD, settle.id}
   ```

6. **A refund finds the payment that funded it and spares the promotion.**
   `reverse_lot/4` for 6 USD against `pi_old` leaves `pi_old` at
   `reversed: 6 USD, available: 4 USD`, `pi_new` at `reversed: 0`, and both
   promotional lots **bucket for bucket identical** to what they were before the
   refund (`architecture-map.md` 7.2's promotional rule).
7. **The lots still project the balance row**: `balance == sum(available +
   reserved) - debt` and `held == sum(reserved)`.

**The before half, in the same file**: `test X380 the same walk on a wallet that
predates the release produces no lot and no allocation` runs the identical
script against a wallet built by `LedgerFixtures.legacy_wallet!/1` and asserts
`Lots.list/2 == []`, `Lots.allocations/2 == []`, no lot rows, no allocation
rows, and `lots_enabled_at` null. The money is still right; the provenance is
what is missing. That is X380's report, reproduced as a test.

### 4.2 The half the decision rests on: an existing wallet is untouched

`test X283 no path but creation touches an existing wallet's lots_enabled_at`
builds one pre-release wallet and drives **fifteen** entry points over it, every
writing path on the facade plus the readers, re-reading the flag and the lot and
allocation tables after each:

`grant`, `hold`, `settle`, `hold` again, `release`, `debit`, `reverse`,
`set_low_balance_threshold`, `balance`, `history`, `summary`, an expiring
promotional `grant`, `expire_due`, `reconcile_holds`, `Recurrences.run`.

After all fifteen the wallet is exactly where it started: `lots_enabled_at`
null, no lots, no allocations. `test X283 a wallet created before this release
and one created after it coexist` then asserts the split population directly:
same money, different provenance, in one database.

**Control C2 is what makes this mean something.** Turning `on_conflict: :nothing`
into `on_conflict: [set: [lots_enabled_at: ...]]` fails precisely these tests and
no others (section 4.4).

### 4.3 `recurring_credits` grants something, and a second gate had to be opened

X380 consequence 7 is the most visible: `AuroraMeter.Credits.Recurrences` scans
only wallets whose `lots_enabled_at` is set, so a plan declaring a monthly
allowance granted nothing, for ever, on every installation.

**Stamping at creation was not sufficient on its own, and that is a finding
rather than a detail.** The first run of the new test granted 0. The reason is
that `Recurrences.lots?/1` asked "does this wallet have the flag set", and a
customer who has just subscribed has **no balance row at all**: the wallet is
created lazily by the first ledger write. The gate was circular. The grant that
pays the allowance is what would create the wallet, and the gate refused to make
it because the wallet did not exist. An allowance is usually the first credit a
wallet ever sees, so this was the case that mattered most.

`lots?/1` now answers "will the allocator own this wallet when the grant writes
to it", with three cases: flag set, true; wallet exists with the flag null,
false (a pre-release wallet, skipped with `reason: :lots_disabled` exactly as
before); **no wallet row at all, true**, because the grant is what creates it and
a wallet created now is born on the allocator. It remains a pre-filter: the
reading that decides is still the locked one in the ledger, so a wallet created
between the two is judged there, on its real flag, under the row lock.

Measured, on a tenant that has done nothing but subscribe to a plan declaring
`recurring_credits :monthly, amount: 5_000_000, rollover: 1_000_000,
expires: :period_end`:

| | before R6 | after R6 |
|---|---|---|
| `summary.counts["granted"]` | 0 | **1** |
| `summary.counts["amount"]` | 0 | **5,000,000** |
| lots on the wallet | none | one, `amount: 5 USD`, `available: 5 USD`, `category: :promotional`, `expires_at: 2026-10-01` |
| `balance.spendable` | 0 | **5,000,000** |
| a 2 USD debit against it | refused | accepted, and the lot reads `consumed: 2 USD` |

The allowance being **spendable** is asserted, not just its row, because a row
is not a feature. The control for it is in the same file: `test X380 a recurring
allowance reaches nothing on a wallet that predates the release` still counts
`granted: 0`, so the old answer is still the answer for the wallets it was ever
about.

X380 consequences 4, 5 and 6 are covered by `test X380 debt, expired and the
:debt_outstanding refusal are reachable on a new wallet`: a settle above its
hold produces `debt: 3 USD`, `hold/4` and `debit/4` both answer
`{:error, :debt_outstanding}`, a grant of any category clears it, and a second
wallet's expired promotion produces `expired: 1 USD`.

### 4.4 Controls: six, six discriminated, and one of them lied first

Every control reverts or breaks one thing in `lib/` and runs the tests that
should notice. `tmp/v1/r6-controls.py`, run under a held lane, restoring on an
`atexit` handler, sha256 identical after.

| Control | What it breaks | Exit | Tests it broke |
|---|---|---|---|
| **C1** | the stamp: `locked_row/2` no longer marks a new wallet | 2 | all five new-wallet claims: the per-lot trail, the split population, recurring credits, debt and expired, the expiry page |
| **C2** | `on_conflict: :nothing` becomes an upsert, so creation reaches an existing wallet | 2 | exactly the three "an existing wallet is untouched" tests, and nothing else |
| **C3** | the recurrences gate reverts, so a tenant with no wallet is skipped again | 2 | exactly one test, the recurring allowance |
| **C4** | the live meter renders a quota that is not the one it was given | 2 | the two "the meter moves" tests, and **not** the snapshot test |
| **C5** | both component forms accepted, one quietly winning | 2 | exactly the exclusivity test |
| **C6** | `legacy_wallet!/1` becomes a no-op | 2 | exactly the four "predates the release" tests |

Two things about that table are worth more than the six exit codes.

**C2 is the decision's own control.** It breaks only the tests that assert an
existing wallet does not move, which is the property the orchestrator named as
the one the decision stands or falls on. If the stamp could reach an existing
wallet, C2 would pass and R6 would have had to stop.

**C3 failed the build before it failed a test, and was rewritten.** The first
version of C3 replaced one clause of `lots?/1` and left `wallet_exists?/1`
unused, so `--warnings-as-errors` failed the **compile**. The harness saw a
non-zero exit and reported `DISCRIMINATED`, and it had measured nothing at all
about recurrences. That is X373's shape exactly, an instrument failing towards
success, and it is the eighth this week. C3 now reverts the whole function,
helper and all, compiles, and fails one test: the right one.

### 4.5 The migration's replay is unchanged, measured at five seeds

R2 verified the migration's replay at five fixed seeds and R6 changes which
wallets take the lot path, so this was re-run rather than assumed
(`tmp/v1/r6-seeds.sh`, `AURORA_PROPERTY_RUNS=40`, seeds 0, 1, 7, 42, 1337).

Every `[06b replay property]` and `[06a cross-oracle]` line is **byte-identical**
to R2's recorded `tmp/v1/r2-seeds-fixed/summary.log`:

| Seed | 06b replay: compared / refused | 06a cross-oracle: compared / diverged |
|---|---|---|
| 0 | 27 / 14 | 17 / 3 |
| 1 | 31 / 10 | 15 / 5 |
| 7 | 32 / 9 | 14 / 6 |
| 42 | 21 / 20 | 15 / 5 |
| 1337 | 31 / 10 | 19 / 1 |

The refusal histograms match term for term as well. The only difference between
the two summaries is the per-seed test count, 51 against 59, which is R6's eight
new tests added to the file list. `LotMigration` was not edited and the cutover
gate was not touched.

### 4.6 Item 2: the meter, proved the way 09c proved it

**What was wrong.** `usage_meter/1` called `AuroraMeter.quota/2` inside itself,
so its output depended on data that was not in its assigns. LiveView re-renders
a function component only when the assigns handed to it changed; a tenant key
and a feature name do not change when usage does. A socket that was subscribed
correctly, received the broadcast and re-rendered still showed the figure read
at the first render. Not a bar that lags: a bar that never moves again.

**Why every existing test was green.** `components_test.exs` and
`realtime_test.exs` render through `render_component/2`, which renders once,
from scratch, with no change tracking at all. They could not see this and cannot:
a component that reads the world behind change tracking's back renders perfectly
every time it is rendered. The defect is in what is **not** rendered.

**The fix, and why it is not a cache-busting attribute.** `usage_meter/1` now
takes `quota={@quota}`, a map from `AuroraMeter.quota/2`. The number **is** the
assign, so when usage moves the assign moves and change tracking re-renders for
the ordinary reason. That contract was already in the documentation:
`docs/examples/showing-usage.md` has shown `<AuroraMeter.Components.usage_meter
quota={@quota} />` beside a `handle_info/2` that re-reads the quota since before
this repair. The component simply never implemented its own documented API.
`usage_summary/1` takes `quotas={@quotas}` on the same terms, because it had the
same defect and called into the same component.

The `tenant`/`feature` form stays, for dead views and `render_component/2`, and
is now documented at the point of use as a snapshot. Passing neither form, or
both, raises rather than guessing: with both, which figure the meter showed
would depend on an internal precedence rule rather than on anything the caller
wrote.

`AuroraMeter.LiveView` gains `quotas/1` (for `mount/3`, compiled without
LiveView), `assign_quota/4` and `assign_quotas/2` (message first, matching
`handle_info/2`, dropping a message for another tenant exactly as
`handle_usage/2` does), so the correct path is one line.

**The test asserts what a browser sees.** `components_change_tracking_test.exs`
does not call `render_component/2`. It renders a parent template twice, the way
a LiveView does: once for the first paint, and once with `__changed__` naming
only what moved. The second render's `dynamic` list **is** the diff the browser
receives, and a part that comes back `nil` is a part the browser is told nothing
about and therefore keeps.

| Parent | differs by | `#tick` after | meter after | real usage |
|---|---|---|---|---|
| `by_quota` (`quota={@quota}`) | one attribute | `1` | **`3 / 50`**, `aria-valuenow="3"` | 3 |
| `by_tenant` (`tenant=`, `feature=`) | one attribute | `1` | `nil`: nothing sent, browser keeps `1 / 50` | 3 |

That is 09c's experiment, two parents differing in exactly one attribute, with
the tick asserted to move in both so a page that rendered nothing could not pass.
**There is no cache-busting attribute anywhere in the file.**

Three more tests carry the rest of the claim: a quota that did **not** move sends
nothing, so the fix is not "defeat change tracking" (a fix that simply forced a
re-render every tick would fail it); `usage_summary/1` moves the same way; and
the two forms are exclusive.

## 5. Found on the way, not asked for

### 5.1 X384: the expiry sweep's lot phase carries no cursor

`Ledger.expire_due/2` runs in two phases. The first scans grant rows joined to
balances `WHERE lots_enabled_at IS NULL`, the **legacy** wallets, and carries a
`{expires_at, id}` keyset cursor. The second walks due lots, shares the page's
budget, and deliberately carries no cursor of its own, with the reasoning beside
it in the source: every lot expiry is idempotent, so an interrupted phase
resumes by being run again, and wiring a second cursor into the worker's
checkpoint was left to 06b.

`AuroraMeter.Oban.CreditExpiry` pages until a batch returns no cursor. On a new
installation the first phase always finds nothing, so **the worker does exactly
one batch per run and reports `stopped: :complete` with work still waiting.**
Measured in `test X384 ...`: six due lots, a page bounded at two, two expired,
`cursor: nil`, four still open and due.

**No money is at risk.** The candidate set is recomputed from a fresh `now` every
run and the remaining lots are expired by the next one, which the same test
asserts. What is wrong is the report an operator alerts on and the rate a backlog
drains. R6 did not fix it: the cursor lives in `lib/aurora_meter/oban/`, which is
outside this unit's files, and merging two keysets into one checkpoint is the
design 06b deferred rather than a repair. It is pinned by a test so it cannot be
rediscovered as a surprise, and filed as X384.

### 5.2 The `deferred` sweep prefix was missing, and it had already cost real time

`credits_after_commit_test.exs` commits on real connections under the prefix
`deferred` and grants `reference: "g1"` and `reference: "seed"`, neither of which
is tenant scoped, while `aurora_meter_credit_transactions` is unique on
`(kind, reference)` across the whole installation. `deferred` was not in
`test_helper.exs`'s suite-start sweep list.

An interrupted run of that file therefore left two rows that made **every later
run's** `reference: "seed"` grant return `:duplicate_reference`, in files that
never touch a real connection, for as long as the database lived. It happened
during this repair: an early run's teardown raised on the new foreign keys (5.3),
and `deferred_4363` holding `seed` and `d0` and `deferred_7881` holding `g1`
then produced 14 failures across `credits_test.exs`, `credits_history_test.exs`,
`credits_low_balance_test.exs` and `credits_after_commit_test.exs` that had
nothing to do with the change under test. That is X109 and X167's exact shape,
and `sweep_prefixes_test.exs` named it the moment the file started using
`Connections`. The prefix is now in the list, with the incident written beside it.

### 5.3 Two teardowns predated the ledger's foreign keys

`credits_after_commit_test.exs` and `credits_concurrency_test.exs` each deleted
`aurora_meter_credit_transactions` and then `aurora_meter_credit_balances`
directly. Core schema version 9 put `ON DELETE RESTRICT` foreign keys on the
ledger (an allocation references its transaction, a lot references its grant
row), so on a wallet with lots that order is refused, the teardown raises, and
the rows stay **committed** on a real connection. Both now call
`Connections.cleanup!/1`, which already owned the deletion order and is prefix
bounded. Invisible before R6 only because neither module's wallets had lots.

### 5.4 A false claim in a test comment, corrected

`credits_figures_test.exs` carried "no wallet a published version can produce
sees the new atom", about `:debt_outstanding`. That was true while every wallet
was born on the legacy writer. It is now the opposite: `:debt_outstanding` is an
ordinary thing for a new host to meet, and the comment says so.

### 5.5 Eighteen test files did not say which writer they were about

Not a defect and worth recording as a cost. Before this change every wallet in
the suite was a legacy wallet unless a test called `Ledger.enable_lots!/1`, so
"which writer owns this wallet" was never written down; it was the default. With
a wallet born on the allocator, 102 tests changed behaviour on the first run.
None of them was a money defect, and the classification took the most time of
anything in this repair:

| Class | Count | What was done |
|---|---|---|
| teardown refused by the version 9 foreign keys, leaving rows committed | 2 files | section 5.3 |
| contamination from those committed rows (`reference: "seed"`, `"g1"`, `"d0"` are not tenant scoped) | 14 tests | section 5.2; no test change needed once the rows were gone |
| the subject really is the legacy writer or the migration | 18 files | each now builds its wallet with `LedgerFixtures.legacy_wallet!/1`, with a comment saying why |
| the subject is the new behaviour and the assertion was stale | 2 | `examples_test.exs` (the refusal term) and `credits_recurrences_test.exs` (a tenant with no wallet is no longer skipped) |
| a defect the change made reachable | 1 | X384, section 5.1 |

The rule used for the third row, applied test by test rather than in bulk: a
test whose **subject** is legacy arithmetic keeps asserting it, because legacy
wallets still exist in the field and the migration must go on working for them;
a test about generic facade behaviour stays on the default wallet, which is now
a lot wallet, because that is what a new host has. Where the two behaviours
differ, both are asserted, each on the wallet it belongs to. `credits_test.exs`'s
`I12 a release after the grant expired returns spendable credit (L1)` is the
clearest case: the legacy leak is still asserted there, and
`credits_lots_test.exs`'s `I12 a reservation released on an expired lot becomes
expired, never spendable` asserts the fix, on the wallet that has it.

### 5.6 `docs/examples/prepaid-credits.md` asserted the wrong refusal

The document said the next spend after an overspend is "refused until a grant
brings them back above zero" and its test asserted `:insufficient_credits`. On a
wallet a new host has, the refusal is `:debt_outstanding`. Both now say so, and
the document also states the legacy answer for wallets that predate the upgrade.

## 6. The proposed amendment to `architecture-map.md`, NOT applied

R6 did not edit the map. This is the text it proposes, for whoever owns it.

**7.1**, replacing "`lots_enabled_at utc_datetime` (null = legacy wallet not yet
cut over)":

> `lots_enabled_at utc_datetime` (null = a wallet that predates the
> lots-on-creation release and has not been cut over). Two statements set it and
> no others: the `INSERT` that creates a balance row, and the migration in 7.4.

**7.4**, as a new paragraph at the head of the section, before "`mix
aurora_meter.credits.migrate_lots` ...":

> **This section is about wallets that already exist.** A wallet created by
> 0.5.0 or later is born on the allocator: `Ledger.locked_row/2` stamps
> `lots_enabled_at` on the `INSERT ... ON CONFLICT DO NOTHING` that creates the
> balance row, so the flag is set at the same instant as `inserted_at`. That
> statement cannot reach a wallet that already exists, and a wallet with no
> history has nothing to replay, so the requirement below that the flag is the
> output of a verified replay is unchanged for every wallet it is about.
> Decided by the orchestrator on 2026-09-17 (open-findings X380), after 06b, 06e
> and repair unit R1 each declined to stamp the flag in the ledger for a reason
> that applies only to existing wallets. The consequence is that an installation
> that upgrades holds two kinds of wallet until this migration has run, which is
> documented in `docs/upgrading-to-lots.md` and `docs/credits.md` rather than
> left to be discovered.

**7.5**, appended to the first "Requirements and limits" bullet's equivalent in
the map, after "`AuroraMeter.Credits.Recurrences.run(opts)` walks entitled
subscriptions in keyset order":

> A tenant with no balance row is eligible: the grant that pays the allowance is
> what creates the wallet, and a wallet created now is born on the allocator. A
> tenant whose wallet predates the release is skipped until the migration
> reaches it.

## 7. `mix check`

| | exit | result |
|---|---|---|
| core `mix check` | **0** | 2179 passed (82 doctests, 22 properties, 2075 tests), 8 excluded |
| Pro `mix check` | **0** | 1159 passed (74 doctests, 1085 tests) |

Both green, with nothing excluded that was not excluded before. Formatting was
applied to the changed files only, never project wide.

Four core failures seen during the repair were **not R6's** and are gone because
repair unit R5 finished its work in the same tree: `EvidenceWritesTest` and
`CorrectnessIndexTest` (naming `test/mix/tasks/install_test.exs` and
`AuroraMeter.InstallShellTest`), `NoOutboundIoTest` (naming
`lib/mix/tasks/aurora_meter.install.ex:318`) and `ApiInventoryTest` (naming
`AuroraMeter.Install.Shell`). R6 edited no file under `lib/aurora_meter/install/`,
`lib/mix/tasks/` or `test/mix/tasks/`.

## 8. Handoff

- **The map needs a decision.** Section 6's text is proposed and not applied.
  Until it is, `architecture-map.md` 7.1 and 7.4 describe a world with one route
  to `lots_enabled_at` and the code has two.
- **X384 is open** and is a reporting and rate defect in the expiry worker on
  any new installation, pinned by a test and not fixed.
- **09c's sample should drop its workaround.** `mix sample.seed` calls
  `Ledger.enable_lots!/1` before its first grant, under a comment saying it is
  not public API and should become the public call when there is one. There is
  no public call and there no longer needs to be: deleting those lines is now
  the correct sample. `examples/` is 09c's and R6 did not touch it.
- **The two-population state is a release-note item**, not just a docs item.
  `docs/upgrading-to-lots.md` states it; a release note has to as well, because
  a host who upgrades without reading that page will meet it through a support
  ticket.
