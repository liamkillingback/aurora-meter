defmodule AuroraMeter.MigrationV9Test do
  @moduledoc """
  Core schema version 9, run for real against a disposable database.

  Version 9 is additive and writes no data: the lot tables arrive empty and
  every wallet stays on the legacy writer until `lots_enabled_at` is set, which
  is what makes a mixed fleet safe across the DDL and an application rollback to
  the previous image supported (`schema-migration-map.md` section 7).

  The claims worth testing here are about a database with rows already in it, so
  these run against a real disposable database rather than the sandbox
  (see `AuroraMeter.Test.Migrations`).
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Migration
  alias AuroraMeter.Test.Migrations

  test "I19 a fresh install and an incremental upgrade to 9 produce the same catalogue" do
    fresh =
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 9, concurrently: false)
        Migrations.catalogue(repo)
      end)

    upgraded =
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.up(repo, from: 7, version: 7)
        Migrations.up(repo, from: 8, version: 8, concurrently: false)
        Migrations.up(repo, from: 9, version: 9)
        Migrations.catalogue(repo)
      end)

    assert (fresh -- upgraded) ++ (upgraded -- fresh) == [],
           "a database built in one step and one built version by version must be the same " <>
             "database. Only in fresh:\n  " <>
             Enum.join(fresh -- upgraded, "\n  ") <>
             "\nOnly in upgraded:\n  " <> Enum.join(upgraded -- fresh, "\n  ")
  end

  test "I19 version 9 creates the lot, allocation and recurrence tables with their constraints" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 8, concurrently: false)
      refute table?(repo, "aurora_meter_credit_lots")

      Migrations.up(repo, from: 9, version: 9)

      for table <- ~w(aurora_meter_credit_lots aurora_meter_credit_allocations
                      aurora_meter_credit_recurrences) do
        assert table?(repo, table), "#{table} was not created"
      end

      names = constraint_names(repo, "aurora_meter_credit_lots")

      for expected <- ~w(aurora_meter_credit_lots_conservation_check
                         aurora_meter_credit_lots_state_check
                         aurora_meter_credit_lots_amount_check
                         aurora_meter_credit_lots_category_check
                         aurora_meter_credit_lots_available_check
                         aurora_meter_credit_lots_reserved_check
                         aurora_meter_credit_lots_consumed_check
                         aurora_meter_credit_lots_reversed_check
                         aurora_meter_credit_lots_expired_check
                         aurora_meter_credit_lots_grant_fkey) do
        assert expected in names, "#{expected} is missing: #{inspect(names)}"
      end

      # The `seq` identity columns, which are what every ordering in the ledger
      # now reads. `GENERATED ALWAYS`, so the sequence assigns it and no caller
      # can send a value.
      for table <- ~w(aurora_meter_credit_transactions aurora_meter_credit_lots
                      aurora_meter_credit_allocations) do
        assert %{"seq" => ["bigint", "NO", nil, "YES"]} = Migrations.columns(repo, table),
               "#{table}.seq is not a NOT NULL bigint identity column"

        assert identity_generation(repo, table, "seq") == "ALWAYS",
               "#{table}.seq is not GENERATED ALWAYS, so a caller can send its own value and " <>
                 "the column stops being an order"
      end

      assert Checkpoints.get("schema:core", repo: repo).cursor["version"] == 9
    end)
  end

  test "I19 version 9 is additive over a database that already holds credit rows" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 8, concurrently: false)

      repo.query!(
        "INSERT INTO aurora_meter_credit_balances (id, tenant_key, balance, held, promotional, " <>
          "currency, inserted_at, updated_at) VALUES (gen_random_uuid(), 'legacy', 500, 100, 0, " <>
          "'usd', now(), now())",
        []
      )

      repo.query!(
        "INSERT INTO aurora_meter_credit_transactions (id, tenant_key, kind, amount, held_delta, " <>
          "balance_after, held_after, metadata, inserted_at) VALUES " <>
          "(gen_random_uuid(), 'legacy', 'grant', 500, 0, 500, 0, '{}'::jsonb, now())",
        []
      )

      Migrations.up(repo, from: 9, version: 9)

      # The rows are still there, unchanged, and they now carry a seq.
      %{rows: [[balance, held, debt, expired, lots_enabled_at]]} =
        repo.query!(
          "SELECT balance, held, debt, expired, lots_enabled_at FROM " <>
            "aurora_meter_credit_balances WHERE tenant_key = 'legacy'",
          []
        )

      assert {balance, held, debt, expired} == {500, 100, 0, 0}
      assert is_nil(lots_enabled_at), "version 9 must not cut a wallet over"

      %{rows: [[seq, updated_at, hold_id]]} =
        repo.query!(
          "SELECT seq, updated_at, hold_transaction_id FROM aurora_meter_credit_transactions " <>
            "WHERE tenant_key = 'legacy'",
          []
        )

      assert is_integer(seq) and seq > 0
      assert is_nil(updated_at), "a row nobody has updated must not claim to have been updated"
      assert is_nil(hold_id)

      # And no lot was invented for it: the replay is 06b's, under its own
      # reconciliation.
      %{rows: [[lots]]} = repo.query!("SELECT count(*) FROM aurora_meter_credit_lots", [])
      assert lots == 0
    end)
  end

  test "I19 version 9 refuses a database whose balance rows already violate the new checks" do
    # The named plan for a violating row: the migration fails inside its DDL
    # transaction and applies nothing, so the operator fixes the wallet and
    # re-runs. The error says how to find it.
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 8, concurrently: false)

      repo.query!(
        "INSERT INTO aurora_meter_credit_balances (id, tenant_key, balance, held, promotional, " <>
          "currency, inserted_at, updated_at) VALUES (gen_random_uuid(), 'broken', 0, -1, 0, " <>
          "'usd', now(), now())",
        []
      )

      error =
        assert_raise Ecto.MigrationError, fn ->
          Migrations.up(repo, from: 9, version: 9)
        end

      assert error.message =~ "aurora_meter_credit_balances_held_check"
      assert error.message =~ "SELECT tenant_key, balance, held, promotional"
      assert error.message =~ "validate_checks: false"

      # Nothing was applied: the whole version rolled back.
      refute table?(repo, "aurora_meter_credit_lots")

      # And the documented escape hatch works, recording in the marker that the
      # history is unproven. The constraint is enforced from now on, which is
      # the safe direction: the bad row is refused the next time anything
      # updates it.
      Migrations.up(repo, from: 9, version: 9, validate_checks: false)
      assert table?(repo, "aurora_meter_credit_lots")

      unvalidated =
        Checkpoints.get("schema:core", repo: repo).counts["unvalidated_balance_constraints"]

      assert "aurora_meter_credit_balances_held_check" in unvalidated

      assert_raise Postgrex.Error, fn ->
        repo.query!(
          "UPDATE aurora_meter_credit_balances SET balance = 1 WHERE tenant_key = 'broken'",
          []
        )
      end
    end)
  end

  test "I19 down(version: 9) without confirm_data_loss raises" do
    assert 9 in Migration.data_loss_versions()

    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)

      assert_raise Migration.DataLossError, fn ->
        Migrations.down(repo, version: 9, to: 9)
      end

      assert table?(repo, "aurora_meter_credit_lots")

      Migrations.down(repo, version: 9, to: 9, confirm_data_loss: true)
      refute table?(repo, "aurora_meter_credit_lots")
      refute table?(repo, "aurora_meter_credit_allocations")
      refute table?(repo, "aurora_meter_credit_recurrences")

      # The ledger itself survives the rollback, which is what makes an
      # application rollback to the previous image supported before the wallet
      # cutover: the legacy writer ignores the new tables entirely.
      assert table?(repo, "aurora_meter_credit_transactions")
      refute Map.has_key?(Migrations.columns(repo, "aurora_meter_credit_transactions"), "seq")
      refute Map.has_key?(Migrations.columns(repo, "aurora_meter_credit_balances"), "debt")
    end)
  end

  test "I19 version 9 is idempotent: running it twice changes nothing" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)
      once = Migrations.catalogue(repo)

      Migrations.up(repo, from: 9, version: 9)
      twice = Migrations.catalogue(repo)

      assert (once -- twice) ++ (twice -- once) == [],
             "re-running version 9 changed the catalogue. Only after one run:\n  " <>
               Enum.join(once -- twice, "\n  ") <>
               "\nOnly after two:\n  " <> Enum.join(twice -- once, "\n  ")
    end)
  end

  defp table?(repo, name) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema() " <>
          "AND table_name = $1",
        [name]
      )

    count == 1
  end

  defp identity_generation(repo, table, column) do
    %{rows: [[generation]]} =
      repo.query!(
        "SELECT identity_generation FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    generation
  end

  defp constraint_names(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = to_regclass($1)::oid",
        [table]
      )

    List.flatten(rows)
  end
end
