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
  # `period_start` is deliberately left null here rather than resolved a second
  # time: `AuroraMeter.track/4` already has the period in hand and passing it
  # down is a change to the `AuroraMeter.Storage.insert_events/1` row shape,
  # which build unit 03c owns along with the rest of the legacy track identity
  # rule. Nothing reads these rows for billing.
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

  @impl AuroraMeter.Storage
  def write_projection_totals(_generation, []), do: :ok

  def write_projection_totals(generation, rows) do
    now = Clock.now()

    entries =
      rows
      |> Enum.map(fn row ->
        %{
          tenant_key: row.tenant_key,
          feature: to_string(row.feature),
          period_start: row.period_start,
          generation: generation,
          quantity: row.quantity,
          events: row.events,
          inserted_at: now,
          updated_at: now
        }
      end)
      |> Enum.sort_by(&{&1.tenant_key, &1.feature, &1.period_start, &1.generation})

    guarded(fn ->
      repo().insert_all(EventTotal, entries,
        on_conflict: {:replace, [:quantity, :events, :updated_at]},
        conflict_target: [:tenant_key, :feature, :period_start, :generation]
      )

      :ok
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
        repo().query!(
          "SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1 FOR UPDATE",
          [@projection_checkpoint]
        )

        repo().query!(
          """
          UPDATE aurora_meter_checkpoints
             SET cursor = (cursor - 'building_generation') || jsonb_build_object(
                   'active_generation', $2::int
                 ),
                 state = 'active',
                 updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
           WHERE name = $1
          """,
          [@projection_checkpoint, generation]
        )

        :ok
      end)

      :ok
    end)
  end

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
