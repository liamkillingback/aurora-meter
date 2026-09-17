defmodule AuroraMeter.RecordConcurrencyTest do
  @moduledoc """
  I06 and I07 under real contention: twelve independent, non-sandbox
  connections racing one identity, and a caller killed on either side of the
  commit (build unit 03b).

  Not `AuroraMeter.DataCase`. The sandbox wraps a test in one transaction on
  one connection, which serialises the very contention a unique index and a
  transaction boundary exist to survive: every assertion here would pass on
  code that has neither. Every task runs on its own connection through
  `AuroraMeter.Test.Connections`, and every assertion is made against the
  database afterwards rather than against a task's return value.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Storage
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.RecordingOutbox
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :fault

  @connections 12

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = AuroraMeter.Test.unique_tenant("recordconc")
    on_exit(fn -> Connections.cleanup!(tenant) end)

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    %{tenant: tenant, at: ~U[2026-09-10 12:00:00.000000Z]}
  end

  defp repo, do: Connections.repo()

  defp events(tenant) do
    repo().all(
      from(e in AuroraMeter.Schema.Event,
        where: e.tenant_key == ^tenant,
        order_by: [asc: e.seq],
        select: map(e, [:event_id, :quantity, :payload_hash, :seq])
      )
    )
  end

  defp totals(tenant) do
    repo().all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant,
        select: map(t, [:feature, :quantity, :events, :generation])
      )
    )
  end

  describe "one identity, twelve connections" do
    test "I06 12 independent connections submitting one identity create one fact, one totals delta and one outbox item",
         ctx do
      TestConfig.with_config([{:aurora_meter, :events_outbox, RecordingOutbox}], fn ->
        results =
          Connections.run(@connections, fn _i ->
            AuroraMeter.record(ctx.tenant, :ai_generations, 5,
              id: "one-identity",
              occurred_at: ctx.at
            )
          end)

        # Every task returned one of the three answers the contract allows, and
        # a conflict_unresolved is retryable into a definite one.
        for result <- results do
          assert match?({:ok, %Event{}, :inserted}, result) or
                   match?({:ok, %Event{}, :duplicate}, result) or
                   result == {:error, {:unavailable, :conflict_unresolved}},
                 "a task returned #{inspect(result)}"
        end

        unresolved = Enum.count(results, &(&1 == {:error, {:unavailable, :conflict_unresolved}}))

        # An unresolved answer is retryable with the same id into a definite
        # one, which is the whole reason it is allowed to exist.
        Enum.each(1..unresolved//1, fn _i ->
          assert {:ok, %Event{}, outcome} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 5,
                     id: "one-identity",
                     occurred_at: ctx.at
                   )

          assert outcome in [:inserted, :duplicate]
        end)

        assert Enum.count(results, &match?({:ok, _event, :inserted}, &1)) == 1

        assert [%{event_id: "one-identity", quantity: 5}] = events(ctx.tenant)
        assert [%{quantity: 5, events: 1, generation: 0}] = totals(ctx.tenant)
        assert length(RecordingOutbox.items()) == 1

        record_concurrency_evidence(%{
          test: "one identity, twelve connections",
          connections: @connections,
          outcomes: Enum.frequencies_by(results, &outcome/1),
          rows: length(events(ctx.tenant)),
          totals: totals(ctx.tenant),
          outbox_items: length(RecordingOutbox.items())
        })
      end)
    end

    test "I07 12 independent connections submitting one identity with two different payloads never produce two rows",
         ctx do
      results =
        Connections.run(@connections, fn i ->
          AuroraMeter.record(ctx.tenant, :ai_generations, if(rem(i, 2) == 0, do: 1, else: 2),
            id: "two-payloads",
            occurred_at: ctx.at
          )
        end)

      rows = events(ctx.tenant)
      assert length(rows) == 1
      [%{quantity: winner}] = rows

      for result <- results do
        assert match?({:ok, %Event{}, :inserted}, result) or
                 match?({:ok, %Event{}, :duplicate}, result) or
                 match?({:error, {:conflict, %Event{}}}, result) or
                 result == {:error, {:unavailable, :conflict_unresolved}} or
                 match?({:error, {:unavailable, {:postgres, _}}}, result),
               "a task returned #{inspect(result)}"
      end

      # Every task that saw the other payload was refused, never silently
      # accepted as a duplicate.
      for {:ok, %Event{quantity: q}, outcome} <- Enum.filter(results, &match?({:ok, _, _}, &1)) do
        assert q == winner, "a #{outcome} came back with a payload that is not the stored one"
      end

      assert [%{quantity: ^winner, events: 1}] = totals(ctx.tenant)

      record_concurrency_evidence(%{
        test: "two payloads, twelve connections",
        connections: @connections,
        outcomes: Enum.frequencies_by(results, &outcome/1),
        rows: length(rows),
        totals: totals(ctx.tenant)
      })
    end

    test "I06 concurrent distinct ids in one tenant and period produce one totals row with the exact sum",
         ctx do
      per_task = 200 |> div(@connections) |> max(1)
      total_events = per_task * @connections

      results =
        Connections.run(@connections, fn i ->
          for n <- 1..per_task do
            AuroraMeter.record(ctx.tenant, :ai_generations, 3,
              id: "t#{i}-#{n}",
              occurred_at: ctx.at
            )
          end
        end)

      assert Enum.all?(List.flatten(results), &match?({:ok, %Event{}, :inserted}, &1))

      assert length(events(ctx.tenant)) == total_events

      assert [%{quantity: quantity, events: count}] = totals(ctx.tenant)
      assert quantity == total_events * 3
      assert count == total_events

      record_concurrency_evidence(%{
        test: "distinct ids, twelve connections",
        connections: @connections,
        events_per_connection: per_task,
        rows: total_events,
        totals: totals(ctx.tenant)
      })
    end

    test "L-03b-3 two batches with the same two keys in opposite input order both commit", ctx do
      # Without sorting the entries before the statement, two concurrent batches
      # touching the same two totals rows acquire them in opposite orders and
      # deadlock inside insert_all. Each pass uses fresh event ids so that every
      # pass really inserts and therefore really upserts both totals rows.
      #
      # 11c: `:requests` is not declared on this tenant's plan, and 1.0 denies
      # an undeclared feature, so the batches stopped inserting at all when the
      # candidate version was cut. This test is about lock ordering, not about
      # entitlement, so it says which policy it means.
      TestConfig.with_config([{:aurora_meter, :undeclared_feature_policy, :allow}], fn ->
        for pass <- 1..10 do
          results =
            Connections.run(2, fn i ->
              elements =
                if i == 1 do
                  [
                    batch_element(ctx, "p#{pass}-a#{i}", :ai_generations),
                    batch_element(ctx, "p#{pass}-b#{i}", :requests)
                  ]
                else
                  [
                    batch_element(ctx, "p#{pass}-b#{i}", :requests),
                    batch_element(ctx, "p#{pass}-a#{i}", :ai_generations)
                  ]
                end

              AuroraMeter.record_batch(elements)
            end)

          for result <- results do
            assert {:ok, [_one, _two]} = result
          end
        end

        assert length(events(ctx.tenant)) == 40

        totals = Map.new(totals(ctx.tenant), &{&1.feature, &1.quantity})
        assert totals["ai_generations"] == 20
        assert totals["requests"] == 20
      end)
    end
  end

  describe "process death" do
    test "I06 killing the caller before commit leaves no row, no delta, no outbox item and no ETS delta",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :storage, FaultStorage},
          {:aurora_meter, :events_outbox, RecordingOutbox}
        ],
        fn ->
          {:killed, _pid} =
            Kill.run(
              fn ->
                Connections.checkout!()

                AuroraMeter.record(ctx.tenant, :ai_generations, 9,
                  id: "killed-before",
                  occurred_at: ctx.at
                )
              end,
              at: :before_commit,
              when: &(&1[:callback] == :record_events)
            )

          Kill.assert_db!(fn ->
            assert events(ctx.tenant) == []
            assert totals(ctx.tenant) == []
          end)

          assert RecordingOutbox.items() == []
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0
        end
      )
    end

    test "I06 killing the caller after commit before the reply leaves exactly one row, and the same-id retry returns duplicate without a second delta or outbox item",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :storage, FaultStorage},
          {:aurora_meter, :events_outbox, RecordingOutbox}
        ],
        fn ->
          {:killed, _pid} =
            Kill.run(
              fn ->
                Connections.checkout!()

                AuroraMeter.record(ctx.tenant, :ai_generations, 9,
                  id: "killed-after",
                  occurred_at: ctx.at
                )
              end,
              at: :after_commit_before_ack,
              when: &(&1[:callback] == :record_events)
            )

          Kill.assert_db!(fn ->
            assert [%{event_id: "killed-after", quantity: 9}] = events(ctx.tenant)
            assert [%{quantity: 9, events: 1}] = totals(ctx.tenant)
          end)

          assert length(RecordingOutbox.items()) == 1

          # I03: the caller died before the in-memory projection, so the
          # advisory view is low. This documents the lag rather than pretending
          # it does not exist.
          assert AuroraMeter.usage(ctx.tenant, :ai_generations) == 0

          # The retry is the recovery, and it is the same id.
          Connections.checkout!()

          assert {:ok, event, :duplicate} =
                   AuroraMeter.record(ctx.tenant, :ai_generations, 9,
                     id: "killed-after",
                     occurred_at: ctx.at
                   )

          assert event.quantity == 9

          Kill.assert_db!(fn ->
            assert length(events(ctx.tenant)) == 1
            assert [%{quantity: 9, events: 1}] = totals(ctx.tenant)
          end)

          assert length(RecordingOutbox.items()) == 1
        end
      )
    end
  end

  describe "generations" do
    test "I06 a record transaction in flight blocks generation activation and completes against the generation it read",
         ctx do
      # The record takes `FOR SHARE` on the `events_projection` checkpoint row
      # before it inserts; `activate_projection/1` takes `FOR UPDATE` on the
      # same row. Wrapping the record in a host transaction holds that shared
      # lock open, which is exactly "a record in flight", without needing a
      # fault point inside production code.
      parent = self()

      recorder =
        Task.async(fn ->
          Connections.checkout!()

          repo().transaction(fn ->
            result =
              AuroraMeter.record(ctx.tenant, :ai_generations, 4,
                id: "in-flight",
                occurred_at: ctx.at
              )

            send(parent, {:in_flight, self()})
            assert_receive :release, 15_000
            result
          end)
        end)

      assert_receive {:in_flight, holder}, 10_000

      activation =
        Task.async(fn ->
          Connections.checkout!()
          Storage.activate_projection(1)
        end)

      assert Task.yield(activation, 1_500) == nil,
             "activation did not wait for the record that was already in flight"

      send(holder, :release)

      assert {:ok, {:ok, %Event{durability: :conditional}, :inserted}} =
               Task.await(recorder, 15_000)

      assert Task.await(activation, 15_000) == :ok

      # The record completed against the generation it read, which was 0.
      assert [%{quantity: 4, events: 1, generation: 0}] = totals(ctx.tenant)

      # And a record that starts after activation reads the new one.
      assert {:ok, %Event{}, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 6,
                 id: "after-activation",
                 occurred_at: ctx.at
               )

      generations = totals(ctx.tenant) |> Enum.map(& &1.generation) |> Enum.sort()
      assert generations == [0, 1]

      on_exit(fn -> reset_projection_generation() end)
    end
  end

  describe "measured Postgres behaviour" do
    test "ON CONFLICT DO NOTHING waits for an uncommitted conflicting row on this Postgres",
         ctx do
      # docs/evidence/v1/phase-03/03b-conflict-wait.md: the conflict_unresolved
      # branch exists for "the insert was skipped and the row is not visible to
      # this transaction". This asserts the half of that which is a property of
      # the running server, so a Postgres upgrade that changed it would fail
      # here rather than silently change what a retry costs.
      parent = self()
      id = "waited-#{System.unique_integer([:positive])}"

      holder =
        spawn(fn ->
          Connections.checkout!()

          repo().transaction(fn ->
            AuroraMeter.record(ctx.tenant, :ai_generations, 1, id: id, occurred_at: ctx.at)
            send(parent, {:held, self()})
            receive do: (:release -> :ok), after: (15_000 -> :ok)
          end)

          send(parent, {:done, self()})
          Sandbox.checkin(repo())
        end)

      assert_receive {:held, ^holder}, 5_000

      second =
        Task.async(fn ->
          Connections.checkout!()

          AuroraMeter.record(ctx.tenant, :ai_generations, 2, id: id, occurred_at: ctx.at)
        end)

      assert Task.yield(second, 1_000) == nil, "the second writer did not wait for the first"

      send(holder, :release)
      assert_receive {:done, ^holder}, 10_000

      assert {:error, {:conflict, existing}} = Task.await(second, 15_000)
      assert existing.quantity == 1
      assert length(events(ctx.tenant)) == 1
    end

    test "the conflict_unresolved precondition is producible: a concurrent delete of the conflicting row",
         ctx do
      # This reproduces, statement for statement, what
      # `AuroraMeter.Storage.Ecto.record_events/2` issues, and asserts that
      # Postgres can leave it in the state the branch exists for. The branch
      # itself cannot be driven end to end without a fault point inside
      # production code, which this unit deliberately does not add; the facade
      # contract for the answer is asserted in AuroraMeter.RecordTest.
      parent = self()
      id = "vanishing-#{System.unique_integer([:positive])}"

      assert {:ok, _event, :inserted} =
               AuroraMeter.record(ctx.tenant, :ai_generations, 1, id: id, occurred_at: ctx.at)

      deleter =
        spawn(fn ->
          Connections.checkout!()

          receive do
            :go ->
              repo().query!(
                "DELETE FROM aurora_meter_events WHERE tenant_key = $1 AND event_id = $2",
                [ctx.tenant, id]
              )

              send(parent, :deleted)
          end

          Sandbox.checkin(repo())
        end)

      state =
        repo().transaction(fn ->
          repo().query!(
            "SELECT cursor FROM aurora_meter_checkpoints WHERE name = $1 FOR SHARE",
            ["events_projection"]
          )

          {count, returned} =
            repo().insert_all(
              AuroraMeter.Schema.Event,
              [conflicting_row(ctx.tenant, id, ctx.at)],
              on_conflict: :nothing,
              conflict_target: [:tenant_key, :event_id],
              returning: [:id, :tenant_key, :event_id, :payload_hash]
            )

          send(deleter, :go)
          assert_receive :deleted, 10_000

          read_back =
            repo().query!(
              "SELECT quantity FROM aurora_meter_events WHERE tenant_key = $1 AND event_id = $2",
              [ctx.tenant, id]
            ).rows

          {count, length(returned), read_back}
        end)

      assert {:ok, {0, 0, []}} = state
    end
  end

  # The `events_projection` checkpoint row is global, so the one test that
  # activates a generation puts it back and **asserts** that it did
  # (`open-findings.md` X97: a restore that is not verified is not a restore).
  defp reset_projection_generation do
    Connections.checkout!()

    repo().query!(
      """
      UPDATE aurora_meter_checkpoints
         SET cursor = jsonb_build_object('active_generation', 0),
             state = 'active',
             updated_at = (clock_timestamp() AT TIME ZONE 'UTC')
       WHERE name = 'events_projection'
      """,
      []
    )

    %{rows: [[cursor]]} =
      repo().query!(
        "SELECT cursor FROM aurora_meter_checkpoints WHERE name = 'events_projection'",
        []
      )

    assert cursor == %{"active_generation" => 0},
           "the projection generation was not restored: #{inspect(cursor)}"

    :ok
  end

  defp conflicting_row(tenant, id, at) do
    %{
      tenant_key: tenant,
      event_id: id,
      feature: "ai_generations",
      quantity: 99,
      kind: "usage",
      original_event_id: nil,
      occurred_at: at,
      inserted_at: DateTime.utc_now(),
      period_start: ~U[2026-09-01 00:00:00Z],
      period_source: "test",
      attribution: "resolved",
      dimensions: %{},
      metadata: %{},
      payload_hash: :crypto.hash(:sha256, id)
    }
  end

  defp batch_element(ctx, id, feature) do
    %{tenant: ctx.tenant, feature: feature, quantity: 1, id: id, occurred_at: ctx.at}
  end

  defp outcome({:ok, _event, outcome}), do: outcome
  defp outcome({:error, {tag, detail}}) when is_atom(detail), do: {tag, detail}
  defp outcome({:error, {tag, _detail}}), do: tag

  # One JSON line per concurrency test into AURORA_CONCURRENCY_REPORT, for
  # docs/evidence/v1/phase-03/03b-concurrency.json. A no-op when the variable is
  # unset, so the suite is unchanged outside the evidence run.
  defp record_concurrency_evidence(report) do
    case System.get_env("AURORA_CONCURRENCY_REPORT") do
      path when is_binary(path) and path != "" ->
        File.mkdir_p!(Path.dirname(path))

        line =
          report
          |> Map.put(:seed, System.get_env("AURORA_SEED") || "unset")
          |> Map.put(:at, DateTime.to_iso8601(DateTime.utc_now()))
          |> Jason.encode!()

        File.write!(path, line <> "\n", [:append])

      _unset ->
        :ok
    end
  end
end
