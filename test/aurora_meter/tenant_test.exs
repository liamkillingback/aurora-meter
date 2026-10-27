defmodule AuroraMeter.TenantTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Tenant
  alias AuroraMeter.Tenant.Default

  test "to_key/1 passes binaries through unchanged" do
    assert Tenant.to_key("org_123") == "org_123"
  end

  test "to_key/1 stringifies integers" do
    assert Tenant.to_key(42) == "42"
  end

  test "to_key/1 stringifies atoms" do
    assert Tenant.to_key(:acme) == "acme"
  end

  defmodule Scope do
    @moduledoc false
    defstruct [:user]
  end

  test "Default.to_key/1 raises a helpful ArgumentError for a term without String.Chars" do
    error = assert_raise ArgumentError, fn -> Default.to_key(%{a: 1}) end
    assert error.message =~ "cannot turn a map into a tenant key"
    assert error.message =~ "config :aurora_meter, tenant:"
  end

  test "a Phoenix 1.8 style scope struct names the struct and the recipe, not the data" do
    scope = %Scope{user: %{id: 7, email: "private@example.com"}}

    error = assert_raise ArgumentError, fn -> Default.to_key(scope) end

    assert error.message =~ "%AuroraMeter.TenantTest.Scope{} struct"
    assert error.message =~ "@behaviour AuroraMeter.Tenant"
    assert error.message =~ "def to_key(%MyApp.Accounts.Scope{user: %{id: id}})"
    refute error.message =~ "private@example.com"
  end

  test "a struct that implements String.Chars is still stringified" do
    assert Default.to_key(Version.parse!("1.2.3")) == "1.2.3"
  end

  test "the Phoenix 1.8 recipe from the README resolves a scope" do
    defmodule ScopeTenant do
      @behaviour AuroraMeter.Tenant

      @impl true
      def to_key(%AuroraMeter.TenantTest.Scope{user: %{id: id}}), do: "user_#{id}"
      def to_key(key) when is_binary(key), do: key
    end

    assert ScopeTenant.to_key(%Scope{user: %{id: 42}}) == "user_42"
    assert ScopeTenant.to_key("user_42") == "user_42"
  end
end
