defmodule AuroraMeter.MigrationV10Test do
  @moduledoc """
  Core schema version 10, run for real against a disposable database
  (build unit 07a, `schema-migration-map.md` step S6).

  Version 10 is additive and writes no data. Every plan column arrives NULL and
  the legacy assignment is `AuroraMeter.Plans.register!/0`'s, which is what makes
  an application rollback to the previous image supported until a transition is
  scheduled.

  It also carries `open-findings.md` **X220**, which belongs to a different
  concern and is verified separately below: the `clock_timestamp()` default on
  `aurora_meter_flush_receipts.inserted_at`, after which
  `AuroraMeter.Storage.Ecto.flush_batch/3` omits the column and the receipt is
  stamped by the database that later compares it.
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Migration
  alias AuroraMeter.Test.Migrations

  @plan_columns ~w(plan_version plan_fingerprint plan_effective_at
                   scheduled_plan_id scheduled_plan_version scheduled_effective_at
                   transition_ref transition_state transition_confirm
                   transition_applied_at)

  test "I19 a fresh install and an incremental upgrade to 10 produce the same catalogue" do
    fresh =
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 10, concurrently: false)
        Migrations.catalogue(repo)
      end)

    upgraded =
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.up(repo, from: 7, version: 7)
        Migrations.up(repo, from: 8, version: 8, concurrently: false)
        Migrations.up(repo, from: 9, version: 9)
        Migrations.up(repo, from: 10, version: 10)
        Migrations.catalogue(repo)
      end)

    assert (fresh -- upgraded) ++ (upgraded -- fresh) == [],
           "a database built in one step and one built version by version must be the same " <>
             "database. Only in fresh:\n  " <>
             Enum.join(fresh -- upgraded, "\n  ") <>
             "\nOnly in upgraded:\n  " <> Enum.join(upgraded -- fresh, "\n  ")
  end

  test "I19 version 10 creates both plan tables and every subscription column with its checks" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)

      refute table?(repo, "aurora_meter_plan_versions")
      refute table?(repo, "aurora_meter_plan_transitions")
      columns_before = Migrations.columns(repo, "aurora_meter_subscriptions")

      for column <- @plan_columns do
        refute Map.has_key?(columns_before, column), "#{column} existed before version 10"
      end

      Migrations.up(repo, from: 10, version: 10)

      assert table?(repo, "aurora_meter_plan_versions")
      assert table?(repo, "aurora_meter_plan_transitions")

      columns = Migrations.columns(repo, "aurora_meter_subscriptions")

      for column <- @plan_columns do
        assert Map.has_key?(columns, column), "#{column} was not added"
        assert [_type, "YES" | _rest] = columns[column], "#{column} is not nullable"
      end

      version_constraints = constraint_names(repo, "aurora_meter_plan_versions")

      for expected <- ~w(aurora_meter_plan_versions_fingerprint_check
                         aurora_meter_plan_versions_version_check
                         aurora_meter_plan_versions_plan_id_check
                         aurora_meter_plan_versions_plan_id_version_index) do
        assert expected in version_constraints,
               "#{expected} is missing: #{inspect(version_constraints)}"
      end

      transition_constraints = constraint_names(repo, "aurora_meter_plan_transitions")

      for expected <- ~w(aurora_meter_plan_transitions_state_check
                         aurora_meter_plan_transitions_confirm_check
                         aurora_meter_plan_transitions_ref_check
                         aurora_meter_plan_transitions_tenant_ref_index) do
        assert expected in transition_constraints,
               "#{expected} is missing: #{inspect(transition_constraints)}"
      end

      subscription_constraints = constraint_names(repo, "aurora_meter_subscriptions")

      for expected <- ~w(aurora_meter_subscriptions_transition_state_check
                         aurora_meter_subscriptions_transition_confirm_check) do
        assert expected in subscription_constraints,
               "#{expected} is missing: #{inspect(subscription_constraints)}"
      end

      # S6 asks for a **partial** index: only pending rows are ever scanned, and
      # on a table where almost every row has a NULL `transition_state` a full
      # two-column index would be almost entirely dead weight.
      assert index_predicate(repo, "aurora_meter_subscriptions_pending_transition_index") =~
               "transition_state = 'pending'"

      # And both `NOT VALID` checks were validated in the same version, so the
      # planner can use them and no later rehearsal has to explain an unproven
      # constraint.
      assert validated?(repo, "aurora_meter_subscriptions_transition_state_check")
      assert validated?(repo, "aurora_meter_subscriptions_transition_confirm_check")

      assert marker_version(repo) == 10
    end)
  end

  test "I19 version 10 refuses a transition state it does not know" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 10, concurrently: false)

      insert_subscription!(repo, "checkt_1")

      assert_raise Postgrex.Error, fn ->
        repo.query!(
          "UPDATE aurora_meter_subscriptions SET transition_state = 'halfway' " <>
            "WHERE tenant_key = 'checkt_1'"
        )
      end

      # NULL is allowed, which is what every existing row is.
      repo.query!(
        "UPDATE aurora_meter_subscriptions SET transition_state = 'pending', " <>
          "transition_confirm = 'provider' WHERE tenant_key = 'checkt_1'"
      )
    end)
  end

  test "I19 version 10 refuses a plan version fingerprint that is not 32 bytes" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 10, concurrently: false)

      assert_raise Postgrex.Error, fn ->
        repo.query!(
          "INSERT INTO aurora_meter_plan_versions (plan_id, version, fingerprint) " <>
            "VALUES ('pro', '1', '\\x0102'::bytea)"
        )
      end

      repo.query!(
        "INSERT INTO aurora_meter_plan_versions (plan_id, version, fingerprint) " <>
          "VALUES ('pro', '1', $1)",
        [:crypto.hash(:sha256, "pro")]
      )

      # And the identity is unique, so two nodes registering at once cannot
      # leave two definitions of one version.
      assert_raise Postgrex.Error, fn ->
        repo.query!(
          "INSERT INTO aurora_meter_plan_versions (plan_id, version, fingerprint) " <>
            "VALUES ('pro', '1', $1)",
          [:crypto.hash(:sha256, "other")]
        )
      end
    end)
  end

  test "I19 a populated version 9 database upgrades with no subscription changed" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)

      for index <- 1..50 do
        insert_subscription!(repo, "popt_#{index}", plan_id: "pro", status: "active")
      end

      before = subscriptions(repo)
      assert length(before) == 50

      Migrations.up(repo, from: 10, version: 10)

      after_upgrade = subscriptions(repo)

      assert after_upgrade == before,
             "version 10 changed a subscription's plan id, status or period. It is additive " <>
               "and must not touch a commercial fact."

      # Every plan column is NULL: the DDL writes no data, and the assignment is
      # `AuroraMeter.Plans.register!/0`'s at the first boot after the upgrade.
      %{rows: [[unnamed]]} =
        repo.query!("SELECT count(*) FROM aurora_meter_subscriptions WHERE plan_version IS NULL")

      assert unnamed == 50
    end)
  end

  test "I19 version 10 run twice is a no-op" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)
      Migrations.up(repo, from: 10, version: 10)
      once = Migrations.catalogue(repo)

      Migrations.up(repo, from: 10, version: 10)
      twice = Migrations.catalogue(repo)

      assert (once -- twice) ++ (twice -- once) == [],
             "re-running version 10 changed the catalogue. Only after one run:\n  " <>
               Enum.join(once -- twice, "\n  ") <>
               "\nOnly after two:\n  " <> Enum.join(twice -- once, "\n  ")
    end)
  end

  test "I19 down of version 10 removes both tables and every column it added" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)
      at_nine = Migrations.catalogue(repo)

      Migrations.up(repo, from: 10, version: 10)
      Migrations.down(repo, version: 10, to: 10, confirm_data_loss: true)

      back = Migrations.catalogue(repo)

      assert (at_nine -- back) ++ (back -- at_nine) == [],
             "down of version 10 did not return the database to version 9. Only at 9:\n  " <>
               Enum.join(at_nine -- back, "\n  ") <>
               "\nOnly after down:\n  " <> Enum.join(back -- at_nine, "\n  ")
    end)
  end

  test "I19 version 10 is on the data-loss list, so its down needs confirm_data_loss" do
    assert 10 in Migration.data_loss_versions()

    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 10, concurrently: false)

      assert_raise Migration.DataLossError, fn ->
        Migrations.down(repo, version: 10, to: 10)
      end

      # And the plan snapshots are still there, which is the fact the guard is
      # protecting: it is the only record of what a retired version sold.
      assert table?(repo, "aurora_meter_plan_versions")
    end)
  end

  # -- X220, verified separately ----------------------------------------------

  test "X220 version 10 gives the flush receipt a clock_timestamp default" do
    Migrations.with_database(fn repo ->
      Migrations.up(repo, from: 1, version: 9, concurrently: false)
      assert column_default(repo, "aurora_meter_flush_receipts", "inserted_at") == nil

      Migrations.up(repo, from: 10, version: 10)

      default = column_default(repo, "aurora_meter_flush_receipts", "inserted_at")
      assert default =~ "clock_timestamp()"

      # A row inserted without the column is stamped by the database.
      id = Ecto.UUID.generate()

      repo.query!("INSERT INTO aurora_meter_flush_receipts (id) VALUES ($1)", [
        Ecto.UUID.dump!(id)
      ])

      %{rows: [[stamped]]} =
        repo.query!("SELECT inserted_at FROM aurora_meter_flush_receipts WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      assert stamped

      # And `down` takes the default with it, so the version is reversible in
      # both directions rather than leaving a stamp behind.
      Migrations.down(repo, version: 10, to: 10, confirm_data_loss: true)
      assert column_default(repo, "aurora_meter_flush_receipts", "inserted_at") == nil
    end)
  end

  # -- helpers ----------------------------------------------------------------

  defp insert_subscription!(repo, tenant_key, opts \\ []) do
    repo.query!(
      "INSERT INTO aurora_meter_subscriptions " <>
        "(tenant_key, plan_id, status, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, now(), now())",
      [tenant_key, Keyword.get(opts, :plan_id, "free"), Keyword.get(opts, :status, "active")]
    )
  end

  defp subscriptions(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT tenant_key, plan_id, status, inserted_at, updated_at " <>
          "FROM aurora_meter_subscriptions ORDER BY tenant_key"
      )

    rows
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

  defp constraint_names(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = to_regclass($1)::oid",
        [table]
      )

    List.flatten(rows) ++ index_names(repo, table)
  end

  defp index_names(repo, table) do
    %{rows: rows} =
      repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = $1", [table])

    List.flatten(rows)
  end

  defp index_predicate(repo, name) do
    %{rows: [[definition]]} =
      repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])

    definition
  end

  defp validated?(repo, name) do
    %{rows: [[validated]]} =
      repo.query!("SELECT convalidated FROM pg_constraint WHERE conname = $1", [name])

    validated
  end

  defp column_default(repo, table, column) do
    %{rows: [[default]]} =
      repo.query!(
        "SELECT column_default FROM information_schema.columns " <>
          "WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    default
  end

  defp marker_version(repo) do
    %{rows: [[version]]} =
      repo.query!(
        "SELECT (cursor ->> 'version')::int FROM aurora_meter_checkpoints " <>
          "WHERE name = 'schema:core'"
      )

    version
  end
end
