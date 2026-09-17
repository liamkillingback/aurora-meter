# Troubleshooting

Symptom first. Each section says what you are seeing, what usually causes it,
the query or telemetry event that confirms which cause it is, and the fix.

For what the library promises rather than what it is doing, read
[Guarantees](guarantees.md). For operating it day to day, read
[Operations](operations.md).

## Usage looks low right after a deploy

**Expected, for a few seconds.** Counters live in ETS and are flushed on the
`:flush_interval` (default 5 s) and once more on a clean shutdown. A restart
seeds them back from the persisted totals on first touch, so a counter nothing
has read yet reads zero until something does.

**Confirm:** `AuroraMeter.usage(tenant, feature)` twice, a flush interval apart.

**If it does not recover,** read the next section: this is the benign version of
the same symptom.

## Usage looks low and never recovers

Three causes, in the order they are worth checking.

**1. `AuroraMeter` is not in the supervision tree.** Nothing is flushing.
`AuroraMeter.Store` creates the ETS tables at boot, and a host that never
started the supervisor raises on the first call rather than counting silently,
so this shows up as an error rather than a low number. Add `AuroraMeter` to your
children, after your repo and your PubSub.

**2. The repo is unreachable and the backlog is growing.** The flusher keeps the
dirty set in memory and retries; nothing is lost until the VM dies, and then
everything in the backlog is. Confirm with the `[:aurora_meter, :flush, :error]`
telemetry event, and with the oldest-unflushed-age gauge
([Telemetry](telemetry.md)). The number to watch is the age, not the error rate.

**3. The feature's reporting source is `:events` and nothing is calling
`record/4`.** An events-source feature never reaches the flush path by design;
its total comes from `aurora_meter_event_totals`. Check
`config :aurora_meter, :feature_sources`.

```sql
-- what has actually been persisted for one tenant this period
select feature, value from aurora_meter_counters
where tenant_key = $1 and period_start = $2;
```

## A hard limit admitted more than the cap

**On one node this cannot happen** and a reproduction is a bug worth reporting.
Under any concurrency, `with_quota/4` against a cap of `n` admits exactly `n`.

**On more than one node it is expected and bounded.** Enforcement is against the
local view; nodes exchange deltas every `:broadcast_interval` and re-base on the
persisted total every `:flush_interval`. The overshoot is what the other nodes
admitted between announcements.

**Confirm:** compare `AuroraMeter.usage/2` on each node. If they differ by more
than a broadcast interval's worth of traffic, gossip is not arriving: check that
every node shares one distributed `Phoenix.PubSub` adapter, not a local one.
[Clustering](clustering.md) has the arithmetic and the tuning.

## `{:error, :not_entitled}` for a feature that is on the plan

In order of likelihood:

1. **The feature is not declared on that tenant's plan.** The undeclared-feature
   policy decides what happens then: `:warn` in 0.5.x (allowed, logged once per
   feature per node) and `:deny` from 1.0. Run `mix aurora_meter.features` to
   list every feature your code names and where it is declared.
2. **The subscription is not in an entitled state.** A plan is granted only
   while the subscription's status is `active`, `trialing` or `past_due`.
   Anything else falls back to `:default_plan`.
3. **The feature name is a binary.** Features are atoms. A binary raises
   `ArgumentError` at the facade rather than creating a second counter, which is
   the behaviour a 0.4.0 host may remember.

```elixir
AuroraMeter.plan(tenant)          # which plan is actually in force
AuroraMeter.quota(tenant, feature) # kind: :undeclared says it is cause 1
```

## A credit balance does not match the sum of its transactions

Run the conservation query before anything else. Conservation is per wallet:

```sql
select b.tenant_key, b.balance,
       (select coalesce(sum(t.amount), 0)
          from aurora_meter_credit_transactions t
         where t.tenant_key = b.tenant_key) as sum_of_transactions
  from aurora_meter_credit_balances b
 where b.tenant_key = $1;
```

If those two agree, the balance is right and what you are looking at is one of
the four figures meaning something different from what you assumed:
`available` is `balance - held`, and `spendable` is zero whenever `debt` is
outstanding. [Credits](credits.md) has all four in one table.

If they disagree, that is a defect and worth a report with the tenant's
transaction history attached.

## Holds that never close

A hold is taken before the row that remembers it exists, and those two writes are
often in different databases, so a process killed in between leaves credit
reserved with nothing pointing at it.

```elixir
AuroraMeter.Credits.pending_holds(older_than: DateTime.add(DateTime.utc_now(), -3600))
```

Only the host can tell such a hold from one whose work is still running, which
is why closing them needs a `:credits_hold_reconciler` and why nothing is closed
until you configure one. `AuroraMeter.Credits.reconcile_holds/1` asks it about
every hold older than `:older_than` and applies the answer.
[Credits](credits.md) under "Holds nothing will ever close" has the shape of the
callback.

## An event is rejected as a conflict

`{:error, {:conflict, existing}}` means the same `(tenant, event_id)` has
already been used with a **different payload**. The comparison is a hash of the
canonical payload: the feature, the quantity, `occurred_at` to the microsecond,
the kind, the original event reference, and the dimensions and metadata with
their keys sorted.

The usual cause is a retry that rebuilt `occurred_at` rather than replaying the
one it sent. A retry has to send the same payload, not an equivalent one; if you
cannot persist the payload before the call, generate a fresh id instead.

## `record/4` times out or returns `{:error, {:unavailable, :overloaded}}`

`:overloaded` is admission control doing its job: `record_max_concurrency`
(default 64) callers may hold an open record transaction at once, and the
sixty-fifth is refused rather than queued behind a connection checkout. Raising
it without raising the pool only moves the queue.

`{:error, {:unavailable, :timeout}}` is `record_timeout` (default 15 s). The
outcome is genuinely unknown: retry with the **same** id, and the duplicate
check will tell you whether the first attempt landed.

## Migrations hang

Almost always a lock wait behind a long-running transaction, not the migration
itself.

```sql
select pid, state, wait_event_type, wait_event, query
  from pg_stat_activity
 where datname = current_database() and state <> 'idle';
```

The concurrent unique index on `aurora_meter_events` must run in its own
migration with `@disable_ddl_transaction true` and
`@disable_migration_lock true`; running it inside a transaction is the other way
this hangs. [Upgrading to 1.0](upgrading-to-1.0.md) has the ordering and the
`lock_timeout` guidance.

## `function gen_random_uuid() does not exist`

PostgreSQL older than 13. `gen_random_uuid()` became a built-in in 13, and no
migration in this package creates the `pgcrypto` extension for you, because
creating an extension needs privileges a host may not want to grant. Upgrade
Postgres, or create the extension yourself before migrating. The floor and the
tested versions are in [the support policy](support-policy.md) section 5.

## The LiveDashboard page refuses to mount

By design, and the message names the option. The page needs an authorisation
check, because it shows tenant-level usage and there is no rule this library
could invent that would be right for your application. Pass `:authorized_by`
with a `{module, function, argument}`, an `{:assign, key}`, or `:host_route` if
your dashboard route is already behind your own authentication.
[Operations](operations.md) has each form.

## Compiler warnings about `AuroraMeter.Oban`

A host with no `oban` dependency sees them because the Oban integration is
compiled behind `Code.ensure_loaded?(Oban)`. Add `{:oban, "~> 2.17"}` if you want
the workers, or ignore them: nothing in the free core needs Oban, and the
scheduled operations are all callable directly.

## Still stuck

Open an issue at
<https://github.com/liamkillingback/aurora-meter/issues> with the package
version, the Elixir and Erlang/OTP versions, and the smallest configuration that
reproduces it. A suspected vulnerability goes to
[SECURITY.md](../SECURITY.md)'s private route instead.
