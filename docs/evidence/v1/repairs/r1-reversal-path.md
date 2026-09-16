# Repair unit R1: the lot-aware reversal path

A repair unit, not a numbered build unit. It closes the cluster phases 06 and 07 left
behind around `AuroraMeter.Credits.reverse/4` on a wallet the allocator owns.

> **Standing rule.** No credentials, no customer identities, no unsanitised logs.
> Synthetic tenant ids only. Nothing here is invented: a command that was not run is
> named as not run.

Rule 4 applies. Nothing in this file ticks a checkbox, nothing is committed, and the
tree is left dirty for the reviewer.

## 0. The decision, written before the code

**X283 and X277 asked one question each, and they have different answers.**

**X283 (is a new wallet born on lots?): no, and not in this unit.** `architecture-map.md`
7.4 does not make `lots_enabled_at` a mode switch that any writer may set; it makes the
flag the *output* of a verified replay ("sets `lots_enabled_at` only when the replay
reconciles exactly"), paired with a per-wallet report row in `aurora_meter_checkpoints`
and with an operator who asked for the cutover (`allow_cutover: true` on every writing
run). A brand-new wallet would satisfy the replay vacuously, so the arithmetic objection
X255 raised is genuinely gone once the reversal path is lot aware. What is not gone is
the rest of 7.4: stamping the flag inside `Ledger.locked_row/2` mints a cut-over wallet
with no report row, so the installation's own record of which wallets the allocator owns
stops being complete, and it does so on `mix deps.update` rather than on a decision. The
result would be an installation permanently split down the middle by upgrade date, in
which two tenants of the same host get different refund semantics, different expiry
semantics and different recurring-grant availability, with nothing in the release notes
that a support engineer could read. That is a rollout decision with a release note
attached, exactly as X283 says, and R1 is not the unit that may take it while also being
the unit that repairs the thing the decision depends on. **X255 and X283 therefore stay
open**, with the objection narrowed to the one that survives (reporting and rollout, not
refund safety), and with the note that R1 removes the *technical* blocker so whoever
takes the decision is choosing between two safe options rather than one.

**This makes X250 a defect I am fixing, not a documented limit, and it would have been a
defect whichever way X283 went.** X250's status cell said it is "an ORDERING CONSTRAINT
rather than a defect today, because no wallet has `lots_enabled_at` set". That sentence
is false as of 06e: `LotMigration.cutover_blocked/0` is behavioural on
`function_exported?(AuroraMeter.Credits, :reverse_lot, 4)` (`lot_migration.ex:952-955`),
06e shipped that function (`credits.ex:581`), so the gate answers `nil` and
`mix aurora_meter.credits.migrate_lots --no-shadow` cuts real wallets over today (the
Mix task turns `--no-shadow` into `allow_cutover: true` itself,
`aurora_meter.credits.migrate_lots.ex:107`). A wallet cut over by the documented command
and refunded through the documented Pro path loses promotional credit it should have
kept. That is reachable without any new-wallet decision at all.

**X277 (LI-06a-5) is a binding-map amendment R1 proposes and did not make.** R1 widens
the case X277 describes rather than closing it, because the wallet-wide reversal now
also declines to repay its debt out of promotional availability. The exact replacement
text is in section 6. **Neither `architecture-map.md` nor 06a was edited**, because
amending a binding map is not a repair unit's to do quietly and because the honest
amendment weakens a stated invariant.

### The evidence that the reading of 7.2 is the right one, and it is not R1's own

01e wrote `AuroraMeter.Test.LedgerModel` from `architecture-map.md` section 7 **before
06a existed**, as an independent oracle. Its `replay/3` clause for `{:reverse, reference,
amount}`, the command that drives the wallet-wide `Credits.reverse/4`, is:

```elixir
# 7.2: a reversal targets the paid side only, buckets in the order available,
# consumed, reserved. Promotional lots are never touched by a paid reversal.
defp replay(state, {:reverse, _reference, amount}, :ok) do
  {state, left} = reverse_from(state, amount, :available)
  {state, left} = reverse_from(state, left, :consumed)
  {state, left} = reverse_from(state, left, :reserved)
  add_debt(state, left)
end
```

with `paid_lot?(lot)` defined as `lot.category != :promotional` and the same spend order,
and no expiry filter. That is what R1 implements, line for line, including the remainder
becoming `debt`. A second reader of the same binding document, with no sight of the
implementation, read it the same way. R1 did not touch the oracle.

## 1. Tasks, repository and revision

| | |
|---|---|
| Unit | Repair unit R1 (not a `v1-release.md` task id) |
| Findings | X250 closed, X274 corrected and closed, X255 / X283 / X277 / X259 / X278 corrected and left open, **X355 opened** |
| Repositories | `aurora_meter` (core), `aurora_meter_pro` (Pro), storefront (`open-findings.md` only) |
| core HEAD | `7d0264f` on `aurorameter-v1`, **tree dirty** |
| Pro HEAD | `ff9419e` on `aurorameter-v1`, **tree dirty** |
| storefront HEAD | `324fa22` on `aurorameter-v1`, **tree dirty** |

The tree is dirty by design (rule 4) and it is **also dirty with three other units' work**:
09a and 09b hold uncommitted changes in core (`lib/aurora_meter/plug/`,
`lib/aurora_meter/install/`, `live_view.ex`, `components.ex`, `realtime_test.exs`,
`docs/{api,configuration,correctness,phoenix}.md`, the installers and the migration
generators) and in Pro (`install/templates.ex`, `pro_install_test.exs`, the generator).
R1 touched none of them. Section 3.4 accounts for every `mix check` finding that names
one.

Files R1 changed, with sha256 at the time of writing:

```
core  bfeb41b69a33e31163b2f20e354f115bc469548a5523a48cc39557299f63281f  lib/aurora_meter/credits/ledger.ex
core  4e9ad414cef5e47fd1d4d73657d32bc46b1ba8990d89f2a6e52b71bc451183a0  lib/aurora_meter/credits/allocator.ex
core  aa9a55ed9d3e80286d897ca27eb2958554f2286b38f18be621142c5dbd9e2762  lib/aurora_meter/credits/lot_migration.ex
core  056b1901921c0f3af778387ad262fbe2782bfa3e6018df7581149bc366893d9f  lib/aurora_meter/credits.ex
core  4cdf42af7e71567ea2b47ceb06e671760b0d053e97b4228c13ad2a981d95d29e  test/aurora_meter/credits/allocator_test.exs
core  00d18ff10b99c7173be1f13432895134dc6cd122e29a3641dd5888f95c9c6508  test/aurora_meter/credits_lot_reversal_test.exs
core  c2b5cb39f7e903262fc2f112a309c29aff27875e5bbe3a60a89ccafce257d8cb  test/aurora_meter/credits_model_test.exs
core  89733a70a9f45cf3c4d72e01f89f670c2e650b32cd47676484a94974a3e00c87  CHANGELOG.md
core  5299a3e40538634c681cf8a915136734b674ace000c6f2904a977f42e324bcc6  docs/credits.md
core  eda00a1dc2bb2fc4d51dc5a82f234871034e1d8ce0fd754ed38afefda96676b2  docs/upgrading-to-lots.md
pro   688b8e8803b15505bee9af3bf353587f53f1833724d1aa2985d62c4633797499  test/aurora_meter/pro/credits_lots_test.exs
store 89bff0be3fcb60a1723f042dee093ada25594f5670b84f8baf544e0028d5ceb4  docs/v1/build-plans/open-findings.md
```

`credits_model_test.exs` carries **comment corrections only**: two comments stated a
reason for the cross-oracle `:reverse` filter that R1 measured to be false. No assertion
in that file changed. The pre-R1 copy is kept at `tmp/v1/r1-model-test-orig.exs`
(`8281324563bedbaee9ffbe1eb691b592b2c11206c7f82719807b81336454556a`) and the file was
byte-restored from it after the experiment in section 3.3.

## 2. Environment

| | |
|---|---|
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), JIT |
| OS | Ubuntu 24.04 under WSL2 on Windows 11 |
| Postgres | `postgres:16` in Docker container `aurora-meter-pro-testdb`, port 5490 (the package lane; the storefront's 5470 lane is untouched) |
| core package | 0.5.0, schema `@latest 10` |
| Pro package | 0.3.0, schema `@latest 11` |
| core `mix.lock` | `d55a81fb21194ad5fb797dd458fe47fcca737a2e4542af4297a55e215d0c7cc0` |
| Pro `mix.lock` | `910d54651cd08dc350eadb29b0915ee662adba4125700d9b6161bdbfe9a08232` |

Every Mix command went through `bash tmp/v1/mixlane.sh <core|pro> mix ...`, which is the
shared `_build` lock; three other agents were running against the same lane throughout
and several runs waited for it.

## 3. Commands and logs

All logs are under `tmp/v1/` in the storefront checkout. Timestamps are UTC as printed by
`mixlane.sh`.

### 3.1 The defect, and the fix, measured on one wallet

| Run | Command | Log | sha256 | Exit |
|---|---|---|---|---|
| Defect | `bash tmp/v1/r1-control.sh ... r1_probe_test.exs` | `r1-probe-defect.log` | `41820ea6992ea0c501f380c7e3b4a0ef9f88c703d36b9d868d4ad146bcdc942c` | 0 |
| Fixed | `bash tmp/v1/r1-run.sh ... r1_probe_test.exs ...` | `r1-probe-fixed.log` | `1a1bb9d9f2ea15ce6d2e502f9bf01143cd7e2e34b09711a5321dd17748935810` | 2 (the one test that encoded the defect) |

The probe was a temporary test file that asserted nothing and printed the lot table. It
is deleted from the test tree; its source and the post-reversal probe are kept at
`tmp/v1/r1-debt-repayment-probe.exs`.

### 3.2 Tests and controls

| Run | Command | Log | sha256 | Result |
|---|---|---|---|---|
| core, R1's files | `mixlane.sh core mix test test/aurora_meter/credits/allocator_test.exs test/aurora_meter/credits_lot_reversal_test.exs` | `r1-core-targeted.log` | `29313d97a80f996174cfe694364451701aa6772e422e006c5442370c3713a077` | **32 passed** (1 property, 31 tests), seed 494926 |
| core, control | `bash tmp/v1/r1-control.sh` on the same two files | `r1-control-core.log` | `21f52874b8382ee855b13d9d13b7c58afcc5dc6c06cb24fc43d006508315a69a` | **22/32, 1 property and 9 tests failed** |
| Pro, R1's file | `mixlane.sh pro mix test test/aurora_meter/pro/credits_lots_test.exs` | `r1-pro-targeted.log` | `8538d58a3ab856b3ce7eea81f1c5e900f6d889cd4403c07ed7cd65312201c421` | **10 passed**, seed 325430 |
| Pro, control | `bash tmp/v1/r1-control-pro.sh` on the same file | `r1-control-pro.log` | `66e79f169694c559ea9c81b0321070fc9c7a671a653f19e1995ff44cb547fcca` | **8/10, 2 tests failed** |
| core, full | `mixlane.sh core mix test` | `r1-core-full.log` | `a11a26379067d63d00c899255685b22be19eb5489621ab5944c1d34bd56214cf` | **2114 passed** (81 doctests, 20 properties, 2013 tests), 8 excluded, 255.3 s |
| Pro, full | `mixlane.sh pro mix test` | `r1-pro-full.log` | `570bc476d62d476435816495ed1723ad3df98a7c9dd80b8ae6a3debe9c345469` | **1156 passed** (74 doctests, 1082 tests), 26.2 s |
| core, the neighbours | `mixlane.sh core mix test` over `credits_model_test`, `credits_lots_test`, `credits_lot_migration_test`, `credits/lot_migration_replay_test`, `credits_lot_migration_property_test`, `docs_claims_test`, `doc_examples_test`, `api_inventory_test` (`tmp/v1/r1-final.sh`, after the last edit to any file) | printed inline | | **149 passed** (9 properties, 140 tests); cross-oracle `compared: 10, diverged: 2` |

The last run is the one that matters for the documentation changes: `docs_claims_test`,
`doc_examples_test` and `api_inventory_test` are the guards that read the prose and the
public surface, and the migration and property suites are the ones a change to
`Allocator.plan/2` is most likely to break. `mix format --check-formatted` over all seven
R1 files passed in the same script, after every edit.

`tmp/v1/r1-control.sh` and `r1-control-pro.sh` put the pre-R1 `ledger.ex` and
`allocator.ex` back from `tmp/v1/r1-defect/`, run, and restore from `tmp/v1/r1-fixed/` in
an `EXIT` trap, printing the sha256 both sides. `git checkout --` is never used anywhere
in this unit (X326: nine files were lost to that command). Every control run's restore
line reads `bfeb41b6...` and `4e9ad414...`, matching the expected line printed beside it.

### 3.3 The cross-oracle experiment (X278)

`mixlane.sh core mix test test/aurora_meter/credits_model_test.exs` with the `:reverse`
filter and the `:reverse_not_wired` classification removed. Log
`r1-model-experiment.log`, sha256
`d96c43aa2ed1661117724b5d2b4c583b0d3ee6b3b7542b9f12032c7263933e05`. Result in section 4.4.
The file was restored byte for byte afterwards from `tmp/v1/r1-model-test-orig.exs`
before the comment corrections were applied.

### 3.4 `mix check`, and why it is red in both repositories

| Run | Log | sha256 | Exit |
|---|---|---|---|
| core `mix check` | `r1-core-check.log` | `a0b4bcfa412c0baf8653d6bc95dfb146bb400d8ac2eb6bcc8a56e41916db0f67` | **1** |
| Pro `mix check` | `r1-pro-check.log` | `fba6838492aa0249851021c8b13d65b79af37225dec49722a671c2b5d017f708` | **2** |
| core, step by step | `r1-core-check-steps.log` | `97b6069cd2ebf49bc0c1b10dddfb9242750b900115228424c2a20c83a5967b96` | see below |
| Pro, step by step | `r1-pro-check-steps.log` | `64a46e874707bd93779b358e661a6b01fd272baa3b3e99ff0ceb1a457248a9db` | see below |

**`mix check` is red in both, and every finding names a file another unit is mid-edit
on.** Not one names a file R1 changed. The full attribution, checked against
`git status` in each repository:

| Repository | Step | File named | `git status` |
|---|---|---|---|
| core | `format --check-formatted` | `test/aurora_meter/realtime_test.exs` | ` M` (09a) |
| core | `format --check-formatted` | `test/aurora_meter/live_view_test.exs` | `??` (09a) |
| core | `format --check-formatted` | `test/aurora_meter/plug/ensure_entitled_test.exs` | `??` (09a) |
| core | `credo --strict` | `test/aurora_meter/plug/ensure_entitled_test.exs` (x2) | `??` (09a) |
| core | `credo --strict` | `lib/mix/tasks/aurora_meter.install.ex` | ` M` (09b) |
| core | `credo --strict` | `lib/aurora_meter/install/plan.ex` | `??` (09b) |
| core | `docs --warnings-as-errors` | `docs/configuration.md` | ` M` (09a) |
| core | `docs --warnings-as-errors` | `docs/phoenix.md` (x2) | `??` (09a) |
| core | `docs --warnings-as-errors` | `docs/correctness.md` | ` M` (09a, +168 lines) |
| Pro | `credo --strict` | `test/mix/tasks/pro_install_test.exs` (x2) | ` M` (09b) |
| Pro | `credo --strict` | `lib/aurora_meter/pro/install/templates.ex` | ` M` (09b) |
| Pro | `docs --warnings-as-errors` | `docs/correctness.md`, the generator, `install/templates.ex` | ` M` (09b); all three reference `AuroraMeter.Install.Plan`, a hidden module 09b has just added to core |

`lib/aurora_meter/plug/`, the installers, the migration generators, `live_view.ex` and
`components.ex` are on R1's explicit do-not-touch list, so none of this was chased and
none of it was fixed.

**Every `mix check` step run on its own, with `format` scoped to R1's files:**

| Step | core | Pro |
|---|---|---|
| `format --check-formatted` (R1's files) | rc=0 | rc=0 |
| `compile --warnings-as-errors --force` | rc=0 | rc=0 |
| `credo --strict` | rc=10, **all four findings are 09a/09b's** | rc=2, **all three are 09b's** |
| `credo --strict`, R1's seven files only | **rc=0, no issues** (`r1-credo-mine.sh`) | covered by the repo run: no finding names R1's file |
| `dialyzer` | rc=0 | rc=0 |
| `test` | rc=0 | rc=0 |
| `docs --warnings-as-errors` | rc=1, **all four warnings are 09a's** | rc=1, **all three are 09b's** |

So: `mix check` is **not** green in either repository, it is red for reasons R1 did not
cause and may not fix, and every step of it passes on R1's own work. That is the honest
statement and it is deliberately not dressed up as green.

## 4. Results

### 4.1 The defect, reproduced with per-lot figures

The fixture is forced, not waited for: a wallet cut over to lots, funded by payment
`pi_r1` with 10 USD, which then spends 5 USD of it, and which afterwards receives a 4 USD
promotional grant. The refund is 6 USD through the **wallet-wide** `Credits.reverse/4`,
which is the call a caller without payment provenance makes.

**Before the refund**, both runs identical:

```
balance=9000000 held=0 promotional=4000000 debt=0
  lot pi_r1 (paid)         amount=10000000 available=5000000 consumed=5000000 reversed=0
  lot promo (promotional)  amount= 4000000 available=4000000 consumed=0       reversed=0
  allocations: 1  (consume 5000000 on pi_r1)
```

**After `Credits.reverse(tenant, 6_000_000, "refund:pi_r1:600")`, pre-R1 code**
(`r1-probe-defect.log`):

```
balance=3000000 held=0 promotional=0 debt=0
  lot pi_r1 (paid)         available=3000000 consumed=7000000 reversed=0        state=open
  lot promo (promotional)  available=0       consumed=4000000 reversed=0        state=exhausted
  allocations: consume 5000000 pi_r1 | consume 4000000 promo | consume 2000000 pi_r1
```

The customer's entire promotion is gone, the paid lot that actually funded the purchase
still holds 3 USD, `reversed` is zero on every lot, and the three allocation rows say
`consume`, so the reversal is indistinguishable from a spend in the allocation trail.

**After the same call, with R1** (`r1-probe-fixed.log`):

```
balance=3000000 held=0 promotional=4000000 debt=1000000
  lot pi_r1 (paid)         available=0       consumed=4000000 reversed=6000000  state=exhausted
  lot promo (promotional)  available=4000000 consumed=0       reversed=0        state=open
  allocations: consume 5000000 pi_r1 | reverse 5000000 pi_r1 | reverse 1000000 pi_r1
```

Five out of `available` and one out of `consumed`, all of it into `reversed`, the one
micro-dollar already spent recorded as `debt`, and the promotional lot byte identical.

**The balance is 3,000,000 in both.** So is conservation, so is `held = sum(reserved)`,
so is every CHECK constraint, and so is the `check!/4` projection re-read. A test that
stopped at the balance would have passed on the defect, which is why every assertion R1
added is per lot and why `credits_lot_reversal_test.exs` asserts the promotional lot by
struct equality against the row read before the refund, so even `updated_at` must not
have moved.

### 4.2 The Pro fallback, end to end

Both doors into `Credits.reverse/4` from Pro were driven from the webhook, on a wallet
that **is** cut over to lots but whose paid lot carries no `source.payment_intent_id`,
which is exactly what 06b's fold writes when it cannot derive the provenance (X263 sizes
that at a large minority of wallets):

1. `Webhook.handle_event/1` -> `reverse/3` -> `reverse_known/4` -> `reverse_grant/5` ->
   `do_reverse_grant/5` -> **`take_back/5`** -> `Credits.reverse_lot/4` =
   `{:error, :no_matching_lots}` -> **`wallet_wide/6`** -> `Credits.reverse/4`.
2. `sync_refund/2` -> `reconcile_refund/3` -> **`reconcile_legacy/3`** (taken whenever
   `Lots.for_source/2` is empty) -> **`legacy_debit/3`** -> `Credits.reverse/4`. This is
   the one a real `charge.refunded` takes, because a real charge carries an id.

Both assert the same lot-level outcome and both check the fallback is genuinely the path
taken (`Lots.for_source/2 == []`, `metadata["fallback"] == true`,
`metadata["fallback_reason"] == "no_matching_lots"`, and the
`[:aurora_meter, :pro, :credits, :wallet_wide_fallback]` telemetry event received once).

| | pre-R1 (`r1-control-pro.log`) | with R1 (`r1-pro-targeted.log`) |
|---|---|---|
| `pi_...` paid lot | `available 3,000,000, consumed 7,000,000, reversed 0` | `available 0, consumed 4,000,000, reversed 6,000,000` |
| promotional lot | consumed to pay the refund | identical to the row read before the refund |
| `balance.debt` | 0 | 1,000,000 |
| `balance.promotional` | 0 | 4,000,000 |

### 4.3 Controls: twelve, and all twelve discriminate

Each was run against the pre-R1 `ledger.ex` and `allocator.ex` restored from the
snapshot, and each failed. The sha256 of both files after every restore matches the
expected line printed beside it.

| # | Test | Discriminates |
|---|---|---|
| 1 | `AllocatorTest` property `I10 every planned movement conserves` | yes, see 4.3.1 |
| 2 | `AllocatorTest` `X250 a wallet-wide reverse takes the non-promotional lots in spend order and never the promotion` | yes |
| 3 | `AllocatorTest` `X250 a wallet-wide reverse a promotional-only wallet cannot fund becomes debt, not a spend` | yes |
| 4 | `AllocatorTest` `X250 a wallet-wide reverse takes reserved value last and beyond the lots becomes debt` | yes |
| 5 | `AllocatorTest` `X250 a wallet-wide reverse reaches a paid lot the expiry sweep has not caught up with` | yes |
| 6 | `CreditsLotReversalTest` `X250 a wallet-wide refund on a cut-over wallet takes the paid lot and leaves the promotion` | yes |
| 7 | `CreditsLotReversalTest` `X250 a wallet-wide refund a promotional-only wallet cannot fund becomes debt` | yes |
| 8 | `CreditsLotReversalTest` `X250 a wallet-wide refund takes reserved value last and leaves held consistent` | yes |
| 9 | `CreditsLotReversalTest` `X250 a wallet-wide refund is idempotent on its reference and writes once` | yes |
| 10 | `CreditsLotReversalTest` `I10 reverse_lot takes only the lots matching the source` (its wallet-wide tail, rewritten by R1) | yes |
| 11 | Pro `X250 take_back falls back to the wallet-wide reversal on a cut-over wallet and spares the promotion` | yes |
| 12 | Pro `X250 the sync refund path also spares the promotion when it falls back to the legacy cap` | yes |

#### 4.3.1 One control passed on the first attempt, and it was a vacuous pass

The property arm for the new `:reverse_wallet` request **passed under the control**,
which is a question and not a result (X125, X287). The reason is X325 and X350's shape
exactly: the pre-R1 allocator's `{:reverse, payment_intent_id, ...}` clause pattern
matches any term in that slot, so `{:reverse, :wallet, amount, now, debt}` matched it,
`:wallet` equalled no lot's `"payment_intent_id"`, the clause returned
`{:error, :no_matching_lot}`, and the property's error arm let every generated case
through without reaching a single assertion. **A detector that can match nothing passes
everything it cannot see.**

Fixed by making the refusal itself an assertion: a wallet-wide reversal is never refused
for want of balance, so the error arm now carries
`refute request == :reverse_wallet`. Re-run: the property fails under the control
(`0/1 properties`) and passes with R1.

The property also gained the arm that matters, over the movements rather than the
projection: **no movement in a `:reverse` or `:reverse_wallet` plan may name a
promotional lot.** The balance arm cannot carry that claim, and the file says so.

### 4.4 The cross-oracle experiment, and what it found

01e's `LedgerModel` already models the wallet-wide reversal the way R1 implements it
(section 0). So R1 removed `comparable_history/0`'s `:reverse` filter and `classify/3`'s
`:reverse_not_wired` clause and ran the property, which is the strongest available proof:
an oracle written by another unit, from the binding map, before the implementation.

**It failed**, and on something real. A promotional lot the model said held
`available: 14,527,949` read `0` in the database. The mechanism is not the reversal:

1. a reversal that reaches `consumed` creates `debt`;
2. its own repayment is deliberately non-promotional (X262), so on a wallet whose only
   remaining availability is promotional the debt survives the reversal;
3. the **next release or settle** repays it through `Allocator.repay_debt/5`, which takes
   `eligible/2` in spend order, which takes the promotional lot first.

Reproduced deterministically (`tmp/v1/r1-debt-repayment-probe.exs`,
`r1-probe-debt.log`): grant 10 USD paid with a source, debit 10, grant 4 USD promotional,
hold 4, reverse 10, release.

```
after the reversal:  promotional=4000000 debt=10000000   promo lot reserved=4000000  (untouched)
after the release:   promotional=0       debt= 6000000   promo lot consumed=4000000
```

**Identical through `Credits.reverse_lot/4`** (`r1-probe-debt-lot.log`), so this is 06a
and 06e's, not R1's, and it applies to the function G06 bullet 5 is asserted against. It
is recorded as **X355** and R1 did not fix it: see section 6.

The filter therefore stays, with both comments in `credits_model_test.exs` corrected to
say the measured reason rather than the stale one. No assertion in that file changed.

### 4.5 Accounting reconciliation

Every run above is inside `AuroraMeter.Credits.Allocator.check!/4`, which re-reads the
lots from the database inside the transaction and compares them with the balance row just
written, raising `ConservationError` on any difference. It fired on nothing. The five-
bucket CHECK constraint, the state CHECK and the `held = sum(reserved)` projection all
held in every run, including every control run, which is the point section 4.1 makes.

The one wallet-level identity R1 adds and asserts: a wallet-wide reversal drops the
balance by **exactly** the amount asked for, always, because what no lot can give back
becomes `debt`. That is asserted in the property over generated books and in the facade
tests over real rows.

## 5. Changes

**Public API: none.** No function was added, removed or changed in signature. The
behaviour of `AuroraMeter.Credits.reverse/4` changes on a wallet with `lots_enabled_at`
set, which is a behaviour change for an unreleased path: no published version of the
package can cut a wallet over, because `cutover_blocked/0` refuses on any core without
`reverse_lot/4` and no core with `reverse_lot/4` has been published. On a legacy wallet
nothing changes at all.

**Internal:**

- `AuroraMeter.Credits.Allocator.plan/2`'s `{:reverse, ...}` request takes a `scope`: a
  binary `payment_intent_id` as before, or the new atom `:wallet`. One code path serves
  both; only the target set differs. `funded_by/2` becomes `reversal_targets/2` over a
  new `purchased/1` (non-promotional, spend order, no expiry filter). `unreachable/2`
  decides whether an unmet remainder becomes debt: never for a source-scoped reversal
  (the caller owns that decision through `:exceeds_source` and `allow_partial`), always
  for a wallet-wide one.
- `AuroraMeter.Credits.Ledger.spend_with_lots/8` is **removed** and replaced by
  `debit_with_lots/7`, which cannot be handed a kind, and `reverse_with_lots/5`. The
  defect was a function that built a `{:debit, ...}` request whatever kind it was given;
  the shape that allowed it is gone, not just the instance.

**Configuration:** none. **Migrations:** none. **Telemetry:** none. Pro's
`[:aurora_meter, :pro, :credits, :wallet_wide_fallback]` event is unchanged and now has a
test that asserts the lot-level outcome behind it.

**Documentation:**

- `AuroraMeter.Credits.reverse/4`'s docstring gains the lot semantics. Its existing
  sentence "it never consumes promotional credit" was true of the legacy writer
  (`Ledger.promotional_delta/2` has a `%{category: :reversal}` clause with a comment
  saying why) and **false of the allocator**; it is now true of both, and the docstring
  says that it was not.
- `reverse_lot/4`'s docstring no longer says `reverse/4` "debits the wallet in spend
  order".
- `LotMigration`'s moduledoc no longer tells a host that calling `reverse/4` on a
  cut-over wallet "is the hazard above with the gate removed rather than the hazard
  fixed". `cutover_blocked/0`'s doc now says plainly what the probe cannot tell you: core
  and the migration ship in one package, so the check reports that release's own state
  and was an ordering device between build units, never a deployment version check.
- `docs/credits.md` and `docs/upgrading-to-lots.md`. The latter still carried "This step
  is refused in the current release", which stopped being true at 06e.
- `CHANGELOG.md` Unreleased.

**No binding map was amended.** See section 6.

## 6. Open defects, and the amendment R1 proposes

### 6.1 The amendment (X277), proposed and not made

R1 gives the wallet-wide reversal the same promotional exclusion the source-scoped one
has, so the case X277 describes is now reachable on the common path as well. The exact
text proposed for `architecture-map.md` 7.2 and for 06a's LI-06a-5:

> **LI-06a-5 (debt exclusivity)**: `debt > 0` implies `SUM(lot.available) = 0` over that
> wallet's **non-promotional** lots. The promotional exclusion in 7.2 is the stronger
> rule and it wins: where the only availability left is promotional, the debt stands
> beside it until the next incoming value repays it.

**Neither document was edited.** Amending a binding map is not a repair unit's to do
quietly, and this amendment weakens a stated invariant, which is a decision with a reader
on the other end of it. Whoever takes it should read X355 at the same time, because the
two are one question.

### 6.2 X355, new, and R1 did not fix it

The promotional exclusion is defeated one event later: the debt a refund creates is
repaid out of the promotion by the next release or settle (section 4.4). Reproduced on
both reversal functions, so it is 06a and 06e's rather than R1's.

The fix is one line, `purchased_eligible/2` instead of `eligible/2` in
`Allocator.repay_debt/5`, and its consequences are not one line: `repay_debt/5` is on
every settle, release and grant path, so excluding promotional availability there weakens
LI-06a-5 across the whole engine rather than on the reversal alone, and it has to be
measured over 06a's generated histories at fixed seeds with the change on and off, the
way X262 was. Doing that inside a reversal repair would make the repair unreviewable.
**Owner: whoever takes X277.**

**What must not happen** is that G06 bullet 5 is ticked on the reversal test alone. The
test that passes is a refund with no hold behind it. The wallet X355 describes, a
promotion and an open hold at the moment of a refund, is an ordinary one.

### 6.3 X259, considered and out of scope

The allocator still has no "expire exactly this much from this lot" request and the
migration fold still builds that one movement itself. R1 left it, and corrected one
clause of the finding: "the recurring-grant unit needs partial expiry of its own for
capped rollover" did not come true. 06d expires **whole** lots through
`Ledger.expire_all/5` and applies the cap to the carry **grant's** amount, so
`Credits.Recurrences` contains no partial expiry at all. The only consumer is the
migration fold.

Routing the fold through an `{:expire_amount, ...}` clause would move the movement
construction and not the decision: the three-way verdict (`<= lot.available`,
`<= lot.available + wallet_reserved` which flags `expire_reserved_grant`, else
`expire_over_lot`) turns on the reservation **anywhere in the wallet**, which is a
migration concept the planner must not learn. All of the risk is in that verdict, 06b
measured it across 280 generated histories, and a reversal repair cannot re-measure it.
**Owner: 11a**, which owns the migration fixtures.

### 6.4 Left open, untouched, and why

- **X255, X283**: the new-wallet rollout decision. Section 0. R1 removes the safety
  objection and declines the decision.
- **X278**: the cross-oracle filter. Section 4.4. Its stated reason is corrected; what is
  owed is narrower than the row thought.
- **X257** (the legacy promotional clamp), **X261** (the wallet-wide legacy expiry
  guard), **X263** (`promotional_delta/2` and holds): three limits of the **frozen 0.4.0
  legacy ledger** that decide which wallets the migration can move. R1 changes the
  allocator and the lot path and cannot affect any of them. X263 is the reason the Pro
  fallback is the common path rather than an edge, which is why R1 tested that path end
  to end, but the finding itself is unchanged and still needs the owner to size the
  population against production data.
- **X270** (`runway_days` divides `available`, not `spendable`): untouched, still owed to
  08b or 10a. R1 changes nothing it reads.

### 6.5 Skipped tests

None. R1 skipped no test, added no `@tag :skip`, and excluded nothing. The 8 excluded
tests in every core run are the pre-existing `:headless` tag.

## 7. Handoff

**Where the work stopped.** The fix, its twelve controls and the evidence are complete.
The tree is dirty and uncommitted in all three repositories, as rule 4 requires. Nothing
is ticked.

**What a reviewer should read first**, in this order: section 0 (the decision and its
reasoning against `architecture-map.md` 7.2), section 4.1 (the defect and the fix at the
money), section 4.3.1 (the control that passed vacuously and what was done about it), and
section 4.4 (X355).

**What must not change:**

- `Allocator.plan/2`'s `{:reverse, scope, ...}` must stay one clause for both scopes. The
  defect was two implementations of one idea, and the repair is that there is one.
- `reversal_targets/2` must not gain an expiry filter. An unswept expired lot still
  contributes its `available` to `balance`; skipping it would make a reversal create debt
  for value still on the books, which the sweep would then destroy as well, leaving the
  tenant owing credit it never had. `AllocatorTest` `X250 ... the expiry sweep has not
  caught up with` is the test that pins this.
- The property's `refute request == :reverse_wallet` in the error arm. Without it the
  property is green over a request that never runs.
- `credits_lot_reversal_test.exs`'s `assert reload(promo_before) == promo_before`. Struct
  equality is deliberate: `Allocator.update_lots!/2` writes only touched lots, so even
  `updated_at` moving is a failure.

**Next verification targets**, in priority order:

1. **X355**, with X277, by an author who is not R1's. It is a money question and it is
   the one thing in this cluster still open that a customer would notice.
2. **X283**, the new-wallet rollout decision, by the orchestrator. Both answers are safe
   now; it is a release-note choice.
3. **X278**, the cross-oracle filter, by a unit that is not the reversal's author, after
   X355 is decided: `debt_reachable?/1` needs to know that a reversal created debt.
4. **`mix check`** in both packages, once 09a and 09b land. R1's own files pass every
   step; the repository runs cannot be green until those units format their files and
   resolve their credo and docs findings (section 3.4).
