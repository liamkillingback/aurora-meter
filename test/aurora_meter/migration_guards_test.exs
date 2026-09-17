defmodule AuroraMeter.MigrationGuardsTest do
  @moduledoc """
  The three refusals build unit 11b added, and the one it inherited.

  Until V1 `AuroraMeter.Migration.up/1` read `:from` and `:version` and dropped
  everything else, so `up(prefix: "tenant_a")` migrated the repository's default
  schema and returned `:ok`. A host reading that return had no way to learn that
  the tables were not where it had asked for them, and the first symptom of the
  mistake would have been an empty ledger rather than an error.

  There is one fact behind all of this: **every query this package issues omits
  the prefix**. So a prefix that reached the migrations and not the queries
  would split the package from its own tables. V1 refuses a prefix in all three
  of the places a host can ask for one:

    * in the call (`up(prefix: ...)`), which is an unknown option like any
      other and raises `ArgumentError`;
    * in the repository (`migration_default_prefix`, or a `default_options`
      prefix), which raises `AuroraMeter.Config.PrefixError` at boot;
    * on the migration runner (`mix ecto.migrate --prefix`), which raises the
      same error before any version runs.

  The fourth refusal, `DataLossError`, is 11a's and is re-proved here for the
  half nobody had run: that a refused `down` really does leave the tables in
  place, and that a confirmed one really does drop them.
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Config
  alias AuroraMeter.Migration
  alias AuroraMeter.Migration.DataLossError
  alias AuroraMeter.Test.Migrations

  defmodule PrefixedRepo do
    @moduledoc false
    # A repository configured the way a schema-per-tenant host configures one.
    def config, do: [otp_app: :aurora_meter_test, migration_default_prefix: "tenant_a"]
    def default_options(_operation), do: []
  end

  defmodule DefaultOptionsRepo do
    @moduledoc false
    # The other half: nothing in the repository's configuration, but every
    # query carries a prefix. This is the direction that leaves the tables in
    # `public` and reads `tenant_a`, which is the silent one.
    def config, do: [otp_app: :aurora_meter_test]
    def default_options(:all), do: [prefix: "tenant_a"]
    def default_options(_operation), do: []
  end

  defmodule InsertAllPrefixRepo do
    @moduledoc false
    # `Storage.Ecto` writes counters, events and receipts with `insert_all`, so
    # a prefix on that operation alone is enough to split writes from reads.
    def config, do: [otp_app: :aurora_meter_test]
    def default_options(:insert_all), do: [prefix: "tenant_a"]
    def default_options(_operation), do: []
  end

  defmodule PublicRepo do
    @moduledoc false
    # The negative control: a repository that names the schema Aurora Meter
    # already uses. Naming it is not a mistake and must not refuse a boot.
    def config, do: [otp_app: :aurora_meter_test, migration_default_prefix: "public"]
    def default_options(_operation), do: [prefix: "public"]
  end

  defmodule NilRepo do
    @moduledoc false
    def config, do: [otp_app: :aurora_meter_test, migration_default_prefix: nil]
    def default_options(_operation), do: []
  end

  defmodule NotARepo do
    @moduledoc false
    # A module with neither callback. Ecto reports this far better than this
    # check could, so the check says nothing rather than guessing.
    def hello, do: :world
  end

  defmodule PrefixMigration do
    @moduledoc false
    use Ecto.Migration

    def up, do: AuroraMeter.Migration.up(from: 1, version: 1)
    def down, do: :ok
  end

  @unique_index "aurora_meter_events_tenant_event_id_index"

  describe "L-11b-1: an unknown option raises rather than being dropped" do
    test "I19 up/1 raises ArgumentError naming the unknown option" do
      error = assert_raise(ArgumentError, fn -> Migration.up(nonsense: 1) end)

      assert error.message =~ ":nonsense"
      assert error.message =~ "does not understand"
      assert error.message =~ "Supported:"
    end

    test "I19 up/1 names prefix and the default schema when prefix is given" do
      error = assert_raise(ArgumentError, fn -> Migration.up(prefix: "tenant_a") end)

      assert error.message =~ ":prefix"
      assert error.message =~ "repository's default schema"
      assert error.message =~ "no query would ever read"
    end

    test "I19 down/1 raises ArgumentError naming the unknown option" do
      error = assert_raise(ArgumentError, fn -> Migration.down(nonsense: 1) end)

      assert error.message =~ ":nonsense"
      assert error.message =~ "down/1"
    end

    test "I19 down/1 names prefix when prefix is given" do
      error = assert_raise(ArgumentError, fn -> Migration.down(prefix: "tenant_a") end)

      assert error.message =~ ":prefix"
      assert error.message =~ "repository's default schema"
    end

    test "I19 a misspelled known option is refused too" do
      error = assert_raise(ArgumentError, fn -> Migration.up(validate_check: false) end)

      assert error.message =~ ":validate_check"
      assert error.message =~ ":validate_checks"
    end

    test "I19 every option the version modules read is accepted" do
      # The negative control for the list itself: a guard that refused
      # everything would pass every test above.
      Migrations.with_database(fn repo ->
        Migrations.up(repo,
          from: 1,
          version: 8,
          concurrently: false,
          validate_checks: true,
          lock_timeout: "5s"
        )

        assert Migrations.columns(repo)["event_id"]
      end)
    end

    test "I19 a non-keyword argument is refused by name" do
      # Through a variable, so the compiler's type checker does not turn a
      # deliberate misuse into a build warning.
      not_a_keyword = Map.new(from: 1)
      error = assert_raise(ArgumentError, fn -> Migration.up(not_a_keyword) end)

      assert error.message =~ "keyword list"
    end
  end

  describe "L-11b-2: a repository that would migrate into another schema refuses to boot" do
    test "I19 validate! raises PrefixError when the repo sets migration_default_prefix" do
      error =
        with_repo(PrefixedRepo, fn ->
          assert_raise(AuroraMeter.Config.PrefixError, fn -> Config.validate!() end)
        end)

      assert error.source == {:repo_config, PrefixedRepo, :migration_default_prefix, "tenant_a"}
      assert error.message =~ "migration_default_prefix"
      assert error.message =~ "AuroraMeter.MigrationGuardsTest.PrefixedRepo"
      assert error.message =~ "not supported"
    end

    test "I19 validate! raises PrefixError when default_options carries a prefix for reads" do
      error =
        with_repo(DefaultOptionsRepo, fn ->
          assert_raise(AuroraMeter.Config.PrefixError, fn -> Config.validate!() end)
        end)

      assert error.source == {:default_options, DefaultOptionsRepo, :all, "tenant_a"}
      assert error.message =~ "default_options(:all)"
    end

    test "I19 validate! raises PrefixError when default_options carries a prefix for insert_all" do
      error =
        with_repo(InsertAllPrefixRepo, fn ->
          assert_raise(AuroraMeter.Config.PrefixError, fn -> Config.validate!() end)
        end)

      assert error.source == {:default_options, InsertAllPrefixRepo, :insert_all, "tenant_a"}
    end

    test "I19 validate! passes when the prefix is nil" do
      with_repo(NilRepo, fn -> assert Config.validate!()[:repo] == NilRepo end)
    end

    test "I19 validate! passes when the prefix is public" do
      with_repo(PublicRepo, fn -> assert Config.validate!()[:repo] == PublicRepo end)
    end

    test "I19 validate! says nothing about a module that is not a repository" do
      # Not a pass by luck: Ecto reports a module that is not a repository in
      # its own words, and a prefix check that invented an opinion about it
      # would be answering a question it cannot see.
      with_repo(NotARepo, fn -> assert Config.validate!()[:repo] == NotARepo end)
    end

    test "I19 the suite's own repository passes the check" do
      assert Config.validate!()[:repo] == AuroraMeter.TestRepo
    end
  end

  describe "L-11b-2: a migration running under a prefix refuses before it creates anything" do
    test "I19 mix ecto.migrate --prefix raises PrefixError and creates no table" do
      Migrations.with_database(fn repo ->
        repo.query!("CREATE SCHEMA tenant_a", [])

        error =
          assert_raise(AuroraMeter.Config.PrefixError, fn ->
            Ecto.Migrator.up(repo, 1, PrefixMigration, prefix: "tenant_a", log: false)
          end)

        assert error.source == {:migration_runner, "tenant_a"}
        assert error.message =~ "Nothing has been created"

        # The claim in the message, checked rather than trusted. Ecto's own
        # `schema_migrations` is created in the prefix before any migration
        # runs, so it is excluded by name: it is the migrator's bookkeeping and
        # not one of this package's tables. Nothing of Aurora Meter's is there.
        assert aurora_tables(repo, "tenant_a") == []
        assert aurora_tables(repo, "public") == []
      end)
    end

    test "I19 the same migration with no prefix runs" do
      # The negative control. Without it the test above would pass for a
      # version that never works at all.
      Migrations.with_database(fn repo ->
        assert Ecto.Migrator.up(repo, 1, PrefixMigration, log: false) == :ok
        assert "aurora_meter_events" in tables(repo, "public")
      end)
    end
  end

  describe "L-11b-3: down is refused unless the loss is confirmed" do
    test "I19 down(version: 10, to: 1) raises DataLossError and changes nothing" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 10, concurrently: false)
        before = tables(repo, "public")

        error = assert_raise(DataLossError, fn -> Migration.down(version: 10, to: 1) end)

        for version <- [1, 3, 4, 7, 8, 9, 10] do
          assert version in error.destructive,
                 "version #{version} is on the binding map's destructive list"
        end

        assert error.message =~ "not a rollback"
        assert error.message =~ "confirm_data_loss: true"

        # The half that matters: a refusal that had already dropped a table
        # would still have raised.
        assert tables(repo, "public") == before
      end)
    end

    test "I19 down of a range with no destructive version needs no confirmation" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.down(repo, version: 6, to: 5)

        assert "aurora_meter_events" in tables(repo, "public")
        refute "aurora_meter_flush_receipts" in tables(repo, "public")
      end)
    end

    test "I19 down with confirm_data_loss: true drops the tables" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 10, concurrently: false)
        assert "aurora_meter_events" in tables(repo, "public")

        Migrations.down(repo,
          version: 10,
          to: 1,
          confirm_data_loss: true,
          concurrently: false
        )

        remaining = tables(repo, "public")

        for table <- [
              "aurora_meter_events",
              "aurora_meter_counters",
              "aurora_meter_subscriptions",
              "aurora_meter_credit_balances",
              "aurora_meter_credit_transactions"
            ] do
          refute table in remaining, "#{table} survived a confirmed down"
        end
      end)
    end
  end

  describe "I16 a re-run of the whole history is a no-op" do
    test "I16 up(from: 1, version: latest) twice raises nothing and changes no catalogue" do
      # The moduledoc's claim, checked: "Every version is idempotent
      # (create_if_not_exists), so up/1 can safely run from version 1 each
      # time." An operator whose upgrade died half way re-runs exactly this,
      # and a version using a bare `add` inside an `alter table` answers with
      # `duplicate_column` rather than with a no-op.
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 10, concurrently: false)
        first = Migrations.catalogue(repo)

        Migrations.up(repo, from: 1, version: 10, concurrently: false)

        assert Migrations.catalogue(repo) == first
      end)
    end
  end

  describe "L-11b-4: version 8 converges on one valid index" do
    test "I16 it drops the index a real aborted concurrent create left behind" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        # A genuinely aborted CREATE INDEX CONCURRENTLY, not a simulated one:
        # two rows claiming the same identity make the build fail, and Postgres
        # leaves the INVALID index behind rather than cleaning it up. The
        # existing V8 test sets `indisvalid = false` by hand, which proves the
        # guard reads the catalogue but not that Postgres leaves this state.
        insert!(repo, "tenant_dup", "same-id", 1)
        insert!(repo, "tenant_dup", "same-id", 2)

        assert_raise(Postgrex.Error, fn ->
          repo.query!(
            "CREATE UNIQUE INDEX CONCURRENTLY #{@unique_index} " <>
              "ON aurora_meter_events (tenant_key, event_id)",
            []
          )
        end)

        assert index_state(repo) == {:present, false},
               "Postgres is expected to leave an INVALID index behind; if it does not, " <>
                 "the guard in version 8 is being tested against a state that cannot occur"

        repo.query!("DELETE FROM aurora_meter_events WHERE quantity = 2", [])

        Migrations.up(repo, from: 8, version: 8, concurrently: false)

        assert index_state(repo) == {:present, true}
        assert index_count(repo) == 1
      end)
    end

    test "I16 applying version 8 twice leaves exactly one valid index" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 8, concurrently: false)
        Migrations.up(repo, from: 8, version: 8, concurrently: false)

        assert index_state(repo) == {:present, true}
        assert index_count(repo) == 1
      end)
    end
  end

  defp with_repo(repo, fun) do
    AuroraMeter.Test.Config.with_config([{:aurora_meter, :repo, repo}], fun)
  end

  defp aurora_tables(repo, schema) do
    repo |> tables(schema) |> Enum.filter(&String.starts_with?(&1, "aurora_meter_"))
  end

  defp tables(repo, schema) do
    %{rows: rows} =
      repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = $1 ORDER BY tablename",
        [schema]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp index_state(repo) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT i.indisvalid
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        WHERE c.relname = $1
        """,
        [@unique_index]
      )

    case rows do
      [] -> :absent
      [[valid]] -> {:present, valid}
    end
  end

  defp index_count(repo) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM pg_class WHERE relname = $1 AND relkind = 'i'", [
        @unique_index
      ])

    count
  end

  defp insert!(repo, tenant, event_id, quantity) do
    repo.query!(
      """
      INSERT INTO aurora_meter_events
        (id, tenant_key, feature, quantity, metadata, inserted_at, event_id, payload_hash,
         occurred_at)
      VALUES (gen_random_uuid(), $1, 'ops', $2, '{}'::jsonb, now(), $3, decode($4, 'hex'), now())
      """,
      [tenant, quantity, event_id, String.duplicate("ab", 32)]
    )

    :ok
  end
end
