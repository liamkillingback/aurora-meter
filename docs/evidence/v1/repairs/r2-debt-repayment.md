# Repair unit R2: debt repayment and the promotional exclusion

A repair unit, not a numbered build unit. It closes finding **X355**, which repair
unit R1 opened and correctly declined to fix, and it applies the binding-map
amendment **X277** has been waiting for since 06e, because the two are one decision.

> **Standing rule.** No credentials, no customer identities, no unsanitised logs.
> Synthetic tenant ids only. Nothing here is invented: a command that was not run is
> named as not run.

Rule 4 applies. Nothing in this file ticks a checkbox, nothing is committed, and the
tree is left dirty for the reviewer. **G06 bullet 5's tick is corrected with a finding
(X358) and is not re-ticked here.**

## 0. The decision, written before the code

### The question

`aurora_meter_credit_balances.debt` is a single `bigint` with **no provenance**. Nothing
in the book can tell debt created by a reversal (money we handed back to a payment
provider that the wallet had already spent) from debt created by an overspend (value the
customer consumed above what the wallet could fund). Three routes were on the table:

- **(a)** promotional credit is never consumed to repay debt, whatever created it;
- **(b)** track debt provenance, so reversal debt is repaid only from purchased lots and
  overspend debt may take any eligible lot;
- **(c)** document the limit and ship it.

### The decision: (a), scoped to credit the wallet already holds

**R2 takes route (a), and states it as two sentences rather than one, because the second
is what keeps the first survivable:**

> **Credit the wallet already holds is never consumed to repay a debt if it is
> promotional.** A new **grant**, of any category, is applied to any outstanding debt
> before it becomes spendable, out of the lot it is creating.

In code: `repay_from_purchased/5` is **removed**, `repay_debt/5` takes
`purchased_eligible/2`, and the `{:reverse, ...}` clause calls `repay_debt/5` like every
other caller. There is now one repayment function in the planner and it cannot reach a
promotional lot. The `{:grant, attrs, debt}` clause is unchanged.

That structural shape is the point rather than a tidiness preference, and it is R1's own
argument applied one level down. R1 wrote: *"the defect was two implementations of one
idea, and the repair is that there is one."* X355 is the same defect one function along.
The promotional exclusion was implemented twice, in `repay_from_purchased/5` for the
reversal and not at all in `repay_debt/5` for settle and release, so it held for exactly
one transaction and the next ordinary release undid it. A rule with two implementations
has one that is wrong.

### Why not (b)

(b) is truer and R2 did not take it, for three reasons in descending order of weight.

1. **It is a money column on a schema version this branch has already shipped
   migrations for.** Splitting `debt` into `reversal_debt` and an overspend remainder
   means a new schema version, `lib/aurora_meter/migration.ex`, the core and Pro
   migration generators, and every reader of `debt`. Three of those files are on this
   unit's explicit do-not-touch list and are mid-edit by 09b, so R2 could not have
   written (b) even if it were right.
2. **The migration has no honest answer for a legacy wallet.** `LotMigration` replays a
   wallet's history into lots. The 0.4.0 legacy ledger has one signed balance and no
   `debt` column at all, so a replay reconstructing provenance for historical debt would
   be inventing it, which is precisely what 06b's own criterion forbids ("do not invent
   grant provenance").
3. **Two kinds of debt is a worse thing to explain than one rule.** Every reader of the
   balance row, every dashboard, every support engineer and every host would have to ask
   which debt they are looking at, permanently, to buy back a case that only arises when
   a wallet holds a promotion and overspends at the same time.

**What (b) would have bought, stated plainly so the owner can overrule this with the
argument in front of them.** Under (b), a promotion could still cover an overspend, which
is arguably what a promotion is for: the customer consumed value, the promotion is value
we gave them, and using one to cover the other is not a refund taking a promotion. Under
(a) it cannot, so an overspend freezes a wallet that is sitting on promotional credit
until an incoming grant clears the debt. That is a real cost and it is section 0's
weakest point. It is written into the code, into `docs/credits.md` and into
`CHANGELOG.md` rather than left for a host to discover.

### Why not (c)

G06 bullet 5 claims a refund of a spent paid lot does not erase later promotional
credit. Documenting that it does, one event later, does not make the bullet true; it
withdraws it. The gate has to be revisited either way (X358), so the only real choice is
whether the code matches the claim.

### Why the grant clause is exempt, which is the half a reviewer should attack

Three independent reasons, and the third is the one that decided it:

1. **`architecture-map.md` 7.2 gives it its own sentence**: "every incoming grant repays
   outstanding debt first, by writing a `consume` allocation against the new lot." It
   does not qualify by category. Excluding promotional grants would be a second,
   unasked amendment to the same section R2 is already amending.
2. **01e's independent `LedgerModel`, written from that document before 06a existed,
   implements it category blind.** `replay/3`'s `{:grant, ...}` clause is
   `repaid = min(amount, state.debt)` with no `paid_lot?` filter, beside a `{:reverse,
   ...}` clause that does carry one. A second reader of the binding map drew the line in
   the same place.
3. **It is the only door out of the state the first rule creates.** A wallet that owes
   money may neither hold nor debit (7.2, and `{:hold, ...}` and `{:debit, ...}` enforce
   it). If a promotional grant could not repay either, a host granting a welcome
   promotion to a wallet in debt would have granted something unspendable, which the
   expiry sweep would then destroy: the customer would keep the promotion in the ledger
   and get nothing from it. Under the rule as written, any grant of any kind unfreezes
   the wallet and the promotion it was standing beside survives whole. That is asserted,
   not asserted about: `credits_lots_test.exs` / `test X355 debt outlives promotional
   availability` drives the refusal and then the grant that lifts it.

The boundary this creates is worth stating on its own, because it is the mistake a
reader of the rule alone would make: **the exclusion is about repaying, not about
spending.** Spend order still takes promotional credit first for executed work,
including the extra consumption a settlement above its hold makes. `allocator_test.exs` /
`test X355 a settle above its reservation still SPENDS promotional credit` pins it and
fails when the rule is over-applied (section 4.4, mutant C).

### What the decision costs, in full

1. **LI-06a-5 weakens across the whole engine, not just on the reversal.** It now reads
   `debt > 0` implies `SUM(lot.available) = 0` over that wallet's **non-promotional**
   lots. Section 5 is the amendment.
2. **X277's "one bad shape" becomes ordinary.** A wallet can report a positive `balance`,
   a positive `promotional` and a positive `promotional_spendable` beside a positive
   `debt`, and refuse every hold and debit. Before R2 that needed a refund on a
   promotional-only wallet; after R2 any settle above a hold, or any release, on a wallet
   holding a promotion reaches it. Filed as **X357**; relaxing `{:hold, ...}`'s blanket
   refusal to `spendable/3` is a second amendment R2 did not take.
3. **A promotion left standing beside a debt is destroyed by the expiry sweep on its
   `expires_at` like any other unspent promotion.** The customer keeps it and may never
   use it. That is the sharpest edge of the decision and it is in `docs/credits.md` and
   in the changelog.
4. **Settle and release change behaviour for wallets that never saw a refund.** This is
   not a reversal-path fix; `repay_debt/5` is on every settle, release and grant path.
   Measured in section 4.5: 06b's migration replay reaches exactly the same wallets at
   all five fixed seeds.
5. **`Ledger.figures/1`'s docstring was false and is corrected.** It said an outstanding
   debt implies no eligible availability of any category, so `promotional_spendable` and
   `spendable` "cannot disagree in practice". After R2 they can and do.

## 1. Tasks, repository and revision

| | |
|---|---|
| Unit | Repair unit R2 (not a `v1-release.md` task id) |
| Findings | **X355 closed**, **X277 closed** (amendment applied), X255 and X283 updated and left open, **X357, X358, X359 opened** |
| Repositories | `aurora_meter` (core), `aurora_meter_pro` (Pro), storefront (binding maps and `open-findings.md`) |
| core HEAD | `7d0264f` on `aurorameter-v1`, **tree dirty** |
| Pro HEAD | `ff9419e` on `aurorameter-v1`, **tree dirty** |
| storefront HEAD | `324fa22` on `aurorameter-v1`, **tree dirty** |

The tree is dirty by design (rule 4) and it is **also dirty with three other units'
work**: repair unit R1 (uncommitted, and the base R2 builds on), 09a and 09b. R2 touched
none of 09a's or 09b's files. Section 3.6 accounts for every `mix check` finding.

Files R2 changed, with sha256 at the time of writing:

```
core  90919908a8fe72c3e4d5d9c7291495e12be5376ca1772bae4046968111141491  lib/aurora_meter/credits/allocator.ex
core  6f163e1b226b5075b9783d9d75a1e81a926c72201bd47f36fc83f4f8478468fe  lib/aurora_meter/credits/ledger.ex
core  c5894dafd060e1b746f4a1596583773b0bf5ae7f195910d586c0226f6dbcbe76  lib/aurora_meter/credits.ex
core  37393004e7d1e96551f0313609c03ef8dff43863149271b8bbc49a8e5977ef01  test/aurora_meter/credits/allocator_test.exs
core  4a8763afb9898bb1a79ce43c3728f71d815b1639b3dee57128f0a06415621b49  test/aurora_meter/credits_lot_reversal_test.exs
core  1e7b1173b4c3b440d9f853a643da11827ac6db9120398632733630021a71e354  test/aurora_meter/credits_lots_test.exs
core  593d78b188f603a549671c6e5c5e7f013a8fbc3cc2b13fbe92578c462a57d0a0  test/aurora_meter/credits_model_test.exs
core  c1ed262e0226a91186af1b629aea6fed563020ab8213649da349adf0970a60e4  docs/credits.md
core  824acfcf4cd344cf16807c543e7bcb1fe804e058b25a9da07988054b941b26cc  docs/upgrading-to-lots.md
core  0c2808db36f0867e1480d5421f478097ff0413c4c3ddfb1ba212521a4f5ed98a  CHANGELOG.md
pro   fbde1cbd1d94a8f677b06c2ffa2b9e81e40950d71e45568350a75ddda536e4ad  test/aurora_meter/pro/credits_lots_test.exs
store 24bf95a742bcb5fc56aeabf49d1708a281c42382d219701ed64f111b3eb5ec13  docs/v1/build-plans/architecture-map.md
store 0f43772b0bbd746c92dfafe1e4b076b30c73bc0ccc12f3b45a7ca3da0efd6a28  docs/v1/build-plans/phase-06/06a-lot-allocation-schema-and-engine.md
store 4e343df74ddc0816c8649c7e63a85fe954cade4979a17421b1a5843f30169db3  docs/v1/build-plans/open-findings.md
```

`open-findings.md` is shared: another unit wrote to it while R2 was writing to it, so its
sha256 is a snapshot of a file R2 is not the only author of. R2's rows are X355, X277,
X255, X283, X357, X358 and X359, and no finding id is duplicated
(`grep -o "^| \*\*X[0-9]*\*\*" | sort | uniq -d` is empty at 237 rows).

**Files R2 deliberately did not change, proved by sha256 rather than asserted** (the
before snapshot is `tmp/v1/r2-before.sha256`, taken before the first edit):

```
core  aa9a55ed9d3e80286d897ca27eb2958554f2286b38f18be621142c5dbd9e2762  lib/aurora_meter/credits/lot_migration.ex
core  4d1d583059c20d4b72ff2cdc53ca1247a43a8c7c5df8d76d676a2dd8b5d4ba05  test/support/aurora_meter/test/ledger_model.ex
store 49eea67f7e75e4a9d83600b339a09ad603cafad25e1cce57d4aaf372e23dd36a  docs/v1/build-plans/invariant-map.md
```

- `lot_migration.ex` is in R2's scope and needed no edit: it drives the same planner, so
  its behaviour follows the fix. Its *outcome* was measured anyway (section 4.5).
- **`ledger_model.ex` is 01e's oracle and was not edited by R1 or by R2, under any
  variant of any experiment.** An oracle adjusted by the implementer to make the
  implementation agree proves nothing (X251).
- **`invariant-map.md` needed no amendment and was not touched.** The orchestrator's
  brief named it as the home of LI-06a-5; it is not. `invariant-map.md` indexes I01 to
  I22 and its I10 row states "Every ledger amount has exact provenance and conservation",
  which R2 does not change. LI-06a-5 is a **local** invariant of build unit 06a and lives
  in `phase-06/06a-lot-allocation-schema-and-engine.md`, which is where the amendment was
  applied. Editing `invariant-map.md` to record a change it does not state would have
  been a binding-map edit for appearance.

`credits_model_test.exs` carries **comment corrections only**, R1's discipline continued:
three comment blocks are updated with R2's measurements and **no assertion in that file
changed**. The pre-R2 copy is at `tmp/v1/r2-model-test-orig.exs` and the file was
byte-restored from it after every experiment in section 4.6, with the sha256 printed
either side.

## 2. Environment

| | |
|---|---|
| Elixir / OTP | Elixir 1.20.1, Erlang/OTP 29 (erts 17.0.1), JIT |
| OS | Ubuntu 24.04 under WSL2 on Windows 11 |
| Postgres | `postgres:16` in Docker container `aurora-meter-pro-testdb`, port 5490 (the package lane) |
| core package | 0.5.0, schema `@latest 10` |
| Pro package | 0.3.0, schema `@latest 11` |

Every Mix command went through `bash tmp/v1/mixlane.sh <core|pro> mix ...`, the shared
`_build` lock. Other agents held the lane repeatedly and several runs waited for it.

## 3. Commands and logs

All logs are under `tmp/v1/` in the storefront checkout.

### 3.1 The baseline, taken before the first edit

R1 reports core 2114 and Pro 1156. **That is a different hour and a different tree**, so
R2 took its own (`tmp/v1/r2-baseline.sh`).

| Run | Log | sha256 | Result |
|---|---|---|---|
| core, before any R2 edit | `r2-baseline-core.log` | `994990356165aac55299a56990bc997de6e17a69270fea4d3094db8d76d8e630` | **2113/2114 passed**, 8 excluded, 259.9 s, **1 failing test** |
| Pro, before any R2 edit | `r2-baseline-pro.log` | `8c58c4afdb3f0d3d63e6229f55b6d0a6355083a516acdc5c8c4bcc877e700fa3` | **1156 passed**, 22.6 s, exit 0 |

**The core suite was already red by one test before R2 touched anything**, and it is not
R2's: `AuroraMeter.LiveViewTest` / `test switch_tenant/2 I20 switch_tenant unsubscribes
the old topics and subscribes the new ones` at `test/aurora_meter/live_view_test.exs:263`,
asserting `registrations(usage_topic(first)) == 0` and reading `1`. That is 09a's
untracked test over `live_view.ex`, both on R2's do-not-touch list. Taking the baseline is
the only reason this is a statement rather than a suspicion.

**It did not fail on the run after R2, which makes it a flake rather than a standing
failure, and that is worth saying because the two are not the same thing.** R2 changed
nothing on that path and claims no credit for it; what the two runs together say is that
the test is order or timing dependent, which is 09a's to know. Recorded here rather than
reported as "R2 turned the suite green".

### 3.1.1 After: both suites green, and eleven more tests of which ten are R2's

| Run | Log | sha256 | Result |
|---|---|---|---|
| core, after | `r2-core-full.log` | `dcf35f0f61c390ae837d3c9bc4329763b28ad8b0a8ef40da4f55b44825d7b2db` | **2125 passed** (81 doctests, 21 properties, 2023 tests), 8 excluded, exit 0 |
| Pro, after | `r2-pro-full.log` | `b75a62778ee573604cadb2ebc58bac9886a8f5710f4894e70dd0d9b149352218` | **1157 passed** (74 doctests, 1083 tests), exit 0 |

2114 to 2125 is eleven, and R2 added **ten**: seven in `allocator_test.exs` (16 to 23, six
tests and one property), two in `credits_lot_reversal_test.exs` (16 to 18) and one in
`credits_lots_test.exs` (20 to 21), plus one in Pro (10 to 11, which is 1156 to 1157).

**The eleventh is not R2's and the arithmetic says so exactly.** Core minus R2's three
files is 2114 - 52 = 2062 before and 2125 - 62 = 2063 after: one test appeared outside
every file R2 touched. The tree is shared and was being written to throughout:
`test/aurora_meter/ci_contract_test.exs`, `test/mix/tasks/install_test.exs` and
`test/aurora_meter/plug/ensure_entitled_test.exs` all have modification times **later than
R2's last edit to any of its own files**, along with `.formatter.exs`, `.gitignore`,
`docs/api.md`, `docs/support-policy.md` and a set of generated `*.html` files that have
appeared at the repository root. None of that is R2's and none of it is chased here; it is
recorded because a count taken from a tree three other agents are editing is a
measurement of that tree, not of this change.

### 3.2 Tests and controls

| Run | Command | Log | sha256 | Result |
|---|---|---|---|---|
| core, planner | `mix test .../credits/allocator_test.exs` | `r2-alloc2.log` | `59ddce4d19a8658fd83e886a94a178c6c38614b515e19a60cd993b24f844b349` | **23 passed** (2 properties, 21 tests) |
| core, facade | `mix test .../credits_lot_reversal_test.exs` | `r2-rev.log` | `f933cd8cc09f29f92155c8ebd9984d04d591b9d54235297e3ac013141e309926` | **18 passed** |
| core, writes | `mix test .../credits_lots_test.exs` | `r2-lots.log` | `159e6cd6de6c7f6980ff519059882736ad6b5216e3d99bb435cc6053f27f076f` | **21 passed** (1 property, 20 tests) |
| Pro, webhook | `mix test .../pro/credits_lots_test.exs` | `r2-pro.log` | `e9e5e4eed023ba47c43c663e59d3cc52ce83fdc28a7ae97724e7b2d933144a59` | **11 passed** |
| core, the neighbours | migration, replay, migration property, docs claims, doc examples, api inventory, cross-oracle | `r2-neighbours.log` | `05c7e00b1f83bd452a03f323746c3471f45ee5b67feac5c0d8c31d8607fa6f92` | **129 passed** (8 properties, 121 tests) |
| core, the prose guards | model, docs claims, doc examples, api inventory, figures | `r2-docs.log` | `e21ce46cffa2265c1234b347c2772b972efc7a9f5335af82e4054bc63320590f` | **77 passed** (8 properties, 69 tests) |
| core, control | `tmp/v1/r2-control.sh core` over the three core files | `r2-control-core.log` | `82e252b965c09c8c33e989aa61d664b478dba34bfc50843f97c08a8fe218dfd8` | **55/62, 1 property and 6 tests failed** |
| Pro, control | `tmp/v1/r2-control.sh pro` | `r2-control-pro.log` | `0acd35f3f48f3200a88a5105069e2b18644e1bca8592563b1b1ed3a1b866c7b2` | **10/11, 1 test failed** |

`tmp/v1/r2-control.sh` puts the pre-R2 `allocator.ex` back from `tmp/v1/r2-defect/`, runs,
and restores from `tmp/v1/r2-fixed/` in an `EXIT` trap, printing the sha256 both sides.
**`git checkout --` is never used anywhere in this unit** (X326). Every restore line
reads `90919908...` against the expected `90919908...`.

### 3.3 The fixed-seed sweep, on and off

`tmp/v1/r2-seeds.sh` and `tmp/v1/r2-control-seeds.sh`, at seeds 0, 1, 7, 42 and 1337 with
`AURORA_PROPERTY_RUNS=40`, over the migration property, the cross-oracle and the lot
write property. Summaries `r2-seeds-fixed/summary.log`
(`8fdc617e59ce49902ec27f268edea5c383cd4c40d2476bc3ef950c99cf47e759`) and
`r2-seeds-defect/summary.log`
(`7b292cf1b47eef116fdb655df8747708840d063011ccfb9ccdd49d43074112db`). Results in 4.5.

### 3.4 The cross-oracle experiments

`tmp/v1/r2-oracle.sh` (three variants) and `tmp/v1/r2-oracle-defect.sh`. Logs under
`tmp/v1/r2-oracle/`. Results in 4.6. The model test file's sha256 is printed before and
after every run and is `c2b5cb39...` every time it is restored.

### 3.5 The anti-regression mutants

`tmp/v1/r2-mutants.sh`, three mutations of the fixed allocator, each run against the whole
planner suite. Results in 4.4.

### 3.6 `mix check`, and why it is red in both repositories

`mix check` is red in core and in Pro for the reasons R1 recorded in its section 3.4, all
of them on 09a's and 09b's mid-flight files. R2 did not fix them and does not report them
as its own. What R2 is answerable for was run scoped and is green
(`tmp/v1/r2-credo.sh`, `r2-credo.log`,
`acb3e62e711b4d18890a74096d68a904013ae8d2e4ebff1f4683e8e62905b289`):

| Step | core | Pro |
|---|---|---|
| `mix format --check-formatted`, R2's files only | rc=0 | rc=0 |
| `mix credo --strict`, R2's files only | **rc=0, 345 mods/funs, no issues** | **rc=0, 14 mods/funs, no issues** |
| `mix dialyzer` (whole repository) | rc=0, **0 errors** | rc=0, 1 error, 1 skipped, pre-existing skip file |
| `mix compile --warnings-as-errors --force` | rc=0 | covered by the suite run |

**No project-wide `mix format` was run.** `tmp/v1/r2-format.sh` names the eight files R2
changed and formats only those.

## 4. Results

### 4.1 The defect, reproduced at the money, per lot

The fixture is forced, not waited for, and it is the whole sequence rather than the
single call. A cut-over wallet funded by `pi_1` with 10 USD, all of it spent, then given
an 8 USD promotion, then two holds of 3 USD each (spend order reserves the promotion), is
refunded 10 USD through the **wallet-wide** `Credits.reverse/4`. Then a release, then a
settle, then a grant.

**After the refund**, identical in both runs, which is R1's fix holding:

```
debt=10000000 promotional=8000000
  lot pi_1  (paid)         available=0       reserved=0       consumed=0  reversed=10000000
  lot promo (promotional)  available=2000000 reserved=6000000 consumed=0  reversed=0
```

**After `Credits.release("h_release")`:**

| | pre-R2 | with R2 |
|---|---|---|
| `promo` available | 0 | **5,000,000** |
| `promo` consumed | **5,000,000** | 0 |
| `promo` reserved | 3,000,000 | 3,000,000 |
| `row.debt` | 5,000,000 | **10,000,000** |
| `row.promotional` | 3,000,000 | **8,000,000** |

The customer's promotion paid five of the ten micro-dollars of the refund, in a
transaction that is a hold release and has nothing to do with the refund, leaving an
allocation row whose `kind` is `consume`, which is what an ordinary spend leaves.

**The pre-R2 column is measured, not inferred from reading the code.** It is the row the
control run printed when the test failed against the restored pre-R2 allocator
(`r2-control-core.log`, failure 6): `%AuroraMeter.Schema.CreditLot{reference: "promo",
category: :promotional, amount: 8000000, available: 0, reserved: 3000000, consumed:
5000000, reversed: 0, expired: 0}`.

**After `Credits.settle("h_settle", 1_000_000)`**, with R2: `promo` reads
`available 7,000,000, reserved 0, consumed 1,000,000` and `debt` is still 10,000,000. One
micro-dollar of the promotion was consumed and it was consumed **out of `:reserved`, for
work that ran**, which the rule permits. Nothing came out of `:available`.

**After `Credits.grant(4 USD, :paid)`**, with R2: the new lot reads
`available 0, consumed 4,000,000`, `debt` falls to 6,000,000, and `promo` is byte
identical to the row read before the grant. The wallet is unfrozen and the promotion
survived.

Asserted per lot at every step in `credits_lot_reversal_test.exs` / `test X355 the debt a
wallet-wide refund leaves is not repaid out of the promotion by the release, the settle or
the grant that follow`, with the promotional lot compared by **struct equality** against
the row read before each step wherever it must not move at all, so even `updated_at` is
a failure (`Allocator.update_lots!/2` writes only touched lots).

**Identical through `Credits.reverse_lot/4`**, the source-scoped function G06 bullet 5's
evidence exercises, in `test X355 reverse_lot/4 leaves the same debt and the release after
it does not take the promotion either`: pre-R2 the release read `promo consumed
4,000,000` and `debt 6,000,000`, which is R1's deterministic reproduction line for line;
with R2 it reads `promo available 4,000,000, consumed 0` and `debt 10,000,000`.

**And with no reversal at all.** The defect is in `repay_debt/5`, which every settle and
release reaches, so it is reachable from an overspend alone:
`credits_lots_test.exs` / `test X355 debt outlives promotional availability, which is
LI-06a-5 as repair unit R2 amends it` grants 3 USD paid and 4 USD promotional, holds both,
settles one 2 USD above its reservation and releases the other. Pre-R2 the release repaid
out of the promotion, measured: the control printed `lot(tenant, "promo").available` as
**2,000,000** against the expected 4,000,000, so two of the four micro-dollars of the
promotion had gone to the debt. With R2 the promotion is whole at 4,000,000 and the debt
stands at 2,000,000.

**And at one micro-dollar, which is the smallest the defect can be.** The property's
shrunk counterexample against the pre-R2 allocator is a single promotional lot
(`amount 2,440,719, available 470,327, reserved 676,811`), a debt of **1**, and a
`:release`: *"a release repaid 1 of debt out of promotional lot lot-1, which
`repay_debt/5` may never do"*. The generator shrank to a wallet with one lot, one
micro-dollar of debt and no reversal anywhere in sight, which is the clearest possible
statement that this was never about refunds.

### 4.2 The balance cannot see any of it

Every figure a wallet-level check reads is identical on the defect and on the fix at every
step above. Conservation held. `held = sum(reserved)` held. Every CHECK constraint held.
`Allocator.check!/4`, which re-reads the lots inside the transaction and compares them
with the balance row just written, fired on nothing in any run, including every control
run. The balance after the release is 3,000,000 either way, because moving X from
`available` to `consumed` while `debt` falls by X is balance neutral by construction.

That is why every assertion R2 added is per lot, and why the one wallet-level figure that
does move (`row.promotional`) is asserted beside them rather than instead of them.

### 4.3 Controls: ten, seven discriminate, and the other three were run against the
mutation each exists to catch

Against the pre-R2 allocator restored from the snapshot (`r2-control-core.log`,
`r2-control-pro.log`), **seven fail**:

| # | Test | Repository |
|---|---|---|
| 1 | property `X355 a debt repayment never names a promotional lot, and takes everything the non-promotional lots can give` | core |
| 2 | `X355 a release does not repay debt out of a promotional lot` | core |
| 3 | `X355 a release repays what the paid lots can cover and leaves the rest of the debt beside the promotion` | core |
| 4 | `X355 a settle below its reservation does not repay debt out of a promotional lot` | core |
| 5 | `X355 the debt a wallet-wide refund leaves is not repaid out of the promotion by the release, the settle or the grant that follow` | core |
| 6 | `X355 reverse_lot/4 leaves the same debt and the release after it does not take the promotion either` | core |
| 7 | `X355 the release after a fallback refund does not repay its debt out of the promotion` | Pro, through the `charge.refunded` webhook |

Control 7 is the one that answers "does a real customer meet this". The wallet is cut over,
its paid lot carries no `source.payment_intent_id` (which is what 06b's fold writes when
it cannot derive provenance, X263's large minority), so Stripe's `charge.refunded` goes
`Webhook.handle_event/1` to `reverse/3` to `take_back/5` to `reverse_lot/4` returning
`{:error, :no_matching_lots}` to `wallet_wide/6` to `Credits.reverse/4`. The hold is
released afterwards. Pre-R2, measured: the promotional lot read
`amount: 4000000, available: 0, reserved: 0, consumed: 4000000`. The whole sign-up bonus
had paid for the refund, in the release.

**Three pass on the defect too, and that is their job, not a failure of the control.**
They are anti-regression pins: their subject is behaviour that must **not** change, so a
control that restores the old behaviour cannot move them. Saying "it passed under the
control" and stopping would be X125's shape, so each was run against the mutation it
exists to catch (section 4.4).

### 4.4 The three mutants, and each pin fails exactly its own

`tmp/v1/r2-mutants.sh` writes three mutations of the **fixed** allocator and runs the whole
planner suite against each, restoring from `tmp/v1/r2-fixed/` on an `EXIT` trap.

| Mutant | What it does | Result |
|---|---|---|
| A, `disabled-repayment` | `take(book, 0, ...)` in `repay_debt/5`: the rule satisfied by never repaying at all | **19/23**. Fails `X355 a release still repays debt out of a paid lot`, `X355 a release repays what the paid lots can cover`, the new property, **and 06e's `X262 the debt a reversal creates is repaid out of paid availability`** |
| B, `over-applied-grant` | the grant clause refuses to repay out of a promotional lot | **22/23**. Fails `X355 a grant repays outstanding debt out of its own lot even when the grant is promotional`, and nothing else |
| C, `over-applied-spend` | the settle overrun spends `purchased_eligible/2`: D07's spend order deleted | **22/23**. Fails `X355 a settle above its reservation still SPENDS promotional credit`, and nothing else |

Logs `r2-mutants/disabled-repayment.log`
(`080303059fb91c2c51ddd86926dc867dd1447d21be4ccb7982bbc43681558473`),
`over-applied-grant.log`
(`117e6a487659ddafe41d2449ec42e2c934f3c05148ec914938a0f4fe5858a9bb`),
`over-applied-spend.log`
(`7297a4b1f443588188fc9e61daf87970cd41d20501d9beed86cec7e20cc4e54d`).

Mutant A is the one worth reading: the new property catches it, which is what the
two-sided assertion is for. A `refute` that no repayment names a promotional lot is
satisfied by never repaying, so the property also asserts
`repaid == min(debt, purchasable)` where `purchasable` is computed from the **final book
plus the repayment's own movements**, not from the planner's internals.

**The first attempt at this script measured nothing and said so.** `mix test --only
test:<name>` matched none of the three names and printed `0 tests, 23 excluded` with a
non-zero exit, three times. That is X350's exact shape, a detector that matches nothing
passing everything it cannot see, and it is recorded here rather than quietly corrected:
the script now runs the whole file and lists every failing test by name, so a mutation
that fails nothing is visible as a full green result rather than as an empty one.

### 4.4.1 The property was made unable to pass vacuously, by construction

R1's property arm for `:reverse_wallet` passed under its own control because every
generated case left through an error arm (X325, X350). R2's property has **no error arm
at all**: `{:settle, ...}` and `{:release, ...}` are never refused by the planner, so the
plan is matched with a hard `assert {:ok, plan} = ...` and a generated case cannot leave
without reaching every assertion.

That closes the escape route and not the second question, which is whether the generated
cases reach the *shape* the property is about. Two counters answer it and **both are
asserted after the run rather than printed**:

- `repaid_cases`: a case in which any debt was repaid at all, without which the equality
  compares nothing;
- `discriminating_cases`: a case that ended with a debt still standing **beside**
  promotional availability, which is the only shape in which the defect and the fix
  disagree.

Both must be greater than zero or the property fails with a message saying which shape
was never generated. **How far above zero was measured rather than left as an
assertion** (`tmp/v1/r2-counters.sh`, which prints the counters, runs five seeds and
restores the test file byte for byte, sha256 `37393004...` both sides):

| seed | 0 | 1 | 7 | 42 | 1337 |
|---|---|---|---|---|---|
| cases that repaid any debt | 85 | 85 | 79 | 92 | 77 |
| cases that ended with a debt beside promotional availability | 56 | 61 | 58 | 41 | 52 |

So of 100 generated cases per run, roughly four in five exercised the equality and about
half were cases in which the defect and the fix give different answers. Reaching them
required extending `book_generator/0`, which is the next item.

### 4.4.2 A hole in 06a's generator, found and closed on the way past

Every lot `book_generator/0` produced had `reserved: 0`. Two consequences, neither of them
recorded before:

- the `:reserved` bucket that a reversal takes **last** was never reached by a single
  generated case, so the conservation property said nothing about it;
- no `:settle` or `:release` could be generated at all, because both are driven by a
  hold's reservations, which is why R2's property needed the generator changed before it
  could exist.

A third percentage now puts value into `reserved`. The existing property's arms are
unchanged and still pass, and they now also cover the reserved bucket of a reversal.

### 4.5 The migration's reach is unchanged, measured at five fixed seeds

`repay_debt/5` is also on `LotMigration`'s replay path: the fold drives the same
`{:settle, ...}` and `{:release, ...}` requests, so a change to what a release repays can
change which wallets reconcile and therefore which can be cut over. X263 sizes that
population at about two thirds. This is the measurement X262 and X277 were held to.

| seed | pre-R2 compared / refused | with R2 compared / refused |
|---|---|---|
| 0 | 27 / 14 | 27 / 14 |
| 1 | 31 / 10 | 31 / 10 |
| 7 | 32 / 9 | 32 / 9 |
| 42 | 21 / 20 | 21 / 20 |
| 1337 | 31 / 10 | 31 / 10 |

**Identical at every seed.** The refusal tallies are identical too, with exactly one
difference in the whole sweep: at seed 42 one wallet's blocking label moves from
`promotional_divergence_release` to `promotional_divergence_settle`, the same wallet
blocked for the same reason one command earlier. Nothing else moves.

That is the answer to the largest risk in this change, and it was not predictable from
the code: the migration replays a legacy history whose `promotional` column the legacy
writer clamped, and the fold's reconciliation is exact.

### 4.6 The cross-oracle: the filter cannot come out, and the fix is visible in what is left

01e's `LedgerModel` was written from `architecture-map.md` section 7 before 06a existed.
`comparable_history/0` filters `{:reverse, ...}` out of the compared histories. R1 tried
to remove it and failed on X355. R2 fixed X355 and tried again at five fixed seeds, with
the filter and the `:reverse_not_wired` clause removed, **against the fixed allocator and
against the pre-R2 one**.

| seed | pre-R2, filter removed | with R2, filter removed |
|---|---|---|
| 0 | fail, compared 1 / diverged 0 | fail, compared 1 / diverged 0 |
| 1 | fail, compared 1 / diverged 0 | fail, compared 1 / diverged 0 |
| 7 | **fail**, compared 4 / diverged 2 | **pass**, compared 11 / diverged 9 |
| 42 | pass, compared 14 / diverged 6 | pass, compared 14 / diverged 6 |
| 1337 | fail, compared 4 / diverged 2 | fail, compared 4 / diverged 2 |

**It cannot come out. What it can now say is different, and that is the result.** The
shrunk divergence at every seed, with its lot's category read off the generated history
(`tmp/v1/r2-oracle-categories.sh`):

| seed | pre-R2 | with R2 |
|---|---|---|
| 0 | `g6` (**adjustment**) available: model 2,812,349, ledger 0 | same |
| 1 | `g1` (**paid**) consumed: model 22,121,167, ledger 14,739,354 | same |
| 7 | `g23` (**promotional**) available: model 22,161,246, ledger 0 | **no divergence, the property passes** |
| 42 | none, passes | none, passes |
| 1337 | `g5` (**adjustment**) reserved: model 104,398, ledger 0 | same |

So: **the promotional class of divergence is gone from the cross-oracle**, and seed 7
turns from a failure into a pass that compares nearly three times as many histories. Every
remaining divergence, at every seed, is on a **paid or adjustment** lot. That is the
already-classified `:debt_repaid_on_release` divergence: 06a repays outstanding debt out
of what a release hands back and 01e's `replay/3` does not repay at all, which is 06a's
deliberate choice against the model (X251).

**What still differs, exactly, and why the filter stays.** 01e's model has **no debt
repayment on settle, release or reverse at all**. Its only repayment is the grant clause.
So R2's change moves the implementation strictly **towards** the model on the question at
issue (the model never takes a promotional lot on a release either, because it never
takes anything), and the residual gap is one the model was always going to have: it does
not repay, and 06a does. Removing the filter therefore needs `debt_reachable?/1` to
exclude histories in which a **reversal** created debt, the way it already excludes
histories in which an overrun did.

**R2 measured the obvious version of that and it buys nothing.** A third variant widened
`debt_reachable?/1` to `LedgerModel.projections(model).debt > 0`: all five seeds are byte
identical to the run above (`r2-oracle/debt-aware.log` has the same sha256 as
`filter-out.log`). The reason is that the failing histories end with the model's debt back
at zero, a later grant having repaid it there too, long after the buckets parted company.
The state the harness needs is "debt was **ever** positive", which 01e's view does not
keep. That is real work on the harness and R2 did not do it: **the oracle and its
exclusion predicate were left alone**, because the author of the repayment fix is the
wrong author for the exclusion that decides whether the repayment is compared.

**One correction to the brief.** The orchestrator's statement that 01e's model "already
implements paid-only repayment" is not what the source says. `ledger_model.ex` implements
paid-only **reversal targeting** (`reverse_from/3` filters on `paid_lot?/1`,
`ledger_model.ex:878`, `:1001`) and implements **no repayment on settle or release**
(`replay/3`'s `{:settle, ...}` at `:780` and `{:release, ...}` at `:794` unreserve,
subtract `held` and stop). Its one repayment is `{:grant, ...}` at `:738`, and that one is
category blind. The mechanism the brief describes is right; the oracle's position on it is
narrower than described, and it matters because it is the reason the filter still cannot
come out.

### 4.7 Accounting reconciliation

Every run above is inside `AuroraMeter.Credits.Allocator.check!/4`. It fired on nothing,
including in every control run and every mutant run. The five-bucket CHECK, the state
CHECK, the `held = sum(reserved)` projection and the `balance = sum(available + reserved)
- debt` identity all held throughout, on the fix and on the defect, which is section 4.2's
point restated: none of them can see this.

The new property adds the planner-level version: on every generated settle and release,
each lot's five buckets still sum to its amount and none is negative.

## 5. The binding-map amendment, applied

**This is a binding-map edit and it is called out rather than folded into the repair.**
Under the decision in section 0 it is not optional: it is the same decision, because a
debt that may not take a promotion is a debt that can stand beside one.

**`architecture-map.md` 7.2** gains a dated amendment block, signed by the unit and the
findings, stating the two rules (no debt is repaid out of promotional credit the wallet
already holds; the grant clause is the one exception) and the invariant they cost. The
original sentences are left standing and are not rewritten.

**06a's LI-06a-5** now reads:

> **LI-06a-5 (debt exclusivity)**: `debt > 0` implies `SUM(lot.available) = 0` over that
> wallet's **non-promotional** lots. [...] The promotional exclusion in
> `architecture-map.md` 7.2 is the stronger rule and it wins: where the only availability
> left is promotional, the debt stands beside it until the next incoming **grant** repays
> it.

This is R1's proposed text with one word changed: R1 wrote "until the next incoming
value", and after R2 nothing but a grant can repay it.

**A test still enforced the unamended form, and it would have failed.**
`credits_lots_test.exs`'s generated-history property asserted `if row.debt > 0, do:
assert(available == 0)` over **every** lot. Under R2 a release can leave a promotional
lot with availability beside a debt, so that assertion is now false. It is widened in the
same change, with the amendment's reasoning beside it, and **the non-promotional half is
still asserted exactly**, so the invariant is weakened by precisely what 7.2's promise
costs and by nothing else. This is the failure the brief predicted; finding it by running
the suite rather than by reading is the reason it is reported as information.

**Nothing else asserts the unamended form, and the sweep is recorded rather than
summarised.** `grep -rln "LI-06a-5"` returns thirteen files in core (excluding `_build`
and `deps`) and four under `docs/v1/build-plans`:

| File | What it holds | R2 |
|---|---|---|
| `test/aurora_meter/credits_lots_test.exs` | **the assertion**, in the generated-history property | widened, with the reasoning beside it |
| `lib/aurora_meter/credits/ledger.ex` | `figures/1`'s docstring, which was **false** after R2 | rewritten, section 6.1 |
| `lib/aurora_meter/credits/allocator.ex` | three comments on the reverse clause and `repay_debt/5` | rewritten |
| `test/aurora_meter/credits_model_test.exs` | `classify/3`'s `:debt_repaid_on_release` comment | comment corrected, no assertion changed |
| `test/aurora_meter/credits/allocator_test.exs`, `credits_lot_reversal_test.exs`, `credits_lot_migration_property_test.exs` | comments about a paid lot repaying, still true | untouched |
| `docs/v1/build-plans/phase-06/06a-...md` | **the statement** | amended |
| `docs/v1/build-plans/architecture-map.md` | 7.2 | amended |
| `docs/v1/build-plans/open-findings.md` | X251, X262, X277, X355 | X277 and X355 closed, X359 added |
| `docs/v1/build-plans/phase-06/06e-pro-lot-integration.md`, and five evidence files under `core:docs/evidence/v1/` | history, including R1's | not amended: an evidence file records what was true when it was written |

`invariant-map.md` does not state it (section 1) and was not touched. `docs/correctness.md`
does not mention it at all and was not touched: it is 09a's and mid-edit.

## 6. Open defects and corrections

### 6.1 Corrected in passing: `Ledger.figures/1`'s docstring was false

It said `promotional_spendable` and `spendable` "cannot disagree in practice, because
every incoming value repays debt out of eligible availability first (LI-06a-5), so an
outstanding debt implies no eligible availability of any category and both figures are
zero". After R2 they disagree routinely: a refunded wallet reports
`promotional_spendable: 4_000_000` beside `spendable: -2_000_000`. The docstring now says
so and says which question each figure answers. No behaviour changed and
`credits_figures_test.exs` passes unaltered (`r2-docs.log`).

### 6.2 X357, new and not fixed: the blanket `debt > 0` refusal

`{:hold, ...}` and `{:debit, ...}` refuse outright while `debt > 0`, which after R2
refuses an ordinary wallet rather than a rare one: a wallet holding a promotion and owing
money reports a positive balance and refuses everything. The candidate fix is one
condition, `spendable/3 < amount` instead of `debt > 0`, and it is **a second amendment to
7.2**, it partially reverses X251's fix (`debit` was made to refuse on `debt > 0` because
01e's model caught it accepting a debit beside a debt), and it needs its own measurement.
R2 asserts the cost rather than fixing it: `credits_lots_test.exs` / `test X355 debt
outlives promotional availability` pins both the refusal and the grant that lifts it.
**Owner: the orchestrator, with X277 and X283.**

### 6.3 X358, new: G06 bullet 5's tick

Section 7 answers the orchestrator's question directly. The row is filed because a tick
already given is corrected with a finding, not quietly repaired (X337's precedent).

### 6.4 X359, new and small: LI-06a-5 cites an enforcer that does not exist

The invariant's own sentence ends "Asserted by the model test and by the conservation
check's optional strict mode". There is no strict mode: `grep -n strict
lib/aurora_meter/credits/allocator.ex` returns nothing, and `check!/4` checks the
projection identities (LI-06a-2), not debt exclusivity. R2 amended the invariant's
statement and deliberately did not also invent its enforcer, because a new refusal on
every ledger write is not a documentation repair. The behavioural enforcement that does
exist is the generated-history property, which R2 widened in the same change.

### 6.5 X255 and X283: updated, still open, still the orchestrator's

R2 was not asked to decide them and does not. Its decision changes nothing about where a
wallet is born and nothing about the migration's reach (4.5). What it adds is one line
that whichever release note answers X283 now has to carry: **a wallet the allocator owns
can hold promotional credit and owe money at the same time and spend neither, which the
legacy writer never did.** If new wallets are born on lots, that difference arrives for
every new wallet on `mix deps.update`, which is the strongest form of X283's own
objection and is now customer visible rather than internal.

### 6.6 X278: narrowed, not closed

The cross-oracle filter stays. What is owed is smaller than it was and is now measured
rather than predicted: section 4.6 gives the exact remaining divergence at each of five
seeds, the category of every diverging lot, and the measurement showing that the obvious
widening of `debt_reachable?/1` buys nothing. **Owner: a unit that is neither R1's author
nor R2's.**

### 6.7 Not touched

- **X259** (no partial-expiry request in the planner), **X257**, **X261**, **X263**,
  **X270**: unchanged by R2 and unexamined by it beyond what section 4.5 measures.
- **The `{:restore, ...}` clause** repays out of the payment's own lots, which
  `reversal_targets/2` already restricts to non-promotional, so it was already consistent
  with the new rule and needed no change. Recorded so a reader does not have to check.

### 6.8 Skipped tests

None. R2 skipped no test, added no `@tag :skip`, excluded nothing. The 8 excluded tests in
every core run are the pre-existing `:headless` tag.

## 7. G06 bullet 5: a direct answer

**The tick was wrong, and it should be corrected rather than defended.**

The bullet is: *"A refund of a spent paid lot does not erase later promotional credit or
exceed the original payment's net reversible grant."* It was ticked **MET** by 06e "three
ways: a core test asserting on the allocation rows rather than the balance, Pro's refund
matrix through the webhook, and scenario 5 of the real Stripe run".

All three are sound about what they assert, and all three assert the same narrower thing:
**no allocation written by the refund's own transaction names a promotional lot.** The
bullet is not about a transaction. It is about whether the customer's promotional credit
survives, and it did not: the debt the refund left was repaid out of the promotion by the
next `release` or `settle`.

The sharpest part is that the bullet's own premise is the shape that breaks it. "A refund
of a **spent** paid lot" is exactly the refund that reaches `consumed`, and reaching
`consumed` is what raises `debt`. So the bullet describes the only case in which its own
claim was false, and was ticked on a test of a refund with no hold behind it.

R1 wrote this down before the tick was given. Its X355 row says, in as many words: *"What
must not happen is that G06 bullet 5 is ticked on the reversal test alone: the test that
passes is a refund with no hold behind it, and the wallet this row describes is a
perfectly ordinary one."* The tick was given anyway, on 2026-09-16, with X355 open. A
finding that names a gate bullet should reopen that bullet.

**What is true now**, and what a re-tick could honestly rest on, all four of which fail
against the pre-R2 allocator:

1. `core:credits_lot_reversal_test.exs` / `test X355 the debt a wallet-wide refund leaves
   is not repaid out of the promotion by the release, the settle or the grant that
   follow`: refund, release, settle and grant in sequence, promotional lot compared field
   for field after each;
2. `core:credits_lot_reversal_test.exs` / `test X355 reverse_lot/4 leaves the same debt
   and the release after it does not take the promotion either`: the same through the
   exact function the bullet's own evidence used;
3. `pro:credits_lots_test.exs` / `test X355 the release after a fallback refund does not
   repay its debt out of the promotion`: through Stripe's `charge.refunded` webhook, on a
   wallet whose provenance the migration could not derive, which X263 sizes at a large
   minority;
4. the cross-oracle at seed 7, where the pre-R2 failure was a promotional lot 01e's
   independent model said held 22,161,246 reading 0, and where the property now passes.

**What a re-tick still could not rest on**: the second half of the bullet, "or exceed the
original payment's net reversible grant", is 06e's cap and R2 changed nothing about it.
And **R2 must not tick it** (rule 4): the correction is the orchestrator's, with X358 in
front of them.

## 8. Handoff

**Where the work stopped.** The fix, its ten controls, its three mutants, the two
binding-map amendments and the evidence are complete. The tree is dirty and uncommitted in
all three repositories. Nothing is ticked.

**What a reviewer should read first**, in this order: section 0 (the decision, and
especially the grant exemption, which is the half to attack), section 4.1 (the money, per
lot, per step), section 4.4 (the three mutants and the script that measured nothing on its
first attempt), section 4.6 (the cross-oracle result and the correction to the brief), and
section 7 (G06 bullet 5).

**What must not change:**

- **There is one debt-repayment function in the planner.** If a caller ever needs a
  different repayment rule, that is a finding, not a second private function. X355 was
  born the day there were two.
- `repay_debt/5` over `purchased_eligible/2`, and the `{:grant, ...}` clause's repayment
  over its own new lot of whatever category. The three mutants in `tmp/v1/r2-mutants.sh`
  are the guard on both, in both directions.
- The new property's two counters and their post-run assertions. Without them a run that
  generated no book holding a promotion beside a debt is green and has measured nothing.
- The new property's hard `assert {:ok, plan} = ...`. It is what makes an error arm
  impossible, which is how X325 and X350's shape is closed by construction here rather
  than by a `refute` in the arm.
- `credits_lots_test.exs`'s LI-06a-5 assertion must keep asserting the **non-promotional**
  half exactly. Dropping it entirely would leave the amendment with no enforcement at all.

**Next verification targets**, in priority order:

1. **G06 bullet 5 and X358**, by the orchestrator. It is a gate correction, not a repair.
2. **X357**, the blanket `debt > 0` refusal, which R2's decision makes ordinary and which
   is the next thing a host will report.
3. **X283**, the new-wallet rollout decision, now with one more release-note line
   attached (6.5).
4. **X278**, the cross-oracle filter, by an author who is neither R1's nor R2's, with
   section 4.6's measurement as the starting point rather than a fresh experiment.
5. **`mix check`** in both packages, once 09a and 09b land. R2's own files pass every step
   scoped; the repository runs cannot be green until those units finish, and the core
   suite carries 09a's failing `live_view_test.exs` in the meantime.
