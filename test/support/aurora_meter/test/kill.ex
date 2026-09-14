defmodule AuroraMeter.Test.Kill do
  @moduledoc """
  Kills a worker at a chosen fault point and observes the death (build unit
  01b).

  Before this module no test in either suite called `Process.exit(pid, :kill)`
  (`open-findings.md` T1). Death was simulated by editing rows back to what the
  author believed a crash would have left, which is the assumption under test.

      {:killed, pid} = Kill.run(fn -> AuroraMeter.Storage.flush_batch(id, c, h) end,
                                at: :before_commit)

      Kill.assert_db!(fn -> assert AuroraMeter.Storage.load_counter(t, :ops, p) == nil end)

  `run/2` fails the test when the worker returned normally although a kill was
  armed, and when the death reason is anything other than exactly `:killed`.
  That distinction is G01 bullet 2: an untrappable kill is not a catchable
  callback exit, and a test that cannot tell them apart proves nothing about
  either.

  `run/2` deliberately offers no cleanup callback. A killed process runs no
  `after` and no `on_exit`; giving the harness one would let a test prove a
  cleanup production does not perform. Cleanup is the enclosing
  `AuroraMeter.Test.Connections.cleanup!/1`.

  `await_restart!/2` is the other half, added by build unit 01c. After killing a
  supervised *named* process a test cannot continue until the supervisor has put
  a new one in the registry, and there is no OTP event that says so.

      pid = Process.whereis(AuroraMeter.Store)
      Process.exit(pid, :kill)
      Kill.await_restart!(AuroraMeter.Store, from: pid)
  """

  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.Faults
  alias Ecto.Adapters.SQL.Sandbox

  @default_timeout 30_000
  @default_restart_timeout 2_000
  @poll 1
  @supervisor AuroraMeter.Supervisor

  @doc """
  Runs `fun` in a supervised task and waits for it to die or return.

  Options: `:at` (the fault point to arm with `:exit_kill_self`; without it no
  fault is armed and the control case returns `{:completed, value}`), `:when`,
  `:count`, `:label` (passed to `AuroraMeter.Test.Faults.arm/3`),
  `:supervisor` and `:timeout` (default #{@default_timeout} ms).
  """
  @spec run((-> term()), keyword()) :: {:killed, pid()} | {:completed, term()}
  def run(fun, opts \\ []) do
    point = Keyword.get(opts, :at)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    if point, do: arm(point, opts)

    case Keyword.fetch(opts, :supervisor) do
      {:ok, supervisor} ->
        await(supervisor, fun, point, timeout)

      :error ->
        {:ok, supervisor} = Task.Supervisor.start_link()

        try do
          await(supervisor, fun, point, timeout)
        after
          Supervisor.stop(supervisor)
        end
    end
  end

  @doc """
  Runs `fun` on one independent, non-sandbox connection and returns its value.

  After a kill the only trustworthy state is what the database says: the
  worker's own connection was returned when it died and its transaction rolled
  back by Postgres.
  """
  @spec assert_db!((-> result)) :: result when result: term()
  def assert_db!(fun) do
    own = Connections.checkout!()

    try do
      fun.()
    after
      if own, do: Sandbox.checkin(Connections.repo())
    end
  end

  @doc """
  Waits for a supervised named process to be replaced by a *different* pid, and
  returns the new one.

  Options: `:from` (the pid to wait past; defaults to whatever is registered
  when this is called), `:timeout` (default #{@default_restart_timeout} ms) and
  `:supervisor` (named in the timeout message; default
  `AuroraMeter.Supervisor`). An integer in place of the keyword list is read as
  the timeout.

  Pass `:from` whenever the kill has already happened. A supervisor can restart
  a child before the test process is scheduled again, and the default would then
  be waiting for the replacement to be replaced.

  There is no OTP event for "a supervisor restarted a child", so after the old
  pid's monitor reports it down this polls `Process.whereis/1` every
  #{@poll} ms. The poll is bounded, its outcome is deterministic, and a timeout
  raises naming both pids and `Supervisor.which_children/1` rather than failing
  later somewhere unrelated.

  A registered pid is not yet a *usable* process. `:gen_server` registers the
  name before it calls `init/1`, and `AuroraMeter.Store` creates its five ETS
  tables inside `init/1`, so a test that returned on `Process.whereis/1` alone
  could read `:aurora_meter_flush_batches` before it existed and fail with
  "the table identifier does not refer to an existing ETS table". This waits
  for the new process to answer a synchronous system call, which a `GenServer`
  does not do until `init/1` has returned. A process that is not an OTP process
  cannot be waited on this way and is returned as soon as it is registered.
  """
  @spec await_restart!(atom(), keyword() | timeout()) :: pid()
  def await_restart!(name, opts \\ [])

  def await_restart!(name, timeout) when is_integer(timeout),
    do: await_restart!(name, timeout: timeout)

  def await_restart!(name, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_restart_timeout)
    supervisor = Keyword.get(opts, :supervisor, @supervisor)
    old = Keyword.get_lazy(opts, :from, fn -> Process.whereis(name) end)
    deadline = System.monotonic_time(:millisecond) + timeout
    if is_pid(old), do: await_down(old, timeout)
    poll_restart!(name, old, deadline, timeout, supervisor)
  end

  # Bounded, because the pid may be one that is never going to die: falling
  # through to the poll makes that a named failure rather than a hang.
  defp await_down(pid, timeout) do
    reference = Process.monitor(pid)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(reference, [:flush])
        :timeout
    end
  end

  defp poll_restart!(name, old, deadline, timeout, supervisor) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        ready!(pid, max(deadline - System.monotonic_time(:millisecond), 1))

      current ->
        if System.monotonic_time(:millisecond) >= deadline do
          restart_timeout!(name, old, current, timeout, supervisor)
        else
          # The one sanctioned sleep in this module, and the reason is written
          # down: nothing in OTP announces a restart, so the alternative is a
          # single sleep long enough to "probably" be enough, which is the kind
          # of assumption this harness exists to remove.
          Process.sleep(@poll)
          poll_restart!(name, old, deadline, timeout, supervisor)
        end
    end
  end

  defp ready!(pid, timeout) do
    :sys.get_state(pid, timeout)
    pid
  catch
    :exit, _reason -> pid
  end

  defp restart_timeout!(name, old, current, timeout, supervisor) do
    raise ExUnit.AssertionError,
      message:
        "#{inspect(name)} was not restarted within #{timeout}ms: it was #{inspect(old)} and " <>
          "is now #{inspect(current)}. Children of #{inspect(supervisor)}: " <>
          "#{inspect(children(supervisor))}"
  end

  defp children(supervisor) do
    Supervisor.which_children(supervisor)
  rescue
    _error -> :unavailable
  catch
    :exit, reason -> {:exit, reason}
  end

  defp arm(point, opts) do
    Faults.arm(
      point,
      :exit_kill_self,
      Keyword.merge(
        [owner: self(), count: 1],
        Keyword.take(opts, [:when, :count, :label])
      )
    )
  end

  # Task.Supervisor.start_child rather than async_nolink: the worker's own
  # monitor and reply message keep the :DOWN reason exactly as the VM reported
  # it, where Task.await would translate it into a caller exit and lose the
  # distinction this module exists to make.
  defp await(supervisor, fun, point, timeout) do
    parent = self()

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        send(parent, {:aurora_kill_result, self(), fun.()})
      end)

    reference = Process.monitor(pid)

    try do
      receive do
        {:aurora_kill_result, ^pid, value} ->
          Process.demonitor(reference, [:flush])
          completed!(point, value)

        {:DOWN, ^reference, :process, ^pid, reason} ->
          killed!(point, pid, reason)
      after
        timeout ->
          raise "#{inspect(__MODULE__)}.run/2: the worker neither died nor returned in #{timeout}ms"
      end
    after
      if point, do: Faults.disarm(point)
    end
  end

  defp killed!(_point, pid, :killed), do: {:killed, pid}

  defp killed!(point, pid, reason) do
    raise ExUnit.AssertionError,
      message:
        "expected the worker #{inspect(pid)} armed to die at #{inspect(point)} to be killed " <>
          "with an untrappable :kill, but it exited with #{inspect(reason)}. A catchable exit " <>
          "is not process death."
  end

  defp completed!(nil, value), do: {:completed, value}

  defp completed!(point, value) do
    raise ExUnit.AssertionError,
      message:
        "expected the worker to be killed at #{inspect(point)}, but it returned " <>
          "#{inspect(value)}. The fault was never reached, so nothing about process death " <>
          "was proven. Fired: #{inspect(Enum.map(Faults.fired(), &elem(&1, 0)))}"
  end
end
