# 09c: the controls, and which of them discriminated

Every negative assertion in this unit has a control that plants the thing the
assertion is looking for. That rule comes from X325, X350 and X360, and from the
note in this unit's brief that four instruments in the previous wave returned a
wrong answer before a right one and **every one failed towards success**.

Sixteen controls. All sixteen discriminated. Four of them changed something, and
those four are the interesting rows.

## The inventory

| # | What it guards | The control | Discriminated |
|---|---|---|---|
| 1 | the suite run counter | plants a failing test, runs the counter, restores by digest (`09c-runcount-control.sh`) | **yes**, `Result: 222/223 passed -> FAILURE`, exit 1 |
| 2 | "no module reads an organisation from params" | the same AST scan over a planted module containing `Orgs.get_org!(params["org_id"])` | **yes** |
| 3 | the same scan, against false positives | the same scan over a module whose `@moduledoc` warns against `params["tenant"]` | **yes, and it changed the instrument.** See below |
| 4 | the same scan, floor | more than 15 files must be scanned | yes |
| 5 | "another organisation's generation is unreachable" | the same id **is** reachable from its own organisation's session | yes |
| 6 | the tenant-resolution probe | resolving the forbidden key deliberately puts it in the probe's list | yes |
| 7 | the same probe, floor | `keys != []` before the negative | yes |
| 8 | "tokens never appears in a flush batch" | `assert :images in features` **first**, in the same test | yes |
| 9 | "no control offers to take money" | a planted `<button>Checkout</button>`, and prose about payment that must not fire | **yes, and it changed the instrument.** See below |
| 10 | "no page collects card details" | a planted `<input name="card_number">` | yes |
| 11 | "no page claims a payment happened" | a planted "Payment successful", and a denial that must not fire | yes |
| 12 | `package.files` excludes the sample | the same filters over a list containing `examples`, `demo` and `test` | yes |
| 13 | the archive grep | the same `grep -E` over a listing that does contain both paths: returns 2 | yes |
| 14 | the profile greps (no Pro, no provider, no network) | the same `grep/1` asked for patterns that must be present (`with_quota`, `record`, `with_credits`) | yes |
| 15 | `enable_lots!` on a fresh wallet | the same call on a wallet with ledger rows, which must be refused | yes |
| 16 | the CI workflow parses | the parser must reject a deliberately broken document first | yes |

Two more that are controls in everything but name:

| | |
|---|---|
| the generated plans module probe | `Code.ensure_loaded?(Host.Plans.Host.Plans)` is `true` for the installer's file and `false` for the same file with the outer `defmodule` removed |
| the outbox configuration swap | "with the real outbox back, the same call succeeds", so a swap that silently failed to take effect cannot leave the previous test passing |

## The four that changed something

### Control 3: the isolation scan reported its own documentation

The first version read `lib/**/*.ex` line by line for
`params["org"|"tenant"|...]`. It reported one offender:

```
lib/aurora_meter_example_ai/tenancy.ex:31: dashboard that reads `params["tenant"]`
  looks exactly like a dashboard that
```

That line is inside `Tenancy`'s `@moduledoc`, explaining the defect the module
exists to prevent. A line scan cannot tell a warning about a defect from the
defect, and the obvious repair, excluding lines that start with `#`, would not
have caught it either, because it is inside a heredoc.

The scan now walks the **parsed AST** looking for `Access.get` with a forbidden
string key. Comments and documentation strings carry no AST nodes at all, so
they are invisible by construction rather than by a pattern that has to be
maintained. Both the positive control and a new negative control ("the scan does
not fire on prose about the defect") are in the suite.

**The transferable part**: a scan for a code pattern that runs over text will
eventually be weakened until it stops seeing anything, because the first false
positive it produces is always in a comment warning about the thing.

### Control 9: the payment scan failed on the honest half of the application

The build document's criterion is "rendering every route in the core profile
produces no occurrence of the words checkout, card, pay or a Stripe reference".
Written as a word list over the page text, it found five:

```
[{"/", "payment"}, {"/generate", "payment"}, {"/ops", "paid"},
 {"/dev/tools", "card"}, {"/dev/tools", "payment"}]
```

Every one is the sample saying there is no payment. `/` says "there is no
payment here". `/dev/tools` says "this sample takes no money, has no card form".
`/ops` prints `paid`, which is the name of a credit category. **You cannot say
there is no payment without the word.**

Worse, a substring scan over the raw HTML would have found `card` in the class
attribute of half the generated markup, because daisyUI's panel class is
literally `card`. That version would have fired on every page and been turned
off.

The criterion underneath the words is about **offers and claims**, so the test
is now four separate scans, each with its own control:

1. no interactive control's **label** offers to pay (`checkout`, `buy`,
   `purchase`, `upgrade`, `subscribe`, `pay now`, `add card`, `payment method`);
2. no `input`, `select`, `label` names or placeholders a card field;
3. no page **text** claims a payment happened;
4. no page names a provider or shows a key shape, anywhere in the document.

The first three read the parsed document and look at labels or text, never at
attributes. The fourth is a whole-document substring scan, which is right for
`stripe` and `sk_live` because those must not appear anywhere at all.

**The transferable part**: an acceptance criterion written as a word list is a
criterion that will be met by deleting the sentence that tells the truth.

### The seed lost what it did, and the browser showed it

`mix sample.seed` ran twelve generations and exited. `/generate` then showed
`images 0 / 200` for an organisation that had used three, while the token figure
was correct. The seed's VM had not flushed, and buffered usage is lost with the
VM.

This is not a control in the harness sense; it is the run being watched rather
than assumed. A seed that is only ever checked by `mix test` would never have
shown it, because the suite and the server are the same VM there. It is fixed by
one line and a comment in the seed, and it is the clearest demonstration in the
sample of why `:tokens` is an events-source feature and `:images` is not.

### The live meter was wrong in the browser and right in the first test

"A generation in one session moves the meter in a second session" was written
with two assertions: `refute after == before`, and then the meter's actual
value. **The first passed and the second failed.** The watcher's HTML really had
changed, because the credit summary had moved, and on a page with more than one
live figure that is enough to satisfy the loose assertion while the figure the
test is named after stands still.

Had the test been written with only the first assertion, which is the obvious
way to write it, it would have been green and the page would have been wrong in
the browser. The cause is `09c-library-findings.md` finding 4. The control for
that finding is
two minimal LiveViews differing in one attribute
(`test/support/meter_probe_live.ex`), both of which receive the broadcast and
re-render, and only one of which shows the new figure.

**The transferable part**: `refute after == before` is not an assertion about the
thing you care about. It is an assertion that **something** changed, and on a
page with more than one live figure that is nearly free.

## Instruments that were watched failing before they were trusted

| Instrument | Watched failing on |
|---|---|
| the run counter | a planted failing test |
| the isolation AST scan | a planted `params["org_id"]` read |
| the payment offer scan | a planted Checkout button |
| the card field scan | a planted `card_number` input |
| the payment claim scan | a planted "Payment successful" |
| the archive grep | a planted listing containing both forbidden paths |
| the `package.files` filters | a planted list containing all three forbidden entries |
| the yaml parser | a deliberately broken document |
| `enable_lots!`'s guard | a wallet with ledger rows |
| the profile greps | patterns that must be present |
