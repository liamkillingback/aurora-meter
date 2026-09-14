defmodule AuroraMeter.Storage.Ecto do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  Default `AuroraMeter.Storage` adapter, backed by the host's Ecto repo
  (`AuroraMeter.Config.repo/0`). Counter and event writes use `insert_all` for
  throughput. Flushes add deltas in a transaction with a unique batch receipt,
  so retrying an uncertain commit cannot duplicate usage.
  """

  @behaviour AuroraMeter.Storage

  import Ecto.Query

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Events.Canonical
  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Schema.FlushReceipt
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Schema.Subscription

  @capabilities [:durable_events, :corrections, :projection_generations, :event_streaming]

  @projection_checkpoint "events_projection"

  # The backstop for build unit 03e's cumulative bound. It can only fire if that
  # bound is wrong, so the adapter names it rather than passing it through.
  @totals_quantity_check "aurora_meter_event_totals_quantity_check"

  @event_columns [
    :id,
    :seq,
    :tenant_key,
    :event_id,
    :feature,
    :quantity,
    :kind,
    :original_event_id,
    :occurred_at,
    :inserted_at,
    :period_start,
    :period_source,
    :dimensions,
    :metadata,
    :plan_id,
    :plan_version,
    :attribution,
    :payload_hash
  ]

  @default_stream_limit 1000

  @impl AuroraMeter.Storage
  def flush_batch(id, counters, history) do
    repo().transaction(fn ->
      {inserted, _} =
        repo().insert_all(FlushReceipt, [%{id: id, inserted_at: Clock.now()}],
          on_conflict: :nothing,
          conflict_target: [:id]
        )

      if inserted == 1 do
        {:ok, counter_totals} = add_counters(counters)
        {:ok, history_totals} = add_history(history)
        %{counters: counter_totals, history: history_totals}
      else
        %{
          counters:
            Enum.map(counters, fn row ->
              %{
                tenant_key: row.tenant_key,
                feature: to_string(row.feature),
                period_start: row.period_start,
                value: load_counter(row.tenant_key, row.feature, row.period_start) || 0
              }
            end),
          history:
            Enum.map(history, fn row ->
              %{
                tenant_key: row.tenant_key,
                feature: to_string(row.feature),
                date: row.date,
                value: load_history(row.tenant_key, row.feature, row.date) || 0
              }
            end)
        }
      end
    end)
  end

  @impl AuroraMeter.Storage
  def upsert_counters(rows) do
    now = Clock.now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          period_start: row.period_start,
          value: row.value,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all(Counter, entries,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:tenant_key, :feature, :period_start]
    )

    :ok
  end

  @impl AuroraMeter.Storage
  def add_counters(rows) do
    now = Clock.now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          period_start: row.period_start,
          value: row.delta,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, returned} =
      repo().insert_all(Counter, entries,
        on_conflict:
          from(c in Counter,
            update: [
              set: [
                value: fragment("? + EXCLUDED.value", c.value),
                updated_at: fragment("EXCLUDED.updated_at")
              ]
            ]
          ),
        conflict_target: [:tenant_key, :feature, :period_start],
        returning: [:tenant_key, :feature, :period_start, :value]
      )

    {:ok,
     Enum.map(returned, fn c ->
       %{
         tenant_key: c.tenant_key,
         feature: c.feature,
         period_start: c.period_start,
         value: c.value
       }
     end)}
  end

  @impl AuroraMeter.Storage
  def add_history(rows) do
    now = Clock.now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          bucket_kind: "day",
          bucket_start: row.date,
          value: row.delta,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, returned} =
      repo().insert_all(History, entries,
        on_conflict:
          from(h in History,
            update: [
              set: [
                value: fragment("? + EXCLUDED.value", h.value),
                updated_at: fragment("EXCLUDED.updated_at")
              ]
            ]
          ),
        conflict_target: [:tenant_key, :feature, :bucket_kind, :bucket_start],
        returning: [:tenant_key, :feature, :bucket_start, :value]
      )

    {:ok,
     Enum.map(returned, fn h ->
       %{tenant_key: h.tenant_key, feature: h.feature, date: h.bucket_start, value: h.value}
     end)}
  end

  @impl AuroraMeter.Storage
  def load_counter(tenant_key, feature, period_start) do
    feature = to_string(feature)

    repo().one(
      from(c in Counter,
        where:
          c.tenant_key == ^tenant_key and c.feature == ^feature and
            c.period_start == ^period_start,
        select: c.value
      )
    )
  end

  @impl AuroraMeter.Storage
  def upsert_history(rows) do
    now = Clock.now()

    entries =
      Enum.map(rows, fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          bucket_kind: "day",
          bucket_start: row.date,
          value: row.value,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all(History, entries,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:tenant_key, :feature, :bucket_kind, :bucket_start]
    )

    :ok
  end

  @impl AuroraMeter.Storage
  def load_history(tenant_key, feature, date) do
    feature = to_string(feature)

    repo().one(
      from(h in History,
        where:
          h.tenant_key == ^tenant_key and h.feature == ^feature and h.bucket_kind == "day" and
            h.bucket_start == ^date,
        select: h.value
      )
    )
  end

  @impl AuroraMeter.Storage
  def load_history_range(tenant_key, feature, from, to) do
    feature = to_string(feature)

    repo().all(
      from(h in History,
        where:
          h.tenant_key == ^tenant_key and h.feature == ^feature and h.bucket_kind == "day" and
            h.bucket_start >= ^from and h.bucket_start <= ^to,
        order_by: [asc: h.bucket_start],
        select: %{date: h.bucket_start, value: h.value}
      )
    )
  end

  @impl AuroraMeter.Storage
  def get_subscription(tenant_key), do: repo().get_by(Subscription, tenant_key: tenant_key)

  @impl AuroraMeter.Storage
  def put_subscription(attrs) do
    %Subscription{}
    |> Subscription.changeset(Map.new(attrs))
    |> repo().insert(
      on_conflict: {:replace_all_except, [:id, :tenant_key, :inserted_at]},
      conflict_target: [:tenant_key],
      returning: true
    )
  end

  @impl AuroraMeter.Storage
  # Keyset on `tenant_key`, which carries the table's unique index, so the scan
  # is index-backed and a page cannot repeat or skip a row when another process
  # inserts or deletes one between pages. `next_cursor` is nil exactly when the
  # page came back shorter than `limit`, which is the only honest end signal: a
  # page that is exactly full may or may not be the last one, so the caller is
  # asked once more rather than guessing.
  def list_subscriptions(cursor, opts) do
    limit = Keyword.get(opts, :limit, 100)

    rows =
      Subscription
      |> after_cursor(cursor)
      |> with_statuses(Keyword.get(opts, :status_in))
      |> then(&from(s in &1, order_by: [asc: s.tenant_key], limit: ^limit))
      |> repo().all()

    if length(rows) < limit do
      {rows, nil}
    else
      {rows, List.last(rows).tenant_key}
    end
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, cursor), do: from(s in query, where: s.tenant_key > ^cursor)

  defp with_statuses(query, nil), do: query
  defp with_statuses(query, statuses), do: from(s in query, where: s.status in ^statuses)

  @impl AuroraMeter.Storage
  # Core schema version 8 makes `event_id`, `payload_hash` and `occurred_at`
  # NOT NULL, so this path has to supply all three or stop writing. It supplies
  # the weakest possible versions of them, because that is exactly what the
  # legacy durable-track path is.
  #
  # The `event_id` is a fresh `track:` value per call, so a retry of the same
  # `AuroraMeter.track/4` writes a second row, as it always has. This path has
  # no caller identity to deduplicate on; `AuroraMeter.record/4` (03b) is the
  # one that does. `occurred_at` is the write instant, because `track/4` never
  # accepted an occurrence time. `attribution` is `"legacy_track"`, which is
  # what marks a row on this path as never having been billed.
  #
  # `period_start` and `period_source` are carried in the row by
  # `AuroraMeter.track/4`, which already resolved the period for the counter it
  # bumped: the row is charged to the same window as the increment it
  # accompanies, and a second lookup that could land on the other side of a
  # boundary is avoided. A caller that supplies neither (a 0.4.x caller of
  # `AuroraMeter.Storage.insert_events/1`) still gets a valid row with a null
  # period, as it always did.
  #
  # Three things this path deliberately does NOT do, each asserted by
  # `AuroraMeter.LegacyDurableTrackTest`:
  #
  #   * no projection. `aurora_meter_event_totals` is untouched, so a legacy row
  #     contributes to no total and `AuroraMeter.Events.total/3` never counts it.
  #   * no outbox. The `AuroraMeter.Events.Outbox` seam is reached from
  #     `record_events/2` only, so no export intent is ever staged from a track.
  #   * no deduplication. The `event_id` is a fresh uuid, so two identical calls
  #     make two rows.
  #
  # The negative space is the contract: `attribution: "legacy_track"` is what
  # separates these rows from recorded ones in every query, report and replay.
  def insert_events(rows) do
    now = Clock.now()

    entries =
      Enum.map(rows, fn row ->
        feature = to_string(row.feature)
        quantity = Map.get(row, :quantity, 1)
        metadata = Map.get(row, :metadata, %{})

        %{
          tenant_key: row.tenant_key,
          feature: feature,
          quantity: quantity,
          metadata: metadata,
          inserted_at: now,
          event_id: "track:" <> Ecto.UUID.generate(),
          occurred_at: now,
          period_start: Map.get(row, :period_start),
          period_source: period_source(Map.get(row, :period_source)),
          attribution: "legacy_track",
          payload_hash:
            Canonical.legacy_payload_hash(%{
              feature: feature,
              quantity: quantity,
              occurred_at: now,
              metadata: metadata
            })
        }
      end)

    repo().insert_all(Event, entries)
    :ok
  end

  @spec period_source(atom() | String.t() | nil) :: String.t() | nil
  defp period_source(nil), do: nil
  defp period_source(source) when is_binary(source), do: source
  defp period_source(source) when is_atom(source), do: Atom.to_string(source)

  @impl AuroraMeter.Storage
  def stream_counters(period_start) do
    repo().all(from(c in Counter, where: c.period_start == ^period_start))
  end

  # -- durable events --------------------------------------------------------

  @impl AuroraMeter.Storage
  def capabilities, do: @capabilities

  @doc """
  Whether this call is already inside a transaction the **host** opened.

  It is `repo.in_transaction?/0`, which reads the Ecto-side connection this
  process holds: `Ecto.Adapters.SQL`'s implementation matches on a
  `conn_mode: :transaction` connection in the process dictionary, and the
  sandbox's own `BEGIN` is issued inside the connection process rather than
  through it. The value is measured rather than assumed in
  `docs/evidence/v1/phase-03/03b-in-transaction.md`, including under
  `Ecto.Adapters.SQL.Sandbox`, because the correct implementation depends on an
  observable fact about `ecto_sql` and not on a reading of its documentation.
  """
  @spec host_transaction?() :: boolean()
  def host_transaction?, do: repo().in_transaction?()

  @impl AuroraMeter.Storage
  def record_events([], _opts), do: {:ok, []}

  def record_events(entries, opts) when is_list(entries) do
    timeout = Keyword.get(opts, :timeout) || Config.record_timeout()

    outbox =
      Keyword.get(opts, :outbox) || Config.events_outbox() || AuroraMeter.Events.Outbox.Noop

    durability = if host_transaction?(), do: :conditional, else: :durable

    guarded(fn ->
      repo().transaction(
        fn -> in_transaction(entries, outbox, timeout, durability) end,
        timeout: timeout
      )
    end)
  end

  @impl AuroraMeter.Storage
  def record_correction(entry, opts) do
    timeout = Keyword.get(opts, :timeout) || Config.record_timeout()

    outbox =
      Keyword.get(opts, :outbox) || Config.events_outbox() || AuroraMeter.Events.Outbox.Noop

    durability = if host_transaction?(), do: :conditional, else: :durable

    request = Map.put(entry, :replacement, Keyword.get(opts, :replacement))

    state = %{
      repo: repo(),
      request: request,
      outbox: outbox,
      timeout: timeout,
      durability: durability
    }

    guarded(fn ->
      state.repo.transaction(fn -> correction_transaction(state) end, timeout: timeout)
    end)
    |> unwrap_correction()
  end

  @impl AuroraMeter.Storage
  def load_event(tenant_key, event_id) do
    case repo().one(
           from(e in Event, where: e.tenant_key == ^tenant_key and e.event_id == ^event_id)
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, AuroraMeter.Event.from_row(row)}
    end
  end

  @impl AuroraMeter.Storage
  def load_event_total(tenant_key, feature, period_start) do
    feature = to_string(feature)
    generation = active_generation(repo())

    total =
      repo().one(
        from(t in EventTotal,
          where:
            t.tenant_key == ^tenant_key and t.feature == ^feature and
              t.period_start == ^period_start and t.generation == ^generation,
          select: %{quantity: t.quantity, events: t.events}
        )
      )

    {:ok, total || %{quantity: 0, events: 0}}
  end

  @impl AuroraMeter.Storage
  def stream_events(cursor, opts) when is_integer(cursor) do
    limit = Keyword.get(opts, :limit, @default_stream_limit)

    query =
      from(e in Event, where: e.seq > ^cursor, order_by: [asc: e.seq], limit: ^limit)
      |> filter(:tenant_key, Keyword.get(opts, :tenant))
      |> filter(:feature, feature_filter(Keyword.get(opts, :feature)))
      |> occurred_from(Keyword.get(opts, :from))
      |> occurred_to(Keyword.get(opts, :to))

    {:ok, Enum.map(repo().all(query), &AuroraMeter.Event.from_row/1)}
  end

  # -- projection generations (build unit 03d) --------------------------------

  # The announcement, and the whole of why a forward scan of a table that is
  # still being written is sound here.
  #
  # `FOR UPDATE` on the `events_projection` row is granted only once every
  # in-flight `record_events/2` and `record_correction/2`, each of which took
  # `FOR SHARE` on that row before inserting anything, has committed or rolled
  # back. So `max(seq)` read in this transaction is a watermark: every event at
  # or below it belongs to a transaction that committed before this one
  # returned, and every record that starts afterwards reads
  # `building_generation` and writes both generations. There is no third case.
  #
  # ## The seed, and the reason it is not optional
  #
  # 03a put `CHECK (quantity >= 0)` on `aurora_meter_event_totals`. A
  # correction applies a NEGATIVE delta, and while a generation is being built
  # it applies it to both generations (03b's dual write). A correction whose
  # original committed at or below the watermark but whose key the scan has not
  # reached yet would therefore drive the BUILDING generation's row below zero
  # and be refused by that constraint, with `record_correction/2` reporting
  # `exceeds_original` for a correction that is perfectly legal. 03e recorded
  # this as replay's problem to solve ("NOTE FOR 03d" in
  # `apply_correction_totals/2`).
  #
  # Copying the active generation into the building generation inside this
  # transaction fixes it by making one thing true for the whole build:
  #
  #     building(key) == active(key) + (whatever the scan has added so far)
  #
  # Both terms are non-negative (the constraint holds on the active generation,
  # and the scan's running sum per key is non-negative because an original
  # always has a lower `seq` than its corrections), so the building generation
  # is refused by that constraint exactly when the active generation would have
  # been, and never on its own account.
  #
  # The seed then has to be taken back out, so the same rows are frozen in a
  # second generation, `-building`, which nothing else ever writes.
  # `drain_projection_seed/2` subtracts and deletes them once the scan is
  # complete, leaving `scan + live deltas`, which is the answer.
  @impl AuroraMeter.Storage
  def begin_projection_generation do
    guarded(fn -> repo().transaction(&announce_or_resume/0) end)
  end

  defp announce_or_resume do
    cursor = lock_projection_row()
    active = Map.get(cursor, "active_generation", 0)

    case Map.get(cursor, "building_generation") do
      nil -> announce(cursor, active)
      building -> resumed(cursor, active, building)
    end
  end

  defp announce(_cursor, active) do
    building = active + 1
    seed = seed_generation(building)

    %{rows: [[watermark]]} =
      repo().query!("SELECT coalesce(max(seq), 0) FROM aurora_meter_events", [])

    seeded = copy_generation(active, building, seed)

    repo().query!(
      """
      UPDATE aurora_meter_checkpoints
         SET cursor = cursor || jsonb_build_object(
               'building_generation', $2::int,
               'seed_generation', $3::int,
               'watermark', $4::bigint),
             state = 'active',
             updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
       WHERE name = $1
      """,
      [@projection_checkpoint, building, seed, watermark]
    )

    %{
      generation: building,
      active_generation: active,
      seed_generation: seed,
      watermark: watermark,
      seeded: seeded,
      resumed: false
    }
  end

  defp resumed(cursor, active, building) do
    %{
      generation: building,
      active_generation: active,
      seed_generation: Map.get(cursor, "seed_generation", seed_generation(building)),
      watermark: Map.get(cursor, "watermark", 0),
      seeded: 0,
      resumed: true
    }
  end

  # One statement, two target generations, so the copy cannot be half done.
  # `ORDER BY` the key columns for the same reason every other multi-row write
  # in this module sorts (L-03b-3), although nothing can be concurrent with it:
  # the caller holds `FOR UPDATE` on the row every writer share-locks first.
  defp copy_generation(active, building, seed) do
    %{num_rows: rows} =
      repo().query!(
        """
        INSERT INTO aurora_meter_event_totals
          (id, tenant_key, feature, period_start, generation, quantity, events,
           inserted_at, updated_at)
        SELECT gen_random_uuid(), t.tenant_key, t.feature, t.period_start, g.generation,
               t.quantity, t.events,
               (clock_timestamp() AT TIME ZONE 'UTC'), (clock_timestamp() AT TIME ZONE 'UTC')
          FROM aurora_meter_event_totals t
          CROSS JOIN (VALUES ($2::int), ($3::int)) AS g(generation)
         WHERE t.generation = $1
         ORDER BY t.tenant_key, t.feature, t.period_start, g.generation
        ON CONFLICT (tenant_key, feature, period_start, generation) DO NOTHING
        """,
        [active, building, seed]
      )

    rows
  end

  @impl AuroraMeter.Storage
  def projection_state do
    guarded(fn ->
      %{rows: [[cursor]]} =
        repo().query!("SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1", [
          @projection_checkpoint
        ])

      cursor = cursor || %{}

      {:ok,
       %{
         active_generation: Map.get(cursor, "active_generation", 0),
         building_generation: Map.get(cursor, "building_generation"),
         previous_generation: Map.get(cursor, "previous_generation"),
         seed_generation: Map.get(cursor, "seed_generation"),
         watermark: Map.get(cursor, "watermark")
       }}
    end)
  end

  @impl AuroraMeter.Storage
  def write_projection_totals(_generation, []), do: :ok

  # ADD, not replace, and in TWO statements rather than one upsert.
  #
  # Add, because a record that commits while this generation is being built has
  # already written its own delta here (03b's dual write) and a replay batch
  # that set an absolute value would erase it.
  #
  # Two statements, because a batch's net delta for a key can be **negative**:
  # a replay reads events in `seq` order, and a batch that happens to contain
  # only corrections for a key proposes a negative quantity for it. `open-
  # findings.md` X124: Postgres applies a `CHECK` to the tuple an
  # `INSERT ... ON CONFLICT DO UPDATE` proposes, before the conflict is
  # resolved, so a single upsert is refused by
  # `aurora_meter_event_totals_quantity_check` even though the row the UPDATE
  # would leave is positive. Measured here on the 10,000 corrections of
  # `AuroraMeter.EventsReplayLargeTest`, which is the same defect 03e's
  # `move_total/2` documents and the same remedy: make the row exist at zero,
  # then move it, so the constraint judges the value that results.
  #
  # Both statements take the entries in one total order, the same
  # `{tenant_key, feature, period_start}` order the record and correction paths
  # sort by (L-03b-3), so writers meet rows in the same sequence.
  def write_projection_totals(generation, rows) do
    now = Clock.now()

    entries =
      rows
      |> Enum.map(fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          period_start: row.period_start,
          quantity: row.quantity,
          events: row.events
        }
      end)
      |> Enum.sort_by(&{&1.tenant_key, &1.feature, &1.period_start})

    guarded(fn ->
      ensure_total_rows(generation, entries, now)
      move_totals(generation, entries)
      :ok
    end)
  end

  defp ensure_total_rows(generation, entries, now) do
    zeroes =
      Enum.map(entries, fn entry ->
        %{
          tenant_key: entry.tenant_key,
          feature: entry.feature,
          period_start: entry.period_start,
          generation: generation,
          quantity: 0,
          events: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    repo().insert_all(EventTotal, zeroes,
      on_conflict: :nothing,
      conflict_target: [:tenant_key, :feature, :period_start, :generation]
    )
  end

  defp move_totals(generation, entries) do
    repo().query!(
      """
      UPDATE aurora_meter_event_totals t
         SET quantity = t.quantity + v.quantity,
             events = t.events + v.events,
             updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
        FROM (SELECT * FROM unnest($2::text[], $3::text[], $4::timestamp[],
                                   $5::bigint[], $6::bigint[])
                       AS u(tenant_key, feature, period_start, quantity, events)
               ORDER BY tenant_key, feature, period_start) AS v
       WHERE t.generation = $1
         AND t.tenant_key = v.tenant_key
         AND t.feature = v.feature
         AND t.period_start = v.period_start
      """,
      [
        generation,
        Enum.map(entries, & &1.tenant_key),
        Enum.map(entries, & &1.feature),
        Enum.map(entries, & &1.period_start),
        Enum.map(entries, & &1.quantity),
        Enum.map(entries, & &1.events)
      ]
    )
  end

  # The seed row is its own cursor: it is subtracted and deleted in one
  # statement, so a kill between two slices leaves the remaining rows to be
  # drained and no row can ever be subtracted twice. `taken` and `applied` are
  # counted separately and compared by the caller, because a seed row with no
  # partner in the generation it seeded would mean the copy was not atomic.
  @impl AuroraMeter.Storage
  def drain_projection_seed(seed_generation, limit)
      when is_integer(seed_generation) and is_integer(limit) and limit > 0 do
    guarded(fn ->
      %{rows: [[taken, applied]]} =
        repo().query!(
          """
          WITH slice AS (
            SELECT id FROM aurora_meter_event_totals
             WHERE generation = $1
             ORDER BY tenant_key, feature, period_start
             LIMIT $3
          ), taken AS (
            DELETE FROM aurora_meter_event_totals t
             USING slice
             WHERE t.id = slice.id
            RETURNING t.tenant_key, t.feature, t.period_start, t.quantity, t.events
          ), applied AS (
            UPDATE aurora_meter_event_totals b
               SET quantity = b.quantity - taken.quantity,
                   events = b.events - taken.events,
                   updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
              FROM taken
             WHERE b.generation = $2
               AND b.tenant_key = taken.tenant_key
               AND b.feature = taken.feature
               AND b.period_start = taken.period_start
            RETURNING b.id
          )
          SELECT (SELECT count(*) FROM taken), (SELECT count(*) FROM applied)
          """,
          [seed_generation, generation_of_seed(seed_generation), limit]
        )

      if taken == applied do
        {:ok, taken}
      else
        {:error, {:seed_without_generation, %{taken: taken, applied: applied}}}
      end
    end)
  end

  @impl AuroraMeter.Storage
  def activate_projection(generation) when is_integer(generation) do
    guarded(fn ->
      repo().transaction(fn ->
        # `FOR UPDATE` against the `FOR SHARE` every record transaction takes.
        # The exclusive lock is granted only once every in-flight record has
        # committed, so a generation can never be activated underneath a record
        # that already read the old one.
        cursor = lock_projection_row()
        previous = Map.get(cursor, "active_generation", 0)

        repo().query!(
          """
          UPDATE aurora_meter_checkpoints
             SET cursor = (cursor - 'building_generation' - 'watermark' - 'seed_generation')
                          || jsonb_build_object(
                   'active_generation', $2::int,
                   'previous_generation', $3::int
                 ),
                 state = 'active',
                 updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
           WHERE name = $1
          """,
          [@projection_checkpoint, generation, previous]
        )

        :ok
      end)

      :ok
    end)
  end

  defp lock_projection_row do
    %{rows: [[cursor]]} =
      repo().query!(
        "SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1 FOR UPDATE",
        [@projection_checkpoint]
      )

    cursor || %{}
  end

  @doc """
  The generation that holds the frozen copy of the active generation taken when
  `building` was announced.

  Negative, so it cannot collide with any generation a replay will ever build
  and an operator reading the table can see at a glance which rows are the
  seed for which build.

  ## Examples

      iex> AuroraMeter.Storage.Ecto.seed_generation(3)
      -3

  """
  @spec seed_generation(pos_integer()) :: neg_integer()
  def seed_generation(building) when is_integer(building) and building > 0, do: -building

  defp generation_of_seed(seed) when is_integer(seed) and seed < 0, do: -seed

  # -- the record transaction ------------------------------------------------

  # Six steps, in this order, and the order is the design:
  #
  #   1. read (and share-lock) the generation state
  #   2. insert the events
  #   3. resolve every entry the insert did not return
  #   4. apply the totals deltas for the inserted rows only
  #   5. hand the export intents to the outbox
  #   6. commit
  #
  # Steps 2 and 4 sort their entries by a total order before the statement, so
  # two concurrent batches touching the same rows acquire them in the same
  # order and cannot deadlock (L-03b-3).
  defp in_transaction(entries, outbox, timeout, durability) do
    repo = repo()
    generations = lock_generations(repo, timeout)

    inserted = insert_events_returning(repo, entries, timeout)
    resolved = resolve(repo, entries, inserted, timeout, durability)

    fresh = for {_index, {event, :inserted}} <- resolved, do: event

    apply_totals(repo, fresh, generations, timeout)
    enqueue(outbox, fresh, repo, timeout)

    resolved |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end

  # `FOR SHARE`, not `FOR UPDATE`: two records do not block each other, and
  # both block `activate_projection/1`. This single row is the only
  # serialisation point between recording and generation activation.
  defp lock_generations(repo, timeout) do
    %{rows: [[cursor]]} =
      repo.query!(
        "SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1 FOR SHARE",
        [@projection_checkpoint],
        timeout: timeout
      )

    active = Map.get(cursor || %{}, "active_generation", 0)
    building = Map.get(cursor || %{}, "building_generation")

    Enum.uniq(Enum.reject([active, building], &is_nil/1))
  end

  defp insert_events_returning(repo, entries, timeout) do
    rows =
      entries
      |> Enum.map(&row/1)
      |> Enum.sort_by(&{&1.tenant_key, &1.event_id})

    {_count, returned} =
      repo.insert_all(Event, rows,
        on_conflict: :nothing,
        conflict_target: [:tenant_key, :event_id],
        returning: @event_columns,
        timeout: timeout
      )

    Map.new(returned, &{{&1.tenant_key, &1.event_id}, &1})
  end

  # `on_conflict: :nothing` returns only the rows it really inserted. For every
  # entry that is missing from that set, read the row back and compare hashes.
  #
  # The one thing this must never do is treat "not returned and not found" as a
  # duplicate. That would silently accept a conflicting reuse of an identity,
  # which is the single defect this unit exists to prevent. It is reported as
  # `{:unavailable, :conflict_unresolved}` and the caller retries with the same
  # id, which then gets a definite answer.
  defp resolve(repo, entries, inserted, timeout, durability) do
    missing = Enum.reject(entries, &Map.has_key?(inserted, identity(&1)))
    existing = read_back(repo, missing, timeout)

    Enum.map(Enum.with_index(entries), fn {entry, index} ->
      outcome(
        repo,
        entry,
        index,
        Map.fetch(inserted, identity(entry)),
        Map.fetch(existing, identity(entry)),
        durability
      )
    end)
  end

  defp outcome(_repo, _entry, index, {:ok, row}, _existing, durability) do
    {index, {AuroraMeter.Event.from_row(row, durability), :inserted}}
  end

  defp outcome(repo, entry, index, :error, {:ok, row}, durability) do
    event = AuroraMeter.Event.from_row(row, durability)

    if row.payload_hash == entry.payload_hash do
      {index, {event, :duplicate}}
    else
      repo.rollback({:conflict, index, event})
    end
  end

  defp outcome(repo, _entry, _index, :error, :error, _durability) do
    repo.rollback({:unavailable, :conflict_unresolved})
  end

  defp read_back(_repo, [], _timeout), do: %{}

  defp read_back(repo, missing, timeout) do
    pairs = Enum.map(missing, &identity/1)
    tenant_keys = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    event_ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(pairs)

    repo.all(
      from(e in Event, where: e.tenant_key in ^tenant_keys and e.event_id in ^event_ids),
      timeout: timeout
    )
    |> Enum.filter(&MapSet.member?(wanted, {&1.tenant_key, &1.event_id}))
    |> Map.new(&{{&1.tenant_key, &1.event_id}, &1})
  end

  # Inserted rows only. A duplicate contributes no quantity and no event count,
  # which is the whole of "no second projection effect" (I06).
  defp apply_totals(_repo, [], _generations, _timeout), do: :ok

  defp apply_totals(repo, events, generations, timeout) do
    entries =
      events
      |> Enum.group_by(&{&1.tenant_key, to_string(&1.feature), &1.period_start})
      |> Enum.flat_map(fn {{tenant_key, feature, period_start}, group} ->
        quantity = Enum.reduce(group, 0, &(&1.quantity + &2))

        Enum.map(generations, fn generation ->
          %{
            tenant_key: tenant_key,
            feature: feature,
            period_start: period_start,
            generation: generation,
            quantity: quantity,
            events: length(group),
            inserted_at: Clock.now(),
            updated_at: Clock.now()
          }
        end)
      end)
      |> Enum.sort_by(&{&1.tenant_key, &1.feature, &1.period_start, &1.generation})

    repo.insert_all(EventTotal, entries,
      on_conflict:
        from(t in EventTotal,
          update: [
            set: [
              quantity: fragment("? + EXCLUDED.quantity", t.quantity),
              events: fragment("? + EXCLUDED.events", t.events),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:tenant_key, :feature, :period_start, :generation],
      timeout: timeout
    )

    :ok
  end

  defp enqueue(_outbox, [], _repo, _timeout), do: :ok

  # A raise and an `{:error, reason}` are the same answer: the intent was not
  # staged, so the fact must not commit without it. Both roll back and surface
  # as `{:unavailable, {:outbox, reason}}`, which the caller retries with the
  # same id. Letting the exception escape instead would give the caller an
  # exception where the contract promises an error tuple, and an implementation
  # that raises is exactly the one whose caller is least likely to be ready for
  # that.
  defp enqueue(outbox, events, repo, timeout) do
    items = Enum.map(events, &%{event: &1, eligibility: eligibility(&1)})

    result =
      try do
        outbox.enqueue(items, %{repo: repo, timeout: timeout})
      rescue
        error -> {:error, {:raised, error.__struct__, Exception.message(error)}}
      catch
        :throw, value -> {:error, {:threw, value}}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> repo.rollback({:unavailable, {:outbox, reason}})
      other -> repo.rollback({:unavailable, {:outbox, {:unexpected_return, other}}})
    end
  end

  # Core computes eligibility from facts core owns and nothing else. Everything
  # provider-shaped is the outbox implementation's decision at enqueue time.
  defp eligibility(%AuroraMeter.Event{attribution: :unresolved}),
    do: {:ineligible, :attribution_unresolved}

  defp eligibility(%AuroraMeter.Event{feature: feature} = event) do
    if Config.feature_source(feature) == :buffered and event.kind == :usage do
      {:ineligible, :feature_buffered}
    else
      :eligible
    end
  end

  # -- the correction transaction (build unit 03e) ----------------------------

  # Seven steps, and the ORDER IS THE DESIGN. Two orderings are wrong and both
  # are financial defects; `docs/evidence/v1/phase-03/03e-step-order.md` names
  # them, the observed failure of each, and the test that catches it.
  #
  #   1. share-lock the generation state, exactly as `record_events/2` does, so
  #      a correction and a record never take these locks in different orders
  #   2. the duplicate check, BEFORE the bound check
  #   3. `FOR UPDATE` on the ORIGINAL: the serialisation point for every
  #      corrector of this one fact, and of nothing else
  #   3b. the duplicate check again, now under that lock
  #   4. the cumulative sum and the bound (I09)
  #   5. insert the correction (and, for `replace/4`, its replacement)
  #   6. apply the totals deltas, NEGATIVE for a correction
  #   7. hand the export intents to the outbox
  #
  # **Why step 2 precedes step 4.** A retry of a correction has its own
  # committed row inside the cumulative sum, so a bound evaluated first refuses
  # every retry with `exceeds_original`. Putting the duplicate check first is
  # the only way `correct/4` is both bounded and idempotent.
  #
  # **Why step 3b exists, and it is not in the build document.** Step 2 runs
  # before the lock, so a corrector that arrives while an identical correction
  # is still uncommitted sees nothing there. It then waits at step 3, and by the
  # time the lock is granted the other correction is committed and inside the
  # sum: without this second check the caller is told `exceeds_original` for a
  # correction that IS its own, which is the same defect the step order exists
  # to prevent, seen under concurrency instead of in sequence. The negative
  # control for it is
  # `AuroraMeter.CorrectConcurrencyTest / test I09 12 concurrent submissions of
  # one correction identity produce one row, one delta and one outbox item`.
  #
  # **Why the lock is on the original and not on the totals row.** The bound is
  # a property of one original event; the totals row aggregates many events
  # across many originals and is also written by every concurrent `record/4`
  # for that key, which is the hot path. The original row serialises exactly the
  # transactions that can violate I09 and nothing else.
  #
  # **Why `FOR UPDATE` and not a lease, a deadline or a timestamp comparison.**
  # `open-findings.md` X100: the one clock every node shares is not monotonic,
  # and steps backwards about 439 ms on a 32.5 second cadence on this hardware.
  # A row lock is decided by Postgres, is released by COMMIT, ROLLBACK or the
  # connection dying, and consults no clock at all, so there is nothing here for
  # a backwards step to invert.
  defp correction_transaction(state) do
    state = Map.put(state, :generations, lock_generations(state.repo, state.timeout))

    case read_event(state, state.request.event_id) do
      nil -> lock_original(state)
      row -> settle_duplicate(state, row, read_event(state, state.request.original_event_id))
    end
  end

  # Step 3. `READ COMMITTED` is what makes this work: every statement after the
  # lock is granted takes a fresh snapshot, so step 4's sum sees every
  # correction committed by a corrector that held this lock before us. A reader
  # who assumes repeatable-read semantics here would write a subtly wrong
  # implementation, which is why it is said twice (`architecture-map.md` 4.2).
  defp lock_original(state) do
    row =
      state.repo.one(
        from(e in Event,
          where:
            e.tenant_key == ^state.request.tenant_key and
              e.event_id == ^state.request.original_event_id,
          lock: "FOR UPDATE"
        ),
        timeout: state.timeout
      )

    cond do
      is_nil(row) -> {:refused, {:not_found, :original}}
      row.kind == "correction" -> {:refused, {:invalid, [original: :is_correction]}}
      true -> recheck_duplicate(state, row)
    end
  end

  # Step 3b.
  defp recheck_duplicate(state, original) do
    case read_event(state, state.request.event_id) do
      nil -> check_bound(state, original)
      row -> settle_duplicate(state, row, original)
    end
  end

  # Step 4. The partial index `aurora_meter_events_corrections_index` on
  # `(tenant_key, original_event_id) where kind = 'correction'` serves it.
  # `::bigint`, because `sum()` over a bigint column is `numeric` in Postgres
  # and would arrive as a `Decimal`; the bound is integer arithmetic and must
  # stay that way.
  defp check_bound(state, original) do
    corrected =
      state.repo.one(
        from(e in Event,
          where:
            e.tenant_key == ^state.request.tenant_key and
              e.original_event_id == ^original.event_id and e.kind == "correction",
          select: fragment("coalesce(sum(?), 0)::bigint", e.quantity)
        ),
        timeout: state.timeout
      )

    case magnitude(state.request.quantity, original.quantity, corrected) do
      {:ok, quantity} -> insert_correction(state, original, quantity)
      {:refused, _reason} = refusal -> refusal
    end
  end

  defp magnitude(:remaining, original_quantity, corrected) do
    case original_quantity - corrected do
      0 -> {:refused, {:invalid, [quantity: :already_fully_corrected]}}
      remaining -> {:ok, remaining}
    end
  end

  defp magnitude(quantity, original_quantity, corrected) do
    if corrected + quantity > original_quantity do
      {:refused, {:invalid, [quantity: :exceeds_original]}}
    else
      {:ok, quantity}
    end
  end

  # Steps 5, 6 and 7. The insert and the conflict resolution are
  # `record_events/2`'s own `insert_events_returning/3` and `resolve/5`, called
  # rather than copied: a correction is an event and inherits its identity
  # rules, its duplicate and conflict resolution and its refusal to guess when
  # the row is neither inserted nor visible (I06, I07).
  defp insert_correction(state, original, quantity) do
    entries = entries(state, original, quantity)
    inserted = insert_events_returning(state.repo, entries, state.timeout)
    resolved = state.repo |> resolve(entries, inserted, state.timeout, state.durability)

    outcomes = resolved |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    mixed!(state, outcomes)

    fresh = for {event, :inserted} <- outcomes, do: event

    apply_correction_totals(state, fresh)
    enqueue_corrections(state, fresh)

    outcomes
  end

  # `replace/4` is two rows or none. A state where one of the two identities is
  # already held and the other is not can only be reached by overriding
  # `replacement_id:` differently across attempts, and there is no honest
  # outcome for it: the caller asked for a pairing that does not exist.
  defp mixed!(_state, [_one]), do: :ok

  defp mixed!(_state, [{_correction, outcome}, {_replacement, outcome}]) when is_atom(outcome),
    do: :ok

  defp mixed!(state, outcomes) do
    index = Enum.find_index(outcomes, fn {_event, outcome} -> outcome == :duplicate end)
    {event, _outcome} = Enum.at(outcomes, index)
    state.repo.rollback({:conflict, index, event})
  end

  defp entries(state, original, quantity) do
    correction = correction_entry(state.request, original, quantity)

    case state.request.replacement do
      nil -> [correction]
      replacement -> [correction, replacement(state, original, replacement)]
    end
  end

  # L-03e-2: every field a correction inherits is copied here, inside the
  # transaction that read the original under lock, so none of them can drift
  # from it. `period_start` in particular: a September fact corrected in
  # October belongs to September's invoice, not October's (decision D08).
  defp correction_entry(request, original, quantity) do
    %{
      tenant_key: original.tenant_key,
      event_id: request.event_id,
      feature: original.feature,
      quantity: quantity,
      kind: "correction",
      original_event_id: original.event_id,
      occurred_at: original.occurred_at,
      period_start: original.period_start,
      period_source: original.period_source,
      attribution: original.attribution,
      dimensions: original.dimensions || %{},
      metadata: request.metadata,
      plan_id: original.plan_id,
      plan_version: original.plan_version,
      payload_hash: Canonical.correction_hash(original, quantity, request.metadata)
    }
  end

  # The replacement restates the same commercial fact, so its feature is the
  # original's. The facade resolved the period for the caller's new
  # `occurred_at` and hashed the payload; all that is left is to refuse a
  # feature that is not the original's, now that the original is in hand.
  # `to_string/1`: the entry carries the feature atom the facade validated and
  # the row carries the string the column holds, and comparing the two directly
  # is a check that can only ever fail.
  defp replacement(state, original, replacement) do
    if to_string(replacement.feature) == original.feature do
      replacement
    else
      state.repo.rollback({:invalid, [feature: :differs_from_original]})
    end
  end

  # L-03e-3: the delta for a correction is `-quantity` on `quantity` and `+1` on
  # `events`, so a key's projected quantity is its usage events less its
  # corrections and its event count is the number of rows of both kinds. A
  # replay (03d) uses the identical rule.
  #
  # Deliberately not `apply_totals/4`, and not the same statement either.
  #
  # `apply_totals/4` is `INSERT ... ON CONFLICT DO UPDATE SET quantity =
  # quantity + EXCLUDED.quantity`, and a correction cannot use it. 03a put
  # `CHECK (quantity >= 0)` on `aurora_meter_event_totals`, and **Postgres
  # applies a CHECK to the tuple the INSERT proposes, before the conflict is
  # resolved**: proposing `-3` against a row holding `10` is refused even though
  # the row the UPDATE would leave holds `7`. Measured on PostgreSQL 16.13 in
  # `docs/evidence/v1/phase-03/03e-totals-check.md`, which also shows the
  # backstop surviving: the same `-3` as an UPDATE is accepted and a `-100` that
  # really would go negative is still refused.
  #
  # So the delta is applied in two statements: make sure the row exists at zero,
  # then move it. `DO NOTHING` on the first waits for a concurrent uncommitted
  # insert of the same totals row exactly as `record_events/2`'s does (03b
  # measured 1505 ms), which is row-level serialisation bounded by that
  # transaction and not a lock this one holds across anything.
  #
  # NOTE FOR 03d: a **building** generation whose scan has not yet reached this
  # key has no row, so the zero row this creates is what the correction's
  # negative delta lands on, and the check would refuse it. No building
  # generation exists until replay ships, and reconciling the dual write with
  # the scan's absolute writes is replay's own design problem.
  defp apply_correction_totals(_state, []), do: :ok

  defp apply_correction_totals(state, events) do
    events
    |> Enum.group_by(&{&1.tenant_key, to_string(&1.feature), &1.period_start})
    |> Enum.flat_map(fn {key, group} ->
      quantity = Enum.reduce(group, 0, &(projection_delta(&1) + &2))
      Enum.map(state.generations, &{key, &1, quantity, length(group)})
    end)
    |> Enum.sort_by(fn {{tenant, feature, period}, generation, _q, _n} ->
      {tenant, feature, period, generation}
    end)
    |> Enum.each(&move_total(state, &1))

    :ok
  end

  defp move_total(state, {{tenant_key, feature, period_start}, generation, quantity, count}) do
    now = Clock.now()

    state.repo.insert_all(
      EventTotal,
      [
        %{
          tenant_key: tenant_key,
          feature: feature,
          period_start: period_start,
          generation: generation,
          quantity: 0,
          events: 0,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_key, :feature, :period_start, :generation],
      timeout: state.timeout
    )

    state.repo.update_all(
      from(t in EventTotal,
        where:
          t.tenant_key == ^tenant_key and t.feature == ^feature and
            t.period_start == ^period_start and t.generation == ^generation
      ),
      [inc: [quantity: quantity, events: count], set: [updated_at: now]],
      timeout: state.timeout
    )

    :ok
  end

  # The signed contribution one event makes to a total. The in-memory
  # projection applies the same rule in `AuroraMeter.Events`, and a replay
  # (03d) must apply it too.
  defp projection_delta(%AuroraMeter.Event{kind: :correction, quantity: quantity}), do: -quantity
  defp projection_delta(%AuroraMeter.Event{quantity: quantity}), do: quantity

  # Core computes what core knows and never drops a correction. I09's provider
  # half is "never treat a provider-ineligible correction as silently settled
  # externally": the item is always staged, always with a reason attached, and
  # Pro (04d) turns a reason into a quarantined item plus a reconciliation
  # item rather than into a success or a silence.
  defp enqueue_corrections(_state, []), do: :ok

  defp enqueue_corrections(state, events) do
    items = Enum.map(events, &%{event: &1, eligibility: correction_eligibility(&1)})

    result =
      try do
        state.outbox.enqueue(items, %{repo: state.repo, timeout: state.timeout})
      rescue
        error -> {:error, {:raised, error.__struct__, Exception.message(error)}}
      catch
        :throw, value -> {:error, {:threw, value}}
      end

    case result do
      :ok -> :ok
      {:error, reason} -> state.repo.rollback({:unavailable, {:outbox, reason}})
      other -> state.repo.rollback({:unavailable, {:outbox, {:unexpected_return, other}}})
    end
  end

  # A correction inherits the original's `attribution`, so `:unresolved` on a
  # correction row means the ORIGINAL could not be attributed. The correction of
  # an unattributed fact cannot be attributed either, and it is named
  # `:original_ineligible` so an operator reading the outbox is told which of
  # the two rows is the problem.
  #
  # `kind` is matched before `attribution` on purpose. `replace/4` stages a
  # replacement as well, and that one is a USAGE event whose attribution was
  # resolved from the caller's own new `occurred_at`; an unresolved attribution
  # there is its own problem and is named `:attribution_unresolved` like any
  # other recorded event's.
  defp correction_eligibility(%AuroraMeter.Event{kind: :correction, attribution: :unresolved}),
    do: {:ineligible, :original_ineligible}

  defp correction_eligibility(%AuroraMeter.Event{kind: :correction} = event) do
    if Config.feature_source(event.feature) == :buffered do
      {:ineligible, :feature_buffered}
    else
      :eligible
    end
  end

  defp correction_eligibility(event), do: eligibility(event)

  defp read_event(state, event_id) do
    state.repo.one(
      from(e in Event,
        where: e.tenant_key == ^state.request.tenant_key and e.event_id == ^event_id
      ),
      timeout: state.timeout
    )
  end

  # The duplicate and conflict decision, made with the ONE definition of "the
  # same payload" this package has. The expected hash needs the original,
  # because a correction's canonical tuple carries the original's feature,
  # occurrence instant and dimensions; without one there is nothing to compare
  # against and the honest answer is that the original is gone.
  #
  # `:remaining` takes the stored row's own quantity: `replace/4`'s caller never
  # stated a magnitude, so a magnitude is not something their retry can conflict
  # on. Their metadata still is.
  defp settle_duplicate(_state, _row, nil), do: {:refused, {:not_found, :original}}

  defp settle_duplicate(state, row, original) do
    quantity = stated_quantity(state.request, row)
    expected = Canonical.correction_hash(original, quantity, state.request.metadata)

    if row.payload_hash == expected do
      duplicate_outcomes(state, row)
    else
      state.repo.rollback({:conflict, 0, AuroraMeter.Event.from_row(row, state.durability)})
    end
  end

  defp stated_quantity(%{quantity: :remaining}, row), do: row.quantity
  defp stated_quantity(%{quantity: quantity}, _row), do: quantity

  # A duplicate contributes no totals delta and no outbox item: the ones it is a
  # duplicate of were staged when it first committed (I06).
  defp duplicate_outcomes(state, row) do
    correction = {AuroraMeter.Event.from_row(row, state.durability), :duplicate}

    case state.request.replacement do
      nil -> [correction]
      replacement -> [correction, duplicate_replacement(state, row, replacement)]
    end
  end

  # The correction identity is spent and the replacement it was spent on is not
  # the one this caller is now naming. That is a conflict on the CORRECTION,
  # which is the identity the caller can do something about, and not
  # `:conflict_unresolved`: nothing was inserted and nothing is uncertain.
  defp duplicate_replacement(state, correction, replacement) do
    case read_event(state, replacement.event_id) do
      %{payload_hash: hash} = row when hash == replacement.payload_hash ->
        {AuroraMeter.Event.from_row(row, state.durability), :duplicate}

      %{} = row ->
        state.repo.rollback({:conflict, 1, AuroraMeter.Event.from_row(row, state.durability)})

      nil ->
        state.repo.rollback(
          {:conflict, 0, AuroraMeter.Event.from_row(correction, state.durability)}
        )
    end
  end

  # A refusal RETURNS; only a conflict rolls back. `credits/ledger.ex`'s
  # `transact_outcome/1` records why at length: `repo.rollback/1` inside a
  # nested transaction marks the whole thing for rollback, savepoint or not, so
  # a host that wrapped `correct/4` beside its own writes loses them to an
  # answer that decided nothing. A bound that was exceeded wrote nothing; there
  # is nothing to undo.
  #
  # The totals check constraint is the backstop for the bound, and it is
  # translated rather than passed through: `quantity >= 0` firing on
  # `aurora_meter_event_totals` means this unit's arithmetic is wrong, and an
  # operator needs that sentence rather than an opaque storage error.
  defp unwrap_correction({:ok, {:refused, reason}}), do: {:error, reason}
  defp unwrap_correction({:ok, outcomes}) when is_list(outcomes), do: {:ok, outcomes}

  defp unwrap_correction({:error, {:unavailable, {:constraint, @totals_quantity_check = name}}}) do
    Logger.warning(
      "AuroraMeter: a correction violated #{name}. The cumulative bound in " <>
        "AuroraMeter.Storage.Ecto.record_correction/2 should have refused it first, so this is " <>
        "a bug in that bound and not a caller error. The transaction rolled back."
    )

    {:error, {:invalid, [quantity: :exceeds_original]}}
  end

  defp unwrap_correction({:error, reason}), do: {:error, reason}

  # -- helpers ---------------------------------------------------------------

  defp identity(entry), do: {entry.tenant_key, entry.event_id}

  defp row(entry) do
    now = Clock.now()

    %{
      tenant_key: entry.tenant_key,
      event_id: entry.event_id,
      feature: to_string(entry.feature),
      quantity: entry.quantity,
      kind: entry.kind,
      original_event_id: entry.original_event_id,
      occurred_at: entry.occurred_at,
      period_start: entry.period_start,
      period_source: entry.period_source,
      attribution: entry.attribution,
      dimensions: entry.dimensions,
      metadata: entry.metadata,
      plan_id: Map.get(entry, :plan_id),
      plan_version: Map.get(entry, :plan_version),
      payload_hash: entry.payload_hash,
      inserted_at: now
    }
  end

  defp active_generation(repo) do
    %{rows: [[cursor]]} =
      repo.query!("SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1", [
        @projection_checkpoint
      ])

    Map.get(cursor || %{}, "active_generation", 0)
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, :tenant_key, value), do: from(e in query, where: e.tenant_key == ^value)
  defp filter(query, :feature, value), do: from(e in query, where: e.feature == ^value)

  defp feature_filter(nil), do: nil
  defp feature_filter(feature), do: to_string(feature)

  defp occurred_from(query, nil), do: query
  defp occurred_from(query, from), do: from(e in query, where: e.occurred_at >= ^from)

  defp occurred_to(query, nil), do: query
  defp occurred_to(query, to), do: from(e in query, where: e.occurred_at < ^to)

  # Every way the database can refuse, turned into the one error shape the
  # facade contract names. A timeout is `{:unavailable, :timeout}` and not an
  # exit; a check constraint names itself, because a violated
  # `quantity >= 0` on the totals table is a correction bug (03e) and the
  # operator needs to know which constraint said so.
  defp guarded(fun) do
    fun.()
  rescue
    error in DBConnection.ConnectionError ->
      if error.reason == :queue_timeout,
        do: {:error, {:unavailable, :pool_timeout}},
        else: {:error, {:unavailable, :timeout}}

    error in Postgrex.Error ->
      {:error, {:unavailable, postgres_reason(error)}}
  catch
    :exit, {:timeout, _call} -> {:error, {:unavailable, :timeout}}
  end

  # `:query_canceled` is this timeout seen from the other end: when a statement
  # runs past `record_timeout`, DBConnection sends Postgres a cancel request,
  # and whether the client's own timer or the server's cancellation wins is a
  # race. Both are "the database did not answer in time", and the contract says
  # a caller gets one answer for that, retryable with the same id.
  defp postgres_reason(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: :timeout

  defp postgres_reason(%Postgrex.Error{postgres: %{constraint: name}}) when is_binary(name),
    do: {:constraint, name}

  defp postgres_reason(%Postgrex.Error{postgres: %{code: code}}), do: {:postgres, code}
  defp postgres_reason(_error), do: {:postgres, :unknown}

  @spec repo() :: module()
  defp repo, do: AuroraMeter.Config.repo()
end
