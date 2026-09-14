defmodule AuroraMeter.Storage do
  @moduledoc """
  Behaviour for persisting Aurora Meter state, plus dispatch helpers that route to
  the configured adapter (`AuroraMeter.Config.storage/0`, default
  `AuroraMeter.Storage.Ecto`).

  Only a Postgres/Ecto adapter ships in v1. Writing another one is supported,
  and [Storage adapters](storage-adapters.md) is the guide: it gives a
  copyable minimal adapter, and `AuroraMeter.StorageCase` is the conformance
  suite that proves one correct.

  ## Capabilities

  Every callback here is required, including the durable-event ones. An adapter
  that cannot do durable work does not omit them: it declares what it supports
  from `c:capabilities/0` and the dispatcher answers
  `{:error, {:unsupported, operation}}` without calling the adapter at all. The
  difference matters because "this adapter cannot record durable events" is an
  answer a caller can handle, and a `FunctionClauseError` from a missing
  callback is not.
  """

  alias AuroraMeter.Event
  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Subscriptions

  @typedoc "A counter snapshot to persist. `feature` may be an atom or string."
  @type counter_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:period_start) => DateTime.t(),
          required(:value) => integer()
        }

  @typedoc "A day-bucket snapshot to persist."
  @type history_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:date) => Date.t(),
          required(:value) => integer()
        }

  @typedoc "A day bucket as read back: `%{date: Date.t(), value: integer()}`."
  @type history_point :: %{date: Date.t(), value: integer()}

  @typedoc """
  A raw usage event to persist, as the legacy durable-track path writes them.

  `period_start` and `period_source` are the period `AuroraMeter.track/4`
  already resolved for the counter it bumped, passed down rather than looked up
  again: a second resolution could land on the other side of a period boundary
  from the increment the row accompanies. They are optional so that a 0.4.x
  caller of `AuroraMeter.Storage.insert_events/1` keeps working, in which case
  the row carries no period.
  """
  @type event_row :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          optional(:quantity) => integer(),
          optional(:metadata) => map(),
          optional(:period_start) => DateTime.t() | nil,
          optional(:period_source) => atom() | String.t() | nil
        }

  @typedoc "A counter delta to add: `value = value + delta`."
  @type counter_delta :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:period_start) => DateTime.t(),
          required(:delta) => integer()
        }

  @typedoc "A day-bucket delta to add."
  @type history_delta :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => atom() | String.t(),
          required(:date) => Date.t(),
          required(:delta) => integer()
        }

  @typedoc "A total as returned after adding deltas. `feature` is a string."
  @type counter_total :: %{
          tenant_key: String.t(),
          feature: String.t(),
          period_start: DateTime.t(),
          value: integer()
        }

  @typedoc "A day-bucket total as returned after adding deltas."
  @type history_total :: %{
          tenant_key: String.t(),
          feature: String.t(),
          date: Date.t(),
          value: integer()
        }

  @typedoc """
  A durable operation an adapter may support.

  `:durable_events` covers `c:record_events/2`, `c:load_event/2` and
  `c:load_event_total/3`; `:corrections` covers `record_correction/2` (build
  unit 03e); `:projection_generations` covers `c:write_projection_totals/2` and
  `c:activate_projection/1`; `:event_streaming` covers `c:stream_events/2`.
  """
  @type capability :: :durable_events | :corrections | :projection_generations | :event_streaming

  @typedoc """
  One event to record, already validated and canonicalised by
  `AuroraMeter.Events.Canonical`.

  `feature` and `kind` are strings because that is how the columns hold them,
  and an adapter must not have to know which atoms exist.
  """
  @type event_entry :: %{
          required(:tenant_key) => String.t(),
          required(:event_id) => String.t(),
          required(:feature) => String.t(),
          required(:quantity) => pos_integer(),
          required(:kind) => String.t(),
          required(:original_event_id) => String.t() | nil,
          required(:occurred_at) => DateTime.t(),
          required(:period_start) => DateTime.t(),
          required(:period_source) => String.t(),
          required(:attribution) => String.t(),
          required(:dimensions) => map(),
          required(:metadata) => map(),
          required(:payload_hash) => binary(),
          optional(:plan_id) => String.t() | nil,
          optional(:plan_version) => String.t() | nil
        }

  @typedoc """
  One correction to record: what the caller stated, and nothing it inherits.

  A correction's feature, occurrence instant, period, plan attribution and
  dimensions are the original's, read inside the transaction that holds it
  under lock, so they cannot drift from it (L-03e-2). `quantity` is the
  **magnitude of the reduction**, a positive integer, or `:remaining` for
  `AuroraMeter.replace/4`, whose magnitude is `original.quantity` less the
  corrections already committed and is therefore not known until then.

  There is no `payload_hash` here for the same reason: the canonical tuple
  covers fields that come from the original, so the adapter computes it with
  `AuroraMeter.Events.Canonical.correction_hash/3` once it has read one.
  """
  @type correction_entry :: %{
          required(:tenant_key) => String.t(),
          required(:event_id) => String.t(),
          required(:original_event_id) => String.t(),
          required(:quantity) => pos_integer() | :remaining,
          required(:metadata) => map()
        }

  @typedoc "What one recorded event produced: the persisted fact and whether it was new."
  @type record_outcome :: {Event.t(), :inserted | :duplicate}

  @typedoc "A projection total, as `c:write_projection_totals/2` takes them."
  @type projection_total :: %{
          required(:tenant_key) => String.t(),
          required(:feature) => String.t(),
          required(:period_start) => DateTime.t(),
          required(:quantity) => non_neg_integer(),
          required(:events) => non_neg_integer()
        }

  @callback upsert_counters([counter_row()]) :: :ok
  @callback add_counters([counter_delta()]) :: {:ok, [counter_total()]}
  @callback flush_batch(Ecto.UUID.t(), [counter_delta()], [history_delta()]) ::
              {:ok, %{counters: [counter_total()], history: [history_total()]}} | {:error, term()}
  @callback load_counter(String.t(), atom() | String.t(), DateTime.t()) :: integer() | nil
  @callback upsert_history([history_row()]) :: :ok
  @callback add_history([history_delta()]) :: {:ok, [history_total()]}
  @callback load_history(String.t(), atom() | String.t(), Date.t()) :: integer() | nil
  @callback load_history_range(String.t(), atom() | String.t(), Date.t(), Date.t()) ::
              [history_point()]
  @callback get_subscription(String.t()) :: Subscription.t() | nil
  @callback put_subscription(map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  @callback insert_events([event_row()]) :: :ok
  @callback stream_counters(DateTime.t()) :: [Counter.t()]

  @doc """
  The durable operations this adapter supports.

  An adapter that returns `[]` still defines every callback below; the
  dispatchers refuse the call on its behalf.
  """
  @callback capabilities() :: [capability()]

  @doc """
  Records a batch of events in **one** transaction, with their projection
  deltas and the configured outbox's intent.

  The three are one commit or none of them (L-03b-1). Results are returned in
  the caller's input order. An entry whose `(tenant_key, event_id)` already
  exists with an equal `payload_hash` is `:duplicate` and contributes no totals
  delta and no outbox item; one with a different hash rolls the whole batch
  back with `{:error, {:conflict, index, existing}}`.

  Options: `:timeout` (milliseconds for the transaction and every statement in
  it) and `:outbox` (the `AuroraMeter.Events.Outbox` module to invoke).
  """
  @callback record_events([event_entry()], keyword()) ::
              {:ok, [record_outcome()]}
              | {:error, {:conflict, non_neg_integer(), Event.t()}}
              | {:error, term()}

  @doc """
  Records one **correction**, and optionally its replacement, in one transaction.

  A correction is a new immutable row reducing the effective quantity of an
  existing event in the same tenant; no historical row is ever updated. The
  cumulative magnitude of the corrections of one original may never exceed that
  original's quantity (**I09**), which an adapter enforces by serialising every
  corrector of that original against one another. The Ecto adapter does it with
  `SELECT ... FOR UPDATE` on the original row.

  The order of the two checks is load bearing and an adapter must keep it: the
  **duplicate check comes before the bound check**. A retry of a correction has
  its own committed row inside the cumulative sum, so evaluating the bound
  first makes every retry of a correct correction fail with
  `exceeds_original`, which is the difference between an idempotent financial
  operation and one that cannot be retried at all.

  Results are `[{correction, outcome}]`, or `[{correction, outcome},
  {replacement, outcome}]` when `opts[:replacement]` carries a usage entry to
  insert in the same transaction (`AuroraMeter.replace/4`).

  Refusals **return** `{:error, {:invalid, _}}` or `{:error, {:not_found,
  :original}}` without rolling back, so a host transaction that wrapped the
  call keeps its own writes. Conflicts roll back, because by then a write has
  been attempted and the caller's intent is unsatisfiable.

  Options: `:timeout`, `:outbox` and `:replacement`.
  """
  @callback record_correction(correction_entry(), keyword()) ::
              {:ok, [record_outcome()]}
              | {:error, {:conflict, non_neg_integer(), Event.t()}}
              | {:error, {:invalid, [{atom(), atom()}]}}
              | {:error, {:not_found, :original}}
              | {:error, term()}

  @doc "Reads one recorded event by its caller identity."
  @callback load_event(String.t(), String.t()) ::
              {:ok, Event.t()} | {:error, :not_found | {:unsupported, capability()}}

  @doc "Reads the projected total for one feature and period, in the active generation."
  @callback load_event_total(String.t(), atom() | String.t(), DateTime.t()) ::
              {:ok, %{quantity: non_neg_integer(), events: non_neg_integer()}}
              | {:error, {:unsupported, capability()}}

  @doc """
  Reads one bounded page of events after `cursor`, ordered by `seq`.

  `seq` and not `id`: event ids are random v4 UUIDs, so a keyset scan ordered
  by `id` can silently miss a row committed by a transaction that started
  earlier (`open-findings.md` L20).

  Options: `:limit`, `:tenant`, `:feature`, `:from` and `:to` (on
  `occurred_at`, half-open).
  """
  @callback stream_events(non_neg_integer(), keyword()) ::
              {:ok, [Event.t()]} | {:error, {:unsupported, capability()}}

  @doc "Writes absolute projection totals for `generation`. Used by replay (03d)."
  @callback write_projection_totals(non_neg_integer(), [projection_total()]) ::
              :ok | {:error, term()}

  @doc "Makes `generation` the one `c:load_event_total/3` reads."
  @callback activate_projection(non_neg_integer()) :: :ok | {:error, term()}

  @doc """
  Sets counter snapshots to absolute values by `{tenant_key, feature,
  period_start}`. For backfills and test fixtures; the flusher uses
  `add_counters/1` so that nodes add up instead of overwriting one another.
  """
  @spec upsert_counters([counter_row()]) :: :ok
  def upsert_counters(rows), do: impl().upsert_counters(rows)

  @doc """
  Adds deltas to counters (`value = value + delta`, inserting at `delta` when
  the row is new) and returns the resulting totals. This is what makes
  cluster-wide counting correct: each node writes only what it added.
  """
  @spec add_counters([counter_delta()]) :: {:ok, [counter_total()]}
  def add_counters([]), do: {:ok, []}
  def add_counters(rows), do: impl().add_counters(rows)

  @doc "Adds deltas to day buckets and returns the resulting totals. See `add_counters/1`."
  @spec add_history([history_delta()]) :: {:ok, [history_total()]}
  def add_history([]), do: {:ok, []}
  def add_history(rows), do: impl().add_history(rows)

  @doc """
  Atomically applies counter and history deltas once for `batch_id`.

  Adapters must persist the receipt and both sets of deltas in one transaction.
  A retry returns the current totals without applying either delta again.

  ## Examples

      {:ok, %{counters: [], history: []}} = AuroraMeter.Storage.flush_batch(Ecto.UUID.generate(), [], [])

  """
  @spec flush_batch(Ecto.UUID.t(), [counter_delta()], [history_delta()]) ::
          {:ok, %{counters: [counter_total()], history: [history_total()]}} | {:error, term()}
  def flush_batch(id, counters, history), do: impl().flush_batch(id, counters, history)

  @doc "Loads a single flushed counter value, or `nil` if absent."
  @spec load_counter(String.t(), atom() | String.t(), DateTime.t()) :: integer() | nil
  def load_counter(tenant_key, feature, period_start),
    do: impl().load_counter(tenant_key, feature, period_start)

  @doc "Upserts day-bucket snapshots (absolute values) by `{tenant_key, feature, date}`."
  @spec upsert_history([history_row()]) :: :ok
  def upsert_history(rows), do: impl().upsert_history(rows)

  @doc "Loads a single flushed day-bucket value, or `nil` if absent."
  @spec load_history(String.t(), atom() | String.t(), Date.t()) :: integer() | nil
  def load_history(tenant_key, feature, date), do: impl().load_history(tenant_key, feature, date)

  @doc "Loads the flushed day buckets for a feature between two dates (inclusive), oldest first."
  @spec load_history_range(String.t(), atom() | String.t(), Date.t(), Date.t()) ::
          [history_point()]
  def load_history_range(tenant_key, feature, from, to),
    do: impl().load_history_range(tenant_key, feature, from, to)

  @doc "Fetches a tenant's subscription straight from storage (uncached), or `nil`."
  @spec get_subscription(String.t()) :: Subscription.t() | nil
  def get_subscription(tenant_key), do: impl().get_subscription(tenant_key)

  @doc """
  Inserts or updates a tenant's subscription (upsert on `tenant_key`) and evicts
  it from the subscription cache on every node.
  """
  @spec put_subscription(map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def put_subscription(attrs) do
    result = impl().put_subscription(attrs)

    with {:ok, %Subscription{tenant_key: tenant_key}} <- result do
      Subscriptions.invalidate(tenant_key)
    end

    result
  end

  @doc "Appends raw usage events (durable mode / audit)."
  @spec insert_events([event_row()]) :: :ok
  def insert_events(rows), do: impl().insert_events(rows)

  @doc "Returns all counter snapshots for a period (used by Pro rollups)."
  @spec stream_counters(DateTime.t()) :: [Counter.t()]
  def stream_counters(period_start), do: impl().stream_counters(period_start)

  @doc """
  The durable operations the configured adapter supports.

  ## Examples

      iex> :durable_events in AuroraMeter.Storage.capabilities()
      true

  """
  @spec capabilities() :: [capability()]
  def capabilities, do: impl().capabilities()

  @doc """
  Whether the configured adapter supports `capability`.

  ## Examples

      iex> AuroraMeter.Storage.supports?(:corrections)
      true

  """
  @spec supports?(capability()) :: boolean()
  def supports?(capability), do: capability in capabilities()

  @doc "Records a batch of events in one transaction. See `c:record_events/2`."
  @spec record_events([event_entry()], keyword()) ::
          {:ok, [record_outcome()]}
          | {:error, {:conflict, non_neg_integer(), Event.t()}}
          | {:error, term()}
  def record_events(entries, opts \\ []) do
    with :ok <- require!(:durable_events), do: impl().record_events(entries, opts)
  end

  @doc "Records one correction (and optionally its replacement). See `c:record_correction/2`."
  @spec record_correction(correction_entry(), keyword()) ::
          {:ok, [record_outcome()]}
          | {:error, {:conflict, non_neg_integer(), Event.t()}}
          | {:error, {:invalid, [{atom(), atom()}]}}
          | {:error, {:not_found, :original}}
          | {:error, term()}
  def record_correction(entry, opts \\ []) do
    with :ok <- require!(:corrections), do: impl().record_correction(entry, opts)
  end

  @doc "Reads one recorded event by its caller identity. See `c:load_event/2`."
  @spec load_event(String.t(), String.t()) ::
          {:ok, Event.t()} | {:error, :not_found | {:unsupported, capability()}}
  def load_event(tenant_key, event_id) do
    with :ok <- require!(:durable_events), do: impl().load_event(tenant_key, event_id)
  end

  @doc "Reads the active generation's projected total. See `c:load_event_total/3`."
  @spec load_event_total(String.t(), atom() | String.t(), DateTime.t()) ::
          {:ok, %{quantity: non_neg_integer(), events: non_neg_integer()}}
          | {:error, {:unsupported, capability()}}
  def load_event_total(tenant_key, feature, period_start) do
    with :ok <- require!(:durable_events),
         do: impl().load_event_total(tenant_key, feature, period_start)
  end

  @doc "Reads one bounded page of events after `cursor`. See `c:stream_events/2`."
  @spec stream_events(non_neg_integer(), keyword()) ::
          {:ok, [Event.t()]} | {:error, {:unsupported, capability()}}
  def stream_events(cursor, opts \\ []) do
    with :ok <- require!(:event_streaming), do: impl().stream_events(cursor, opts)
  end

  @doc "Writes absolute projection totals for a generation. See `c:write_projection_totals/2`."
  @spec write_projection_totals(non_neg_integer(), [projection_total()]) ::
          :ok | {:error, term()}
  def write_projection_totals(generation, rows) do
    with :ok <- require!(:projection_generations),
         do: impl().write_projection_totals(generation, rows)
  end

  @doc "Makes a generation the one reads see. See `c:activate_projection/1`."
  @spec activate_projection(non_neg_integer()) :: :ok | {:error, term()}
  def activate_projection(generation) do
    with :ok <- require!(:projection_generations), do: impl().activate_projection(generation)
  end

  # The adapter is asked what it supports before it is asked to do the work, so
  # an adapter that cannot do durable writes never has to fake one. The answer
  # is the same shape as every other error in this API.
  @spec require!(capability()) :: :ok | {:error, {:unsupported, capability()}}
  defp require!(capability) do
    if capability in impl().capabilities() do
      :ok
    else
      {:error, {:unsupported, capability}}
    end
  end

  @spec impl() :: module()
  defp impl, do: AuroraMeter.Config.storage()
end
