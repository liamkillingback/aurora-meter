# 02b: the boot checks, and the credit currency rule

Build unit 02b, core `aurora_meter`. Open finding L13 (the currency is stamped
once from configuration, and a later configuration change leaves a wallet set
with two currencies and no check).

## Where they run

`AuroraMeter.Config.validate!/0` runs in the starting process before any Aurora
Meter process exists, so it can only look at configuration. Anything that needs
the database belongs to `AuroraMeter.BootChecks`, which is the **last** child of
`AuroraMeter.Supervisor` and returns `:ignore`, so the checks run with the rest of
the tree up and leave no process behind.

```
| BootChecks is the last child and leaves no process behind | pass |
```

Raising inside it makes `Supervisor.start_link/1` fail and tear down the children
it already started. That is the right outcome for a misconfigured host: a
half-started tree metering against a wallet set it cannot reconcile is worse than
no tree at all.

## The only check in this unit

```sql
SELECT currency, count(*) FROM aurora_meter_credit_balances GROUP BY currency LIMIT 5
```

One read-only query, once per node, outside any transaction. `LIMIT 5` because
the message has to show the operator that there is a problem and roughly how big
it is, not enumerate a corrupted wallet set.

## The three outcomes, observed

`mix run tmp/v1/02b/boot_report.exs`, exit 0, log
`tmp/v1/02b/logs/15-boot-report.log`. It starts the real repo, writes real rows
under a `evidence_02b_` prefix, and removes them in an `after` block.

### 1. Every row carries the configured currency

Two rows at `"usd"`, `:credits_currency` at its default `"usd"`:

```
   AuroraMeter.Credits.assert_currency!() => :ok
```

Zero rows is the same answer: a host that has never granted credit boots.

### 2. A row in another currency

Two more rows at `"eur"`, configuration still `"usd"`:

```
   raised AuroraMeter.Credits.CurrencyMismatchError
   config :aurora_meter, credits_currency: "usd" does not match the currency already stored on aurora_meter_credit_balances ("eur" on 2 rows). Aurora Meter stamps the currency once, when a balance row is created, so a wallet set with two currencies has no meaningful total. Either restore the previous credits_currency, or migrate the rows deliberately before changing it. V1 supports USD only.
```

The message names the configured currency, every stored currency with its row
count, and the two ways out. Through the supervisor, the same condition is:

```
{:error, {:shutdown, {:failed_to_start_child, AuroraMeter.BootChecks,
  {:EXIT, {%AuroraMeter.Credits.CurrencyMismatchError{configured: "usd", stored: [{"eur", 2}]}, _stacktrace}}}}}
```

asserted in `test/aurora_meter/supervisor_test.exs`.

### 3. The tables cannot be read

The check is skipped, with one `:info` line, and the host boots. Anything that
makes the query fail takes this path: the credit migration has not been run, the
table does not exist, the repo has not started yet, or the repo is misconfigured.
Observed with a repo module that does not exist:

```
[info] AuroraMeter: credit currency check skipped: function AuroraMeter.NoSuchRepo.all/1 is undefined (module AuroraMeter.NoSuchRepo is not available)
   AuroraMeter.Credits.assert_currency!() => :ok
```

`test/aurora_meter/supervisor_test.exs` also drives this path with a real
injected read failure against the real schema, using build unit 01b's fault
harness (`AuroraMeter.Test.FaultRepo` plus a `:before_commit` fault armed on
`kind: :read, schema: AuroraMeter.Schema.CreditBalance`), so the skip is proved
against a failing statement and not only against a missing module. The test
asserts the fault fired, so a version of it that drifted off the call path and
passed for the wrong reason would fail.

Both skip tests raise the Logger level to `:info` for their duration and put it
back: this package pins Logger at `:warning` in `config/config.exs` so the
suite's output stays readable, and an `:info` line is invisible at that level.

## Cost

One sequential scan of a table bounded by the number of tenants with credit,
once per node, at boot, outside any transaction. A host that finds that
expensive can only be a host with a very large wallet set, and for that host the
check is worth more, not less.

## What this unit does not check at boot

Everything else on `BootChecks`' eventual list belongs to later units: plan
version fingerprints are 07a, outbox and cutover state are Pro's. The child
exists here with one check in it, which is the shape later units extend.
