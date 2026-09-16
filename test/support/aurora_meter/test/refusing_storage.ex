defmodule AuroraMeter.Test.RefusingStorage do
  @moduledoc """
  An `AuroraMeter.Storage` shim whose `flush_batch/3` **returns** `{:error, _}`
  for a set number of calls and then delegates like everything else.

  `AuroraMeter.Test.FaultStorage` can make a callback raise; it cannot make one
  return an error tuple, and the two are different paths through
  `:telemetry.span/3`: a raise is `:exception` and re-raised, an error tuple is
  `:stop` carrying `result: :error`. The flush span's contract distinguishes
  them, so a test of that contract needs both.

  Every other callback is delegated by generating one clause per entry of
  `AuroraMeter.Storage.behaviour_info(:callbacks)`, so a callback added to the
  behaviour later is delegated the day it is added rather than when somebody
  remembers this file.

  The counter lives in `:persistent_term` rather than in a process, because the
  callback runs inside `AuroraMeter.Flusher`, which shares no state with the
  test process.
  """

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Storage.Ecto, as: Backend

  @key {__MODULE__, :refusals}

  @doc "Refuse the next `n` flush batches, then behave normally."
  @spec refuse(non_neg_integer()) :: :ok
  def refuse(n) when is_integer(n) and n >= 0, do: :persistent_term.put(@key, n)

  @doc "How many refusals are still armed."
  @spec remaining() :: non_neg_integer()
  def remaining, do: :persistent_term.get(@key, 0)

  @impl AuroraMeter.Storage
  def flush_batch(id, counters, history) do
    case remaining() do
      n when n > 0 ->
        :persistent_term.put(@key, n - 1)
        {:error, :refused_by_test}

      _none ->
        Backend.flush_batch(id, counters, history)
    end
  end

  for {name, arity} <- AuroraMeter.Storage.behaviour_info(:callbacks),
      {name, arity} != {:flush_batch, 3} do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl AuroraMeter.Storage
    def unquote(name)(unquote_splicing(args)) do
      Backend.unquote(name)(unquote_splicing(args))
    end
  end
end
