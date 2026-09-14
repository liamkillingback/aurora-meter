defmodule AuroraMeter.Test.RecordingOutbox do
  @moduledoc """
  An `AuroraMeter.Events.Outbox` that records every item it is handed, and can
  be told to fail (build unit 03b).

  Agent-backed, never the process dictionary: the enqueue runs inside the
  record transaction, which may be on a different process from the test (a
  task on its own connection), and process-dictionary state is invisible from
  there. 01b fixed the same shape in the Stripe fakes.

      RecordingOutbox.start!()
      with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn -> ... end)
      assert [%{event: event, eligibility: :eligible}] = RecordingOutbox.items()

  `fail!/1` makes the next `enqueue/2` return `{:error, reason}`, and
  `raise!/1` makes it raise. Both roll the caller's `record/4` back, which is
  the contract: an outbox that cannot stage the intent must not let the fact
  commit without it.
  """

  @behaviour AuroraMeter.Events.Outbox

  @doc "Starts (or resets) the recorder. Safe to call in every `setup`."
  @spec start!() :: :ok
  def start! do
    case Agent.start_link(fn -> %{items: [], calls: 0, mode: :ok} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset!()
    end
  end

  @doc "Forgets every recorded item and clears any failure mode."
  @spec reset!() :: :ok
  def reset!, do: Agent.update(__MODULE__, fn _state -> %{items: [], calls: 0, mode: :ok} end)

  @doc "Every item handed to `enqueue/2` since the last reset, in order."
  @spec items() :: [AuroraMeter.Events.Outbox.item()]
  def items, do: Agent.get(__MODULE__, & &1.items)

  @doc "How many times `enqueue/2` has been called since the last reset."
  @spec calls() :: non_neg_integer()
  def calls, do: Agent.get(__MODULE__, & &1.calls)

  @doc "Makes the next `enqueue/2` return `{:error, reason}`."
  @spec fail!(term()) :: :ok
  def fail!(reason \\ :staging_unavailable),
    do: Agent.update(__MODULE__, &%{&1 | mode: {:error, reason}})

  @doc "Makes the next `enqueue/2` raise."
  @spec raise!(String.t()) :: :ok
  def raise!(message \\ "outbox exploded"),
    do: Agent.update(__MODULE__, &%{&1 | mode: {:raise, message}})

  @doc "Whether the recorder is running."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @impl AuroraMeter.Events.Outbox
  @spec enqueue([AuroraMeter.Events.Outbox.item()], AuroraMeter.Events.Outbox.context()) ::
          :ok | {:error, term()}
  def enqueue(items, context) do
    mode =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.mode, %{state | items: state.items ++ items, calls: state.calls + 1, mode: :ok}}
      end)

    # The contract says to use the repo you are given and to open no connection
    # of your own. Asserting the shape here means every test that stages an
    # intent also checks that the seam handed one over.
    %{repo: repo, timeout: timeout} = context
    true = is_atom(repo) and is_integer(timeout)

    case mode do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      {:raise, message} -> raise message
    end
  end
end
