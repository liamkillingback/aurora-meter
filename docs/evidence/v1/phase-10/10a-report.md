# 10a: trust pack and mental model, core

V1 tasks **10.01** (trust pack) and **10.02** (mental model). Findings closed or
advanced: **X88**, **X98**, **X229**, **X233**, **X237**, **X370**.

Repository: `aurora_meter`, branch `aurorameter-v1`, working tree dirty by
construction (programme rule 4: the author writes evidence and does not commit).
Baseline at the start of this unit: `1a3a98ec0a743d3183c0f38d6212c3e554e5c44e`.
Pro's baseline: `dce6ffc2e3a71da5bbb0974ac1ada8f1d7d0e5b1`.

Toolchain: Elixir 1.20.1, Erlang/OTP as resolved by the lane, PostgreSQL on
`DB_PORT=5490`. Every Mix invocation went through `tmp/v1/mixlane.sh`, and the
control harness held the lane across its whole patch-and-restore cycle
(`open-findings.md` X371).

## 1. What was done

| Deliverable | Where |
|---|---|
| The mental model (10.02) | `docs/mental-model.md` |
| Architecture map | `docs/architecture.md` |
| Troubleshooting, symptom first | `docs/troubleshooting.md` |
| Security disclosure, what is stored, what is sent, host responsibilities | `SECURITY.md` |
| Contributing | `CONTRIBUTING.md` |
| The dash guard (X88) | `test/aurora_meter/house_style_test.exs` plus two fixtures |
| Signature against `@spec` (X370, X229) | `test/aurora_meter/api_inventory_test.exs` A06 |
| Every example is run (X237) | `api_inventory_test.exs` A07 and `test/aurora_meter/doctests_test.exs` |
| The claims sweep reads `lib/` doc strings (X98) | `test/aurora_meter/docs_claims_test.exs` G06 |
| A guarantee may not under-claim (X233) | `docs_claims_test.exs` G07, and `docs/guarantees.md` G10 |
| The evidence-writer guard reads the AST | `test/aurora_meter/evidence_writes_test.exs` |

Pro's half is in `pro:docs/evidence/v1/phase-10/10a-report.md`.

## 2. Results

Both packages green, up from the 2179 and 1159 this unit was handed.

| | `mix check` | tests |
|---|---|---|
| core | pass | **2284** passed (158 doctests, 22 properties, 2104 tests), 8 excluded |
| Pro | pass | **1204** passed (96 doctests, 1108 tests) |

Logs: `10a-doc-test.log`, `10a-docs-build.log`, `10a-dash-scan.txt`, and the
same three in Pro.

## 3. The dash sweep (X88)

Counted, swept, counted again, both counts from the **same** detector, the
before column taken from a `git archive` of HEAD rather than from memory.

| | before | after | closed |
|---|---|---|---|
| Everything, both packages | 642 | 348 | 294 |
| **The shipped and rendered surface** (README, NOTICE, `docs/` minus history, `lib/` doc strings and rendered strings) | **299** | **0** | **299** |

X88's row said 475. It was 642 when this unit measured it, which is why the row
told the unit to count again: the difference is not drift in the sweep, it is
that the row counted `lib/` and `docs/` in two packages and this detector also
counts `plan.md`, the released `CHANGELOG.md` entries, `test/`, `examples/` and
the ADR and evidence trees, all of which are deliberately left.

**Left on purpose, with the reason:**

| What | How many | Why |
|---|---|---|
| `plan.md` (core) | 94 | finished history; the build document's scope says so explicitly |
| Released `CHANGELOG.md` entries | 86 | history. The **unreleased** section is swept and is now guarded |
| `docs/adr/`, `docs/evidence/`, `docs/launch/` | 73 | a decision as it was taken, what a run printed, a superseded draft |
| `#` comments in `lib/` | 51 | a comment is not copy, and a guard that fires on one is a guard people route around |
| `test/` | 36 | not copy. 8 of them are this unit's own fixtures, which must carry dashes to control anything |
| Code samples inside doc strings | 8 | a sample is not prose (X88) |

Five dashes that **were** inside fenced code samples were swept anyway, because
they were prose sentences in comments on the README pages a prospective customer
reads. They are recorded in `10a-claims.md` and the guard does **not** cover
them, so that is a claim maintained by hand rather than by a test. Said here
rather than left to be assumed.

## 4. The two detectors disagreed, and the AST one was right

Worth recording because it is the reason the evidence keeps three numbers rather
than two.

The Python detector classifies a line in an Elixir doc string as code when it is
indented four spaces or more, measured **against the file**. An Elixir heredoc is
dedented by the indentation of its closing delimiter, so a list item indented
four spaces in a `@doc` at module level is indented **two** in the string that
actually renders. The AST guard measured it correctly and reported
`lib/aurora_meter/credits.ex:1124`; the Python detector had classified the same
dash as a code sample and reported nothing.

One dash, but the shape matters: the before count was produced by the version
that was wrong. The detector was corrected to measure indentation against the
doc string's own base, and **both** columns in `10a-dash-scan.txt` were then
regenerated from the corrected version over both trees.

## 5. The guards, and what each would and would not catch

### H1, the dash guard (`AuroraMeter.HouseStyleTest`)

**Catches:** an em or en dash in `README.md`, `NOTICE.md`, the unreleased part of
`CHANGELOG.md`, any `*.md` under `docs/` except `adr/`, `evidence/` and
`launch/`, and, in every `lib/**/*.ex`, both the doc strings and every other
string literal. The last is where the dashes a customer actually sees live
(X271's `runway_text/1`, and the `aria-label` 09b found).

**Does not catch:** a dash in a `#` comment, a fenced sample, an indented sample
inside a doc string, an inline code span, a URL, a `>` quotation, anything under
`test/`, or a released changelog entry. Those are deliberate, and the fixtures
assert each of them stays silent.

**How it avoids the trap it was written for:** it reads the **AST**, so a comment
is invisible by construction rather than by a pattern that tries to skip one.
`AuroraMeter.EvidenceWritesTest` matched prose and was tripped by exactly that,
which happened again on this unit's first full run (section 7).

**Why it cannot pass by matching nothing:** two fixtures under
`test/support/style_fixtures/` carry one dash of each kind with each line named,
and the test asserts the scanner reports **exactly** the two prose lines and
none of the three code lines, plus that every named line really does carry a
dash. A scan-size floor and a "the scan selects what it is meant to select"
test sit beside them.

### A06, the documented signature against the real `@spec` (X370, X229)

**Catches:** a documented argument count that is not the entry's arity, and a
**match surface** in the printed return that the `@spec` does not have, in both
directions. The match surface is the atom members of the top-level union, the
leading atom of each top-level tuple, and the tag one level inside it. A named
type met at one of those positions is resolved, so `{:error, error()}` and the
union written out are the same thing.

**Does not catch:** an argument type that is abbreviated (`keyword()` against a
specific keyword list), a return abbreviated as `map()` where the spec names a
struct, or anything inside a list or a map. Those abbreviations are the
inventory working as intended, and a check that failed them would be noise
somebody switches off.

**What it found on first run:** 12 rows in core and 22 in Pro, every one a real
disagreement, none planted. **Six of the thirty-four were the worst class**, one
in core and five in Pro, where the documented return is a shape the function
cannot produce and a caller matching on it raises. All are in `10a-claims.md`.

### A07, every worked example is run (X237)

**Catches:** a module carrying an `iex>` example that no `doctest` declaration
anywhere names. Reads the test sources as AST, so `doctest Foo` in a moduledoc
does not count (X84).

**Does not catch:** an example that is wrong but is inside a fenced block rather
than an `iex>` prompt, and a `doctest Mod, except: [...]` that excludes the
example in question. The second is a hole and is named here rather than left.

**What it found:** 19 undoctested modules in core and 11 in Pro. Adding the
declarations found **two broken examples in core**, one of which could never
have compiled. Both fixed.

### G06, the claims sweep reads `lib/` doc strings (X98)

**Catches:** a bounded-loss, exactly-once or global-quota claim in a
`@moduledoc`, `@doc`, `@typedoc` or `@shortdoc`, which render on hexdocs exactly
as the guides do.

**Does not catch:** the same phrase in a `#` comment, which is deliberate and is
why Pro's count here is one rather than the two X98 recorded: the second is in a
comment.

**What it found:** four in core and one in Pro. Two were reworded, two are
allow-listed with a written reason, and Pro's one was a **real over-claim**:
`AuroraMeter.Pro.Alerts` said alerts fire "exactly once per
`{tenant, feature, period, threshold}`" while the mechanism is a dedup row
claimed before the handler runs and dropped when it fails. Corrected.

### G07, a guarantee may not under-claim (X233)

**Catches:** a `docs/guarantees.md` row that says "not yet proven (phase NN)"
while every invariant it names has at least one non-PLANNED test in
`docs/correctness.md`.

**Does not catch:** a row whose guarantee text is pessimistic in prose rather
than in its Proven by cell.

**What it found:** G10, exactly as X233 said. Closing it broke a sibling test
that required at least one row to say "not yet proven", which was a property of
the tree on the day it was written rather than an invariant. Replaced; see
section 7.

## 6. Controls: 16 of 16 discriminated

`tmp/v1/10a_controls.py`, run under a held lane, snapshot and digest-verified
restore, no `git checkout` anywhere (X326, X371). Each control plants one defect
and requires the run to fail **and** the message to carry a phrase only that
guard prints **plus** the site. A run with no `Result:` line is counted as a
failure of the control, not as a discrimination (X325, X350).

| | controls | discriminated |
|---|---|---|
| core | 10 | 10 |
| Pro | 6 | 6 |

Run twice, once when the guards were written and once against the final tree,
with the same answer both times.

## 7. Two guards that had to change because this unit's work was correct

Both are recorded as findings rather than fixed quietly.

**`AuroraMeter.EvidenceWritesTest` reported this unit's dash guard as an evidence
writer**, because it matched on the source **text** and the guard's moduledoc
names `docs/evidence` beside an unrelated `File.write!`. That is precisely what
the brief predicted. It now reads the AST and classifies by **destination**: a
call to `File.write`/`File.write!` in a module that does not confine its writes
to `System.tmp_dir!()`. That change found **two writers the old check could never
see** (`test/support/aurora_meter/test/connections.ex` and `ledger_commands.ex`,
both gated, both naming `docs/evidence` nowhere) and stopped flagging one test
whose own comment said it assembled a directory name from parts so the old check
would not see it.

**`DocsClaimsTest`'s "at least one row is honest about not being proven yet"**
required the defect X233 records. Replaced with a test that the form still
parses, that the pattern does not match free text, and that every row on today's
page resolves.

## 8. What was not done, and why

- **No storefront file changed.** `10b`, `10c` and `10d` own those, and nothing
  under `priv/docs/` was touched.
- **No `CHANGELOG.md` entry for a released version was edited**, and no file
  under `docs/adr/` or `docs/evidence/phase-*`.
- **`package.files` is unchanged.** The new trust-pack pages under `docs/` do
  **not** ship inside the Hex tarball; they render on hexdocs from the extras
  list. `T12` records that question and `11c` decides it.
- **`docs/supported-versions.md` and `docs/api-stability.md` were not created.**
  Both facts already have a home: `docs/support-policy.md` sections 1 to 5 and
  the README's supported-versions table. Creating a second page for the same
  fact is the thing this unit's own "one fact, one home" rule forbids, and the
  build document's rule outranks its file list.
- **`docs/upgrading.md` was not created** for the same reason:
  `docs/upgrading-to-1.0.md` and `docs/upgrading-to-lots.md` hold it.
- **`docs/retention.md` already existed** (`05d`) and was not rewritten.
- **`.github/ISSUE_TEMPLATE/` was not added.** It is repository configuration
  rather than package documentation, it ships in no tarball, and nothing in the
  suite can check it.

## 9. Files created and edited

Created: `docs/mental-model.md`, `docs/architecture.md`, `docs/troubleshooting.md`,
`SECURITY.md`, `CONTRIBUTING.md`, `test/aurora_meter/house_style_test.exs`,
`test/aurora_meter/doctests_test.exs`,
`test/support/style_fixtures/dashes.md`, `test/support/style_fixtures/dashes.exs`,
this directory.

Edited: `README.md`, `NOTICE.md` is unchanged, `AGENTS.md`, `CLAUDE.md`,
`CHANGELOG.md` is unchanged, `mix.exs` (extras and one group only),
`docs/api.md`, `docs/guarantees.md`, `docs/support-policy.md`,
`docs/configuration.md`, `docs/credits.md`, `docs/entitlements.md`,
`docs/metering.md`, `docs/plans.md`, `docs/RELEASE.md`, `docs/examples/*.md`,
and the doc strings of thirteen files under `lib/`, plus
`test/aurora_meter/api_inventory_test.exs`,
`test/aurora_meter/docs_claims_test.exs`,
`test/aurora_meter/evidence_writes_test.exs`.

**The working tree also holds build unit 09d's changes**, which are everything
under  plus  in the storefront.
Nothing in this unit touched either, and the two sets do not overlap. The list
above is this unit's alone.

No credential, customer identity or live-mode provider object appears in any
file in this directory.
