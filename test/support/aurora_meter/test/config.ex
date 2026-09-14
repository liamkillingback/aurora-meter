defmodule AuroraMeter.Test.Config do
  @moduledoc """
  Node-wide configuration changes for a test, serialised and always restored
  (build unit 01b).

  `Application.put_env/3` changes the whole node. Three places in this suite did
  it by hand and restored in `on_exit`, which loses the race when the test
  process is killed and silently overlaps when two modules touch the same key.
  Every configuration mutation in a test goes through this module instead; a new
  one that does not is a review failure (`docs/testing.md`).

      with_config([{:aurora_meter, :storage, AuroraMeter.Test.FaultStorage}], fn ->
        ...
      end)

  One token is held for the duration of a region, so regions never overlap. A
  waiter that has waited longer than the report interval logs the current
  holder's pid, its registered name and the keys it holds, so a deadlock names
  its cause rather than timing out anonymously.
  """

  use GenServer

  require Logger

  @default_report_interval 30_000

  @typedoc "An `{application, key, value}` override."
  @type override :: {atom(), atom(), term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Applies `overrides` for the duration of `fun` and restores the exact prior
  state afterwards, including deleting a key that was absent before.

  Restoration runs on a normal return, a raise, a throw and a caught exit. A
  `:kill` of the calling process is handled by the server, which holds the same
  snapshot and restores it when the holder's monitor fires.
  """
  @spec with_config([override()], (-> result)) :: result when result: var
  def with_config(overrides, fun) do
    snapshot = acquire(overrides)

    try do
      fun.()
    after
      release(snapshot)
    end
  end

  @doc """
  The `setup`-block form: applies `overrides` now and restores them in
  `ExUnit.Callbacks.on_exit/1`.
  """
  @spec put_config([override()]) :: :ok
  def put_config(overrides) do
    snapshot = acquire(overrides)
    ExUnit.Callbacks.on_exit(fn -> release(snapshot) end)
    :ok
  end

  @doc "Sets the waiter report interval in milliseconds. For the harness self-tests."
  @spec put_report_interval(pos_integer()) :: :ok
  def put_report_interval(ms) when is_integer(ms) and ms > 0,
    do: GenServer.call(__MODULE__, {:report_interval, ms})

  @doc "The pid currently holding the configuration token, or `nil`."
  @spec holder() :: pid() | nil
  def holder, do: GenServer.call(__MODULE__, :holder)

  # The snapshot is taken by the server at the moment the token is granted, not
  # here. Taking it before acquiring reads the *previous* holder's overrides and
  # restores those when this region ends, which silently defeats the token:
  # observed on 2026-09-14 as two regions overriding the same key, the second
  # restoring the first's value instead of deleting the key.
  defp acquire(overrides) do
    Enum.each(overrides, &validate_override!/1)
    keys = Enum.map(overrides, fn {app, key, _value} -> {app, key} end)
    {:ok, snapshot} = GenServer.call(__MODULE__, {:acquire, self(), keys}, :infinity)
    Enum.each(overrides, fn {app, key, value} -> Application.put_env(app, key, value) end)
    refresh_caches()
    %{holder: self(), snapshot: snapshot}
  end

  defp release(%{holder: holder, snapshot: snapshot}) do
    Enum.each(snapshot, &restore/1)
    refresh_caches()
    GenServer.call(__MODULE__, {:release, holder})
  end

  defp restore({app, key, {:ok, value}}), do: Application.put_env(app, key, value)
  defp restore({app, key, :error}), do: Application.delete_env(app, key)

  # `:feature_sources` is cached in `:persistent_term` because the `track/4` and
  # `reserve/2,3` guards read it on every call (build unit 03c). The cache is
  # filled by `AuroraMeter.Config.validate!/0`, which runs once at boot, so a
  # region that overrides the key would otherwise change the declaration and not
  # the behaviour, and a region that restored it would leave the previous
  # region's sources in force for the rest of the run.
  #
  # It is called unconditionally rather than only for regions naming that key:
  # the cost is one environment read and a comparison when nothing changed
  # (`refresh!/0` writes the term only when the set actually differs), and a
  # conditional here would be one more place that has to be kept in step with
  # which keys are cached.
  defp refresh_caches, do: AuroraMeter.Config.refresh!()

  defp validate_override!({app, key, _value}) when is_atom(app) and is_atom(key), do: :ok

  defp validate_override!(other) do
    raise ArgumentError,
          "an override must be {application, key, value}, got #{inspect(other)}"
  end

  # -- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok,
     %{
       holder: nil,
       monitor: nil,
       snapshot: [],
       queue: :queue.new(),
       report: @default_report_interval
     }}
  end

  @impl true
  def handle_call({:acquire, pid, keys}, _from, %{holder: nil} = state) do
    state = grant(state, pid, keys)
    {:reply, {:ok, state.snapshot}, state}
  end

  def handle_call({:acquire, pid, keys}, from, state) do
    Process.send_after(self(), {:report, pid}, state.report)
    {:noreply, %{state | queue: :queue.in({from, pid, keys}, state.queue)}}
  end

  def handle_call({:release, pid}, _from, %{holder: pid} = state) do
    {:reply, :ok, next(demonitor(state))}
  end

  def handle_call({:release, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call({:report_interval, ms}, _from, state), do: {:reply, :ok, %{state | report: ms}}

  def handle_call(:holder, _from, state), do: {:reply, state.holder, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %{monitor: ref, holder: pid} = state) do
    Enum.each(state.snapshot, &restore/1)
    refresh_caches()
    {:noreply, next(%{state | holder: nil, monitor: nil, snapshot: []})}
  end

  def handle_info({:report, pid}, state) do
    if waiting?(state.queue, pid), do: log_holder(state, pid)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp grant(state, pid, keys) do
    snapshot = Enum.map(keys, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)
    %{state | holder: pid, monitor: Process.monitor(pid), snapshot: snapshot}
  end

  defp next(state) do
    case :queue.out(state.queue) do
      {{:value, {from, pid, keys}}, queue} ->
        state = grant(%{state | queue: queue}, pid, keys)
        GenServer.reply(from, {:ok, state.snapshot})
        state

      {:empty, queue} ->
        %{state | holder: nil, monitor: nil, snapshot: [], queue: queue}
    end
  end

  defp demonitor(%{monitor: nil} = state), do: state

  defp demonitor(state) do
    Process.demonitor(state.monitor, [:flush])
    %{state | holder: nil, monitor: nil, snapshot: []}
  end

  defp waiting?(queue, pid),
    do: Enum.any?(:queue.to_list(queue), fn {_from, waiter, _keys} -> waiter == pid end)

  defp log_holder(state, waiter) do
    keys = Enum.map(state.snapshot, fn {app, key, _} -> {app, key} end)

    Logger.error("""
    AuroraMeter.Test.Config: #{inspect(waiter)} has waited #{state.report}ms for the \
    configuration token. Current holder: #{inspect(state.holder)} \
    (#{inspect(registered_name(state.holder))}) holding #{inspect(keys)}.\
    """)
  end

  defp registered_name(nil), do: nil

  defp registered_name(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} -> name
      _ -> nil
    end
  end
end
