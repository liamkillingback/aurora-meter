defmodule AuroraMeter.SupervisorTest do
  @moduledoc false
  use ExUnit.Case, async: true

  test "starts the registry, store, cluster, flusher and broadcaster" do
    assert is_pid(Process.whereis(AuroraMeter.Registry))
    assert is_pid(Process.whereis(AuroraMeter.Store))
    assert is_pid(Process.whereis(AuroraMeter.Cluster))
    assert is_pid(Process.whereis(AuroraMeter.Flusher))
    assert is_pid(Process.whereis(AuroraMeter.Broadcaster))
  end
end
