defmodule AuroraMeter.Operations do
  @moduledoc """
  Pause, resume and cursors for Aurora Meter's scheduled operations.

  This is the operator surface. An operation is a named, resumable task: the
  credit expiry sweep, the hold reconciler, Aurora Meter Pro's usage reporter.
  Each one keeps a single row in `aurora_meter_checkpoints` holding where it got
  to (`cursor`), what it has done (`counts`) and whether an operator has asked
  it to stop (`state`).

      AuroraMeter.Operations.pause("credit_expiry:global")
      AuroraMeter.Operations.paused?("credit_expiry:global")
      #=> true
      AuroraMeter.Operations.resume("credit_expiry:global")

  ## There is no Oban in here

  Deliberately, and it is invariant I20. A host that schedules
  `AuroraMeter.Credits.expire_due/2` from Quantum, from `:timer`, or from a
  Kubernetes CronJob gets pause, resume and cursors on exactly the same terms as
  a host running `AuroraMeter.Oban.CreditExpiry`. Nothing in this module
  references Oban, and nothing in it needs Oban to be installed.

  ## Names

  A name is `"<operation>:<scope>"`. The scope is `"global"` for a sweep with no
  natural partition, and the partition key otherwise (`"rollup:month"`,
  `"events_replay:7"`, `"lot_migration:org_42"`). The shape is validated and
  anything else raises `ArgumentError`, so a typo cannot quietly create a second
  checkpoint that nothing ever reads and no sweep ever resumes from.

  Two rows core writes are **not** operations and are not reachable through this
  module: `"events_projection"` (which generation is live) and
  `"events_backfill"`. Neither carries a colon, so both are refused here by
  design; read them with `AuroraMeter.Checkpoints`, which is the table's own
  module.

  ## Pausing is a promise about batches, not about jobs

  `pause/1` asks the operation to stop at its **next batch boundary**. A batch
  already in flight finishes and commits; nothing is interrupted and nothing is
  rolled back. The run then stops with its cursor where the last committed batch
  left it, and `resume/1` plus the next tick carries on from there.

  This is the one operational foot-gun in the module and it is worth stating:
  **a paused operation looks exactly like a healthy one from the outside.**
  Nothing runs, no error is raised, and the backlog grows quietly. Record the
  pause somewhere a human reads, and put `paused?/1` in your health check.

  ## Writes are autocommitted, never inside the work's transaction

  A checkpoint write is a single-row upsert of its own. It is never enlisted in
  the transaction that commits the batch it describes, in either direction, so a
  rolled-back batch cannot roll back an unrelated cursor and a failed cursor
  write cannot roll back committed work.

  The consequence is explicit rather than hidden: **a crash between a batch's
  commit and its checkpoint write re-runs that batch.** That is safe here for
  one reason and it is not a general one. Every operation that uses this module
  re-reads the thing it is about to change under that row's own lock and refuses
  when the work is already done: expiry re-reads `expired_at`, the hold
  reconciler re-reads `status = 'pending'`, the reporter's staging collapses onto
  the outbox identity. An operation whose effects were **not** idempotent could
  not use a cursor written this way, and a later unit that adds one must say so
  rather than inherit this paragraph.
  """

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Clock

  @name_format ~r/^[a-z_]+:[A-Za-z0-9_.:-]+$/

  @default_max_batches 10

  @telemetry [:aurora_meter, :operations, :batch]

  @typedoc ~S"""
  An operation name, `"<operation>:<scope>"`.
  """
  @type name :: String.t()

  @typedoc """
  What an operator reads back. The map may gain keys in a later release.
  """
  @type checkpoint :: %{
          name: name(),
          cursor: map() | nil,
          counts: map(),
          state: String.t() | nil,
          updated_at: DateTime.t()
        }

  @typedoc "One batch's outcome, as `run_batches/3`'s callback reports it."
  @type batch :: %{
          required(:cursor) => map() | nil,
          optional(:counts) => map()
        }

  @typedoc """
  What one `run_batches/3` call did.

  `stopped` says why the loop ended: `:complete` when the scan reached its end,
  `:paused` when an operator paused it, `:max_batches` when the run's own budget
  ran out with work still waiting.
  """
  @type report :: %{
          batches: non_neg_integer(),
          counts: map(),
          cursor: map() | nil,
          stopped: :complete | :paused | :max_batches
        }

  @doc """
  Asks `name` to stop at its next batch boundary.

  Creates the row when the operation has never run, so an operation can be
  paused before it is first scheduled. Leaves `cursor` and `counts` exactly as
  they are, so pausing never loses a position.
  """
  @spec pause(name()) :: :ok
  def pause(name), do: Checkpoints.pause(validate!(name))

  @doc """
  Clears a pause. The next run starts from the cursor, not from the beginning.
  """
  @spec resume(name()) :: :ok
  def resume(name), do: Checkpoints.resume(validate!(name))

  @doc """
  Whether `name` is paused. `false` for an operation that has never run.
  """
  @spec paused?(name()) :: boolean()
  def paused?(name), do: Checkpoints.paused?(validate!(name))

  @doc """
  Reads `name`'s checkpoint, or `nil` when it has never written one.
  """
  @spec checkpoint(name()) :: checkpoint() | nil
  def checkpoint(name), do: Checkpoints.get(validate!(name))

  @doc """
  Every checkpoint this installation holds, in name order.

  Includes the rows that are not operations (`"events_projection"`,
  `"schema:core"`), because an operator listing checkpoints wants to see the
  table rather than this module's idea of it.
  """
  @spec list() :: [checkpoint()]
  def list, do: Checkpoints.all()

  @doc """
  Writes `name`'s cursor and counts, leaving any pause alone.

  Attributes: `:cursor` (a map, or `nil` to say the scan is finished) and
  `:counts` (a map). At least one is required. A field that is not given is not
  written.

  A `nil` cursor is stored as the empty object, because core schema version 7
  declares the column `NOT NULL`, and `checkpoint/1` reads an empty cursor back
  as `nil`. The two are the same statement: this scan has no position.

  **This is an operator tool with an edge.** Writing a cursor by hand tells a
  sweep that everything before it is done. Moving one forwards skips work;
  moving one backwards re-runs work, which is safe only because every operation
  using this module has idempotent effects. Prefer `clear_checkpoint/1` if what
  you want is "start again".
  """
  @spec put_checkpoint(name(), keyword()) :: :ok
  def put_checkpoint(name, attrs) when is_list(attrs) do
    name = validate!(name)
    cursor = field!(attrs, :cursor)
    counts = field!(attrs, :counts)

    if cursor == :absent and counts == :absent do
      raise ArgumentError,
            "AuroraMeter.Operations.put_checkpoint/2 needs :cursor or :counts, got: " <>
              inspect(attrs)
    end

    Checkpoints.put_progress(name, cursor, counts)
  end

  @doc """
  Deletes `name`'s checkpoint row entirely.

  The next run starts from the beginning of its scan. That is safe for every
  operation in this package, because re-processing an item finds it already
  done, but it is not free: the whole scan runs again.

  **It also clears a pause**, because the pause lives in the same row. An
  operator who wants to rewind a cursor without resuming a paused operation
  wants `put_checkpoint(name, cursor: nil)` instead, which is what the workers
  themselves use when a scan completes.
  """
  @spec clear_checkpoint(name()) :: :ok
  def clear_checkpoint(name), do: Checkpoints.delete(validate!(name))

  @doc """
  Runs `fun` over bounded batches, carrying the cursor in `name`'s checkpoint.

  `fun` is called with the current cursor (a map, or `nil` at the start of a
  scan) and returns `{:ok, %{cursor: cursor, counts: counts}}` or
  `{:error, reason}`. A `cursor` of `nil` means the scan reached its end.

  The loop is the whole of lower-level invariants L05c-1 to L05c-3, in one place
  rather than once per worker:

    1. The pause is read **before every batch**, including the first, so pausing
       takes effect within one batch rather than one run.
    2. The cursor lives in the checkpoint row and is **never a job argument**, so
       two runs of the same operation read the same position and the second one
       resumes where the first got to rather than restarting from a stale one.
    3. A per-item failure is `fun`'s to count and to step over. Only a failure of
       the batch mechanism itself, the listing query or the checkpoint write,
       ends the run with `{:error, reason}`.

  Options:

    * `:max_batches` (default #{@default_max_batches}) - how many batches one
      call runs before returning with work still waiting. A run that stopped
      here leaves its cursor in place, so the next tick continues.
    * `:counts` (default `%{}`) - the counter map batches accumulate into.

  Returns `{:ok, report}`, `{:paused, report}` or `{:error, reason}`.

  Emits `#{inspect(@telemetry)}` per batch with measurements
  `%{items: integer, duration_ms: integer}` and metadata
  `%{name: name, result: :ok | :error}`. The duration is an in-memory span, so
  it is measured with `AuroraMeter.Clock.monotonic_ms/0` and not with any clock
  that can step backwards (`AuroraMeter.Clock`).
  """
  @spec run_batches(name(), keyword(), (map() | nil -> {:ok, batch()} | {:error, term()})) ::
          {:ok, report()} | {:paused, report()} | {:error, term()}
  def run_batches(name, opts, fun) when is_list(opts) and is_function(fun, 1) do
    name = validate!(name)

    loop(%{
      name: name,
      fun: fun,
      batches: 0,
      counts: Keyword.get(opts, :counts, %{}),
      cursor: cursor_of(Checkpoints.get(name)),
      max_batches: Keyword.get(opts, :max_batches, @default_max_batches)
    })
  end

  # -- the loop ---------------------------------------------------------------

  defp loop(state) do
    cond do
      # Before the first batch as well as between batches. A run that starts
      # while paused does nothing at all, not one batch of work.
      Checkpoints.paused?(state.name) -> {:paused, report(state, :paused)}
      state.batches >= state.max_batches -> {:ok, report(state, :max_batches)}
      true -> run_one(state)
    end
  end

  defp run_one(state) do
    started = Clock.monotonic_ms()

    case state.fun.(state.cursor) do
      {:ok, batch} ->
        commit(state, batch, started)

      {:error, reason} ->
        emit(state.name, %{}, started, :error)
        {:error, reason}
    end
  end

  defp commit(state, batch, started) do
    counts = merge_counts(state.counts, Map.get(batch, :counts, %{}))
    cursor = Map.fetch!(batch, :cursor)

    # The checkpoint write is a statement of its own, outside whatever
    # transaction `fun` used. See the module documentation for why that is the
    # right way round and what it costs.
    :ok = Checkpoints.put_progress(state.name, cursor, counts)

    emit(state.name, batch, started, :ok)

    state = %{state | batches: state.batches + 1, counts: counts, cursor: cursor}

    if is_nil(cursor), do: {:ok, report(state, :complete)}, else: loop(state)
  end

  defp report(state, stopped),
    do: %{batches: state.batches, counts: state.counts, cursor: state.cursor, stopped: stopped}

  defp merge_counts(acc, added) do
    Map.merge(acc, added, fn
      _key, a, b when is_number(a) and is_number(b) -> a + b
      _key, _a, b -> b
    end)
  end

  # The literal event name rather than the module attribute, so the inventory
  # guard that greps `lib/` for emit sites can see it (A05). The attribute is
  # kept because the moduledoc interpolates it, and a test asserts the two agree.
  defp emit(name, batch, started, result) do
    :telemetry.execute(
      [:aurora_meter, :operations, :batch],
      %{items: items(batch), duration_ms: Clock.monotonic_ms() - started},
      %{name: name, result: result}
    )
  end

  defp items(batch), do: batch |> Map.get(:counts, %{}) |> Map.get("examined", 0)

  # -- names ------------------------------------------------------------------

  defp validate!(name) when is_binary(name) do
    if Regex.match?(@name_format, name) do
      name
    else
      raise ArgumentError, """
      #{inspect(name)} is not an Aurora Meter operation name.

      A name is "<operation>:<scope>", matching #{inspect(@name_format)}: the
      operation in lower snake case, then a colon, then the scope ("global" for
      a sweep with no natural partition, the partition key otherwise). For
      example "credit_expiry:global" or "rollup:month".

      The shape is checked so a typo cannot silently create a second checkpoint
      that nothing resumes from. Rows that are not operations,
      "events_projection" and "events_backfill", are read with
      AuroraMeter.Checkpoints instead.
      """
    end
  end

  defp validate!(other),
    do: raise(ArgumentError, "an Aurora Meter operation name is a string, got: #{inspect(other)}")

  defp cursor_of(%{cursor: cursor}) when is_map(cursor) and map_size(cursor) > 0, do: cursor
  defp cursor_of(_absent_or_empty), do: nil

  defp field!(attrs, key) do
    case Keyword.fetch(attrs, key) do
      :error ->
        :absent

      {:ok, nil} ->
        nil

      {:ok, value} when is_map(value) ->
        value

      {:ok, other} ->
        raise ArgumentError, "#{inspect(key)} is a map or nil, got: #{inspect(other)}"
    end
  end
end
