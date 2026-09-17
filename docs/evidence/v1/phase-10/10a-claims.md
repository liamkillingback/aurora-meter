# 10a: every claim this unit changed, and every A-item accounted for

Two halves. Section 1 is what changed and why, grouped by what found it.
Section 2 accounts for all thirty-two A-items in the build document, most of
which earlier units closed; this unit verified each rather than assuming.

Removed claims are **described, not quoted**, so that a dash or a banned phrase
does not re-enter the tree through its own record. That rule is now enforced:
this file is inside the sweep's scope through `docs/evidence/`'s exclusion only,
and the guards would catch a quotation that reached a shipped page.

## 1. What changed

### 1.1 Found by A06, the documented signature against the real `@spec`

Twelve rows in core and twenty-two in Pro printed a return type the `@spec` does
not declare. Every one is a documentation defect; no code was changed.

**Core, `docs/api.md`.** Each row's printed return was missing an error tag the
function can genuinely return, so a reader writing a `case` would not have
written the clause:

| Entry | What the table printed | What the spec declares |
|---|---|---|
| `AuroraMeter.Events.get/2` | one error atom | that atom plus the four-tag `error()` union |
| `AuroraMeter.Events.Replay.run/1` | a bare `{:error, term()}` | plus `projection_mismatch` and `already_running` |
| `AuroraMeter.Events.Replay.prune/1` | a bare `{:error, term()}` | plus `active`, `not_found`, `already_running` |
| `AuroraMeter.Storage.record_events/2` | a bare `{:error, term()}` | plus the `conflict` triple |
| `AuroraMeter.Storage.record_correction/2` | a bare `{:error, term()}` | plus `conflict`, `invalid`, `not_found` |
| `AuroraMeter.Storage.put_plan_version/1` | a bare `{:error, term()}` | plus `unsupported` |
| `AuroraMeter.Storage.list_plan_versions/1` | **a list only** | a list **or** an error tuple |
| `AuroraMeter.Storage.assign_legacy_plan_versions/1` | a bare `{:error, term()}` | plus `unsupported` |
| `AuroraMeter.Subscriptions.schedule_transition/3` | an unnamed tag variable | the four real tags |
| `AuroraMeter.Subscriptions.cancel_transition/3` | an unnamed tag variable | the four real tags |
| `AuroraMeter.Subscriptions.preview_transition/3` | one of the four tags | all four |
| `AuroraMeter.Subscriptions.confirm_transition/3` | an unnamed tag variable | the four real tags |

`list_plan_versions/1` is the dangerous one of the twelve: the table said the
function returns a list, and a caller piping it into `Enum.map/2` would raise on
the error clause.

**Pro, `docs/api.md`.** Twenty-two rows, regenerated from the `@spec` itself with
the documented argument list kept. Three of them are the same class as
`list_plan_versions/1`, where the documented return is a shape the function
cannot produce:

| Entry | What the table printed | What it really returns |
|---|---|---|
| `AuroraMeter.Pro.Credits.close_account/1` | an ok/error tuple pair | a bare `:ok` |
| `AuroraMeter.Pro.Credits.AutoTopUpSweeper.sweep/0` | `:ok` | a count |
| `AuroraMeter.Pro.Credits.checkout_params/3` | a bare map | an ok/error tuple |
| `AuroraMeter.Pro.Stripe.checkout_params/2` | a bare map | an ok/error tuple |
| `AuroraMeter.Pro.Stripe.portal_params/2` | a bare map | an ok/error tuple |

The other seventeen printed `term()` where a named type or an error tag exists:
`checkout/3`, `portal_url/2`, `update_auto_top_up/3`, `disable_auto_top_up/2`,
`re_enable_auto_top_up/1`, `on_low_balance/1`, `record_failure/3`,
`handle_event/1` (twice, in `Credits` and `Webhook`), `with_lock/2`,
`AutoTopUpWorker.attempt/2`, and the six `AuroraMeter.Pro.Recovery` operations,
which now print `refusal()` and `summary()` rather than `term()` and `map()`.

### 1.2 Found by A07, every worked example is run

Nineteen modules in core and eleven in Pro carried an `iex>` example that no
`doctest` declaration named. Declaring all thirty found **three** examples that
did not survive being executed:

| Where | What was wrong |
|---|---|
| `AuroraMeter.Credits.LotMigration.checkpoint_name/1` | the example's continuation lines were in the wrong order, so it **could never have compiled**. It had looked like a proof since it was written |
| `AuroraMeter.Config.metrics_interval/0` | the example asserted the default, which is not what the function returns: it returns whatever the host configured, and this repository's own test configuration sets something else. Replaced with a statement of the default in prose |
| `AuroraMeter.Pro.Reconcile.list_items/1` | the example asserted an empty database, which is not a property of the function. Replaced with one that asserts the shape |

### 1.3 Found by G06, the claims sweep reading `lib/` doc strings (X98)

| Where | What it claimed | What was done |
|---|---|---|
| `AuroraMeter.Pro.Alerts` moduledoc | that an alert fires exactly once per crossing | **corrected.** A dedup row is claimed before the handler runs and dropped when the handler fails, so it is at least once with a dedup row, and a node that dies between the claim and the call leaves that one alert undelivered. The new wording says all three |
| `AuroraMeter.Operations.pause/1` | that pausing never loses a position | reworded to say the paused operation keeps its position, which is the same fact without the phrase |
| `AuroraMeter.Schema.CreditRecurrence` moduledoc | a uniqueness property phrased as exactly once | reworded to "one row", which is what the unique index gives |
| `AuroraMeter.Exporter.outcomes/2` | that `:uncertain` is the only non-terminal state that cannot lose money | **kept, allow-listed with a written reason.** It is a statement about the outbox state machine and it withholds a promise rather than making one |
| `AuroraMeter.Credits.pending_holds/1` | that paging returns every hold exactly once | **kept, allow-listed with a written reason.** It is a statement about a keyset cursor over rows, proved by `AuroraMeter.CreditsHistoryTest` |

X98 recorded two occurrences in Pro. The AST sweep finds one, because the second
is in a `#` comment, and a comment is not copy. That difference is the guard
working, not the guard missing something.

### 1.4 Found by G07, a guarantee that under-claims (X233)

`docs/guarantees.md` G10 (durable recorded events are transactional) read "not
yet proven (phase 03)" while `docs/correctness.md` names twenty tests for I06
alone. Its Proven by cell now names one of them. No other row under-claims.

### 1.5 The dash sweep (X88)

299 occurrences on the shipped and rendered surface, now 0. The arithmetic and
what was deliberately left are in `10a-dash-scan.txt` and section 3 of
`10a-report.md`. Five judgements worth recording individually:

- **Table cells whose whole content was a dash** were replaced with the word the
  dash stood in for, and the word differs by column: "no" under a Required
  heading, "n/a" under a Default heading, "none" under a Money heading. A rule
  that guessed one word would have written the wrong one in two of the four
  tables it met, so the tool refuses to act on a column it was not told about.
- **Five dashes inside fenced code samples** were swept although X88 exempts
  code samples, because they were prose sentences in comments on the two README
  pages and on three guide pages a customer reads. The guard does **not** cover
  them.
- **Every `#` comment was left**, in `lib/` and everywhere else.
- **`plan.md`, the released changelog entries, `docs/adr/`, `docs/evidence/` and
  `docs/launch/` were left**, which is the build document's own scope rule.
- **Two heading anchors changed** (`## quota` and `## with_quota` in
  `docs/entitlements.md`, and four `###` headings in
  `docs/examples/concepts.md`). Every inbound link in both repositories was
  checked first; none pointed at them.

## 2. The build document's A1 to A32, each accounted for

The build document was written on 2026-09-14 against core 0.4.0. Most of these
were closed by units between then and now. This unit verified each against the
tree rather than assuming, and re-fixed none that was already right.

| Ref | Disposition |
|---|---|
| A1 | **Closed earlier.** `docs/metering.md` no longer bounds buffered loss by an interval; `docs/guarantees.md` G6 states it as everything not in an acknowledged batch, and `DocsClaimsTest` G01 now fails the phrase anywhere, including in `lib/` |
| A2 | **Closed earlier.** No "exactly once" or five-second bound survives in `docs/examples/`; verified by search and by G01 |
| A3 | **Closed by 08c.** The README quotes 3,418,407 increments/s with the toolchain, the date and a link to `docs/evidence/v1/phase-08/08c-results.md`; `AuroraMeter.Bench.ClaimsTest` fails if a superseded figure reappears anywhere |
| A4 | **Kept, as the row says.** Cluster overshoot is bounded by what other nodes admitted in one broadcast interval, in the README, `docs/clustering.md` and G4, and is now also in `docs/mental-model.md`'s list of things a reader would assume wrongly |
| A5 | **Closed by 03c.** Reporting source is explicit per feature; `docs/mental-model.md` restates which source answers which question and links to I08 |
| A6 | **Closed earlier and restated.** `check/2` is advisory, and `docs/mental-model.md` now puts it beside `with_quota/4` so a reader cannot take one for the other |
| A7 | **Closed by 02b.** The undeclared-feature policy and both defaults are in `docs/configuration.md`, and `docs/troubleshooting.md` names it as the first cause of an unexpected `:not_entitled` |
| A8 | **Closed by 05d.** `AuroraMeter.Retention` exists and `docs/retention.md` documents it |
| A9 | **Closed by 05b.** `Credits.reconcile_holds/1` exists; `docs/credits.md` and `docs/troubleshooting.md` both say nothing closes a hold until a reconciler is configured |
| A10 | **Closed by 06a and 06b.** The promotional-figure limitation is gone; `docs/credits.md` has "Which wallets are on lots" and `docs/mental-model.md` carries the honest consequence that one installation can hold two kinds of wallet |
| A11 | **Closed earlier.** Credits still require the Ecto storage, stated in `docs/credits.md` and now in `docs/architecture.md` section 1 |
| A12 | **Closed differently and better.** The single home for runtime floors is `docs/support-policy.md` section 5 plus the README's supported-versions table, both already written and both CI-backed. This unit did **not** create `docs/supported-versions.md`, because a second page for the same fact is what the build document's own "one fact, one home" rule forbids |
| A13 | **Closed earlier.** `docs/clustering.md` no longer claims "0.3 adds no migration" |
| A14 | **Closed differently.** `docs/upgrading-to-1.0.md` and `docs/upgrading-to-lots.md` hold the upgrade path; no `docs/upgrading.md` was created for the same reason as A12 |
| A15 | **Closed by the guarantee table.** `docs/guarantees.md` has fifteen rows with conditions, what voids them and a resolving proof, and `DocsClaimsTest` G05 and G07 now guard both directions |
| A16 | **Closed here.** `SECURITY.md` in both packages, `CONTRIBUTING.md` in core. Issue templates deliberately not added (section 8 of `10a-report.md`) |
| A17 | **Closed here.** `docs/launch/gtm.md` carries a historical note, is not in the extras list, and is excluded from the dash sweep as history |
| A18 | **Superseded, and the replacement is stronger.** `docs/RELEASE.md` still names a concrete tag, and `AuroraMeter.ReleaseMetadataTest` asserts that tag equals `mix.exs`'s version. A placeholder would have removed a guarded fact and replaced it with an unguarded one |
| A19 | **Closed by 04e.** Pro's `docs/recovery.md` is written around the guarded operations |
| A20 | **Closed by 04b.** The uncertainty horizon is a configuration key, stated once |
| A21 | **Closed earlier (P11).** `docs/getting-started.md` says plainly that `invoice.paid` used to be on the required list and is not any more, and why |
| A22 | **Closed earlier (P13).** `docs/operations.md` shows `Rollup.history(org, "month")` |
| A23 | **Closed earlier (P13).** `docs/operations.md` documents `%{data:, has_more:, next_cursor:}` and says which shape it is not |
| A24 | **Closed here.** `docs/architecture.md` in Pro states the audit writer's boundary: outside the request transaction, after the response, a warning on failure |
| A25 | **Closed by 08b, documented here.** Both `SECURITY.md` files state the mounting contract, and Pro's says why its page does not accept `:host_route` |
| A26 | **Closed earlier (P25).** No `stripe:` prefix and no "no refund mirroring" survives in Pro's docs |
| A27 | **Closed by 02d, documented here.** Pro's `SECURITY.md` says rotation works from 0.3.1 and what to do on 0.3.0 |
| A28 | **Closed by 04a and 04b.** One account of the reporting window |
| A29 | **Closed by 05e.** One schedule map |
| A30 | **Verified, not edited.** `AuroraMeter.Pro.AdrFormatTest` passes and ADR 0005's status line is correct |
| A31 | **Closed here.** The dash sweep, section 1.5 |
| A32 | **Partly here.** Cross-links to hexdocs slugs resolve for the pages that exist, and the new Pro pages link to core pages that are now in core's extras list (`architecture.html`, `security.html`, `troubleshooting.html`, `guarantees.html`). Whether a slug resolves **on the registry** is `11c`'s archive audit, not something a local suite can answer |

## 3. What was handed to 10b

`10b` rewrites the storefront copy against the same facts. The four claims most
likely to be wrong on a marketing page, and the page that states each correctly:

1. **Delivery is at least once with provider-side idempotency**, never exactly
   once. `docs/guarantees.md` G11, Pro `docs/correctness.md` I15.
2. **Buffered loss is everything not in an acknowledged flush batch**, not one
   interval. `docs/guarantees.md` G6.
3. **A hard cap can overshoot in a cluster**, bounded by what other nodes
   admitted between announcements. `docs/guarantees.md` G4.
4. **Throughput is 3,418,407 increments/s**, on the machine, toolchain and load
   shape named in `docs/evidence/v1/phase-08/08c-results.md`, and no other
   figure may be published. `AuroraMeter.Bench.ClaimsTest` enforces it.

And one that a storefront page would not think to state, which
`docs/mental-model.md` now does: **credit lots are not retroactive**, so an
installation that upgrades holds two kinds of wallet until it runs the
migration.
