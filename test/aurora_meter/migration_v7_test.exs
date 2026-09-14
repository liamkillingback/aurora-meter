defmodule AuroraMeter.MigrationV7Test do
  @moduledoc """
  Core schema version 7, run for real against a disposable database.

  Version 7 is additive: an 0.4.x node keeps writing events through it, which
  is the whole reason the V1 upgrade does not need the fleet drained. That
  claim is only worth something if it is exercised against rows that were
  really committed before the migration ran, so these tests do not use the
  sandbox (see `AuroraMeter.Test.Migrations`).
  """
  use ExUnit.Case, async: false

  @moduletag :migration

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Events.Backfill
  alias AuroraMeter.Test.Migrations

  describe "the ladder" do
    test "I19 a fresh install and an incremental upgrade produce the same catalogue" do
      fresh =
        Migrations.with_database(fn repo ->
          Migrations.up(repo, from: 1, version: 8, concurrently: false)
          Migrations.catalogue(repo)
        end)

      upgraded =
        Migrations.with_database(fn repo ->
          Migrations.up(repo, from: 1, version: 6)
          Migrations.up(repo, from: 7, version: 7)
          Migrations.up(repo, from: 8, version: 8, concurrently: false)
          Migrations.catalogue(repo)
        end)

      assert (fresh -- upgraded) ++ (upgraded -- fresh) == [],
             "a database built in one step and one built version by version must be the " <>
               "same database. Only in fresh:\n  " <>
               Enum.join(fresh -- upgraded, "\n  ") <>
               "\nOnly in upgraded:\n  " <> Enum.join(upgraded -- fresh, "\n  ")
    end

    test "I19 each published schema history reaches 7 and then 8" do
      # core 1 is core 0.1.0, core 2 is core 0.2.0 to 0.3.2, core 6 is core
      # 0.4.0. No customer is at 3, 4 or 5 (schema-migration-map.md section 1),
      # but the ladder is run from each of those too, because a version that
      # only works from the one starting point its author had is not a version.
      for start <- [1, 2, 3, 4, 5, 6] do
        Migrations.with_database(fn repo ->
          Migrations.up(repo, from: 1, version: start)
          Migrations.up(repo, from: start + 1, version: 6)
          Migrations.up(repo, from: 7, version: 7)

          columns = Migrations.columns(repo)
          assert Map.has_key?(columns, "event_id"), "core #{start}: version 7 added no event_id"

          assert Checkpoints.get("schema:core", repo: repo).cursor["version"] == 7,
                 "core #{start}: the schema marker did not reach 7"

          Migrations.up(repo, from: 8, version: 8, concurrently: false)

          assert Checkpoints.get("schema:core", repo: repo).cursor["version"] == 8,
                 "core #{start}: the schema marker did not reach 8"
        end)
      end
    end

    test "I19 the schema marker is absent below version 7" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)

        assert Checkpoints.get("schema:core", repo: repo) == nil,
               "there is no checkpoints table below version 7, so the absence of the marker " <>
                 "is what tells 11a the database is pre-V7"
      end)
    end
  end

  describe "version 7 against rows written by 0.4.x" do
    test "legacy rows survive it unchanged, with a null event_id" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.seed_legacy_events(repo, 3, tenant: "legacy_a", quantity: 7)

        before = rows(repo)

        Migrations.up(repo, from: 7, version: 7)

        after_rows = rows(repo)
        assert length(after_rows) == 3
        assert before == after_rows

        %{rows: event_ids} =
          repo.query!("SELECT event_id FROM aurora_meter_events", [])

        assert event_ids == [[nil], [nil], [nil]],
               "version 7 gives no row an identity; the backfill does"
      end)
    end

    test "C13 a quantity above the int4 maximum inserts and reads back exactly" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        Migrations.seed_legacy_events(repo, 1, tenant: "big_one", quantity: 2_147_483_648)

        %{rows: [[quantity]]} =
          repo.query!("SELECT quantity FROM aurora_meter_events WHERE tenant_key = 'big_one'", [])

        assert quantity == 2_147_483_648
      end)
    end

    test "the check constraints it adds reject a new bad row while leaving history alone" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)

        # A row that a 0.4.x `track/4` accepted and the V1 contract does not.
        # `track/4` never validated quantity, so a real customer database can
        # hold this, and a constraint added VALID would refuse to migrate it.
        Migrations.seed_legacy_events(repo, 1, tenant: "legacy_neg", quantity: -5)

        Migrations.up(repo, from: 7, version: 7)

        assert [%{quantity: -5}] = rows(repo),
               "the historical row must survive the migration untouched"

        for {overrides, constraint} <- [
              {%{"kind" => "'nonsense'"}, "aurora_meter_events_kind_check"},
              {%{"original_event_id" => "'x'"}, "aurora_meter_events_correction_pairing_check"},
              {%{"event_id" => "repeat('x', 129)"}, "aurora_meter_events_event_id_length_check"},
              {%{"dimensions" => "'[]'::jsonb"}, "aurora_meter_events_dimensions_object_check"}
            ] do
          error = assert_raise(Postgrex.Error, fn -> insert!(repo, overrides) end)

          assert error.postgres.constraint == constraint,
                 "expected #{constraint}, got #{inspect(error.postgres.constraint)}"
        end
      end)
    end

    # The defect this guards against was found while building this unit. A
    # NOT VALID constraint is enforced on UPDATE as well as on INSERT, so a
    # `quantity > 0` constraint in version 7 would make the backfill unable to
    # give an identity to precisely the rows it exists for, and the V1 upgrade
    # would have been impossible on any database holding one. The two
    # constraints legacy rows can violate therefore arrive in version 8, after
    # the backfill.
    test "it does not add a constraint that legacy history can violate" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 6)
        Migrations.seed_legacy_events(repo, 1, tenant: "legacy_neg", quantity: -5)

        Migrations.seed_legacy_events(repo, 1,
          tenant: "legacy_fat",
          metadata: %{"blob" => String.duplicate("x", 20_000)}
        )

        Migrations.up(repo, from: 7, version: 7)

        for constraint <- [
              "aurora_meter_events_quantity_check",
              "aurora_meter_events_metadata_size_check"
            ] do
          refute constraint in constraints(repo),
                 "#{constraint} in version 7 would block the backfill's own UPDATE of the " <>
                   "rows it exists to fill"
        end

        {:ok, counts} = Backfill.run(repo: repo)

        assert counts["updated"] == 2
        assert counts["nonpositive_quantity"] == 1
        assert counts["oversized_metadata"] == 1
      end)
    end

    test "L-03a-2 seq is assigned in insertion order" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        for index <- 1..3 do
          Migrations.seed_legacy_events(repo, 1, tenant: "seq_#{index}")
        end

        %{rows: rows} =
          repo.query!("SELECT tenant_key, seq FROM aurora_meter_events ORDER BY seq", [])

        assert Enum.map(rows, &hd/1) == ["seq_1", "seq_2", "seq_3"]
        seqs = Enum.map(rows, &List.last/1)
        assert seqs == Enum.sort(seqs)
        assert length(Enum.uniq(seqs)) == 3
      end)
    end

    test "seq cannot be supplied by a writer" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        assert_raise Postgrex.Error, ~r/identity column/, fn ->
          insert!(repo, %{"seq" => "999"})
        end
      end)
    end

    test "it seeds the events_projection checkpoint row" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)

        checkpoint = Checkpoints.get("events_projection", repo: repo)

        assert checkpoint.cursor == %{"active_generation" => 0}
        assert checkpoint.state == "active"
      end)
    end

    test "running it twice changes nothing and rewrites nothing" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        first = Migrations.catalogue(repo)

        Migrations.up(repo, from: 7, version: 7)

        assert Migrations.catalogue(repo) == first
      end)
    end
  end

  describe "compatibility with Pro 0.3.0" do
    # A copy of the query in aurora_meter_pro's `AuroraMeter.Pro.Rollup`,
    # function `day_rollups_from_events/1`, which is the only read of this
    # table outside core and the only thing the "additive" claim can break.
    # Cited by symbol rather than by line, per open-findings.md X67.
    test "Pro's event rollup still resolves against a version 7 database" do
      Migrations.with_database(fn repo ->
        Migrations.up(repo, from: 1, version: 7)
        Migrations.seed_legacy_events(repo, 4, tenant: "pro_rollup", quantity: 3)

        %{rows: rows} =
          repo.query!(
            """
            SELECT e.inserted_at::date AS day, sum(e.quantity)
            FROM aurora_meter_events AS e
            WHERE e.tenant_key = $1 AND e.feature = $2 AND e.inserted_at >= $3
            GROUP BY e.inserted_at::date
            ORDER BY day
            """,
            ["pro_rollup", "ops", ~N[2020-01-01 00:00:00.000000]]
          )

        assert [[_day, total]] = rows
        assert Decimal.to_integer(total) == 12
      end)
    end
  end

  # Only the columns that existed in 0.4.x, so the same read works on both
  # sides of the migration and "unchanged" means unchanged.
  defp rows(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, tenant_key, feature, quantity, metadata, inserted_at " <>
          "FROM aurora_meter_events ORDER BY inserted_at",
        []
      )

    Enum.map(rows, fn [id, tenant_key, feature, quantity, metadata, inserted_at] ->
      %{
        id: id,
        tenant_key: tenant_key,
        feature: feature,
        quantity: quantity,
        metadata: metadata,
        inserted_at: inserted_at
      }
    end)
  end

  defp constraints(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT conname FROM pg_constraint " <>
          "WHERE conrelid = to_regclass('aurora_meter_events')::oid AND contype = 'c'",
        []
      )

    Enum.map(rows, &hd/1)
  end

  @base %{
    "tenant_key" => "'guard'",
    "feature" => "'ops'",
    "quantity" => "1",
    "metadata" => "'{}'::jsonb",
    "inserted_at" => "now()"
  }

  # One insert with named overrides, so a case that overrides a base column
  # replaces it instead of naming it twice.
  defp insert!(repo, overrides) do
    values = Map.merge(@base, overrides)
    columns = values |> Map.keys() |> Enum.sort()

    repo.query!(
      "INSERT INTO aurora_meter_events (id, #{Enum.join(columns, ", ")}) " <>
        "VALUES (gen_random_uuid(), " <>
        Enum.map_join(columns, ", ", &Map.fetch!(values, &1)) <> ")",
      []
    )
  end
end
