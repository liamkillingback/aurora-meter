defmodule AuroraMeter.Exporter.JournalTest do
  @moduledoc """
  The reference exporter (build unit 04a).

  `async: false`, because the journal is a singleton under its own module name
  and a test that scripts an answer must be the only one reading that queue.
  """
  use ExUnit.Case, async: false

  alias AuroraMeter.Exporter
  alias AuroraMeter.Exporter.Journal

  setup do
    case Journal.start_link([]) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
        :ok

      {:error, {:already_started, _pid}} ->
        Journal.reset()
        :ok
    end
  end

  describe "answers" do
    test "journal returns the default outcome when nothing is scripted" do
      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", :accepted}]
    end

    test "journal consumes scripted outcomes in order and then falls back to the default" do
      :ok = Journal.script("ref-a", [{:retry, 30}, {:retry, nil}])

      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", {:retry, 30}}]
      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", {:retry, nil}}]
      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", :accepted}]
    end

    test "journal scripts per subject reference, not per item id" do
      :ok = Journal.script("ref-a", :uncertain)

      assert Journal.deliver([item("a", "ref-a"), item("b", "ref-b")], %{}) ==
               [{"a", :uncertain}, {"b", :accepted}]
    end

    test "journal answers in the caller's input order" do
      items = for index <- 1..5, do: item("row-#{index}", "ref-#{index}")
      results = Journal.deliver(items, %{})

      assert Enum.map(results, &elem(&1, 0)) == ["row-1", "row-2", "row-3", "row-4", "row-5"]
    end

    test "journal can be scripted with a term that is not an outcome at all" do
      :ok = Journal.script("ref-a", {:ok, %{"status" => "queued"}})
      [item] = [item("a", "ref-a")]

      # It comes back verbatim, and normalize/2 is what refuses to believe it.
      assert [{"a", {:ok, %{"status" => "queued"}}}] = raw = Journal.deliver([item], %{})
      assert {:ok, %{"a" => :uncertain}} = Exporter.normalize([item], raw)
    end

    test "journal raises only when a raise was scripted, and records the delivery first" do
      :ok = Journal.script("ref-a", {:raise, "provider exploded"})

      assert_raise RuntimeError, "provider exploded", fn ->
        Journal.deliver([item("a", "ref-a")], %{})
      end

      # The record survives the raise, which is exactly the real situation: the
      # request may have been sent before the client blew up.
      assert [%{outcome: {:raise, "provider exploded"}}] = Journal.deliveries_for("ref-a")
    end

    test "journal exits with :noproc when it is not running" do
      :ok = Agent.stop(Journal)

      assert catch_exit(Journal.deliver([item("a", "ref-a")], %{}))
    end
  end

  describe "the log" do
    test "journal records every delivery with the item, outcome, attempt and time" do
      item = item("a", "ref-a")
      _ = Journal.deliver([item], %{})

      assert [entry] = Journal.deliveries()
      assert entry.item == item
      assert entry.outcome == :accepted
      assert entry.attempt == 0
      assert %DateTime{time_zone: "Etc/UTC"} = entry.at
    end

    test "journal keeps deliveries in insertion order" do
      for index <- 1..3, do: Journal.deliver([item("row-#{index}", "ref-#{index}")], %{})

      assert Enum.map(Journal.deliveries(), & &1.item.id) == ["row-1", "row-2", "row-3"]
    end

    test "E5 an identical item redelivered carries an identical payload" do
      first = item("a", "ref-a")
      second = %{first | attempts: 1, first_attempt_at: ~U[2026-09-15 00:00:00.000000Z]}

      _ = Journal.deliver([first], %{})
      _ = Journal.deliver([second], %{})

      assert [one, two] = Journal.deliveries_for("ref-a")

      # Byte identical, not merely equal: this is the property an adapter breaks
      # by re-deriving a field from live state between attempts, and a retry that
      # sends different bytes under one idempotency key is a second charge.
      assert :erlang.term_to_binary(one.item.payload) ==
               :erlang.term_to_binary(two.item.payload)

      assert one.attempt == 0 and two.attempt == 1
    end

    test "E6 a repeated delivery of one identity returns an outcome rather than raising" do
      item = item("a", "ref-a")

      assert [{"a", :accepted}] = Journal.deliver([item], %{})
      assert [{"a", :accepted}] = Journal.deliver([item], %{})
      assert [{"a", :accepted}] = Journal.deliver([%{item | attempts: 2}], %{})

      # At-least-once means the journal records both, and deduplication is the
      # provider's job through `payload["identifier"]`, not the adapter's.
      assert length(Journal.deliveries_for("ref-a")) == 3
    end

    test "journal deliveries_for/1 selects by subject reference" do
      _ = Journal.deliver([item("a", "ref-a"), item("b", "ref-b")], %{})

      assert [%{item: %{id: "a"}}] = Journal.deliveries_for("ref-a")
      assert [%{item: %{id: "b"}}] = Journal.deliveries_for("ref-b")
      assert Journal.deliveries_for("ref-missing") == []
    end
  end

  describe "processes" do
    test "journal state is visible across processes" do
      # The direct regression for a process-dictionary fake: a scripted answer
      # set anywhere has to be visible everywhere, because the process that
      # calls deliver/2 in production is a worker, not the test.
      task = Task.async(fn -> Journal.script("ref-a", {:retry, 15}) end)
      assert :ok = Task.await(task)
      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", {:retry, 15}}]

      # And the reverse: the test scripts, another process delivers and sees it.
      :ok = Journal.script("ref-b", :uncertain)
      deliverer = Task.async(fn -> Journal.deliver([item("b", "ref-b")], %{}) end)
      assert Task.await(deliverer) == [{"b", :uncertain}]

      # And the delivery a foreign process recorded is readable here.
      assert [%{outcome: :uncertain}] = Journal.deliveries_for("ref-b")
    end

    test "journal records eight concurrent deliveries of disjoint items exactly once each" do
      items = for index <- 1..8, do: item("row-#{index}", "ref-#{index}")

      results =
        items
        |> Task.async_stream(fn item -> Journal.deliver([item], %{}) end, ordered: false)
        |> Enum.map(fn {:ok, [result]} -> result end)

      assert length(results) == 8

      recorded = Journal.deliveries()
      assert length(recorded) == 8

      assert recorded |> Enum.map(& &1.item.id) |> Enum.sort() ==
               Enum.sort(Enum.map(items, & &1.id))

      for item <- items do
        assert length(Journal.deliveries_for(item.subject_ref)) == 1
      end
    end
  end

  describe "describe/0 and reset/1" do
    test "journal describe returns the configured description and the default when not started" do
      assert Journal.describe() == Journal.default_description()

      :ok = Agent.stop(Journal)
      assert Journal.describe() == Journal.default_description()

      {:ok, pid} = Journal.start_link(describe: %{Journal.default_description() | max_batch: 7})
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      assert Journal.describe().max_batch == 7
    end

    test "E4 describe is a pure function of how the journal was started" do
      assert Journal.describe() == Journal.describe()
      assert Journal.describe().max_batch > 0
      assert Journal.describe().timestamp_window.past >= 0
      assert Journal.describe().timestamp_window.future >= 0
      assert Journal.describe().supports -- Exporter.subject_kinds() == []
    end

    test "journal reset empties the log and the scripted queue" do
      :ok = Journal.script("ref-a", {:retry, 30})
      _ = Journal.deliver([item("a", "ref-b")], %{})

      :ok = Journal.reset()

      assert Journal.deliveries() == []
      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", :accepted}]
    end

    test "journal default_outcome changes the answer for an unscripted reference" do
      :ok = Agent.stop(Journal)
      {:ok, pid} = Journal.start_link(default_outcome: :uncertain)
      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      assert Journal.deliver([item("a", "ref-a")], %{}) == [{"a", :uncertain}]
    end
  end

  defp item(id, subject_ref) do
    Exporter.item!(%{
      id: id,
      subject_kind: :event,
      subject_ref: subject_ref,
      tenant_key: "acme",
      payload: %{"identifier" => subject_ref, "quantity" => 3}
    })
  end
end
