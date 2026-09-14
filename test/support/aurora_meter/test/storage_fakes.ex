defmodule AuroraMeter.Test.IncapableStorage do
  @moduledoc """
  An `AuroraMeter.Storage` adapter that declares **no** durable capabilities
  (build unit 03b).

  It is the shape `docs/storage-adapters.md` gives an adapter author who cannot
  do durable events: every callback is defined, `capabilities/0` is empty, and
  the dispatcher refuses the call before the adapter is ever reached. It is
  also the negative half of the `AuroraMeter.StorageCase` conformance suite: a
  fake that fails these assertions has declined the work in a way a caller
  cannot handle.

  Counters, history and subscriptions still work, because "cannot record
  durable events" and "cannot count" are different disabilities.
  """

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Storage.Ecto, as: Backend

  @impl AuroraMeter.Storage
  def capabilities, do: []

  @impl AuroraMeter.Storage
  def record_events(_entries, _opts), do: {:error, {:unsupported, :durable_events}}

  @impl AuroraMeter.Storage
  def record_correction(_entry, _opts), do: {:error, {:unsupported, :corrections}}

  @impl AuroraMeter.Storage
  def load_event(_tenant_key, _event_id), do: {:error, {:unsupported, :durable_events}}

  @impl AuroraMeter.Storage
  def load_event_total(_tenant_key, _feature, _period_start),
    do: {:error, {:unsupported, :durable_events}}

  @impl AuroraMeter.Storage
  def stream_events(_cursor, _opts), do: {:error, {:unsupported, :event_streaming}}

  @impl AuroraMeter.Storage
  def write_projection_totals(_generation, _rows),
    do: {:error, {:unsupported, :projection_generations}}

  @impl AuroraMeter.Storage
  def activate_projection(_generation), do: {:error, {:unsupported, :projection_generations}}

  @impl AuroraMeter.Storage
  def begin_projection_generation, do: {:error, {:unsupported, :projection_generations}}

  @impl AuroraMeter.Storage
  def projection_state, do: {:error, {:unsupported, :projection_generations}}

  @impl AuroraMeter.Storage
  def drain_projection_seed(_seed, _limit),
    do: {:error, {:unsupported, :projection_generations}}

  @impl AuroraMeter.Storage
  defdelegate upsert_counters(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate add_counters(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate flush_batch(id, counters, history), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_counter(tenant_key, feature, period_start), to: Backend

  @impl AuroraMeter.Storage
  defdelegate upsert_history(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate add_history(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_history(tenant_key, feature, date), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_history_range(tenant_key, feature, from, to), to: Backend

  @impl AuroraMeter.Storage
  defdelegate get_subscription(tenant_key), to: Backend

  @impl AuroraMeter.Storage
  defdelegate put_subscription(attrs), to: Backend

  @impl AuroraMeter.Storage
  defdelegate insert_events(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate stream_counters(period_start), to: Backend
end

defmodule AuroraMeter.Test.UnresolvedStorage do
  @moduledoc """
  An adapter that always answers `{:unavailable, :conflict_unresolved}` from
  `record_events/2` (build unit 03b).

  The branch it stands in for is the one the whole unit turns on: the insert
  skipped a row and the row is not visible to this transaction. Guessing
  `:duplicate` there would silently accept a conflicting reuse of an identity,
  which is how a retry bills twice. This fake exists so the **facade** contract
  for that answer is asserted directly, rather than being left to a race whose
  reachability is a property of the Postgres version (measured in
  `docs/evidence/v1/phase-03/03b-conflict-wait.md`).
  """

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Storage.Ecto, as: Backend

  @impl AuroraMeter.Storage
  defdelegate capabilities(), to: Backend

  @impl AuroraMeter.Storage
  def record_events(_entries, _opts), do: {:error, {:unavailable, :conflict_unresolved}}

  @impl AuroraMeter.Storage
  def record_correction(_entry, _opts), do: {:error, {:unavailable, :conflict_unresolved}}

  @impl AuroraMeter.Storage
  defdelegate load_event(tenant_key, event_id), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_event_total(tenant_key, feature, period_start), to: Backend

  @impl AuroraMeter.Storage
  defdelegate stream_events(cursor, opts), to: Backend

  @impl AuroraMeter.Storage
  defdelegate write_projection_totals(generation, rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate activate_projection(generation), to: Backend

  @impl AuroraMeter.Storage
  defdelegate begin_projection_generation(), to: Backend

  @impl AuroraMeter.Storage
  defdelegate projection_state(), to: Backend

  @impl AuroraMeter.Storage
  defdelegate drain_projection_seed(seed, limit), to: Backend

  @impl AuroraMeter.Storage
  defdelegate upsert_counters(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate add_counters(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate flush_batch(id, counters, history), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_counter(tenant_key, feature, period_start), to: Backend

  @impl AuroraMeter.Storage
  defdelegate upsert_history(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate add_history(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_history(tenant_key, feature, date), to: Backend

  @impl AuroraMeter.Storage
  defdelegate load_history_range(tenant_key, feature, from, to), to: Backend

  @impl AuroraMeter.Storage
  defdelegate get_subscription(tenant_key), to: Backend

  @impl AuroraMeter.Storage
  defdelegate put_subscription(attrs), to: Backend

  @impl AuroraMeter.Storage
  defdelegate insert_events(rows), to: Backend

  @impl AuroraMeter.Storage
  defdelegate stream_counters(period_start), to: Backend
end
