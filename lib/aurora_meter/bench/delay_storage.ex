defmodule AuroraMeter.Bench.DelayStorage do
  @moduledoc false

  # `AuroraMeter.Storage.Ecto` with a configurable delay in front of every
  # callback, and an outage switch in front of `flush_batch/3`.
  #
  # The `db_delay` mode uses the delay: a slow database is not an unavailable
  # one, and the behaviour it produces (a dirty set that grows because the
  # flusher cannot keep up) is a different failure from the outage the
  # `db_recovery` mode measures.
  #
  # The outage switch exists for the **negative control** of the outage
  # measurement, not for the measurement itself. `db_recovery`'s own outage is a
  # real `docker stop`, orchestrated by `scripts/v1/bench.sh`, because a
  # simulated refusal proves the flusher retries and proves nothing at all about
  # what Postgres does when it comes back.
  #
  # State lives in `:persistent_term`: the callback runs inside
  # `AuroraMeter.Flusher`, which shares no process state with the caller.

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Clock
  alias AuroraMeter.Storage.Ecto, as: Backend

  @delay {__MODULE__, :delay_us}
  @outage {__MODULE__, :outage}

  @doc "Delays every storage callback by `us` microseconds."
  @spec delay(non_neg_integer()) :: :ok
  def delay(us) when is_integer(us) and us >= 0, do: :persistent_term.put(@delay, us)

  @doc "The configured delay in microseconds."
  @spec delay_us() :: non_neg_integer()
  def delay_us, do: :persistent_term.get(@delay, 0)

  @doc "Refuses every `flush_batch/3` until `resume/0`."
  @spec outage() :: :ok
  def outage, do: :persistent_term.put(@outage, true)

  @doc "Ends a simulated outage."
  @spec resume() :: :ok
  def resume, do: :persistent_term.put(@outage, false)

  @doc "Whether a simulated outage is armed."
  @spec outage?() :: boolean()
  def outage?, do: :persistent_term.get(@outage, false)

  @impl AuroraMeter.Storage
  def flush_batch(id, counters, history) do
    sleep()

    if outage?() do
      {:error, :bench_simulated_outage}
    else
      Backend.flush_batch(id, counters, history)
    end
  end

  for {name, arity} <- AuroraMeter.Storage.behaviour_info(:callbacks),
      {name, arity} != {:flush_batch, 3} do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl AuroraMeter.Storage
    def unquote(name)(unquote_splicing(args)) do
      sleep()
      Backend.unquote(name)(unquote_splicing(args))
    end
  end

  # `:timer.sleep/1` has millisecond resolution and the delays this mode is
  # about are smaller than that, so a busy wait on the monotonic clock is the
  # only reading that means what it says. It burns a scheduler, which is exactly
  # what a synchronous storage call does to the caller anyway.
  defp sleep do
    case delay_us() do
      0 ->
        :ok

      us ->
        spin(Clock.monotonic_native() + :erlang.convert_time_unit(us, :microsecond, :native))
    end
  end

  defp spin(deadline) do
    if Clock.monotonic_native() < deadline do
      spin(deadline)
    else
      :ok
    end
  end
end
