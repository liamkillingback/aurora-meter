defmodule AuroraMeter.Events.Replay do
  @moduledoc """
  Rebuilds `aurora_meter_event_totals` from the events that produced it, into
  an isolated generation, while the system keeps recording.

      {:ok, report} = AuroraMeter.Events.Replay.run()
      AuroraMeter.Events.Replay.status()
      AuroraMeter.Events.Replay.prune(1)

  A replay is an **operator action**, not a scheduled job. Nothing runs one by
  itself: `AuroraMeter.Oban` schedules no replay, and the runbook
  ([replay](operations/replay.md)) says when to run one and what it costs.

  ## What makes a forward scan sound here

  The events table is being written while the scan reads it, and two obvious
  keyset orders are unsound: `id` is a random version 4 UUID, so a transaction
  that started earlier can commit a row below a cursor the scan has passed, and
  `inserted_at` is an application clock value rather than a commit order. The
  scan orders by `seq`, the database-assigned identity column, and is bounded
  by a **watermark**:

    * `AuroraMeter.Storage.begin_projection_generation/0` takes `FOR UPDATE` on
      the `events_projection` checkpoint row. Every record and correction
      transaction takes `FOR SHARE` on that same row **before** inserting
      anything, so the exclusive lock is granted only once every in-flight one
      has finished. `max(seq)` read in that transaction is therefore a line
      every committed event is below.
    * Every record that starts afterwards reads the building generation in its
      own first step and writes its delta to **both** generations. Those events
      are above the watermark and the scan never sees them.

  There is no third case, which is what makes "no event is missing and none is
  counted twice" provable rather than likely.

  ## What a replay never does

  It reads `aurora_meter_events` and writes `aurora_meter_event_totals` and its
  own checkpoint rows. It never calls `AuroraMeter.record/4`, so it stages no
  export intent and inserts no event. It never grants a credit, never marks a
  counter key dirty, never writes `pending_flush`, never publishes a PubSub
  message and never calls a host handler. A rebuilt projection therefore cannot
  cause a resend, a second invoice line or a duplicate notification (I08).

  ## Exclusion, and why there is no lease

  Two runners are kept apart by `AuroraMeter.Checkpoints.claim/3`, a Postgres
  session advisory lock on a pinned connection. It dies with the connection, so
  a runner killed with `kill -9` leaves nothing to expire. The heartbeat in the
  checkpoint cursor is a **report for a human** and nothing subtracts it from
  anything: `open-findings.md` X100 measured the one clock every node shares
  stepping backwards 439 ms on a 32.5 second cadence, and a lease compared
  against it can invert.

  ## Repo-bound, like the backfill

  Each batch commits its totals and its checkpoint in one transaction, which is
  the whole of the resumability guarantee, so this module opens that
  transaction on `AuroraMeter.Config.repo/0` directly, exactly as
  `AuroraMeter.Checkpoints` and `AuroraMeter.Events.Backfill` do. An adapter
  that does not declare `:projection_generations` is refused up front with
  `{:error, {:unsupported, :projection_generations}}` rather than half served.
  """

  require Logger

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Counter
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @claim "events_replay"

  @default_batch_size 5000
  @default_compare_limit 1000
  @default_drain_size 5000
  @default_timeout 60_000
  @rehydrate_chunk 500

  @typedoc "What a completed run reports."
  @type report :: %{
          generation: pos_integer(),
          scanned: non_neg_integer(),
          projected: non_neg_integer(),
          keys: non_neg_integer(),
          batches: non_neg_integer(),
          differences: non_neg_integer(),
          activated: boolean(),
          duration_ms: non_neg_integer()
        }

  @typedoc "What `status/0` reports."
  @type status :: %{
          active_generation: non_neg_integer(),
          building_generation: integer() | nil,
          previous_generation: non_neg_integer() | nil,
          seed_generation: integer() | nil,
          watermark: non_neg_integer() | nil,
          replay: map() | nil
        }

  @doc """
  Rebuilds the projection into a new generation and, by default, activates it.

  Options:

    * `:batch_size`: events per committed batch, default #{@default_batch_size}.
    * `:compare`: `:require_match` (default) refuses to activate when the
      rebuilt generation differs from the live one and returns
      `{:error, {:projection_mismatch, summary}}`, leaving the built generation
      for inspection. `:report` returns the differences and activates anyway,
      which is the mode for repairing a projection already known to be wrong.
    * `:activate`: default `true`. `false` builds and compares only.
    * `:resume`: default `true`. `false` refuses when a building generation
      already exists rather than continuing it.
    * `:generation`: refuse unless the building generation is this one. For an
      operator who wants to be sure which build they are resuming.
    * `:compare_limit`: differences listed, default #{@default_compare_limit}.
      The count is always complete.
    * `:max_batches`: stop cleanly after this many committed batches, leaving
      the cursor where it is. For a bounded maintenance window.
    * `:rehydrate`: default `true`. Re-seats warm events-source counter keys
      after activation so dashboards move without a restart.
    * `:timeout`: milliseconds for one statement and one batch transaction,
      default #{@default_timeout}.

  A paused replay returns `{:ok, :paused, status}` at its next batch boundary
  with everything in place; `AuroraMeter.Checkpoints.resume/1` and another
  `run/1` carry on from the cursor.
  """
  @spec run(keyword()) ::
          {:ok, report()}
          | {:ok, :paused, status()}
          | {:error, {:projection_mismatch, map()}}
          | {:error, {:already_running, status()}}
          | {:error, term()}
  def run(opts \\ []) do
    if Storage.supports?(:projection_generations) do
      claimed(opts)
    else
      {:error, {:unsupported, :projection_generations}}
    end
  end

  @doc """
  The generations and, when one is in progress, the replay's own checkpoint.

  ## Examples

      iex> status = AuroraMeter.Events.Replay.status()
      iex> is_integer(status.active_generation)
      true

  """
  @spec status() :: status()
  def status do
    case Storage.projection_state() do
      {:ok, state} -> Map.put(state, :replay, replay_checkpoint(state.building_generation))
      {:error, _reason} -> empty_status()
    end
  end

  @doc """
  Deletes a retired generation's rows in bounded slices.

  Refuses the active generation (`{:error, :active}`), refuses while a replay
  holds the claim (`{:error, {:already_running, status}}`) and refuses a
  generation with no rows and no mention in the projection state
  (`{:error, :not_found}`).

  Pruning the generation a replay abandoned also drops its seed rows and clears
  it from the projection state, so the next `run/1` starts a fresh build.

  ## Examples

      iex> AuroraMeter.Events.Replay.prune(0)
      {:error, :active}

  """
  @spec prune(integer()) ::
          {:ok, non_neg_integer()}
          | {:error, :active | :not_found | {:already_running, status()}}
          | {:error, term()}
  def prune(generation) when is_integer(generation) do
    case Checkpoints.claim(@claim, fn -> pruning(generation) end, repo: repo()) do
      {:ok, result} -> result
      {:error, :already_running} -> {:error, {:already_running, status()}}
    end
  end

  @doc """
  The checkpoint row name a build of `generation` keeps.

  ## Examples

      iex> AuroraMeter.Events.Replay.checkpoint_name(2)
      "events_replay:2"

  """
  @spec checkpoint_name(integer()) :: String.t()
  def checkpoint_name(generation) when is_integer(generation),
    do: "events_replay:#{generation}"

  @doc """
  The name of the advisory-lock claim a run holds, shared by every generation.

  Two replays of *different* generations exclude each other too: a second
  building generation while one is in flight would leave the record path
  writing three rows and no way to say which build a delta belonged to.

  ## Examples

      iex> AuroraMeter.Events.Replay.claim_name()
      "events_replay"

  """
  @spec claim_name() :: String.t()
  def claim_name, do: @claim

  # -- the run ---------------------------------------------------------------

  defp claimed(opts) do
    case Checkpoints.claim(@claim, fn -> phases(opts) end, repo: repo()) do
      {:ok, result} -> result
      {:error, :already_running} -> {:error, {:already_running, status()}}
    end
  end

  defp phases(opts) do
    started = Clock.monotonic_ms()

    with {:ok, state} <- announce(opts),
         {:ok, state} <- scan(state),
         {:ok, state} <- drain(state),
         {:ok, state} <- compare(state) do
      finish(state, started)
    end
  end

  # -- phase 1: announcement -------------------------------------------------

  defp announce(opts) do
    at = Clock.monotonic_ms()

    case Storage.begin_projection_generation() do
      {:ok, announced} -> announced(announced, opts, at)
      {:error, reason} -> {:error, reason}
    end
  end

  defp announced(announced, opts, at) do
    wanted = Keyword.get(opts, :generation)

    cond do
      announced.resumed and not Keyword.get(opts, :resume, true) ->
        {:error, {:already_building, status()}}

      not is_nil(wanted) and wanted != announced.generation ->
        {:error, {:wrong_generation, %{asked: wanted, building: announced.generation}}}

      true ->
        state = fresh(announced, opts)

        emit_phase(:announce, state, Clock.monotonic_ms() - at, %{
          seeded: announced.seeded,
          resumed: announced.resumed
        })

        start_checkpoint(state)
    end
  end

  defp fresh(announced, opts) do
    %{
      generation: announced.generation,
      active: announced.active_generation,
      seed: announced.seed_generation,
      watermark: announced.watermark,
      resumed: announced.resumed,
      seeded: announced.seeded,
      name: checkpoint_name(announced.generation),
      opts: opts,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      cursor: 0,
      counts: %{},
      scanned: 0,
      projected: 0,
      keys: 0,
      batches: 0,
      drained: 0,
      differences: 0,
      difference_list: [],
      activated: false,
      stopped: nil
    }
  end

  # The counts describe THIS run, and the cursor is what carries across runs.
  # A resumed run reporting the first run's totals would be the wrong number in
  # the one place an operator looks (the same rule `Events.Backfill` states).
  #
  # The pause is read BEFORE anything is written. Writing `"running"` first and
  # then asking whether the task is paused would clear the operator's pause on
  # every invocation, which is the one thing a pause has to survive.
  defp start_checkpoint(state) do
    checkpoint = Checkpoints.get(state.name, repo: repo())
    cursor = cursor_of(checkpoint)

    if state_of(checkpoint) == "paused" do
      {:ok, %{state | cursor: cursor, stopped: :paused}}
    else
      counts = %{
        "scanned" => 0,
        "projected" => 0,
        "keys" => 0,
        "batches" => 0,
        "started_at" => iso(Clock.db_now())
      }

      Checkpoints.put(
        state.name,
        %{"seq" => cursor, "watermark" => state.watermark},
        counts,
        "running",
        repo: repo()
      )

      Checkpoints.heartbeat(state.name, repo: repo())
      {:ok, %{state | cursor: cursor, counts: counts}}
    end
  end

  defp state_of(nil), do: nil
  defp state_of(%{state: state}), do: state

  # -- phase 2: the scan -----------------------------------------------------

  defp scan(%{stopped: :paused} = state), do: {:ok, state}

  defp scan(state) do
    cond do
      Checkpoints.paused?(state.name, repo: repo()) ->
        {:ok, %{state | stopped: :paused}}

      max_batches?(state) ->
        {:ok, %{state | stopped: :max_batches}}

      true ->
        scan_batch(state, select(state))
    end
  end

  defp scan_batch(state, []), do: {:ok, state}

  defp scan_batch(state, rows) do
    case apply_batch(state, rows) do
      {:ok, state} -> scan(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp max_batches?(state) do
    case Keyword.get(state.opts, :max_batches) do
      nil -> false
      limit -> state.batches >= limit
    end
  end

  defp select(state) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT seq, tenant_key, feature, period_start, kind, quantity, attribution, event_id
          FROM aurora_meter_events
         WHERE seq > $1 AND seq <= $2
         ORDER BY seq
         LIMIT $3
        """,
        [state.cursor, state.watermark, state.batch_size],
        timeout: state.timeout
      )

    rows
  end

  defp apply_batch(state, rows) do
    at = Clock.monotonic_ms()
    cursor = rows |> List.last() |> Enum.at(0)
    entries = aggregate(rows)

    counts =
      state.counts
      |> bump("scanned", length(rows))
      |> bump("projected", Enum.count(rows, &projected?/1))
      |> bump("keys", length(entries))
      |> bump("batches", 1)

    # The totals write and the checkpoint advance are ONE transaction, and that
    # is the whole of the resumability guarantee: a kill at any instant leaves
    # the cursor naming a `seq` whose batch is either fully applied or not
    # applied at all.
    committed =
      repo().transaction(
        fn ->
          case Storage.write_projection_totals(state.generation, entries) do
            :ok ->
              Checkpoints.put(
                state.name,
                %{"seq" => cursor, "watermark" => state.watermark},
                counts,
                "running",
                repo: repo()
              )

              Checkpoints.heartbeat(state.name, repo: repo())
              :ok

            {:error, reason} ->
              repo().rollback(reason)
          end
        end,
        timeout: state.timeout
      )

    case committed do
      {:ok, :ok} ->
        :telemetry.execute(
          [:aurora_meter, :replay, :batch],
          %{scanned: length(rows), keys: length(entries), duration: Clock.monotonic_ms() - at},
          %{generation: state.generation, cursor: cursor, phase: :scan}
        )

        {:ok,
         %{
           state
           | cursor: cursor,
             counts: counts,
             scanned: counts["scanned"],
             projected: counts["projected"],
             keys: counts["keys"],
             batches: counts["batches"]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The signed contribution of one event, which is `projection_delta/1` in
  # `AuroraMeter.Storage.Ecto` and `AuroraMeter.Events` written a third time
  # against the raw columns: a correction is a negative quantity and a positive
  # event count (I09, L-03e-3). A rebuilt total that used a different rule
  # would differ from the live one for every corrected key, which is what the
  # comparison in phase 3 is there to catch.
  defp aggregate(rows) do
    rows
    |> Enum.filter(&projected?/1)
    |> Enum.reduce(%{}, fn [_seq, tenant, feature, period, kind, quantity, _attr, _id], acc ->
      delta = if kind == "correction", do: -quantity, else: quantity
      Map.update(acc, {tenant, feature, period}, {delta, 1}, fn {q, n} -> {q + delta, n + 1} end)
    end)
    |> Enum.map(fn {{tenant, feature, period}, {quantity, events}} ->
      %{
        tenant_key: tenant,
        feature: feature,
        period_start: utc(period),
        quantity: quantity,
        events: events
      }
    end)
  end

  # Which rows the live projection contains, and the predicate is a
  # reconstruction rather than a shared definition, because the live path does
  # not filter: it projects exactly what it inserts.
  #
  # Two families of row are in `aurora_meter_events` and in no total:
  #
  #   * `AuroraMeter.track/4` on a legacy durable feature, through
  #     `AuroraMeter.Storage.insert_events/1`. Those carry
  #     `attribution = "legacy_track"` and an `event_id` of `"track:<uuid>"`,
  #     and `AuroraMeter.LegacyDurableTrackTest` asserts they reach no total.
  #   * The same rows from before core schema version 7, given an identity by
  #     `mix aurora_meter.events.backfill`. Those carry
  #     `event_id = "legacy:<id>"` and an attribution of `"resolved"` or
  #     `"unresolved"`, because the backfill resolves a period for them; the
  #     prefix is the only thing that separates them from a recorded event.
  #
  # `period_start IS NULL` is the third: a row with no period cannot be a
  # projection key at all, and only the legacy path can produce one.
  #
  # Including any of them would make every rebuilt total larger than the live
  # one for a key with history, which `compare: :require_match` would refuse,
  # and which `compare: :report` would activate.
  defp projected?([_seq, _tenant, _feature, period, _kind, _quantity, attribution, event_id]) do
    not is_nil(period) and attribution != "legacy_track" and
      not String.starts_with?(event_id || "", ["legacy:", "track:"])
  end

  # -- phase 2b: draining the seed ------------------------------------------

  # The announcement copied the active generation into the building generation
  # so that a concurrent correction could never drive it below zero (the reason
  # is written out in `AuroraMeter.Storage.Ecto.begin_projection_generation/0`).
  # That copy now comes back out, one bounded slice at a time. Each slice is
  # one statement that subtracts and deletes together, so the seed row's own
  # existence is the cursor and an interrupted drain resumes with no
  # bookkeeping at all.
  defp drain(%{stopped: stopped} = state) when stopped in [:paused, :max_batches],
    do: {:ok, state}

  defp drain(state) do
    at = Clock.monotonic_ms()

    case drain_slices(state, 0) do
      {:ok, drained} ->
        emit_phase(:drain, state, Clock.monotonic_ms() - at, %{drained: drained})
        {:ok, %{state | drained: drained}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drain_slices(state, total) do
    size = Keyword.get(state.opts, :drain_size, @default_drain_size)

    case Storage.drain_projection_seed(state.seed, size) do
      {:ok, 0} -> {:ok, total}
      {:ok, n} -> drain_slices(state, total + n)
      {:error, reason} -> {:error, reason}
    end
  end

  # -- phase 3: the comparison ----------------------------------------------

  defp compare(%{stopped: stopped} = state) when stopped in [:paused, :max_batches],
    do: {:ok, state}

  defp compare(state) do
    at = Clock.monotonic_ms()
    limit = Keyword.get(state.opts, :compare_limit, @default_compare_limit)
    {count, listed} = differences(state, limit)

    state = %{state | differences: count, difference_list: listed}
    emit_phase(:compare, state, Clock.monotonic_ms() - at, %{differences: count})

    Checkpoints.put(
      state.name,
      %{"seq" => state.cursor, "watermark" => state.watermark},
      Map.merge(state.counts, %{"differences" => count, "drained" => state.drained}),
      "compared",
      repo: repo()
    )

    if count > 0 and Keyword.get(state.opts, :compare, :require_match) == :require_match do
      {:error, {:projection_mismatch, summary(state)}}
    else
      {:ok, state}
    end
  end

  defp differences(state, limit) do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM (" <> difference_query() <> ") d",
        [state.active, state.generation],
        timeout: state.timeout
      )

    %{rows: rows} =
      repo().query!(
        difference_query() <> " ORDER BY 1, 2, 3 LIMIT $3",
        [state.active, state.generation, limit],
        timeout: state.timeout
      )

    {count, Enum.map(rows, &difference_row/1)}
  end

  defp difference_query do
    """
    SELECT coalesce(a.tenant_key, b.tenant_key) AS tenant_key,
           coalesce(a.feature, b.feature) AS feature,
           coalesce(a.period_start, b.period_start) AS period_start,
           a.quantity AS active_quantity, a.events AS active_events,
           b.quantity AS built_quantity, b.events AS built_events
      FROM (SELECT * FROM aurora_meter_event_totals WHERE generation = $1) a
      FULL OUTER JOIN
           (SELECT * FROM aurora_meter_event_totals WHERE generation = $2) b
        ON a.tenant_key = b.tenant_key AND a.feature = b.feature
       AND a.period_start = b.period_start
     WHERE a.quantity IS DISTINCT FROM b.quantity
        OR a.events IS DISTINCT FROM b.events
    """
  end

  defp difference_row([tenant, feature, period, aq, ae, bq, be]) do
    %{
      tenant_key: tenant,
      feature: feature,
      period_start: utc(period),
      active: %{quantity: aq, events: ae},
      built: %{quantity: bq, events: be}
    }
  end

  defp summary(state) do
    %{
      generation: state.generation,
      active_generation: state.active,
      differences: state.differences,
      listed: length(state.difference_list),
      keys: state.difference_list
    }
  end

  # -- phase 4: activation ---------------------------------------------------

  defp finish(%{stopped: :paused} = state, _started) do
    Checkpoints.put(
      state.name,
      %{"seq" => state.cursor, "watermark" => state.watermark},
      state.counts,
      "paused",
      repo: repo()
    )

    {:ok, :paused, status()}
  end

  defp finish(%{stopped: :max_batches} = state, started) do
    {:ok, report(state, started)}
  end

  defp finish(state, started) do
    if Keyword.get(state.opts, :activate, true) do
      case activate(state) do
        {:ok, state} -> {:ok, state |> rehydrate() |> report(started)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, report(state, started)}
    end
  end

  defp activate(state) do
    at = Clock.monotonic_ms()

    case Storage.activate_projection(state.generation) do
      :ok ->
        emit_phase(:activate, state, Clock.monotonic_ms() - at, %{
          differences: state.differences
        })

        Checkpoints.put(
          state.name,
          %{"seq" => state.cursor, "watermark" => state.watermark},
          Map.merge(state.counts, %{
            "differences" => state.differences,
            "drained" => state.drained,
            "finished_at" => iso(Clock.db_now())
          }),
          "activated",
          repo: repo()
        )

        {:ok, %{state | activated: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Warm keys only, and a failure here is logged rather than raised: the totals
  # are right, `AuroraMeter.Events.total/3` reads them, and a cold key seeds
  # from the new generation on its first read anyway. Turning a correct rebuild
  # into an error because an ETS row could not be re-seated would be the wrong
  # trade for a view.
  defp rehydrate(state) do
    if Keyword.get(state.opts, :rehydrate, true) do
      rehydrate_keys(:ets.select(Store.counters_table(), key_spec(), @rehydrate_chunk), 0)
    end

    state
  rescue
    error ->
      Logger.warning(
        "AuroraMeter: re-seating in-memory counters after activating projection " <>
          "generation #{state.generation} failed (#{Exception.message(error)}). The durable " <>
          "totals are correct and AuroraMeter.Events.total/3 reads them; each key corrects " <>
          "itself on its next cold read."
      )

      state
  end

  defp key_spec, do: [{{:"$1", :_, :_, :_, :_, :_}, [], [:"$1"]}]

  defp rehydrate_keys(:"$end_of_table", done), do: done

  defp rehydrate_keys({keys, continuation}, done) do
    done =
      Enum.reduce(keys, done, fn key, done ->
        if events_key?(key), do: done + seat(key), else: done
      end)

    rehydrate_keys(:ets.select(continuation), done)
  end

  defp seat(key) do
    case Counter.rehydrate(key) do
      :ok -> 1
      :cold -> 0
    end
  end

  defp events_key?({_tenant, feature, %DateTime{}}), do: Config.feature_source(feature) == :events
  defp events_key?(_other), do: false

  # -- prune -----------------------------------------------------------------

  defp pruning(generation) do
    state = status()

    cond do
      generation == state.active_generation ->
        {:error, :active}

      generation == state.building_generation ->
        abandon(state, generation)

      rows?(generation) ->
        {:ok, delete_generation(generation)}

      true ->
        {:error, :not_found}
    end
  end

  defp abandon(state, generation) do
    deleted = delete_generation(generation)
    deleted = deleted + delete_generation(state.seed_generation || -generation)

    repo().query!(
      """
      UPDATE aurora_meter_checkpoints
         SET cursor = cursor - 'building_generation' - 'watermark' - 'seed_generation',
             updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
       WHERE name = 'events_projection'
      """,
      []
    )

    # The cursor goes back to nothing as well as the state. Leaving it would
    # make the NEXT build of this generation number resume from a seq whose
    # rows were just deleted, and it would be short by everything below the
    # cursor: the same silent shortfall the watermark exists to prevent,
    # arriving from the other end.
    case Checkpoints.update(
           checkpoint_name(generation),
           [cursor: %{"seq" => 0}, state: "abandoned"],
           repo: repo()
         ) do
      :ok -> {:ok, deleted}
      {:error, :not_found} -> {:ok, deleted}
    end
  end

  defp rows?(generation) do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM aurora_meter_event_totals WHERE generation = $1 LIMIT 1",
        [generation]
      )

    count > 0
  end

  # Bounded slices, so a generation with a million keys never takes one long
  # lock. The bound is a `LIMIT` on the ids, which the `(generation)` index
  # 03a created serves.
  defp delete_generation(generation, deleted \\ 0) do
    %{num_rows: rows} =
      repo().query!(
        """
        DELETE FROM aurora_meter_event_totals
         WHERE id IN (SELECT id FROM aurora_meter_event_totals
                       WHERE generation = $1 LIMIT $2)
        """,
        [generation, @default_drain_size]
      )

    if rows == 0, do: deleted, else: delete_generation(generation, deleted + rows)
  end

  # -- reporting -------------------------------------------------------------

  defp report(state, started) do
    %{
      generation: state.generation,
      scanned: state.scanned,
      projected: state.projected,
      keys: state.keys,
      batches: state.batches,
      differences: state.differences,
      activated: state.activated,
      duration_ms: Clock.monotonic_ms() - started
    }
  end

  defp replay_checkpoint(nil), do: nil

  defp replay_checkpoint(generation),
    do: Checkpoints.get(checkpoint_name(generation), repo: repo())

  defp empty_status do
    %{
      active_generation: 0,
      building_generation: nil,
      previous_generation: nil,
      seed_generation: nil,
      watermark: nil,
      replay: nil
    }
  end

  # The literal event names rather than module attributes, so the inventory
  # guard that greps `lib/` for emit sites can see them (A05).
  defp emit_phase(phase, state, duration, metadata) do
    :telemetry.execute(
      [:aurora_meter, :replay, :phase],
      %{duration: duration},
      Map.merge(metadata, %{generation: state.generation, phase: phase})
    )
  end

  defp cursor_of(nil), do: 0
  defp cursor_of(%{cursor: cursor}), do: Map.get(cursor, "seq", 0)

  defp bump(counts, key, by), do: Map.update(counts, key, by, &(&1 + by))

  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp utc(%DateTime{} = instant), do: instant

  defp iso(%DateTime{} = instant), do: DateTime.to_iso8601(instant)

  defp repo, do: Config.repo()
end
