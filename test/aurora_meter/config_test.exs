defmodule AuroraMeter.ConfigTest do
  @moduledoc false
  # async: false — some tests mutate the application environment.
  use ExUnit.Case, async: false

  alias AuroraMeter.Config

  test "validate!/0 returns the validated options for the test config" do
    opts = Config.validate!()
    assert opts[:repo] == AuroraMeter.TestRepo
    assert opts[:pubsub] == AuroraMeter.TestPubSub
    assert opts[:plans] == AuroraMeter.TestPlans
  end

  test "accessors reflect config and defaults" do
    assert Config.repo() == AuroraMeter.TestRepo
    assert Config.pubsub() == AuroraMeter.TestPubSub
    assert Config.plans() == AuroraMeter.TestPlans
    assert Config.tenant() == AuroraMeter.Tenant.Default
    assert Config.default_plan() == :free
    assert Config.storage() == AuroraMeter.Storage.Ecto
    assert Config.provider() == AuroraMeter.Billing.Noop
    assert Config.period_source() == AuroraMeter.Period.Calendar
    assert Config.durable_features() == []
    assert Config.flush_interval() == 60_000
    assert Config.broadcast_interval() == 60_000
  end

  test "validate!/0 raises when a required key is missing" do
    original = Application.get_env(:aurora_meter, :repo)
    Application.delete_env(:aurora_meter, :repo)
    on_exit(fn -> Application.put_env(:aurora_meter, :repo, original) end)

    assert_raise NimbleOptions.ValidationError, fn -> Config.validate!() end
  end

  test "validate!/0 raises when a key has the wrong type" do
    original = Application.get_env(:aurora_meter, :flush_interval)
    Application.put_env(:aurora_meter, :flush_interval, "nope")
    on_exit(fn -> Application.put_env(:aurora_meter, :flush_interval, original) end)

    assert_raise NimbleOptions.ValidationError, fn -> Config.validate!() end
  end

  describe "credits_hold_reconciler" do
    test "defaults to nil, which is what keeps every hold" do
      assert Config.credits_hold_reconciler() == nil
      assert Config.credits_hold_reconciler_timeout() == 5_000
    end

    test "accepts a module, a {module, function} pair and a one-argument function" do
      for value <- [
            AuroraMeter.ConfigTest.Reconciler,
            {AuroraMeter.ConfigTest.Reconciler, :decide},
            fn _hold -> :keep end,
            nil
          ] do
        with_config(:credits_hold_reconciler, value, fn ->
          assert is_list(Config.validate!())
          assert Config.credits_hold_reconciler() == value
        end)
      end
    end

    test "refuses a module that does not implement the behaviour" do
      with_config(:credits_hold_reconciler, AuroraMeter.ConfigTest, fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message
        assert message =~ "credits_hold_reconciler"
        assert message =~ "decide/1"
      end)
    end

    test "refuses a module that does not exist" do
      with_config(:credits_hold_reconciler, AuroraMeter.NoSuchReconciler, fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message
        assert message =~ "could not be loaded"
      end)
    end

    test "refuses a {module, function} pair whose function is not exported" do
      with_config(:credits_hold_reconciler, {AuroraMeter.ConfigTest.Reconciler, :nope}, fn ->
        message = assert_raise(ArgumentError, fn -> Config.validate!() end).message
        assert message =~ "does not export nope/1"
      end)
    end

    test "refuses a function of the wrong arity" do
      with_config(:credits_hold_reconciler, fn _a, _b -> :keep end, fn ->
        assert_raise NimbleOptions.ValidationError, fn -> Config.validate!() end
      end)
    end

    test "refuses a timeout that is not a positive integer" do
      for bad <- [0, -1, "5000", 5.0] do
        with_config(:credits_hold_reconciler_timeout, bad, fn ->
          assert_raise NimbleOptions.ValidationError, fn -> Config.validate!() end
        end)
      end
    end
  end

  # This file predates `AuroraMeter.Test.Config` and mutates the environment
  # directly in the tests above; the new cases keep the same shape rather than
  # mixing two conventions inside one module, and every one of them restores
  # what it found, including deleting a key that was absent.
  defp with_config(key, value, fun) do
    original = Application.fetch_env(:aurora_meter, key)
    Application.put_env(:aurora_meter, key, value)

    try do
      fun.()
    after
      case original do
        {:ok, previous} -> Application.put_env(:aurora_meter, key, previous)
        :error -> Application.delete_env(:aurora_meter, key)
      end
    end
  end
end

defmodule AuroraMeter.ConfigTest.Reconciler do
  @moduledoc false
  @behaviour AuroraMeter.Credits.HoldReconciler

  @impl AuroraMeter.Credits.HoldReconciler
  def decide(_hold), do: :keep
end
