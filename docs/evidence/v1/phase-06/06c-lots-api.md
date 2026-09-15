# 06c: the lot read API, worked from a support question

V1 task **06.03**: "add grant list, detail and allocation history for support and
dashboards through public APIs". Invariant **I10**: the read API is how a human
audits provenance, so a support answer that cannot be produced from it is a gap
in the model rather than in the tooling.

Every figure below was captured from a running ledger:
`tmp/v1/06c-lots-scenario.exs`, Postgres 16.13, 2026-09-15, log
`tmp/v1/06c-logs/lots-scenario.log` sha256
`b5aa41d822bd1fdb6b828b3a4a23d7ba590b7f36d6d2c213d582233022daf899`.

## The wallet

One tenant, cut over to lots, five events, in this order:

| # | Event | Amount | Detail |
|---|---|---|---|
| 1 | promotional grant `promo:signup` | 3 USD | expires 2026-10-01 |
| 2 | promotional grant `promo:conference` | 5 USD | expires 2026-12-01 |
| 3 | paid grant `stripe:pi_…` | 10 USD | `source: %{payment_intent_id: pi, checkout_session_id: cs}` |
| 4 | hold `job:render-1` 4 USD, settled at 6 USD | overrun 2 USD | |
| 5 | reversal `refund:pi_…:200` | 2 USD | a partial refund of the payment |

## What the operator sees

### `Credits.balance(org)`

```elixir
%{balance: 10000000, held: 0, available: 10000000, spendable: 10000000,
  promotional: 0, promotional_spendable: 0, debt: 0, expired: 0,
  currency: "usd", low_balance_threshold: nil}
```

18 USD granted, 6 USD settled, 2 USD refunded, 10 USD left, no debt (the overrun
was covered by the promotional credit) and nothing expired.

### `Lots.list(org)`: what the next debit will take

```elixir
[%{reference: "stripe:pi_…", category: :paid, amount: 10000000,
   available: 10000000, reserved: 0, consumed: 0, reversed: 0, expired: 0,
   state: :open, expires_at: nil}]
```

One lot, because the default is `states: [:open]` and both promotions are spent.

### `Lots.list(org, states: :all)`: the whole history

```elixir
[{"promo:signup",     :exhausted, 0,        3000000},
 {"promo:conference", :exhausted, 0,        5000000},
 {"stripe:pi_…",      :open,      10000000, 0}]
```

Promotional before paid, and inside promotional the earliest expiry first. That
is the spend order, and it is the order the settlement actually consumed them
in, which the trail below confirms.

### `Lots.for_source(org, %{payment_intent_id: pi})`: what this payment bought

```elixir
[{"stripe:pi_…", amount: 10000000, available: 10000000, consumed: 0}]
```

Exactly one lot, and not the promotions. This is the function 06e will use to
cap a refund, and the refusal on an unsupported key is what stops it becoming
"every lot".

### `Lots.allocations(org)`: where the money went

```elixir
[{"promo:signup",     :reserve, :available, :reserved, 3000000},
 {"promo:conference", :reserve, :available, :reserved, 1000000},
 {"promo:signup",     :consume, :reserved,  :consumed, 3000000},
 {"promo:conference", :consume, :reserved,  :consumed, 1000000},
 {"promo:conference", :consume, :available, :consumed, 2000000},
 {"promo:conference", :consume, :available, :consumed, 2000000}]
```

### `Lots.allocations(org, reference: "job:render-1")`: one job

```elixir
[{"promo:signup",     :reserve, :available, :reserved, 3000000},
 {"promo:conference", :reserve, :available, :reserved, 1000000},
 {"promo:signup",     :consume, :reserved,  :consumed, 3000000},
 {"promo:conference", :consume, :reserved,  :consumed, 1000000},
 {"promo:conference", :consume, :available, :consumed, 2000000}]
```

## The narrative an operator would write

> The 4 USD hold for `job:render-1` reserved the signup promotion in full (3 USD)
> and 1 USD of the conference promotion, soonest expiry first. The job actually
> cost 6 USD. The settlement consumed both reservations and then took the extra
> 2 USD from what the conference promotion still had available. Nothing was
> written off and no debt was created, because the conference promotion covered
> the overrun. Your 10 USD payment is untouched and is what the next job will
> spend.

Every sentence of that is read from the trail. `from_bucket` and `to_bucket` are
what make it possible: the two `consume` rows on `promo:conference` differ only
in where the value came from, and "consumed from its own reservation" and
"consumed from spare availability" are different facts about the same settlement
(finding X249).

The settle row's own metadata is `%{}`: nothing was written off, so there is no
`expired_amount` key. A settlement that had lost reserved value to an expiry
would carry one, which is the one case where a settle moves the balance by
something other than its own cost.

## What this scenario also shows, and it is a live finding

**The 2 USD refund of a *paid* payment consumed the promotional
`promo:conference` lot and wrote nothing into `reversed`.** That is the last
allocation in the trail above, and it is finding **X250**, visible rather than
argued.

```elixir
# the refund's own row is right
%{kind: :reverse, category: :reversal, reference: "refund:pi_…:200", amount: -2000000}

# ...and the lot it touched is the wrong one
{"promo:conference", :consume, :available, :consumed, 2000000}

# ...while the lot the payment actually funded is untouched
Lots.get(org, "stripe:pi_…")
#=> %{available: 10000000, consumed: 0, reversed: 0, state: :open, ...}
```

`v1-release.md` 10.1 forbids this by name: "Promotional lots cannot absorb a paid
refund simply because they were created later."

**It is not a live defect**, and the reason is a gate rather than luck:
`Credits.reverse/4` does not take the lot path, no production wallet has
`lots_enabled_at` set, and `LotMigration.cutover_blocked/0` refuses a cutover
while `function_exported?(AuroraMeter.Credits, :reverse_lot, 4)` is false. This
scenario reached it only because it called `Ledger.enable_lots!/1` directly,
which is the maintainer door.

**06e owns the fix**, and this file is what its evidence should be compared
against: after 06e the last allocation should read
`{"stripe:pi_…", :reverse, :available, :reversed, 2000000}` and the promotional
lot should be untouched. 06c deliberately did not fix it: wiring `reverse_lot/4`
here would open the cutover gate that 06e is meant to open.

## Refusals, which are part of the contract

| Call | Answer |
|---|---|
| `Lots.for_source(org, %{promotion: "welcome"})` | `ArgumentError` naming `[:payment_intent_id, :recurrence_key]` |
| `Lots.for_source(org, %{})` | `ArgumentError` |
| `Lots.for_source(org, %{payment_intent_id: 7})` | `ArgumentError`: values are strings |
| `Lots.list(org, states: [:nonsense])` | `ArgumentError` naming the four states |
| `Lots.list(org, order: :whatever)` | `ArgumentError`: `:spend` or `:granted_at` |
| `Lots.list(org, limit: 0)` | `ArgumentError`: a positive integer |
| `Lots.list(org, limit: 100_000)` | capped at 500, silently, which is documented |
| `Lots.get(org, "unknown")` | `nil` |
| `Lots.get(other_tenant, lot_id)` | `nil`: a lot belongs to one wallet |
| every function on a wallet with no lots | `[]` or `nil` |

The `for_source/2` refusal is the one that matters most. Its caller is a refund
path; a matcher that ignored a key it did not understand would return **every**
lot, and a refund against every lot is not a near miss.

## Paging

`test I10 Lots.list paginates by cursor without skipping or repeating a lot`
walks 25 lots in pages of 7, in both orders, and asserts 25 distinct references
equal to the single-page listing. Both orders end in the lot's own ordering key,
which is unique, so the keyset is total: a page boundary cannot fall between two
lots that compare equal, because no two do.
