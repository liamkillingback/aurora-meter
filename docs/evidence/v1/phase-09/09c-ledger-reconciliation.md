# 09c: the ledger, reconciled

Figures read from the live development database after `mix ecto.reset`,
`mix sample.seed` and the browser walkthrough recorded in `09c-sample-run.md`
section 6. Collected by `tmp/v1/09c-collect.sh` through the public API only:
`AuroraMeter.Credits.summary/1`, `history/2`, `Lots.list/2` and
`Lots.allocations/2`. Nothing reads an `aurora_meter_*` table directly.

All amounts are micro-dollars. USD only (D06).

## 1. The two organisations

| | `acme` (`org_1`) | `globex` (`org_2`) |
|---|---|---|
| plan | `:free` | `:studio` |
| ledger entries | 0 | 32 |
| granted this period | 0 | 32,000,000 |
| spent this period | 0 | 5,920 |

`acme` holds nothing on purpose: it is the organisation that gets refused, and a
sample where every path succeeds teaches nothing about the paths that do not.

## 2. Conservation

The identity is checked by summing **every ledger entry ever written** for the
wallet and comparing the two totals with what the summary reports. `amount` is
the signed delta an entry applied to the balance; `held_delta` is the delta it
applied to the reserved figure.

### `globex`

| Quantity | Ledger sum | Summary | Agree |
|---|---|---|---|
| balance | 31,994,080 | 31,994,080 | yes |
| held | 0 | 0 | yes |
| available | | 31,994,080 | `balance - held == available`: yes |

`entries = 32`, `identity holds = yes`.

### `acme`

| Quantity | Ledger sum | Summary | Agree |
|---|---|---|---|
| balance | 0 | 0 | yes |
| held | 0 | 0 | yes |

`entries = 0`. A wallet with nothing in it satisfies the identity trivially,
which is why it is not the wallet the claim rests on.

### The same identity under load

`ops_live_test.exs` "I10 granted minus spent minus held equals available after a
scripted sequence" runs the check against a wallet with something in every
bucket: a grant, ten settled generations, one refused generation and **one open
hold** of 1,000,000 micro-dollars. It asserts `entries > 20`, both sums against
both summary figures, `summary_held == 1_000_000`, and the subtraction identity.

The page states, and this file repeats, that it is a snapshot taken with several
queries rather than a serialised total: a generation completing between two of
the reads moves one figure and not the other.

## 3. Full summary, `globex`

```
balance                31_994_080
available              31_994_080
spendable              31_994_080
promotional            11_994_080
promotional_spendable  11_994_080
held                            0
debt                            0
expired                         0
granted_this_period    32_000_000
spent_this_period           5_920
```

`spendable == available` and `promotional_spendable == promotional` because
`debt` is zero. Repair unit R3's rule is that both spendability figures read
**zero** while a wallet owes, whatever the balance says, and the sample's
`/generate` and `/dev/tools` both render `debt` and both carry the banner that
explains the frozen state. It cannot be reached on a fresh installation at all,
for the reason in `09c-library-findings.md` finding 5: `debt` is only ever
non-zero on a wallet the allocator owns, and a reversal is the only thing that
puts it there.

## 4. The lots, in spend order (D07)

The seed grants three lots and the `:studio` plan's recurring allowance adds a
fourth. The number is not arbitrary: promotional before paid, and within
promotional earliest expiry first, needs at least two promotional lots with
different expiry dates and one paid lot to be visible at all.

| # | Category | Reference | Amount | Available | Consumed | Expires |
|---|---|---|---|---|---|---|
| 1 | promotional | `synthetic:seed:globex:promo-early` | 3,000,000 | 2,994,080 | **5,920** | 2026-09-23 |
| 2 | promotional | `recurring:org_2:monthly_allowance:studio:1:2026-09-01T00:00:00Z` | 5,000,000 | 5,000,000 | 0 | 2026-10-01 |
| 3 | promotional | `synthetic:seed:globex:promo-late` | 4,000,000 | 4,000,000 | 0 | 2026-11-15 |
| 4 | paid | `synthetic:seed:globex` | 20,000,000 | 20,000,000 | 0 | never |

The order the library returned them in is the order above, and it is exactly
D07: every promotional lot before the paid one, and the three promotional lots
sorted by expiry. The recurring allowance sorts **between** the two seeded
promotions because its period-end expiry falls between their two dates, which is
the rule working rather than a coincidence of insertion order.

### Where the spending went

Thirteen generations, all thirteen drawn from lot 1:

```
consume allocations by lot:
  synthetic:seed:globex:promo-early (promotional) rows=13 total=5920
```

5,920 micro-dollars is well inside lot 1's 3,000,000, so nothing reached lots 2,
3 or 4. That is correct and it is also why the **test** for the order uses two
promotional lots of 60 micro-dollars each: a single generation there costs more
than both together and has to reach the paid lot, so the order after the first
lot is observed rather than assumed.

`generations_test.exs` "spend draws the earlier-expiring promotional lot, then
the later one, then the paid lot":

```
assert length(lots) == 3, "the lot engine is off for this wallet, so this test proves nothing"
assert generation.cost_micros > 120, "the spend did not exceed the two promotional lots,
                                      so the order after them is unobserved"
assert categories == [:promotional, :promotional, :paid]
assert DateTime.compare(early, late) == :lt
```

Both guards are there deliberately. The first fails loudly if the wallet is on
the legacy engine, where `Lots.list/2` returns `[]` and every assertion about
order would be vacuous. The second fails loudly if the spend is too small to
leave the first lot.

### The allocation trail

Each generation produces three movements, visible on `/ops`:

```
reserve    available -> reserved    $0.00046   promo-early
consume    reserved  -> consumed    $0.00028   promo-early
unreserve  reserved  -> available   $0.00018   promo-early
```

The estimate is reserved, the actual is consumed, and the difference goes back.
That is the hold-and-settle lifecycle written in lot terms, and it is the reason
the sample says a settlement is one movement rather than two debits.

## 5. Before and after the refused generation

The two `/ops` reads in the browser walkthrough bracket exactly one event: the
`fail: on purpose` submit. The first read was taken after the image generation
had settled; the collection script ran after the refusal.

| | after the image generation | after the refusal |
|---|---|---|
| ledger entries | 30 | **32** |
| balance | 31,994,080 | **31,994,080** |
| held | 0 | 0 |
| images usage | 4 | **4** |
| tokens usage | 592 | **592** |
| identity holds | yes | yes |

This is the whole of I03 and I04 in five numbers. The refusal wrote **two**
ledger entries, a `hold` and a `release`, so the wallet's history records that
something was attempted. It moved **no money**: the balance is identical to the
micro-dollar. It consumed **no quota**: the image count did not move. And it
recorded **no usage**: the token count did not move, because the work raised
before `AuroraMeter.record/4` was ever called.

The entry count going up while every other figure stands still is the shape to
look for. A failure that left no trace would be indistinguishable from a request
that never arrived, and a failure that moved a figure would be a customer paying
for nothing.
