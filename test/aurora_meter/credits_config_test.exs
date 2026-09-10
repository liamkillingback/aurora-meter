defmodule AuroraMeter.CreditsConfigTest do
  @moduledoc false
  # async: false — these tests change the application environment.
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test, only: [fund!: 2]

  alias AuroraMeter.Config
  alias AuroraMeter.Credits

  defp put_env(key, value) do
    Application.put_env(:aurora_meter, key, value)
    on_exit(fn -> Application.delete_env(:aurora_meter, key) end)
  end

  test "credit config defaults and validation" do
    assert Config.credits_currency() == "usd"
    assert Config.credits_overdraft_tolerance() == 0
    assert Config.credits_low_balance_threshold() == nil
    assert Config.credits_low_balance_handler() == nil
    assert Keyword.get(Config.validate!(), :credits_currency) == "usd"

    put_env(:credits_low_balance_handler, fn -> :arity_zero end)
    assert_raise NimbleOptions.ValidationError, fn -> Config.validate!() end
  end

  test ":credits_overdraft_tolerance lets a hold or debit dip below zero by that much" do
    put_env(:credits_overdraft_tolerance, 250_000)
    tenant = unique_tenant()
    fund!(tenant, 1_000_000)

    assert Credits.sufficient?(tenant, 1_250_000)
    refute Credits.sufficient?(tenant, 1_250_001)
    assert {:error, :insufficient_credits} = Credits.hold(tenant, 1_250_001, "a:#{tenant}")
    assert {:ok, _} = Credits.hold(tenant, 1_250_000, "a:#{tenant}")
    assert %{available: -250_000} = Credits.balance(tenant)
    assert {:error, :insufficient_credits} = Credits.debit(tenant, 1, "b:#{tenant}")
  end

  test ":credits_low_balance_threshold and :credits_low_balance_handler fire once per crossing" do
    parent = self()
    put_env(:credits_low_balance_threshold, 500_000)
    put_env(:credits_low_balance_handler, fn event -> send(parent, {:low, event}) end)

    tenant = unique_tenant()
    fund!(tenant, 1_000_000)
    {:ok, _} = Credits.debit(tenant, 600_000, "d1:#{tenant}")
    assert_receive {:low, %{tenant_key: ^tenant, available: 400_000, threshold: 500_000}}

    {:ok, _} = Credits.debit(tenant, 100_000, "d2:#{tenant}")
    refute_receive {:low, _}

    # A row threshold overrides the configured one.
    other = unique_tenant()
    {:ok, _} = Credits.set_low_balance_threshold(other, 100_000)
    fund!(other, 1_000_000)
    {:ok, _} = Credits.debit(other, 600_000, "d1:#{other}")
    refute_receive {:low, %{tenant_key: ^other}}
    {:ok, _} = Credits.debit(other, 350_000, "d2:#{other}")
    assert_receive {:low, %{tenant_key: ^other, available: 50_000, threshold: 100_000}}
  end

  test "new balance rows take :credits_currency" do
    put_env(:credits_currency, "eur")
    tenant = unique_tenant()
    assert Credits.balance(tenant).currency == "eur"
    fund!(tenant, 1)
    assert Credits.balance(tenant).currency == "eur"
  end
end
