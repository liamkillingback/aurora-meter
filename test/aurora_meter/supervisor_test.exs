defmodule AuroraMeter.SupervisorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "starts the registry, store, flusher and broadcaster" do
    assert is_pid(Process.whereis(AuroraMeter.Registry))
    assert is_pid(Process.whereis(AuroraMeter.Store))
    assert is_pid(Process.whereis(AuroraMeter.Flusher))
    assert is_pid(Process.whereis(AuroraMeter.Broadcaster))
  end
end
