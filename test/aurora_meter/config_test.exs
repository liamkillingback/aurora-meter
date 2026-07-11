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
end
