defmodule AuroraMeter.Retention do
  @moduledoc """
  Deletes the operational rows that are genuinely disposable, and nothing else.

  Aurora Meter keeps financial history for ever. Events, event totals, the
  credit ledger, subscriptions and the cursors every sweep resumes from are
  never deleted by anything in this package, at any age, under any option. What
  grows without bound and is genuinely disposable is a much shorter list, and
  this module is that list plus the proof that each entry is safe to remove.

      AuroraMeter.Retention.plan([])
      #=> {:ok, %{flush_receipts: 4_182_000, replay_checkpoints: 3}}

      AuroraMeter.Retention.prune([])
      #=> {:ok, %{flush_receipts: 50_000, replay_checkpoints: 3}}

  `plan/1` is a dry run: it runs the prune's own predicate with `count(*)`
  instead of a `DELETE` and writes nothing at all.

  ## The allow list is closed, and it is compile time

  | Table | Age | State | Window |
  |---|---|---|---|
  | `aurora_meter_flush_receipts` | `inserted_at` | every node's flush heartbeat proves no node holds an older batch | `flush_receipt_retention`, 30 days |
  | `aurora_meter_checkpoints` (only `"events_replay:<generation>"` rows) | `updated_at` | `activated` or `abandoned`, and not a generation the live projection names | `replay_checkpoint_retention`, 365 days |

  There is no option, no configuration key and no argument that adds a table to
  it. `:only` narrows the list; it can never widen it, which is why it is named
  `:only` rather than `:tables`. A name that is not an allow-list key raises
  `ArgumentError` and the message lists the two that are.

  **Age alone never authorises a deletion.** Every entry has an age predicate
  *and* a state predicate, because "this row is old" and "this row can no longer
  affect anything" are different statements and only the second is a reason to
  delete.

  ## Why a flush receipt is the dangerous one

  `AuroraMeter.Storage.Ecto.flush_batch/3` inserts the batch's receipt with
  `on_conflict: :nothing` and applies the counter deltas only when that insert
  reported one new row. That single `inserted == 1` is the whole of invariant
  I01. Delete a receipt while a node still holds the batch in ETS, let that node
  retry, and the deltas are added a second time: a double count of real usage,
  in money.

  So a receipt is deleted only when age and a **cluster-wide liveness proof**
  agree. Every node's `AuroraMeter.Flusher` writes a `"flush:<node>"` row into
  `aurora_meter_checkpoints`: `"idle"` after a batch commits, `"pending"` with
  the batch's `snapshot_at` after one fails, and `"idle"` on a throttled tick
  when there is nothing to send. `prune/1` refuses to touch receipts unless
  every one of those rows says either "idle, and I said so after the cutoff" or
  "pending, with a batch taken after the cutoff".

  Three refusals are deliberately stricter than "check the rows that are there":

    * **no rows at all** refuses, when there is a receipt older than the cutoff.
      A fleet that has not yet been upgraded writes no heartbeats, and "nobody
      is reporting" is not evidence that nobody is holding a batch.
    * **a missing `aurora_meter_checkpoints` table** refuses, for the same
      reason: it is a database below core schema version 7 and it has receipts.
    * **an unparseable `pending_since`** refuses rather than being ignored.

  A node that is genuinely gone is cleared with `forget_node/1`, deliberately
  and one node at a time. That is the only override, and it overrides the rule
  for one node rather than removing the rule.

  ## Clocks, and the bound this module relies on

  `AuroraMeter.Checkpoints`' documentation says the heartbeat is not a lease and
  that **nothing in this package subtracts it from anything**, because
  `open-findings.md` X100 measured `clock_timestamp()` stepping backwards nine
  times in 300 seconds, worst 439 ms. This module does subtract it from
  something, so the distinction has to be exact rather than implied.

  That rule is about **exclusion at seconds scale**: deciding that a runner is
  gone so that its work may be taken. No N a person would pick survives a
  439 ms step there, and the sound mechanism has no clock in it at all
  (`AuroraMeter.Checkpoints.claim/3`).

  This decision is a different one. The smallest window it will act on is
  **one day**, refused below that at boot (`AuroraMeter.Config`), which is about
  200,000 times the measured backwards step of the shared clock and about 30,000
  times the worst measured step of a node's own (2.6472 s, X59). For the answer
  to flip, a row would have to sit within a few seconds of a cutoff a day or
  more wide, and the row that then loses its protection is one whose node was
  reporting idle at almost exactly the cutoff instant, so the batch it could
  retry is itself within seconds of the cutoff. The durations rule in
  `architecture-map.md` section 3 says exactly this: unsafe at seconds, safe at
  minutes and hours. A day is neither of the cases it warns about.

  One of the three stamps is the database's own: `aurora_meter_checkpoints`'
  `updated_at` is written with `clock_timestamp()` in the statement, so the
  staleness half of the receipt rule compares two readings of one clock and the
  439 ms figure is the whole of its error.

  The other two are a node's wall clock, and they are named rather than glossed.
  `aurora_meter_flush_receipts.inserted_at` is stamped by the node that flushed
  (`AuroraMeter.Storage.Ecto.flush_batch/3`, which says why it is not the
  database's), and the heartbeat's `pending_since` is when a node took a batch
  out of its own ETS, which has no database in it by design and must not
  acquire one on the flush path. For either of those to produce a wrong answer,
  a node's clock would have to disagree with the database's by more than the
  **whole window**, which at the one day floor is 288 times the largest
  disagreement anything else in this system tolerates: `events_future_tolerance`
  refuses an event 300 seconds ahead, and Stripe's webhook signature window is
  the same 300 seconds. A fleet whose clocks are a day apart has already stopped
  being able to record events or accept webhooks. That is the bound, and it is
  stated rather than assumed.

  ## Sizing, and what to do before the first prune

  A node under continuous traffic writes one receipt per `flush_interval`, which
  at the 5,000 ms default is 17,280 rows per node per day. See
  [Retention](retention.md) for the measured table and index sizes, the archive
  guidance, and the order to do an upgrade in: deploy, let every node write a
  heartbeat, confirm them with `status/0`, and only then schedule the worker.

  ## Running it

  `AuroraMeter.Oban.Retention` is the optional worker. Nothing runs without a
  host scheduling it, and a host that schedules nothing keeps every row for
  ever, which is what task 03.09 means by "retained indefinitely".
  """

  require Logger

  alias AuroraMeter.Checkpoints
  alias AuroraMeter.Config
  alias AuroraMeter.Operations

  @typedoc "An allow-list key. The map may gain keys in a later release."
  @type table :: :flush_receipts | :replay_checkpoints

  @typedoc "Rows counted (`plan/1`) or deleted (`prune/1`), per allow-list key."
  @type report :: %{optional(table()) => non_neg_integer()}

  @typedoc "Why one table was not pruned."
  @type reason :: %{table: table(), reason: atom(), detail: map()}

  @typedoc "One node's flush heartbeat, as `status/0` reports it."
  @type heartbeat :: %{
          node: String.t(),
          state: String.t(),
          updated_at: DateTime.t(),
          pending_since: DateTime.t() | nil,
          batch_id: String.t() | nil,
          version: String.t() | nil,
          blocks: boolean(),
          why: atom()
        }

  @heartbeat_prefix "flush:"

  @default_batch_size 1_000
  @default_max_items 50_000

  # The checkpoint rows every node's Flusher writes. Not an
  # `AuroraMeter.Operations` name, and that is forced rather than chosen: an
  # operation name must match `~r/^[a-z_]+:[A-Za-z0-9_.:-]+$/`, and the default
  # node id `"nonode@nohost"` contains an `@`, so `"flush:nonode@nohost"` is not
  # a legal operation name. It is also not an operation: nothing pauses it,
  # nothing resumes it and it keeps no scan position. It is a report, in the
  # same class as `"events_projection"`, so it goes through
  # `AuroraMeter.Checkpoints`, which is the table's own module.
  @doc false
  @spec heartbeat_name(String.t()) :: String.t()
  def heartbeat_name(node_id), do: @heartbeat_prefix <> node_id

  # -- the allow list ---------------------------------------------------------

  # `predicate` is written **once** per entry and is textually shared by the
  # count and the delete (see `count_sql/2` and `delete_sql/2`), so `plan/1`
  # cannot promise to remove something `prune/1` would keep, or the reverse.
  # `AuroraMeter.RetentionTest` asserts the sharing structurally as well as
  # behaviourally, because a comment is not a mechanism.
  #
  # `bound` is a materialised CTE holding the cutoff, so the clock is read once
  # per statement, inside the statement, by the database.
  @allow [
    %{
      key: :flush_receipts,
      table: "aurora_meter_flush_receipts",
      id: "id",
      order: "inserted_at",
      window: :flush_receipt_retention,
      with: [],
      predicate: "inserted_at < (SELECT cutoff FROM bound)"
    },
    %{
      key: :replay_checkpoints,
      table: "aurora_meter_checkpoints",
      id: "name",
      order: "updated_at",
      window: :replay_checkpoint_retention,
      # The generations the live projection row names, in any role. A replay
      # checkpoint is the provenance of a projection generation, so the one
      # belonging to the generation currently serving reads is not disposable at
      # any age, and neither is a build in flight or the seed it copied.
      with: [
        {"live_generations",
         """
         SELECT 'events_replay:' || value AS name
           FROM aurora_meter_checkpoints p,
                LATERAL (VALUES (p.cursor->>'active_generation'),
                                (p.cursor->>'building_generation'),
                                (p.cursor->>'previous_generation'),
                                (p.cursor->>'seed_generation')) AS v(value)
          WHERE p.name = 'events_projection' AND value IS NOT NULL
         """}
      ],
      predicate: """
      name LIKE 'events_replay:%'
        AND state IN ('activated', 'abandoned')
        AND updated_at < (SELECT cutoff FROM bound)
        AND name NOT IN (SELECT name FROM live_generations)
      """
    }
  ]

  # Every table this package's migrations create that `prune/1` must never
  # delete a row from. `AuroraMeter.RetentionTest` derives the set of tables the
  # migrations actually create and fails unless every one appears in exactly one
  # of the two lists, in both directions, so a table added by a later unit
  # cannot be left unclassified and a name listed here that no migration creates
  # cannot rot (`open-findings.md` X206).
  #
  # `aurora_meter_checkpoints` is on **both** lists and is the only table that
  # is: the allow list reaches exactly the finished replay rows, and every other
  # row in it is a live cursor or a pause an operator set.
  @protected [
    "aurora_meter_checkpoints",
    "aurora_meter_counters",
    "aurora_meter_credit_allocations",
    "aurora_meter_credit_balances",
    "aurora_meter_credit_lots",
    "aurora_meter_credit_recurrences",
    "aurora_meter_credit_transactions",
    "aurora_meter_event_totals",
    "aurora_meter_events",
    "aurora_meter_history",
    # A plan version snapshot is what makes a subscription or an event that
    # names a retired version readable at all, and there is one row per plan
    # version rather than one per tenant or per period: it does not grow, and
    # pruning one would turn a customer's contract into an unreadable string.
    # A transition row is the audit trail of a commercial change.
    "aurora_meter_plan_transitions",
    "aurora_meter_plan_versions",
    "aurora_meter_subscriptions"
  ]

  @doc """
  The allow-list keys, in the order `plan/1` and `prune/1` process them.

  ## Examples

      iex> AuroraMeter.Retention.tables()
      [:flush_receipts, :replay_checkpoints]

  """
  @spec tables() :: [table()]
  def tables, do: Enum.map(@allow, & &1.key)

  @doc """
  The tables `prune/1` must never delete a row from.

  ## Examples

      iex> "aurora_meter_events" in AuroraMeter.Retention.protected()
      true

  """
  @spec protected() :: [String.t()]
  def protected, do: @protected

  @doc false
  # The allow list itself, for the tests that check it against the migrations
  # and check the two statements share one predicate.
  @spec __allow__() :: [map()]
  def __allow__, do: @allow

  # -- plan and prune ---------------------------------------------------------

  @doc """
  Counts what `prune/1` would delete, and writes nothing.

  Returns `{:ok, report}`, or `{:blocked, report, reasons}` when at least one
  requested table could not be pruned. Being blocked is a normal outcome an
  operator should see, not a failure a job should retry, so it is not an error
  tuple. `report` still carries the counts for the tables that are prunable.

  Options:

    * `:only` - allow-list keys to consider (default: all of them). Narrows;
      never widens.
    * `:older_than` - a `DateTime` cutoff overriding every configured window,
      for an operator running a one-off. Still subject to every state predicate
      and to the receipt rule.

  ## Examples

      {:ok, report} = AuroraMeter.Retention.plan([])
      Map.keys(report)
      #=> [:flush_receipts, :replay_checkpoints]

  """
  @spec plan(keyword()) :: {:ok, report()} | {:blocked, report(), [reason()]}
  def plan(opts \\ []) when is_list(opts) do
    run(opts, :plan)
  end

  @doc """
  Deletes what `plan/1` counted, in bounded batches, and returns how many rows
  went per table.

  Returns `{:ok, report}` or `{:blocked, report, reasons}` on the same terms as
  `plan/1`. A table that an operator has paused
  (`AuroraMeter.Operations.pause("retention:flush_receipts")`) contributes a
  `:paused` reason and whatever the batches before the pause removed.

  Options: `:only` and `:older_than` as for `plan/1`, plus

    * `:batch_size` (default #{@default_batch_size}) - rows per `DELETE`.
    * `:max_items` (default #{@default_max_items}) - rows one call removes per
      table before returning with work still waiting. The next run continues.

  Every batch is one autocommitted statement. Nothing here takes a lock of its
  own, opens a transaction or runs inside one.

  ## Examples

      {:ok, report} = AuroraMeter.Retention.prune(only: [:replay_checkpoints])
      is_integer(report.replay_checkpoints)
      #=> true

  """
  @spec prune(keyword()) :: {:ok, report()} | {:blocked, report(), [reason()]}
  def prune(opts \\ []) when is_list(opts) do
    run(opts, :prune)
  end

  @doc """
  Every node's flush heartbeat, whether it blocks a receipt prune, and why.

  This is what an operator reads before scheduling retention for the first time:
  one row per node, each carrying the package version that node is running.

  Returns `%{cutoff: DateTime.t() | nil, heartbeats: [heartbeat()], versions:
  [String.t()]}`. `cutoff` is `nil` when `aurora_meter_checkpoints` does not
  exist, which is every database below core schema version 7.

  ## Examples

      status = AuroraMeter.Retention.status()
      is_list(status.heartbeats)
      #=> true

  """
  @spec status(keyword()) :: %{
          cutoff: DateTime.t() | nil,
          heartbeats: [heartbeat()],
          versions: [String.t()]
        }
  def status(opts \\ []) when is_list(opts) do
    case heartbeats(opts) do
      {:error, :undefined_table} ->
        %{cutoff: nil, heartbeats: [], versions: []}

      {:ok, cutoff, rows} ->
        %{
          cutoff: cutoff,
          heartbeats: rows,
          versions: rows |> Enum.map(& &1.version) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        }
    end
  end

  @doc """
  Removes one node's `"flush:<node>"` heartbeat, so it stops blocking a receipt
  prune.

  This is the **only** override of the receipt rule, and it overrides it for one
  named node rather than removing it. Use it when a node is genuinely gone:
  scaled down, terminated, replaced, its machine destroyed. Returns
  `{:error, :not_found}` rather than `:ok` when there is no such row, so a typo
  cannot look like success.

  > #### The precondition, in plain words {: .warning}
  >
  > The node must not be coming back with its ETS tables intact. If it is merely
  > partitioned, or stopped and about to be restarted from the same memory, it
  > may still hold a flush batch. Forgetting it removes the protection for that
  > batch, and if the node then returns and retries it, the batch's usage is
  > added a second time.

  It logs at `:warning` with the row it removed, because a deletion that cannot
  be undone should leave a trace an operator can find afterwards.

  ## Examples

      AuroraMeter.Retention.forget_node("app@10.0.1.7")
      #=> {:ok, %{node: "app@10.0.1.7", state: "pending", ...}}

  """
  @spec forget_node(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def forget_node(node_id, opts \\ []) when is_binary(node_id) do
    name = heartbeat_name(node_id)

    case Checkpoints.get(name, opts) do
      nil ->
        {:error, :not_found}

      row ->
        :ok = Checkpoints.delete(name, opts)

        Logger.warning("""
        AuroraMeter.Retention.forget_node/1 removed the flush heartbeat for #{inspect(node_id)}.

        It read: state=#{inspect(row.state)} updated_at=#{inspect(row.updated_at)} \
        cursor=#{inspect(row.cursor)}

        That node no longer blocks a flush-receipt prune. If it is still alive and still \
        holding a pending batch, and it later retries that batch after its receipt has been \
        pruned, the batch's usage is counted twice (invariant I01).
        """)

        {:ok, Map.put(row, :node, node_id)}
    end
  end

  # -- the heartbeat the Flusher writes --------------------------------------

  @doc false
  # Called by `AuroraMeter.Flusher` and by nothing else. Never raises: a
  # heartbeat that cannot be written must not be able to fail a flush, and the
  # staleness rule is exactly what covers the heartbeat that is missing because
  # the database is the thing that failed.
  @spec record_flush_state(:idle | {:pending, map()}, keyword()) :: :ok | {:error, term()}
  def record_flush_state(state, opts \\ [])

  def record_flush_state(:idle, opts), do: write_heartbeat("idle", %{}, opts)

  def record_flush_state({:pending, batch}, opts) do
    cursor =
      %{"batch_id" => Map.get(batch, :id)}
      |> put_instant("pending_since", Map.get(batch, :snapshot_at))

    write_heartbeat("pending", cursor, opts)
  end

  @doc """
  This node's identity in its flush heartbeat row.

  `:flush_node_id` when the host set one, and `to_string(node())` otherwise.

  ## Examples

      iex> is_binary(AuroraMeter.Retention.node_id())
      true

  """
  @spec node_id() :: String.t()
  def node_id, do: Config.flush_node_id() || to_string(node())

  defp write_heartbeat(state, cursor, opts) do
    node_id = Keyword.get(opts, :node_id) || node_id()
    cursor = Map.put(cursor, "version", package_version())

    Checkpoints.put(heartbeat_name(node_id), cursor, %{}, state, opts)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp put_instant(cursor, _key, nil), do: cursor

  defp put_instant(cursor, key, %DateTime{} = at),
    do: Map.put(cursor, key, DateTime.to_iso8601(at))

  @doc false
  # The package version this node runs, stamped into every heartbeat so that a
  # mixed-fleet check is mechanical rather than an operator's attestation
  # (`architecture-map.md` section 6, and section 7.4's lot cutover, which reads
  # the same rows).
  @spec package_version() :: String.t()
  def package_version do
    case :application.get_key(:aurora_meter, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "unknown"
    end
  end

  # -- the run ----------------------------------------------------------------

  defp run(opts, mode) do
    keys = requested(opts)
    override = cutoff_override!(opts)

    {report, reasons} =
      Enum.reduce(keys, {%{}, []}, fn key, {report, reasons} ->
        entry = entry!(key)

        case guard(entry, override, opts) do
          :ok ->
            {count, blocked} = execute(entry, mode, override, opts)
            {Map.put(report, key, count), reasons ++ blocked}

          {:blocked, reason} ->
            emit(key, 0, 0, true)
            {Map.put(report, key, 0), reasons ++ [reason]}
        end
      end)

    if reasons == [], do: {:ok, report}, else: {:blocked, report, reasons}
  end

  defp execute(entry, :plan, override, opts) do
    started = AuroraMeter.Clock.monotonic_ms()
    {count, _cutoff} = count(entry, override, opts)
    emit(entry.key, count, AuroraMeter.Clock.monotonic_ms() - started, false)
    {count, []}
  end

  defp execute(entry, :prune, override, opts) do
    started = AuroraMeter.Clock.monotonic_ms()
    batch_size = positive(opts, :batch_size, @default_batch_size)
    max_items = positive(opts, :max_items, @default_max_items)
    max_batches = max(1, div(max_items, batch_size))

    result =
      Operations.run_batches(
        operation(entry.key),
        [max_batches: max_batches],
        fn _cursor -> delete_batch(entry, override, batch_size, opts) end
      )

    case result do
      {:ok, %{stopped: :max_batches} = report} ->
        # The run budget ran out with rows still eligible. Not a failure and not
        # a block, but an operator has to know: a table that grows faster than
        # one run removes needs a larger `:max_items` or a more frequent
        # schedule, and a silent partial prune would hide that for months.
        deleted = counted(report)
        emit(entry.key, deleted, AuroraMeter.Clock.monotonic_ms() - started, false)

        {deleted,
         [
           %{
             table: entry.key,
             reason: :budget_exhausted,
             detail: %{deleted: deleted, max_items: max_items, batch_size: batch_size}
           }
         ]}

      {:ok, report} ->
        deleted = counted(report)
        emit(entry.key, deleted, AuroraMeter.Clock.monotonic_ms() - started, false)
        {deleted, []}

      {:paused, report} ->
        deleted = counted(report)
        emit(entry.key, deleted, AuroraMeter.Clock.monotonic_ms() - started, true)

        {deleted,
         [
           %{
             table: entry.key,
             reason: :paused,
             detail: %{operation: operation(entry.key), deleted: deleted}
           }
         ]}

      {:error, reason} ->
        emit(entry.key, 0, AuroraMeter.Clock.monotonic_ms() - started, true)
        {0, [%{table: entry.key, reason: :error, detail: %{error: reason}}]}
    end
  end

  defp counted(%{counts: counts}), do: Map.get(counts, "deleted", 0)

  @doc """
  The `AuroraMeter.Operations` name one table's prune pauses and resumes under.

  One operation per table, because pausing receipt pruning while leaving the
  replay rows alone is something an operator actually wants.

  ## Examples

      iex> AuroraMeter.Retention.operation(:flush_receipts)
      "retention:flush_receipts"

  """
  @spec operation(table()) :: String.t()
  def operation(key), do: "retention:#{key}"

  # One bounded `DELETE`, and the only statement in this module that removes a
  # row. The cursor it hands back is **not a position**: a delete sweep advances
  # by doing the work, so the only thing the next batch needs to know is whether
  # the last one filled its limit. `nil` means the scan reached its end, which
  # is what `AuroraMeter.Operations.run_batches/3` reads as complete.
  defp delete_batch(entry, override, batch_size, opts) do
    {sql, params} = delete_sql(entry, override)

    %{num_rows: deleted} = repo(opts).query!(sql, params ++ [batch_size])

    cursor = if deleted < batch_size, do: nil, else: %{"remaining" => true}

    {:ok, %{cursor: cursor, counts: %{"deleted" => deleted, "examined" => deleted}}}
  rescue
    exception -> {:error, exception}
  end

  defp count(entry, override, opts) do
    {sql, params} = count_sql(entry, override)

    %{rows: [[count, cutoff]]} = repo(opts).query!(sql, params)

    {count, utc(cutoff)}
  end

  # -- the statements ---------------------------------------------------------

  @doc false
  # Exported so the test can assert that these two really do share one
  # predicate, rather than trusting a comment that says they do.
  @spec count_sql(map(), DateTime.t() | nil) :: {String.t(), [term()]}
  def count_sql(entry, override) do
    {bound, params} = bound(entry, override)

    sql = """
    #{with_clause(bound, entry)}
    SELECT (SELECT count(*) FROM #{entry.table} WHERE #{entry.predicate}),
           (SELECT cutoff FROM bound)
    """

    {sql, params}
  end

  @doc false
  @spec delete_sql(map(), DateTime.t() | nil) :: {String.t(), [term()]}
  def delete_sql(entry, override) do
    {bound, params} = bound(entry, override)

    sql = """
    #{with_clause(bound, entry)}
    DELETE FROM #{entry.table}
     WHERE #{entry.id} IN (
       SELECT #{entry.id} FROM #{entry.table}
        WHERE #{entry.predicate}
        ORDER BY #{entry.order}
        LIMIT $2
     )
    """

    {sql, params}
  end

  defp with_clause(bound, entry) do
    ctes = [{"bound", bound} | entry.with]

    "WITH " <>
      Enum.map_join(ctes, ",\n     ", fn {name, body} ->
        "#{name} AS MATERIALIZED (#{String.trim(body)})"
      end)
  end

  # The cutoff is computed **in the statement**, by the database, from
  # `clock_timestamp()`. Nothing is read into Elixir and written back, so there
  # is no future caller who has to remember which clock this comparison takes,
  # which is the stronger form `architecture-map.md` section 3 asks for. When
  # the caller supplied `:older_than` the instant is a parameter and no clock is
  # read at all.
  defp bound(_entry, %DateTime{} = override),
    do: {"SELECT $1::timestamp AS cutoff", [DateTime.to_naive(override)]}

  defp bound(entry, nil) do
    {"SELECT (clock_timestamp() AT TIME ZONE 'UTC') - make_interval(days => $1::int) AS cutoff",
     [apply(Config, entry.window, [])]}
  end

  # -- the guards -------------------------------------------------------------

  defp guard(%{key: :flush_receipts} = entry, override, opts) do
    case heartbeats(opts) do
      {:error, :undefined_table} ->
        {:blocked,
         %{
           table: entry.key,
           reason: :checkpoints_unavailable,
           detail: %{
             table: "aurora_meter_checkpoints",
             note:
               "the heartbeat table does not exist, so no node can report whether it still " <>
                 "holds a batch. This is a database below core schema version 7."
           }
         }}

      {:ok, cutoff, []} ->
        no_heartbeats(entry, override, cutoff, opts)

      {:ok, _cutoff, rows} ->
        warn_ambiguous(rows)

        case Enum.filter(rows, & &1.blocks) do
          [] -> :ok
          blocking -> {:blocked, liveness_reason(entry, blocking)}
        end
    end
  end

  defp guard(_entry, _override, _opts), do: :ok

  # No heartbeat row anywhere is not evidence that no node holds a batch: it is
  # exactly what a fleet that has not been upgraded yet looks like. It only
  # matters when there is something to delete, so an installation with no old
  # receipts is not blocked by it and a first prune on a fresh database is not
  # an error.
  defp no_heartbeats(entry, override, _cutoff, opts) do
    {eligible, cutoff} = count(entry, override, opts)

    if eligible == 0 do
      :ok
    else
      {:blocked,
       %{
         table: entry.key,
         reason: :no_heartbeats,
         detail: %{
           eligible: eligible,
           cutoff: cutoff,
           note:
             "no node has written a \"flush:<node>\" heartbeat, and there are receipts older " <>
               "than the cutoff. Deploy the release to every node, let each write one " <>
               "heartbeat (AuroraMeter.Retention.status/0 lists them), then prune."
         }
       }}
    end
  end

  defp liveness_reason(entry, blocking) do
    %{
      table: entry.key,
      reason: :node_liveness_unknown,
      detail: %{
        nodes:
          Enum.map(blocking, fn row ->
            %{
              node: row.node,
              state: row.state,
              why: row.why,
              updated_at: row.updated_at,
              pending_since: row.pending_since,
              batch_id: row.batch_id,
              version: row.version
            }
          end)
      }
    }
  end

  defp warn_ambiguous(rows) do
    if Enum.any?(rows, &(&1.node == "nonode@nohost")) do
      Logger.warning(
        "AuroraMeter.Retention: a flush heartbeat is filed under \"nonode@nohost\", which is " <>
          "what every unnamed VM calls itself. If more than one node shares this database, " <>
          "they share this one row and it cannot tell one node from ten. Set " <>
          ":flush_node_id per node, or start the VMs with names."
      )
    end

    case rows |> Enum.map(& &1.version) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [_one] ->
        :ok

      [] ->
        :ok

      many ->
        Logger.warning(
          "AuroraMeter.Retention: the fleet is reporting #{length(many)} different Aurora " <>
            "Meter versions (#{Enum.join(many, ", ")}). That is normal during a rolling " <>
            "deploy and worth a look if it persists."
        )
    end

    :ok
  end

  # One statement: the rows and the cutoff they are judged against come from the
  # same read of the same clock.
  @heartbeat_sql """
  WITH bound AS MATERIALIZED (
    SELECT (clock_timestamp() AT TIME ZONE 'UTC') - make_interval(days => $1::int) AS cutoff
  )
  SELECT name,
         state,
         updated_at,
         cursor->>'pending_since',
         cursor->>'batch_id',
         cursor->>'version',
         (SELECT cutoff FROM bound)
    FROM aurora_meter_checkpoints
   WHERE name LIKE 'flush:%'
   ORDER BY name
  """

  defp heartbeats(opts) do
    days = Keyword.get(opts, :heartbeat_days) || Config.flush_receipt_retention()

    %{rows: rows} = repo(opts).query!(@heartbeat_sql, [days])

    cutoff = rows |> List.first() |> cutoff_of()

    {:ok, cutoff, Enum.map(rows, &heartbeat_row/1)}
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :undefined_table do
        {:error, :undefined_table}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp cutoff_of(nil), do: nil
  defp cutoff_of(row), do: row |> List.last() |> utc()

  defp heartbeat_row([name, state, updated_at, pending_since, batch_id, version, cutoff]) do
    updated_at = utc(updated_at)
    cutoff = utc(cutoff)
    pending = parse_instant(pending_since)

    {blocks, why} = blocks?(state, updated_at, pending, cutoff)

    %{
      node: String.replace_prefix(name, @heartbeat_prefix, ""),
      state: state,
      updated_at: updated_at,
      pending_since: pending,
      batch_id: batch_id,
      version: version,
      blocks: blocks,
      why: why
    }
  end

  # The whole of the receipt rule, and every branch that is not an explicit
  # "this node cannot be holding an older batch" blocks. A state this release
  # does not write blocks too: a heartbeat vocabulary that grows without this
  # function growing with it must fail towards keeping the receipts.
  defp blocks?("idle", updated_at, _pending, cutoff) do
    if DateTime.compare(updated_at, cutoff) == :lt,
      do: {true, :heartbeat_stale},
      else: {false, :idle_and_current}
  end

  defp blocks?("pending", _updated_at, nil, _cutoff), do: {true, :pending_since_unreadable}

  defp blocks?("pending", _updated_at, pending, cutoff) do
    if DateTime.compare(pending, cutoff) == :lt,
      do: {true, :pending_batch_older_than_cutoff},
      else: {false, :pending_batch_newer_than_cutoff}
  end

  defp blocks?(_unknown_state, _updated_at, _pending, _cutoff), do: {true, :unknown_state}

  defp parse_instant(nil), do: nil

  defp parse_instant(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _unparseable -> nil
    end
  end

  # -- options ----------------------------------------------------------------

  defp requested(opts) do
    case Keyword.get(opts, :only) do
      nil -> tables()
      list when is_list(list) -> Enum.map(list, &validate_key!/1)
      other -> validate_key!(other) |> List.wrap()
    end
  end

  defp validate_key!(key) do
    if key in tables() do
      key
    else
      raise ArgumentError, """
      #{inspect(key)} is not a table AuroraMeter.Retention may delete from.

      The allow list is closed and it is compile time: #{inspect(tables())}.

      There is no option that adds to it. Everything else this package stores is
      financial history or a live cursor, and this module never deletes either:

        #{Enum.join(@protected, "\n  ")}
      """
    end
  end

  defp entry!(key), do: Enum.find(@allow, &(&1.key == key))

  defp cutoff_override!(opts) do
    case Keyword.get(opts, :older_than) do
      nil ->
        nil

      %DateTime{} = at ->
        at

      other ->
        raise ArgumentError,
              ":older_than is a DateTime or nil, got: #{inspect(other)}"
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _absent_or_invalid -> default
    end
  end

  # The literal event name rather than the module attribute, so the inventory
  # guard that greps `lib/` for emit sites can see it (A05, and the same reason
  # `AuroraMeter.Events.Replay` writes its two out in full).
  defp emit(table, deleted, duration, blocked) do
    :telemetry.execute(
      [:aurora_meter, :retention, :prune],
      %{
        deleted: deleted,
        duration: duration
      },
      %{table: table, blocked: blocked}
    )
  end

  defp repo(opts), do: Keyword.get(opts, :repo) || Config.repo()

  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at
end
