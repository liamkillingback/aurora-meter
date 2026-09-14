defmodule AuroraMeter.Test.Migrations do
  @moduledoc """
  A disposable Postgres database, migrated for real (build unit 03a).

  The Ecto SQL sandbox wraps a test in one transaction on one connection. A
  migration is the opposite of that: core schema version 8 creates an index
  `CONCURRENTLY` and refuses to run inside a transaction at all, version 7's
  `ALTER TABLE` is worth proving against rows that were really committed, and
  the unique index version 8 builds can only be shown to reject a duplicate by
  two connections racing for it.

  So these tests do not use the sandbox. Each one creates its own database,
  named `aurora_v1_<something>` so it can never be confused with
  `aurora_meter_test`, migrates it through `Ecto.Migrator` exactly as a host
  would, and drops it on the way out.

      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 8, concurrently: false)
        assert Migrations.columns(repo)["seq"] == "bigint"
      end)

  `up/2` and `down/2` take the same options `AuroraMeter.Migration.up/1` and
  `down/1` take, and pass them through. The option set is carried in
  application configuration rather than in the migration module, because
  `Ecto.Migrator` calls `module.up/0` with no arguments and the module is the
  only thing it will call.
  """

  alias Ecto.Adapters.Postgres

  @opts_key :aurora_v1_migration_opts

  defmodule Repo do
    @moduledoc false
    use Ecto.Repo, otp_app: :aurora_meter_test, adapter: Ecto.Adapters.Postgres
  end

  defmodule Txn do
    @moduledoc false
    use Ecto.Migration

    alias AuroraMeter.Test.Migrations

    def up, do: Migrations.dispatch(:up)
    def down, do: Migrations.dispatch(:down)
  end

  defmodule NoTxn do
    @moduledoc false
    use Ecto.Migration

    # What `mix aurora_meter.gen.migration` must emit for core schema version 8.
    @disable_ddl_transaction true
    @disable_migration_lock true

    alias AuroraMeter.Test.Migrations

    def up, do: Migrations.dispatch(:up)
    def down, do: Migrations.dispatch(:down)
  end

  @doc false
  @spec dispatch(:up | :down) :: :ok
  def dispatch(direction) do
    opts = Application.get_env(:aurora_meter_test, @opts_key, [])
    apply(AuroraMeter.Migration, direction, [opts])
  end

  @doc """
  Creates a disposable database, starts a repo on it, runs `fun.(repo)` and
  drops the database afterwards, whatever `fun` did.
  """
  @spec with_database((module() -> result), keyword()) :: result when result: term()
  def with_database(fun, opts \\ []) do
    config = config(Keyword.get(opts, :name) || unique_name())

    :ok = Postgres.storage_up(config)
    {:ok, pid} = Repo.start_link(config)

    try do
      fun.(Repo)
    after
      Supervisor.stop(pid)
      :ok = Postgres.storage_down(config)
    end
  end

  @doc """
  Runs `AuroraMeter.Migration.up/1` with `opts` through `Ecto.Migrator`, as a
  host migration would.

  Pass `mode: :no_txn` for a version that must run outside a DDL transaction.
  """
  @spec up(module(), keyword()) :: :ok
  def up(repo, opts) do
    {mode, opts} = Keyword.pop(opts, :mode, :txn)
    migrate(repo, :up, mode, opts)
  end

  @doc """
  Runs `AuroraMeter.Migration.down/1` with `opts` through `Ecto.Migrator`.
  """
  @spec down(module(), keyword()) :: :ok
  def down(repo, opts) do
    {mode, opts} = Keyword.pop(opts, :mode, :txn)
    migrate(repo, :down, mode, opts)
  end

  # Ecto.Migrator records each run in schema_migrations, so every call needs a
  # version number of its own; `down` re-uses the number its `up` was given.
  defp migrate(repo, direction, mode, opts) do
    Application.put_env(:aurora_meter_test, @opts_key, opts)
    module = if mode == :no_txn, do: NoTxn, else: Txn

    version =
      case direction do
        :up -> next_version(repo)
        :down -> last_version(repo)
      end

    apply(Ecto.Migrator, direction, [repo, version, module, [log: false]])
    :ok
  after
    Application.delete_env(:aurora_meter_test, @opts_key)
  end

  defp next_version(repo) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT count(*) FROM information_schema.tables " <>
          "WHERE table_schema = current_schema() AND table_name = 'schema_migrations'",
        []
      )

    if count == 0 do
      1
    else
      %{rows: [[max]]} =
        repo.query!("SELECT coalesce(max(version), 0) FROM schema_migrations", [])

      max + 1
    end
  end

  defp last_version(repo) do
    %{rows: [[max]]} = repo.query!("SELECT coalesce(max(version), 0) FROM schema_migrations", [])
    max
  end

  @doc "Column name to Postgres type, for the table given."
  @spec columns(module(), String.t()) :: %{String.t() => String.t()}
  def columns(repo, table \\ "aurora_meter_events") do
    %{rows: rows} =
      repo.query!(
        """
        SELECT column_name, data_type, is_nullable, column_default, is_identity
        FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = $1
        ORDER BY column_name
        """,
        [table]
      )

    Map.new(rows, fn [name | rest] -> {name, rest} end)
  end

  @doc """
  The whole catalogue of the tables this package owns, as sorted text.

  Columns, indexes and constraints, each as one line, so two databases can be
  compared with a plain string diff and the difference read without tooling.
  """
  @spec catalogue(module()) :: [String.t()]
  def catalogue(repo) do
    columns =
      catalogue_query(repo, """
        SELECT 'column ' || table_name || '.' || column_name || ' ' || data_type ||
               ' null=' || is_nullable || ' identity=' || is_identity ||
               ' default=' || coalesce(column_default, '-')
        FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name LIKE 'aurora_meter%'
      """)

    indexes =
      catalogue_query(repo, """
        SELECT 'index ' || indexname || ' ' || indexdef
        FROM pg_indexes
        WHERE schemaname = current_schema() AND tablename LIKE 'aurora_meter%'
      """)

    constraints =
      catalogue_query(repo, """
        SELECT 'constraint ' || c.relname || '.' || con.conname || ' ' || con.contype::text ||
               ' valid=' || con.convalidated::text || ' ' || pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = current_schema() AND c.relname LIKE 'aurora_meter%'
      """)

    Enum.sort(columns ++ indexes ++ constraints)
  end

  defp catalogue_query(repo, sql) do
    %{rows: rows} = repo.query!(sql, [])
    Enum.map(rows, fn [line] -> line end)
  end

  @doc """
  Inserts `count` rows shaped the way `AuroraMeter.track/4` wrote them in
  0.4.x: no `event_id`, no `occurred_at`, nothing but the five columns that
  existed then.

  Options: `:tenant` (default `"legacy_tenant"`), `:feature` (`"ops"`),
  `:quantity` (1), `:metadata` (`%{}`) and `:at` (a `NaiveDateTime` for
  `inserted_at`; rows are spaced one second apart from it).
  """
  @spec seed_legacy_events(module(), pos_integer(), keyword()) :: :ok
  def seed_legacy_events(repo, count, opts \\ []) do
    repo.query!(
      """
      INSERT INTO aurora_meter_events (id, tenant_key, feature, quantity, metadata, inserted_at)
      SELECT gen_random_uuid(), $1, $2, $3, $4::jsonb, $5::timestamp + (i || ' seconds')::interval
      FROM generate_series(1, $6) AS i
      """,
      [
        Keyword.get(opts, :tenant, "legacy_tenant"),
        Keyword.get(opts, :feature, "ops"),
        Keyword.get(opts, :quantity, 1),
        Keyword.get(opts, :metadata, %{}),
        Keyword.get(opts, :at, ~N[2026-03-10 12:00:00.000000]),
        count
      ]
    )

    :ok
  end

  @doc "Every event row's `{seq, event_id, payload_hash}`, in `seq` order."
  @spec fingerprints(module()) :: [{integer(), String.t() | nil, binary() | nil}]
  def fingerprints(repo) do
    %{rows: rows} =
      repo.query!("SELECT seq, event_id, payload_hash FROM aurora_meter_events ORDER BY seq", [])

    Enum.map(rows, fn [seq, event_id, hash] -> {seq, event_id, hash} end)
  end

  @doc "A name no other run can collide with, in the reserved disposable namespace."
  @spec unique_name() :: String.t()
  def unique_name do
    "aurora_v1_#{System.unique_integer([:positive, :monotonic])}_#{System.pid()}"
  end

  defp config(database) do
    AuroraMeter.TestRepo.config()
    |> Keyword.drop([:pool, :ownership_timeout, :name, :telemetry_prefix])
    |> Keyword.merge(database: database, pool_size: 4, log: false)
  end
end
