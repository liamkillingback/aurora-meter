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

  @doc """
  An instant inside `tenant`'s current period and not in the future, with
  microsecond precision: one second before now, or the period start when the
  period began less than a second ago. For fixtures that need "a recent event"
  without depending on the date the test was written.
  """
  @spec instant_in_current_period(String.t()) :: DateTime.t()
  def instant_in_current_period(tenant) do
    start = AuroraMeter.period(tenant).start
    candidate = DateTime.add(AuroraMeter.Clock.now(), -1, :second)
    at = if DateTime.compare(candidate, start) == :lt, do: start, else: candidate
    %{DateTime.truncate(at, :microsecond) | microsecond: {elem(at.microsecond, 0), 6}}
  end

  @doc "A process-unique tenant key, so tests can share the global ETS tables safely."
  @spec unique_tenant(String.t()) :: String.t()
  def unique_tenant(prefix \\ "org") do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
