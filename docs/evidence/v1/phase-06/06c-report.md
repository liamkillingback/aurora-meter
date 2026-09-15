# 06c: credit API compatibility, the lot read API and the money figures

V1 tasks **06.03** (API compatibility and the grant, detail and allocation read
API) and **06.07** (money displays, and one threshold alert per crossing).

## 1. Tasks, repository and revision

| | |
|---|---|
| Tasks | 06.03, 06.07 |
| Repositories | core `product-workspaces/aurora_meter`, Pro `product-workspaces/aurora_meter_pro` |
| Core SHA at start | `04d8dd4d6c2c2b32c9d923abb501c188a5f851b1` |
| Pro SHA at start | `a32112cb6a5dac018bbc395fbe5946ba7cf6ea0c` |
| Tree state | **dirty**: this unit does not commit (programme rule 4) |
| Core patch sha256 | `4a4ac66fe5fdf40f2ad57ccac899099e4f2ce5770d7661515beebed14d154470` (`git diff \| sha256sum`, untracked files excluded) |
| Pro patch sha256 | `500c1ac3b7a31b71511a057af59f0e89fcacd8db3ca737a1e4bb99285c2ff0fe` |

Untracked files this unit adds, which the patch checksums above do not cover:

```
core: lib/aurora_meter/credits/lots.ex
core: test/aurora_meter/credits_after_commit_test.exs
core: test/aurora_meter/credits_figures_test.exs
core: test/aurora_meter/credits_history_test.exs
core: test/aurora_meter/credits_lots_api_test.exs
core: test/aurora_meter/credits_low_balance_test.exs
core: test/regressions/seeds/i10-l2-reverse-has-its-own-reference-namespace.exs
```

and one deletion, `core: test/regressions/seeds/i10-l2-reverse-shares-the-debit-reference-namespace.exs`,
which is the same seed renamed and re-expected (section 4).

## 2. Environment

| | |
|---|---|
| Core schema version | 9 (`AuroraMeter.Migration.latest_version/0`); **no DDL in this unit** |
| Core package version | 0.5.0 (working source) |
| Pro package version | 0.3.0 (working source) |
| Elixir | 1.20.1 |
| Erlang/OTP | 29 (erts 17.0.1, jit) |
| OS | Linux 6.6.87.2-microsoft-standard-WSL2, x86_64 |
| Postgres | 16.13 (Debian 16.13-1.pgdg13+1), port 5490, probed in this unit |
| core `mix.lock` sha256 | `f61daa1e4e86792351572088bcff4a7515794fed9077ed008441cec9d2e722a6` |
| Pro `mix.lock` sha256 | `a2140b7e65132ec337fb7e6ac70fbd750b4ade13f1f6b1fb1762d1426bfbac8e` |

## 3. Commands and logs

Every Mix command ran through `tmp/v1/mixlane.sh`, which takes a per-package
`flock` on `_build` (wave rule 1). Seeds are `--seed 0` unless a command is a
full `mix check`, whose suite step uses its own default seed and prints it.

| # | Command | Exit | Seed | UTC start | UTC end | Artifact |
|---|---|---|---|---|---|---|
| 1 | core `mix check` | **0** | 0 (suite default) | 2026-09-15T18:24:00Z | 2026-09-15T18:28:00Z | `tmp/v1/06c-logs/core-check.log` sha256 `eb96270c…` |
| 2 | core headless (`tmp/v1/06c-core-headless.sh`) | **0** | 0 | 2026-09-15T18:28:41Z | 2026-09-15T18:32:22Z | `tmp/v1/06c-logs/core-headless.log` sha256 `cb33149a…` |
| 3 | Pro `mix check` with the PLT deleted (`tmp/v1/06c-check-pro.sh`) | **0** | 0 | 2026-09-15T18:26:30Z | 2026-09-15T18:28:10Z | `tmp/v1/06c-logs/pro-check.log` sha256 `da3c6d90…` |
| 4 | X266 negative control (`tmp/v1/06c-x266-run.sh`) | 0 | 0 | 2026-09-15T17:16:48Z | 2026-09-15T17:16:59Z | inline, section 4 |
| 5 | X269 location (`tmp/v1/06c-x269-locate.sh`, `mix test --trace`) | 0 | 0 | 2026-09-15T18:18:13Z | 2026-09-15T18:18:28Z | `tmp/v1/06c-logs/x269-locate.log` sha256 `6e7ec911…` |
| 6 | X269 control C6 (`tmp/v1/06c-c6.sh`), both packages | 0 | 0 | 2026-09-15T18:21:00Z | 2026-09-15T18:21:40Z | inline, section 4 |

Commands 1 and 3 were re-run after every later edit; the numbers below are from
those runs. Command 2's `mix compile --force` under `AURORA_HEADLESS=1` removes
the optional dependencies from the build, so the working `_build` was restored
with a plain `mix compile --force` afterwards and command 1 re-run.

The log artifacts are under `tmp/v1/06c-logs/`, which is outside both packages:
they are working artifacts of this run, not committed evidence, and `sha256` is
what ties this report to them (finding X135: a test that rewrites its own
evidence on every run cannot be reviewed).

## 4. Results

### Counts

| | Before (HEAD) | After | Delta |
|---|---|---|---|
| core `mix check` | exit 0, 1530 passed | **exit 0, 1583 passed** (68 doctests, 17 properties, 1498 tests), 4 excluded | +53 |
| core headless (`--include headless`) | 1442 passed | **1495 passed** (64 doctests, 17 properties, 1414 tests) | +52 then +1 for X269's regression |
| Pro `mix check` | exit 0, 959 passed | **exit 0, 966 passed** (66 doctests, 900 tests) | +7 |

The four excluded core tests are the `:headless` tag, which command 2 includes.
No test is skipped and none is tagged out by this unit.

### The X266 decision: the fold accepts `:reverse`

**Decided: extend `AuroraMeter.Credits.LotMigration`'s fold, under the narrow
authorisation the orchestrator gave, rather than decline the API change.**

The reasoning, and both halves matter:

- **The rows already written can never change.** A reversal from before schema
  version 9 is `kind: :debit, category: :reversal`, and the ledger is append
  only, so the fold's existing clause is permanent whatever else happens.
- **Declining the API change would leave finding L2 open**, and L2 is an
  acceptance criterion of this unit and a real defect: a host debit and a Pro
  refund keyed by one order id collided on the `(kind, reference)` unique index,
  and the loser was told `:duplicate_reference` for a write it had never made.
  The refund was silently not applied. Declining costs a correctness fix to
  protect a migration the same unit can teach in one clause.
- **The fix is one clause and changes no arithmetic.** `step(acc, %{kind:
  :reverse} = row), do: reversal(acc, row)` routes to the same function the
  legacy clause routes to, so the two shapes produce identical lots,
  allocations and flags.

The test is `AuroraMeter.CreditsLotMigrationTest` / `test I19 a wallet holding a
reverse row migrates and reconciles, and so does one holding the legacy shape
(X266)`. It builds **two** wallets: one whose refund was written by today's
`Credits.reverse/4` (so `kind: :reverse`), and one rewritten in place to the
pre-version-9 shape. Both migrate, both reconcile against `balance`, `held` and
`promotional`, and both leave a lot reading `reversed: 2_000_000, available:
3_000_000` with a `reverse` allocation. The legacy half is not decoration: a
fold that handled only the new shape would break every wallet that has already
taken a refund, which is the larger population.

### The X266 negative control, and a correction to X266's premise

`tmp/v1/06c-x266-control.py` removes the single clause and puts it back;
`tmp/v1/06c-x266-run.sh` runs the three migration files either side and asserts
the file is restored byte for byte.

```
baseline sha256 d0b1627ba92e67ca34e5015ac3e85d699f541db06aef39743081cb52fda6b831
break    sha256 54bc4e9315ee6ab5e71fa3056f876426f4b8412cdfad228c6048d43925751903
restore  sha256 d0b1627ba92e67ca34e5015ac3e85d699f541db06aef39743081cb52fda6b831   (identical)

with the clause removed : 43/57 passed, 14 failures, every one `unsupported_row`
with the clause restored: 57/57 passed
```

**X266 says "nothing would have failed". That is not what the control measured,
and the correction is worth more than the confirmation would have been.**
Thirteen of the fourteen failures are pre-existing 06b tests, so the break would
have turned the migration suite red immediately rather than drifting silently.
The reason is incidental but decisive: 06b's replay fixtures build their
reversals by calling `Credits.reverse/4`, so changing what that function writes
changed what those fixtures contain.

What **is** true, and is the part worth keeping:

- the silent-drift scenario is real for **production data**. A wallet whose
  reversal rows were written by a host after the release is not built by any
  test, and its migration would simply have been refused;
- no test asserted that a wallet containing a reversal migrates **at all**
  before this unit. The thirteen failures would have said "unsupported_row",
  which reads as a fixture problem, not as "every refunded wallet is now
  unmigratable";
- and the break removed the **only** trigger for a blocking flag. 06b's
  `:unsupported_row` fixture inserted a `kind: :reverse` row, precisely because
  `:reverse` was then the one kind in `Schema.CreditTransaction.kinds/0` with no
  clause. After this unit the `kind` dispatcher is **total** over all seven
  kinds, so the fixture had to change to a shape that is still unreachable: a
  `:grant` carrying `category: :reversal`. Without that change the flag would
  have had no test, which is X212's shape.

11a's mechanical check that every `kind` the schema admits has a clause in every
dispatcher over `kind` would now pass for this dispatcher. It is worth having
anyway: the next kind added will not have a 06b fixture pointing at it.

### The compatibility diff, line by line

Every changed assertion in a pre-existing test file, with the reason. The
criterion is that the suite passes "with no change other than added keys", so
each departure from that is named here.

**`test/support/aurora_meter/test/ledger_model.ex`** (01e's independent model,
which is the oracle the generated histories compare against):

| Change | Why |
|---|---|
| `wallet/1` gains `spendable`, `promotional_spendable`, `debt`, `expired` | `LedgerCommands.wallet_problems/2` compares the model's map with `Credits.balance/1` by **exact equality**, so a subset match would have been the easy fix and would have cost the oracle its teeth: a comparison that ignores unknown keys cannot notice a figure that starts coming back wrong. The model is the legacy ledger's arithmetic and `LedgerCommands.run/2` only ever drives a legacy wallet, so all four have definitional values there. |
| `step/2` for `{:reverse, ...}` registers `{:reverse, reference}` instead of `{:debit, reference}` | The model reproduced L2 deliberately. The contract changed, so the model follows it. **This one reported itself**: with the old line in place the two generated-history properties failed on the first history that debited and reversed under one reference (`model {:error, :duplicate_reference} vs ledger {:error, :insufficient_credits}`), which is the oracle working. |

**`test/support/aurora_meter/test/ledger_fixtures.ex`**:

| Change | Why |
|---|---|
| `corrupt!(tenant, :unsupported_row, _)` writes a `:grant` with `category: :reversal` instead of a `kind: :reverse` row | See above: the kind dispatcher is now total, so the old fixture no longer reaches the flag it exists to trigger. |

**`test/aurora_meter/credits_concurrency_test.exs`**:

| Change | Why |
|---|---|
| `test I10 a host transaction that rolls back undoes the ledger row although the side effects already fired (L18, fixed in 06c)` renamed and inverted | It was written as the "before" half of L18 and names 06c in its own description. It now asserts the opposite, which is the fix: `refute_received` inside the transaction, `Credits.deferred_effects?()` true, `after_commit(discard: true)` in the rollback branch, and nothing emitted. |

**`test/aurora_meter/credits_model_test.exs`**:

| Change | Why |
|---|---|
| `test the model itself model: a hold and a debit share no reference namespace, but a debit and a reversal do (L2)` renamed and inverted | The model change above, asserted directly. It also gains an assertion that a second `:reverse` under the same reference is still `:duplicate_reference`, which is the half a "they no longer collide" change could quietly lose. |
| the two `bigint ceiling`/`bigint floor` tests renamed and inverted, plus one new | Both named 06c in their descriptions and recorded L17's behaviour so this unit had a before and an after. They now assert an `ArgumentError` naming the limit, and that `Money.max_micro()` itself is admitted, so the test distinguishes "refuses too much" from "refuses everything" (finding X155). |

**`test/regressions/seeds/`**: `i10-l2-reverse-shares-the-debit-reference-namespace.exs`
is deleted and `i10-l2-reverse-has-its-own-reference-namespace.exs` replaces it.
The history is identical; the recorded final balance moves from 900_000 to
850_000 because the reversal now lands. The file says which half of L2 it is and
why, per the seed directory's own rule that a seed is never deleted to make the
suite green.

**Pro**: `test/aurora_meter/pro/credits/sync_refund_test.exs` replaces seven
`CoreCredits.history(tenant, kinds: [:debit])` calls with one `reversals/1`
helper that asks for both kinds and filters with
`Schema.CreditTransaction.reversal?/1`. Those assertions were about the row's
kind; the kind changed, and the helper is now the only place in that file that
decides what a reversal looks like.
`test/aurora_meter/pro/dashboard_test.exs`'s `leads with balance...` gains
`Spendable`, `On hold`, `Owed` and `Expired` and no longer asserts `Balance`,
because the section's headline figure is `spendable` from this unit on.

**Everything else in `credits_test.exs`, `credits_series_test.exs` and
`credits_config_test.exs` passes unchanged.** No assertion in those three files
was edited. They pattern-match `assert %{...} = Credits.balance(...)` rather
than comparing whole maps, which is why the four new keys cost them nothing; the
one exact-map comparison in the package is `balance/1`'s own doctest, in the file
whose return value changed.

### A cross-package break the core change caused, found by running both suites

Pro's `mix check` went from 959 passed to **944/966 with 22 failures** the first
time it was run after the core change, every one in the refund and dispute path.
`AuroraMeter.Pro.Credits.reference_total/3` counted what had already been taken
back with `t.kind == :debit`, so every reversal written under the new kind read
as zero. Each cap in that module is "what Stripe says the total is" minus "what
we have already taken", so a zero there **refunds the customer a second time**.

The fix is a `reference_total(key, :reversal, prefix)` clause matching
`kind in [:debit, :reverse] and category == :reversal`, and the two call sites
that counted reversals. It is deliberately minimal: `free-pro-boundary.md`
gives Pro's direct `CreditTransaction` reads to **06e**, and this is the smallest
change that keeps them correct until then.

This is X252 exactly ("a change to core's schema is a change to Pro whether or
not a Pro file is edited"), one level up: a change to what a core **row** is, is
a change to Pro. It was found by running Pro's suite, not by reasoning.

### How the deferral negative was proved without a vacuous assertion

`refute_received` on an asynchronous message passes when the message is merely
slow, so `credits_after_commit_test.exs` does not use it for the main claim. The
telemetry handler there records **when** it ran, not that it ran: it reads a
phase marker from an Agent at the instant it fires and appends it. The
assertions are then

```elixir
assert fired(phases) == [:after_drain]     # commit path: one event, in the last phase
assert fired(phases) == []                 # rollback path with discard: true
assert fired(phases) == [:immediate]       # the control: a call owning its transaction
```

A handler that fired inside the host transaction records `:inside` and the first
assertion fails naming the phase that actually happened. The positive is in the
same assertion, from the same recording, so the mechanism is shown to work
rather than shown to be absent. The control (`a ledger call that owns its
transaction is unaffected`) is the assertion that fails if `transact_outcome/1`
deferred unconditionally, which every other test in the file would tolerate.

### X269: a vacuous pass in a money path, and what it cost to find

**The first implementation of this unit made the writer wait for the handler,
and two Pro tests passed because that wait deadlocked.**

`Ledger.low_balance/1` ran the handler in a task and blocked on `Task.yield/2`.
That satisfies the contract on paper. It also holds the **writer** still while
the **handler** wants a connection, and `AuroraMeter.Pro.Lock.with_lock/2` wraps
Pro's payment paths in `Repo.checkout/1`, which pins a connection to the writer
for the length of the callback. So the handler needed a second, concurrent
connection while the writer held the first and was waiting for it. Under the one
connection a sandbox gives a test, that is a deadlock every time, broken only by
the checkout queue giving up after about 985 ms, after which the handler was
reported `:raised` and no alert was delivered.

The two tests it happened in are

- `webhook: top-up a refund stops auto top-up instead of charging the card again`
- `webhook: top-up a chargeback also drops the card it was disputed on`

and **both assert `refute_enqueued`**. Nothing was enqueued because the handler
had crashed, not because the code decided not to. Both carry comments saying the
negative assertion is worthless unless the hook fires; it was not firing. I
reported this as a weak spot and left it; the orchestrator was right that a
vacuous pass in a money path is not a weak spot to note, it is a defect.

**Located rather than guessed:** `mix test --trace`, correlating each warning
line with the test above it (`tmp/v1/06c-logs/x269-locate.log`). The module is
`async: false`, so the sandbox is shared and the connection was genuinely busy,
not merely unowned. `Repo.checkout/1` is not `Repo.transaction/1`: a ledger call
inside a transaction **defers** its effects and never reaches the handler at all,
which is why this only appears on the checkout path.

**The fix moves the wait, it does not remove it.** The writer broadcasts PubSub
synchronously, starts one supervised watcher and returns. The watcher runs the
handler under the same `async_nolink` plus `yield` plus `shutdown`, and emits
the telemetry when it knows the outcome. Every guarantee is kept and one is
strengthened: the handler cannot fail the write, cannot block it, and now cannot
**delay** it.

**What the tests do now.** Core gained
`test I11 a handler that needs a connection gets one while the writer holds a
pinned one (X269)`, which runs the ledger call inside `TestRepo.checkout/1` with
a handler that reads the balance, and asserts both the read and
`handler: :ok`. The four Pro tests that wire the hook call
`assert_handler_delivered!/1`, which waits for
`[:aurora_meter, :credits, :low_balance]` with `handler: :ok` **before** anything
is read: `:raised`, `:timeout` and `:exit` all fail there, so a handler that does
not run is a failure rather than a log line. Core's low-balance counts moved off
the handler entirely and onto the synchronous PubSub broadcast, which is exact
rather than eventual and is the right place for a claim about the ledger.

**Control C6** (`tmp/v1/06c-c6.sh`) restores the old shape and fails **four**
tests, two in each package:

```
core: I11 a low-balance handler that never returns is shut down at the timeout and the write stands
core: I11 a handler that needs a connection gets one while the writer holds a pinned one (X269)
pro:  webhook: top-up a refund stops auto top-up instead of charging the card again
pro:  webhook: top-up a chargeback also drops the card it was disputed on

core 13/15, pro 87/89; restored, core 15/15 and pro 89/89, ledger.ex sha256
identical either side (f84cbcfc...)
```

The two Pro failures are exactly the tests X269 named, which is what says the
new assertions discriminate. The other two `low_balance_hook` tests pass under
C6, because their handler is not competing with a pinned connection: the control
distinguishes the tests that were affected from the tests that were not, rather
than failing the file.

**What happened to the pool.** Nothing, and that is the answer. The pool is 30
in both packages and was never the constraint: the constraint was one connection
pinned by the caller and a caller that would not proceed until the handler had
one. With the wait moved, the writer releases its checkout and the handler takes
a connection normally. Pro's whole suite now runs with **zero** occurrences of
the warning, against two before. In production the same change removes a
deadlock that would have appeared at pool exhaustion rather than at pool size 1.

### Crossing counts

Measured, not argued. Each is the `length/1` of the handler's own invocation log.

| Scenario | Handler invocations | `low_balance_crossing_id` |
|---|---|---|
| cross once, then five more debits below the line | **1** | one id, unchanged across all five |
| cross, recover above the threshold, cross again | **2** | two ids, `second != first`; nil in between |
| cross, then a deduplicated webhook redelivery, then a duplicate grant | **1** | unchanged |
| threshold lowered below the wallet, then a genuine fall | **2** | cleared on the lower, a new id on the fall |
| threshold cleared | no new alert | cleared |
| no threshold at all | **0** | nil |
| handler raises | **1** (it ran and raised) | set; telemetry `handler: :raised`; call returns `{:ok, txn}` |
| handler never returns, 50 ms timeout | **0** delivered | set; telemetry `handler: :timeout`; caller waited under 500 ms |

The "at least once" version of the first row would pass against the old
edge-triggered code. The count and the stable id are what distinguish them.

### What the accessibility assertion actually asserts

Not a class. `figure(html, "Owed")` finds the `.aurora-money__stat` whose
**label text** is `Owed` and returns its **value text**, and the assertions are

```elixir
assert figure(html, "Owed") == "$3.00"
assert aria(html, "Owed") == "Owed: $3.00 of executed cost is unfunded"

stripped = String.replace(html, "aurora-money__stat--owed", "aurora-money__stat")
assert figure(stripped, "Owed") == "$3.00"
assert aria(stripped, "Owed") == "Owed: $3.00 of executed cost is unfunded"
```

The last two are the point: with the colour class removed the word, the amount
and the screen-reader phrase are all still there, so nothing meaningful is
carried by the class. The zero case asserts `$0.00` for all four figures **and**
that six `.aurora-money__stat` elements are present, so a figure cannot pass by
being hidden.

### Per-bullet G06 coverage

Checked against `v1-release.md`'s G06 bullets rather than against this unit's own
criteria (finding X212).

| G06 bullet | This unit | Evidence |
|---|---|---|
| Allocation order: promotional, earliest expiry, oldest first | not this unit's (06a) | `Lots.list/2` **exposes** it and asserts it is the order the next debit takes: `test I10 Lots.list returns lots in the documented spend order` |
| No promotional lot absorbs a paid refund | not this unit's (06a, 06e) | untouched; `test I10 Lots.for_source returns exactly the lots funded by one payment intent` asserts a payment cannot reach a promotional lot |
| Expiry destroys only the expired lot's value | not this unit's (06a) | `test I12 expired value appears in expired and never in spendable` asserts the display half |
| Every figure reconstructible from the lot tables | **contributed** | `property I10 for any generated operation sequence, summary/1's figures agree with the lot tables`, which recomputes them with a second query |
| Recurring grants | 06d | not touched |
| Wallet migration | 06b | the X266 clause and its test |
| **Money displays separate spendable, held, expired and debt** | **owned** | `credits_figures_test.exs`, Pro's six I20 tests |
| **Exact unit conversion at display and provider boundaries** | **owned** | `Money.assert_range!/1` at six facade entry points, its three tests, and the fault-repo proof that it issues no query |
| **Low-balance signals use spendable and avoid duplicate alerts on replay** | **owned** | `credits_low_balance_test.exs`, eight tests, counts above |
| **API compatibility, or documented adapters** | **owned** | `06c-compatibility.md`, and the line-by-line diff above |

Two G06 bullets this unit does not own are **not** proved by it, and saying so is
the point of the table: the allocation order and the promotional-refund
exclusion are 06a's and 06e's.

## 5. Changes

### Public API (core)

Additive: `AuroraMeter.Credits.Lots.{list/2, get/2, allocations/2, for_source/2}`,
`AuroraMeter.Credits.{after_commit/1, deferred_effects?/0, cursor/1}`,
`AuroraMeter.Credits.Money.{assert_range!/1, max_micro/0}`,
`AuroraMeter.Schema.CreditTransaction.reversal?/1`,
`history/2`'s `:cursor`, four keys on `balance/1` and `summary/1`, three keys on
the credits PubSub payload, two on the low-balance payload, one telemetry
measurement and one metadata key on `[:aurora_meter, :credits, kind]`, two
metadata keys on `[:aurora_meter, :credits, :low_balance]`.

Compat: `reverse/4` writes `kind: :reverse`; `grant/3` and `grant_with_status/3`
answer `{:error, :duplicate_reference}` for a cross-tenant reference;
`history/2`'s default kinds gain `:reverse`; `Series` rejects `:reverse` as a
spend kind; `set_low_balance_threshold/2` recomputes the crossing; the
low-balance handler runs in a task and the telemetry event is emitted after it.
Each row is justified in `06c-compatibility.md`.

### Configuration

`:credits_low_balance_handler_timeout`, positive integer, default 5,000.

### Migrations

**None.** The one column this unit writes,
`aurora_meter_credit_balances.low_balance_crossing_id`, was created by 06a's
version 9.

### Documentation

core `docs/credits.md` (the four figures, the lot read API, the reversal kind,
the cursor, the crossing rule, the deferral rule, the corrected promotional
limitation), `docs/api.md`, `docs/configuration.md`, `docs/correctness.md`,
`CHANGELOG.md`. Pro `docs/correctness.md` and `CHANGELOG.md`.

### Operational procedures

One new operator fact, documented in `docs/credits.md`: the low-balance alert is
**at most once**, the crossing flag means "decided" rather than "delivered", and
the remedy for a lost alert is to lower and restore the threshold. 05e's
operational guide should carry the same sentence; it is listed as a handoff item
rather than edited here, because 05e owns that file.

## 6. Open defects

| Defect | Severity | Reproduction | Invariant | Next owner |
|---|---|---|---|---|
| ~~The low-balance handler cannot get a connection while the writer waits for it holding one~~ | was high: two Pro `refute_enqueued` tests passed because the handler had crashed | `tmp/v1/06c-c6.sh` restores the old shape and fails four tests, two per package | I11 | **CLOSED in this unit**, finding **X269**. The writer no longer waits: it starts a supervised watcher and returns. See section 4 |
| `Credits.reverse/4` still does not take the lot path, so on a cut-over wallet a paid refund consumes eligible lots in spend order | high, **not reachable**: no wallet is cut over and 06b's gate refuses one until `reverse_lot/4` exists | pre-existing, finding X250 | I10 | **06e** |
| `Allocator.plan/2`'s `{:reverse, ...}` creates debt without repaying it | medium, not reachable for the same reason | pre-existing, finding X262 | I10 | **06e** |
| `summary/1`'s `runway_days` is still derived from `available` rather than from `spendable` | low | by inspection; deliberate and documented in the function's own docs | I11 | recorded as **X270**, for 08b or 10a to decide |

No test is skipped by this unit. The four `:headless`-tagged core tests are
excluded from an ordinary `mix test` and run in command 2, which is the
pre-existing arrangement.

## 7. Handoff

**Where the work stopped.** Both packages are green, uncommitted, on their
starting SHAs. Evidence is this file plus `06c-compatibility.md`,
`06c-lots-api.md`, `i11-low-balance.md` and `06c-deferral.md` here, and
`06c-pro-displays.md` in Pro. The README row for 06c is `EVIDENCED` with its
criteria unticked; a reviewer other than the author ticks them (rule 4).

**What to read.** `06c-compatibility.md` first: it is the table the whole unit
turns on. Then `docs/credits.md`, which is the version of the same facts a host
reads.

**What must not change.**

- `AuroraMeter.Schema.CreditTransaction.reversal?/1` is the **one** predicate
  that knows both permanent reversal shapes. A second copy is the one that gets
  the older shape wrong. `Series` scores by `category` for the same reason, and
  that is why its output is identical across the change.
- `LotMigration.step/2`'s two reversal clauses are both permanent.
- `Credits.reverse_lot/4` must **not** be defined until 06e wires the lot-aware
  refund path: 06b's cutover gate is `function_exported?/3` on it, so defining it
  opens the gate.
- The low-balance handler runs in a watcher the writer does **not** wait for.
  Restoring the wait reintroduces X269: the writer may be holding a pinned
  connection (`AuroraMeter.Pro.Lock.with_lock/2` does) and the handler may want
  one. `tmp/v1/06c-c6.sh` is the control that proves it.
- The crossing flag is written inside the ledger's own transaction. Moving it
  outside would let a rolled-back write leave a standing crossing.
- The deferral queue is process bound because Ecto's transaction scope is. Any
  other store would have to be told when the process died.

**Next verification target.** For 06e: `Credits.Lots.for_source/2` and
`Schema.CreditTransaction.reversal?/1` are the two seams it was promised, so its
first target is replacing `AuroraMeter.Pro.Credits.grant_for/1` and
`reference_total/3` with them, and then `reverse_lot/4`. For 08b: the four
figures and the `spendable_after` measurement are in place.
