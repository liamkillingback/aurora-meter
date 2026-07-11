defmodule AuroraMeter.Store do
  @moduledoc """
  Owns the ETS tables that back real-time metering.

  This process does nothing on the hot path — it merely creates and owns two
  public, named ETS tables so that writers (`AuroraMeter.Counter`) and readers
  hit ETS directly without a GenServer bottleneck:

    * `:aurora_meter_counters` — `{tenant_key, feature, period_start} => value`
    * `:aurora_meter_dirty` — the set of counter keys changed since the last flush

  If this process crashes the tables are lost; its supervisor restarts it and the
  tables are recreated (counter state rehydrates lazily from the database).
  """

  use GenServer

  @counters :aurora_meter_counters
  @dirty :aurora_meter_dirty

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The ETS table holding counter values."
  @spec counters_table() :: atom()
  def counters_table, do: @counters

  @doc "The ETS table holding the dirty-key set."
  @spec dirty_table() :: atom()
  def dirty_table, do: @dirty

  @impl GenServer
  def init(_opts) do
    :ets.new(@counters, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(@dirty, [:set, :public, :named_table, write_concurrency: true])

    {:ok, %{}}
  end
end
