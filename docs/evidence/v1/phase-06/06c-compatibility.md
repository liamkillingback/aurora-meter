# 06c: the credit API compatibility table

V1 task **06.03**: "retain existing grant, hold, settle, release, debit and
reverse return contracts or ship documented V1 adapters".

Every "after" value below was **captured from a running ledger**, not written
from the code: `tmp/v1/06c-compat-probe.exs`, run against Postgres 16.13 on
2026-09-15, log `tmp/v1/06c-logs/compat-probe.log` sha256
`bdea1a25cadf971560a1fc21ceb3491a26ad54cdf10a6874d56fceefff174846`. "Before"
values are quoted from the assertion that held them at core
`04d8dd4d6c2c2b32c9d923abb501c188a5f851b1`, and the file and test that held each
one is named so the claim can be checked against git rather than against this
document.

## The table

| Function | Status | Detail |
|---|---|---|
| `balance/1` | **adapted** (additive keys) | gains `spendable`, `promotional_spendable`, `debt`, `expired` |
| `available/1` | unchanged | still `balance - held` |
| `sufficient?/2` | adapted in 06a | now compares `spendable`; 06c reports the same figure |
| `grant/3` | **adapted** | cross-tenant reference collision; gains `:source` (06a) |
| `grant_with_status/3` | **adapted** | same collision change; `:new \| :duplicate` unchanged |
| `hold/4` | unchanged shape | refusal follows `sufficient?/2` |
| `settle/3` | unchanged | plus the range guard |
| `release/1,2` | unchanged | |
| `debit/4` | unchanged shape | plus the range guard |
| `reverse/4` | **adapted** | writes `kind: :reverse`, keeps `category: :reversal` |
| `pending_holds/1` | unchanged | |
| `reconcile_holds/1` | unchanged | |
| `with_credits/4` | unchanged | |
| `history/2` | **adapted** | `:reverse` in the default kinds; gains `:cursor`; `:before` kept and documented as lossy |
| `spend_history/2`, `spend_total/2` | unchanged output | `:kinds` now rejects `:reverse` |
| `summary/1` | **adapted** (additive keys) | the same four keys |
| `set_low_balance_threshold/2` | **adapted** (behaviour) | recomputes the standing crossing |
| `expire_due/1,2` | unchanged shape | documentation corrected (L15) |
| `subscribe/1`, `topic/1` | unchanged | |
| `Money.*` | unchanged | `assert_range!/1` and `max_micro/0` added |
| `Schema.CreditTransaction.kinds/0` | adapted in 06a | already contained `:reverse` |
| `Schema.CreditTransaction.categories/0` | unchanged | still the three grant categories |
| PubSub `{:aurora_meter, :credits, map}` | **adapted** (additive keys) | gains `spendable`, `debt`, `expired` |
| PubSub `{:aurora_meter, :low_balance, event}` | **adapted** (additive keys) | gains `spendable`, `crossing_id` |
| Telemetry `[:aurora_meter, :credits, kind]` | **adapted** | `kind` can be `:reverse`; gains `spendable_after` and `deferred` |
| Telemetry `[:aurora_meter, :credits, :low_balance]` | **adapted** | gains `spendable`, `crossing_id`, `handler`; now emitted **after** the handler |

## Each adapted row, measured

### `balance/1` and `summary/1`: four additive keys

**Before**, `credits.ex`'s own doctest at the starting SHA:

```elixir
%{balance: 0, held: 0, available: 0, promotional: 0, currency: "usd", low_balance_threshold: nil}
```

**After**, measured:

```elixir
# never funded
%{balance: 0, held: 0, available: 0, spendable: 0, promotional: 0,
  promotional_spendable: 0, debt: 0, expired: 0, currency: "usd",
  low_balance_threshold: nil}

# a legacy wallet: 10 USD paid, 4 USD promotional, 3 USD held
%{balance: 14000000, held: 3000000, available: 11000000, spendable: 11000000,
  promotional: 4000000, promotional_spendable: 4000000, debt: 0, expired: 0,
  currency: "usd", low_balance_threshold: nil}

# summary/1's keys
[:available, :balance, :currency, :daily_burn, :debt, :expired,
 :granted_this_period, :held, :period, :promotional, :promotional_spendable,
 :runway_days, :spendable, :spent_this_period]
```

On a legacy wallet `spendable == available` and `promotional_spendable ==
promotional`, which is the compatibility promise. On a cut-over wallet they part
company, and the measurement shows exactly how: 5 USD paid, 3 USD promotional
already past its `expires_at`, 1 USD held.

```elixir
%{balance: 8000000, held: 1000000, available: 7000000,
  spendable: 4000000,            # the 3 USD is past its expiry, so it is not spendable
  promotional: 3000000,
  promotional_spendable: 0,      # ...and none of it is promotional spendable
  debt: 0, expired: 0, currency: "usd", low_balance_threshold: nil}
```

The hold reserved from the **paid** lot rather than the promotional one, which
would be the spend order on an unexpired promotion. That is the eligibility rule
working, visible in the figures.

**Release note.** "`AuroraMeter.Credits.balance/1` and `summary/1` report four
more figures: `spendable`, `promotional_spendable`, `debt` and `expired`. The
existing keys keep their meanings exactly, and on a wallet that has not been cut
over to credit lots the four restate what you already had."

**Risk.** Additive map keys break a caller that pattern-matches the map
**exactly**, which the documentation has never promised and which the whole test
suite avoids. The one exact comparison in the package is `balance/1`'s own
doctest, and the one in the test tree is `LedgerCommands.wallet_problems/2`,
which is 01e's oracle and was extended rather than relaxed (`06c-report.md`
section 4).

### `reverse/4`: `kind: :reverse`

**Before**, `test/regressions/seeds/i10-l2-reverse-shares-the-debit-reference-namespace.exs`
at the starting SHA recorded that `grant 1 USD; debit "order-1" 0.10; reverse
"order-1" 0.05` left the balance at **900_000**: the debit landed and the
reversal was refused.

**After**, measured, same reference for both:

```elixir
debit/4   %{kind: :debit,   category: nil,       reference: "order:99:…", amount: -1000000}
reverse/4 %{kind: :reverse, category: :reversal, reference: "order:99:…", amount: -2000000}

second reverse under the same reference : {:error, :duplicate_reference}
second debit  under the same reference  : {:error, :duplicate_reference}
```

Both land, and idempotency inside each namespace is unchanged. The separation is
the database's: the unique index is on `(kind, reference)`.

**Both shapes are permanent, and both read as reversals**:

```elixir
reversal?(%{kind: :reverse, category: :reversal}) # => true
reversal?(%{kind: :debit,   category: :reversal}) # => true

# one wallet holding both, after rewriting one row to the pre-version-9 shape
[{:debit,   :reversal, "refund:legacy-shape:…"},
 {:reverse, :reversal, "order:99:…"}]
```

And the reporting is unchanged across the change, because `Series` scores by
`category`. The same wallet, before and after one row was rewritten to the
legacy shape, with a 0.50 USD reversal added in between:

```elixir
# new shape only
%{spent: 1000000, granted: 12000000, net: 11000000}
# both shapes, after adding a 0.50 USD reversal and rewriting it to :debit
%{spent: 1000000, granted: 11500000, net: 10500000}
```

`spent` did not move: neither shape is scored as spend. `granted` fell by
exactly the new reversal, from either shape. That is the assertion that would
fail if anything in `Series` had been switched from `category` to `kind`.

**Release note.** "A reversal is now written with its own `kind: :reverse`
rather than as a `:debit` carrying `category: :reversal`, so a refund and an
ordinary debit no longer share a reference namespace and neither is refused for
the other's write. Existing rows are unchanged and still read as reversals; ask
`AuroraMeter.Schema.CreditTransaction.reversal?/1` rather than matching on a
kind. `spend_history/2`, `spend_total/2` and `history/2`'s default view are
unchanged in content. **If you query `aurora_meter_credit_transactions` directly
for `kind = 'debit'` to find reversals, that query now misses new ones: use
`kind = 'reverse' OR category = 'reversal'`.**"

**Risk, and it is the highest in this unit.** The release note's last sentence
is not hypothetical: our own Pro package did exactly that, in
`AuroraMeter.Pro.Credits.reference_total/3`, and it cost 22 test failures and
would have refunded a customer twice. See `06c-report.md` section 4.

### `grant/3` and `grant_with_status/3`: a cross-tenant reference

**Before**, `open-findings.md` L3: a reference already held by another tenant
returned a raw `%Ecto.Changeset{}`, because the in-transaction lookup is scoped
to one tenant and the collision only surfaces at the global unique index.

**After**, measured:

```elixir
# another tenant already holds this reference
grant/3 cross-tenant reference          : {:error, :duplicate_reference}
# the same tenant, the same reference: still the original entry
grant/3 same tenant, same reference     : :ok
# a changeset error that is not a collision: still a changeset
grant/3 with expires_at on a paid grant :
  {:error, {:changeset, [expires_at: {"only promotional grants expire", []}]}}
```

The mapping is **narrow on purpose**. Mapping every changeset error the way
`hold/4` and `debit/4` do would hide the one a grant can genuinely produce for
another reason, and a caller needs to see that field and that message.

**Release note.** "A `grant/3` or `grant_with_status/3` whose reference belongs
to another tenant now returns `{:error, :duplicate_reference}` instead of a raw
changeset, matching `hold/4` and `debit/4`. Every other changeset error is
unchanged."

### `history/2`: the default kinds and the cursor

**Before**: `@default_history_kinds` was `[:grant, :settle, :debit, :expire]`,
and a reversal appeared because it was a `:debit`. `:before` was the only paging
option.

**After**, measured on a wallet with two grants, a debit and a reversal:

```elixir
history/2 default kinds present : [:reverse, :debit, :grant, :grant]
cursor/1                        : 156081
history/2 with :before and :cursor together :
  {:raised, ArgumentError,
   "history/2 takes :before or :cursor, not both. :before filters on
    `inserted_at`, which is a wall-clock stamp and orders nothing; :cursor pages
    on the ledger's ordering key. Combining them would look like paging while
    filtering."}
```

**The cursor is the ordering key, not a `{DateTime, id}` tuple**, and that is a
deliberate departure from this unit's own build document. The document was
written before 06a moved `history/2`'s `order_by` from `inserted_at` to `seq`. A
`{inserted_at, id}` keyset over a `seq`-ordered query pages by a different column
from the one that sorted it, which is the defect L8 describes rather than the fix
for it. The cursor is documented as opaque: `Credits.cursor/1` produces it, and
nothing else should read into it.

**Release note.** "`AuroraMeter.Credits.history/2` takes `:cursor`, produced by
`AuroraMeter.Credits.cursor/1`, which pages on the ledger's ordering key and
cannot skip or repeat an entry. `:before` is kept, is a filter on `inserted_at`,
and may skip a row that shares a microsecond with another; giving both raises.
`:reverse` joined the default kinds, which is what keeps the default view
unchanged in content."

### `Series`: `:reverse` is not a spend kind

**Before**: `:kinds` rejected `:hold`, `:release` and `:grant`. A reversal was a
`:debit`, so `kinds: [:debit]` included its kind and the `IS DISTINCT FROM
'reversal'` arm kept it out of `spent` anyway.

**After**, measured:

```elixir
{:raised, ArgumentError,
 ":kinds cannot include [:reverse]: a reversal is money handed back, so it is
  reported against grants, and counting one as spend scores it twice with
  opposite signs"}
```

The two existing refusals are untouched, and the message follows `:grant`'s
style. **The output of `spend_history/2` and `spend_total/2` is unchanged**, as
measured above.

### `set_low_balance_threshold/2`: the crossing is recomputed

**Before**: it wrote the column and nothing else. There was no crossing to
recompute.

**After**: under the same row lock it clears a standing crossing when the new
threshold is at or below the wallet's spendable figure, or when the threshold is
cleared. It never raises an alert by itself. Measured in
`i11-low-balance.md`'s matrix, rows "threshold lowered" and "threshold cleared".

**Release note.** "Lowering or clearing a tenant's low-balance threshold clears a
standing crossing, so the next genuine fall below the new line alerts. Setting a
threshold never raises an alert by itself."

### The PubSub and telemetry payloads

Additive in every case, and the existing keys are untouched. The one ordering
change is `[:aurora_meter, :credits, :low_balance]`, and it moved twice in this
unit. It is emitted **after** the handler, because it reports how the handler
ended (`:ok`, `:none`, `:raised`, `:exit` or `:timeout`); and since finding X269
the handler runs in a watcher the caller does not wait for, so the event also
arrives **after the ledger call has returned**.

A consumer that only reads measurements sees no difference. One that read the
event back synchronously after a write does, and so does one that assumed two
crossings in quick succession emit in order: they may not, which is why each
event carries its own `crossing_id`.

**The PubSub broadcast did not move.** It is still sent synchronously by the
writer, before the watcher starts, so a consumer that wants an exact count of
crossings counts those rather than the telemetry.

**Release note.** "The low-balance handler runs in a watcher process that the
ledger call does not wait for, so it can no longer fail, block or delay a write.
`[:aurora_meter, :credits, :low_balance]` therefore arrives shortly after the
call returns rather than before it. The PubSub message is unchanged and is still
sent synchronously."


### `Money.assert_range!/1`

**Before**, the two tests named "fixed in 06c" at the starting SHA recorded a
`DBConnection.EncodeError` from Postgrex's encoder.

**After**, measured:

```elixir
Money.max_micro/0     : 9000000000000000
grant/3 above the limit:
  {:raised, ArgumentError,
   "amount 9000000000000001 is outside the range AuroraMeter.Credits can hold:
    at most 9000000000000000 micro-dollars (9,000,000,000 USD) either side of
    zero"}
```

Called by `grant/3`, `grant_with_status/3`, `hold/4`, `debit/4`, `reverse/4`,
`settle/3` and `set_low_balance_threshold/2`, before any I/O. That "before any
I/O" is proved rather than asserted: `test I10 the range guard refuses before any
database work (L17)` arms 01b's fault repo to raise on **every** statement, and
the out-of-range call still comes back as an `ArgumentError`. Its control, in the
same test, is an in-range grant that does hit the fault, so the wrapper is
demonstrably on the call path.

**Release note.** "Amounts beyond 9e15 micro-dollars (nine billion USD) are
refused at the facade with an `ArgumentError` naming the limit, before any
database work. The limit is three orders of magnitude below the `bigint` ceiling
because `balance_after` and the conservation aggregate are sums of amounts."

## The new read API, and its refusals

Not a compatibility row (nothing existed), but the refusals are part of the
contract and are measured here.

```elixir
Lots.for_source(lots, %{payment_intent_id: "pi_…"})  # => ["compat_lots_…:pay"]

Lots.for_source(lots, %{promotion: "welcome"}) =>
  {:raised, ArgumentError,
   "for_source/2 supports [:payment_intent_id, :recurrence_key] in this release,
    got: :promotion. A `source` key the matcher does not understand would match
    every lot, and a refund against every lot is not a near miss."}
```

## What is deliberately not changed

| Considered | Decision | Why |
|---|---|---|
| `summary/1`'s `runway_days` derived from `spendable` | **not changed** | It is a published figure with a published meaning. Changing what it divides would move every dashboard's number with nothing in the compatibility table saying so. Recorded as **X270**; the function's own documentation says what it divides and how to compute the stricter form. |
| Clamping `spendable` at zero for display | **not changed** | It is the figure `sufficient?/2` compares against. Clamping it would make the reported number and the ledger's refusal disagree, and the refusal is what is being reported. |
| Mapping every `grant/3` changeset error to `:duplicate_reference` | **not changed** | It would hide `validate_expiry/1`'s error, which is the one a caller can act on. |
| Removing `:before` from `history/2` | **not changed** | It is a filter, it is documented as one, and "what happened before lunchtime" is a real question. |
| `reverse/4` taking the lot path | **out of scope**, finding X250 | 06e owns it, and 06b's cutover gate refuses a cutover until it exists. Defining `Credits.reverse_lot/4` here would open that gate. |
