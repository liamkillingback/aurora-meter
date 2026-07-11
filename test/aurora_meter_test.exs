defmodule AuroraMeterTest do
  @moduledoc false
  use ExUnit.Case, async: true

  doctest AuroraMeter

  test "version/0 returns a non-empty binary" do
    version = AuroraMeter.version()
    assert is_binary(version)
    assert version != ""
  end
end
