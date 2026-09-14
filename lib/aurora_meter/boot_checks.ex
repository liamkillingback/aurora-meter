defmodule AuroraMeter.BootChecks do
  @moduledoc false
  # The checks that need the rest of the tree to be up.
  #
  # `AuroraMeter.Config.validate!/0` runs before any process exists and can only
  # look at configuration. Anything that has to read the database belongs here
  # instead, as the last child of `AuroraMeter.Supervisor`.
  #
  # `start_link/1` returns `:ignore`, so the supervisor runs the checks and then
  # leaves no process behind. Raising inside it makes `Supervisor.start_link/1`
  # fail and tear down the children it already started, which is the right
  # outcome for a misconfigured host: a half-started tree that meters against a
  # wallet set it cannot reconcile is worse than no tree at all.

  alias AuroraMeter.Credits

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc false
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts) do
    Credits.assert_currency!()
    :ignore
  end
end
