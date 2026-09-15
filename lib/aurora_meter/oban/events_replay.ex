if Code.ensure_loaded?(Oban) do
  defmodule AuroraMeter.Oban.EventsReplay do
    @moduledoc """
    Runs `AuroraMeter.Events.Replay.run/1` as a job, for an operator who would
    rather not hold an `iex` session open for an hour.

    **It has no schedule and `AuroraMeter.Oban.cron_entries/1` never returns
    it.** Rebuilding a projection generation is a deliberate act with a
    checkpoint behind it, not something that should begin because a minute
    elapsed. Enqueue it by hand:

        %{"batch_size" => 5_000, "activate" => false}
        |> AuroraMeter.Oban.EventsReplay.new()
        |> Oban.insert()

    `max_attempts: 1`, and that is the point of running it here rather than
    under a worker that retries. A replay resumes from its own checkpoint, so an
    automatic retry of a run an operator started would continue work they may
    have stopped on purpose. A failed job is visible, and the next `run/1`
    carries on from the cursor.

    ## Job arguments

    Every option `AuroraMeter.Events.Replay.run/1` takes, as a string key:
    `"batch_size"`, `"compare"` (`"require_match"` or `"report"`),
    `"activate"`, `"resume"`, `"generation"`, `"compare_limit"`,
    `"max_batches"`, `"rehydrate"` and `"timeout"`.

    A paused replay returns `{:ok, status}` from the job: the run stopped
    cleanly at a batch boundary and everything is in place for the next one.
    """

    use Oban.Worker, queue: :aurora_meter, max_attempts: 1

    alias AuroraMeter.Events.Replay

    @integer_keys ~w(batch_size generation compare_limit max_batches timeout)
    @boolean_keys ~w(activate resume rehydrate)

    @doc """
    Runs one replay and returns `{:ok, report}`, `{:ok, status}` for a paused
    run, or `{:error, reason}`.

    ## Examples

        {:ok, report} =
          AuroraMeter.Oban.EventsReplay.perform(%Oban.Job{args: %{"activate" => false}})

    """
    @impl Oban.Worker
    @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:cancel, term()}
    def perform(%Oban.Job{args: args}) do
      args
      |> options()
      |> Replay.run()
      |> translate()
      |> AuroraMeter.Oban.result()
    end

    @doc false
    # A paused run is a success carrying a status, not the three-element result
    # the generic mapping would call unexpected. Public so it can be exercised
    # without standing up a replay: a branch no test can reach is a branch
    # nothing knows the shape of (`open-findings.md` X182).
    @spec translate(term()) :: term()
    def translate({:ok, :paused, status}), do: {:ok, Map.put(status, :paused, true)}
    def translate(other), do: other

    @doc false
    @spec options(map()) :: keyword()
    def options(args) when is_map(args) do
      Enum.flat_map(args, fn
        {"compare", value} -> [compare: String.to_existing_atom(value)]
        {key, value} when key in @integer_keys -> [{String.to_existing_atom(key), value}]
        {key, value} when key in @boolean_keys -> [{String.to_existing_atom(key), value}]
        _ -> []
      end)
    end
  end
end
