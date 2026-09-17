# 09d: the sample's Pro profile

Build unit 09d, V1 task 09.07. What the opt-in profile is, what it resolves,
what it adds to the application, and the proof that the core profile is
unaffected by its absence.

> **Standing rule.** No credentials, no customer identities, no unsanitised
> logs. Synthetic tenant ids only. Nothing here is invented: a command that was
> not run is named as not run.

Rule 4 applies. Nothing in this file ticks a checkbox and nothing is committed.

Repository `product-workspaces/aurora_meter`, branch `aurorameter-v1`, Pro at
`0.3.0`. Run on 2026-09-17, Elixir 1.20.1 / OTP 29, Postgres 16.13 in the
package container on port 5490.

---

## 0. The shape of the opt in

One environment variable, `AURORA_SAMPLE_PRO=1`, decides four things, and they
all have to agree or the build is incoherent:

| | core profile | Pro profile |
|---|---|---|
| dependency list | `deps()` | `deps() ++ pro_deps()` |
| lockfile | `mix.lock` | `mix.pro.lock` |
| build directory | `_build/core` | `_build/pro` |
| migration paths | `priv/repo/migrations` | that, then `priv/repo/pro_migrations` |

`test/pro_absent_test.exs` asserts the flag and the build agree
(`AuroraMeterExampleAi.Pro.available?/0 == System.get_env("AURORA_SAMPLE_PRO") == "1"`),
so a stale build cannot pretend to be a profile it is not.

### Step 1 of the build document: is `:lockfile` supported?

Yes, and the probe discriminates rather than confirming.
`tmp/v1/09d/step1-lockfile-probe.sh` builds one throwaway project twice,
differing in one line:

| Leg | project option | `mix.alt.lock` | `mix.lock` |
|---|---|---|---|
| A | `lockfile: "mix.alt.lock"` | **written** | absent |
| B | none | absent | **written** |

`Mix 1.20.1 (compiled with Erlang/OTP 29)`. A probe that ran only leg A could
not tell "the option works" from "Mix wrote a lock somewhere and I happened to
look in the right place".

### The two lockfiles, measured against the real project

`tmp/v1/09d/step2-two-lockfiles.sh`, both legs against the sample itself, both
files fingerprinted before and after:

```
== before ==
mix.lock     c90e4cc23d61d999
mix.pro.lock ABSENT

LEG A: core profile (AURORA_SAMPLE_PRO unset)
  rc=0  mix.lock c90e4cc23d61d999 -> c90e4cc23d61d999   mix.pro.lock ABSENT -> ABSENT
  aurora_meter_pro in the core profile's dependency tree: 0 occurrences

LEG B: Pro profile (AURORA_SAMPLE_PRO=1)
  rc=0  mix.lock c90e4cc23d61d999 -> c90e4cc23d61d999   mix.pro.lock ABSENT -> f673928e8316bab0

VERDICT: the mechanism holds
```

`mix deps.get` in either profile leaves the other profile's lockfile
byte-identical, which is the property the two-lockfile mechanism exists for.

`mix.lock` holds 54 entries and `mix.pro.lock` 65. What the eleven extra ones
are, read from the two files:

```
certifi, h2, hackney, mimerl, oban, parse_trans, quic, ssl_verify_fun,
stripity_stripe, uri_query, webtransport
```

`aurora_meter_pro` itself appears in **neither** lockfile, and that is not an
omission. In this repository it resolves as a **path** dependency to the
sibling checkout, exactly as Aurora Meter Pro's own `core_dep/0` resolves core,
and a path dependency is never locked: there is no version, no checksum and no
repository to pin. A customer's copy of the sample has no sibling, takes the
Hex branch (`{:aurora_meter_pro, "~> 0.3", organization: "phxtemplates"}`) and
locks it like any other package. `test/secret_scan_test.exs` asserts on the two
packages Pro brings with it rather than on a Hex shape this tree cannot
produce.

### What was NOT exercised here, and who owns it

**Resolution from the private Hex organisation.** `mix hex.organization list`
on this host is empty: the `phxtemplates` organisation is not authorised here,
and authorising it would mean writing a key into `~/.hex/hex.config` with the
only Hex key on this machine, which is a publishing key rather than the
least-privilege read key the build document specifies. So the Hex branch of
`pro_dep/0` is documented, is the branch a customer takes, and **has not been
run**. G09 bullet 2's clean-room mechanics are `09e`'s, and this is the
precondition it inherits.

### A third thing two resolutions need, which the build document does not mention

**Two build directories.** Two lockfiles are necessary and are not sufficient.
With one shared `_build`, switching profiles leaves the other profile's
compiled artefacts in place: `deps/oban` is fetched for the Pro profile, the
shared `_build/test/lib/aurora_meter` is then compiled while `Oban` is
resolvable, and a core-profile run fails **type checking inside a dependency it
does not depend on**:

```
warning: Oban.Worker.backoff/1 is undefined (module Oban.Worker is not available)
  (aurora_meter 0.5.0) .../deps/oban/lib/oban/worker.ex:466: AuroraMeter.Oban.Retention.backoff/1
== Type checking failed with errors ==
==> aurora_meter
could not compile dependency :aurora_meter
```

Observed, not reasoned about: the core suite went from 264 passing to "could
not compile dependency" the first time it ran after a Pro-profile run.
`build_path: if(pro?(), do: "_build/pro", else: "_build/core")` fixes it.
`deps/` is still shared deliberately: it holds fetched source, and a package
present but undeclared is not on the code path.

---

## 1. Configuration, by name

`config/pro.exs` is imported from `config/runtime.exs` when
`AURORA_SAMPLE_PRO=1` **and** `config_env() != :test`. Every value comes from
the environment and no default is a credential.

The variable names it reads, listed from the file itself:

```
AURORA_STRIPE_ACCOUNT_ID    AURORA_STRIPE_METER_EVENT
AURORA_STRIPE_CREDITS_PRODUCT   AURORA_STRIPE_METER_ID
AURORA_STRIPE_PRICE_STUDIO  AURORA_STRIPE_PRICE_TOKENS
STRIPE_API_VERSION          STRIPE_PUBLISHABLE_KEY
STRIPE_SECRET_KEY           STRIPE_WEBHOOK_SECRET
```

**No value of any of them appears in this file, in the repository, or in any
evidence file.**

Two of those names are not in the build document's table, and both are
required by Aurora Meter Pro rather than chosen here:

- `AURORA_STRIPE_ACCOUNT_ID`. `AuroraMeter.Pro.validate!/0` refuses to boot
  without `stripe_account_id` once `stripe_meters` is non-empty, because the
  account is part of every outbox item's identity and an invented one produces
  an identity that can never match a real one.
- `AURORA_STRIPE_METER_EVENT`. `stripe_meters` takes the meter's **event
  name** (what a meter event is sent under) and `stripe_meter_ids` takes the
  meter's **id** (what a summary is read by). They are different values and Pro
  needs both; the build document's table has only the id.

### The refusals, observed

A boot with the flag set and no key, at the real command:

```
** (RuntimeError) STRIPE_SECRET_KEY is not set, and the Pro profile needs it.

It is the Stripe secret key the sample's Pro profile bills with.

Copy examples/aurora_meter_example_ai/.env.example to .env, fill in your
own TEST-MODE values, and source it:

    set -a; . ./.env; set +a

Or run the core profile instead, which needs none of this:

    unset AURORA_SAMPLE_PRO
```

The prefix refusals have the same shape and print the prefix that was wanted
and **no part of what was supplied**:

```
STRIPE_SECRET_KEY does not begin sk_test_.

The Pro profile of this sample is TEST MODE ONLY. It refuses on the prefix
rather than trusting a comment or a habit, because Stripe's key prefixes
are structural and a mistake here moves real money.

Nothing of the value you supplied is printed here, deliberately. And
nothing has been sent to Stripe: this refusal happens while configuration
is being read, before the application starts.
```

`config/pro_test.exs` is the separate answer for `MIX_ENV=test`: the same
wiring with Aurora Meter Pro's own fakes, so the suite needs no credential and
can run in CI. The two files exist because a development or production boot
that silently fell back to a fake would be an application that looks like it is
billing and is not.

### `import_config/1` is not available in `runtime.exs`

The build document's shape (`import_config "pro.exs"`) is refused by Elixir:

```
** (RuntimeError) import_config/1 is not enabled for this configuration file.
Some configuration files do not allow importing other files as they are often
copied to external systems
```

and the refusal arrives at the first Mix task that starts the application, not
at compile time. `Config.Reader.read!/2` plus two loops applying `config/3` is
the supported way, and `config/runtime.exs` carries the explanation.

---

## 2. What the Pro profile adds to the application

| Surface | Module | What it demonstrates |
|---|---|---|
| `/billing` | `AuroraMeterExampleAiWeb.Pro.BillingLive` | the subscription, the credit account, auto-recharge, the portal link, and two buttons that create real test-mode Stripe objects |
| the webhook | `AuroraMeterExampleAiWeb.Pro.WebhookMount` | `AuroraMeter.Pro.Webhook`, mounted in the **endpoint**, above `Plug.Parsers` |
| the outbox | `AuroraMeterExampleAi.Pro.Outbox` | this application's own staged row **and** Pro's, in the one transaction |
| supervision | `AuroraMeterExampleAi.Pro.Children` | Oban and `AuroraMeter.Pro`, or an empty list |
| billing data | `AuroraMeterExampleAi.Pro.Billing` | every figure through a documented Pro function |

### The webhook is not a router route, and that is the interesting part

Pro's own documentation shows `forward "/webhooks/stripe",
AuroraMeter.Pro.Webhook` and says "mount it where the raw request body is still
available (before `Plug.Parsers`, or with a cached raw body)". Both halves are
true and only the second is actionable: a Phoenix router is **always** after
the endpoint's parsers, so the `forward` cannot be the mount point.

Mounted behind the parsers, `Plug.Conn.read_body/2` answers `{:ok, "", conn}`,
the HMAC is computed over an empty string, and **every** event fails
verification with a 400. The failure is silent, total, and its symptom appears
at the other end of the system as customers who paid and were never credited.

`test/pro/webhook_test.exs` mounts it the wrong way round and asserts the 400,
after first asserting that the parser really did consume the body, so a future
Plug that stopped consuming it would fail the mechanism assertion rather than
turning the test into a green test of nothing.

### The outbox is a composite, and the first attempt at it was wrong

The obvious configuration is one line:

```elixir
config :aurora_meter, events_outbox: AuroraMeter.Pro.Outbox
```

It works, and it quietly removes this application's own record of what it
metered. `AuroraMeter.record/4` calls **one** outbox, so pointing it at Pro's
stops staging `sample_outbox_items`, and five things built on that row stop
working at once:

- `Generations.recover/4`, the orphan path;
- `AuroraMeterExampleAi.HoldPolicy`, which decides an open hold from it;
- `mix sample.repair`;
- four figures on `/ops`;
- five of the eight recipes in `docs/failures.md`.

**Thirty-one tests went red the moment the flag was set**, which is how this
was found. `AuroraMeterExampleAi.Pro.Outbox` is three lines and calls both, in
the one transaction, so the commit guarantee is unchanged. The alternative is
to rewrite those five call sites against Pro's tables, which is the dependency
`architecture-map.md` rule 1 exists to prevent.

---

## 3. I20: the core profile is provably unaffected

### The instrument, and why it is not a grep

The first version of `test/pro_absent_test.exs` grepped `lib/` for the string
`AuroraMeter.Pro` and failed on `lib/aurora_meter_example_ai/failures.ex`,
which names `AuroraMeter.Pro.Recovery` **inside a sentence a recipe prints to a
reader in the core profile**. That sentence cannot raise, cannot be called, and
is the honest answer to "what would I do about this uncertain item".

So the instrument was wrong rather than the code. What I20 is about is a call
site, and the compiler already knows every one: each `.beam` carries an import
table of every remote function the module references. A string literal is not
in it and a call is.

### The measurement

| Assertion | core profile | Pro profile |
|---|---|---|
| modules in the application referencing `AuroraMeter.Pro*` | **0** | only the boundary and the two guarded trees |
| `Code.ensure_loaded?(AuroraMeter.Pro)` | `false` | `true` |
| `:aurora_meter_pro` in the declared dependency list | absent | present |
| routes matching `billing\|checkout\|webhook\|top-?up\|stripe` | **none** | `/billing` |
| `GET /billing` | **404** | 200 |
| `POST /webhooks/stripe`, unsigned | **404** | 400 |
| the top-up affordance on `/generate` | **absent from the markup** | a link to `/billing` |

The last row is not "disabled" and not "greyed": `SampleComponents` defines the
component twice behind a compile-time `if`, so the core profile compiles an
empty component. A disabled control labelled "Top up" is a payment surface that
does not work, which is the one thing a billing sample must never ship.

### Both suites

```
core profile:  mix test --seed 0   ->  266 passed (4 doctests, 262 tests), 2 files excluded (:pro)
Pro profile:   mix test --seed 0   ->  280 passed (4 doctests, 276 tests)
```

The 15-test difference is `test/pro/`. In the core profile those two files are
**not compiled at all** (the whole module is behind the guard) and the exclusion
prints a banner naming the files and how to run them, on stderr, because a
silently skipped required suite reports as a pass.

Both suites were also run at `--seed 1234`: 266 and 280, unchanged.

---

## 4. Things Aurora Meter Pro made hard, filed as findings

Four, all reported against their owning units rather than patched from the
sample.

1. **`mix aurora_meter_pro.gen.migration` cannot run in any host.** It does not
   call `Mix.Ecto.ensure_repo/2`, so the host's modules are never loaded and it
   raises `function AuroraMeterExampleAi.Repo.config/0 is undefined (module
   AuroraMeterExampleAi.Repo is not available)`. Core's equivalent generator
   does call it. Isolated by
   `tmp/v1/09d/probe-pro-gen-migration.sh`: three legs, one host, one command
   shape, and only Pro fails to resolve the repo.

2. **Pro's recommended crontab and an events-source feature refuse to boot
   together.** `AuroraMeter.Pro.cron_entries()` includes `UsageReporter`, which
   reports a metered feature from the buffered counter. A feature configured
   `feature_sources: %{tokens: :events}` is exported through the outbox
   instead; running both stages one `aurora_meter_usage_reports` row, and the
   next node to start raises `AuroraMeter.Pro.CutoverRequiredError`. Found by
   the real-provider proof run, on its third attempt.

3. **`Credits.pending_holds/1` and `reconcile_holds/1` use "amount" for two
   different things.** The first returns raw transactions whose `amount` column
   is `0` on a hold row (a hold moves `held_delta`); the second maps
   `held_delta` into the callback's `hold.amount`. A host printing
   `txn.amount` for an open hold prints zero for every hold there is.

4. **The `Account` object carries no `livemode` field**, and neither did the
   `Refund` this run created. The harness prints `livemode=%s` for every
   object, so an absent field reads exactly like a false one. The `sample`
   profile now distinguishes three cases and records the absent ones.

---

## 5. Commands

```bash
# the lockfile probe
bash tmp/v1/09d/step1-lockfile-probe.sh

# the two-lockfile mechanism against the real project
bash tmp/v1/mixlane.sh hold core bash tmp/v1/09d/step2-two-lockfiles.sh

# the core profile
bash tmp/v1/mixlane.sh hold core bash tmp/v1/09d/sample.sh mix test --seed 0

# the Pro profile
AURORA_SAMPLE_PRO=1 bash tmp/v1/mixlane.sh hold core \
  bash tmp/v1/09d/sample.sh mix test --seed 0

# the guard and payment-surface controls, nine of them
bash tmp/v1/mixlane.sh hold core bash tmp/v1/09d/controls-guards.sh
```

Logs: `tmp/v1/09d/logs/`.
