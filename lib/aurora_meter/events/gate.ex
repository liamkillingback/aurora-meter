defmodule AuroraMeter.Events.Gate do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Admission control for the durable write path: at most
  `:record_max_concurrency` callers may hold a connection and an open
  transaction at once, and the rest are told `:overloaded` rather than queued
  behind a pool checkout that will time out somewhere unhelpful.

  ## Why a process and not a counter

  `:counters` would be cheaper and is wrong here. A caller that is killed with
  `:kill` runs no `after` block and no `on_exit`, so its permit would never be
  returned and the loss would be permanent: after enough kills the gate would
  refuse everything for ever. A process can monitor its callers, so a permit
  comes back when the caller dies however it dies.

  ## There is no clock in this module

  A concurrency limit at this timescale must not be decided by comparing two
  wall-clock instants: the shared database clock steps backwards by hundreds of
  milliseconds on this hardware (`open-findings.md` X100), and a node clock is
  worse. So the gate counts and monitors; it never expires anything. The only
  time value here is the `GenServer.call/3` timeout, which is OTP's own
  monotonic timer and not a comparison of two stamped instants, and a caller
  whose call times out is refused rather than admitted.
  """

  use GenServer

  alias AuroraMeter.Config

  @call_timeout 5_000

  @typedoc "A permit. Hand it back to `leave/1` when the work is done."
  @type permit :: reference()

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Asks for a permit.

  `{:ok, permit}` admits the caller and monitors it. `{:error, :overloaded}`
  means `:record_max_concurrency` callers are already admitted.
  `{:error, :unavailable}` means the gate did not answer: it is restarting, or
  it is too busy to reply within #{@call_timeout} ms. Neither is a reason to
  fall back to buffered tracking (L-03b-4).
  """
  @spec enter() :: {:ok, permit()} | {:error, :overloaded | :unavailable}
  def enter do
    GenServer.call(__MODULE__, :enter, @call_timeout)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Returns a permit. Safe to call with a permit that has already been released."
  @spec leave(permit()) :: :ok
  def leave(permit) when is_reference(permit) do
    GenServer.cast(__MODULE__, {:leave, permit})
  catch
    :exit, _reason -> :ok
  end

  @doc "How many callers are admitted right now. For tests and for `AuroraMeter.Operations`."
  @spec admitted() :: non_neg_integer()
  def admitted do
    GenServer.call(__MODULE__, :admitted, @call_timeout)
  catch
    :exit, _reason -> 0
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{admitted: 0, monitors: %{}}}

  @impl GenServer
  def handle_call(:enter, {pid, _tag}, state) do
    if state.admitted >= Config.record_max_concurrency() do
      {:reply, {:error, :overloaded}, state}
    else
      permit = Process.monitor(pid)

      {:reply, {:ok, permit},
       %{state | admitted: state.admitted + 1, monitors: Map.put(state.monitors, permit, pid)}}
    end
  end

  def handle_call(:admitted, _from, state), do: {:reply, state.admitted, state}

  @impl GenServer
  def handle_cast({:leave, permit}, state), do: {:noreply, release(state, permit)}

  @impl GenServer
  def handle_info({:DOWN, permit, :process, _pid, _reason}, state) do
    {:noreply, release(state, permit)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Idempotent: a permit released by `leave/1` and then again by the caller's
  # own `:DOWN` must decrement once. `Map.pop/2` is the arbiter, and
  # `demonitor(:flush)` drops a `:DOWN` already in the mailbox.
  defp release(state, permit) do
    case Map.pop(state.monitors, permit) do
      {nil, _monitors} ->
        state

      {_pid, monitors} ->
        Process.demonitor(permit, [:flush])
        %{state | admitted: state.admitted - 1, monitors: monitors}
    end
  end
end
