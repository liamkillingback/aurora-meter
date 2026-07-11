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

  test "Default.to_key/1 raises for a term without String.Chars" do
    assert_raise Protocol.UndefinedError, fn -> Default.to_key(%{a: 1}) end
  end
end
