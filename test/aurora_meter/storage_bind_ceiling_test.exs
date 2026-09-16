defmodule AuroraMeter.StorageBindCeilingTest do
  @moduledoc """
  **X338**: a flush bigger than one Postgres statement can carry.

  Postgres puts a statement's bind-parameter count in a 16-bit field, so one
  statement takes at most 65,535 of them, and `insert_all/3` spends one per
  column per row. `AuroraMeter.Storage.Ecto.add_counters/1` used to build one
  statement over a whole flush batch at seven parameters per counter row, so a
  batch of more than `floor(65535 / 7) = 9,362` distinct counter keys could not
  be **sent**: Postgrex refused to encode it and the query never reached the
  database. `AuroraMeter.Flusher.failed/2` then retained the batch for an
  idempotent retry, which is right for a transient failure and exactly wrong for
  this one, so the node buffered for ever with no way to write. Build unit 08c
  bisected it to the key against the real database
  (`docs/evidence/v1/phase-08/08c-flush-limit.md`); repair unit R4 fixed it.

  Every test here uses `AuroraMeter.Storage.Ecto.rows_per_statement/1` rather
  than the number 9,362, for the same reason the adapter derives it: a column
  added to `AuroraMeter.Schema.Counter` in a later version lowers the real
  ceiling, and a test written against a literal would go on passing at a row
  count that no longer means anything.

  The first test is the one that matters. It proves, against the real database
  in this run, that `rows_per_statement/1` is the **actual** boundary and not an
  estimate: exactly that many rows in one statement is accepted, one more cannot
  be sent at all. If Postgres or Postgrex ever moved the limit, or a column were
  added without the derivation following it, that test fails rather than the
  ceiling coming back silently as a stuck flusher in production.
  """

  # async: false: these tests write several tens of thousands of counter rows,
  # and the sandbox owner is shared so that the derivation probe below can raise
  # inside it without stranding an async owner.
  use AuroraMeter.DataCase, async: false

  import AuroraMeter.Test.Config, only: [with_config: 2]

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Storage
  alias AuroraMeter.Storage.Ecto, as: EctoStorage

  # `rows_per_statement/1`'s `## Examples` block prints 9,362 for the counter
  # schema, and nothing else in either suite runs the doctests of this internal
  # module, so without this line that number would be a claim nobody checks. It
  # is the canary for the whole derivation: widen `AuroraMeter.Schema.Counter`
  # and this fails, which is the moment somebody should be looking.
  doctest AuroraMeter.Storage.Ecto, only: [rows_per_statement: 1]

  @period ~U[2026-07-01 00:00:00Z]
  @date ~D[2026-07-01]

  # A repo that records the calls and writes nothing, used by "the shape of the
  # write" below. It is deliberately not the fault harness: the question there
  # is the shape of the calls the adapter makes, and the fault harness answers a
  # different one (what happens when a call fails). Defined before the tests so
  # that the alias exists when they are compiled.
  defmodule RecordingRepo do
    @moduledoc false

    def transaction(fun) do
      log({:transaction, 0})
      {:ok, fun.()}
    end

    def insert_all(_schema, entries, _opts \\ []) do
      log({:statement, length(entries)})
      {length(entries), []}
    end

    defp log(entry) do
      Process.put(:bind_ceiling_log, [entry | Process.get(:bind_ceiling_log, [])])
    end
  end

  describe "the derivation" do
    test "X338 rows_per_statement/1 is the real ceiling, proved against this database" do
      limit = EctoStorage.rows_per_statement(Counter)

      assert limit > 1,
             "a chunk of #{limit} rows would make every flush a row-at-a-time loop, which is " <>
               "not a fix, and a limit of 0 would make Enum.chunk_every/2 raise."

      # Exactly the derived limit, in ONE statement, through the repo rather
      # than through the adapter: this is the boundary itself and not the
      # chunking that respects it.
      assert {^limit, nil} = TestRepo.insert_all(Counter, counter_entries("ceil_at", limit))

      # And one row more cannot be sent. `send_one_statement/1` returns the
      # message rather than letting it escape, because a test that asserted on
      # an exception struct would pass for the wrong exception.
      assert {:error, message} = send_one_statement(limit + 1)

      assert message =~ "parameters",
             "one statement of #{limit + 1} counter rows failed for a reason other than the " <>
               "bind-parameter ceiling: #{message}. Either the ceiling moved or this probe is " <>
               "measuring something else, and in both cases the derived chunk size is no " <>
               "longer known to be safe."

      assert message =~ "65535"
    end

    test "X338 the derivation falls when a schema is wider, rather than being written down" do
      # `AuroraMeter.Schema.History` carries one more column than
      # `AuroraMeter.Schema.Counter` (`bucket_kind`), so its ceiling is strictly
      # lower. Nothing in the adapter says either number.
      assert length(History.__schema__(:fields)) == length(Counter.__schema__(:fields)) + 1

      assert EctoStorage.rows_per_statement(History) <
               EctoStorage.rows_per_statement(Counter),
             "the two schemas are different widths and the derived ceilings are the same, " <>
               "which means the ceiling is not being derived from the schema at all."
    end
  end

  describe "the flush" do
    @tag timeout: 300_000
    test "X338 a flush of one more counter key than a statement can carry is written" do
      limit = EctoStorage.rows_per_statement(Counter)
      prefix = unique_tenant("ceil")
      counters = counter_deltas(prefix, limit + 1, 3)

      assert {:ok, %{counters: totals}} =
               Storage.flush_batch(Ecto.UUID.generate(), counters, [])

      assert length(totals) == limit + 1
      assert Enum.all?(totals, &(&1.value == 3))
      assert counter_sum(prefix) == (limit + 1) * 3
    end

    @tag timeout: 300_000
    test "X338 a flush spanning several statements still counts once when it is retried" do
      # This is the part chunking could have broken and did not. The receipt and
      # every chunk are in one transaction, so a retry of the same batch id
      # finds the receipt already there, applies no delta and answers the
      # current totals. A chunked write that committed per statement would add
      # the whole batch a second time here.
      limit = EctoStorage.rows_per_statement(Counter)
      prefix = unique_tenant("ceilonce")
      counters = counter_deltas(prefix, limit + 1, 2)
      id = Ecto.UUID.generate()

      assert {:ok, %{counters: first}} = Storage.flush_batch(id, counters, [])
      assert counter_sum(prefix) == (limit + 1) * 2

      assert {:ok, %{counters: again}} = Storage.flush_batch(id, counters, [])

      assert counter_sum(prefix) == (limit + 1) * 2,
             "the retried batch was applied a second time. Chunking must not cost the " <>
               "flusher its idempotent retry: a stuck flusher is a bad day and a double " <>
               "count is a wrong invoice."

      assert length(again) == length(first)
      assert Enum.all?(again, &(&1.value == 2))
    end

    @tag timeout: 300_000
    test "X338 history chunks on its own width, in the same flush" do
      limit = EctoStorage.rows_per_statement(History)
      prefix = unique_tenant("ceilhist")

      history =
        for n <- 1..(limit + 1),
            do: %{tenant_key: "#{prefix}_#{n}", feature: :ops, date: @date, delta: 4}

      assert {:ok, %{history: totals}} =
               Storage.flush_batch(Ecto.UUID.generate(), [], history)

      assert length(totals) == limit + 1
      assert Enum.all?(totals, &(&1.value == 4))
      assert history_sum(prefix) == (limit + 1) * 4
    end

    @tag timeout: 300_000
    test "X338 add_counters/1 above the ceiling writes every row and sums them" do
      limit = EctoStorage.rows_per_statement(Counter)
      prefix = unique_tenant("ceiladd")
      deltas = counter_deltas(prefix, limit + 1, 1)

      assert {:ok, totals} = Storage.add_counters(deltas)
      assert length(totals) == limit + 1
      assert counter_sum(prefix) == limit + 1

      # A delta add is not idempotent and is not meant to be: the receipt in
      # `flush_batch/3` is what makes a flush safe to retry, and the test above
      # is the one that proves it. Calling it twice adds twice, across chunks
      # exactly as it did in one statement.
      assert {:ok, _} = Storage.add_counters(deltas)
      assert counter_sum(prefix) == (limit + 1) * 2
    end
  end

  describe "the shape of the write" do
    # The database tests above prove the rows land. They cannot show HOW,
    # because a chunked write and a single statement leave the same rows behind.
    # This one reads the shape directly through a repo that records instead of
    # writing: how many statements, how wide each was, and whether a call that
    # needs more than one of them opened a transaction to hold them.
    #
    # The transaction is the part that would otherwise be reasoning rather than
    # evidence. Inside `flush_batch/3` it is redundant, because the receipt and
    # both delta sets are already in one. Outside it, `add_counters/1` is a
    # public storage callback whose caller has always been able to assume "all
    # of these deltas or none", and chunking is what would have taken that away.
    setup do
      Process.put(:bind_ceiling_log, [])
      :ok
    end

    test "X338 one chunk is one statement and no transaction of its own" do
      limit = EctoStorage.rows_per_statement(Counter)

      with_config([{:aurora_meter, :repo, RecordingRepo}], fn ->
        assert {:ok, []} = EctoStorage.add_counters(counter_deltas("rec", limit, 1))
      end)

      assert statements() == [limit]
      assert transactions() == 0
    end

    test "X338 more than one chunk is several statements inside one transaction" do
      limit = EctoStorage.rows_per_statement(Counter)

      with_config([{:aurora_meter, :repo, RecordingRepo}], fn ->
        assert {:ok, []} = EctoStorage.add_counters(counter_deltas("rec", limit * 2 + 1, 1))
      end)

      assert statements() == [limit, limit, 1],
             "a batch of #{limit * 2 + 1} rows went out as #{inspect(statements())} rows per " <>
               "statement. Every statement must be at or under #{limit}, and the split must " <>
               "not lose or duplicate a row."

      assert Enum.sum(statements()) == limit * 2 + 1

      assert transactions() == 1,
             "the chunked write opened #{transactions()} transactions. A multi-statement " <>
               "add_counters/1 must be all-or-nothing, or a caller that retries a half-" <>
               "applied call double counts the half that landed."
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp counter_deltas(prefix, count, delta) do
    for n <- 1..count,
        do: %{tenant_key: "#{prefix}_#{n}", feature: :ops, period_start: @period, delta: delta}
  end

  defp counter_entries(prefix, count) do
    now = DateTime.utc_now()

    for n <- 1..count do
      %{
        tenant_key: "#{prefix}_#{System.unique_integer([:positive])}_#{n}",
        feature: "ops",
        period_start: @period,
        value: 1,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # One statement, deliberately unchunked, so that the ceiling itself is what
  # answers. The rescue catches whatever Postgrex raises rather than naming an
  # exception module: the thing under test is the message, and an assertion on
  # a struct would quietly pass for a different failure.
  defp send_one_statement(count) do
    {rows, nil} = TestRepo.insert_all(Counter, counter_entries("ceil_over", count))
    {:ok, rows}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp statements do
    :bind_ceiling_log
    |> Process.get([])
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:statement, rows} -> [rows]
      {:transaction, _} -> []
    end)
  end

  defp transactions do
    :bind_ceiling_log
    |> Process.get([])
    |> Enum.count(&match?({:transaction, _}, &1))
  end

  # One aggregate rather than a read per key: at ten thousand rows a
  # row-at-a-time check would cost more than the thing it checks.
  defp counter_sum(prefix) do
    %{rows: [[value]]} =
      TestRepo.query!(
        "SELECT coalesce(sum(value), 0) FROM aurora_meter_counters WHERE tenant_key LIKE $1",
        [prefix <> "%"]
      )

    to_integer(value)
  end

  defp history_sum(prefix) do
    %{rows: [[value]]} =
      TestRepo.query!(
        "SELECT coalesce(sum(value), 0) FROM aurora_meter_history WHERE tenant_key LIKE $1",
        [prefix <> "%"]
      )

    to_integer(value)
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
end
