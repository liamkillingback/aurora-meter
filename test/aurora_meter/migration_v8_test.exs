defmodule AuroraMeter.MigrationV8Test do
  @moduledoc """
  Core schema version 8, run for real against a disposable database.

  Version 8 is the version that turns "one identity, one fact" from something
  the application tries to do into something the database will not let it stop
  doing. Proving that needs two connections racing, an index that is really
  built, and a `NOT NULL` that is really promoted, so none of this can run in
  the sandbox (see `AuroraMeter.Test.Migrations`).
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Events.Backfill
  alias AuroraMeter.Migration
  alias AuroraMeter.Test.Migrations

  @unique_index "aurora_meter_events_tenant_event_id_index"
  @plain_index "aurora_meter_events_tenant_key_event_id_index"

  describe "one identity, one fact" do
    test "I06 two inserts of the same (tenant_key, event_id) leave exactly one row" do
      Migrations.with_database(fn repo ->
        migrated(repo)

        results =
          1..2
          |> Enum.map(fn index ->
            Task.async(fn -> insert(repo, "tenant_one", "same-id", index) end)
          end)
          |> Task.await_many(15_000)

        assert Enum.count(results, &(&1 == :ok)) == 1
        assert [%Postgrex.Error{} = error] = Enum.reject(results, &(&1 == :ok))
        assert error.postgres.code == :unique_violation
        assert error.postgres.constraint == @unique_index

        assert count(repo, "tenant_one") == 1
      end)
    end

    test "I06 the same event_id under two tenants is two facts" do
      Migrations.with_database(fn repo ->
        migrated(repo)

        assert insert(repo, "tenant_a", "shared-id", 1) == :ok
        assert insert(repo, "tenant_b", "shared-id", 2) == :ok

        assert count(repo, "tenant_a") == 1
        assert count(repo, "tenant_b") == 1
      end)
    end

    test "the plain index version 7 added is gone, superseded by the unique one" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        assert index?(repo, @plain_index)

        Migrations.up(repo, from: 8, version: 8, concurrently: false)

        refute index?(repo, @plain_index),
               "the plain index is a prefix of the unique one and serves nothing after it"

        assert index?(repo, @unique_index)
      end)
    end
  end

  describe "it refuses rather than guess" do
    test "I07 it refuses while any event_id is null, and names the count" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.seed_legacy_events(repo, 3, tenant: "not_backfilled")
        Migrations.up(repo, from: 7, version: 7)

        error =
          assert_raise Migration.BackfillIncompleteError, fn ->
            Migrations.up(repo, from: 8, version: 8, concurrently: false)
          end

        assert error.remaining == 3
        assert Exception.message(error) =~ "3 rows"
        assert Exception.message(error) =~ "mix aurora_meter.events.backfill"

        refute index?(repo, @unique_index), "nothing may be created before the refusal"
      end)
    end

    test "I07 it runs once the backfill has filled them" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.seed_legacy_events(repo, 3, tenant: "backfilled")
        Migrations.up(repo, from: 7, version: 7)

        {:ok, counts} = Backfill.run(repo: repo)
        assert counts["updated"] == 3

        Migrations.up(repo, from: 8, version: 8, concurrently: false)
        assert index?(repo, @unique_index)
        assert nullable(repo, "event_id") == "NO"
      end)
    end

    test "I07 it promotes event_id, payload_hash and occurred_at to NOT NULL" do
      Migrations.with_database(fn repo ->
        migrated(repo)

        for column <- ~w(event_id payload_hash occurred_at) do
          assert nullable(repo, column) == "NO", "#{column} is still nullable"
        end

        # period_start stays nullable on purpose: it is resolved, not supplied,
        # and a source that cannot answer is recorded rather than refused.
        assert nullable(repo, "period_start") == "YES"
      end)
    end
  end

  describe "it must run outside a transaction" do
    test "it raises ConcurrentVersionError inside a DDL transaction" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        assert_raise Migration.ConcurrentVersionError, ~r/@disable_ddl_transaction/, fn ->
          # mode: :txn is the default migration file shape, which is exactly
          # the mistake this guard exists to name.
          Migrations.up(repo, from: 8, version: 8, mode: :txn)
        end
      end)
    end

    # The negative control. The same call in a file carrying both attributes
    # must succeed, or the guard above would pass for a version that simply
    # never works.
    test "it succeeds in a file carrying both attributes" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        Migrations.up(repo, from: 8, version: 8, mode: :no_txn)

        assert index?(repo, @unique_index)
        assert indisvalid(repo, @unique_index)
      end)
    end
  end

  describe "leftovers from a failed attempt" do
    test "it drops an INVALID index before retrying" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        # What a killed CREATE INDEX CONCURRENTLY leaves behind. Postgres does
        # not clean it up, nothing uses it, and it holds the name.
        repo.query!(
          "CREATE UNIQUE INDEX #{@unique_index} ON aurora_meter_events " <>
            "(tenant_key, event_id)",
          []
        )

        repo.query!(
          "UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)::oid",
          [@unique_index]
        )

        refute indisvalid(repo, @unique_index)

        Migrations.up(repo, from: 8, version: 8, concurrently: false)

        assert indisvalid(repo, @unique_index),
               "the retry must drop the invalid index and build a valid one"
      end)
    end
  end

  describe "validate_checks" do
    test "it validates all six constraints by default" do
      Migrations.with_database(fn repo ->
        migrated(repo)

        assert unvalidated(repo) == []

        assert Checkpoints.get("schema:core", repo: repo).counts[
                 "unvalidated_constraints"
               ] == []
      end)
    end

    test "validate_checks: false leaves them NOT VALID and records which" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        # A row the V1 contract refuses and 0.4.x accepted. With the checks
        # validated this migration would fail; that is what the escape is for.
        Migrations.seed_legacy_events(repo, 1, tenant: "bad_history", quantity: -1)
        Migrations.up(repo, from: 7, version: 7)
        {:ok, _counts} = Backfill.run(repo: repo)

        assert_raise Postgrex.Error, ~r/check constraint/, fn ->
          Migrations.up(repo, from: 8, version: 8, concurrently: false)
        end
      end)

      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.seed_legacy_events(repo, 1, tenant: "bad_history", quantity: -1)
        Migrations.up(repo, from: 7, version: 7)
        {:ok, _counts} = Backfill.run(repo: repo)

        Migrations.up(repo, from: 8, version: 8, concurrently: false, validate_checks: false)

        assert unvalidated(repo) == [
                 "aurora_meter_events_correction_pairing_check",
                 "aurora_meter_events_dimensions_object_check",
                 "aurora_meter_events_event_id_length_check",
                 "aurora_meter_events_kind_check",
                 "aurora_meter_events_metadata_size_check",
                 "aurora_meter_events_quantity_check"
               ]

        recorded =
          Checkpoints.get("schema:core", repo: repo).counts[
            "unvalidated_constraints"
          ]

        assert Enum.sort(recorded) == unvalidated(repo),
               "the marker must say which constraints are unproven, so 11a's " <>
                 "reconciliation does not have to re-derive it"

        # NOT VALID still enforces the constraint on every new row. Only the
        # history is left unproven.
        error = assert_raise(Postgrex.Error, fn -> insert!(repo, "new_writer", "new-id", 0) end)
        assert error.postgres.constraint == "aurora_meter_events_quantity_check"
      end)
    end
  end

  describe "down" do
    test "it drops the unique index and restores the plain one, once the loss is confirmed" do
      # It used to run without `confirm_data_loss` and the test name said the
      # version "needs no confirmation". `schema-migration-map.md` section 3
      # names version 8 with its reason: the unique index on
      # `(tenant_key, event_id)` is the identity guarantee, so dropping it is
      # losing the guarantee, not losing an index (`open-findings.md` X362).
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        Migrations.up(repo, from: 8, version: 8, mode: :no_txn)

        Migrations.down(repo, version: 8, to: 8, mode: :no_txn, confirm_data_loss: true)

        refute index?(repo, @unique_index)
        assert index?(repo, @plain_index)
        assert nullable(repo, "event_id") == "YES"

        assert Checkpoints.get("schema:core", repo: repo).cursor["version"] == 7,
               "after a successful down of 8 the database is at 7 and the marker must say so"
      end)
    end
  end

  defp migrated(repo) do
    Migrations.up(repo, from: 1, version: 8, concurrently: false)
  end

  # Raises, for a case whose subject is the refusal.
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

  # Returns the error instead, for a case that races two of these and has to
  # look at both outcomes.
  defp insert(repo, tenant, event_id, quantity) do
    insert!(repo, tenant, event_id, quantity)
  rescue
    error in Postgrex.Error -> error
  end

  defp count(repo, tenant) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM aurora_meter_events WHERE tenant_key = $1", [tenant])

    count
  end

  defp index?(repo, name) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM pg_class WHERE relname = $1 AND relkind = 'i'", [name])

    count > 0
  end

  defp indisvalid(repo, name) do
    %{rows: [[valid]]} =
      repo.query!(
        "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)::oid",
        [name]
      )

    valid
  end

  defp nullable(repo, column) do
    %{rows: [[nullable]]} =
      repo.query!(
        "SELECT is_nullable FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = 'aurora_meter_events' " <>
          "AND column_name = $1",
        [column]
      )

    nullable
  end

  defp unvalidated(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT conname FROM pg_constraint " <>
          "WHERE conrelid = 'aurora_meter_events'::regclass AND contype = 'c' " <>
          "AND NOT convalidated ORDER BY conname",
        []
      )

    Enum.map(rows, &hd/1)
  end
end
