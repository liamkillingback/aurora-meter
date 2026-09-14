defmodule AuroraMeter.Migration.V8 do
  @moduledoc false

  # Core schema version 8: the unique index that makes event identity a
  # database guarantee rather than an application convention, the three
  # `NOT NULL` promotions behind it, and the validation of the constraints
  # version 7 added `NOT VALID`.
  #
  # It creates the index CONCURRENTLY, which Postgres refuses inside a
  # transaction block, so its host migration carries `@disable_ddl_transaction
  # true` and `@disable_migration_lock true`. `concurrently: false` is the
  # escape for a fresh install and for a small table.
  #
  # Every step is idempotent, because with the migration lock disabled two
  # runners really can overlap: a leftover INVALID index from a killed run is
  # dropped before the retry, the index is created IF NOT EXISTS, and SET NOT
  # NULL on a column that is already NOT NULL is a no-op.

  import Ecto.Migration

  alias AuroraMeter.Migration.BackfillIncompleteError
  alias AuroraMeter.Migration.ConcurrentVersionError

  @events "aurora_meter_events"

  @unique_index "aurora_meter_events_tenant_event_id_index"

  @plain_index "aurora_meter_events_tenant_key_event_id_index"

  @not_null [:event_id, :payload_hash, :occurred_at]

  # The two constraints a database written by 0.4.x can actually violate.
  # `AuroraMeter.track/4` never validated quantity and never bounded metadata,
  # so real rows can break both.
  #
  # They belong here rather than in version 7 for a reason that is easy to get
  # wrong: a NOT VALID constraint is enforced on UPDATE as well as on INSERT.
  # Added in version 7 they would have left the backfill unable to touch
  # precisely the rows it exists to give an identity to, and the upgrade would
  # have been impossible on any database holding one. Added here, after the
  # backfill has run and counted them, the history is intact and every row
  # written from this point on is constrained.
  #
  # The metadata bound is `octet_length(metadata::text)` and not
  # `pg_column_size(metadata)`, which is what `architecture-map.md` 4.1 named.
  # `pg_column_size` reports the size of the value **as stored**, so it is not a
  # property of the value at all: measured on this host, one 20,012 byte
  # metadata map is 20,012 bytes to an INSERT and 259 bytes once TOAST has
  # compressed it, so the same value is refused on the way in and passes
  # `VALIDATE CONSTRAINT` on the way out. A constraint whose truth changes with
  # how a row happens to be stored is not a constraint. `octet_length` of the
  # canonical jsonb text is deterministic and is exactly the contract
  # `AuroraMeter.record/4` documents: metadata at most 16 KiB encoded.
  @late_checks [
    {"aurora_meter_events_quantity_check", "quantity > 0"},
    {"aurora_meter_events_metadata_size_check", "octet_length(metadata::text) <= 16384"}
  ]

  # Validated in this order, cheapest first.
  @checks [
    "aurora_meter_events_kind_check",
    "aurora_meter_events_correction_pairing_check",
    "aurora_meter_events_event_id_length_check",
    "aurora_meter_events_dimensions_object_check",
    "aurora_meter_events_quantity_check",
    "aurora_meter_events_metadata_size_check"
  ]

  @duplicates """
  SELECT tenant_key, event_id, count(*)
  FROM aurora_meter_events
  GROUP BY tenant_key, event_id
  HAVING count(*) > 1
  """

  @doc false
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    concurrently? = Keyword.get(opts, :concurrently, true)

    guard_transaction!(concurrently?)
    drop_invalid_index(concurrently?)
    refuse_while_incomplete()
    create_unique_index(concurrently?)
    verify_index(concurrently?)
    promote_not_null()
    drop_plain_index(concurrently?)
    add_late_checks()
    validate_checks(Keyword.get(opts, :validate_checks, true))

    :ok
  end

  @doc false
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    concurrently? = Keyword.get(opts, :concurrently, true)

    guard_transaction!(concurrently?)
    flush()

    Enum.each(@late_checks, fn {name, _expression} ->
      execute("ALTER TABLE #{@events} DROP CONSTRAINT IF EXISTS #{name}")
    end)

    Enum.each(@not_null, fn column ->
      execute("ALTER TABLE #{@events} ALTER COLUMN #{column} DROP NOT NULL")
    end)

    flush()
    create_if_not_exists index(:aurora_meter_events, [:tenant_key, :event_id])
    flush()
    execute("DROP INDEX #{concurrent(concurrently?)}IF EXISTS #{@unique_index}")
    flush()

    :ok
  end

  # `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block, and the
  # failure Postgres gives for it does not say what to do about it.
  defp guard_transaction!(false), do: :ok

  defp guard_transaction!(true) do
    flush()

    if repo().in_transaction?() do
      raise ConcurrentVersionError, versions: [8], concurrent: [8]
    end

    :ok
  end

  # A killed `CREATE INDEX CONCURRENTLY` leaves an INVALID index behind that
  # nothing uses and that blocks the name. Postgres does not clean it up.
  defp drop_invalid_index(concurrently?) do
    flush()

    if index_state() == :invalid do
      execute("DROP INDEX #{concurrent(concurrently?)}IF EXISTS #{@unique_index}")
      flush()
    end

    :ok
  end

  defp refuse_while_incomplete do
    flush()

    %{rows: [[remaining]]} =
      repo().query!("SELECT count(*) FROM #{@events} WHERE event_id IS NULL", [])

    if remaining > 0 do
      raise BackfillIncompleteError, remaining: remaining
    end

    :ok
  end

  defp create_unique_index(concurrently?) do
    flush()

    execute(
      "CREATE UNIQUE INDEX #{concurrent(concurrently?)}IF NOT EXISTS #{@unique_index} " <>
        "ON #{@events} (tenant_key, event_id)"
    )

    flush()
  end

  # `CREATE INDEX CONCURRENTLY` reports success and leaves an INVALID index
  # when it loses a race or hits a duplicate, so the catalogue is the only
  # honest answer to "did that work".
  defp verify_index(concurrently?) do
    case index_state() do
      :valid ->
        :ok

      other ->
        execute("DROP INDEX #{concurrent(concurrently?)}IF EXISTS #{@unique_index}")
        flush()

        raise Ecto.MigrationError,
          message:
            "Aurora Meter schema version 8 could not build a unique index on " <>
              "(tenant_key, event_id): the index came back #{other}. The usual cause is a " <>
              "duplicate identity. Find them with:\n\n#{@duplicates}\n" <>
              "and resolve them before re-running. The index has been dropped, so the " <>
              "re-run starts clean."
    end
  end

  # PG 12 and later prove this from an existing constraint rather than scanning
  # the table, so the ACCESS EXCLUSIVE lock is brief. It is not free; it is
  # measured rather than assumed.
  defp promote_not_null do
    flush()

    Enum.each(@not_null, fn column ->
      execute("ALTER TABLE #{@events} ALTER COLUMN #{column} SET NOT NULL")
    end)

    flush()
  end

  defp drop_plain_index(concurrently?) do
    execute("DROP INDEX #{concurrent(concurrently?)}IF EXISTS #{@plain_index}")
    flush()
  end

  defp add_late_checks do
    Enum.each(@late_checks, fn {name, expression} ->
      flush()

      if not constraint?(name) do
        execute("ALTER TABLE #{@events} ADD CONSTRAINT #{name} CHECK (#{expression}) NOT VALID")
        flush()
      end
    end)
  end

  defp constraint?(name) do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT count(*) FROM pg_constraint " <>
          "WHERE conrelid = to_regclass($1)::oid AND conname = $2",
        [@events, name]
      )

    count > 0
  end

  # `VALIDATE CONSTRAINT` takes SHARE UPDATE EXCLUSIVE, so reads and writes
  # continue while it scans. A violation is a real fact about the customer's
  # history, not a bug in this migration, so the error says what to do with it.
  defp validate_checks(false) do
    flush()
    record_unvalidated(@checks)
    :ok
  end

  defp validate_checks(true) do
    Enum.each(@checks, fn name ->
      flush()
      execute("ALTER TABLE #{@events} VALIDATE CONSTRAINT #{name}")
    end)

    flush()
    record_unvalidated([])
    :ok
  end

  # The marker carries which constraints are still unproven, so 11a's
  # reconciliation can see a database that took the escape hatch without
  # having to re-derive it from pg_constraint.
  defp record_unvalidated(names) do
    repo().query!(
      """
      UPDATE aurora_meter_checkpoints
      SET counts = jsonb_set(counts, '{unvalidated_constraints}', $1::jsonb),
          updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
      WHERE name = 'schema:core'
      """,
      # The list itself, not `Jason.encode!/1` of it: `$1::jsonb` makes Postgrex
      # encode the parameter as jsonb, so an already-encoded string would land
      # as the jsonb *string* "[]" rather than the empty array.
      [names]
    )

    :ok
  end

  defp index_state do
    %{rows: rows} =
      repo().query!(
        """
        SELECT i.indisvalid, i.indisready
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = $1
        """,
        [@unique_index]
      )

    case rows do
      [] -> :absent
      [[true, true]] -> :valid
      [[_valid, _ready]] -> :invalid
    end
  end

  defp concurrent(true), do: "CONCURRENTLY "
  defp concurrent(false), do: ""
end
