defmodule AuroraMeter.Test.FailingSeedStorage do
  @moduledoc """
  An `AuroraMeter.Storage` shim whose `load_counter/3` raises a real
  `DBConnection.ConnectionError` while armed (build unit 09a).

  It exists for the two halves of one question about
  `AuroraMeter.Plug.EnsureEntitled`, and neither sibling could answer it.
  `AuroraMeter.Test.FaultStorage` raises `AuroraMeter.Test.Faults.Injected`,
  which is a test-support exception rather than the one a real outage produces,
  and `AuroraMeter.Test.RefusingStorage` returns an error tuple from
  `flush_batch/3` only. What the plug has to classify is an exception escaping
  the storage adapter on the cold-seed path, and the exception a database that
  has gone away actually raises is `DBConnection.ConnectionError`.

  The two halves:

    * armed, `mode: :check` reaches `Counter.ensure_seeded/1` on a cold counter,
      the adapter raises, and the plug must answer 503 rather than let the
      exception reach the host;
    * armed, `mode: :entitled?` must pass **because it never reads a counter**.
      That claim is only worth something if the same arming makes the other mode
      fail, which is why the two are written as a pair and why `calls/0` is
      here: the `:entitled?` case asserts zero, and its control asserts one.

  Like `AuroraMeter.Test.RefusingStorage`, the state lives in `:persistent_term`
  rather than in a process, and every other callback is delegated by generating
  one clause per entry of `AuroraMeter.Storage.behaviour_info(:callbacks)`, so a
  callback added to the behaviour later is delegated the day it is added.
  """

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Storage.Ecto, as: Backend

  @armed {__MODULE__, :armed}
  @calls {__MODULE__, :calls}

  @doc "Make every `load_counter/3` raise, and reset the call count."
  @spec arm() :: :ok
  def arm do
    :persistent_term.put(@calls, 0)
    :persistent_term.put(@armed, true)
  end

  @doc "Stop failing, and reset the call count."
  @spec disarm() :: :ok
  def disarm do
    :persistent_term.put(@armed, false)
    :persistent_term.put(@calls, 0)
  end

  @doc "How many times `load_counter/3` has been called since the last arming."
  @spec calls() :: non_neg_integer()
  def calls, do: :persistent_term.get(@calls, 0)

  @impl AuroraMeter.Storage
  def load_counter(tenant_key, feature, period_start) do
    :persistent_term.put(@calls, calls() + 1)

    if :persistent_term.get(@armed, false) do
      raise DBConnection.ConnectionError,
            "connection not available (injected by AuroraMeter.Test.FailingSeedStorage)"
    end

    Backend.load_counter(tenant_key, feature, period_start)
  end

  for {name, arity} <- AuroraMeter.Storage.behaviour_info(:callbacks),
      {name, arity} != {:load_counter, 3} do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl AuroraMeter.Storage
    def unquote(name)(unquote_splicing(args)) do
      Backend.unquote(name)(unquote_splicing(args))
    end
  end
end
