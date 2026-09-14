defmodule AuroraMeter.Migration.V7 do
  @moduledoc false

  # Core schema version 7: durable event identity, the projection totals table
  # and the checkpoints table. Additive and transactional. `AuroraMeter.Migration`
  # carries the documentation; this module carries the statements.
  #
  # Two properties the rest of the programme rests on:
  #
  #   * every statement is guarded by a catalogue check, `create_if_not_exists`
  #     or `add_if_not_exists`, so re-running the version after a partial
  #     failure is safe (L-03a-4);
  #   * the `quantity` widening and the `seq` identity column go in ONE
  #     `ALTER TABLE`, because each of them rewrites the table and two
  #     statements would rewrite it twice under `ACCESS EXCLUSIVE`.

  import Ecto.Migration

  @events "aurora_meter_events"

  @columns [
    {:event_id, :text, []},
    {:payload_hash, :binary, []},
    {:occurred_at, :utc_datetime_usec, []},
    {:period_start, :utc_datetime, []},
    {:period_source, :text, []},
    {:kind, :text, [null: false, default: "usage"]},
    {:original_event_id, :text, []},
    {:dimensions, :map, [null: false, default: {:fragment, "'{}'::jsonb"}]},
    {:plan_id, :text, []},
    {:plan_version, :text, []},
    {:attribution, :text, []}
  ]

  # The four constraints no row written by 0.4.x can violate. `kind` and
  # `dimensions` arrive with a default on every existing row, `event_id` is
  # null until the backfill derives a 43 byte value, and the correction pairing
  # holds for every `kind = 'usage'` row with a null original.
  #
  # They are still added NOT VALID, so no existing row is scanned and no long
  # ACCESS EXCLUSIVE lock is taken. NOT VALID enforces the constraint on every
  # insert and update from the moment it exists; it only leaves historical rows
  # unproven. Version 8 proves them.
  #
  # The two constraints history CAN violate, `quantity > 0` and the metadata
  # size, are deliberately NOT here. They are added by version 8, after the
  # backfill. Adding them in version 7 would make the backfill impossible on
  # exactly the databases it exists for: NOT VALID is enforced on UPDATE as
  # well as on INSERT, and the backfill's whole job is to UPDATE those rows.
  # See `AuroraMeter.Migration.V8`.
  @checks [
    {"aurora_meter_events_kind_check", "kind in ('usage','correction')"},
    {"aurora_meter_events_correction_pairing_check",
     "(kind = 'correction') = (original_event_id is not null)"},
    {"aurora_meter_events_event_id_length_check", "octet_length(event_id) <= 128"},
    {"aurora_meter_events_dimensions_object_check", "jsonb_typeof(dimensions) = 'object'"}
  ]

  # Every check constraint this version and version 8 put on the table. `down`
  # of version 7 removes the columns they are written against, so it has to
  # take all of them, not only the ones version 7 added.
  @all_checks [
    "aurora_meter_events_kind_check",
    "aurora_meter_events_correction_pairing_check",
    "aurora_meter_events_event_id_length_check",
    "aurora_meter_events_dimensions_object_check",
    "aurora_meter_events_quantity_check",
    "aurora_meter_events_metadata_size_check"
  ]

  @totals_checks [
    {"aurora_meter_event_totals_quantity_check", "quantity >= 0"},
    {"aurora_meter_event_totals_events_check", "events >= 0"}
  ]

  @indexes [
    :aurora_meter_events_tenant_key_event_id_index,
    :aurora_meter_events_seq_index,
    :aurora_meter_events_corrections_index
  ]

  @lock_timeout ~r/^\d+(us|ms|s|min|h|d)?$/

  @doc false
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    previous = set_lock_timeout(Keyword.get(opts, :lock_timeout, "5s"))

    rewrite_events()
    add_columns()
    add_indexes()
    Enum.each(@checks, fn {name, expression} -> add_check(@events, name, expression) end)
    create_event_totals()
    create_checkpoints()
    seed_projection_checkpoint()

    restore_lock_timeout(previous)
    :ok
  end

  @doc false
  @spec down(keyword()) :: :ok
  def down(_opts \\ []) do
    drop_if_exists table(:aurora_meter_checkpoints)
    drop_if_exists table(:aurora_meter_event_totals)

    Enum.each(@indexes, fn name ->
      execute("DROP INDEX IF EXISTS #{name}")
    end)

    Enum.each(@all_checks, fn name ->
      execute("ALTER TABLE #{@events} DROP CONSTRAINT IF EXISTS #{name}")
    end)

    alter table(:aurora_meter_events) do
      Enum.each(@columns, fn {name, type, _opts} -> remove_if_exists(name, type) end)
      remove_if_exists(:seq, :bigint)
    end

    flush()

    # Back to int4. This fails, correctly, when a row now holds a quantity that
    # does not fit: version 7 is on the data-loss list precisely because going
    # back down it is destructive.
    execute("ALTER TABLE #{@events} ALTER COLUMN quantity TYPE integer")
    flush()

    :ok
  end

  # One statement, so Postgres performs one rewrite rather than two. Each
  # subcommand is included only when the catalogue says it is still needed, so
  # a re-run after a partial failure neither fails nor rewrites the table again.
  defp rewrite_events do
    flush()
    columns = columns(@events)

    subcommands =
      []
      |> widen_quantity(columns)
      |> add_seq(columns)

    if subcommands != [] do
      execute("ALTER TABLE #{@events}\n  " <> Enum.join(subcommands, ",\n  "))
      flush()
    end
  end

  defp widen_quantity(subcommands, columns) do
    case Map.get(columns, "quantity") do
      "bigint" -> subcommands
      _other -> subcommands ++ ["ALTER COLUMN quantity TYPE bigint"]
    end
  end

  # `GENERATED ALWAYS AS IDENTITY`, not `bigserial`: the point of the column is
  # that the sequence assigns it, so that for any two committed rows A and B, if
  # A committed before B started then `A.seq < B.seq` (L-03a-2). `ALWAYS` is how
  # that is enforced by the database rather than by every future caller
  # remembering. `AuroraMeter.Schema.Event` marks the field `read_after_writes`
  # so Ecto never sends a value for it.
  defp add_seq(subcommands, columns) do
    if Map.has_key?(columns, "seq") do
      subcommands
    else
      subcommands ++ ["ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY"]
    end
  end

  # Constant or null defaults only, so PG 11 and later add each one as a
  # catalogue entry and no row is touched.
  defp add_columns do
    alter table(:aurora_meter_events) do
      Enum.each(@columns, fn {name, type, opts} -> add_if_not_exists(name, type, expand(opts)) end)
    end

    flush()
  end

  defp expand(opts) do
    Enum.map(opts, fn
      {:default, {:fragment, sql}} -> {:default, fragment(sql)}
      other -> other
    end)
  end

  defp add_indexes do
    # Serves the backfill's lookups and the facade's conflict resolution until
    # version 8's unique index supersedes it, at which point version 8 drops it.
    create_if_not_exists index(:aurora_meter_events, [:tenant_key, :event_id])

    # The keyset cursor for the backfill, for 03d's replay scan and for the
    # `max(seq)` watermark. Unique because the identity column is.
    create_if_not_exists unique_index(:aurora_meter_events, [:seq],
                           name: :aurora_meter_events_seq_index
                         )

    # 03e sums the corrections of one original under the original's row lock.
    # Partial, because corrections are a vanishing fraction of the table.
    create_if_not_exists index(:aurora_meter_events, [:tenant_key, :original_event_id],
                           where: "kind = 'correction'",
                           name: :aurora_meter_events_corrections_index
                         )

    flush()
  end

  defp create_event_totals do
    create_if_not_exists table(:aurora_meter_event_totals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false
      add :feature, :string, null: false
      add :period_start, :utc_datetime, null: false
      add :generation, :integer, null: false, default: 0
      add :quantity, :bigint, null: false, default: 0
      add :events, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    # Generation last, so the three-column prefix serves `load_event_total/3`.
    create_if_not_exists unique_index(
                           :aurora_meter_event_totals,
                           [:tenant_key, :feature, :period_start, :generation],
                           name: :aurora_meter_event_totals_key_index
                         )

    create_if_not_exists index(:aurora_meter_event_totals, [:generation])

    flush()

    Enum.each(@totals_checks, fn {name, expression} ->
      add_check("aurora_meter_event_totals", name, expression, valid: true)
    end)
  end

  defp create_checkpoints do
    create_if_not_exists table(:aurora_meter_checkpoints, primary_key: false) do
      add :name, :text, primary_key: true
      add :cursor, :map, null: false, default: fragment("'{}'::jsonb")
      add :counts, :map, null: false, default: fragment("'{}'::jsonb")
      add :state, :text, null: false, default: "idle"

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")
    end

    flush()
  end

  # The one row every later unit assumes exists. 03b reads the active
  # generation from it on every record; 03d takes `FOR UPDATE` on it to fix a
  # replay watermark.
  defp seed_projection_checkpoint do
    execute("""
    INSERT INTO aurora_meter_checkpoints (name, cursor, counts, state, updated_at)
    VALUES ('events_projection', '{"active_generation": 0}'::jsonb, '{}'::jsonb, 'active',
            (clock_timestamp() AT TIME ZONE 'UTC'))
    ON CONFLICT (name) DO NOTHING
    """)

    flush()
  end

  defp add_check(table, name, expression, opts \\ []) do
    flush()

    if not constraint?(table, name) do
      suffix = if opts[:valid], do: "", else: " NOT VALID"
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{expression})#{suffix}")
      flush()
    end
  end

  defp constraint?(table, name) do
    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT count(*) FROM pg_constraint
        WHERE conrelid = to_regclass($1)::oid AND conname = $2
        """,
        [table, name]
      )

    count > 0
  end

  defp columns(table) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT column_name, data_type FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = $1
        """,
        [table]
      )

    Map.new(rows, fn [name, type] -> {name, type} end)
  end

  # A stuck ALTER on this table queues every subsequent query behind it, so the
  # version fails fast instead. `SET` is transactional in Postgres, so on a
  # failure inside the DDL transaction the previous value comes back with the
  # rollback; the explicit restore covers the success path and the case of a
  # host that runs the version outside one.
  defp set_lock_timeout(value) when is_binary(value) do
    if not Regex.match?(@lock_timeout, value) do
      raise ArgumentError,
            "AuroraMeter.Migration.up/1 :lock_timeout must be a Postgres interval such as " <>
              "\"5s\" or \"0\", got: #{inspect(value)}"
    end

    flush()
    %{rows: [[previous]]} = repo().query!("SHOW lock_timeout", [])
    execute("SET lock_timeout = '#{value}'")
    flush()
    previous
  end

  defp restore_lock_timeout(previous) do
    execute("SET lock_timeout = '#{previous}'")
    flush()
    :ok
  end
end
