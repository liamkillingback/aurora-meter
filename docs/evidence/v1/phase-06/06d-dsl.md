# 06d: the `recurring_credits/2` DSL surface

Build unit 06d, V1 task 06.05. Raw output: `logs/06d-evidence.txt`, section
"06d-dsl". Every message below was produced by compiling a real plans module,
not transcribed from the source.

## The declaration

```elixir
plan :pro do
  price 4_900
  metered :tokens, included: 1_000_000, unit_price: 1

  recurring_credits :monthly_allowance,
    amount: 5_000_000,        # micro-dollars, required, a positive integer
    category: :promotional,   # the default
    rollover: 1_000_000,      # micro-dollars carried into one following period
    expires: :period_end      # the default
end
```

`recurring_credits/2` is a new macro on `AuroraMeter.Plans`, exported through
the package's `.formatter.exs` so a host that has `import_deps: [:aurora_meter]`
keeps writing it without parentheses. It is **not** a feature kind:
`t:AuroraMeter.Plan.feature_config/0` and every consumer of it are untouched,
which is what `architecture-map.md` 7.5 requires.

## The rendered struct

```
AuroraMeter.Plans.get(:allowance).recurring_credits
  [%{name: :monthly, category: :promotional, amount: 5000000,
     expires: :period_end, rollover: 1000000}]

AuroraMeter.Plans.get(:allowance_flat).recurring_credits
  [%{name: :monthly, category: :promotional, amount: 5000000,
     expires: :period_end, rollover: 0}]

AuroraMeter.Plans.get(:pro).recurring_credits
  []
```

A list, in declaration order, empty unless the plan declares one. That empty
list is the whole of "recurring grants default to disabled":
`Recurrences.run/1` skips a tenant whose plan has one with
`reason: :no_recurring_credits` before it opens anything.

## Every compile-time refusal, as the compiler prints it

```
* duplicate name:
    plan :x declares duplicate recurring_credits name(s): [:monthly]

* float amount:
    plan :x: recurring_credits :monthly :amount must be a positive integer of
    micro-dollars, got: 5000000.0

* zero amount:
    plan :x: recurring_credits :monthly :amount must be a positive integer of
    micro-dollars, got: 0

* no amount:
    plan :x: recurring_credits :monthly needs an :amount

* rollover with expires: :never:
    plan :x: recurring_credits :monthly declares rollover: 1 with expires:
    :never. A rollover is what the previous period's lot did not spend before it
    expired, so it is defined only when the lot expires at the period boundary.
    With any other expiry the carried value would still be spendable on the old
    lot as well as granted again on the new one.

* rollover with {:seconds, n}:
    (the same message, with expires: {:seconds, 60})

* paid with an expiry:
    plan :x: recurring_credits :monthly declares category: :paid with expires:
    :period_end. Only promotional grants expire: AuroraMeter.Schema.CreditTransaction
    refuses an `expires_at` on any other category, and v1-release.md 10.1 says
    paid top-ups do not expire unless their own contract says so. Use expires:
    :never.

* unknown option:
    plan :x: recurring_credits :monthly has unknown option(s) [:roll_over]; the
    options are [:amount, :category, :rollover, :expires]

* unknown category:
    plan :x: recurring_credits :monthly :category must be one of [:promotional,
    :paid, :adjustment], got: :bonus

* unknown expiry:
    plan :x: recurring_credits :monthly :expires must be :period_end, :never or
    {:seconds, n}, got: :tomorrow

* negative rollover:
    plan :x: recurring_credits :monthly :rollover must be a non-negative integer
    of micro-dollars, got: -1

* a name with a colon:
    plan :x: recurring_credits :"monthly:extra" must be lower snake case,
    matching ~r/^[a-z][a-z0-9_]*$/: the name becomes part of the recurrence key
    and a key is read by splitting on ":"

* a capitalised name:
    (the same message, for :Monthly)

* a plan id with a colon:
    plan :"pro:legacy" declares recurring_credits, so its id becomes part of a
    recurrence key ("recurring:<tenant>:<name>:<plan>:<version>:<period>") and
    must be lower snake case, matching ~r/^[a-z][a-z0-9_]*$/. A key is read by
    splitting on ":", so an id carrying one cannot be read back.
```

And the one combination that compiles and warns:

```
* a never-expiring promotional allowance:
    warning: plan :x: recurring_credits :monthly is a promotional allowance that
    never expires, so every period's grant stays spendable for ever and the
    tenant accumulates them. That is legal and is almost always a mistake; use
    expires: :period_end, or category: :paid if the money is really theirs to
    keep.
```

## Three of these are not in the build document, and why

**`rollover > 0` with `{:seconds, n}`** is refused as well as with `:never`. The
build document only forbids the `:never` pairing, but the arithmetic is the
same: a rollover is defined as what the previous period's lot did not spend
*before it expired*, so a lot whose expiry can fall anywhere except the period
boundary could be carried into the new period and still be spendable in the old
one. Narrowing it at compile time removes the class rather than documenting it.

**An expiry on a non-promotional allowance** is refused because
`AuroraMeter.Schema.CreditTransaction.validate_expiry/1` refuses an
`expires_at` on any category but `:promotional`. Without this rule, `category:
:paid` with the default `expires: :period_end` would compile and then fail at
run time with a changeset error, once, per tenant, per period. It is also
`v1-release.md` 10.1's rule ("paid top-ups do not expire unless their existing
explicit contract says so") enforced rather than written down.

**The name and plan id format** is X272's rule applied where the string is
invented. Both halves become part of the recurrence key, which is read back by
splitting on `:` (`AuroraMeter.Credits.Recurrences` and the `split_part` in its
`last_recurrence` query), so neither may contain one. The test asserts the plan
id as well as the name, because the plan id is the half a host is more likely to
spell oddly and the half no test would otherwise have covered.
