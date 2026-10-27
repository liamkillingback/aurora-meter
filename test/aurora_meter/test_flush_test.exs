defmodule AuroraMeter.TestFlushTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias AuroraMeter.Test, as: AuroraTest

  @ownership "cannot find ownership process for #PID<0.1.0> (AuroraMeter.Flusher)"

  test "an ownership failure names the sandbox allowance and shared mode, with the real repo" do
    message = AuroraTest.flush_failure_message(@ownership)

    assert message =~ "AuroraMeter.Flusher process has no connection in the Ecto SQL sandbox"

    assert message =~
             "Ecto.Adapters.SQL.Sandbox.allow(AuroraMeter.TestRepo, self(), Process.whereis(AuroraMeter.Flusher))"

    assert message =~ "Ecto.Adapters.SQL.Sandbox.mode(AuroraMeter.TestRepo, {:shared, self()})"
    assert message =~ @ownership
  end

  test "the exception struct form is recognised too" do
    message =
      AuroraTest.flush_failure_message(%{__exception__: true, kind: DBConnection.OwnershipError})

    assert message =~ "Sandbox.allow"
  end

  test "any other failure is reported as it is, without the sandbox advice" do
    message = AuroraTest.flush_failure_message({:error, :timeout})
    assert message =~ "failed; the batch stays pending"
    refute message =~ "Sandbox"
  end
end
