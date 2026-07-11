defmodule AuroraMeter.StoreTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Store

  test "owns the counter and dirty ETS tables" do
    refute :ets.info(Store.counters_table()) == :undefined
    refute :ets.info(Store.dirty_table()) == :undefined
  end

  test "the counter table is public and named" do
    info = :ets.info(Store.counters_table())
    assert info[:named_table] == true
    assert info[:protection] == :public
  end
end
