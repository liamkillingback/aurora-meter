defmodule AuroraMeter.AmbiguousStorage do
  @moduledoc false
  @behaviour AuroraMeter.Storage
  alias AuroraMeter.Storage.Ecto, as: Backend

  @impl true
  def flush_batch(id, rows, history) do
    result = Backend.flush_batch(id, rows, history)

    if Agent.get_and_update(__MODULE__, fn fail? -> {fail?, false} end) do
      {:ok, _} = Backend.add_counters(Enum.map(rows, &Map.put(&1, :delta, 3)))
      raise "connection lost after commit; a second node flushed before recovery"
    end

    result
  end

  @impl true
  defdelegate add_counters(rows), to: Backend

  @impl true
  defdelegate upsert_counters(rows), to: Backend
  @impl true
  defdelegate load_counter(tenant, feature, period), to: Backend
  @impl true
  defdelegate upsert_history(rows), to: Backend
  @impl true
  defdelegate add_history(rows), to: Backend
  @impl true
  defdelegate load_history(tenant, feature, date), to: Backend
  @impl true
  defdelegate load_history_range(tenant, feature, from, to), to: Backend
  @impl true
  defdelegate get_subscription(tenant), to: Backend
  @impl true
  defdelegate put_subscription(attrs), to: Backend
  @impl true
  defdelegate insert_events(rows), to: Backend
  @impl true
  defdelegate stream_counters(since), to: Backend
end
