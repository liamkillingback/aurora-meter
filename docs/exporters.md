# Writing an exporter

An exporter is the last step of metering: it takes usage Aurora Meter has
already decided to bill and hands it to whoever collects the money. It is a
behaviour, `AuroraMeter.Exporter`, with two callbacks.

**Aurora Meter ships no exporter that talks to a network.** The one included
implementation, `AuroraMeter.Exporter.Journal`, records what it was given and
answers what it was told to. A provider adapter is your code, or Aurora Meter
Pro's.

That is deliberate. An adapter has to encode a specific provider's batch limits,
idempotency window and error vocabulary, and those change without asking us. A
wrong number in that encoding is a double charge or a silent gap, so the numbers
belong next to the person who can check them against the provider's own
documentation this week.

## What an exporter does and does not decide

| It decides | Somebody else decides |
|---|---|
| how to talk to the provider | what to send, and when |
| what the provider's answer means | whether to try again, and after how long |
| which subject kinds it accepts | persisting the attempt and its result |

An exporter holds no state between calls beyond whatever its client needs. It
does not write rows, it does not schedule, and it does not retry. In Aurora
Meter Pro the caller is the outbox deliverer; in a host application it is
whatever the host wrote, and the sample in `examples/` uses the journal.

## The two callbacks

```elixir
@callback describe() :: %{
            max_batch: pos_integer(),
            idempotency_horizon: non_neg_integer(),
            timestamp_window: %{past: non_neg_integer(), future: non_neg_integer()},
            supports: [:usage_window | :event | :correction]
          }

@callback deliver([AuroraMeter.Exporter.Item.t()], context :: map()) ::
            [{item_id :: String.t(), outcome()}]
```

`describe/0` is a pure function of compiled configuration. The caller reads it
to size its batches and to decide when an item is too old to resend.

`deliver/2` gets a list and returns one entry per member of it. Not one entry
per member it liked: one per member, keyed by `item.id`.

## The five outcomes

This is the part worth reading twice, because the difference between two of
these lines is money.

| Outcome | The provider | The caller should |
|---|---|---|
| `:accepted` | took it, and named nothing | mark it accepted with no provider reference |
| `{:accepted, ref}` | took it and named it | mark it accepted and keep `ref` for reconciliation |
| `{:retry, seconds}` | did not take it, and the same bytes may be sent again. `nil` means no delay was named | try again with the identical payload |
| `:uncertain` | may or may not have taken it | stop guessing. Reconcile against the provider |
| `{:rejected, reason}` | refused it, and will refuse it again in this form | stop, and show a human |

Two rules follow, and both exist because real code got them wrong.

### A rate limit is a retry

HTTP 429 means "not now". An adapter that maps it to `{:rejected, _}` invites
the caller to abandon the item, or, worse, to build a fresh idempotency key for
the next attempt. If the rate-limited request had in fact reached the provider,
that fresh key bills the same usage a second time.

Aurora Meter had this defect in two places at once, classified two different
ways, which is what the shared vocabulary is for.

### An answer nobody understood is uncertain

`:accepted` and `{:rejected, _}` are both terminal. One says the money arrived,
the other says to stop trying. An answer the adapter could not parse justifies
neither. Report `:uncertain` and let the caller reconcile.

`AuroraMeter.Exporter.normalize/2` enforces this on the caller's side too: an
outcome that is not one of the five shapes becomes `:uncertain`, an item with no
entry becomes `:uncertain`, and when two entries disagree about one id the more
conservative one wins.

## The payload is immutable

`item.payload` is the financial intent. It was decided when the item was
created and it must reach the provider byte for byte however many attempts it
takes.

The failure this prevents is quiet. Suppose an adapter fills in the customer id
by looking it up when it sends, rather than reading it from the payload. The
first attempt times out. Between then and the retry the customer's record
changes. The retry now sends different bytes under the same idempotency key, and
the provider either rejects it or, depending on the provider, accepts it as a
new event.

So: read everything you send from `item.payload`, and key the provider's
idempotency on `item.payload["identifier"]`. Never derive one.

The conformance suite checks this by delivering one item twice and comparing the
bytes, which is why it asks for a `sent/1` hook.

## Delivery is at-least-once

`deliver/2` may be called again for an item whose outcome the caller never
learned: the worker died, the reply was lost, the lease expired. Answer the
repeat rather than refusing it. One provider effect per identity is the
provider's job, through the idempotency key, and the caller's job, through its
own identity tuple. It is not the adapter's.

This is also why `:uncertain` exists at all. A caller that has to choose between
"it worked" and "it failed" for a request that timed out mid-flight will choose
wrong roughly half the time.

## Time, and which clock

Nothing in this vocabulary is an absolute deadline, on purpose.

`{:retry, seconds}`, `idempotency_horizon` and `timestamp_window` are all
**durations**. The caller adds them to its own clock reading, so the adapter and
the caller never have to agree about what time it is.

`first_attempt_at` is the one instant that crosses the boundary. It is there so
an adapter can refuse an item older than its own idempotency horizon rather than
send a second copy the provider will no longer recognise as a repeat. The caller
stamps it from the **database**, not from a node clock, because it is persisted
and later compared against. In Aurora Meter that means `AuroraMeter.Clock.db_now/0`
or a `clock_timestamp()` column default.

That comparison is safe because the horizon is measured in hours. The shared
database clock is shared but it is not monotonic: it is the host's clock, and on
the hardware this library was measured on it stepped backwards by up to 439 ms
several times in five minutes. A comparison of two instants from it is sound
when the duration involved is large, and unsound when it is small.

**So do not decide a lease, a fence or a short timeout with these types.** Use
`SELECT ... FOR UPDATE SKIP LOCKED`, an advisory lock, or a fencing token, none
of which asks the clock anything. `context.attempt_started_at` is for logging;
`context.timeout_ms` is an in-process duration and belongs to
`AuroraMeter.Clock.monotonic_ms/0`.

## A worked example

A fictional provider with an HTTP API. It takes up to fifty events per request,
recognises a repeated `Idempotency-Key` for twenty-four hours, and accepts
occurrence times up to thirty days old.

```elixir
defmodule MyApp.Exporter do
  @moduledoc """
  Delivers usage to Example Metering.

  `describe/0`'s numbers come from https://example.test/docs/metering/limits,
  read on 2026-09-15. Check them before changing any of them: a horizon that is
  longer than the provider's turns a retry into a second charge.
  """

  @behaviour AuroraMeter.Exporter

  @impl AuroraMeter.Exporter
  def describe do
    %{
      max_batch: 50,
      idempotency_horizon: 86_400,
      timestamp_window: %{past: 2_592_000, future: 300},
      supports: [:usage_window, :event]
    }
  end

  @impl AuroraMeter.Exporter
  def deliver(items, context) do
    timeout = Map.get(context, :timeout_ms, 10_000)

    Enum.map(items, fn item -> {item.id, deliver_one(item, timeout)} end)
  end

  defp deliver_one(item, timeout) do
    # Everything sent comes out of the payload. Nothing is looked up here.
    body = item.payload
    key = Map.fetch!(item.payload, "identifier")

    case MyApp.HTTP.post("/v1/events", body, idempotency_key: key, timeout: timeout) do
      {:ok, %{status: 200, body: %{"id" => id}}} -> {:accepted, id}
      {:ok, %{status: 202}} -> :accepted
      {:ok, %{status: 409}} -> {:retry, nil}
      {:ok, %{status: 429} = response} -> {:retry, retry_after(response)}
      {:ok, %{status: status}} when status >= 500 -> {:retry, nil}
      {:ok, %{status: 400, body: %{"code" => code}}} -> {:rejected, code}
      {:ok, %{status: 404}} -> {:rejected, :unknown_customer}
      {:error, :timeout} -> :uncertain
      {:error, :closed} -> :uncertain
      _anything_else -> :uncertain
    end
  end

  defp retry_after(%{headers: headers}) do
    case List.keyfind(headers, "retry-after", 0) do
      {_name, value} -> String.to_integer(value)
      nil -> nil
    end
  end
end
```

Four things in that clause list are worth naming.

The 429 branch is a retry. The 5xx branch is a retry, because a server error
gives no information about whether the write landed and a retry under the same
key is safe. A timeout is `:uncertain`, not a retry, because the request was
already sent and the key may or may not be spent. And the last clause is
`:uncertain` rather than a crash: an answer with no clause is precisely the case
the vocabulary has a word for.

Notice also that `retry_after/1` reads a header. Check that your client actually
exposes headers before writing a clause that depends on one. At least one
popular SDK discards them, and a delay you believe you are reading and are not
is worse than one you computed.

## Declaring `describe/0` honestly

Every number in it is a promise, so:

- Take it from the provider's current official documentation, not from a blog
  post, not from a previous adapter, and not from memory.
- Put the URL and the date you read it in the module's `@moduledoc`, as above.
- When you cannot find a documented number, choose the value that costs you a
  reconciliation rather than a charge: a **shorter** `idempotency_horizon`, a
  **smaller** `max_batch`, a **narrower** `timestamp_window`.
- `supports` lists only kinds you have actually implemented. The caller trusts
  it and will not hand you anything else.

`max_batch` is a hard upper bound on what the caller may pass. An adapter handed
more may answer `{:error, :batch_too_large}` for the whole call; the caller is
at fault, `normalize/2` marks every item `:uncertain`, and the fix is in the
caller's code.

## Proving it with the conformance suite

```elixir
defmodule MyApp.ExporterConformanceTest do
  use AuroraMeter.ExporterCase, exporter: MyApp.Exporter, require_scriptable: true

  # Point the adapter at a fake for the duration of each test.
  def setup_exporter(_config), do: MyApp.HTTP.Fake.start()

  # Make the adapter behave as if the provider had done a given thing.
  def script(subject_ref, :rate_limited), do: MyApp.HTTP.Fake.reply(subject_ref, 429, %{})
  def script(subject_ref, :malformed), do: MyApp.HTTP.Fake.reply(subject_ref, 200, %{"??" => 1})
  def script(subject_ref, :unknown_status), do: MyApp.HTTP.Fake.reply(subject_ref, 418, %{})
  def script(subject_ref, :raise), do: MyApp.HTTP.Fake.explode(subject_ref)
  def script(subject_ref, :accepted), do: MyApp.HTTP.Fake.reply(subject_ref, 202, %{})
  def script(subject_ref, {:retry, _s}), do: MyApp.HTTP.Fake.reply(subject_ref, 503, %{})
  def script(_subject_ref, _other), do: :unsupported

  # What the adapter actually put on the wire for a subject reference.
  def sent(subject_ref), do: MyApp.HTTP.Fake.sent(subject_ref)
end
```

The suite checks nine areas: identity, payload identity, retry, partial success,
malformed response, rate limiting, unknown outcome, exceptions and description.
An area whose scenario your `script/2` reports as `:unsupported` is named in a
warning rather than silently skipped, so a green run cannot mean "nothing ran".
`require_scriptable: true` turns that warning into a failure, which is the right
setting for an adapter that talks to a real provider.

Every assertion is a public function of `AuroraMeter.ExporterCase`, so a failure
names something you can open, and so you can call one directly while you are
working on it.

## The journal, and when to use it in production

`AuroraMeter.Exporter.Journal` is an `Agent` that records every item it is
handed and returns scripted answers. It is the reference implementation, it is
what tests script, and it is a legitimate dry-run rail for a host that wants to
see what would be exported before exporting anything.

**It is memory, not a ledger.** Its log lives in that process and is gone when
the process stops, when the node restarts, and when anything calls `reset/1`. It
writes no file and no row. Do not treat it as a record of what was billed.

It is an `Agent` rather than a process-dictionary fake for a specific reason: an
answer scripted by a test process has to be visible to the worker process that
calls `deliver/2`, which in practice is an Oban job or a `Task`. A
process-dictionary fake is invisible there, and that has cost this project real
debugging time.

## Where the caller's half lives

Two things belong to the caller and not to you, and both are worth knowing
because the suite assumes them:

**The guard.** A caller must wrap `deliver/2` in something that catches a raise,
an exit and a throw alike, and treat every item in that call as `:uncertain`.
Catching only a raise is not enough: an adapter whose HTTP client exits takes the
caller down just as thoroughly.

**The interpretation.** A caller passes the raw answer through
`AuroraMeter.Exporter.normalize/2` rather than reading it directly, so that
"fewer entries than items" and "an id I did not send" mean the same thing in
every caller.

```elixir
outcomes =
  try do
    MyApp.Exporter.deliver(items, context)
  rescue
    _ -> :exporter_blew_up
  catch
    :exit, _ -> :exporter_blew_up
    _ -> :exporter_blew_up
  end

case outcomes do
  :exporter_blew_up ->
    Map.new(items, &{&1.id, :uncertain})

  raw ->
    case AuroraMeter.Exporter.normalize(items, raw) do
      {:ok, by_id} -> by_id
      {:error, {:unknown_ids, _ids}} -> Map.new(items, &{&1.id, :uncertain})
    end
end
```

## See also

- `AuroraMeter.Exporter` for the behaviour and the outcome types.
- `AuroraMeter.Exporter.Journal` for the reference implementation.
- `AuroraMeter.ExporterCase` for the conformance suite and its hooks.
- [docs/guarantees.md](guarantees.md) for what Aurora Meter promises about
  export, and under what conditions.
