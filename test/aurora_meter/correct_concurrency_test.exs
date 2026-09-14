defmodule AuroraMeter.CorrectConcurrencyTest do
  @moduledoc """
  **I09 under real contention** (build unit 03e): twelve independent,
  non-sandbox connections correcting one original at the same moment, and a
  corrector killed on either side of the commit.

  Not `AuroraMeter.DataCase`, and the reason is the whole point of the file.
  The sandbox wraps a test in one transaction on one connection, which
  serialises the very contention `SELECT ... FOR UPDATE` exists to survive:
  every assertion here would pass on an implementation with no lock at all, and
  "cumulative corrections cannot exceed the original" is a statement about money.
  Every task runs on its own connection through `AuroraMeter.Test.Connections`,
  and every assertion is made against the database afterwards rather than
  against a task's return value.

  The lock is a row lock and not a lease, a deadline or a comparison of two
  timestamps. `open-findings.md` X100 measured the one clock every node shares
  stepping backwards 439 ms on a 32.5 second cadence on this hardware; a lock
  Postgres grants and COMMIT releases consults no clock at all.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Test.Config, as: TestConfig
  alias AuroraMeter.Test.Connections
  alias AuroraMeter.Test.FaultStorage
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.RecordingOutbox
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :fault

  @connections 12

  @events_source [{:aurora_meter, :feature_sources, %{ai_generations: :events}}]

  setup do
    AuroraMeter.Test.reset!()
    :ok = RecordingOutbox.start!()
    tenant = AuroraMeter.Test.unique_tenant("corrconc")
    on_exit(fn -> Connections.cleanup!(tenant) end)

    own = Connections.checkout!()
    on_exit(fn -> if own, do: Sandbox.checkin(Connections.repo()) end)

    %{tenant: tenant, at: ~U[2026-09-10 12:00:00.000000Z]}
  end

  defp repo, do: Connections.repo()

  defp record(ctx, id, quantity) do
    AuroraMeter.record(ctx.tenant, :ai_generations, quantity, id: id, occurred_at: ctx.at)
  end

  defp events(tenant) do
    repo().all(
      from(e in AuroraMeter.Schema.Event,
        where: e.tenant_key == ^tenant,
        order_by: [asc: e.seq],
        select: map(e, [:event_id, :quantity, :kind, :original_event_id, :seq])
      )
    )
  end

  defp corrections(tenant), do: Enum.filter(events(tenant), &(&1.kind == "correction"))

  defp totals(tenant) do
    repo().all(
      from(t in EventTotal,
        where: t.tenant_key == ^tenant,
        select: map(t, [:feature, :quantity, :events, :generation])
      )
    )
  end

  defp correction_items do
    Enum.filter(RecordingOutbox.items(), &(&1.event.kind == :correction))
  end

  describe "twelve correctors of one original" do
    test "I09 12 concurrent partial corrections of one 10-unit original never exceed it", ctx do
      TestConfig.with_config(
        [{:aurora_meter, :events_outbox, RecordingOutbox} | @events_source],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          RecordingOutbox.reset!()

          {results, log} =
            with_log(fn ->
              Connections.run(@connections, fn i ->
                AuroraMeter.correct(ctx.tenant, "base", 1, id: "fix-#{i}")
              end)
            end)

          # Every task got one of the two answers the contract allows here.
          for result <- results do
            assert match?({:ok, %Event{}, :inserted}, result) or
                     result == {:error, {:invalid, [quantity: :exceeds_original]}},
                   "a task returned #{inspect(result)}"
          end

          inserted = Enum.count(results, &match?({:ok, _event, :inserted}, &1))

          refused =
            Enum.count(results, &(&1 == {:error, {:invalid, [quantity: :exceeds_original]}}))

          assert inserted == 10
          assert refused == 2

          # The two refusals came from the BOUND and not from 03a's totals check
          # constraint. Without this the test cannot tell the two apart: the
          # constraint is a real backstop that produces the same numbers and the
          # same error tuple, and it masked a missing `FOR UPDATE` completely
          # (recorded in `docs/evidence/v1/phase-03/03e-step-order.md`).
          refute log =~ "aurora_meter_event_totals_quantity_check",
                 "the bound was bypassed and the check constraint caught it instead"

          assert length(corrections(ctx.tenant)) == 10
          assert [%{quantity: 0, events: 11, generation: 0}] = totals(ctx.tenant)
          assert length(correction_items()) == 10

          bound_evidence(%{
            test: "12 concurrent partial corrections of one 10-unit original",
            connections: @connections,
            original_quantity: 10,
            magnitude_each: 1,
            outcomes: Enum.frequencies_by(results, &outcome/1),
            inserted: inserted,
            exceeds_original: refused,
            correction_rows: length(corrections(ctx.tenant)),
            totals: totals(ctx.tenant),
            outbox_correction_items: length(correction_items())
          })
        end
      )
    end

    test "I09 12 concurrent submissions of one correction identity produce one row, one delta and one outbox item",
         ctx do
      TestConfig.with_config(
        [{:aurora_meter, :events_outbox, RecordingOutbox} | @events_source],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          RecordingOutbox.reset!()

          # Ten of ten, so that a corrector whose pre-lock duplicate check
          # missed the winner arrives at the bound with NO headroom left. Without
          # the second duplicate check under the lock, those correctors are told
          # `exceeds_original` for a correction that is their own.
          results =
            Connections.run(@connections, fn _i ->
              AuroraMeter.correct(ctx.tenant, "base", 10, id: "one-identity")
            end)

          for result <- results do
            assert match?({:ok, %Event{}, :inserted}, result) or
                     match?({:ok, %Event{}, :duplicate}, result),
                   "a task returned #{inspect(result)}"
          end

          assert Enum.count(results, &match?({:ok, _event, :inserted}, &1)) == 1

          assert [%{event_id: "one-identity", quantity: 10}] = corrections(ctx.tenant)
          assert [%{quantity: 0, events: 2, generation: 0}] = totals(ctx.tenant)
          assert length(correction_items()) == 1

          bound_evidence(%{
            test: "12 concurrent submissions of one correction identity",
            connections: @connections,
            original_quantity: 10,
            magnitude_each: 10,
            outcomes: Enum.frequencies_by(results, &outcome/1),
            correction_rows: length(corrections(ctx.tenant)),
            totals: totals(ctx.tenant),
            outbox_correction_items: length(correction_items())
          })
        end
      )
    end

    test "I09 concurrent corrections of two different originals in one key both commit", ctx do
      TestConfig.with_config(@events_source, fn ->
        assert {:ok, _a, :inserted} = record(ctx, "base-a", 10)
        assert {:ok, _b, :inserted} = record(ctx, "base-b", 10)

        results =
          Connections.run(2, fn i ->
            original = if i == 1, do: "base-a", else: "base-b"
            AuroraMeter.correct(ctx.tenant, original, 4, id: "fix-#{original}")
          end)

        assert Enum.all?(results, &match?({:ok, %Event{}, :inserted}, &1))
        assert length(corrections(ctx.tenant)) == 2
        assert [%{quantity: 12, events: 4}] = totals(ctx.tenant)
      end)
    end

    test "I09 the lock that serialises correctors is the one on the original row", ctx do
      TestConfig.with_config(@events_source, fn ->
        assert {:ok, _a, :inserted} = record(ctx, "base-a", 10)
        assert {:ok, _b, :inserted} = record(ctx, "base-b", 10)

        parent = self()

        # `FOR UPDATE` on ONE original row and nothing else: the statement
        # `lock_original/1` issues, held open with no totals row and no
        # checkpoint row involved. Holding a whole `correct/4` open instead
        # would also hold the totals row for the key, which every corrector of
        # that key needs whichever original it corrects, and the test would then
        # prove nothing about which lock discriminates (recorded as a defect in
        # the build document's own version of this test).
        holder =
          spawn(fn ->
            Connections.checkout!()

            repo().transaction(fn ->
              repo().query!(
                """
                SELECT event_id FROM aurora_meter_events
                 WHERE tenant_key = $1 AND event_id = $2 FOR UPDATE
                """,
                [ctx.tenant, "base-a"]
              )

              send(parent, {:holding, self()})
              receive do: (:release -> :ok), after: (15_000 -> :ok)
            end)

            send(parent, {:released, self()})
            Sandbox.checkin(repo())
          end)

        assert_receive {:holding, ^holder}, 10_000

        # A corrector of the OTHER original is not blocked by it.
        elsewhere =
          Task.async(fn ->
            Connections.checkout!()
            AuroraMeter.correct(ctx.tenant, "base-b", 4, id: "elsewhere")
          end)

        assert {:ok, %Event{}, :inserted} = Task.await(elsewhere, 10_000)

        # A corrector of the SAME original is.
        same =
          Task.async(fn ->
            Connections.checkout!()
            AuroraMeter.correct(ctx.tenant, "base-a", 9, id: "same")
          end)

        assert Task.yield(same, 1_500) == nil,
               "a corrector of the locked original did not wait for the lock"

        send(holder, :release)
        assert_receive {:released, ^holder}, 10_000

        assert {:ok, %Event{quantity: 9}, :inserted} = Task.await(same, 15_000)
        assert length(corrections(ctx.tenant)) == 2
      end)
    end
  end

  describe "process death" do
    test "I06 killing a corrector before commit leaves no row, no delta and no outbox item",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :storage, FaultStorage},
          {:aurora_meter, :events_outbox, RecordingOutbox}
          | @events_source
        ],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          RecordingOutbox.reset!()

          {:killed, _pid} =
            Kill.run(
              fn ->
                Connections.checkout!()
                AuroraMeter.correct(ctx.tenant, "base", 4, id: "killed-before")
              end,
              at: :before_commit,
              when: &(&1[:callback] == :record_correction)
            )

          Kill.assert_db!(fn ->
            assert corrections(ctx.tenant) == []
            assert [%{quantity: 10, events: 1}] = totals(ctx.tenant)
          end)

          assert correction_items() == []
        end
      )
    end

    test "I06 killing a corrector after commit before the reply leaves exactly one of each and the retry is a duplicate",
         ctx do
      TestConfig.with_config(
        [
          {:aurora_meter, :storage, FaultStorage},
          {:aurora_meter, :events_outbox, RecordingOutbox}
          | @events_source
        ],
        fn ->
          assert {:ok, _event, :inserted} = record(ctx, "base", 10)
          RecordingOutbox.reset!()

          {:killed, _pid} =
            Kill.run(
              fn ->
                Connections.checkout!()
                AuroraMeter.correct(ctx.tenant, "base", 4, id: "killed-after")
              end,
              at: :after_commit_before_ack,
              when: &(&1[:callback] == :record_correction)
            )

          Kill.assert_db!(fn ->
            assert [%{event_id: "killed-after", quantity: 4}] = corrections(ctx.tenant)
            assert [%{quantity: 6, events: 2}] = totals(ctx.tenant)
          end)

          assert length(correction_items()) == 1

          # The retry is the recovery, and it is the same id.
          Connections.checkout!()

          assert {:ok, %Event{quantity: 4}, :duplicate} =
                   AuroraMeter.correct(ctx.tenant, "base", 4, id: "killed-after")

          Kill.assert_db!(fn ->
            assert length(corrections(ctx.tenant)) == 1
            assert [%{quantity: 6, events: 2}] = totals(ctx.tenant)
          end)

          assert length(correction_items()) == 1
        end
      )
    end
  end

  # A string, not a tuple: these become the keys of a JSON object in the
  # evidence file, and a tuple key is an encoding error in the last line of the
  # test, after every assertion has already passed.
  defp outcome({:ok, _event, outcome}), do: to_string(outcome)
  defp outcome({:error, {:invalid, [{field, reason}]}}), do: "#{field}:#{reason}"
  defp outcome({:error, {tag, detail}}) when is_atom(detail), do: "#{tag}:#{detail}"
  defp outcome({:error, {tag, _detail}}), do: to_string(tag)

  # One JSON line per bound test into AURORA_BOUND_REPORT, for
  # docs/evidence/v1/phase-03/03e-bound.json. A no-op when the variable is
  # unset, so the suite is unchanged outside the evidence run.
  defp bound_evidence(report) do
    case System.get_env("AURORA_BOUND_REPORT") do
      path when is_binary(path) and path != "" ->
        File.mkdir_p!(Path.dirname(path))

        line =
          report
          |> Map.put(:seed, System.get_env("AURORA_SEED") || "unset")
          |> Map.put(:at, AuroraMeter.Clock.now() |> DateTime.to_iso8601())
          |> Jason.encode!()

        File.write!(path, line <> "\n", [:append])

      _unset ->
        :ok
    end
  end
end
