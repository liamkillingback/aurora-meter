# Aurora Meter example: a metered AI application

A complete, runnable Phoenix application that meters usage, enforces a plan's
quotas, holds and settles prepaid credit, records a durable fact for every unit
of work, and stages that fact for export. It is the reference application for
[Aurora Meter](https://hexdocs.pm/aurora_meter), it is MIT, and you can read all
of it.

## What this is and what it is not

**There is no AI in it.** The workload is a deterministic simulation in
`lib/aurora_meter_example_ai/tokens.ex`: it computes a token count and assembles
a paragraph out of the words of your own prompt. No account, no key, no HTTP
client, no network call of any kind. The output is built from your prompt
precisely so that it can never be mistaken for a model's answer. Point the same
call at a real provider and nothing else in the application changes.

**There is no payment in it.** No checkout, no card form, no pricing page that
leads to one, and no screen that says a payment succeeded. The `:studio` plan
has a price on it and that price is a label: a plan is assigned by the seed or
from the developer tools page, and the UI says so wherever it shows a plan name.
Credit arrives from the seed or from a clearly labelled synthetic grant. A
sample that showed a convincing fake payment would be teaching the one thing a
billing example must never teach.

**It runs on one node.** Buffered quotas are strict on one node and convergent
across nodes, and nothing stronger. The figures you see here are exact because
there is one node; the `/generate` page says so at the bottom.

**It is not the library's only example.** `demo/` in the package root is a
historical minimal wiring example pinned to a July 2026 migration, kept for
reference and excluded from the published archive. This directory is the
current one.

## Running it

You need Elixir and a Postgres server. Nothing else, and no credential at all.

```bash
cd examples/aurora_meter_example_ai
mix setup                 # deps, database, migrations, assets
mix sample.seed           # two organisations, four users, four credit lots
PORT=4021 mix phx.server
```

The sample's database configuration defaults to `localhost:5490`, which is the
Postgres container the Aurora Meter package's own suite uses, so there is no
second server to start. Set `DB_HOST` and `DB_PORT` for your own.

`mix sample.seed` prints the accounts it made. They all end `@example.com` and
they all share one password, which it also prints. Log in at `/users/log-in`.

`mix ecto.reset` starts again from nothing. This database is never a customer's.

### What `mix deps.get` and `mix setup` fetch

Worth knowing before you run this somewhere without general internet access.
`mix deps.get` fetches Hex packages and **two git dependencies from GitHub**
(`heroicons` and `daisyui`), both of which `mix phx.new` generates and neither
of which Aurora Meter needs. `mix assets.setup` downloads the `tailwind` and
`esbuild` binaries. None of that is needed to run `mix test`, and none of it
happens while the application is running.

## What to look at, in order

| Route | What it shows |
|---|---|
| `/generate` | the whole teaching path: a quota that reserves, a credit hold for an estimate, the work, a durable record, a settlement for the real cost |
| `/history` | one request's three identities: the local row, the durable event and the credit hold |
| `/ops` | the conservation identity, the credit lots in spend order, the outbox, and the two reporting sources side by side |
| `/dev/tools` | a labelled synthetic grant, a local plan switch, and the organisation's API key |
| `POST /api/generate` | `AuroraMeter.Plug.EnsureEntitled` in a pipeline, and `with_quota/4` in the action |

Things to try with your own hands:

- **Double-click the Generate button.** The second click is refused before a
  token is generated, because the request id in the form is replaced only after
  a success.
- **Start a prompt with `fail:`.** The simulated workload raises, the
  reservation and the hold both come back, and the row says `rejected`.
- **Log in as an `acme` user.** That organisation is on `:free` with no credit
  at all: it is the one that gets refused.
- **Open `/generate` in two tabs** as the same user and generate in one. The
  other tab's meter, balance and chart move without a reload.

## The shape of the integration

The whole of it is `AuroraMeterExampleAi.Generations.create/3`. In order:

1. `AuroraMeter.with_quota(org, :images, 1, fn -> ... end)` for an image
   request. A text request skips this and is gated by credit alone, so both
   styles are visible in one application.
2. `AuroraMeter.Credits.with_credits(org, estimate, "gen:" <> request_id, fn -> ... end)`.
3. the work.
4. `AuroraMeter.record(org, :tokens, total, id: "gen:" <> request_id, ...)`.
5. the callback returns `{:ok, result, actual}`, so the hold is settled for the
   real cost rather than the estimate.
6. this application's own `generations` row.

Four things in that list are worth stopping on.

**A refusal inside `with_quota/4` has to be raised.** `with_quota/4` commits its
reservation on any normal return, including an error tuple from your own code.
It catches raises, throws and exits, releases the reservation and re-raises, and
that is its only channel for "the work did not happen". Returning
`{:error, :insufficient_credits}` from inside it bills a quota unit for work you
did not do, and nothing will tell you. `Generations.Refused` is the exception
that carries a business refusal out.

**One string, three systems.** The `request_id` is the `generations` primary
key, the credit hold reference and the Aurora Meter event id. A double-clicked
button is refused three times over and the first refusal costs nothing.

**The event and the local row are in separate transactions.** That is the
simpler of the two shapes and it is what most hosts start with. A process that
dies between them leaves an event with no local row; `/ops` shows it as an
orphan and `mix sample.repair` rebuilds it. The other shape is to wrap both in
one `Repo.transaction/2`: the event comes back with `durability: :conditional`,
nothing is published until you call `AuroraMeter.Events.after_commit/1` after
your commit, and your rollback removes the event, its total and its export
intent together.

**Recovery reads this application's own outbox row, not the library's tables.**
`AuroraMeter.record/4` staged that row inside the transaction that wrote the
event, so a host that implements the `AuroraMeter.Events.Outbox` seam gets a
durable local record of everything it recorded, for free. Retrying `record/4`
with the same id to ask what happened does **not** work after a crash: the
payload identity includes `occurred_at` to the microsecond, so a retry stamping
a fresh instant comes back as a conflict. "Retry with the same id" means retry
with the same id and the same payload.

## Organisation isolation

Every organisation in this application comes out of the session, through
`AuroraMeterExampleAi.Accounts.Scope`. `AuroraMeterExampleAi.Tenancy.org!/1` has
one clause and it matches a scope carrying an organisation: hand it request
parameters, an id or `nil` and it raises rather than resolving anything. Every
organisation-scoped query goes through `AuroraMeterExampleAi.Orgs.scope_query/2`,
which takes the scope and adds the filter itself, so there is no call shape that
lets a caller forget it. No route carries an organisation.

`test/aurora_meter_example_ai_web/live/isolation_test.exs` proves it three ways:
a scan of the parsed source for a parameter read, a behavioural check that
another organisation's generation is as unreachable as one that does not exist,
and a probe over the run asserting that no other organisation's tenant key was
resolved at all while one organisation's session was being served. Each has a
control that plants the defect, because a negative whose instrument cannot fire
is not a test.

## The outbox and the exporter

`AuroraMeterExampleAi.SampleOutbox` implements `AuroraMeter.Events.Outbox`.
`AuroraMeter.record/4` calls it **inside** the transaction that writes the event,
so an export intent is staged in the same commit as the fact. It inserts rows
and does nothing else: a network call there would hold a financial transaction
open across a network boundary.

`SampleOutbox.Drainer` claims a bounded batch with `FOR UPDATE SKIP LOCKED` and
hands it to `AuroraMeter.Exporter.Journal`, the deterministic reference
exporter, which records what it was given and answers what it was told to. Every
one of the five outcomes is reachable from a test without a mocked HTTP layer.
`:uncertain` is never retried automatically, by design, and `/ops` shows it with
its age so a person can decide.

This is a deliberately simplified version of Aurora Meter Pro's outbox. The real
one adds lease tokens and fencing: `SKIP LOCKED` makes two drainers claim
disjoint rows, but it does not survive a worker that claims a batch and then
hangs, and the reclaim here is a timeout, which is a guess.

## Two things a reader should know about this release

**The credit lot engine is off on a new wallet.** `mix sample.seed` turns it on
with `AuroraMeter.Credits.Ledger.enable_lots!/1`, which is **not public API**,
and the comment above that call explains why there is currently no other way. A
wallet left on the legacy engine has no lots, no allocation trail, `debt` and
`expired` permanently zero, and the plan DSL's `recurring_credits` grants
nothing. This is reported against the library rather than hidden.

**`AuroraMeter.Components.usage_meter/1` needs a changing assign to update
live.** It reads `AuroraMeter.quota/2` inside itself, so its output depends on
data that is not in its assigns, and LiveView will not re-render a function
component whose assigns did not change. `GenerateLive` passes
`data-usage={@usage_version}` for that reason, and
`test/.../usage_meter_change_tracking_test.exs` shows both halves.

## The Pro profile

Everything above is the **core profile**: MIT, Elixir and Postgres, no
credential, no provider, no payment. It is the profile this sample is written
for and it is what you get if you never read this section.

The **Pro profile** adds Aurora Meter Pro and a real Stripe **test-mode**
integration: a `/billing` page, credit top-ups, auto-recharge, the Stripe
webhook, and export through Pro's outbox onto Stripe's Billing Meters. It is
opt in, it is absent by default, and turning it on takes four commands.

```bash
mix hex.organization auth phxtemplates --key "$AURORA_HEX_READ_KEY"   # once, by you
cp .env.example .env && $EDITOR .env                                   # your own TEST-MODE values
set -a; . ./.env; set +a
export AURORA_SAMPLE_PRO=1
mix deps.get
mix ecto.migrate
mix ecto.migrate --migrations-path priv/repo/pro_migrations
PORT=4021 mix phx.server
```

`.env.example` lists every variable by name with an empty value, and says what
each one is for. **No key of any kind is in this repository**, and
`test/secret_scan_test.exs` fails the suite if one appears.

### What the flag actually changes

| | core profile | Pro profile |
|---|---|---|
| dependencies | `mix.lock` | `mix.pro.lock`, which adds `aurora_meter_pro`, `oban` and `stripity_stripe` |
| build directory | `_build/core` | `_build/pro` |
| migrations | `priv/repo/migrations` | that, then `priv/repo/pro_migrations` |
| supervision tree | as above | plus Oban and `AuroraMeter.Pro` |
| routes | as above | plus `/billing` |
| endpoint | as above | plus the Stripe webhook, **above `Plug.Parsers`** |
| outbox | `SampleOutbox` | `AuroraMeterExampleAi.Pro.Outbox`, which calls both |
| `/generate` | no top-up affordance at all | a link to `/billing` |

Two of those rows are worth a sentence each.

**The webhook is mounted in the endpoint, not in the router.** Stripe signs the
raw request body and `Plug.Parsers` consumes it, so a router `forward` makes
every event fail verification with a 400 and the symptom appears at the far end
of the system as customers who paid and were never credited. There is a test
that mounts it the wrong way round and asserts the 400.

**The outbox is a composite, not a swap.** The obvious configuration is
`events_outbox: AuroraMeter.Pro.Outbox`, and it works, and it quietly takes
away this application's own record of what it metered: the orphan recovery
path, the hold policy, `mix sample.repair`, four figures on `/ops` and five of
the eight failure recipes all read `sample_outbox_items`. Thirty-one tests went
red the moment the flag was set. `AuroraMeterExampleAi.Pro.Outbox` is three
lines and calls both, in the one transaction.

### Without a licence

Nothing about the core profile changes, and that is asserted rather than
claimed: `test/pro_absent_test.exs` reads every compiled module's import table
and fails if anything in this application references `AuroraMeter.Pro` outside
the two guarded trees. In the core profile the answer is **nothing at all**.

The Pro-only tests are tagged `:pro` and excluded when the package is absent,
and the exclusion prints a loud banner naming the files and how to run them,
because a silently skipped suite reports as a pass.

## The failure catalogue

`docs/failures.md` is eight ways this application can fail, what each leaves in
the database and in the ledger, and what to do about it. Every one of them
runs:

```bash
mix sample.failure                      # list them
mix sample.failure untrappable_death    # run one
mix sample.failure all                  # the seven that need no provider
mix sample.failure --check              # re-assert the last run's JSON
```

`test/sample_failure_test.exs` asserts the end state each recipe documents, and
cross-checks the document's headings against the implemented recipes in both
directions, so the catalogue cannot drift from the software without the suite
going red.

## Testing

```bash
mix test
```

The suite needs Postgres and nothing else: no network, no credential, no
provider. Every test is `async: false` and resets Aurora Meter's ETS tables
first, because the counters are global to the node and a suite that shared them
across concurrent tests would be measuring whichever test ran last. That is a
real cost and it is the honest trade for a sample of this size.

`AuroraMeter.Test` is the library's own host-testing helper: `reset!/0`,
`flush!/0`, `broadcast!/0`, `fund!/3` and a fixed clock. The sample uses it
rather than reaching into ETS.

## Licence

MIT, the same as Aurora Meter. See `LICENSE`.

Generated with `mix phx.new` from `phx_new 1.8.13`, then `mix phx.gen.auth
Accounts User users --live`, then
`mix aurora_meter.install --repo AuroraMeterExampleAi.Repo --feature-policy deny
--events-source tokens:events`. The Aurora Meter configuration, the supervision
child and the migration in this tree are that installer's output.
