# 06e (core): `reverse_lot/4`, `restore_lot/4` and the X262 allocator fix

Build unit **06e**, V1 task **06.06**, gate **G06 bullet 5**. This is the core
half: the two public functions Pro calls, the allocator change they rest on, and
the cutover gate they open. The Pro half is
`aurora_meter_pro:docs/evidence/v1/phase-06/06e-report.md`.

## 1. Tasks, repository and exact source

| | |
|---|---|
| V1 task | **06.06** (Pro integration), core half |
| Repository | core `aurora_meter`, branch `aurorameter-v1` |
| Base SHA | `d78f575a29f611e52b395493196f401f45bafd80` |
| State at hand-back | **dirty, uncommitted by instruction** (programme rule 4: the author does not commit) |
| Patch sha256 (tracked, `git diff \| sha256sum`) | `0e4fc73823c13e64b00bb87410686b014786383f95b3cd04a1295b22c9cd1d4e` |

Modified, tracked: `CHANGELOG.md`, `docs/correctness.md`, `docs/credits.md`,
`lib/aurora_meter/credits.ex`, `lib/aurora_meter/credits/allocator.ex`,
`lib/aurora_meter/credits/ledger.ex`,
`lib/aurora_meter/credits/lot_migration.ex`,
`test/aurora_meter/credits/allocator_test.exs`,
`test/aurora_meter/credits_lot_migration_test.exs`,
`test/aurora_meter/credits_model_test.exs`,
`test/aurora_meter/exporter_case_test.exs` and
`test/support/aurora_meter/test/kill.ex` (the two teardown races in section 9;
both are test support and neither changes a line of shipped library code).

New, untracked: `test/aurora_meter/credits_lot_reversal_test.exs` and this file.

Pro at `20f29a63e3255141360c550d55ee96855c0a63e0`; storefront at
`1f3cb88dc62424da8c844386c958658a3254e657`.

## 2. Schema, toolchain and environment

| | |
|---|---|
| Core schema version | **9, unchanged. No DDL in this unit.** |
| Pro schema version | **10, unchanged. No DDL.** |
| Elixir / OTP | 1.20.1 / OTP 29 (erts 17.0.1) |
| Postgres | 16.13 on the `aurora-meter-pro-testdb` container, port 5490 |
| Stripe CLI | 1.43.7, test mode |
| Mix lane | every command through `tmp/v1/mixlane.sh core`, `DB_PORT=5490` |

## 3. The two functions

```elixir
@spec reverse_lot(tenant, pos_integer(), String.t(), keyword()) ::
        {:ok, txn()} | {:error, :duplicate_reference | :no_matching_lots | :exceeds_source}

@spec restore_lot(tenant, pos_integer(), String.t(), keyword()) ::
        {:ok, txn()} | {:error, :duplicate_reference | :no_matching_lots | :exceeds_reversed}
```

Options, both: `:source` (**required**), `:metadata`, `:allow_partial`
(default `false`).

### `:source` is validated, not widened

`:source` must be exactly `%{payment_intent_id: binary}` (string keys accepted,
because jsonb has no atoms). Anything else raises `ArgumentError` with the same
sentence `Lots.for_source/2` uses: a source key the matcher does not understand
would match every lot, and a refund against every lot is not a near miss.
Rejected in the test `I10 the :source option is validated rather than widened`:
`[]`, `%{}`, `%{payment_intent_id: _, checkout_session_id: _}`,
`%{promotion: _}`, a non-binary value, and a bare string.

It is **stricter than `Lots.for_source/2`**, which also matches
`recurrence_key`, and deliberately: the allocator scopes a reversal by
`payment_intent_id` alone, so accepting a second key would silently widen what
a refund may take.

### Every error tuple, with its reproduction

| Error | When | Reproduction |
|---|---|---|
| `:duplicate_reference` | the reference already exists in that kind's namespace | `I10 reverse_lot and restore_lot are idempotent on the reference` |
| `:no_matching_lots` | the tenant has no lot carrying that payment: an unknown payment, or a wallet with `lots_enabled_at IS NULL` | `I10 reverse_lot with no matching lots returns no_matching_lots` |
| `:exceeds_source` | `reverse_lot/4`, `allow_partial: false`, amount above what the payment's lots can still give back, **or nothing left to take** | `I10 reverse_lot above the cap returns exceeds_source and writes nothing` |
| `:exceeds_reversed` | `restore_lot/4`, `allow_partial: false`, amount above `SUM(lot.reversed)` | `I10 restore_lot is capped by the lots' reversed total` |

A refused call writes **nothing**: no ledger row, no allocation, no movement on
the lot. Asserted directly (`allocations(tenant) == []`, history length 1, the
balance unchanged) rather than inferred from the return value.

### The allocation rows each writes

`reverse_lot/4` writes one `reverse` allocation per lot touched, in spend order,
naming the bucket it came out of:

| kind | from_bucket | to_bucket | raises debt |
|---|---|---|---|
| `reverse` | `available` | `reversed` | no |
| `reverse` | `consumed` | `reversed` | **yes, by the same amount** |
| `reverse` | `reserved` | `reversed` | no (and `held` falls by the same) |

plus, when the reversal created debt, `consume` allocations on the wallet's
remaining **non-promotional** lots that repay it (section 4).

`restore_lot/4` writes one `restore` allocation (`reversed` to `available`) per
lot, then the ledger's ordinary `consume` repayments out of what came back.

Two lots from one payment, asserted exactly in
`I10 reverse_lot writes one reverse allocation per lot touched`:

```
{:reverse, :available, :reversed, 4_000_000}   # lot "pi_1"
{:reverse, :available, :reversed, 2_000_000}   # lot "pi_1:adjust"
```

### Idempotency

Both are keyed on `reference` in their own kind's namespace, which is the
database's separation and not a convention: the unique index is on
`(kind, reference)`, `reverse_lot/4` writes `kind: :reverse` and
`restore_lot/4` writes `kind: :grant`. A restoration may therefore carry the
string a reversal already used, which the idempotency test asserts.

## 4. X262: the reversal now carries the debt, and repays it

**The finding.** `Allocator.plan/2`'s `{:reverse, ...}` created debt without
repaying it and its request tuple did not even carry the debt, where the other
five did. The book then held `debt > 0` beside availability other lots still
had, which LI-06a-5 forbids, and `{:hold, ...}` refused a hold the legacy ledger
accepted.

**The fix, and the one thing it may not do.** The tuple is now
`{:reverse, payment_intent_id, amount, now, debt}` and the debt is repaid, out
of the wallet's remaining **non-promotional** eligible availability.

X262's own measurement patched the allocator to repay out of `eligible/2`, which
is every lot in spend order, and spend order takes **promotional first**. That
would erase exactly the credit this unit exists to protect:
`architecture-map.md` 7.2 says "promotional lots are never touched by a paid
reversal", `v1-release.md` 10.1 says "promotional lots cannot absorb a paid
refund simply because they were created later", and 06e's first acceptance
criterion says the promotional lot ends untouched at 4 USD available with debt
up by 6 USD. So the repayment is scoped to non-promotional lots.

**The balance is identical either way** (the projection subtracts debt, so
moving X out of `available` while debt falls by X is balance neutral), which is
why this had to be asserted on the lot and on the allocation rows rather than on
any wallet figure. That assertion is in
`I10 reverse_lot of a spent lot raises debt by the unrecoverable amount`:

```elixir
promo_id = lot(tenant, "promo").id
refute Enum.any?(allocations(tenant), &(&1.lot_id == promo_id))
```

**The cost, stated.** Where the only availability left is promotional, the debt
stays and LI-06a-5 is false for that wallet until the next incoming value
repays it. That is forced by the sentence above and is recorded as finding
**X277**.

### The measurement, at five fixed seeds

`tmp/v1/06e-property-seeds.sh` runs 06b's generated-history migration property
at seeds 0, 1, 7, 42 and 1337, forty histories each. The control turns
`repay_from_purchased/5` into a no-op and changes nothing else
(`tmp/v1/06e-x262-control.py`), and the file's sha256 is
`fc00a2927d7f32cc793b0e8c28c2ffa90fc3197b3b2eeb35a1fe37c97ed88a3c` before the
break and after the restore.

| seed | compared, with the fix | compared, control | `hold_unbacked`, with the fix | `hold_unbacked`, control |
|---|---|---|---|---|
| 0 | 27 | 27 | 0 | 1 |
| 1 | 31 | 29 | 0 | 1 |
| 7 | 32 | 30 | 0 | 2 |
| 42 | 21 | 21 | 0 | 0 |
| 1337 | 31 | 31 | 0 | 0 |

`hold_unbacked` closes at every seed that raised it, and the migration reaches
**two more wallets** at seeds 1 and 7. Seed 0 trades one `hold_unbacked` for one
`expire_reserved_grant` (the same wallet, blocked for a different reason, so the
reach is unchanged); seed 42 moves one wallet from `promotional_divergence_grant`
to `reversal_took_reserved`. Full per-seed refusal maps in
`tmp/v1/06e-logs/property-seeds.log` and `tmp/v1/06e-logs/control-x262.log`.

This differs from X262's own prediction, which was that the repayment would
change nothing but `hold_unbacked` (`compared` 28, 22, 26 either side). The
narrower, promotional-excluding repayment **raises** reach at two of five seeds.
Recorded in the finding rather than smoothed over.

### The one place the migration fold changed

`LotMigration.check_reversal/5` summed **every** movement in the plan to decide
whether a legacy reversal row took as much as it claimed. A reversal's plan can
now carry `consume` movements that are not part of the reversal at all, so a
repayment of X would have hidden a reversal that fell X short. It now sums only
movements whose `to_bucket` is `:reversed`. That is the only change to 06b's
fold, and it is required by the allocator change rather than incidental to it.

## 5. The gate, and that it opens

`LotMigration.cutover_blocked/0` is
`function_exported?(AuroraMeter.Credits, :reverse_lot, 4)`. Defining the
function opens it, so a stub would have opened it too, and **nothing in the
suite asserted the gate ever opens** before this unit: only that it was shut.

`X250 the cutover gate is open, and a wallet really cuts over through the
production route` now asserts, in one test and without the maintainer door
(`allow_lot_cutover` is deliberately not set):

1. `cutover_blocked() == nil` and `function_exported?(Credits, :reverse_lot, 4)`;
2. a legacy wallet (10 USD paid as `pi_<n>`, 6 USD spent) migrates through
   `LotMigration.run(shadow: false, allow_cutover: true)` with `state: :migrated`,
   `lots_enabled_at` set, a checkpoint written and its three figures unmoved;
3. a 4 USD promotion granted **after** the payment and the spend;
4. a 10 USD `reverse_lot/4` for that payment leaves the paid lot at
   `reversed = 10 USD`, the promotional lot at `available = 4 USD, consumed = 0`
   and `debt = 6 USD`;
5. and `{:error, :cutover_not_requested}` still answers a run that did not ask.

**The negative control** (`tmp/v1/06e-core-control.py`) replaces
`reverse_lot/4`'s planner request with the wallet-wide `{:debit, ...}`: the stub
06e could have shipped. It fails **12 of 39** tests across
`credits_lot_reversal_test.exs` and `credits_lot_migration_test.exs`, including
the criterion-1 test, the gate test and X274's. The file's sha256 is
`b1fe3d0c0a910a21e043a50c4da6b9e43f0d5648a78db5b63c1c1cfa0df7b6d4` before the
break and after the restore.

## 6. X274: what the open gate makes reachable

06d's recurring allowances refuse a wallet whose `lots_enabled_at` is null, and
no wallet had it set, so the whole feature could not reach a production wallet.
`X274 a wallet the migration cut over takes a recurring allowance and still
refunds right` is the first test where one arrives on the lot path through the
production route and then takes an allowance. What it asserts, in order:

1. `Recurrences.lots?(tenant)` is false before the migration and true after;
2. a real `Recurrences.run/1` at a frozen September instant grants **1**;
3. the allowance lot holds 5 USD available;
4. a 5 USD `reverse_lot/4` for the wallet's first payment (whose 5 USD had been
   wholly consumed by an earlier 6 USD debit) reverses that lot in full,
   creates 5 USD of debt, and **repays 4 USD of it out of the wallet's two
   other paid lots**, leaving `debt = 1 USD`;
5. the allowance ends `available: 5 USD, consumed: 0, reversed: 0`.

So a recurring allowance and a paid refund do not interfere, and the debt a
refund creates is repaid by paid credit and never by the allowance.

## 7. The cross-oracle property, and a correction to X250

X250 says 06a's cross-oracle property filters `:reverse` out of its generated
histories and that "when 06e lands, the filter comes out". **It does not, and
the reason is worth having.** 06e adds a *second* function scoped to a payment's
lots and deliberately leaves `Credits.reverse/4` wallet wide for hosts with no
payment provenance. The command the generator issues still takes the spend-order
path and still disagrees with a model that reverses paid lots only. Comparing
the model against the lot-scoped path needs the generator to mint payment ids,
the model's grants to carry a `source` and `LedgerModel.reverse_from/3` to scope
by it: real work on 01e's oracle, and doing it inside 06e would make the oracle
agree with the implementation by construction, which is the one thing a second
implementation must not do. The comment in `credits_model_test.exs` is corrected
and this is finding **X278**.

What **did** come out is the filter on 06a's *self-consistency* property:
`credits/allocator_test.exs`'s conservation property now generates `:reverse`
and `:restore` requests as well as `:debit` and `:hold`, over a book whose lots
carry history (`consumed`, `reversed`) and provenance (half the purchased lots
carry the payment the requests name). Before, every generated lot was wholly
available and carried no `source`, so those two requests would have moved
nothing and the property would have been green over two arms that never ran.

## 8. Commands, exit codes and seeds

Every command through `tmp/v1/mixlane.sh core`, `DB_PORT=5490`.

| Command | Seed | Exit | Result |
|---|---|---|---|
| `mix compile --warnings-as-errors` | | 0 | |
| `mix test test/aurora_meter/credits_lot_reversal_test.exs` | 0 | 0 | 12 passed |
| `mix test test/aurora_meter/credits_lot_migration_test.exs` | 0 | 0 | 27 passed |
| `mix test` | 0 | 0 | **1657 passed** (73 doctests, 17 properties, 1567 tests), 4 excluded |
| `mix check` | random | **0** | 1657 passed, docs generated |
| `tmp/v1/06e-property-seeds.sh` (migration property) | 0, 1, 7, 42, 1337 | 0 each | green at all five, per-seed table in section 4 |
| `tmp/v1/06e-property-seeds.sh` (lots, model, allocator, reversal, migration) | 0, 1, 7, 42, 1337 | 0 each | 101 passed (10 properties, 91 tests) at every seed |
| `tmp/v1/06e-core-headless.sh` | 0 | **0** | `headless ok`, then **1568 passed** (69 doctests, 17 properties, 1482 tests) |

### The headless leg (I20, D12)

`AURORA_HEADLESS=1`, `_build/test/lib/{aurora_meter,oban}` removed, recompiled
with `--warnings-as-errors --force`, and a real cycle driven with
`Code.ensure_loaded?(Oban)` and `Code.ensure_loaded?(Phoenix.LiveView)` both
**false**. `reverse_lot/4` and `restore_lot/4` are core, MIT and not optional: a
host with its own payment rail and neither Oban nor Phoenix must be able to
scope a refund to the payment that funded it, and the cutover gate an operator
reads before running the migration must answer on that host too.

What the run asserts with nothing optional loaded: both functions are exported;
`LotMigration.cutover_blocked()` answers `nil`; the `:source` validation raises
for an unsupported key and for a missing source; and the whole of criterion 1 on
a real database (10 USD paid, 6 USD spent, 4 USD promotion, 10 USD refunded,
leaving the paid lot at `reversed = 10 USD` and the promotional lot at
`available = 4 USD, consumed = 0`), followed by a `restore_lot/4` that puts it
back. Baseline before this unit: 1555.

Baseline before this unit: 1644 passed. The 13 new tests are the 12 in
`credits_lot_reversal_test.exs` plus the rewritten gate test, less the one it
replaced.

### The fixed-seed sweep, per seed

| seed | 06b replay property | 06a cross-oracle |
|---|---|---|
| 0 | compared 27, refused 14 | compared 17, diverged 3 |
| 1 | compared 31, refused 10 | compared 15, diverged 5 |
| 7 | compared 32, refused 9 | compared 14, diverged 6 |
| 42 | compared 21, refused 20 | compared 15, diverged 5 |
| 1337 | compared 31, refused 10 | compared 19, diverged 1 |

Neither property compared nothing at any seed, which is the teardown assertion
that makes a green run mean something (X125's shape, and the reason X276 put
this sweep in the gate).

## 9. Two teardown races, closed after the review

The orchestrator's independent `mix check` of core exited **2** where mine
exited 0:

```
1) test coverage reporting the suite names every area it could not script
   (AuroraMeter.ExporterCaseSelfTest)
   ** (exit) exited in: GenServer.stop(#PID<0.32496.0>, :normal, :infinity)
       ** (EXIT) no process
   stacktrace: ExUnit.OnExitHandler.exec_callback/1
```

It does not reproduce in isolation (five fixed seeds, 34 passed each) and the
file is byte identical to 06d's commit, so it is not this unit's code. It is a
teardown race that full-suite load makes reachable, and it is the family
`open-findings.md` X260, X241 and X264 are already about.

### X284: the exporter journal's teardown

**The mechanism.** `JournalScript.stop/1` was
`if Process.alive?(pid), do: Agent.stop(pid), else: :ok`. Three facts make the
gap between the check and the call reachable:

1. the journal is `Agent.start_link/2`ed inside the **test** process, so it is
   linked to it;
2. `ExUnit.Runner` exits a test process with **`:shutdown`** once its body has
   run, and a link propagates `:shutdown` where it would ignore `:normal`;
3. `on_exit` callbacks run later, in `ExUnit.OnExitHandler`, a **different**
   process.

So the link is already tearing the journal down when the callback looks at it.
`Process.alive?/1` answers `true`, and the `Agent.stop/1` microseconds later
exits. ExUnit reports that as the **test** failing, in a teardown that had
nothing to say about the test.

**The fix** is to call `Agent.stop/1` with no guard and tolerate exactly the
reasons that mean "it is gone", re-raising anything else, so a journal that
times out or crashes on the way down still fails the teardown. There is no
window to widen, because nothing can die between a call and its own failure.
The `is_pid/1` guard keeps the other half of the assertion: a teardown handed
`nil` still fails.

**The measurement** (`tmp/v1/06e-teardown-race.exs`, the production shape:
a linked Agent, an owner that exits `:shutdown`, and a different process
stopping it):

| implementation | rounds | uncaught exits |
|---|---|---|
| `if alive?, do: stop` | 24,000 (3 runs of 8,000 concurrent) | **29** (10, 12, 7) |
| shipped | 24,000 (3 runs of 8,000 concurrent) | **0** (0, 0, 0) |

**Two things the measurement corrected, and neither was guessable.** A serial
loop of 15,000 rounds hit it three times in one sitting and zero in the next,
which is not a measurement: **concurrency is what makes this race reachable**,
and that is the same sentence as "only under full-suite load". And the VM
states the failure in **two** shapes:

```
{:noproc, {GenServer, :stop, [pid, :normal, :infinity]}}                    24 times
{{:shutdown, {:sys, :terminate, [...]}}, {GenServer, :stop, [...]}}          5 times
```

The first draft of the fix caught only the first, because it matched
`:shutdown` as an **atom** where the VM sends it as a **tuple**, and it would
have left about one failure in six. The shipped `gone?/1` handles both and
nothing else.

### X260: `Test.Kill`'s late monitor, and why one fix does not cover both

`await/4` called `Task.Supervisor.start_child/2` and then `Process.monitor/1`:
a monitor established **after** the process could already have died. A worker
armed with `:exit_kill_self` can be gone first, `Process.monitor/1` on a dead
pid delivers `:noproc` immediately, and `killed!/3` raises naming the one thing
that did not happen.

**It is the same family and it needs the opposite fix.** X284's caller only
wants the process gone, so "it is already gone" is an acceptable answer and
tolerating the error is right. Here the **reason** is the entire subject: once
the monitor is late, the real reason is unrecoverable, because `:noproc` is all
the VM will ever say. So the monitor has to exist before the worker can die,
and with `start_child` the only way is to make the worker ask permission:

```elixir
{:ok, pid} = Task.Supervisor.start_child(supervisor, fn ->
  receive do
    {:aurora_kill_go, ^parent} -> send(parent, {:aurora_kill_result, self(), fun.()})
  after
    @ready_timeout -> exit(:aurora_kill_never_released)
  end
end)

reference = Process.monitor(pid)
send(pid, {:aurora_kill_go, parent})
```

That is the fix X260's own row proposed. `@ready_timeout` (30 s) turns a worker
whose caller died into a named exit rather than a process sitting in a `receive`
for the life of the suite.

### Verification of both

| Run | Exit | Result |
|---|---|---|
| `harness_test.exs`, `kill_test.exs`, `exporter_case_test.exs`, seeds 0, 1, 7, 42, 1337 | 0 each | 84 passed each (`tmp/v1/06e-x260-seeds.sh`) |
| core `mix check`, twice | **0** both | 1657 passed |

Both files are test support, so neither changes a line of shipped library code.

## 10. What is weak

- **LI-06a-5 is still false for one shape**, and by construction: a wallet whose
  only remaining availability is promotional keeps its debt after a reversal,
  because repaying it would take the promotion. `{:hold, ...}`'s blanket refusal
  on `debt > 0` is then conservative rather than wrong in every reachable case
  but one (promotional availability strictly greater than the debt), where it
  refuses a hold the legacy ledger would have accepted. Finding **X277**.
- **`restore_lot/4` restores in spend order, not newest reversal first.** 06e's
  build document says "newest reversal first"; 06a's `{:restore, ...}` walks
  `funded_by/2`, which is spend order. Nothing in V1 distinguishes them, because
  a payment usually has one lot, and the difference is invisible in the ledger.
  It is documented as it behaves rather than as the plan described it. Finding
  **X279**.
- **The core facade tests are named `I10`, not `I13`.** `docs/correctness.md`
  says I13 is Pro's and core states only its own half; the build document names
  them `I13`. Renaming was the smaller lie.
