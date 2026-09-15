# 06c: side effects deferred out of a host transaction

Finding **L18**, lower-level invariant **LI-06c-3**. Tests:
`AuroraMeter.CreditsAfterCommitTest`, six, all `I10`, plus the flipped
`AuroraMeter.CreditsConcurrencyTest` / `test I10 a host transaction that rolls
back emits nothing, because the side effects were deferred (L18)`.

Trace log `tmp/v1/06c-logs/lowbal-deferral-trace.log` sha256
`4a4542151a77f3c83f12e74913d68fc0bd157d4355ee31c6b856ac10973ba47b`, seed 0,
2026-09-15.

## What was wrong

`Ledger.transact_outcome/1` ran `emit/1` when its own `repo.transaction/1`
returned. Inside a host's transaction that return is a **savepoint release**,
not a commit, so telemetry, PubSub and the low-balance handler all described a
balance the host could still throw away. The concrete hazard is not abstract:
the low-balance handler is where Pro enqueues an auto top-up, so a rolled-back
settle could buy credit against a payment that never happened.

## What happens now

At the top of every ledger operation, before any work:

```elixir
nested? = repo.in_transaction?()
```

When false, the effects run on commit exactly as before. When true they are
appended to a queue on the **calling process**, and
`AuroraMeter.Credits.after_commit/1` runs them. `after_commit(discard: true)`
drops them, which is what the rollback branch calls.

The queue lives in the process dictionary, and that is the design rather than a
shortcut: Ecto's transaction scope is itself process bound, so the queue and the
transaction have exactly the same lifetime. A store that outlived the process
would have to be told when the process died; this cannot be told wrong.

## How the negative is proved

`refute_received` on an asynchronous message passes when the message is merely
slow, so it is not what carries the claim here. The telemetry handler records
**when** it ran: it reads a phase marker at the instant it fires and appends it
to a log.

```elixir
defp phase(phases, name), do: Agent.update(phases, fn {_p, log} -> {name, log} end)

def record(event, _measurements, metadata, %{tenant: tenant, phases: phases}) do
  if metadata.tenant_key == tenant, do: append(phases, List.last(event), metadata)
  :ok
end
```

A handler that fires inside the host transaction records `:inside`, and the
assertion fails naming the phase that actually happened rather than saying
"nothing arrived".

## The three traces

### Commit path

```
phase :before
  Repo.transaction(fn ->
    Credits.grant(org, 10 USD, reference: "g1")   -> {:ok, txn}
    Credits.balance(org).balance                  == 10_000_000   # the row is there
    Credits.deferred_effects?()                   == true         # ...and so is the queue
  end)                                            -> {:ok, :done}
phase :after_commit_before_drain
  Credits.deferred_effects?()                     == true         # committed, still nothing fired
phase :after_drain
  Credits.after_commit()                          -> :ok
  Credits.deferred_effects?()                     == false

fired(phases) == [:after_drain]                                   # exactly one event, in the last phase
assert_receive {:aurora_meter, :credits, %{balance: 10_000_000}}  # and the PubSub message
```

The positive and the negative come from **one** recording, so the mechanism is
shown to work rather than shown to be absent.

### Rollback path

```
phase :before
  Repo.transaction(fn ->
    Credits.grant(org, 10 USD, reference: "g1")   -> {:ok, txn}
    Repo.rollback(:nope)
  end)                                            -> {:error, :nope}
phase :after_rollback
  Credits.deferred_effects?()                     == true
  Credits.after_commit(discard: true)             -> :ok
  Credits.deferred_effects?()                     == false

fired(phases) == []                               # nothing described a write that no longer exists
Credits.balance(org).balance == 0
refute_receive {:aurora_meter, :credits, _}, 200  # belt and braces, not the claim
```

### Order, and the `deferred` flag

A grant, a hold and a settle inside one host transaction, drained afterwards:

```
kinds(phases)          == [:grant, :hold, :settle]        # the order the writes happened
fired(phases)          == [:after_drain, :after_drain, :after_drain]
deferred_flags(phases) == [true, true, true]
```

`deferred: true` is metadata on `[:aurora_meter, :credits, kind]`, so an
operator reading the events can tell a late one from a slow one.

### The L18 hazard itself

`test I10 a low-balance crossing inside a host transaction does not invoke the
handler before commit` configures a real handler and asserts its log is
**empty** while the transaction is open, then `[{:after_drain, event}]` after the
drain, with `event.spendable == 4_000_000` and a `crossing_id`. That is the auto
top-up path, with Pro's handler replaced by a recorder.

## The control

`test I10 a ledger call that owns its transaction is unaffected` is the test that
fails if `transact_outcome/1` deferred unconditionally. Every other test in the
file would tolerate that, which is why it exists:

```elixir
phase(phases, :immediate)
assert {:ok, _txn} = Credits.grant(tenant, @dollar, reference: "g1")
assert fired(phases) == [:immediate]
refute Credits.deferred_effects?()
assert deferred_flags(phases) == [false]
```

Measured, not asserted. `tmp/v1/06c-controls.sh`, over 26 tests in four files,
`ledger.ex` restored sha256-identical
(`2f27218d5f16a868699b5ad03703849caa62052ec3e4370085df8b6011aed3c8`) after each:

| Control | Break | Failures |
|---|---|---|
| **C3** | `nested?` is always true, so every call defers | **8**. `a ledger call that owns its transaction is unaffected`, and **seven of the eight low-balance tests**: with the effects queued and never drained, no alert is ever delivered |
| **C4** | `nested?` is always false, which is L18's behaviour | **6**. Five of the six in this file, plus the flipped `CreditsConcurrencyTest` one |

C3's blast radius is the interesting one. The control that names the condition
fails, **and so does almost every test that depends on an effect arriving at
all**, which says the two halves of the change are not independent: deferral and
the low-balance alert share one path, and breaking the condition breaks both. A
reviewer reading only C4 would conclude the deferral tests are self-contained;
they are not.

The compiler had a say in how these controls are written. A literal `nested? =
true` is narrowed by the type checker, which then reports the `else` branch as
unreachable and `--warnings-as-errors` refuses the build: the control would have
proved that the build rejects it rather than that a test does. Both are written
as `System.get_env("AURORA_CONTROL_NEVER_SET")` comparisons, which are opaque at
compile time and constant at run time.

## Limits, stated

- **The queue is not durable.** A process that dies between the commit and the
  drain loses that round of effects. The money is committed and correct; one
  telemetry event, one PubSub message and possibly one low-balance alert are not
  delivered. A host that needs at-least-once subscribes to PubSub or polls
  `balance/1`, which is what `docs/credits.md` says.
- **It is per process.** `test I10 deferred_effects? reports an undrained queue`
  asserts a `Task` sees `false` while the parent's queue is full. A host that
  spawns the ledger call inside its own transaction, which Ecto does not support
  anyway, gets no effects.
- **A host that forgets `after_commit/1` loses that round** and
  `deferred_effects?/0` stays true until the process ends.
  `AuroraMeter.CreditsAfterCommitTest`'s own `setup` calls
  `after_commit(discard: true)` in `on_exit`, for exactly that reason: a queue
  left behind would leak an effect into the next test.
