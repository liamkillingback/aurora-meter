defmodule AuroraMeter.Migration.V9 do
  @moduledoc false

  # Core schema version 9: the credit lot engine's tables and columns
  # (`schema-migration-map.md` step S4, `architecture-map.md` 7.1).
  #
  # Additive and transactional. It creates three tables, adds five columns to
  # `aurora_meter_credit_balances` and three to
  # `aurora_meter_credit_transactions`, and writes **no data**. Wallets stay on
  # the legacy writer until `mix aurora_meter.credits.migrate_lots` (S5, build
  # unit 06b) sets `lots_enabled_at`, so a mixed fleet across this version is
  # safe and an application rollback to the previous image is supported.
  #
  # ## The column this version exists for
  #
  # `aurora_meter_credit_transactions.seq bigint GENERATED ALWAYS AS IDENTITY`.
  # The ledger used to order its own account of the past by `inserted_at`, which
  # is stamped from a wall clock; that clock steps backwards (findings X59, X100,
  # L20) and an `:expire` row written after its grant could carry an earlier
  # timestamp and sort before it. The financial consequences were measured:
  # a fully spent promotional grant reported as unspent, a grant `expire_due/2`
  # could never expire, and a `KeyError` that cost 7 of 50 expiries in one run
  # (X213). A monotonic identity cannot go backwards.
  #
  # **The seq of a row written before this version comes from the table rewrite,
  # not from insertion order.** `ADD COLUMN ... GENERATED ALWAYS AS IDENTITY`
  # rewrites the heap and numbers the rows in the physical order it reads them.
  # For a row that has never been updated that is insertion order; for one that
  # has (a closed hold, a stamped grant) it is wherever the update put the new
  # tuple. Nothing here can fix that, and it is why
  # `AuroraMeter.Credits.Promotions` no longer raises when it meets an expire
  # entry whose grant it has not folded yet (finding X244). Rows written from
  # this version on are numbered by the sequence, in commit order.
  #
  # ## The two balance checks
  #
  # `held >= 0` and `promotional >= 0` were validated by the changeset and by
  # nothing else (finding X183): the only thing standing between a lost row lock
  # and silent corruption was the lock itself. They are added `NOT VALID` and
  # then validated in a separate statement, so the fast `ALTER` does not scan and
  # the scan takes `SHARE UPDATE EXCLUSIVE` rather than blocking writes.
  #
  # A database holding a violating row fails `VALIDATE CONSTRAINT`, which fails
  # this version inside its DDL transaction and applies nothing. That is the
  # right failure, and `validate_checks: false` is the same escape hatch version
  # 8 offers: the constraints are then enforced on every insert and update from
  # now on and the history stays unproven, recorded in the schema marker so 11a
  # can see it. `find_violating_balances/0` is quoted in the error.
  #
  # `NOT VALID` is not a grace period: it is enforced on UPDATE as well as on
  # INSERT (`schema-migration-map.md`, "Two Postgres facts"). A wallet whose
  # `held` is already negative therefore stops accepting ledger writes the
  # moment this version lands, which is deliberate. A refused write is
  # recoverable; a wrong balance is not.

  import Ecto.Migration

  @balances "aurora_meter_credit_balances"
  @transactions "aurora_meter_credit_transactions"
  @lots "aurora_meter_credit_lots"
  @allocations "aurora_meter_credit_allocations"
  @recurrences "aurora_meter_credit_recurrences"

  # Added to the balance row in one ALTER, all with constant or null defaults,
  # so PG 11 and later record each as a catalogue entry and no row is touched.
  @balance_columns [
    {:debt, :bigint, [null: false, default: 0]},
    {:expired, :bigint, [null: false, default: 0]},
    {:lots_enabled_at, :utc_datetime, []},
    {:projection_checked_at, :utc_datetime_usec, []},
    {:low_balance_crossing_id, :uuid, []}
  ]

  @balance_checks [
    {"aurora_meter_credit_balances_held_check", "held >= 0"},
    {"aurora_meter_credit_balances_promotional_check", "promotional >= 0"},
    {"aurora_meter_credit_balances_debt_check", "debt >= 0"},
    {"aurora_meter_credit_balances_expired_check", "expired >= 0"}
  ]

  # `debt` and `expired` arrive with a default of 0 on every row, so they cannot
  # be violated by history; they are validated in the same pass because the scan
  # is shared.
  @validated_checks [
    "aurora_meter_credit_balances_held_check",
    "aurora_meter_credit_balances_promotional_check",
    "aurora_meter_credit_balances_debt_check",
    "aurora_meter_credit_balances_expired_check"
  ]

  @violating_balances """
  SELECT tenant_key, balance, held, promotional
  FROM aurora_meter_credit_balances
  WHERE held < 0 OR promotional < 0
  """

  @lot_quantities [:available, :reserved, :consumed, :reversed, :expired]

  # `state` is a total function of the quantities, so no writer can disagree
  # with it and no writer has to remember to keep it current.
  @lot_state_expression """
  state = CASE
    WHEN reversed = amount THEN 'reversed'
    WHEN available = 0 AND reserved = 0 AND expired > 0 THEN 'expired'
    WHEN available = 0 AND reserved = 0 THEN 'exhausted'
    ELSE 'open'
  END\
  """

  @lot_checks [
    {"aurora_meter_credit_lots_amount_check", "amount > 0"},
    {"aurora_meter_credit_lots_category_check",
     "category in ('paid','promotional','adjustment')"},
    {"aurora_meter_credit_lots_conservation_check",
     "available + reserved + consumed + reversed + expired = amount"},
    {"aurora_meter_credit_lots_state_check", @lot_state_expression}
  ]

  @buckets "('available','reserved','consumed','reversed','expired')"

  @allocation_checks [
    {"aurora_meter_credit_allocations_amount_check", "amount > 0"},
    {"aurora_meter_credit_allocations_kind_check",
     "kind in ('reserve','unreserve','consume','expire','reverse','restore')"},
    {"aurora_meter_credit_allocations_from_bucket_check", "from_bucket in #{@buckets}"},
    {"aurora_meter_credit_allocations_to_bucket_check", "to_bucket in #{@buckets}"},
    {"aurora_meter_credit_allocations_movement_check", "from_bucket <> to_bucket"}
  ]

  @recurrence_checks [
    {"aurora_meter_credit_recurrences_state_check", "state in ('granted','issued_and_expired')"}
  ]

  @doc false
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    alter_transactions()
    alter_balances()
    create_lots()
    create_allocations()
    create_recurrences()
    validate_balance_checks(Keyword.get(opts, :validate_checks, true))

    :ok
  end

  @doc false
  @spec down(keyword()) :: :ok
  def down(_opts \\ []) do
    drop_if_exists table(:aurora_meter_credit_recurrences)
    drop_if_exists table(:aurora_meter_credit_allocations)
    drop_if_exists table(:aurora_meter_credit_lots)
    flush()

    Enum.each(@balance_checks, fn {name, _expression} ->
      execute("ALTER TABLE #{@balances} DROP CONSTRAINT IF EXISTS #{name}")
    end)

    flush()

    alter table(:aurora_meter_credit_balances) do
      Enum.each(@balance_columns, fn {name, type, _opts} -> remove_if_exists(name, type) end)
    end

    execute("DROP INDEX IF EXISTS aurora_meter_credit_transactions_hold_index")
    execute("DROP INDEX IF EXISTS aurora_meter_credit_transactions_seq_index")
    execute("DROP INDEX IF EXISTS aurora_meter_credit_transactions_tenant_seq_index")
    flush()

    alter table(:aurora_meter_credit_transactions) do
      remove_if_exists(:seq, :bigint)
      remove_if_exists(:updated_at, :utc_datetime_usec)
      remove_if_exists(:hold_transaction_id, :uuid)
    end

    flush()
    :ok
  end

  @doc """
  The query an operator runs when this version's `VALIDATE CONSTRAINT` refuses
  their database. Quoted in the error so it does not have to be looked up.
  """
  @spec find_violating_balances() :: String.t()
  def find_violating_balances, do: @violating_balances

  # One ALTER, because adding an identity column rewrites the table and three
  # statements would rewrite it three times under ACCESS EXCLUSIVE. Each
  # subcommand is included only when the catalogue says it is still missing, so
  # re-running after a partial failure neither fails nor rewrites again.
  defp alter_transactions do
    flush()
    columns = columns(@transactions)

    subcommands =
      []
      |> add_column(columns, "seq", "ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY")
      |> add_column(columns, "updated_at", "ADD COLUMN updated_at timestamp(6) without time zone")
      |> add_column(columns, "hold_transaction_id", "ADD COLUMN hold_transaction_id uuid")

    if subcommands != [] do
      execute("ALTER TABLE #{@transactions}\n  " <> Enum.join(subcommands, ",\n  "))
      flush()
    end

    # The ordering key, per tenant: every scan that reconstructs what happened
    # in what order is `WHERE tenant_key = $1 ORDER BY seq`.
    create_if_not_exists(
      index(:aurora_meter_credit_transactions, [:tenant_key, :seq],
        name: :aurora_meter_credit_transactions_tenant_seq_index
      )
    )

    # Unique because the identity column is; it is what a whole-installation
    # keyset scan pages on.
    create_if_not_exists(
      unique_index(:aurora_meter_credit_transactions, [:seq],
        name: :aurora_meter_credit_transactions_seq_index
      )
    )

    create_if_not_exists(
      index(:aurora_meter_credit_transactions, [:hold_transaction_id],
        where: "hold_transaction_id IS NOT NULL",
        name: :aurora_meter_credit_transactions_hold_index
      )
    )

    flush()
  end

  defp alter_balances do
    alter table(:aurora_meter_credit_balances) do
      Enum.each(@balance_columns, fn {name, type, opts} -> add_if_not_exists(name, type, opts) end)
    end

    flush()

    Enum.each(@balance_checks, fn {name, expression} ->
      add_check(@balances, name, expression)
    end)
  end

  defp create_lots do
    create_if_not_exists table(:aurora_meter_credit_lots, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false

      # The first foreign key in the ledger, and it is deliberate: a lot
      # without its grant row cannot be explained to anybody. RESTRICT so
      # `AuroraMeter.Retention.prune/1` cannot orphan one (it already excludes
      # credit rows; this makes it structural).
      add :grant_transaction_id,
          references(:aurora_meter_credit_transactions,
            type: :binary_id,
            on_delete: :restrict,
            name: :aurora_meter_credit_lots_grant_fkey
          ),
          null: false

      add :reference, :string, null: false
      add :category, :string, null: false
      add :amount, :bigint, null: false
      Enum.each(@lot_quantities, &add(&1, :bigint, null: false, default: 0))

      # A display and reporting value only. It is never an ordering key: the
      # clock that produces it is not monotonic. `seq` is the order.
      add :granted_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime
      add :source, :map, null: false, default: fragment("'{}'::jsonb")
      add :state, :string, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    flush()
    add_seq(@lots)

    Enum.each(@lot_quantities, fn quantity ->
      add_check(@lots, "aurora_meter_credit_lots_#{quantity}_check", "#{quantity} >= 0",
        valid: true
      )
    end)

    Enum.each(@lot_checks, fn {name, expression} ->
      add_check(@lots, name, expression, valid: true)
    end)

    # One lot per grant row: a replayed migration or a retried grant cannot
    # create a second one.
    create_if_not_exists(
      unique_index(:aurora_meter_credit_lots, [:tenant_key, :grant_transaction_id],
        name: :aurora_meter_credit_lots_grant_index
      )
    )

    # The spend-order scan. `granted_at` is in the key for the human-meaningful
    # sort and `seq` is the tiebreak that makes it total.
    create_if_not_exists(
      index(
        :aurora_meter_credit_lots,
        [:tenant_key, :state, :category, :expires_at, :granted_at, :seq],
        name: :aurora_meter_credit_lots_spend_index
      )
    )

    create_if_not_exists(
      index(:aurora_meter_credit_lots, [:tenant_key, :expires_at],
        where: "state = 'open' AND expires_at IS NOT NULL",
        name: :aurora_meter_credit_lots_expiry_index
      )
    )

    # 06e's refund lookup. `jsonb_exists(source, 'payment_intent_id')` rather
    # than `source ? 'payment_intent_id'`: the `?` operator collides with the
    # placeholder syntax of every tool that will ever have to read this
    # statement back, and the function is the same predicate.
    execute("""
    CREATE INDEX IF NOT EXISTS aurora_meter_credit_lots_source_intent_index
    ON #{@lots} ((source ->> 'payment_intent_id'))
    WHERE jsonb_exists(source, 'payment_intent_id')
    """)

    flush()
  end

  defp create_allocations do
    create_if_not_exists table(:aurora_meter_credit_allocations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false

      add :lot_id,
          references(:aurora_meter_credit_lots,
            type: :binary_id,
            on_delete: :restrict,
            name: :aurora_meter_credit_allocations_lot_fkey
          ),
          null: false

      add :transaction_id,
          references(:aurora_meter_credit_transactions,
            type: :binary_id,
            on_delete: :restrict,
            name: :aurora_meter_credit_allocations_transaction_fkey
          ),
          null: false

      add :kind, :string, null: false

      # **The two columns that make the trail reconstructible rather than
      # merely suggestive.** `kind` alone is ambiguous: a `consume` can come out
      # of `available` (a debit) or out of `reserved` (a settlement against its
      # hold), an `expire` out of either, and a `reverse` out of any of three.
      # Without the source bucket, folding a lot's allocations back into its
      # quantities has to guess, and a guess is not a reconstruction. Found by
      # 06a's generated-history property with the counterexample
      # `[grant 4076543 adjustment, hold 738690, debit 483911]`, where the fold
      # took the debit out of the reservation and disagreed with the row.
      add :from_bucket, :string, null: false
      add :to_bucket, :string, null: false

      add :amount, :bigint, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    flush()
    add_seq(@allocations)

    Enum.each(@allocation_checks, fn {name, expression} ->
      add_check(@allocations, name, expression, valid: true)
    end)

    # No uniqueness: one transaction legitimately produces several allocations
    # of the same kind on different lots, and a settle produces both a
    # `consume` and an `unreserve` on one lot.
    create_if_not_exists(index(:aurora_meter_credit_allocations, [:transaction_id]))

    create_if_not_exists(
      index(:aurora_meter_credit_allocations, [:lot_id, :seq],
        name: :aurora_meter_credit_allocations_lot_seq_index
      )
    )

    create_if_not_exists(
      index(:aurora_meter_credit_allocations, [:tenant_key, :seq],
        name: :aurora_meter_credit_allocations_tenant_seq_index
      )
    )

    flush()
  end

  # Created here so phase 06 has one DDL version. Populated by 06d.
  defp create_recurrences do
    create_if_not_exists table(:aurora_meter_credit_recurrences, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :tenant_key, :string, null: false
      add :key, :string, null: false
      add :policy, :map, null: false, default: fragment("'{}'::jsonb")

      add :granted_transaction_id,
          references(:aurora_meter_credit_transactions,
            type: :binary_id,
            on_delete: :restrict,
            name: :aurora_meter_credit_recurrences_grant_fkey
          )

      add :rollover_from_id,
          references(:aurora_meter_credit_recurrences,
            type: :binary_id,
            on_delete: :restrict,
            name: :aurora_meter_credit_recurrences_rollover_fkey
          )

      add :period_start, :utc_datetime, null: false
      add :state, :string, null: false, default: "granted"
      add :inserted_at, :utc_datetime_usec, null: false
    end

    flush()

    Enum.each(@recurrence_checks, fn {name, expression} ->
      add_check(@recurrences, name, expression, valid: true)
    end)

    create_if_not_exists(
      unique_index(:aurora_meter_credit_recurrences, [:tenant_key, :key],
        name: :aurora_meter_credit_recurrences_key_index
      )
    )

    create_if_not_exists(index(:aurora_meter_credit_recurrences, [:tenant_key, :period_start]))
    flush()
  end

  defp add_seq(table) do
    flush()

    if not Map.has_key?(columns(table), "seq") do
      execute("ALTER TABLE #{table} ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY")
      flush()
    end

    execute("CREATE UNIQUE INDEX IF NOT EXISTS #{table}_seq_index ON #{table} (seq)")
    flush()
  end

  defp add_column(subcommands, columns, name, statement) do
    if Map.has_key?(columns, name), do: subcommands, else: subcommands ++ [statement]
  end

  # `valid: true` for a table this version creates, `NOT VALID` for one that
  # already has rows in it. A `NOT VALID` check on a table created empty in the
  # same statement block is not a fast path, it is a permanently unproven
  # constraint the planner cannot use and the next migration rehearsal has to
  # explain.
  defp add_check(table, name, expression, opts \\ []) do
    flush()

    if not constraint?(table, name) do
      suffix = if opts[:valid], do: "", else: " NOT VALID"
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{expression})#{suffix}")
      flush()
    end

    :ok
  end

  # The scan takes SHARE UPDATE EXCLUSIVE, so reads and writes continue while it
  # runs. A violation is a real fact about the customer's wallet rather than a
  # bug in this migration, so the error says how to find it.
  defp validate_balance_checks(false) do
    flush()
    record_unvalidated(@validated_checks)
    :ok
  end

  defp validate_balance_checks(true) do
    flush()

    Enum.each(@validated_checks, fn name ->
      execute(fn -> validate_or_explain(repo(), name) end)
    end)

    flush()
    record_unvalidated([])
    :ok
  end

  # `execute/1` with a one-argument function gives the version the repo rather
  # than a string, which is what lets the failure be turned into an error that
  # says what to do. The constraint is left in place by the rollback of the
  # whole DDL transaction, so a re-run starts clean.
  defp validate_or_explain(repo, name) do
    repo.query!("ALTER TABLE #{@balances} VALIDATE CONSTRAINT #{name}")
    :ok
  rescue
    error in Postgrex.Error ->
      reraise Ecto.MigrationError,
              [
                message:
                  "Aurora Meter schema version 9 could not prove #{name} against the existing " <>
                    "credit balance rows: #{Exception.message(error)}\n\n" <>
                    "A negative `held` or `promotional` is a wallet whose ledger and whose " <>
                    "balance row disagree, and it has to be understood before the lot engine " <>
                    "projects it. Find them with:\n\n#{@violating_balances}\n" <>
                    "Correct the rows and re-run, or pass `validate_checks: false` to apply " <>
                    "version 9 with the constraints enforced from now on and the history left " <>
                    "unproven (recorded in the aurora_meter_checkpoints schema marker)."
              ],
              __STACKTRACE__
  end

  # Version 8's shape: the marker carries which constraints are still unproven,
  # so 11a's reconciliation can see a database that took the escape hatch
  # without re-deriving it from pg_constraint.
  defp record_unvalidated(names) do
    execute(fn ->
      repo().query!(
        """
        UPDATE aurora_meter_checkpoints
        SET counts = jsonb_set(counts, '{unvalidated_balance_constraints}', $1::jsonb),
            updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
        WHERE name = 'schema:core'
        """,
        # The list itself, not `Jason.encode!/1` of it: `$1::jsonb` makes
        # Postgrex encode the parameter as jsonb, so an already-encoded string
        # would land as the jsonb *string* "[]" rather than the empty array.
        [names]
      )

      :ok
    end)

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

  defp columns(table) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = $1
        """,
        [table]
      )

    Map.new(rows, fn [name] -> {name, true} end)
  end
end
