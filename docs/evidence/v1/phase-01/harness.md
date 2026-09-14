# 01b: the fault harness (core)

Build unit 01b, `docs/v1/build-plans/phase-01/01b-fault-harness-and-independent-connections.md`.
Recorded 2026-09-14 against core at `26e18b6` plus the uncommitted wave 1a tree.

Nothing in this document ships. Every module below lives under `test/support/`,
which `mix.exs` `package.files` does not include, so the Hex archive is
unchanged and D03 holds: the harness creates no new free or paid surface.

## The seven points and the call sites that invoke them

| Point | Invoked from | Context keys |
|---|---|---|
| `:before_commit` | `AuroraMeter.Test.FaultStorage`, before each of the twelve `AuroraMeter.Storage` callbacks | `:callback` plus per-callback keys |
| `:before_commit` | `AuroraMeter.Test.FaultRepo`, before every statement | `:statement`, `:schema`, `:repo_fun`, `:kind` |
| `:after_commit_before_ack` | `AuroraMeter.Test.FaultStorage`, after each callback returns and before the shim does | `:callback`, `:result` |
| `:after_commit_before_ack` | `AuroraMeter.Test.FaultRepo.transaction/1`, after the **outermost** transaction commits | `:statement` = `:transaction` |
| `:after_claim` | no core call site yet. Pro's `AuroraMeter.Pro.Test.BlockingCreditClient` uses it; 04b's outbox lease is the production one | |
| `:after_provider_accept` | no core call site yet (04b) | |
| `:before_ack_persist` | no core call site yet (04b, 05c) | |
| `:during_shutdown` | no core call site yet (01c, 05c) | |
| `:during_recovery` | no core call site yet (04e) | |

Four points have no production call site in this unit and are exercised only by
the self-tests. That is deliberate and is stated rather than hidden: the unit
ships the instrument, and the units named above wire it to their boundaries.

`FaultRepo.transaction/1` fires no `:before_commit`. That point belongs to
statements, and a check before `BEGIN` would read as a statement failure that
never happened. It fires `:after_commit_before_ack` only when
`target().in_transaction?/0` is false afterwards, so a nested ledger
transaction does not look like a commit.

## The four actions

| Action | Observable effect |
|---|---|
| `:raise` | raises `AuroraMeter.Test.Faults.Injected` carrying `:point`, `:context` and `:label` |
| `:exit_kill_self` | `Process.exit(self(), :kill)`; the monitor reports exactly `:killed` |
| `{:block_until, ref}` | sends `{:aurora_fault_blocked, point, pid, ref}` to the owner, waits for `{:aurora_fault_release, ref}`, and raises `AuroraMeter.Test.Faults.Timeout` naming the point, ref, owner and blocked pid after `:block_timeout` (default 5000 ms) |
| `{:delay, ms}` | `Process.sleep(ms)` |

`{:block_until, ref}` raising rather than returning `{:error, :test_timeout}` is
the deliberate departure from `test/support/blocking_credit_client.ex` in Pro,
whose timeout value the code under test classified as a provider failure so
that a lost rendezvous failed five seconds later somewhere unrelated
(`open-findings.md` T3, suspect 2).

## The ownership rule

`check/2` resolves the owner from `[self() | Process.get(:"$callers", [])]` and
takes the first entry in that chain with an armed, unconsumed,
predicate-satisfied entry for the point. `Task.async/1`,
`Task.Supervisor.async*/2`, `Task.Supervisor.start_child/2` and
`Task.async_stream/3` all set `$callers`, which is the same resolution
`Ecto.Adapters.SQL.Sandbox` uses, so the fault owner and the connection owner
agree by construction.

Two cases carry no `$callers` and need `owner:` naming the checking process:

- a bare `spawn/1` (asserted, as a non-firing case, by the Y1 self-test);
- a `GenServer.call/3`, because the callback runs in the server. `flusher_test.exs`
  arms against `Process.whereis(AuroraMeter.Flusher)` and reads the fired log
  back with `fired(owner: flusher)`.

The `:when` predicate is evaluated **exactly once per check, in the checking
process**, and never re-evaluated by the server. A scripted fault may therefore
carry a side effect (the ported `AmbiguousStorage` case does: its guard applies
the foreign writer's delta of 3 before returning true), provided the test
guarantees a single checker.

`count:` is decremented with `:ets.update_counter/3` inside the server, so
twelve concurrent checkers of a `count: 1` fault produce exactly one victim.

Owners are monitored: when an owner dies its armed faults are deleted and its
fired log dropped, so a killed test cannot leave an armed fault for the next
module.

## `with_config/2`

`AuroraMeter.Test.Config` holds one token for the duration of a region.

1. `GenServer.call({:acquire, self(), keys}, :infinity)`.
2. **The server takes the snapshot at the moment it grants the token**, and
   returns it. This ordering is load-bearing: snapshotting in the caller before
   acquiring reads the *previous* holder's overrides and restores those when the
   region ends. That defect was written, observed on 2026-09-14 at seed 296 of
   the harness self-tests (`Y3 two concurrent with_config regions do not
   overlap` failed with `{:ok, :first}` where `:error` was expected) and fixed.
3. The caller applies the overrides.
4. `try/after`: restore each key (`put_env` for a key that existed,
   `delete_env` for one that did not), then release. `after` covers a normal
   return, a raise, a throw and a caught exit; a `:kill` of the holder is
   covered by the server's monitor, which restores the same snapshot.

A waiter that has waited longer than the report interval (default 30 s,
settable with `put_report_interval/1`) makes the server log the holder's pid,
its registered name and the keys it holds.

## `:fault_repo_target`

`FaultRepo` reads its real repo from
`Application.get_env(:aurora_meter_test, :repo, AuroraMeter.TestRepo)`, set in
`test/test_helper.exs`. The key lives under the harness's own application
rather than `:aurora_meter`, so when 02b makes unknown `:aurora_meter` keys a
boot error it never sees this one. `AuroraMeter.Test.Connections` reads the
same key.

## Statement classification

`FaultRepo.statement/2` maps the first argument's schema (from an
`Ecto.Query` source, an `Ecto.Changeset`'s data, a struct, or a bare module) and
the repo function to a name:

| Schema | Statement |
|---|---|
| `AuroraMeter.Schema.FlushReceipt` | `:receipt_insert` |
| `AuroraMeter.Schema.Counter` | `:counter_upsert` |
| `AuroraMeter.Schema.History` | `:history_upsert` |
| `AuroraMeter.Schema.Event` | `:event_insert` |
| `AuroraMeter.Schema.Subscription` | `:subscription_upsert` |
| `AuroraMeter.Schema.CreditTransaction` | `:transaction_insert`, or `:transaction_update` under `update`, `update!`, `insert_or_update`, `insert_or_update!` |
| `AuroraMeter.Schema.CreditBalance` | `:balance_update` |
| anything else | `:other`, with the module in `:schema` |

`AuroraMeter.Schema.EventTotal` is not in the table because 03a creates it;
03a adds the row when it does.

A read and a write of the same schema carry the same statement name, so a
predicate names `:kind` as well:
`when: &(&1[:statement] == :counter_upsert and &1[:kind] == :write)`.

## The two guards

- `FaultRepo.uncovered_call_sites(["lib"])` parses every `lib/**/*.ex` with
  `Code.string_to_quoted!/1`, expands pipes with `Macro.pipe/3` so a piped call
  is counted at its real arity, and collects every call whose target is
  `repo()`, a `repo` variable or `Config.repo()`. Anything the shim does not
  export is reported with file and line. 34 call sites are found in core today, across twelve `{name, arity}` pairs.
- `FaultStorage.uncovered_callbacks/1` compares
  `AuroraMeter.Storage.behaviour_info(:callbacks)` against the functions in the
  shim's **own source** that contain a `Faults.check/2` call, so a callback that
  is implemented but not instrumented is caught as well as one that is missing.

Both were demonstrated to fail; see `harness-selftest.md`.
