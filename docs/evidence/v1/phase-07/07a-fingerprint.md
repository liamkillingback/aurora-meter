# 07a: the plan fingerprint

Build unit 07a, V1 task 07.01. Core `aurora_meter`, 2026-09-16.

## What it is

`AuroraMeter.Plans.Snapshot.fingerprint/1` is `:crypto.hash(:sha256, canonical/1)`
where `canonical/1` renders a plan's **commercial content** explicitly, field by
field, as a binary. `fingerprint_version` is **1** and is stored beside the
digest in every `aurora_meter_plan_versions.definition`.

## The canonical form as implemented

Fields are joined with the ASCII record separator `0x1e` (`RS` below) and the
parts of a field with the unit separator `0x1f` (`US`).

```
v1
RS  id            US <Atom.to_string(id)>
RS  version       US <version>
RS  price         US i<price>
RS  features
RS  f US <name> US <rendered config>     ... one per feature, sorted by name
RS  recurring_credits
RS  c US <name> US amount US i<amount> US category US <category>
       US rollover US i<rollover> US expires US <rendered expiry>
                                          ... one per credit, sorted by name
```

Feature configs render as:

| Config | Rendering |
|---|---|
| `{:limit, n, :hard}` | `limit US i<n> US hard` |
| `{:metered, included, unit_price}` | `metered US i<included> US <number>` |
| `{:counter}` | `counter` |
| `{:feature, true \| false}` | `feature US bool US true \| false` |
| `{:feature, n}` when integer | `feature US int US i<n>` |

Numbers carry a type tag: an integer is `i<digits>`, a float is
`f<:erlang.float_to_binary(f, [:short])>`. Expiries render as `period_end`,
`never` or `seconds US i<n>`.

## A worked example

```elixir
%AuroraMeter.Plan{
  id: :pro,
  version: "1",
  price: 2_000,
  features: %{ai_generations: {:limit, 1_000, :hard}, api_access: {:feature, true}},
  recurring_credits: [
    %{name: :monthly, amount: 5_000_000, category: :promotional,
      rollover: 1_000_000, expires: :period_end}
  ]
}
```

renders, with the separators shown as `<RS>` and `<US>`, as:

```
v1<RS>id<US>pro<RS>version<US>1<RS>price<US>i2000<RS>features<RS>f<US>ai_generations<US>limit<US>i1000<US>hard<RS>f<US>api_access<US>feature<US>bool<US>true<RS>recurring_credits<RS>c<US>monthly<US>amount<US>i5000000<US>category<US>promotional<US>rollover<US>i1000000<US>expires<US>period_end
```

That exact string is asserted, byte for byte, by
`AuroraMeter.PlansSnapshotTest` / `test I17 the canonical form renders every
commercial field with visible separators`.

## The stability argument

**Not `:erlang.term_to_binary/1`.** Three of the four properties L17.3 asks for
are properties it does not have: the external term format is versioned and has
changed maps' encoding across OTP releases; it is not independent of map
iteration order for maps above 32 entries; and it encodes the whole struct,
including `fingerprint` itself. Nothing in the form above depends on a runtime
representation.

**Declaration order is invisible.** Features are sorted by
`Atom.to_string(name)` and recurring credits by `Atom.to_string(credit.name)`
before rendering.

**Map iteration order is invisible.** Above 32 keys an Erlang map is a hash map
whose iteration order follows the hashes, not the keys. The sort removes that
from the digest. Note the honest limit here: **within one BEAM this cannot be
demonstrated by a difference**, because a given key set iterates the same way
every time, so the test asserts the rendered order directly
(`test I17 the canonical form lists features in name order, whatever order the
map iterates in`) rather than comparing two digests. Finding X291 records why.

**The separators cannot be forged.** `AuroraMeter.Plans.__build__/5` raises at
compile time for a feature or recurring credit name whose `Atom.to_string/1`
contains either separator, and the version regex `\A[A-Za-z0-9][A-Za-z0-9._-]{0,31}\z`
excludes both. So `("ab", "c")` and `("a", "bc")` cannot render alike. The
negative control `h-no-separators` removes the record separator and two tests
fail.

**An integer and a float are different content.** `{:metered, 10, 2}` and
`{:metered, 10, 2.0}` fingerprint differently, deliberately:
`AuroraMeter.Config` already warns that a float unit price may lose precision,
and a host that switches one for the other has changed what it charges.

## What is deliberately NOT in it

`effective_at`. The build document's draft of this form had it; finding **X290**
records the change and the three reasons:

1. It is not commercial content. It decides which version a **new** subscription
   gets; a tenant already pinned to a version is not moved by it, so changing it
   cannot reprice anybody, which is what I17 is about.
2. It would make a conflict out of something that is not one. Bringing version 2
   forward from October to September changes nothing about what version 2 sells.
3. **It would make `v1-release.md` 07.03 unreachable.** Deleting a retired
   version's block is the case the registry exists for, and when the deleted
   version was the base version the one left behind must drop its own
   `effective_at` or the plans module no longer compiles (every plan id needs a
   base version). Fingerprinting the instant would turn every retirement into a
   refused boot for a plan whose price nobody had touched, which is precisely
   acceptance criterion 9.

The instant is still stored, in `definition["effective_at"]` and in the
`effective_at` column, so `Plans.versions/1` can report it for a version that is
no longer in code.

## `fingerprint_version`

Stored so that a future change to this rendering is detectable as a rendering
change rather than read as a content conflict. `AuroraMeter.Plans.register!/0`
compares it: a stored row whose `fingerprint_version` differs from the compiled
one is logged once per `(plan_id, version)` per node and left alone, never
reported as a conflict. Nothing has shipped at version 1 yet, so no
re-registration task exists or is needed.

## Tests

- `AuroraMeter.PlansSnapshotTest`: 15 tests over the pure functions, including
  the byte-for-byte canonical form, the sha256 identity, order independence in
  both directions, a table of 13 single-field changes each of which must change
  the digest and must differ from every other, the integer/float distinction,
  the boolean/integer distinction, the jsonb round trip, the dropped-atom path
  and the separator guard.
- `AuroraMeter.PlanVersionsPropertyTest`: three properties (determinism,
  injectivity on commercial content, encode/decode round trip), 100 runs each,
  run at seeds 0, 1, 7, 42 and 1337. Compared counts per seed: determinism 100,
  injectivity distinct=100 equal=0, round trip 100 at every seed.

## Negative controls

| Control | Break | Result |
|---|---|---|
| `h-no-separators` | fields joined with `""` | DISCRIMINATED: 2 tests |
| `i-unsorted-features` | feature sort removed | DISCRIMINATED: 1 test |
| `j-unsorted-credits` | credit sort removed | DISCRIMINATED: 1 test, 1 property |

Logs: `07a-logs/control-h-no-separators.log`,
`07a-logs/control-i-unsorted-features.log`,
`07a-logs/control-j-unsorted-credits.log`.
