defmodule AuroraMeter.Exporter do
  @moduledoc """
  The seam between Aurora Meter and something that gets billed.

  An exporter takes a list of items a caller has already decided to send, hands
  them to a provider, and says what happened to each one. It does not decide
  *what* to send, it does not persist anything, and it does not retry. Those are
  the caller's, which in Aurora Meter Pro is the outbox deliverer and in a host
  application is whatever the host wrote.

  Aurora Meter ships exactly one implementation, `AuroraMeter.Exporter.Journal`,
  which records what it was given and returns scripted answers. **The core
  contacts no network.** A provider adapter is a host's code, or Aurora Meter
  Pro's.

      defmodule MyApp.Exporter do
        @behaviour AuroraMeter.Exporter

        @impl true
        def describe do
          %{
            max_batch: 100,
            idempotency_horizon: 86_400,
            timestamp_window: %{past: 2_592_000, future: 300},
            supports: [:usage_window, :event]
          }
        end

        @impl true
        def deliver(items, _context) do
          Enum.map(items, fn item -> {item.id, send_one(item)} end)
        end
      end

  Write the adapter, then prove it with `AuroraMeter.ExporterCase`. See
  `docs/exporters.md` for the worked example.

  ## The five outcomes

  Every item gets exactly one of these, and the difference between them is
  money.

  | Outcome | Means | The caller may |
  |---|---|---|
  | `:accepted` | the provider took it, and gave nothing back to name it | mark it accepted, with no provider reference |
  | `{:accepted, ref}` | the provider took it and named it | mark it accepted and record `ref` |
  | `{:retry, seconds}` | it did not land, and sending the same item again is safe. `nil` means the provider named no delay | schedule another attempt with the same `payload` |
  | `:uncertain` | it may have landed. Nobody knows | **not** send a new identity for it. Reconcile |
  | `{:rejected, reason}` | it did not land and it never will in this form | stop, and make the item visible to a human |

  Two rules hold this together, and both exist because the code this behaviour
  replaces got them wrong.

  **A rate limit is a retry, never a rejection.** HTTP 429 means "not now", and
  an adapter that reports it as `{:rejected, _}` invites the caller to give up
  on an item, or worse, to re-derive a fresh idempotency key for it and double
  bill when the original request turns out to have landed.

  **An answer nobody understood is `:uncertain`, never `:accepted` and never
  `{:rejected, _}`.** Both of those are terminal: one stops the money arriving
  and the other stops the retry. Uncertainty is the honest answer, and it is a
  state a caller can reconcile out of.

  ## What an adapter must not do

  - **Do not change the item.** `payload` is the financial intent. It was
    decided when the item was created, and it must reach the provider byte for
    byte however many attempts it takes. An adapter that reads live application
    state to fill in a field has made the retry send something the original
    attempt did not.
  - **Do not re-derive an identity.** Key provider idempotency on
    `item.payload["identifier"]`. A fresh key on a retry is how one unit of
    usage gets billed twice.
  - **Do not run inside the caller's transaction.** `c:deliver/2` performs
    network I/O and the caller guarantees it is called outside `Repo.transaction/2`
    and outside a pinned connection. An adapter that opens its own database
    transaction around a provider call has put the provider inside a lock.
  - **Do not raise for a provider problem.** A timeout, a 500 and a rejection
    are all outcomes. A raise is a bug in the adapter, and although a careful
    caller rescues it (and must then treat every item in the call as
    `:uncertain`), an adapter that raises has thrown away the per-item answers
    it did have.

  ## At-least-once, and what follows

  `c:deliver/2` may be called again for an item whose outcome the caller never
  learned: the caller died, the reply was lost, the lease expired. An adapter
  must answer a repeated item rather than refusing it, and the provider's
  idempotency on `payload["identifier"]` is what keeps the repeat from being a
  second charge. This is invariant I16's shape at the adapter level, and it is
  why `:uncertain` exists at all.

  ## Time, and which clock

  Nothing in this vocabulary is an absolute deadline, deliberately.

  `{:retry, seconds}` is a **duration**, not an instant: the caller adds it to
  its own persisted clock reading, so the adapter never has to agree with the
  caller about what time it is. `idempotency_horizon` and `timestamp_window` are
  durations too.

  `first_attempt_at` is the one instant that crosses the boundary, and it is
  there so an adapter can refuse an item older than its own idempotency horizon
  rather than send a second copy the provider will no longer recognise as a
  repeat. It is stamped by the caller's **database**, because it is persisted
  and later compared against, and in Aurora Meter that means
  `AuroraMeter.Clock.db_now/0` or a `clock_timestamp()` default. The horizon is
  measured in hours, which is the only reason a clock may decide it at all: the
  shared database clock is shared but not monotonic, and it has been measured
  stepping backwards by hundreds of milliseconds on this hardware.

  The consequence for anything short is blunt: **a lease, a fence or a timeout
  is not decided with these types.** Use `SELECT ... FOR UPDATE SKIP LOCKED`, an
  advisory lock, or a fencing token. `context.attempt_started_at` is for logging
  and `context.timeout_ms` is an in-process duration measured with
  `AuroraMeter.Clock.monotonic_ms/0`; neither is a correctness input.

  ## Interpreting the answers

  Do not read an adapter's return value directly. `normalize/2` is the one
  interpretation, and it is shared so that Aurora Meter Pro, a host and the
  sample cannot disagree about what a missing entry means.
  """

  defmodule Item do
    @moduledoc """
    One thing to deliver, and everything an adapter is allowed to know about it.

    The caller builds it, usually from a durable row, and it is immutable from
    that moment: the same struct is handed to `c:AuroraMeter.Exporter.deliver/2`
    on the first attempt and on the twentieth, with only `attempts` moving.
    Build one with `AuroraMeter.Exporter.item!/1` so a half-built struct cannot
    reach an adapter.

    | Field | What it is |
    |---|---|
    | `id` | the caller's row id, opaque to the adapter, and the key of the tuple the adapter returns |
    | `subject_kind` | `:usage_window`, `:event` or `:correction`. The caller must not send a kind the adapter's `supports` list omits |
    | `subject_ref` | the caller's stable business reference: an event id, or `"usage:<feature>:<period_start>:<from>:<to>"` |
    | `tenant_key` | for logging, and for an adapter that must refuse an item belonging to another account |
    | `payload` | a map with string keys, already JSON safe. This is the financial intent, and Aurora Meter never looks inside it |
    | `attempts` | how many previous attempts this item has had; `0` on the first |
    | `first_attempt_at` | when the first attempt was made, or `nil` before it. Stamped by the caller's database, not by a node clock |

    `payload` is where provider-specific fields live, and that is on purpose:
    an account id, a mode flag or a customer reference belongs there (or in the
    caller's own row), never in a field of this struct. Aurora Meter would then
    have to know what a provider is.
    """

    @enforce_keys [:id, :subject_kind, :subject_ref, :tenant_key, :payload]
    defstruct [
      :id,
      :subject_kind,
      :subject_ref,
      :tenant_key,
      :payload,
      :first_attempt_at,
      attempts: 0
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            subject_kind: AuroraMeter.Exporter.subject_kind(),
            subject_ref: String.t(),
            tenant_key: String.t(),
            payload: %{optional(String.t()) => term()},
            attempts: non_neg_integer(),
            first_attempt_at: DateTime.t() | nil
          }
  end

  @subject_kinds [:usage_window, :event, :correction]

  @item_fields [
    :id,
    :subject_kind,
    :subject_ref,
    :tenant_key,
    :payload,
    :attempts,
    :first_attempt_at
  ]

  @typedoc "What an item is: a buffered usage window, one durable event, or a correction to one."
  @type subject_kind :: :usage_window | :event | :correction

  @typedoc """
  The answer for one item. Five shapes, and anything else is a bug the caller
  reads as `:uncertain`.
  """
  @type outcome ::
          :accepted
          | {:accepted, provider_ref :: String.t()}
          | {:retry, delay_seconds :: non_neg_integer() | nil}
          | :uncertain
          | {:rejected, reason :: atom() | String.t()}

  @typedoc """
  What an adapter promises about itself. Every number is a duration in seconds
  except `max_batch`, which is a count.
  """
  @type description :: %{
          max_batch: pos_integer(),
          idempotency_horizon: non_neg_integer(),
          timestamp_window: %{past: non_neg_integer(), future: non_neg_integer()},
          supports: [subject_kind()]
        }

  @typedoc """
  Caller-scoped information that is not part of the financial payload. An
  adapter may ignore all of it, and nothing in it may change what is sent.
  """
  @type context :: %{
          optional(:attempt_started_at) => DateTime.t(),
          optional(:lease_owner) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(atom()) => term()
        }

  @typedoc "What an adapter returns: one entry per item it was given."
  @type result :: {item_id :: String.t(), outcome()}

  @doc """
  What this adapter can do. Pure, and constant for the life of the node.

  `max_batch` is the largest list a caller may pass to `c:deliver/2`; the caller
  is at fault for exceeding it, and an adapter handed more may refuse the whole
  call. `idempotency_horizon` is how long, in seconds, the provider promises to
  recognise a repeated `payload["identifier"]`; past it the caller must
  reconcile rather than resend. `timestamp_window` bounds how far into the past
  and the future an occurrence time may be and still be accepted. `supports`
  lists the `subject_kind` values this adapter accepts.

  Every number must come from the provider's current official documentation,
  with the URL and the date recorded by whoever wrote the adapter. A guess here
  is a guess about when a duplicate becomes a second charge.
  """
  @callback describe() :: description()

  @doc """
  Delivers `items` and returns one `{item_id, outcome}` per item.

  At most one provider round trip per item, although an adapter may batch them
  into one request. The order of the returned list does not matter; the id does.
  Returning fewer entries than items is not an error the adapter can express,
  but it is not free either: `AuroraMeter.Exporter.normalize/2` reads a missing
  entry as `:uncertain`, which is the most expensive state a caller can be left
  in.

  This is at-least-once. The same item may arrive again, with `attempts`
  incremented and `payload` unchanged.
  """
  @callback deliver(items :: [Item.t()], context :: context()) :: [result()]

  @doc """
  Builds an `AuroraMeter.Exporter.Item` from a map or keyword list, raising
  `ArgumentError` on anything an adapter should not have to defend against.

  Checked: `id`, `subject_ref` and `tenant_key` are non-empty binaries;
  `subject_kind` is one of #{inspect(@subject_kinds)}; `payload` is a map whose
  keys are all binaries; `attempts` is a non-negative integer; and
  `first_attempt_at` is `nil` or a `DateTime` in `Etc/UTC`.

  The UTC check is not fussiness. `first_attempt_at` is compared against the
  idempotency horizon, and a local-zone instant in that comparison is a silent
  offset on the one decision that stops a second charge.

      iex> item = AuroraMeter.Exporter.item!(%{
      ...>   id: "01HZ",
      ...>   subject_kind: :event,
      ...>   subject_ref: "evt_1",
      ...>   tenant_key: "acme",
      ...>   payload: %{"identifier" => "evt_1", "quantity" => 3}
      ...> })
      iex> {item.attempts, item.first_attempt_at}
      {0, nil}
  """
  @spec item!(map() | keyword()) :: Item.t()
  def item!(fields) when is_list(fields) do
    if Keyword.keyword?(fields) do
      item!(Map.new(fields))
    else
      raise ArgumentError, "AuroraMeter.Exporter.item!/1 takes a map or a keyword list"
    end
  end

  def item!(fields) when is_map(fields) do
    unknown = Map.keys(fields) -- @item_fields

    if unknown != [] do
      raise ArgumentError,
            "AuroraMeter.Exporter.item!/1 does not know these keys: #{inspect(unknown)}"
    end

    %Item{
      id: binary!(fields, :id),
      subject_kind: subject_kind!(fields),
      subject_ref: binary!(fields, :subject_ref),
      tenant_key: binary!(fields, :tenant_key),
      payload: payload!(fields),
      attempts: attempts!(fields),
      first_attempt_at: first_attempt_at!(fields)
    }
  end

  def item!(other) do
    raise ArgumentError,
          "AuroraMeter.Exporter.item!/1 takes a map or a keyword list, got: #{inspect(other)}"
  end

  @doc """
  Turns whatever an adapter returned into one outcome per item.

  Four rules, and every one of them errs towards `:uncertain` because
  `:uncertain` is the only non-terminal state that cannot lose money:

  1. An id in the results that was not in `items` is an adapter bug and returns
     `{:error, {:unknown_ids, ids}}`. The caller treats the **whole call** as
     uncertain, because an adapter that answered for something it was not given
     may equally have sent something it was not given.
  2. An item with no entry becomes `:uncertain`. Not `{:retry, nil}`: a missing
     answer may follow a request that was actually made.
  3. An entry whose outcome is not one of the five documented shapes becomes
     `:uncertain`.
  4. Two entries for one id is an adapter bug, and the **most conservative**
     answer wins, ordered `{:rejected, _}`, then `:accepted`, then
     `{:accepted, ref}`, then `{:retry, _}`, then `:uncertain`.

  An adapter that returned something that is not a list at all (`:ok`, or
  `{:error, :batch_too_large}`) leaves every item `:uncertain`.

  Rule 4's order is a semantic promise, not an implementation detail: changing
  it would silently change what a caller does with an ambiguous answer, so a
  future change to it is a deliberate break.

      iex> items = [
      ...>   AuroraMeter.Exporter.item!(%{id: "a", subject_kind: :event, subject_ref: "r1",
      ...>     tenant_key: "acme", payload: %{"identifier" => "r1"}}),
      ...>   AuroraMeter.Exporter.item!(%{id: "b", subject_kind: :event, subject_ref: "r2",
      ...>     tenant_key: "acme", payload: %{"identifier" => "r2"}})
      ...> ]
      iex> AuroraMeter.Exporter.normalize(items, [{"a", :accepted}])
      {:ok, %{"a" => :accepted, "b" => :uncertain}}

      iex> items = [AuroraMeter.Exporter.item!(%{id: "a", subject_kind: :event,
      ...>   subject_ref: "r1", tenant_key: "acme", payload: %{"identifier" => "r1"}})]
      iex> AuroraMeter.Exporter.normalize(items, [{"a", :accepted}, {"ghost", :accepted}])
      {:error, {:unknown_ids, ["ghost"]}}
  """
  @spec normalize([Item.t()], term()) ::
          {:ok, %{optional(String.t()) => outcome()}}
          | {:error, {:unknown_ids, [String.t()]}}
  def normalize(items, raw_results) when is_list(items) do
    ids = MapSet.new(items, & &1.id)
    entries = attributable(raw_results)

    case Enum.reject(entries, fn {id, _outcome} -> MapSet.member?(ids, id) end) do
      [] ->
        by_id = Enum.group_by(entries, &elem(&1, 0), &elem(&1, 1))

        {:ok, Map.new(items, fn item -> {item.id, outcome_for(by_id, item.id)} end)}

      unknown ->
        {:error, {:unknown_ids, unknown |> Enum.map(&elem(&1, 0)) |> Enum.uniq()}}
    end
  end

  @doc "The `subject_kind` values Aurora Meter knows about."
  @spec subject_kinds() :: [subject_kind()]
  def subject_kinds, do: @subject_kinds

  @doc """
  Whether `term` is one of the five documented outcome shapes.

  An adapter does not need this; a caller that wants to log the difference
  between "the provider said something odd" and "the item went uncertain for
  another reason" does.
  """
  @spec outcome?(term()) :: boolean()
  def outcome?(:accepted), do: true
  def outcome?(:uncertain), do: true
  def outcome?({:accepted, ref}) when is_binary(ref), do: true
  def outcome?({:retry, nil}), do: true
  def outcome?({:retry, seconds}) when is_integer(seconds) and seconds >= 0, do: true
  def outcome?({:rejected, reason}) when is_atom(reason) or is_binary(reason), do: true
  def outcome?(_other), do: false

  @doc """
  How conservative an outcome is: higher wins when one id is answered twice.

  Exposed because a caller that merges answers from more than one source (a
  delivery and a later reconciliation, say) needs the same order this module
  uses, rather than a second one that disagrees with it.
  """
  @spec conservatism(outcome()) :: non_neg_integer()
  def conservatism({:rejected, _reason}), do: 0
  def conservatism(:accepted), do: 1
  def conservatism({:accepted, _ref}), do: 2
  def conservatism({:retry, _delay}), do: 3
  def conservatism(:uncertain), do: 4

  # -- internals --------------------------------------------------------------

  # An entry that names no id cannot be attributed to an item, so it is dropped
  # here and the item it was meant for falls to rule 2 and becomes `:uncertain`.
  # Nothing is lost by the drop: the conservative answer is what it would have
  # produced anyway, and the caller sees it in the result rather than in a log.
  defp attributable(results) when is_list(results) do
    Enum.filter(results, fn
      {id, _outcome} when is_binary(id) -> true
      _other -> false
    end)
  end

  defp attributable(_not_a_list), do: []

  defp outcome_for(by_id, id) do
    case Map.get(by_id, id) do
      nil -> :uncertain
      outcomes -> outcomes |> Enum.map(&sanitise/1) |> Enum.max_by(&conservatism/1)
    end
  end

  defp sanitise(outcome) do
    if outcome?(outcome), do: outcome, else: :uncertain
  end

  defp binary!(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) and value != "" ->
        value

      other ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a non-empty binary #{key}, got: " <>
                inspect(other)
    end
  end

  defp subject_kind!(fields) do
    case Map.get(fields, :subject_kind) do
      kind when kind in @subject_kinds ->
        kind

      other ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a subject_kind in " <>
                "#{inspect(@subject_kinds)}, got: #{inspect(other)}"
    end
  end

  defp payload!(fields) do
    payload = Map.get(fields, :payload)

    cond do
      not is_map(payload) or is_struct(payload) ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a payload map, got: #{inspect(payload)}"

      not Enum.all?(Map.keys(payload), &is_binary/1) ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a payload with binary keys so it is JSON " <>
                "safe, got keys: #{inspect(Map.keys(payload))}"

      true ->
        payload
    end
  end

  defp attempts!(fields) do
    case Map.get(fields, :attempts, 0) do
      attempts when is_integer(attempts) and attempts >= 0 ->
        attempts

      other ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a non-negative integer attempts, got: " <>
                inspect(other)
    end
  end

  defp first_attempt_at!(fields) do
    case Map.get(fields, :first_attempt_at) do
      nil ->
        nil

      %DateTime{time_zone: "Etc/UTC"} = at ->
        at

      other ->
        raise ArgumentError,
              "AuroraMeter.Exporter.item!/1 needs a first_attempt_at that is nil or a " <>
                "DateTime in Etc/UTC, got: #{inspect(other)}"
    end
  end
end
