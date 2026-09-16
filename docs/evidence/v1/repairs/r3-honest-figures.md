# Repair unit R3: honest figures for a wallet in debt

A repair unit, not a numbered build unit. It closes the half of finding **X357**
that the orchestrator decided in **X361** ships now, answers **X359**, and
writes the other half of X357 up for the owner rather than taking it.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only. Nothing here is invented: a command that was
> not run is named as not run.

Rule 4 applies. Nothing in this file ticks a checkbox, nothing is committed, and
the tree is left dirty for the reviewer.

## 0. The decision, written before the code

### The defect, stated as a question about who is lying to whom

After repair unit R2 a wallet can owe money and hold credit at the same time,
because a promotion is never consumed to repay a debt. That is R2's decision and
R3 does not revisit it. What R3 fixes is that the wallet then **told a host it
could spend that credit and refused every attempt to**:

```
balance: 4_000_000   promotional: 8_000_000   debt: 4_000_000
spendable: 1_000_000   promotional_spendable: 5_000_000      <- both positive
Credits.hold(tenant, 1, ref)  ->  {:error, :insufficient_credits}
```

Two separate faults, and only the second is close to the commercial question:

1. `spendable` and `promotional_spendable` claimed availability the planner
   would refuse. `spendable`'s own docstring says it is "what a hold or a debit
   would actually be allowed to take"; it was `eligible_available - debt`, which
   is positive whenever the wallet holds more than it owes, while
   `Allocator.plan/2`'s `{:hold, ...}` and `{:debit, ...}` clauses refuse on
   `debt > 0` before looking at a lot.
2. The refusal said `:insufficient_credits`, which is the ledger's word for a
   wallet that was never funded. A support agent reading it goes looking for a
   grant that is not missing.

**Neither is a commercial question.** Whatever the owner decides about X361's
other half, a figure that says "you may spend 5 USD" beside a call that refuses
one micro-dollar is wrong, and a refusal that names the wrong cause is wrong.

### Which fields are claims about spending, and which are totals

This is the judgement the brief asked for, field by field, and it is the
substance of the fix rather than an afterthought.

| Field | Judgement | What R3 did, and why |
|---|---|---|
| `spendable` | **Spendability claim.** Documented as "what a hold or a debit would actually be allowed to take, and exactly the figure `sufficient?/2` compares against" | **Changed.** Never positive while `debt > 0`. Capped at what the planner accepts, **not clamped at zero**: where the debt exceeds what is left it stays negative, because 06c's reason for not flooring it is still right and only the positive direction can mislead |
| `promotional_spendable` | **Spendability claim.** Documented as "the part of `spendable` that came from promotional lots", so it answers the same question about the same planner | **Changed.** Reads `0` while `debt > 0`, for exactly the same reason. A part cannot be larger than the whole it is part of, which is now an assertion |
| `balance` | **Total.** Everything granted minus everything settled, debited or expired, and the checked projection `sum(available + reserved) - debt` | **Unchanged.** The credit is really there. Flattening it would mean the conservation check, the CHECK constraints and `Credits.history/2` all disagreed with the figure |
| `promotional` | **Total.** The promotional part of the balance | **Unchanged.** R1 and R2 exist to make this survive a refund whole; reporting it as zero would hide the thing they protect. A customer's promotion is not gone, it is frozen |
| `held` | **Total.** The sum of pending holds, and the checked projection `sum(reserved)` | **Unchanged.** Not a claim about anything a caller may do next |
| `debt` | **Total.** What is owed | **Unchanged.** It is the reason the other two read zero |
| `expired` | **Total.** Value destroyed by expiry | **Unchanged.** Irrelevant to the refusal |
| `available` | **Derived total, and the hard case.** `balance - held`, published since 0.1 and documented as that identity | **Unchanged, deliberately, and it can be positive on a frozen wallet.** Three reasons. (a) It is an arithmetic identity a host can recompute from two other figures, so changing it would make `available == balance - held` false, which is a harder promise to break than a soft one. (b) `runway_days` divides it (`summary/1`), and the docstring says in as many words that it divides `available` rather than `spendable` "deliberately: it is a published figure with a published meaning, and changing what it divides would move every dashboard's number without anything saying so" (X270 is the open finding about that choice, and it is not R3's). (c) The word "available" in this package has meant `balance - held` since before lots existed and means "not committed to a hold", not "spendable". **The mitigation is documentation, not silence**: `t:AuroraMeter.Credits.balance/0` and `docs/credits.md` now both say that `available` can be positive on a wallet that may not spend, and name `spendable` as the figure that answers the other question |
| `currency`, `low_balance_threshold` | Neither | Unchanged |
| `summary/1`'s `spent_this_period`, `granted_this_period`, `daily_burn`, `runway_days`, `period` | Neither (history and derivation) | Unchanged. `runway_days` moves only if `available` moves, which it does not |

**Pro adds no figure of its own.** `AuroraMeter.Pro.Dashboard.load/2` passes
`AuroraMeter.Credits.summary/1` through unchanged and
`AuroraMeter.Pro.Components.money_section/1` renders `spendable`, `held`, `debt`
and `expired` from it with `Map.get(credits, key, 0)`. So Pro's "Spendable" row
became honest the moment core's did, and the only Pro change is a docstring and
a test. That test is the point: every other money test in Pro hands
`money_section/1` a map written by hand, so none of them could ever have caught
this.

### The refusal term, and what the error vocabulary already offered

Checked before adding to it. The ledger's refusal vocabulary is
`:insufficient_credits`, `:duplicate_reference`, `:not_found`,
`:already_settled`, `:no_matching_lot(s)`, `:exceeds_source`,
`:exceeds_reversed`. **Nothing in it names a debt**, and `:insufficient_credits`
is the word used for the unrelated "nothing eligible left" case, including for
credit that is past its `expires_at` before the sweep reaches it. So the right
answer is a new term, `:debt_outstanding`, and `api-change-map.md` gains two
rows and a section (1.3 and the new 1.3.1) saying so **loudly** rather than
quietly.

**It is an API change and it is classified honestly as additive on a path no
published version can reach.** `docs/support-policy.md` promises the error
tuples are covered by SemVer ("`{:error, :insufficient_credits}` will not become
`{:error, :no_credit}`"); R3 adds a term rather than renaming one, and the
promise is kept in the only sense a caller can observe:

1. Both refusals are in the `{:hold, ...}` and `{:debit, ...}` clauses, which
   `Ledger.hold/4` and `Ledger.debit/5` reach only when `lots?(row)` is true.
2. `debt` is a schema-9 column. The last published release, **0.5.0**, is schema
   **6**: the column does not exist there, there are no lots, and `debt` is `0`
   by construction.
3. A legacy wallet goes on refusing with `:insufficient_credits`, including when
   its balance is negative from a settlement above its hold. That is asserted on
   two legacy wallets rather than argued (section 4.3).

So a host meets the new term at the same moment it meets credit lots, which is a
migration it runs on purpose and a release note it has to read. The upgrade
instruction is in `CHANGELOG.md`, in `docs/upgrading-to-lots.md` and in
`api-change-map.md` 1.3.1.

### What R3 deliberately did not do

- **It did not relax the refusal** from `debt > 0` to `spendable/3 < amount`.
  That is X357's other half, it partially reverses X251's fix, it is a second
  amendment to `architecture-map.md` 7.2 inside one release, and the question
  underneath it is commercial. It is the owner's (X361) and it is written up for
  them in **section 6**.
- **It did not amend `architecture-map.md`**, and the file's sha256 is unchanged
  (section 1).
- **It did not edit `ledger_model.ex` or the cross-oracle's exclusion
  predicate.** Both sha256s are unchanged. What it did edit in
  `credits_model_test.exs` is two clauses of the result **classifier**, measured
  at five fixed seeds to be exactly behaviour preserving (section 4.6).
- **It did not implement X359's strict mode.** Section 7 says why and what it
  did instead.

## 1. Tasks, repository and revision

| | |
|---|---|
| Unit | Repair unit R3 (not a `v1-release.md` task id) |
| Findings | **X357 resolved in part**, **X359 resolved**, **X361's shipping half delivered**; X361's commercial half written up and left open |
| Repositories | `aurora_meter` (core), `aurora_meter_pro` (Pro), storefront (build plans) |
| core HEAD | `7d0264f` on `aurorameter-v1`, **tree dirty** |
| Pro HEAD | `ff9419e` on `aurorameter-v1`, **tree dirty** |
| storefront HEAD | `324fa22` on `aurorameter-v1`, **tree dirty** |

The tree is dirty by design (rule 4) and also carries R1's, R2's, 09a's and
09b's uncommitted work. R3 touched none of 09a's or 09b's files.

Files R3 changed, sha256 as written:

```
core  a18f4b2e5dba74c89cfda0db531efe26a1657b0b7dd298b4e6c9ced4acacca0c  lib/aurora_meter/credits.ex
core  92d959ad3bd43eae1b36cab6bd27c100a061ecd9f0f626c4802e5a3f41a40dc3  lib/aurora_meter/credits/allocator.ex
core  46e31ed72144626ce031b80fa084de5eb90de2b48c010b5d3b09ef6084742a33  lib/aurora_meter/credits/ledger.ex
core  d8a0bd3b7319afb0c4a1930e5c166ea79ff0c2d8ddb017b41fee348b2e83f62b  test/aurora_meter/credits/allocator_test.exs
core  aa51b3c4f834b1221aa5c4633ab2173d827eebaa2098bd54d518f4b1be397002  test/aurora_meter/credits_figures_test.exs
core  449749be50aaed4385c4805b5caf20d37ec240cf07032dd9e10bb754ae2f4b16  test/aurora_meter/credits_lots_test.exs
core  53024ea807b564bf3551a970ed14a706ff1fdf951ffaf709ad24ea3d0a8768d3  test/aurora_meter/credits_model_test.exs
core  94996fb699efb9076b1c3c4e577ec67515ef65fbcdc24bb47fb747b2c217819a  docs/credits.md
core  a5538e0a531ebd360b944f316653021c6e71b6acbe62f343540bb7b2a7dc7f0c  docs/upgrading-to-lots.md
core  b870dcf984ba202c73f022eaba8dcf8474e5a1bfc86602acf22f413419ab2bb3  docs/examples/prepaid-credits.md
core  ea9d4b8d0161009524e5e7cef677f694347ac8eb720b02dec4d6749cfc561a44  CHANGELOG.md
pro   503b668abaf7c4c24019e67253318a069e822b1804cd5b6d1d302f5cadad4cf9  lib/aurora_meter/pro/components.ex
pro   1582d561b5d3cada393e8b5e5c0c056c791a362307b6eafb29d004ecf3622681  test/aurora_meter/pro/dashboard_test.exs
pro   13e9122bed5b5e600ef0ae95d80b229f0c05fc65ea1e1c2935a4f02d8244cfec  CHANGELOG.md
store 7ea3f56dd4b1e81b4a4843099bf0b1637adbb531bd95f1dd1bf5f7283d4ecd8e  docs/v1/build-plans/open-findings.md
store a1aafe5cd75956d9ff90dd0e9b1df3a303e896be39608a8fd36a0c88b6830f1e  docs/v1/build-plans/api-change-map.md
store 983f7c41a842b738f299f454ef4012006bfcd51cf651072776b2392c7e8b465f  docs/v1/build-plans/phase-06/06a-lot-allocation-schema-and-engine.md
```

**Files R3 deliberately did not change, proved by sha256 rather than asserted**
(before snapshot `tmp/v1/r3/r3-before.sha256`, after `tmp/v1/r3/r3-after.sha256`):

```
core  4d1d583059c20d4b72ff2cdc53ca1247a43a8c7c5df8d76d676a2dd8b5d4ba05  test/support/aurora_meter/test/ledger_model.ex
core  4a8763afb9898bb1a79ce43c3728f71d815b1639b3dee57128f0a06415621b49  test/aurora_meter/credits_lot_reversal_test.exs
core  c720716e2d9f606e4710ef27ab555f03f6ac57fc499558d2ee024d4519b7657f  docs/api.md
core  92099083ce3787460e636ee44c41ad2f36fe28f69e89446fead815ecf2fd8469  docs/support-policy.md
pro   ca1c0344cd9c9dd81267d6e2858ecb8886b547fb8b10ff68f294e08ff579fc2d  lib/aurora_meter/pro/dashboard.ex
pro   fbde1cbd1d94a8f677b06c2ffa2b9e81e40950d71e45568350a75ddda536e4ad  test/aurora_meter/pro/credits_lots_test.exs
store 24bf95a742bcb5fc56aeabf49d1708a281c42382d219701ed64f111b3eb5ec13  docs/v1/build-plans/architecture-map.md
```

- **`ledger_model.ex` is 01e's oracle** and was not edited by R1, R2 or R3, under
  any variant of any experiment. Its digest is the one R2 recorded.
- **`architecture-map.md` is unchanged.** R3 amends no binding map; 06a's
  LI-06a-5 gains a **citation correction** only (section 7), not a change to the
  invariant.
- **`docs/api.md` is 09b's and is owed R3's two rows.** Section 8.
- `credits_lot_reversal_test.exs` is R1's and R2's and needed nothing.

`credits_model_test.exs` is the one test file R3 changed that it does not own
outright; what changed there is two clauses of `classify/3` and `same?/2` and
one entry in the allowed-class list, measured in section 4.6. **No assertion in
that file about a ledger value changed.**

## 2. Environment

| | |
|---|---|
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), JIT |
| OS | Ubuntu 24.04 under WSL2 on Windows 11 |
| Postgres | `postgres:16` in Docker container `aurora-meter-pro-testdb`, port 5490 (the package lane) |
| core package | 0.5.0, schema `@latest 10` |
| Pro package | 0.3.0, schema `@latest 11` |
| core `mix.lock` | `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0` |
| Pro `mix.lock` | `910d54651cd08dc350eadb29b0915ee662adba4125700d9b6161bdbfe9a08232` |

Every Mix command went through `bash tmp/v1/mixlane.sh <core|pro> mix ...`, the
shared `_build` lock. Other agents held the lane repeatedly.

## 3. Commands, logs and the control mechanism

All logs are under `tmp/v1/r3/` in the storefront checkout.

### 3.1 The baseline, and the one thing R3 could not measure

**A full-suite baseline was started before the first edit and never ran.**
`tmp/v1/r3-baseline.sh` was launched, sat waiting for another agent's hold on
the `_build` lane, and was killed once R3's first edit had landed, precisely so
that it could not be reported as a pre-edit measurement of a tree that had
already been edited. That is said plainly rather than dressed up: **R3 has no
full-suite number taken before its own first edit.**

What it has instead is stronger for the question at issue, and it is the run in
3.3: the **whole core suite with R3's three library files replaced by their
pre-R3 bytes**, which is the tree as it was for every purpose except R3's own
new assertions.

### 3.2 The snapshot, and how the pre-R3 bytes were recovered without `git`

X326 forbids `git checkout --`, and here it would also have been useless: the
tree carries four other units' uncommitted work, so git has no pre-R3 revision
of these files at all.

`tmp/v1/r3/rebuild_defect.py` reconstructs each pre-R3 file by **inverting every
edit R3 made to it**, and then proves the reconstruction against the sha256
taken before the first edit:

```
OK  lib/aurora_meter/credits.ex             reconstructed=c5894daf... expected=c5894daf...
OK  lib/aurora_meter/credits/allocator.ex   reconstructed=90919908... expected=90919908...
OK  lib/aurora_meter/credits/ledger.ex      reconstructed=6f163e1b... expected=6f163e1b...
```

It was re-run and re-verified after `mix format` and again at the end of the
unit. `tmp/v1/r3-control.sh` installs those bytes, refuses to run if any digest
does not match the expected line, runs the command, and restores the R3 files in
an `EXIT` trap, printing both digests each way.

### 3.3 Runs

| Run | Command | Log | Result |
|---|---|---|---|
| core, full | `mixlane.sh core mix test` | `r3-core-full.log` | **2130 passed** (81 doctests, 22 properties, 2027 tests), 8 excluded, exit 0 |
| Pro, full | `mixlane.sh pro mix test` | `r3-pro-full.log` | **1158 passed** (74 doctests, 1084 tests), exit 0 |
| **core, full, under the control** | `r3-control.sh core mix test` | `r3-control-core-full.log` | **2123/2130**, exit 2: **exactly R3's seven core controls fail and nothing else in the suite does** |
| core, targeted control | `r3-control.sh core mix test` over the three files | `r3-control-core.log` | 47/54, **7 failures** |
| Pro, targeted control | `r3-control.sh pro mix test .../dashboard_test.exs` | `r3-control-pro.log` | 21/22, **1 failure** |
| cross-oracle, pre-R3 | `r3-oracle-seeds.sh pre-r3 --control` | `oracle-pre-r3/` | 5 seeds, all pass |
| cross-oracle, R3 without the classifier clause | `r3-oracle-seeds.sh r3-no-harness` | `oracle-r3-no-harness/` | **3 of 5 seeds fail** |
| cross-oracle, R3 | `r3-oracle-seeds.sh r3-final` | `oracle-r3-final/` | 5 seeds, all pass, **identical counts to pre-R3** |
| ten-seed sweep of R3's properties, first version | `r3-seeds.sh` | `seeds/` (overwritten by the second) | **5 of 10 seeds failed on R3's own counters** |
| ten-seed sweep, after the fix | `r3-seeds.sh` | `seeds/summary.log` | **10 of 10 pass** |
| `mix check` | `mixlane.sh core mix check`, `mixlane.sh pro mix check` | inline | **exit 0 in both** |

Log digests are in `tmp/v1/r3/final-run.log` section 7.

Test counts per file, after R3 (`final-run.log` section 6): `allocator_test` 24
(3 properties, 21 tests), `credits_figures_test` 9 (1 property, 8 tests),
`credits_lots_test` 21, `credits_model_test` 28, `credits_lot_reversal_test` 18.

**The arithmetic on the totals, because a count taken from a shared tree is a
measurement of that tree.** R2 recorded core 2125 and Pro 1157. R3 adds
**three** core tests (one property in `allocator_test`, two tests in
`credits_figures_test`) and **one** Pro test, so 2128 and 1158 are R3's
contribution. Pro reads 1158 exactly. Core reads **2130**, two more than R3 can
account for: `credits_lot_reversal_test` and `credits_lots_test` are unchanged
in count, so those two tests appeared outside every file R3 touched, in a tree
four other agents were writing to throughout. That is recorded, not chased.

## 4. Results

### 4.1 The defect and the fix, on one forced wallet, field by field

The fixture is forced, not waited for, and it is the ordinary shape rather than
a contrived one: a wallet with a promotion **and an open hold** takes a refund
larger than the paid credit it has left.

`credits_figures_test.exs` / `test X361 a refund the wallet cannot cover reports
nothing spendable, names the debt and clears on a grant`. 10 USD paid with a
`payment_intent_id`, 9 USD of it spent, then an 8 USD promotion, then a 3 USD
hold (spend order reserves the promotion first), then a 5 USD wallet-wide
refund.

**Before the refund**, identical in both runs:

```
balance=9000000 held=3000000 available=6000000 debt=0 expired=0
promotional=8000000  spendable=6000000  promotional_spendable=5000000
  lot pay   (paid)         available=1000000 reserved=0       consumed=9000000
  lot promo (promotional)  available=5000000 reserved=3000000 consumed=0
```

**After `Credits.reverse(tenant, 5_000_000, ...)`.** One micro-dollar comes out
of the paid lot's `available`, four out of its `consumed`, and four become
`debt`; the promotion is byte identical, `updated_at` included (R1 and R2's
promise, asserted by struct equality).

| Figure | pre-R3 (measured, `r3-control-core.log`) | with R3 |
|---|---|---|
| `balance` | 4,000,000 | 4,000,000 |
| `held` | 3,000,000 | 3,000,000 |
| `available` | 1,000,000 | 1,000,000 |
| `promotional` | 8,000,000 | 8,000,000 |
| `debt` | 4,000,000 | 4,000,000 |
| `expired` | 0 | 0 |
| **`spendable`** | **1,000,000** | **0** |
| **`promotional_spendable`** | **5,000,000** | **0** |
| `sufficient?(tenant, 1)` | **true** | **false** |
| `hold(tenant, 1)` | `{:error, :insufficient_credits}` | `{:error, :debt_outstanding}` |
| `debit(tenant, 1)` | `{:error, :insufficient_credits}` | `{:error, :debt_outstanding}` |

The pre-R3 column is the row the control run printed when the test failed, not a
reading of the code: `assert after_refund.spendable == 0` / `left: 1000000`, and
`figures_1036: promotional_spendable 5000000 is larger than spendable 1000000`.

**Six of the eight figures did not move**, which is the judgement in section 0
made visible: the wallet really does hold 4 USD, 8 USD of it promotional, and it
really does owe 4 USD. What changed is only the two figures that claimed it
could be spent.

**The way out, asserted in the same test.** `Credits.grant(tenant, 4_000_000,
...)` of any category repays the debt out of the lot it is creating:
`debt: 0`, `spendable: 5_000_000`, `promotional_spendable: 5_000_000`, the
promotion still byte identical, and a hold of 5 USD is then accepted.

### 4.2 The assertion that carries the claim: the figure is attempted, not compared

`planner_agrees!/1` reads `Credits.balance/1` and then asks the ledger for
**exactly what that snapshot advertised**:

- `spendable > 0`: assert the wallet owes nothing (a positive figure beside a
  debt is the defect itself); refuse `spendable + tolerance + 1`; **accept
  `spendable`**, to the micro-dollar; and if `promotional_spendable > 0` on a
  cut-over wallet, assert that holding everything spendable leaves
  `promotional_spendable == 0`, which is what "the part of `spendable` that came
  from promotional lots" means.
- `spendable <= 0`: assert `hold(1)` and `debit(1)` are refused **with the same
  reason**, and that the reason is `:debt_outstanding` if and only if
  `debt > 0`.
- either way: `sufficient?(tenant, max(spendable, 1))` is true exactly when
  `spendable > 0`.

**Nothing in it compares a figure with a number written in the test.** A future
change that made `spendable` wrong in a new way would have to make `hold/4`
wrong in the same way to get past it. It returns the branch it took, so callers
can assert their cases reached the state they think.

The same law is asserted at the planner, over generated books, in
`allocator_test.exs` / `property X361 spendable/3 reports exactly what the
planner will accept, and names the debt when it will accept nothing`.

### 4.3 The states, covered deliberately rather than hoped for

`credits_figures_test.exs` / `test X361 the figures and the planner agree in
every state a wallet can be in` drives eight wallets and asserts the branch each
one reaches, then asserts the branch counts so a table whose rows all landed in
one branch fails:

| Wallet | Branch | What it pins |
|---|---|---|
| paid + promotional, one hold | spendable | the ordinary case still works |
| promotional only | spendable | a promotion is spendable when nothing is owed |
| **the refund wallet** | frozen | the X357 state: positive balance, positive promotion, `spendable` and `promotional_spendable` both `0` |
| settle above its hold, nothing left | frozen | `spendable` **negative**, not clamped |
| only credit is past `expires_at` | empty | refused with **`:insufficient_credits`**, which discriminates the two terms |
| legacy, funded, one hold | spendable | the legacy arithmetic is untouched |
| **legacy, overrun, balance negative** | empty | **`:insufficient_credits`**, no `debt`: no published version can see the new term |
| never funded | empty | `:insufficient_credits` |

### 4.4 Controls: eight, and all eight discriminate

Against the pre-R3 library files restored by sha256 (`r3-control-core.log`,
`r3-control-pro.log`):

| # | Test | Repository | How it fails on the defect |
|---|---|---|---|
| 1 | `AllocatorTest` property `X361 spendable/3 reports exactly what the planner will accept ...` | core | shrunk to `spendable 4172 is positive beside a debt of 1` |
| 2 | `CreditsFiguresTest` `X361 a refund the wallet cannot cover ...` | core | `assert after_refund.spendable == 0` reads `1000000` |
| 3 | `CreditsFiguresTest` `X361 the figures and the planner agree in every state a wallet can be in` | core | `promotional_spendable 5000000 is larger than spendable 1000000` |
| 4 | `CreditsFiguresTest` property `I10 for any generated operation sequence ...` | core | `a wallet with debt 48495276 refused with :insufficient_credits and should have refused with :debt_outstanding` |
| 5 | `CreditsFiguresTest` `I11 debt appears in debt and makes spendable zero` | core | the refusal term |
| 6 | `CreditsLotsTest` `I10 a settle above its hold records debt, which blocks a new hold ...` | core | the refusal term |
| 7 | `CreditsLotsTest` `X355 debt outlives promotional availability ...` (R2's) | core | the refusal term, and `spendable`/`promotional_spendable` |
| 8 | `Pro.DashboardTest` `X361 the dashboard shows nothing spendable on a wallet frozen by a debt, through the real ledger` | Pro | `data.credits.spendable` reads `1000000`; the page said `Spendable $1.00` |

**Control 1 is the one worth reading.** Its shrunk counterexample is a debt of
**one micro-dollar** beside 4,172 of availability: the smallest the defect can
be, and nothing to do with refunds.

**Control 8 is the one that answers "does a customer see it".** It builds the
wallet through the public API, calls `AuroraMeter.Pro.Dashboard.load/2` and
renders `money_section/1`, so it reads what a tenant reads.

**No control passed.** There is no anti-regression pin in this set that a
control could not move, so there is no "it passed and that is its job" entry
here.

### 4.4.1 The counters caught R3's own property measuring nothing, at half the seeds

This is the part of the unit a reviewer should read.

The first version of the two properties passed on the seed they were written
against and on the full-suite run. `tmp/v1/r3-seeds.sh` ran them at ten seeds:

```
seed 0     pass          seed 90210  pass
seed 1     pass          seed 5      FAIL: no generated history left the wallet in the frozen state
seed 7     pass          seed 13     FAIL: no generated case reached a debt standing beside MORE
seed 42    FAIL: no generated case reached a wallet with nothing eligible and no debt
seed 1337  FAIL: no generated case reached a debt standing beside MORE eligible availability
seed 271828 FAIL: no generated history left the wallet in the frozen state
seed 31415 pass
```

**Five of ten.** Both causes are X325 and X350's shape with a coin toss on top,
and in both the counters are what found it rather than a reviewer:

- the planner property drew `debt` as a uniform integer over 0..20,000,000, so
  the `debt == 0` arm was reached about never and the discriminating shape (a
  debt **smaller** than the eligible availability beside it) depended on luck;
- the figures property's generated history **could not put a wallet into debt at
  all** unless a hold happened to exist for the `:overrun` command to settle.

Both are fixed by generating the **shape** rather than hoping for it. The
planner property now draws a mode from
`[:spendable, :frozen_under, :frozen_over, :empty]` and `shape/2` and
`debt_for/4` make the case be that shape; the figures property draws a finisher
from `[:fund, :freeze, :drain]` and applies it after the generated history, each
of which lands the wallet in a known state whatever the history did. Re-run at
the same ten seeds: **10 of 10 pass**.

**And a finding that came out of it.** `credits_figures_test.exs`'s
generated-history property, whose whole subject is the four money figures
including `debt`, had never generated a wallet with a non-zero `debt`: every
generated settle is at or below its hold, no reversal is generated, and a
refused debit writes nothing. So `assert summary.debt == truth.debt` had only
ever compared zero with zero, and so had every claim it makes about what a debt
does to `spendable`. That is X360's shape in a second file. Recorded on X361's
row.

### 4.5 One implementation of the rule, for the same reason R2 gave

`Allocator.spendable_figure/2` and `Allocator.promotional_spendable_figure/2`
sit in the module that owns the refusal, beside the clauses they mirror.
`Allocator.spendable/3` (the planned book, telemetry's `spendable_after`, the
low-balance crossing), `Ledger.figures/1` (`balance/1` and `summary/1`) and
`Ledger.lot_spendable/3` (`Credits.sufficient?/2`) all come through them.

That is R2's argument one level along: *"a rule with two implementations has one
that is wrong"*. Before R3 the rule `available - debt` was written out three
times; if a fourth reader had been added it would have been written a fourth.

**The legacy branch of `figures/1` is deliberately left alone.** On a wallet
with `lots_enabled_at IS NULL` the figures are `balance - held` and
`row.promotional` and the refusal is `sufficient?/2`, which does not look at
`debt`; routing it through the helper would make the figure and that refusal
disagree if `debt` were ever non-zero there. The legacy wallets in 4.3 assert it
is not.

### 4.6 The cross-oracle: measured before it was touched, and behaviour preserving

Renaming the refusal breaks the comparison in `credits_model_test.exs`, because
01e's `LedgerModel` has **one** refusal atom and the ledger now has two. R3
measured that before changing anything, at five fixed seeds:

| seed | pre-R3 | R3, classifier untouched | R3, final |
|---|---|---|---|
| 0 | pass, compared 17 / diverged 3 | pass, 17 / 3 | pass, **17 / 3** |
| 1 | pass, 15 / 5 | **fail**, 8 / 1 | pass, **15 / 5** |
| 7 | pass, 14 / 6 | **fail**, 7 / 1 | pass, **14 / 6** |
| 42 | pass, 15 / 5 | pass, 15 / 5 | pass, **15 / 5** |
| 1337 | pass, 19 / 1 | **fail**, 5 / 0 | pass, **19 / 1** |

The failure, three times, is one shape:

```
unclassified divergence on {:hold, "h12", 1}: the model said
{:error, :insufficient_credits} and the ledger said {:error, :debt_outstanding}
```

**Both sides refused.** The behaviour being compared is identical and this pair
classified as `:agree` before R3, through `same?({:error, reason}, {:error,
reason})`. So the fix is a vocabulary mapping, one clause:

```elixir
defp same?({:error, :insufficient_credits}, {:error, :debt_outstanding}), do: true
```

**Identical compared/diverged counts at all five seeds** is the evidence that it
restores the pre-R3 classification and nothing more. It is not an oracle
concession: a model that **accepted** what the ledger refuses is not covered by
it and still falls through to `classify/3`.

**And a misclassification it exposed.** `classify/3`'s fall-through was
`match?({:error, :insufficient_credits}, actual) -> :eligibility`, documented as
06a's expiry compatibility change "and only that". 01e's `sufficient?/1` is
`balance - held + tolerance >= amount`, so a wallet holding 5 USD against a 4 USD
debt **accepts** a 1 USD hold in the model while 06a refuses it: that divergence
has always existed and has always been counted as an expiry divergence. R3 gives
it its own class, `:debt_refusal`, with the reasoning beside it, rather than
folding it back into `:eligibility`.

**Neither `ledger_model.ex` nor `comparable_history/0` nor `debt_reachable?/1`
was touched.** X278 stays exactly where R2 left it.

### 4.7 Accounting reconciliation

`Allocator.check!/4` re-reads the lots inside every transaction and compares
them with the balance row just written. It fired on nothing, in any run,
including every control run and every seed. **R3 changes no movement, no
`debt_delta` and no written value**: every change is to a figure computed for a
reader and to the atom in a refusal. The conservation identities, the
five-bucket CHECK, the state CHECK and `held = sum(reserved)` are untouched by
construction.

**06b's migration replay is unchanged, measured rather than reasoned**
(`tmp/v1/r3-migration.sh`, logs under `tmp/v1/r3/migration/`), at the five fixed
seeds R2 used, with and without R3's library files:

| seed | pre-R3 compared / refused | with R3 compared / refused |
|---|---|---|
| 0 | 27 / 14 | 27 / 14 |
| 1 | 31 / 10 | 31 / 10 |
| 7 | 32 / 9 | 32 / 9 |
| 42 | 21 / 20 | 21 / 20 |
| 1337 | 31 / 10 | 31 / 10 |

**Byte identical at every seed, refusal maps included** (down to
`%{reversal_took_reserved: 1, reversal_exceeds_lots: 2, expire_reserved_grant:
3, promotional_divergence_debit: 3, promotional_divergence_settle: 1}` at seed
1337), and identical to the numbers R2 recorded. That is the expected answer and
it is worth having: the fold drives the same planner, so a change that had
altered a decision rather than a reported figure would have shown up here.

## 5. Changes

**Public API:** one new error term, `:debt_outstanding`, returned by
`AuroraMeter.Credits.hold/4`, `debit/4,5` and `with_credits/4` on a cut-over
wallet that owes money. No function added, removed or changed in signature; the
`@spec` unions widen. Classified and argued in `api-change-map.md` 1.3 and 1.3.1
and in section 0.

**Reported values:** `balance/1` and `summary/1`'s `spendable` is never positive
and `promotional_spendable` is zero while `debt > 0`; `Credits.sufficient?/2`
follows. Six of the eight figures are unchanged (section 0).

**Internal:** `Allocator.spendable_figure/2` and
`Allocator.promotional_spendable_figure/2`, `@doc false`, the single
implementation of the rule. `Allocator.spendable/3`, `Ledger.figures/1` and
`Ledger.lot_spendable/3` call them.

**Configuration, migrations, telemetry, PubSub:** none. The telemetry
`spendable_after` measurement and the low-balance crossing figure both come
through `Allocator.spendable/3`, so they move with the rest rather than
disagreeing with it; no event name, measurement name or metadata key changed.

**Documentation:** `t:AuroraMeter.Credits.balance/0` (which fields are
spendability claims and which are totals), `hold/4`, `debit/4`,
`with_credits/4`, `sufficient?/2`, `Ledger.figures/1`, `Ledger.spendable/1`,
`docs/credits.md` (a new "A wallet that owes money, in full" subsection),
`docs/upgrading-to-lots.md`, `docs/examples/prepaid-credits.md`, both
`CHANGELOG.md`s, Pro's `money_section/1` moduledoc.

Two sentences in `docs/credits.md` and `docs/examples/prepaid-credits.md`
lost their em dashes on the way past: R3 had to edit both to add the new term to
the list of refusals they enumerate, and the house rule forbids the character.
The sentences are otherwise unchanged and `docs_claims_test.exs`,
`doc_examples_test.exs` and `examples_test.exs` pass over them.

**Build plans:** `api-change-map.md` (two rows and section 1.3.1),
06a's LI-06a-5 **citation** (section 7), `open-findings.md` X357, X359, X361.
**No binding map was amended.**

## 6. X357's other half, written up for the owner

This is the decision R3 did not take. It is written so it can be taken from this
page.

### The question

**Should a customer who owes money be able to spend a gift?** Concretely:
should `{:hold, ...}` and `{:debit, ...}` refuse on `debt > 0`, as
`architecture-map.md` 7.2 says today, or on `spendable/3 < amount`, which is
what the legacy ledger did?

### What relaxing it would buy

- **A wallet holding more than it owes would keep working.** After R2, a refund
  or an overrun on a wallet with a promotion freezes it completely. Under the
  relaxed rule a wallet with 8 USD of promotional credit and a 4 USD debt could
  spend 4 USD. Today it can spend nothing until someone grants it money.
- **It is what a promotion is arguably for.** The customer consumed value; the
  promotion is value we gave them; using one to cover the other is not a refund
  eating a promotion, which is the thing R1 and R2 exist to prevent.
- **It is what the legacy ledger did**, so it is what every wallet did before
  the cutover, and it removes a behaviour difference that arrives on a migration
  rather than on a decision (X283's objection).
- **It would make `available` honest too**, without changing it: the awkward
  case in section 0 (a positive `available` on a wallet that may not spend)
  largely disappears.

### What it would cost

- **It partially reverses X251's fix.** 06a's first implementation refused the
  hold and not the debit; 01e's independent model caught the allocator accepting
  a one-micro-dollar debit beside a 17 USD debt on a generated history, and the
  answer was to make the debit refuse on `debt > 0` too. Relaxing it puts the
  allocator back on the side of that argument the model objected to, and the
  model would object again: it would be a **new** divergence rather than a
  restored agreement, because 01e's `sufficient?/1` compares `balance - held`,
  not eligible availability less debt.
- **It is a second amendment to `architecture-map.md` 7.2 inside one release.**
  R2 has already amended it once. Two amendments to one section in one release
  is how a binding document stops binding.
- **Everything R3 has just written would have to change again.** The rule "a
  wallet in debt cannot spend" is now in `t:balance/0`, in `docs/credits.md`'s
  new subsection, in `docs/upgrading-to-lots.md`, in both changelogs, in Pro's
  component docs and in the `:debt_outstanding` term itself. Under the relaxed
  rule `:debt_outstanding` becomes a *partial* refusal rather than a total one
  and probably should not exist as a separate term at all.
- **It makes the debt quieter.** Today a frozen wallet is impossible to miss.
  Under the relaxed rule a wallet can carry a debt indefinitely, spending its
  promotion down to nothing, and only freeze when the promotion runs out, which
  is a worse moment for the customer to discover it.
- **It interacts with expiry.** A promotion spent against a debt is a promotion
  the expiry sweep will not destroy, which is good; but the debt then outlives
  the promotion, and `repay_debt/5` may not take promotional availability
  (R2's rule), so the wallet ends frozen anyway with the promotion gone. The two
  rules would want to be decided together.

### What would have to be re-measured

1. **06b's migration replay at the five fixed seeds.** `hold_unbacked` is one of
   its blocking labels and it is defined partly as "a hold taken while the
   wallet owed money"; relaxing the refusal changes which wallets reconcile and
   therefore which can be cut over. R2 measured 27/14, 31/10, 32/9, 21/20, 31/10
   compared/refused at seeds 0, 1, 7, 42, 1337 and found them unchanged by its
   own change; this one would have to be shown the same way and is much more
   likely to move.
2. **The cross-oracle at the same seeds**, because this is a change to a
   **result**, which the property compares command by command, rather than to a
   bucket.
3. **06a's generated-history property.** Its LI-06a-5 assertion is stated over
   **availability** (`debt > 0` implies no non-promotional availability), not
   over spendability, so it does not obviously break; that has to be
   established rather than assumed.
4. **R3's own `planner_agrees!/1`**, which would become the place the new rule
   is asserted: `spendable` would once again be `eligible_available - debt` and
   the helper's `spendable > 0` arm would carry the claim unchanged. That is a
   point in favour of the relaxation being cheap to re-verify: **the shape of
   R3's test does not depend on which rule is chosen**, only on the two agreeing.

### What the legacy ledger did, exactly

The 0.4.0 ledger has **no `debt` column at all**. A settlement above its hold
drove `balance` negative, `sufficient?/2` compared `balance - held + tolerance`
against the amount, and every hold and debit was refused until the balance came
back above the amount asked for. So:

- a wallet 3 USD under water refused a 4 USD hold and **accepted** a 1 USD one
  once a 4 USD grant arrived, with no notion of repaying anything first;
- a **promotion granted to a wallet that was under water was spendable
  immediately**, because the grant lifted `balance` and `sufficient?/2` looked
  at nothing else. That is the behaviour the relaxation would restore, and it is
  the strongest argument for it: no host has ever seen Aurora Meter freeze a
  funded wallet.

**R3's own view, offered and not acted on**: the relaxation is defensible and
the freeze is defensible, and the cost of choosing wrong in a hurry is higher
than the cost of a documented limit, which is what X361 already says. What R3
would add is that the decision is now **cheaper to reverse than it was**,
because the figures and the refusal are computed in one place each: relaxing the
rule is two functions and a documentation pass, not an audit.

## 7. X359: the answer

**The citation was wrong, R3 corrected it, and R3 did not implement the mode.**
Both halves of the sentence were wrong, and the second half is the one nobody
had noticed.

**There is no strict mode, under that name or any other.** `grep -rn strict
core:lib/` finds four things and none is a conservation check: `mix
aurora_meter.features --strict`, `OptionParser`'s own `strict:` keyword in the
bench task, `AuroraMeter.feature!/2`'s binary-feature-name error mode, and
`Config.Schema`'s `:transition | :strict` release strictness for configuration
validation. `Allocator.check!/4` re-reads the wallet's lots inside the
transaction and compares four projection identities (balance, held, promotional,
expired) against the balance row it just wrote. That is **LI-06a-2**. It never
looks at debt exclusivity, and there is no flag that makes it.

**And the model test does not assert LI-06a-5 either.** R2's row said "the model
test half is real"; it is not. `credits_model_test.exs` compares lot buckets only
when `debt_reachable?/1` is false; `debt_reachable?/1` is true exactly when a
closed hold overran; and after `comparable_history/0` drops every
`{:reverse, ...}`, an overrun is the **only** way a compared history can create
debt. So the one enforcer named excludes the one state the invariant is about.
Its `assert_database_conserves/1` runs on every history and checks LI-06a-2.

**What R3 did.** Corrected the citation in
`docs/v1/build-plans/phase-06/06a-lot-allocation-schema-and-engine.md` to name
the enforcement that exists: the generated-history property in
`core:test/aurora_meter/credits_lots_test.exs`, which asserts the amended form
over every lot of every generated wallet and which R2 widened in the same week.
The correction is a dated block naming both errors, so a reader is told the
sentence was wrong rather than finding a quietly different sentence.

**Why R3 did not implement the mode.** A wallet-level assertion inside
`check!/4` is a new raise on every ledger write. It needs a configuration key of
its own (`api-change-map.md` 1.5 territory), a decision about whether it raises
or reports, and a measurement over 06a's generated histories before it could be
turned on anywhere. That is a build unit, and putting it inside a repair of the
reported figures would make the repair unreviewable. R3 added the **reporting**
half of the same invariant behaviourally instead: `planner_agrees!/1` fails on a
wallet that advertises availability it may not spend, which is a state LI-06a-5
itself permits.

## 8. `mix check`, and what R3 is answerable for

**`mix check` is green in both packages**, which is a change from R1's and R2's
reports: 09a and 09b have since resolved the findings those units attributed to
them.

| Step | core | Pro |
|---|---|---|
| `mix format --check-formatted`, R3's files | rc=0 | rc=0 |
| `mix compile --warnings-as-errors --force` | rc=0 | rc=0 |
| `mix credo --strict`, R3's files | rc=0, 382 mods/funs, no issues | rc=0, 48 mods/funs, no issues |
| `mix credo --strict`, whole repository | rc=0, 4836 mods/funs, **no issues** | rc=0, 2661 mods/funs, **no issues** |
| `mix dialyzer` | rc=0, 0 errors | rc=0, 1 error 1 skipped (pre-existing skip file) |
| `mix docs --warnings-as-errors` | rc=0 | rc=0 |
| `mix test` | rc=0 | rc=0 |
| **`mix check`** | **rc=0** | **rc=0** |

**No project-wide `mix format` was run.** `tmp/v1/r3-format.sh` names the nine
files R3 changed and formats only those.

### 8.1 One flake, reproduced under the control, and it is not R3's

`test/aurora_meter/doc_examples_test.exs` / `test the guides a guide may name an
optional module, and the skip applies only when the dependency is really absent`
fails intermittently on
`assert function_exported?(AuroraMeter.LiveView, :switch_tenant, 2)`.

Measured rather than suspected (`tmp/v1/r3-docguard.sh`,
`r3-docguard-control.sh`): **2 of 6 runs with R3's files, and 2 of 6 runs with
R3's library files replaced by their pre-R3 bytes.** It is the classic
`function_exported?/3` without `Code.ensure_loaded?/1` on a lazily loaded
module. Both files are **09a's** and mid-edit (`lib/aurora_meter/live_view.ex`
is ` M`, `test/aurora_meter/doc_examples_test.exs` is ` M`,
`test/aurora_meter/live_view_test.exs` is `??`). R3 changed nothing on that
path, did not fix it, and does not report it as its own. It is the same shape R2
recorded for 09a's `live_view_test.exs:263`.

### 8.2 What R3 owes and did not take

**`core:docs/api.md` still prints the old error union** for `hold/4`, `debit/4`
and `with_credits/4`. The file is **09b's** and on R3's explicit do-not-touch
list. `api_inventory_test.exs` does not compare the printed type against the
`@spec` (its five invariants are about names, internality, moduledocs, specs
existing, and telemetry tags), so nothing fails and nothing warns. **This is
owed to 09b or to whoever lands after it**, and it is listed here rather than
fixed behind that unit's back. The three rows to change are at `docs/api.md:120`,
`:123` and `:125`, and the line at `:640` that lists the credit family's bare
atom reasons.

## 9. Handoff

**Where the work stopped.** The fix, its eight controls, the ten-seed sweep, the
five-seed cross-oracle measurement, the documentation and this evidence are
complete. Both suites are green, `mix check` is green in both packages, the tree
is dirty and uncommitted in all three repositories, and nothing is ticked.

**What a reviewer should read first**, in this order: section 0's field-by-field
table (which figures are claims and which are totals, and why `available` is
the hard case), section 4.1 (the money, per figure, before and after), section
4.4.1 (R3's own property measuring nothing at half the seeds, and what the
counters did about it), section 4.6 (the cross-oracle, and why the classifier
clause is not a concession), and section 6 (the owner's decision).

**What must not change:**

- **There is one implementation of the spendability rule**, in the module that
  owns the refusal. If a fourth reader needs the figure it calls
  `Allocator.spendable_figure/2`. The defect was the same arithmetic written out
  three times.
- **`planner_agrees!/1` must go on attempting the figure rather than comparing
  it.** A version that asserted `spendable == 0` would pass on any future change
  that broke the agreement in a new way.
- **Both properties must go on generating their shape rather than hoping for
  it.** `shape/2`, `debt_for/4` and `finish/2` exist because the versions
  without them measured nothing at five seeds in ten, and the counters that
  caught that must stay asserted rather than printed.
- **`spendable` must stay capped rather than clamped.** The negative figure on a
  wallet deeper in debt than it holds is deliberate, and
  `credits_figures_test.exs` / `I11 debt appears in debt and makes spendable
  zero` pins it at `-3_000_000`.
- **The legacy branch of `Ledger.figures/1` must not be routed through the
  helper.** On a legacy wallet the refusal does not look at `debt`, so the
  figure must not either.

**Next verification targets**, in priority order:

1. **X361's commercial half**, by the owner, from section 6.
2. **`docs/api.md`'s three rows**, by 09b or whoever lands after it (8.2).
3. **09a's `doc_examples_test.exs` flake** (8.1), which will fail CI about one
   run in three.
4. **X283**, the new-wallet rollout decision, which now has one more
   release-note line: a wallet the allocator owns can refuse with a term no
   legacy wallet ever returns.
5. **X278**, the cross-oracle filter, still by an author who is none of R1's,
   R2's or R3's.
