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
  batch. `AuroraMeter.Operations` (05c) is the documented operator surface over
  the same rows.

  ## The state column is not a lock

  A `state` of `"running"` says a task believed it was running when it last
  wrote. It is a *report*, and nothing in this package decides a correctness
  question from it or from the age of `updated_at`. A clock cannot decide
  exclusion here: `clock_timestamp()` is the database host's OS clock and it is
  corrected, so a short lease compared against it can invert. Exclusion between
  two runners is taken with a Postgres advisory lock instead
  (`AuroraMeter.Events.Backfill`), which has no clock in it at all.

  `updated_at` is stamped by the database, with `clock_timestamp()` in the
  statement, so any comparison against it is a comparison of two readings of
  one clock. Read the other side with `AuroraMeter.Clock.db_now/0`.

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
