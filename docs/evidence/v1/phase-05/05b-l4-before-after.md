# 05b: L4 before and after

Open finding **L4**: `AuroraMeter.Credits.with_credits/4`'s success branch
asserted `{:ok, _txn} = settle(reference, actual)`. Nothing could close a hold
behind a running `with_credits/4` before this unit, so the match never failed.
This unit ships a reconciler that can release one, which makes the match a live
`MatchError` raised inside the caller's process, caught by the `catch` clause
below it, released a second time and re-raised: the caller sees a `MatchError`
instead of its result and the executed work is never charged.

This file is the proof that the defect was real at the commit that carried it,
and that the change was necessary.

## The commit that had it

| | |
|---|---|
| Repository | `product-workspaces/aurora_meter` (core) |
| Branch | `aurorameter-v1` |
| HEAD at the before-run | `668818bd8538f50b94ed93b13c6a2fe0227b7bb5` |
| `lib/aurora_meter/credits.ex` sha256 at that HEAD | `4d0a64c211e88fe5db016ebc2722b3cdba0871e649d48c9fe9b70bed5090030d` |
| Verified identical to the working copy at the before-run | yes: `sha256sum lib/aurora_meter/credits.ex` and `git show HEAD:lib/aurora_meter/credits.ex \| sha256sum` both printed that digest |
| Last commit to touch the file before this unit | `1434084` (02c, the clock seam) |

`git log --oneline -- lib/aurora_meter/credits.ex` was read before a line was
written, per `open-findings.md` X147. **L4 had not been fixed by another unit**:
no commit between the build document's 2026-09-14 inspection and this run
touched `run_held/2`.

The build document cites the defect at `credits.ex:401`. At HEAD it is at
**`credits.ex:405`**, which the stack trace below names. Line numbers in the
build document are stale; the symbol `AuroraMeter.Credits.run_held/2` is not.

## The old text

```elixir
  @spec run_held(String.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp run_held(reference, fun) do
    case fun.() do
      {:ok, result, actual} when is_integer(actual) and actual >= 0 ->
        {:ok, _txn} = settle(reference, actual)      # <- credits.ex:405
        {:ok, result}

      {:error, reason} ->
        _ = release(reference)
        {:error, reason}

      other ->
        _ = release(reference)
        raise ArgumentError, "..."
    end
  catch
    kind, reason ->
      release(reference)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end
```

## The before-run

Command, run against the unmodified `lib/aurora_meter/credits.ex` at the digest
above, with only the four new tests added to `test/aurora_meter/credits_test.exs`:

```
bash tmp/v1/mixlane.sh core \
  env MIX_ENV=test mix test test/aurora_meter/credits_test.exs --trace \
  --only describe:"with_credits/4"
```

`2026-09-15T05:19:24Z`, exit **2**. Full log: `tmp/v1/05b-logs/05b-l4-before.log`.

```
Result: 5/9 passed, 57 excluded
Failed: 4 tests
```

Every one of the four failed the same way, and the failure is the defect itself:

```
  3) test with_credits/4 I11 returns its result when the hold was settled by someone else
     test/aurora_meter/credits_test.exs:238
     ** (MatchError) no match of right hand side value:

         {:error, :already_settled}

     code: Credits.with_credits(tenant, 500_000, reference, fn ->
     stacktrace:
       (aurora_meter 0.5.0) lib/aurora_meter/credits.ex:405: AuroraMeter.Credits.run_held/2
       test/aurora_meter/credits_test.exs:250: (test)
```

The other three, identically:

| Test | Line | Failure |
|---|---|---|
| `I11 returns its result when the hold was settled by someone else` | 238 | `MatchError` at `credits.ex:405` |
| `I11 records the executed cost when the hold was released by someone else` | 262 | `MatchError` at `credits.ex:405` |
| `writes nothing extra when the released hold's actual cost was zero` | 286 | `MatchError` at `credits.ex:405` |
| `is idempotent for the settle_missed debit across a retry` | 301 | `MatchError` at `credits.ex:405` |

The five pre-existing `with_credits/4` tests passed in the same run, which is
the point: the defect is invisible to every test written before a third party
could close a hold.

## The new text

```elixir
  @spec run_held(String.t(), String.t(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp run_held(tenant_key, reference, fun) do
    case fun.() do
      {:ok, result, actual} when is_integer(actual) and actual >= 0 ->
        settled(tenant_key, reference, actual, result)
      ...
  end

  defp settled(tenant_key, reference, actual, result) do
    case settle(reference, actual, tenant: tenant_key) do
      {:ok, _txn} -> {:ok, result}
      {:error, reason} when reason in [:already_settled, :not_found] ->
        closed_by_other(tenant_key, reference, actual, result)
      {:error, reason} -> {:error, reason}
    end
  end

  defp closed_by_other(tenant_key, reference, actual, result) do
    hold = Ledger.fetch_hold(reference)
    now = Clock.now()

    case hold do
      %CreditTransaction{status: :settled} ->
        Reconciliation.emit_external(hold, :settled_by_other, now)
        {:ok, result}

      _released_or_gone ->
        if hold, do: Reconciliation.emit_external(hold, :released_by_other, now)
        record_missed_settle(tenant_key, reference, actual)
        {:ok, result}
    end
  end

  defp record_missed_settle(_tenant_key, _reference, 0), do: :ok

  defp record_missed_settle(tenant_key, reference, actual) do
    _ =
      Ledger.debit(tenant_key, actual, "settle_missed:" <> reference,
        %{"reason" => "hold_released_before_settle", "hold_reference" => reference},
        allow_negative: true)

    :ok
  end
```

Three decisions are worth naming.

**A hold already settled by somebody else returns the caller's result.** One
settle per hold is the contract; the other settle stands, and raising at the
caller would turn a correct outcome into an error.

**A hold released by somebody else charges for the work anyway.** The work ran
and cost something. `v1-release.md` 10.1 says never to hide executed cost by
pretending settlement was not owed, so the cost is recorded as its own
`:debit` under `settle_missed:<reference>`, with `allow_negative: true` because
the reservation has already gone back and the balance may have been spent. The
reference is the idempotency key, so a retry cannot double charge.

**A settle that failed for any other reason is returned to the caller.** A
storage failure is not a concurrent close; swallowing it would hand back
`{:ok, result}` for work whose charge silently vanished.

## The after-run

Same command, after the change, `2026-09-15T05:22:13Z`, exit **0**:

```
Result: 9 passed, 57 excluded
```

And on real connections rather than in the sandbox, the same property with the
release coming from an actual `reconcile_holds/1` run on another connection:
`AuroraMeter.CreditsReconcileConcurrencyTest` /
`test I11 a with_credits caller whose hold the reconciler released records the
executed cost`, which asserts one `:release` row, no `:settle` row, exactly one
`:debit` row referenced `settle_missed:job:<tenant>` for 300_000 micro-USD, and a
balance of 700_000 from 1_000_000.
