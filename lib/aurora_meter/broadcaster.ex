defmodule AuroraMeter.Broadcaster do
  @moduledoc """
  Fans live counter values out over `Phoenix.PubSub` on an interval, decoupled
  from the (slower) database flush.

  Each tick broadcasts the current value of every counter touched since the
  previous tick on its tenant topic (`"aurora_meter:tenant:" <> tenant_key`) as
  `{:aurora_meter, :usage, %{feature:, value:, period_start:}}`. The touched set
  is independent of the flusher's dirty set, so a flush landing between a track
  and the next tick can never swallow an update.
  """

  use GenServer

  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias Phoenix.PubSub

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Broadcasts touched counters now, returning `:ok`."
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
    keys = Counter.touched_keys()

    count =
      Enum.reduce(keys, 0, fn key, acc ->
        Counter.clear_touched(key)

        if Counter.history_key?(key) do
          acc
        else
          {tenant_key, feature, period_start} = key
          value = Counter.value(tenant_key, feature, period_start)

          PubSub.broadcast(
            Config.pubsub(),
            topic(tenant_key),
            {:aurora_meter, :usage, %{feature: feature, value: value, period_start: period_start}}
          )

          acc + 1
        end
      end)

    :telemetry.execute([:aurora_meter, :broadcast], %{count: count}, %{})
    :ok
  end
end
