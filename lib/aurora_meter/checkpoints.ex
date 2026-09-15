defmodule AuroraMeter.Checkpoints do
  @moduledoc """
  The resumable cursor every bounded task in Aurora Meter keeps.

  One row of `aurora_meter_checkpoints` per task, named by the task:
  `"events_backfill"`, `"events_projection"`, `"events_replay:<generation>"`,
  `"schema:core"`. A row carries a `cursor` (where the task got to), `counts`
  (what it has done so far), a `state` and an `updated_at`. A task that is
  killed and restarted reads its row and carries on; an operator reads it to
  see where a stalled task stopped.

  This is repo-direct rather than a `AuroraMeter.Storage` callback, for the
  reason `AuroraMeter.Credits` is (ADR 0005): it is operational bookkeeping for
  core's own tooling, not adapter-visible state, and a third-party adapter
  would have no reason to implement six callbacks that exist only to serve a
  backfill.

  ## The state column

  `state` is the task lifecycle, a free string so a later task can add its own
  vocabulary without a migration. The values this release writes are `"idle"`,
  `"running"`, `"paused"`, `"active"` (the projection row, which is not a task)
  and `"applied"` (the `"schema:core"` marker).

  `pause/1` and `resume/1` set `"paused"` and `"idle"`. A running task reads
  `paused?/1` at a batch boundary and stops cleanly; it never interrupts a
  batch. `AuroraMeter.Operations` is the documented operator surface over the
  same rows, and is what a host and Aurora Meter Pro use; this module is the
  table's own, and is what core's backfill, replay and migration tasks use
  because their names predate the `"<operation>:<scope>"` shape `Operations`
  enforces.

  ## The state column is not a lock

  A `state` of `"running"` says a task believed it was running when it last
  wrote. It is a *report*, and nothing in this package decides a correctness
  question from it or from the age of `updated_at`. A clock cannot decide
  exclusion here: `clock_timestamp()` is the database host's OS clock and it is
  corrected, so a short lease compared against it can invert. Exclusion between
  two runners is taken with a Postgres advisory lock instead (`claim/3`, and
  `AuroraMeter.Events.Backfill`), which has no clock in it at all.

  `updated_at` is stamped by the database, with `clock_timestamp()` in the
  statement, so any comparison against it is a comparison of two readings of
  one clock. Read the other side with `AuroraMeter.Clock.db_now/0`.

  ## The heartbeat is not a lease

  `heartbeat/3` stamps `cursor["heartbeat_at"]` and `cursor["runner"]` so an
  operator can tell a stalled task from a finished one. **Nothing in this
  package decides an exclusion question from its age.** `open-findings.md` X100
  measured `clock_timestamp()` stepping backwards nine times in 300 seconds,
  worst 439 ms, on a 32.5 second cadence, so "the heartbeat is older than N
  seconds" is not a sound test for "the runner is gone" at any N a person would
  pick. The sound test is `claim/3`: a session advisory lock dies with the
  connection that held it, so a runner that was killed has already released it
  and a runner that is alive has not, with no duration anywhere in the decision.

  **The rule is about exclusion at seconds scale, and that boundary is worth
  stating because one caller is on the other side of it.**
  `AuroraMeter.Retention` does compare a `"flush:<node>"` row's age against a
  cutoff, and it is sound there for the reason `architecture-map.md` section 3
  gives: unsafe at seconds, safe at minutes and hours. The smallest window it
  will act on is one day, refused below that at boot, which is about 200,000
  times the measured backwards step; both sides of that comparison are stamped
  by `clock_timestamp()`; and the decision it feeds is a **veto** on deleting
  data rather than a licence to take another runner's work. Its moduledoc
  carries the arithmetic. A decision at seconds scale still has no business
  reading this column.

  ## The missing table

  `get/1` returns `nil` when `aurora_meter_checkpoints` does not exist, because
  that is the state of every database below core schema version 7 and
  `get("schema:core") == nil` is exactly how a caller detects one. Every write
  raises on a missing table: writing a checkpoint to a pre-V7 database is a
  bug, not a state to tolerate.
  """

  alias AuroraMeter.Config

  @typedoc "One checkpoint row."
  @type t :: %{
          name: String.t(),
          cursor: map(),
          counts: map(),
          state: String.t(),
          updated_at: DateTime.t()
        }

  @typedoc "Fields `update/2` accepts."
  @type attrs :: [cursor: map(), counts: map(), state: String.t()]

  # The advisory-lock namespace for name-derived task claims. Deliberately not
  # `AuroraMeter.Events.Backfill`'s `0x4155524F`, which holds hand-picked
  # integer keys: two namespaces cannot collide, so a new checkpoint name can
  # never accidentally take the backfill's lock.
  @claim_namespace 0x4155524E

  @select "SELECT name, cursor, counts, state, updated_at FROM aurora_meter_checkpoints"

  @upsert """
  INSERT INTO aurora_meter_checkpoints (name, cursor, counts, state, updated_at)
  VALUES ($1, $2, $3, $4, (clock_timestamp() AT TIME ZONE 'UTC'))
  ON CONFLICT (name) DO UPDATE
    SET cursor = EXCLUDED.cursor,
        counts = EXCLUDED.counts,
        state = EXCLUDED.state,
        updated_at = EXCLUDED.updated_at
  """

  @doc """
  Reads one checkpoint, or `nil` when there is no such row.

  Also `nil` when the table itself is absent, which is every database below
  core schema version 7.

  Options: `:repo` (defaults to the configured repo), for a caller that is
  inside a migration and must use the migrator's repo.

  ## Examples

      iex> AuroraMeter.Checkpoints.get("no_such_task")
      nil

  """
  @spec get(String.t(), keyword()) :: t() | nil
  def get(name, opts \\ []) when is_binary(name) do
    case query(opts, @select <> " WHERE name = $1", [name]) do
      {:ok, %{rows: [row]}} -> row(row)
      {:ok, %{rows: []}} -> nil
      {:error, :undefined_table} -> nil
    end
  end

  @doc """
  Lists every checkpoint, name order. `[]` when the table is absent.

  Options: `:repo`.
  """
  @spec all(keyword()) :: [t()]
  def all(opts \\ []) do
    case query(opts, @select <> " ORDER BY name", []) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &row/1)
      {:error, :undefined_table} -> []
    end
  end

  @doc """
  Writes `cursor`, `counts` and `state` for `name`, creating the row if needed.

  `updated_at` is stamped by the database. Call this inside the same
  transaction as the work it records, so the cursor can never run ahead of the
  work.

  Options: `:repo`.
  """
  @spec put(String.t(), map(), map(), String.t(), keyword()) :: :ok
  def put(name, cursor, counts, state, opts \\ [])
      when is_binary(name) and is_map(cursor) and is_map(counts) and is_binary(state) do
    repo(opts).query!(@upsert, [name, cursor, counts, state])
    :ok
  end

  # Written for `AuroraMeter.Operations.put_checkpoint/2` (build unit 05c), and
  # here rather than there because this module owns every statement against the
  # table (`open-findings.md` X161: if a table has an owner, every writer goes
  # through it).
  #
  # `state` appears in the INSERT and **not** in the DO UPDATE, which is the
  # whole point of the statement. `put/5` overwrites `state`, so a worker using
  # it to advance a cursor would clear a pause an operator had just set; `update/3`
  # leaves `state` alone but refuses to create a row, so the first batch of a
  # scan that has never run would have nowhere to write. This does both.
  #
  # The two booleans say whether the caller supplied the field at all, which
  # `COALESCE` cannot express on its own: "write an empty cursor" and "leave the
  # cursor alone" are different instructions and both arrive as an absence of
  # content.
  #
  # **An empty cursor is `'{}'`, not `NULL`.** Version 7 declares `cursor`,
  # `counts` and `state` all `NOT NULL` with defaults, while
  # `architecture-map.md` section 4.1 and `schema-migration-map.md` S1 describe
  # every one of them as nullable and say a `NULL` state means active. The
  # shipped table is the authority and no unit is adding DDL to make the map
  # true, so "this scan has no position" is the empty object here and
  # `AuroraMeter.Operations` reads it back as `nil`.
  @put_progress """
  INSERT INTO aurora_meter_checkpoints (name, cursor, counts, state, updated_at)
  VALUES ($1, COALESCE($2, '{}'::jsonb), COALESCE($3, '{}'::jsonb), 'idle',
          (clock_timestamp() AT TIME ZONE 'UTC'))
  ON CONFLICT (name) DO UPDATE
    SET cursor = CASE WHEN $4 THEN EXCLUDED.cursor ELSE aurora_meter_checkpoints.cursor END,
        counts = CASE WHEN $5 THEN EXCLUDED.counts ELSE aurora_meter_checkpoints.counts END,
        updated_at = EXCLUDED.updated_at
  """

  @doc """
  Writes `cursor` and `counts` for `name` **without touching `state`**, creating
  the row as `"idle"` when it does not exist.

  Either field may be `:absent`, which leaves it as it is. A `cursor` of `nil`
  is a value rather than an omission: it is how a run says its scan reached the
  end, and it is stored as the empty object because the column is `NOT NULL`.

  This is what a batch loop advancing a cursor uses, so that an operator pausing
  the operation mid run cannot be clobbered by the batch that was already in
  flight. Options: `:repo`.
  """
  @spec put_progress(String.t(), map() | nil | :absent, map() | :absent, keyword()) :: :ok
  def put_progress(name, cursor, counts, opts \\ []) when is_binary(name) do
    repo(opts).query!(@put_progress, [
      name,
      unless_absent(cursor),
      unless_absent(counts),
      cursor != :absent,
      counts != :absent
    ])

    :ok
  end

  defp unless_absent(:absent), do: nil
  defp unless_absent(value), do: value

  @doc """
  Merges the given fields into an existing row, leaving the others alone.

  Returns `{:error, :not_found}` when there is no such row; it never creates
  one, because a partial update of a checkpoint that does not exist is a
  caller mistake rather than a state worth inventing.

  Options: `:repo`.

  ## Examples

      iex> AuroraMeter.Checkpoints.update("no_such_task", state: "paused")
      {:error, :not_found}

  """
  @spec update(String.t(), attrs(), keyword()) :: :ok | {:error, :not_found}
  def update(name, attrs, opts \\ []) when is_binary(name) do
    {sets, params} = assignments(attrs)

    sql =
      "UPDATE aurora_meter_checkpoints SET " <>
        Enum.join(sets ++ ["updated_at = (clock_timestamp() AT TIME ZONE 'UTC')"], ", ") <>
        " WHERE name = $#{length(params) + 1}"

    case repo(opts).query!(sql, params ++ [name]) do
      %{num_rows: 0} -> {:error, :not_found}
      %{num_rows: _} -> :ok
    end
  end

  @doc """
  Removes a checkpoint. Succeeds whether or not the row was there.

  Options: `:repo`.
  """
  @spec delete(String.t(), keyword()) :: :ok
  def delete(name, opts \\ []) when is_binary(name) do
    repo(opts).query!("DELETE FROM aurora_meter_checkpoints WHERE name = $1", [name])
    :ok
  end

  @doc """
  Asks a task to stop at its next batch boundary.

  Creates the row when the task has not run yet, so a task can be paused
  before it is started. Never interrupts a batch in flight.

  Options: `:repo`.
  """
  @spec pause(String.t(), keyword()) :: :ok
  def pause(name, opts \\ []), do: set_state(name, "paused", opts)

  @doc """
  Clears a pause. The next run of the task starts from its checkpoint.

  Options: `:repo`.
  """
  @spec resume(String.t(), keyword()) :: :ok
  def resume(name, opts \\ []), do: set_state(name, "idle", opts)

  @doc """
  Whether `name` is paused. `false` when there is no row and when the table is
  absent.

  Options: `:repo`.

  ## Examples

      iex> AuroraMeter.Checkpoints.paused?("no_such_task")
      false

  """
  @spec paused?(String.t(), keyword()) :: boolean()
  def paused?(name, opts \\ []) do
    case get(name, opts) do
      %{state: "paused"} -> true
      _other -> false
    end
  end

  @doc """
  Stamps `cursor["heartbeat_at"]` and `cursor["runner"]` and sets the state to
  `"running"`, leaving every other cursor key and the counts alone.

  The instant is `clock_timestamp()`, written by the database in the same
  statement, so it is never a node's reading of the time. Call it inside the
  transaction that commits a batch, so a heartbeat can never be fresher than
  the work it claims to be reporting.

  It is a **report for a human**, not a lease: see the module documentation.
  Returns `{:error, :not_found}` when there is no such row.

  Options: `:repo`, and `:runner` (default `"<node>/<pid>"`).
  """
  @spec heartbeat(String.t(), keyword()) :: :ok | {:error, :not_found}
  def heartbeat(name, opts \\ []) when is_binary(name) do
    runner = Keyword.get(opts, :runner) || runner()

    result =
      repo(opts).query!(
        """
        UPDATE aurora_meter_checkpoints
           SET cursor = cursor || jsonb_build_object(
                 'heartbeat_at', to_jsonb((clock_timestamp() AT TIME ZONE 'UTC')::text),
                 'runner', to_jsonb($2::text)),
               state = 'running',
               updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
         WHERE name = $1
        """,
        [name, runner]
      )

    case result do
      %{num_rows: 0} -> {:error, :not_found}
      %{num_rows: _} -> :ok
    end
  end

  @doc """
  Runs `fun` while holding a Postgres **session** advisory lock derived from
  `name`, on one pinned connection, and returns `{:ok, fun.()}`.

  Returns `{:error, :already_running}` without calling `fun` when another
  connection holds it. This is the exclusion every bounded task in this package
  uses, and it has no clock in it: the lock is granted or it is not, and it is
  released by `pg_advisory_unlock`, by the connection closing or by the process
  that held it dying. A runner killed with `kill -9` therefore leaves nothing
  behind to time out (`open-findings.md` X100).

  The lock key is `{0x4155524E, :erlang.phash2(name)}`. The namespace is
  distinct from the fixed-key namespace `0x4155524F` that
  `AuroraMeter.Events.Backfill` uses, so a name can never collide with a task
  that took a hand-picked key. Two *different* names that hash alike would
  exclude each other, which is over-exclusion rather than a correctness
  failure, and there are four names in this package.

  Options: `:repo`, `:timeout` (per statement, default 15_000).
  """
  @spec claim(String.t(), (-> result), keyword()) :: {:ok, result} | {:error, :already_running}
        when result: term()
  def claim(name, fun, opts \\ []) when is_binary(name) and is_function(fun, 0) do
    repo = repo(opts)
    timeout = Keyword.get(opts, :timeout, 15_000)
    lock = [@claim_namespace, :erlang.phash2(name)]

    repo.checkout(
      fn ->
        case repo.query!("SELECT pg_try_advisory_lock($1, $2)", lock, timeout: timeout) do
          %{rows: [[true]]} ->
            try do
              {:ok, fun.()}
            after
              repo.query!("SELECT pg_advisory_unlock($1, $2)", lock, timeout: timeout)
            end

          %{rows: [[false]]} ->
            {:error, :already_running}
        end
      end,
      timeout: :infinity
    )
  end

  @doc """
  The runner identity `heartbeat/2` stamps: this node and this process.

  Informational. Nothing decides anything from it; it is what an operator reads
  to find the machine a stalled task is on.
  """
  @spec runner() :: String.t()
  def runner, do: "#{node()}/#{inspect(self())}"

  defp set_state(name, state, opts) do
    case update(name, [state: state], opts) do
      :ok ->
        :ok

      {:error, :not_found} ->
        put(name, %{}, %{}, state, opts)
    end
  end

  # Only the three known keys reach the SQL, and each contributes a fixed
  # fragment with a placeholder: no caller-supplied string is ever interpolated
  # into a statement.
  defp assignments(attrs) do
    {sets, params, _index} =
      Enum.reduce([:cursor, :counts, :state], {[], [], 1}, fn key, {sets, params, index} ->
        case Keyword.fetch(attrs, key) do
          {:ok, value} -> {sets ++ ["#{key} = $#{index}"], params ++ [value], index + 1}
          :error -> {sets, params, index}
        end
      end)

    if sets == [] do
      raise ArgumentError,
            "AuroraMeter.Checkpoints.update/2 needs at least one of :cursor, :counts or " <>
              ":state, got: #{inspect(attrs)}"
    end

    {sets, params}
  end

  defp query(opts, sql, params) do
    {:ok, repo(opts).query!(sql, params)}
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :undefined_table do
        {:error, :undefined_table}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp repo(opts), do: Keyword.get(opts, :repo) || Config.repo()

  defp row([name, cursor, counts, state, updated_at]) do
    %{
      name: name,
      cursor: cursor,
      counts: counts,
      state: state,
      updated_at: utc(updated_at)
    }
  end

  defp utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp utc(%DateTime{} = instant), do: instant
end
