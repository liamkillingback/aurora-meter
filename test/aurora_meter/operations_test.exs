defmodule AuroraMeter.OperationsTest do
  @moduledoc """
  `AuroraMeter.Operations`: the name shape, the four things a checkpoint write
  must and must not clobber, and the batch loop's three lower-level invariants
  (L05c-1 to L05c-3).

  Sandboxed. Nothing here is a race; the race proofs for the workers that use
  this loop are in `oban_job_controls_test.exs`, which runs on real connections.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Operations

  setup do
    name = "credit_expiry:" <> unique_scope()
    on_exit(fn -> :ok end)
    {:ok, name: name}
  end

  defp unique_scope, do: "t#{System.unique_integer([:positive])}"

  describe "names" do
    test "an invalid checkpoint name raises ArgumentError" do
      for bad <- [
            # no scope at all: the two rows core writes without one are
            # deliberately unreachable from here.
            "events_projection",
            "events_backfill",
            # a scope but no operation
            ":global",
            # upper case in the operation half
            "CreditExpiry:global",
            # a space
            "credit expiry:global",
            # empty
            ""
          ] do
        assert_raise ArgumentError, ~r/is not an Aurora Meter operation name/, fn ->
          Operations.paused?(bad)
        end
      end
    end

    test "a name that is not a string raises ArgumentError naming the type" do
      assert_raise ArgumentError, ~r/is a string, got: :credit_expiry/, fn ->
        Operations.paused?(:credit_expiry)
      end
    end

    test "every shape the scope vocabulary uses is accepted" do
      for good <- [
            "credit_expiry:global",
            "rollup:month",
            "events_replay:7",
            "lot_migration:org_42",
            "outbox_reconciler:confirm",
            "retention:aurora_meter_flush_receipts",
            "lot_migration:acct-1.2"
          ] do
        assert Operations.paused?(good) == false
      end
    end

    test "every function validates, not just the read ones" do
      for call <- [
            fn -> Operations.pause("nope") end,
            fn -> Operations.resume("nope") end,
            fn -> Operations.paused?("nope") end,
            fn -> Operations.checkpoint("nope") end,
            fn -> Operations.put_checkpoint("nope", cursor: %{}) end,
            fn -> Operations.clear_checkpoint("nope") end,
            fn -> Operations.run_batches("nope", [], fn _ -> {:ok, %{cursor: nil}} end) end
          ] do
        assert_raise ArgumentError, call
      end
    end
  end

  describe "pause and resume" do
    test "pause/1 then paused?/1 is true; resume/1 then false", %{name: name} do
      refute Operations.paused?(name)

      assert :ok = Operations.pause(name)
      assert Operations.paused?(name)

      assert :ok = Operations.resume(name)
      refute Operations.paused?(name)
    end

    test "pause/1 works before the operation has ever run", %{name: name} do
      assert Operations.checkpoint(name) == nil
      assert :ok = Operations.pause(name)
      assert %{state: "paused", cursor: %{}} = Operations.checkpoint(name)
    end

    test ~s(resume/1 writes "idle", not "active"), %{name: name} do
      # The build document says `"active"`. It is wrong, and following it would
      # have collided with the `"events_projection"` row, whose `"active"` means
      # "this is the live generation" and which is not a task at all. 03a
      # shipped `"idle"` and this is the value every reader in the package
      # already understands.
      Operations.pause(name)
      Operations.resume(name)

      assert %{state: "idle"} = Operations.checkpoint(name)
    end
  end

  describe "what a write must not clobber" do
    test "pause/1 does not clear an existing cursor and put_checkpoint/2 does not clear a pause",
         %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "abc"}, counts: %{"examined" => 7})

      :ok = Operations.pause(name)

      assert %{cursor: %{"id" => "abc"}, counts: %{"examined" => 7}, state: "paused"} =
               Operations.checkpoint(name)

      # The batch that was in flight when the operator paused writes its cursor
      # afterwards. It must not resume the operation it knows nothing about.
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "def"}, counts: %{"examined" => 9})

      assert %{cursor: %{"id" => "def"}, counts: %{"examined" => 9}, state: "paused"} =
               Operations.checkpoint(name)

      assert Operations.paused?(name)
    end

    test "put_checkpoint/2 writes only the fields it is given", %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "abc"}, counts: %{"examined" => 7})

      :ok = Operations.put_checkpoint(name, counts: %{"examined" => 8})
      assert %{cursor: %{"id" => "abc"}, counts: %{"examined" => 8}} = Operations.checkpoint(name)

      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "xyz"})
      assert %{cursor: %{"id" => "xyz"}, counts: %{"examined" => 8}} = Operations.checkpoint(name)
    end

    test "a nil cursor is a value and not an omission", %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "abc"})
      :ok = Operations.put_checkpoint(name, cursor: nil)

      # Stored as `{}`, because core V7 declares the column NOT NULL, and read
      # back as "no position". The map documents the column as nullable and the
      # shipped table is not; see `Checkpoints.put_progress/4`.
      assert %{cursor: %{}} = Operations.checkpoint(name)
      assert Operations.checkpoint(name).cursor == %{}
    end

    test "put_checkpoint/2 with neither field raises", %{name: name} do
      assert_raise ArgumentError, ~r/needs :cursor or :counts/, fn ->
        Operations.put_checkpoint(name, [])
      end
    end
  end

  describe "checkpoint/1 and clear_checkpoint/1" do
    test "checkpoint/1 returns nil for a name that was never written", %{name: name} do
      assert Operations.checkpoint(name) == nil
    end

    test "clear_checkpoint/1 removes the row, pause and all", %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "abc"})
      :ok = Operations.pause(name)

      assert :ok = Operations.clear_checkpoint(name)

      assert Operations.checkpoint(name) == nil
      # The documented edge, asserted rather than only written down: clearing a
      # checkpoint resumes a paused operation, which is why the workers clear
      # their cursor with `put_checkpoint(name, cursor: nil)` instead.
      refute Operations.paused?(name)
    end

    test "list/0 includes rows that are not operations", %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"id" => "abc"})
      Checkpoints.put("events_backfill", %{}, %{}, "idle")

      names = Operations.list() |> Enum.map(& &1.name)

      assert name in names
      assert "events_backfill" in names
    end
  end

  describe "run_batches/3" do
    test "L05c-1 the cursor comes from the row and never from the caller", %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"at" => 3})

      seen = collect(fn -> Operations.run_batches(name, [], batches([nil])) end)

      # The first batch was handed the persisted cursor, not `nil`: a second job
      # for the same operation resumes where the first got to.
      assert seen == [%{"at" => 3}]
    end

    test "L05c-2 a run that starts while paused does no work at all", %{name: name} do
      :ok = Operations.pause(name)

      seen =
        collect(fn ->
          assert {:paused, report} = Operations.run_batches(name, [], batches([nil]))
          report
        end)

      assert seen == []
    end

    test "L05c-2 the pause is read before every batch, not only the first", %{name: name} do
      # Batch 2 pauses the operation from inside itself, standing in for an
      # operator who paused while the run was in flight. Batch 3 must not run.
      fun = fn cursor ->
        n = step(cursor)
        if n == 2, do: Operations.pause(name)
        {:ok, %{cursor: %{"n" => n + 1}, counts: %{"examined" => 1}}}
      end

      assert {:paused, report} = Operations.run_batches(name, [max_batches: 10], fun)

      assert report.stopped == :paused
      assert report.batches == 2
      assert report.counts == %{"examined" => 2}

      # The cursor is where the last committed batch left it, and it survived
      # the pause.
      assert %{cursor: %{"n" => 3}, state: "paused"} = Operations.checkpoint(name)
    end

    test "a completed scan clears the cursor and keeps the counts and the state", %{name: name} do
      :ok = Operations.pause(name)
      :ok = Operations.resume(name)

      assert {:ok, report} =
               Operations.run_batches(name, [], batches([%{"n" => 1}, %{"n" => 2}, nil]))

      assert report.stopped == :complete
      assert report.batches == 3

      assert %{cursor: %{}, counts: %{"examined" => 3}, state: "idle"} =
               Operations.checkpoint(name)

      assert Operations.checkpoint(name).cursor == %{}

      # And the next run starts from the beginning rather than from a stale
      # position, which is what an empty cursor means.
      assert {:ok, %{batches: 1}} = Operations.run_batches(name, [], batches([nil]))
    end

    test "the run stops at its batch budget with the cursor in place", %{name: name} do
      fun = fn cursor ->
        {:ok, %{cursor: %{"n" => step(cursor) + 1}, counts: %{"examined" => 1}}}
      end

      assert {:ok, report} = Operations.run_batches(name, [max_batches: 3], fun)

      assert report.stopped == :max_batches
      assert report.batches == 3
      assert %{cursor: %{"n" => 4}} = Operations.checkpoint(name)

      # And the next run continues from there rather than starting again.
      assert {:ok, %{batches: 2}} = Operations.run_batches(name, [max_batches: 2], fun)
      assert %{cursor: %{"n" => 6}} = Operations.checkpoint(name)
    end

    test "L05c-3 a batch-mechanism failure ends the run and leaves the cursor where it was",
         %{name: name} do
      :ok = Operations.put_checkpoint(name, cursor: %{"n" => 5})

      assert {:error, :listing_failed} =
               Operations.run_batches(name, [], fn _cursor -> {:error, :listing_failed} end)

      assert %{cursor: %{"n" => 5}} = Operations.checkpoint(name)
    end

    test "counts accumulate across batches and merge numerically", %{name: name} do
      fun = fn cursor ->
        n = step(cursor)
        cursor = if n >= 3, do: nil, else: %{"n" => n + 1}
        {:ok, %{cursor: cursor, counts: %{"examined" => 10, "failed" => 1}}}
      end

      assert {:ok, report} = Operations.run_batches(name, [], fun)
      assert report.counts == %{"examined" => 30, "failed" => 3}
    end

    test "each batch emits [:aurora_meter, :operations, :batch]", %{name: name} do
      handler = "ops-batch-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:aurora_meter, :operations, :batch],
        fn _event, measurements, metadata, _ ->
          send(parent, {:batch, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _} = Operations.run_batches(name, [], batches([%{"n" => 1}, nil]))

      assert_received {:batch, %{items: 1, duration_ms: first}, %{name: ^name, result: :ok}}
      assert_received {:batch, %{items: 1, duration_ms: _}, %{name: ^name, result: :ok}}

      # An in-memory span, so it is measured with the monotonic clock and can
      # never be negative. `AuroraMeter.Clock`'s other three readings can be.
      assert first >= 0

      assert {:error, :boom} = Operations.run_batches(name, [], fn _ -> {:error, :boom} end)
      assert_received {:batch, %{items: 0}, %{name: ^name, result: :error}}
    end
  end

  # -- helpers -----------------------------------------------------------------

  # A callback that walks the given cursors in order, one per batch.
  defp batches(cursors) do
    {:ok, agent} = Agent.start_link(fn -> cursors end)

    fn cursor ->
      send(self(), {:seen, cursor})

      next = Agent.get_and_update(agent, fn [head | rest] -> {head, rest} end)
      {:ok, %{cursor: next, counts: %{"examined" => 1}}}
    end
  end

  defp collect(fun) do
    fun.()
    drain([])
  end

  defp drain(acc) do
    receive do
      {:seen, cursor} -> drain([cursor | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp step(nil), do: 1
  defp step(%{"n" => n}), do: n
end
