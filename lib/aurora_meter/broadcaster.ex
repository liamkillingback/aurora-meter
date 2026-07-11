defmodule AuroraMeter.Broadcaster do
  @moduledoc """
  Fans live counter values out over `Phoenix.PubSub` on an interval, decoupled
  from the (slower) database flush.

  Each tick broadcasts the current value of every recently-changed counter on its
  tenant topic (`"aurora_meter:tenant:" <> tenant_key`) as
  `{:aurora_meter, :usage, %{feature:, value:, period_start:}}`.
  """

  use GenServer

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias Phoenix.PubSub

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Broadcasts changed counters now, returning `:ok`."
  @spec broadcast_now() :: :ok
  def broadcast_now, do: GenServer.call(__MODULE__, :broadcast)

  @doc "The PubSub topic for a tenant's usage updates."
  @spec topic(String.t()) :: String.t()
  def topic(tenant_key), do: "aurora_meter:tenant:" <> tenant_key

  @impl GenServer
  def init(_opts) do
    interval = Config.broadcast_interval()
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:broadcast, state) do
    do_broadcast()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:broadcast, _from, state), do: {:reply, do_broadcast(), state}

  @spec schedule(pos_integer()) :: reference()
  defp schedule(interval), do: Process.send_after(self(), :broadcast, interval)

  @spec do_broadcast() :: :ok
  defp do_broadcast do
    keys = Counter.dirty_keys()

    Enum.each(keys, fn {tenant_key, feature, period_start} ->
      value = Counter.value(tenant_key, feature, period_start)

      PubSub.broadcast(
        Config.pubsub(),
        topic(tenant_key),
        {:aurora_meter, :usage, %{feature: feature, value: value, period_start: period_start}}
      )
    end)

    :telemetry.execute([:aurora_meter, :broadcast], %{count: length(keys)}, %{})
    :ok
  end
end
