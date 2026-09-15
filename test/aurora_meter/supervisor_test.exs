defmodule AuroraMeter.SupervisorTest do
  @moduledoc false
  # async: false: the boot checks below insert credit balance rows, override
  # the repo and change the Logger level.
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]
  import ExUnit.CaptureLog

  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.CurrencyMismatchError
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Test.Faults

  test "starts the registry, store, cluster, flusher and broadcaster" do
    assert is_pid(Process.whereis(AuroraMeter.Registry))
    assert is_pid(Process.whereis(AuroraMeter.Store))
    assert is_pid(Process.whereis(AuroraMeter.Cluster))
    assert is_pid(Process.whereis(AuroraMeter.Flusher))
    assert is_pid(Process.whereis(AuroraMeter.Broadcaster))
  end

  test "starts a task supervisor for host callbacks, which supervises nothing at rest" do
    # `AuroraMeter.Credits.reconcile_holds/1` runs the host's `decide/1` under
    # this supervisor with `async_nolink`, so a callback that raises cannot take
    # the reconciler with it and one that hangs can be killed.
    pid = Process.whereis(AuroraMeter.TaskSupervisor)
    assert is_pid(pid)
    assert Task.Supervisor.children(pid) == []

    # And a task under it that raises leaves the caller alive. `async_nolink`,
    # because `Task.async/1` links and the raise would take this process down.
    capture_log(fn ->
      task = Task.Supervisor.async_nolink(AuroraMeter.TaskSupervisor, fn -> raise "boom" end)
      assert {:exit, {%RuntimeError{message: "boom"}, _stacktrace}} = Task.yield(task, 5_000)
      assert Process.alive?(self())
    end)
  end

  test "BootChecks is the last child and leaves no process behind" do
    {:ok, {_flags, specs}} = AuroraMeter.Supervisor.init([])

    assert List.last(specs).id == AuroraMeter.BootChecks
    assert Process.whereis(AuroraMeter.BootChecks) == nil
  end

  test "boot succeeds when every balance row matches the configured currency" do
    fund("usd")

    assert Credits.assert_currency!() == :ok
    assert AuroraMeter.BootChecks.start_link([]) == :ignore
    assert Process.whereis(AuroraMeter.BootChecks) == nil
  end

  test "boot fails with CurrencyMismatchError when a balance row has another currency" do
    fund("eur")
    fund("eur")
    fund("usd")

    message = assert_raise(CurrencyMismatchError, fn -> Credits.assert_currency!() end).message

    assert message =~ "credits_currency: \"usd\""
    assert message =~ "\"eur\" on 2 rows"
    assert message =~ "restore the previous credits_currency"
    assert message =~ "migrate the rows deliberately"

    # And the supervisor refuses to start, rather than starting half a tree.
    # Exits are trapped because a failed start also exits the linking process.
    Process.flag(:trap_exit, true)

    {result, _log} =
      with_log(fn -> Supervisor.start_link([AuroraMeter.BootChecks], strategy: :one_for_one) end)

    assert {:error, {:shutdown, {:failed_to_start_child, AuroraMeter.BootChecks, reason}}} =
             result

    assert {:EXIT, {%CurrencyMismatchError{stored: [{"eur", 2}]}, _stacktrace}} = reason
  end

  test "boot succeeds and logs at info when the credit tables cannot be read" do
    fund("usd")

    log =
      at_info(fn ->
        with_config([{:aurora_meter, :repo, AuroraMeter.Test.FaultRepo}], fn ->
          Faults.arm(:before_commit, :raise,
            when: &(&1[:kind] == :read and &1[:schema] == CreditBalance),
            label: :credit_tables_absent
          )

          assert Credits.assert_currency!() == :ok
          Faults.assert_fired!(:before_commit)
        end)
      end)

    assert log =~ "credit currency check skipped"
  end

  test "boot succeeds and logs at info when the repo is not available at all" do
    log =
      at_info(fn ->
        with_config([{:aurora_meter, :repo, AuroraMeter.NoSuchRepo}], fn ->
          assert Credits.assert_currency!() == :ok
        end)
      end)

    assert log =~ "credit currency check skipped"
  end

  defp fund(currency) do
    TestRepo.insert!(%CreditBalance{
      tenant_key: unique_tenant(),
      balance: 0,
      held: 0,
      promotional: 0,
      currency: currency
    })
  end

  # The package's test configuration pins Logger at :warning so the suite's
  # output stays readable; the skip path reports at :info, so this test raises
  # the level for the duration and puts it back.
  defp at_info(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: level)
    end
  end
end
