defmodule AuroraMeter.Events.Backfill do
  @moduledoc """
  **Internal.** The implementation behind `mix aurora_meter.events.backfill`.
  Not part of the supported surface; run the Mix task.

  It gives every `aurora_meter_events` row written before core schema version 7
  the identity that version 8 makes mandatory. Bounded, checkpointed and
  re-runnable.

  ## What it writes, and what it approximates

  For each row whose `event_id` is null:

    * `event_id = "legacy:" <> id`, derived from the row's own primary key, so
      two runs produce the same value for the same row and a re-run is a no-op.
    * `occurred_at = inserted_at`. **This is an approximation.** The row was
      written by `AuroraMeter.track/4`, which never recorded when the usage
      happened, only when the row reached the database.
    * `kind = "usage"`, `original_event_id = NULL`, `dimensions = '{}'`.
    * `period_start` and `period_source` from
      `AuroraMeter.Period.containing/2` at `occurred_at`.
    * `payload_hash` from the canonical tuple (`AuroraMeter.Events.Canonical`).
    * `attribution = "resolved"` when the period source placed the instant, and
      `"unresolved"` when it could not, in which case `period_start` is the
      calendar month containing the instant. **That is the second
      approximation, and `"unresolved"` is how you find it.**
    * `plan_id` and `plan_version` stay null. Legacy events were never billed
      and their plan attribution cannot be reconstructed.

  ### How an operator tells an approximated row from an exact one

      -- every row this task has ever touched: occurred_at is the write time,
      -- not the usage time
      SELECT count(*) FROM aurora_meter_events WHERE event_id LIKE 'legacy:%';

      -- of those, the ones whose billing period is a guess as well
      SELECT count(*) FROM aurora_meter_events WHERE attribution = 'unresolved';

  A row recorded through the V1 durable path carries a caller-supplied
  `event_id` that cannot begin `legacy:` (the prefix is reserved) and an
  `occurred_at` the caller stated. The `legacy:` prefix is therefore the exact
  discriminator, and it is derived rather than flagged, so it cannot drift.

  ## What it never writes

  It writes no `aurora_meter_event_totals` row, enqueues no outbox item and
  emits no PubSub (L-03a-3). Legacy events were never billed, and upgrading one
  must not make it billable.

  ## Exclusion between two runners

  Two concurrent runs are safe, because the derivation is deterministic and
  every update carries `WHERE event_id IS NULL`; they are only wasteful. The
  task still refuses a second run, and it decides that with a **Postgres
  advisory lock** on a pinned connection, held for the length of the run.

  A lock rather than a lease, deliberately. A lease is a duration compared
  against a clock, and `clock_timestamp()` is the database host's OS clock,
  which is corrected: it was measured stepping backwards 439 ms on a 32.5
  second cadence on the development host (`open-findings.md` X100). A lock has
  no clock in it, and it releases itself when the connection holding it dies,
  which is exactly the signal a stale lease is trying to approximate.

  The checkpoint row's `state` and `updated_at` are a **report** for an
  operator, not the decision. A `"running"` state with the lock free means a
  previous run was killed; the task says so and `--force-resume` proceeds.

  One measured consequence of holding the lock on a pooled connection: when the
  runner is killed, Postgres releases the lock as the connection closes, and
  the pool closes it when it notices the client is gone. That is immediate for
  a killed OS process, and on this host it took under 50 ms for a killed BEAM
  process. So a resume attempted in the same instant as the kill can still see
  `:already_running`; a resume attempted by a human cannot.

  ## Resuming

  The cursor is `%{"seq" => n}` in `aurora_meter_checkpoints["events_backfill"]`,
  advanced inside the same transaction as the batch it describes. A run killed
  between batches resumes at the last committed batch. The scan is ordered by
  `seq`, never by `id`: `id` is a random v4 UUID, so a forward keyset scan
  ordered by it can miss a row committed by a transaction that started earlier.

  A row inserted by a still-running 0.4.x node during the backfill receives a
  higher `seq` than the cursor, so the same forward pass reaches it.
  """

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Config
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Period

  @checkpoint "events_backfill"

  # The advisory-lock namespace for core's own operational tasks, and one key
  # per task. Pro's ledger locks use a namespace of their own, so the two
  # cannot collide.
  @lock_namespace 0x4155524F

  @lock_key 7

  @default_batch_size 5000

  # DBConnection defaults to 15 seconds, which is a sensible number for a
  # request and the wrong one for bulk work: a 10,000 row batch on a table of
  # a million rows exceeded it on the development host, and the run died
  # holding its advisory lock. A batch is bounded by `--batch-size`, so the
  # right bound here is generous and explicit rather than inherited.
  @default_timeout 60_000

  @metadata_limit 16_384

  @typedoc "The counts a run reports."
  @type counts :: %{String.t() => term()}

  @typedoc """
  What a run returns.

  `:already_running` means another process holds the advisory lock right now.
  `:stale_running` means the checkpoint says `"running"` but nothing holds the
  lock, so the previous run was killed: `--force-resume` proceeds from its
  cursor. The two are kept apart because only the second is a decision for a
  human.
  """
  @type result ::
          {:ok, counts()}
          | {:error, :already_running, counts()}
          | {:error, :stale_running, counts()}
          | {:error, :paused, counts()}

  @doc """
  Runs the backfill.

  Options:

    * `:repo`: the repo to work through. Defaults to the configured repo.
    * `:batch_size`: rows per transaction, default #{@default_batch_size}.
    * `:max_batches`: stop cleanly after this many committed batches, leaving
      the checkpoint at the last one. For a bounded maintenance window.
    * `:dry_run`: scan and compute, write nothing at all, report the same
      counts. No row is updated and no checkpoint row is created or changed,
      so a dry run takes no lock and is safe beside a real one.
    * `:force_resume`: proceed although the checkpoint says `"running"`. Only
      reachable when the advisory lock is free, which is to say when the
      previous runner is gone.
    * `:timeout`: milliseconds allowed for one statement and for one batch
      transaction, default #{@default_timeout}. Raise it with `--batch-size`,
      or a large batch on a busy database dies part way through.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo) || Config.repo()
    opts = Keyword.put(opts, :repo, repo)

    if Keyword.get(opts, :dry_run, false) do
      {counts, _stopped} = scan(repo, opts, fresh_counts(), 0, 0)
      {:ok, counts}
    else
      exclusive(repo, opts, fn -> guarded(repo, opts) end)
    end
  end

  @doc """
  The name of the checkpoint row this task keeps.

  ## Examples

      iex> AuroraMeter.Events.Backfill.checkpoint_name()
      "events_backfill"

  """
  @spec checkpoint_name() :: String.t()
  def checkpoint_name, do: @checkpoint

  @doc """
  The `event_id` this task derives for a legacy row with the given primary key.

  Deterministic, which is what makes a re-run a no-op.

  ## Examples

      iex> AuroraMeter.Events.Backfill.legacy_event_id("6d1f0b9c-0000-4000-8000-000000000001")
      "legacy:6d1f0b9c-0000-4000-8000-000000000001"

  """
  @spec legacy_event_id(String.t()) :: String.t()
  def legacy_event_id(id) when is_binary(id), do: "legacy:" <> id

  @doc """
  How many rows still have no `event_id`. What core schema version 8 refuses on.

  Options: `:repo`.
  """
  @spec remaining(keyword()) :: non_neg_integer()
  def remaining(opts \\ []) do
    repo = Keyword.get(opts, :repo) || Config.repo()

    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM aurora_meter_events WHERE event_id IS NULL", [])

    count
  end

  # -- exclusion -------------------------------------------------------------

  # One pinned connection for the whole run, holding a session advisory lock.
  # No clock is consulted: the lock is held or it is not, and it goes away with
  # the connection that held it.
  defp exclusive(repo, opts, fun) do
    timeout = timeout(opts)
    lock = [@lock_namespace, @lock_key]

    repo.checkout(
      fn ->
        case repo.query!("SELECT pg_try_advisory_lock($1, $2)", lock, timeout: timeout) do
          %{rows: [[true]]} ->
            try do
              fun.()
            after
              repo.query!("SELECT pg_advisory_unlock($1, $2)", lock, timeout: timeout)
            end

          %{rows: [[false]]} ->
            {:error, :already_running, fresh_counts()}
        end
      end,
      timeout: :infinity
    )
  end

  defp guarded(repo, opts) do
    checkpoint = Checkpoints.get(@checkpoint, repo: repo)

    cond do
      state(checkpoint) == "paused" ->
        {:error, :paused, counts_of(checkpoint)}

      state(checkpoint) == "running" and not Keyword.get(opts, :force_resume, false) ->
        {:error, :stale_running, counts_of(checkpoint)}

      true ->
        start(repo, opts, checkpoint)
    end
  end

  # The counts describe THIS run, not the sum of every run that ever touched
  # this checkpoint. A resumed run reporting "updated: 12000" when it updated
  # 300 rows would be the wrong number in the one place an operator looks. The
  # cursor is what carries across runs; the counts are not.
  defp start(repo, opts, checkpoint) do
    counts = Map.put(fresh_counts(), "started_at", iso(db_now(repo)))
    cursor = cursor_of(checkpoint)
    Checkpoints.put(@checkpoint, %{"seq" => cursor}, counts, "running", repo: repo)

    {counts, stopped} = scan(repo, opts, counts, cursor, 0)
    counts = Map.put(counts, "finished_at", iso(db_now(repo)))

    # A pause is the operator's state, not this run's. Finishing must not clear
    # it, or a paused task would restart itself on the next invocation.
    final = if stopped == :paused, do: "paused", else: "idle"
    Checkpoints.put(@checkpoint, %{"seq" => counts["cursor"]}, counts, final, repo: repo)

    {:ok, counts}
  end

  # -- the scan --------------------------------------------------------------

  defp scan(repo, opts, counts, cursor, batches) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    max_batches = Keyword.get(opts, :max_batches)
    dry_run? = Keyword.get(opts, :dry_run, false)
    source = inspect(Config.period_source())

    rows = select(repo, cursor, batch_size, timeout(opts))

    cond do
      rows == [] ->
        {Map.put(counts, "cursor", cursor), :done}

      max_batches && batches >= max_batches ->
        {Map.put(counts, "cursor", cursor), :max_batches}

      not dry_run? and Checkpoints.paused?(@checkpoint, repo: repo) ->
        {Map.put(counts, "cursor", cursor), :paused}

      true ->
        {counts, cursor} = apply_batch(repo, rows, counts, source, opts)
        scan(repo, opts, counts, cursor, batches + 1)
    end
  end

  defp select(repo, cursor, limit, timeout) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT id, seq, tenant_key, feature, quantity, metadata, inserted_at, event_id,
               octet_length(metadata::text)
        FROM aurora_meter_events
        WHERE seq > $1
        ORDER BY seq
        LIMIT $2
        """,
        [cursor, limit],
        timeout: timeout
      )

    Enum.map(rows, &row/1)
  end

  defp row([id, seq, tenant_key, feature, quantity, metadata, inserted_at, event_id, size]) do
    %{
      id: Ecto.UUID.cast!(id),
      raw_id: id,
      seq: seq,
      tenant_key: tenant_key,
      feature: feature,
      quantity: quantity,
      metadata: metadata || %{},
      inserted_at: inserted_at,
      event_id: event_id,
      metadata_size: size
    }
  end

  defp apply_batch(repo, rows, counts, source, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    timeout = timeout(opts)
    cursor = rows |> List.last() |> Map.fetch!(:seq)
    {filled, pending} = Enum.split_with(rows, & &1.event_id)
    computed = Enum.map(pending, &compute(&1, source))

    counts =
      counts
      |> bump("scanned", length(rows))
      |> bump("already_filled", length(filled))
      |> bump("batches", 1)
      |> tally(computed)

    if dry_run? do
      # What a real run would update. A dry run whose counts do not predict the
      # real ones is not a preview of anything, and `updated` is the number an
      # operator sizing a maintenance window actually reads.
      counts =
        counts
        |> bump("updated", length(computed))
        |> Map.put("cursor", cursor)

      {counts, cursor}
    else
      {:ok, counts} =
        repo.transaction(
          fn ->
            counts =
              counts
              |> bump("updated", update(repo, computed, timeout))
              |> Map.put("cursor", cursor)

            Checkpoints.put(@checkpoint, %{"seq" => cursor}, counts, "running", repo: repo)
            counts
          end,
          timeout: timeout
        )

      emit(counts, length(rows), cursor)
      {counts, cursor}
    end
  end

  defp update(_repo, [], _timeout), do: 0

  defp update(repo, computed, timeout) do
    %{num_rows: rows} =
      repo.query!(
        """
        UPDATE aurora_meter_events AS e
        SET event_id = v.event_id,
            payload_hash = v.payload_hash,
            occurred_at = v.occurred_at,
            period_start = v.period_start,
            period_source = v.period_source,
            attribution = v.attribution,
            kind = 'usage',
            dimensions = '{}'::jsonb
        FROM unnest($1::uuid[], $2::text[], $3::bytea[], $4::timestamp[], $5::timestamp[],
                    $6::text[], $7::text[])
             AS v(id, event_id, payload_hash, occurred_at, period_start, period_source,
                  attribution)
        WHERE e.id = v.id AND e.event_id IS NULL
        """,
        [
          Enum.map(computed, & &1.raw_id),
          Enum.map(computed, & &1.event_id),
          Enum.map(computed, & &1.payload_hash),
          Enum.map(computed, & &1.occurred_at),
          Enum.map(computed, & &1.period_start),
          Enum.map(computed, & &1.period_source),
          Enum.map(computed, & &1.attribution)
        ],
        timeout: timeout
      )

    rows
  end

  # -- one row ---------------------------------------------------------------

  defp compute(row, source) do
    occurred_at = DateTime.from_naive!(row.inserted_at, "Etc/UTC")

    {period_start, period_source, attribution, reason} =
      period(row.tenant_key, occurred_at, source)

    hash =
      Canonical.legacy_payload_hash(%{
        feature: row.feature,
        quantity: row.quantity,
        occurred_at: occurred_at,
        metadata: row.metadata
      })

    %{
      raw_id: row.raw_id,
      event_id: legacy_event_id(row.id),
      payload_hash: hash,
      occurred_at: row.inserted_at,
      period_start: DateTime.to_naive(period_start),
      period_source: period_source,
      attribution: attribution,
      unresolved_reason: reason,
      nonpositive_quantity?: row.quantity <= 0,
      # The same measure core schema version 8's constraint uses:
      # `octet_length(metadata::text)`, not `pg_column_size`, which reports
      # storage size and so answers a different question for the same value.
      oversized_metadata?: row.metadata_size > @metadata_limit
    }
  end

  # `Period.containing/2` raises `AuroraMeter.Period.InvalidPeriodError` when
  # the source cannot place the instant, and that raise IS the contract: a
  # caller that must degrade rather than fail rescues it and records an
  # unresolved attribution. A custom source can also fail in ways of its own,
  # and a backfill that aborts on one tenant's source has failed at its only
  # job, so any exception degrades the same way. Which one it was is counted,
  # so an unexpected `unresolved` total can be explained rather than guessed at.
  defp period(tenant_key, occurred_at, source) do
    period = Period.containing(tenant_key, occurred_at)
    {period.start, source, "resolved", nil}
  rescue
    error ->
      fallback = Period.Calendar.current(tenant_key, occurred_at)
      {fallback.start, inspect(Period.Calendar), "unresolved", reason(error)}
  end

  defp reason(%Period.InvalidPeriodError{reason: reason}), do: "invalid_period:#{reason}"
  defp reason(error), do: inspect(error.__struct__)

  # -- counts ----------------------------------------------------------------

  defp fresh_counts do
    %{
      "scanned" => 0,
      "updated" => 0,
      "already_filled" => 0,
      "resolved" => 0,
      "unresolved" => 0,
      "unresolved_reasons" => %{},
      "nonpositive_quantity" => 0,
      "oversized_metadata" => 0,
      "batches" => 0,
      "cursor" => 0,
      "started_at" => nil,
      "finished_at" => nil
    }
  end

  defp state(nil), do: nil
  defp state(%{state: state}), do: state

  # On a refusal, what the last run recorded, so the message can name the
  # cursor a resume would start from. Only ever reached with a checkpoint,
  # because a refusal is a decision about one.
  defp counts_of(%{counts: counts, cursor: cursor}) do
    fresh_counts()
    |> Map.merge(counts)
    |> Map.put("cursor", Map.get(cursor, "seq", 0))
  end

  defp cursor_of(nil), do: 0
  defp cursor_of(%{cursor: cursor}), do: Map.get(cursor, "seq", 0)

  defp tally(counts, computed) do
    Enum.reduce(computed, counts, fn row, acc ->
      acc
      |> bump(if(row.attribution == "unresolved", do: "unresolved", else: "resolved"), 1)
      |> bump_if(row.nonpositive_quantity?, "nonpositive_quantity")
      |> bump_if(row.oversized_metadata?, "oversized_metadata")
      |> note(row.unresolved_reason)
    end)
  end

  defp bump(counts, key, by), do: Map.update(counts, key, by, &(&1 + by))

  defp timeout(opts), do: Keyword.get(opts, :timeout) || @default_timeout

  defp bump_if(counts, false, _key), do: counts
  defp bump_if(counts, true, key), do: bump(counts, key, 1)

  defp note(counts, nil), do: counts

  defp note(counts, reason) do
    Map.update(counts, "unresolved_reasons", %{reason => 1}, fn seen ->
      Map.update(seen, reason, 1, &(&1 + 1))
    end)
  end

  # The literal list rather than a module attribute, so the documentation guard
  # that greps `lib/` for emit sites can see it (`AuroraMeter.ApiInventoryTest`
  # A05). An event only a human knows about is an event nothing checks.
  defp emit(counts, scanned, cursor) do
    :telemetry.execute(
      [:aurora_meter, :events, :backfill, :batch],
      %{scanned: scanned, updated: counts["updated"], batches: counts["batches"]},
      %{cursor: cursor}
    )
  end

  defp db_now(repo) do
    %{rows: [[instant]]} = repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'", [])
    DateTime.from_naive!(instant, "Etc/UTC")
  end

  defp iso(%DateTime{} = instant), do: DateTime.to_iso8601(instant)
end
