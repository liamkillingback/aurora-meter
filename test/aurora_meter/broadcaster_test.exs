defmodule AuroraMeter.BroadcasterTest do
  @moduledoc """
  **X348**: a broadcast tick that lands while `AuroraMeter.Store` is not there.

  `AuroraMeter.Broadcaster.do_broadcast/0` opens with
  `AuroraMeter.Counter.touched_keys/0`, which is `:ets.tab2list/1` on a table
  the Store owns. Until repair unit R4, `handle_info(:broadcast, _)` had neither
  a `rescue` nor a `catch` where `AuroraMeter.Flusher.do_flush/1` has both, so a
  tick arriving between a Store crash and its restart raised `:badarg` and took
  the Broadcaster with it. The shipped `broadcast_interval` default is **one
  second**, so a host whose Store crashed had a live chance of it on every
  crash, and enough of those close together exhausted the supervision tree's
  restart intensity and took the buffered deltas in ETS down with it (X354).

  The window is opened here with `Supervisor.terminate_child/2` rather than with
  a kill, for the reason `AuroraMeter.KillTest`'s moduledoc gives: a kill is an
  automatic restart charged against the tree's intensity, and this module is not
  entitled to spend one. Terminating and restarting by hand runs exactly the
  same `init/1` on exactly the same path and leaves the tables exactly as
  absent.
  """

  # async: false: it takes the Store's ETS tables away from the whole VM for the
  # length of one test.
  use AuroraMeter.DataCase, async: false

  import ExUnit.CaptureLog

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Store

  setup do
    on_exit(fn ->
      # Belt and braces: if a test fails partway the tables must still come
      # back, or every later module in the run fails for a reason its author
      # could never find.
      unless Process.whereis(Store) do
        {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)
      end
    end)

    :ok
  end

  test "X348 a tick that meets a missing Store leaves the Broadcaster alive" do
    pid = Process.whereis(Broadcaster)
    assert is_pid(pid)

    # The control on this control: with the Store up, the same tick is served
    # rather than rescued, so a Broadcaster that had simply stopped reading
    # would pass the assertion below for the wrong reason.
    assert reachable?(pid)
    refute_broadcast_error(fn -> tick(pid) end)

    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Store)

    log =
      try do
        refute Process.whereis(Store),
               "the Store is still registered, so the tick below would find its tables and " <>
                 "this test would prove nothing (X325)."

        capture_log(fn -> tick(pid) end)
      after
        {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)
      end

    assert Process.whereis(Broadcaster) == pid,
           "the Broadcaster died on a tick it could not serve and was restarted with a new " <>
             "pid. That is X348: at the shipped one second interval a host whose Store " <>
             "crashes meets this on every crash."

    assert log =~ "AuroraMeter broadcast failed",
           "the tick was swallowed without a word. A rescue that logs nothing is the " <>
             "silent pass this suite keeps finding: the next tick recovers, and nobody " <>
             "ever learns the Store went away."
  end

  test "X348 the next tick after the Store is back publishes what was touched meanwhile" do
    pid = Process.whereis(Broadcaster)

    :ok = Supervisor.terminate_child(AuroraMeter.Supervisor, Store)

    try do
      capture_log(fn -> tick(pid) end)
    after
      {:ok, _pid} = Supervisor.restart_child(AuroraMeter.Supervisor, Store)
    end

    tenant = unique_tenant("bcast")
    :ok = Phoenix.PubSub.subscribe(AuroraMeter.Config.pubsub(), Broadcaster.topic(tenant))
    AuroraMeter.subscribe(tenant, :payg)
    :ok = AuroraMeter.track(tenant, :requests, 4)

    assert Broadcaster.broadcast_now() == :ok

    assert_receive {:aurora_meter, :usage, %{tenant_key: ^tenant, feature: :requests, value: 4}},
                   2_000

    assert Process.whereis(Broadcaster) == pid,
           "the value arrived, but from a Broadcaster the supervisor had to replace. Without " <>
             "this the test passes whether or not the tick was rescued, because a restarted " <>
             "Broadcaster publishes just as well as one that never died."
  end

  # There is deliberately no test here that `broadcast_now/0` refuses to swallow,
  # although it does and the reason is in `broadcaster.ex`. Proving it means
  # making the Broadcaster die, which the supervisor then restarts
  # automatically, and an automatic restart of a child of
  # `AuroraMeter.Supervisor` outside `AuroraMeter.KillTest` is exactly what that
  # module's guard forbids. An assertion is not worth spending a restart budget
  # somebody else is counting.

  # A `:broadcast` message is what the timer sends, and `:sys.get_state/1` is
  # processed after it, so a successful call proves the tick was handled and the
  # process is still there to handle the next one. An exit here is the
  # Broadcaster dying on the tick, which is the defect.
  defp tick(pid) do
    send(pid, :broadcast)
    reachable?(pid)
  end

  defp reachable?(pid) do
    :sys.get_state(pid)
    true
  catch
    :exit, _reason -> false
  end

  defp refute_broadcast_error(fun) do
    log = capture_log(fun)

    refute log =~ "AuroraMeter broadcast failed",
           "a tick with the Store running was rescued, so the assertion that a tick without " <>
             "one is rescued would pass whatever the Broadcaster did."
  end
end
