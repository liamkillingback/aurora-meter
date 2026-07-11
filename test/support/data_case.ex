defmodule AuroraMeter.DataCase do
  @moduledoc """
  Test case for code that touches the database.

  Uses the Ecto SQL sandbox. Non-async tests run in shared mode so that the
  Aurora Meter background processes (flusher, broadcaster) see the same
  connection; async tests get an isolated owner.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Query
      import AuroraMeter.DataCase

      alias AuroraMeter.TestRepo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(AuroraMeter.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "A process-unique tenant key, so tests can share the global ETS tables safely."
  @spec unique_tenant(String.t()) :: String.t()
  def unique_tenant(prefix \\ "org") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
