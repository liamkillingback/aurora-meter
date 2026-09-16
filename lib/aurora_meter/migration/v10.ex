defmodule AuroraMeter.Migration.V10 do
  @moduledoc false

  # Core schema version 10: plan version identity (`schema-migration-map.md`
  # step S6, `architecture-map.md` section 8), and one line of DDL that belongs
  # to `open-findings.md` X220.
  #
  # Additive and transactional. It creates two tables, adds ten columns to
  # `aurora_meter_subscriptions`, and **writes no data**: the legacy assignment
  # is `AuroraMeter.Plans.register!/0`'s, because `plan_fingerprint` is a
  # sha256 of the compiled definition and there is no compiled definition inside
  # a SQL statement. Until that runs, `plan_version` is NULL on every existing
  # row and every entitlement resolves exactly as it did on version 9, which is
  # what makes an application rollback supported here (`schema-migration-map.md`
  # section 7).
  #
  # ## The column this version exists for
  #
  # `aurora_meter_subscriptions.plan_version`. Before it, a plan was identified
  # by its id alone, so redeploying an edited `plan :pro` block repriced every
  # tenant on `:pro` at their next entitlement read, retroactively and with no
  # record that it had happened. With it, a tenant is pinned to the contract
  # they were sold and a changed definition is a refused boot rather than a
  # silent repricing (D05, I17).
  #
  # ## X220, and why it is last
  #
  # `ALTER TABLE aurora_meter_flush_receipts ALTER COLUMN inserted_at SET
  # DEFAULT (clock_timestamp() AT TIME ZONE 'UTC')`. The receipt's timestamp is
  # compared by `AuroraMeter.Retention` against a cutoff the **database**
  # computes, and it was stamped by the **node**: two clocks on one comparison,
  # which `architecture-map.md` section 3 forbids. `Storage.Ecto.flush_batch/3`
  # now omits the column from its `insert_all` and Postgres stamps it.
  #
  # It was proposed for version 9 and declined there: a wrong default on that
  # column reaches I01's idempotency check and therefore double counting, and
  # version 9 was already rewriting the ledger's ordering. It is one statement
  # and it is the last one this version runs, so nothing else in the version can
  # be confused with it when it is read back.
  #
  # **A database at version 9 running 1.0.0-rc.1 code cannot flush**, because
  # the insert omits a `NOT NULL` column that has no default until this version
  # lands. That is loud and immediate rather than silent, and it is the same
  # quiescence requirement `schema-migration-map.md` section 4 already records
  # for S6: the migration and the code ship together.
  #
  # ## Checks
  #
  # Every check on a table this version creates is added `valid: true`: the
  # table is empty in the same statement block and a permanently unproven
  # constraint the planner cannot use is worse than no constraint at all
  # (version 9's rule, followed here).
  #
  # The two checks on `aurora_meter_subscriptions` are the exception. That table
  # has customer rows in it, so they go on `NOT VALID` and are validated in a
  # separate statement whose scan takes SHARE UPDATE EXCLUSIVE rather than
  # blocking writes. They can only be violated by a row this version itself
  # created as NULL, so the scan is expected to be trivial; the escape hatch
  # `validate_checks: false` and the finder query exist anyway, because the one
  # thing a migration against a real customer database must never do is fail
  # without saying what to look at.

  import Ecto.Migration

  @subscriptions "aurora_meter_subscriptions"
  @plan_versions "aurora_meter_plan_versions"
  @plan_transitions "aurora_meter_plan_transitions"
  @receipts "aurora_meter_flush_receipts"

  @transition_states "('pending','applied','cancelled','failed')"
  @confirmations "('local','provider')"

  # Ten columns, one ALTER. Every one is nullable with no default, so PG 11 and
  # later record each as a catalogue entry and no row is rewritten.
  @subscription_columns [
    {:plan_version, :text, []},
    {:plan_fingerprint, :bytea, []},
    {:plan_effective_at, :utc_datetime, []},
    {:scheduled_plan_id, :text, []},
    {:scheduled_plan_version, :text, []},
    {:scheduled_effective_at, :utc_datetime, []},
    {:transition_ref, :text, []},
    {:transition_state, :text, []},
    {:transition_confirm, :text, []},
    {:transition_applied_at, :utc_datetime_usec, []}
  ]

  @subscription_checks [
    {"aurora_meter_subscriptions_transition_state_check",
     "transition_state IS NULL OR transition_state in #{@transition_states}"},
    {"aurora_meter_subscriptions_transition_confirm_check",
     "transition_confirm IS NULL OR transition_confirm in #{@confirmations}"}
  ]

  @violating_subscriptions """
  SELECT tenant_key, transition_state, transition_confirm
  FROM aurora_meter_subscriptions
  WHERE (transition_state IS NOT NULL
         AND transition_state NOT IN ('pending','applied','cancelled','failed'))
     OR (transition_confirm IS NOT NULL
         AND transition_confirm NOT IN ('local','provider'))
  """

  @doc false
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    create_plan_versions()
    create_plan_transitions()
    alter_subscriptions()
    validate_subscription_checks(Keyword.get(opts, :validate_checks, true))
    stamp_receipts_from_the_database()

    :ok
  end

  @doc false
  @spec down(keyword()) :: :ok
  def down(_opts \\ []) do
    execute("ALTER TABLE #{@receipts} ALTER COLUMN inserted_at DROP DEFAULT")
    flush()

    drop_if_exists table(:aurora_meter_plan_transitions)
    drop_if_exists table(:aurora_meter_plan_versions)
    flush()

    Enum.each(@subscription_checks, fn {name, _expression} ->
      execute("ALTER TABLE #{@subscriptions} DROP CONSTRAINT IF EXISTS #{name}")
    end)

    execute("DROP INDEX IF EXISTS aurora_meter_subscriptions_pending_transition_index")
    flush()

    alter table(:aurora_meter_subscriptions) do
      Enum.each(@subscription_columns, fn {name, type, _opts} -> remove_if_exists(name, type) end)
    end

    flush()
    :ok
  end

  @doc """
  The query an operator runs when this version's `VALIDATE CONSTRAINT` refuses
  their database. Quoted in the error so it does not have to be looked up.
  """
  @spec find_violating_subscriptions() :: String.t()
  def find_violating_subscriptions, do: @violating_subscriptions

  # -- the two new tables -----------------------------------------------------

  defp create_plan_versions do
    create_if_not_exists table(:aurora_meter_plan_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :plan_id, :text, null: false
      add :version, :text, null: false

      # 32 raw bytes rather than 64 hex characters: it is a digest, not a
      # string, and the check below says so in a way a hex column could not.
      add :fingerprint, :bytea, null: false
      add :definition, :map, null: false, default: fragment("'{}'::jsonb")

      # NULL means "from the beginning". A declared instant, never a stamp: it
      # is copied out of the compiled plan block and no clock produces it, which
      # is why comparing it against `AuroraMeter.Clock.now/0` puts one clock on
      # the comparison and not two.
      add :effective_at, :utc_datetime

      add :first_seen_at, :utc_datetime_usec,
        null: false,
        default: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")
    end

    flush()

    # The identity. Two nodes registering the same version at the same time both
    # insert; one wins and the other's `on_conflict: :nothing` is a no-op.
    create_if_not_exists(
      unique_index(:aurora_meter_plan_versions, [:plan_id, :version],
        name: :aurora_meter_plan_versions_plan_id_version_index
      )
    )

    # `AuroraMeter.Plans.versions/1` reads one plan's history in effective order.
    create_if_not_exists(
      index(:aurora_meter_plan_versions, [:plan_id, :effective_at],
        name: :aurora_meter_plan_versions_plan_effective_index
      )
    )

    add_check(
      @plan_versions,
      "aurora_meter_plan_versions_fingerprint_check",
      "octet_length(fingerprint) = 32",
      valid: true
    )

    add_check(
      @plan_versions,
      "aurora_meter_plan_versions_version_check",
      "octet_length(version) between 1 and 32",
      valid: true
    )

    add_check(
      @plan_versions,
      "aurora_meter_plan_versions_plan_id_check",
      "octet_length(plan_id) between 1 and 128",
      valid: true
    )

    # No `updated_at`: the row is immutable after insert. The precedent is
    # `aurora_meter_flush_receipts`, the other insert-only core table.
    flush()
  end

  defp create_plan_transitions do
    create_if_not_exists table(:aurora_meter_plan_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :text, null: false
      add :ref, :text, null: false
      add :from_plan_id, :text
      add :from_version, :text
      add :to_plan_id, :text, null: false
      add :to_version, :text, null: false
      add :effective_at, :utc_datetime, null: false
      add :state, :text, null: false, default: "pending"
      add :confirm, :text, null: false, default: "local"
      add :provider_ref, :text
      add :applied_at, :utc_datetime_usec
      add :detail, :map, null: false, default: fragment("'{}'::jsonb")
      timestamps(type: :utc_datetime_usec)
    end

    flush()

    create_if_not_exists(
      unique_index(:aurora_meter_plan_transitions, [:tenant_key, :ref],
        name: :aurora_meter_plan_transitions_tenant_ref_index
      )
    )

    create_if_not_exists(
      index(:aurora_meter_plan_transitions, [:state, :effective_at],
        name: :aurora_meter_plan_transitions_due_index
      )
    )

    add_check(
      @plan_transitions,
      "aurora_meter_plan_transitions_state_check",
      "state in #{@transition_states}",
      valid: true
    )

    add_check(
      @plan_transitions,
      "aurora_meter_plan_transitions_confirm_check",
      "confirm in #{@confirmations}",
      valid: true
    )

    add_check(
      @plan_transitions,
      "aurora_meter_plan_transitions_ref_check",
      "octet_length(ref) between 1 and 128",
      valid: true
    )

    flush()
  end

  # -- the subscription columns -----------------------------------------------

  defp alter_subscriptions do
    alter table(:aurora_meter_subscriptions) do
      Enum.each(@subscription_columns, fn {name, type, opts} ->
        add_if_not_exists(name, type, opts)
      end)
    end

    flush()

    # **Partial, as `schema-migration-map.md` S6 requires.** Only pending rows
    # are ever scanned (07b's due sweep), and on a table where almost every row
    # has a NULL `transition_state` a full two-column index would be almost
    # entirely dead weight. The build document quotes the earlier, unpredicated
    # form of this row; the map is binding and it was corrected after the
    # document was written (finding X285).
    create_if_not_exists(
      index(:aurora_meter_subscriptions, [:scheduled_effective_at, :tenant_key],
        where: "transition_state = 'pending'",
        name: :aurora_meter_subscriptions_pending_transition_index
      )
    )

    flush()

    Enum.each(@subscription_checks, fn {name, expression} ->
      add_check(@subscriptions, name, expression)
    end)
  end

  defp validate_subscription_checks(false) do
    flush()
    record_unvalidated(Enum.map(@subscription_checks, &elem(&1, 0)))
    :ok
  end

  defp validate_subscription_checks(true) do
    flush()

    Enum.each(@subscription_checks, fn {name, _expression} ->
      execute(fn -> validate_or_explain(repo(), name) end)
    end)

    flush()
    record_unvalidated([])
    :ok
  end

  defp validate_or_explain(repo, name) do
    repo.query!("ALTER TABLE #{@subscriptions} VALIDATE CONSTRAINT #{name}")
    :ok
  rescue
    error in Postgrex.Error ->
      reraise Ecto.MigrationError,
              [
                message:
                  "Aurora Meter schema version 10 could not prove #{name} against the " <>
                    "existing subscription rows: #{Exception.message(error)}\n\n" <>
                    "Version 10 adds `transition_state` and `transition_confirm` as NULL on " <>
                    "every existing row, so a violation means something other than Aurora " <>
                    "Meter has written to those columns. Find them with:\n\n" <>
                    "#{@violating_subscriptions}\n" <>
                    "Correct the rows and re-run, or pass `validate_checks: false` to apply " <>
                    "version 10 with the constraints enforced from now on and the history " <>
                    "left unproven (recorded in the aurora_meter_checkpoints schema marker)."
              ],
              __STACKTRACE__
  end

  # Version 9's shape, and the same key, so a database that took either escape
  # hatch carries one list rather than two that 11a would have to merge.
  defp record_unvalidated([]), do: :ok

  defp record_unvalidated(names) do
    execute(fn ->
      repo().query!(
        """
        UPDATE aurora_meter_checkpoints
        SET counts = jsonb_set(counts, '{unvalidated_subscription_constraints}', $1::jsonb),
            updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
        WHERE name = 'schema:core'
        """,
        [names]
      )

      :ok
    end)

    :ok
  end

  # -- X220 -------------------------------------------------------------------

  # Last, and on its own, because it belongs to a different finding from
  # everything above it. `SET DEFAULT` touches the catalogue only: no row is
  # read and no row is rewritten, so it holds ACCESS EXCLUSIVE for the time it
  # takes to update one pg_attrdef entry.
  defp stamp_receipts_from_the_database do
    flush()

    execute(
      "ALTER TABLE #{@receipts} " <>
        "ALTER COLUMN inserted_at SET DEFAULT (clock_timestamp() AT TIME ZONE 'UTC')"
    )

    flush()
    :ok
  end

  # -- helpers (version 9's, unchanged) ---------------------------------------

  defp add_check(table, name, expression, opts \\ []) do
    flush()

    if not constraint?(table, name) do
      suffix = if opts[:valid], do: "", else: " NOT VALID"
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{expression})#{suffix}")
      flush()
    end

    :ok
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
end
