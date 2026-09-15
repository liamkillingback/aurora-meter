# Measures what `aurora_meter_flush_receipts` costs, and what a prune of it
# costs, so that `docs/retention.md` cites numbers rather than arithmetic.
#
#   DB_PORT=5490 MIX_ENV=test mix run priv/v1/receipt_sizing.exs
#
# Build unit 05d wrote it; build unit 11d's soak re-runs it and asserts the
# table stays bounded over twenty four hours. It is kept in the repository for
# that reason rather than because anything in the library calls it.
#
# It inserts a million synthetic receipts and then truncates the table, so it
# refuses to run against any database whose name does not contain "_test".

alias AuroraMeter.Config
alias AuroraMeter.Retention
alias AuroraMeter.TestRepo

repo = TestRepo
{:ok, _} = Application.ensure_all_started(:aurora_meter)
{:ok, _} = repo.start_link(pool_size: 4, queue_target: 5_000, queue_interval: 60_000)

database = Keyword.fetch!(repo.config(), :database)

unless String.contains?(database, "_test") do
  raise """
  receipt_sizing.exs inserts a million rows and then TRUNCATEs the table. The
  configured database is #{inspect(database)}, which is not a test database.
  Refusing.
  """
end

rows = String.to_integer(System.get_env("AURORA_RECEIPT_ROWS") || "1000000")
days = String.to_integer(System.get_env("AURORA_RECEIPT_DAYS") || "60")

query = fn sql, params -> repo.query!(sql, params, timeout: 600_000) end

IO.puts("database: #{database}")
IO.puts("rows: #{rows}, spread over #{days} days")
IO.puts("")

query.("TRUNCATE aurora_meter_flush_receipts", [])

{insert_us, _} =
  :timer.tc(fn ->
    query.(
      """
      INSERT INTO aurora_meter_flush_receipts (id, inserted_at)
      SELECT gen_random_uuid(),
             (clock_timestamp() AT TIME ZONE 'UTC') - make_interval(secs => (random() * $2)::int)
        FROM generate_series(1, $1)
      """,
      [rows, days * 86_400]
    )
  end)

IO.puts("insert: #{div(insert_us, 1_000)} ms")

%{rows: [[total, table, index, relation, bytes]]} =
  query.(
    """
    SELECT count(*),
           pg_size_pretty(pg_table_size('aurora_meter_flush_receipts')),
           pg_size_pretty(pg_indexes_size('aurora_meter_flush_receipts')),
           pg_size_pretty(pg_total_relation_size('aurora_meter_flush_receipts')),
           pg_total_relation_size('aurora_meter_flush_receipts')
      FROM aurora_meter_flush_receipts
    """,
    []
  )

per_row = bytes / total

# The **shipped** default, not this environment's: the test configuration sets
# a 60 s flush interval so the periodic timers never fire mid-suite, and a
# sizing number taken from that would be twelve times too small.
shipped_interval = Map.fetch!(Config.defaults(), :flush_interval)
per_node_per_day = div(86_400_000, shipped_interval)

IO.puts("count: #{total}")
IO.puts("table: #{table}   index: #{index}   total: #{relation}")
IO.puts("bytes per row: #{Float.round(per_row, 1)}")

IO.puts(
  "at the shipped #{shipped_interval} ms flush_interval " <>
    "(this environment is configured for #{Config.flush_interval()} ms): " <>
    "#{per_node_per_day} rows per node per day, " <>
    "#{Float.round(per_node_per_day * per_row / 1_048_576, 2)} MiB per node per day, " <>
    "#{Float.round(365 * per_node_per_day * per_row / 1_073_741_824, 2)} GiB per node per year"
)

IO.puts("")

# The receipt rule needs a live fleet, or prune/1 correctly refuses.
query.(
  """
  INSERT INTO aurora_meter_checkpoints (name, cursor, counts, state, updated_at)
  VALUES ('flush:sizing_node', jsonb_build_object('version', $1::text), '{}'::jsonb, 'idle',
          (clock_timestamp() AT TIME ZONE 'UTC'))
  ON CONFLICT (name) DO UPDATE SET updated_at = EXCLUDED.updated_at, state = 'idle'
  """,
  [Retention.package_version()]
)

entry = Enum.find(Retention.__allow__(), &(&1.key == :flush_receipts))

explain = fn label, {sql, params} ->
  %{rows: plan} = query.("EXPLAIN (ANALYZE, BUFFERS) " <> sql, params)

  IO.puts("== #{label} ==")
  Enum.each(plan, fn [line] -> IO.puts("  " <> line) end)
  IO.puts("")
end

{count_sql, count_params} = Retention.count_sql(entry, nil)
{delete_sql, delete_params} = Retention.delete_sql(entry, nil)

explain.("plan/1, the count", {count_sql, count_params})
explain.("prune/1, one batch of 1000", {delete_sql, delete_params ++ [1000]})

# And the public API over everything eligible, timed.
{prune_us, result} =
  :timer.tc(fn ->
    Retention.prune(only: [:flush_receipts], batch_size: 1_000, max_items: 2_000_000)
  end)

IO.puts("prune/1 over the eligible rows: #{div(prune_us, 1_000)} ms -> #{inspect(result)}")

%{rows: [[left]]} = query.("SELECT count(*) FROM aurora_meter_flush_receipts", [])
IO.puts("rows left (inside the 30 day window): #{left}")

query.("TRUNCATE aurora_meter_flush_receipts", [])
query.("DELETE FROM aurora_meter_checkpoints WHERE name = 'flush:sizing_node'", [])

Enum.each(Retention.tables(), fn table ->
  query.("DELETE FROM aurora_meter_checkpoints WHERE name = $1", [Retention.operation(table)])
end)

IO.puts("")
IO.puts("truncated.")
