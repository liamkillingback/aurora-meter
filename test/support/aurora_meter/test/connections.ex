defmodule AuroraMeter.Test.Connections do
  @moduledoc """
  N independent, non-sandbox SQL connections, and prefix-bounded cleanup of the
  rows they really commit (build unit 01b).

  The sandbox wraps a test in one transaction on one connection, which
  serialises the very contention a row lock, a unique index or a transaction
  boundary is supposed to survive. A test whose subject is one of those runs its
  work on real connections instead, and asserts on database totals rather than
  on task return values.

      tenant = AuroraMeter.Test.unique_tenant("flush_batch")
      on_exit(fn -> AuroraMeter.Test.Connections.cleanup!(tenant) end)

      AuroraMeter.Test.Connections.run(12, fn _i ->
        AuroraMeter.Storage.flush_batch(id, counters, history)
      end)

      assert AuroraMeter.Storage.load_counter(tenant, :ops, period) == 5

  `cleanup!/1` refuses a prefix that is not a `unique_tenant/1` value or a
  prefix registered with `register_prefix/1`, so a typo can never issue
  `DELETE FROM aurora_meter_counters WHERE tenant_key LIKE '%'`.

  `run/3` refuses more tasks than the pool can serve, with the arithmetic in
  the error, because pool exhaustion surfaces as an unrelated checkout timeout
  several layers away.
  """

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Schema.Counter
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Schema.Event
  alias AuroraMeter.Schema.EventTotal
  alias AuroraMeter.Schema.History
  alias AuroraMeter.Schema.Subscription
  alias Ecto.Adapters.SQL.Sandbox

  @tables [Counter, CreditBalance, CreditTransaction, Event, EventTotal, History, Subscription]

  @tenantless [AuroraMeter.Schema.FlushReceipt]

  @tenant_pattern ~r/^[a-z][a-z0-9_]{2,}_\d+$/

  @reserved_headroom 4

  @doc "The schema modules `cleanup!/1` deletes from, in alphabetical order."
  @spec tables() :: [module()]
  def tables, do: @tables

  @doc "Schemas the package owns that carry no `tenant_key` and so cannot be cleaned by prefix."
  @spec tenantless() :: [module()]
  def tenantless, do: @tenantless

  @doc "The real repo these connections are taken from."
  @spec repo() :: module()
  def repo, do: Application.get_env(:aurora_meter_test, :repo, AuroraMeter.TestRepo)

  @doc "The largest `n` `run/3` accepts: the pool size less #{@reserved_headroom} reserved connections."
  @spec max_tasks() :: integer()
  def max_tasks, do: pool_size() - @reserved_headroom

  @doc "The configured pool size of `repo/0`."
  @spec pool_size() :: pos_integer()
  def pool_size, do: Keyword.get(repo().config(), :pool_size, 10)

  @doc """
  Runs `fun.(i)` for `i` in `1..n`, each on its own non-sandbox connection,
  and returns the results in index order.

  Options: `:supervisor` (an existing `Task.Supervisor`; one is started and
  stopped otherwise) and `:timeout` (default 30_000, matching the existing
  independent-connection tests).

  Every task checks its connection back in from an `after`, including when the
  body raises; the raise then propagates out of `run/3` as a task exit.
  """
  @spec run(pos_integer(), (pos_integer() -> result), keyword()) :: [result] when result: term()
  def run(n, fun, opts \\ []) do
    guard_pool!(n)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case Keyword.fetch(opts, :supervisor) do
      {:ok, supervisor} ->
        spawn_all(supervisor, n, fun, timeout)

      :error ->
        {:ok, supervisor} = Task.Supervisor.start_link()

        try do
          spawn_all(supervisor, n, fun, timeout)
        after
          Supervisor.stop(supervisor)
        end
    end
  end

  @doc """
  Checks out one non-sandbox connection for the calling process, and returns
  whether this call is the one that took it (so the caller knows whether to
  check it back in). A process that already owns one keeps it.
  """
  @spec checkout!() :: boolean()
  def checkout! do
    case Sandbox.checkout(repo(), sandbox: false) do
      :ok -> true
      {:already, _} -> false
    end
  end

  @doc """
  Deletes every row in every package table whose `tenant_key` starts with
  `prefix`, on one independent connection.

  Raises `ArgumentError` *before* issuing any statement when `prefix` is
  shorter than four characters, or is neither a `unique_tenant/1` value nor a
  prefix registered with `register_prefix/1`.
  """
  @spec cleanup!(String.t()) :: :ok
  def cleanup!(prefix) do
    validate_prefix!(prefix)
    own = checkout!()
    length = String.length(prefix)

    try do
      for schema <- @tables do
        repo().delete_all(
          from(row in schema, where: fragment("left(?, ?) = ?", row.tenant_key, ^length, ^prefix))
        )
      end

      :ok
    after
      if own, do: Sandbox.checkin(repo())
    end
  end

  @doc """
  Registers a bare alphabetic prefix (`"flush_batch"`, say) that `cleanup!/1`
  will accept in addition to `unique_tenant/1` values.
  """
  @spec register_prefix(String.t()) :: :ok
  def register_prefix(prefix) when is_binary(prefix) do
    if String.length(prefix) < 4 do
      raise ArgumentError,
            "a registered prefix must be at least four characters: #{inspect(prefix)}"
    end

    :persistent_term.put({__MODULE__, :prefix, prefix}, true)
  end

  @doc "Counts the rows in every package table, for the conservation check."
  @spec row_counts() :: %{module() => non_neg_integer()}
  def row_counts do
    Map.new(@tables ++ @tenantless, fn schema ->
      {schema, repo().aggregate(schema, :count)}
    end)
  end

  @doc """
  Appends one JSON line to the file named by `AURORA_FAULT_REPORT`, for the
  conservation runner (`scripts/v1/faults.sh`). A no-op when the variable is
  unset, so the suite is unchanged outside the runner.

  Shape: `test`, `seed`, `point`, `action`, `tenant_prefix`, and the integer
  maps `before`, `after` and `delta`.
  """
  @spec report!(map()) :: :ok
  def report!(report) do
    case System.get_env("AURORA_FAULT_REPORT") do
      nil ->
        :ok

      "" ->
        :ok

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(line(report)) <> "\n", [:append])
        :ok
    end
  end

  defp line(report) do
    %{
      "test" => to_string(Map.get(report, :test, "")),
      "seed" => Map.get(report, :seed, 0),
      "point" => to_string(Map.get(report, :point, "")),
      "action" => inspect(Map.get(report, :action)),
      "tenant_prefix" => to_string(Map.get(report, :tenant_prefix, "")),
      "before" => integers(Map.get(report, :before, %{})),
      "after" => integers(Map.get(report, :after, %{})),
      "delta" => integers(Map.get(report, :delta, %{}))
    }
  end

  defp integers(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp spawn_all(supervisor, n, fun, timeout) do
    repo = repo()

    1..n
    |> Enum.map(fn index ->
      Task.Supervisor.async_nolink(supervisor, fn ->
        :ok = Sandbox.checkout(repo, sandbox: false)

        try do
          fun.(index)
        after
          Sandbox.checkin(repo)
        end
      end)
    end)
    |> Task.await_many(timeout)
  end

  defp guard_pool!(n) when is_integer(n) and n > 0 do
    if n > max_tasks() do
      raise ArgumentError, """
      #{inspect(__MODULE__)}.run/3 refuses #{n} tasks: the pool is #{pool_size()} and \
      #{@reserved_headroom} connections are reserved for the test process, the sandbox owner \
      and cleanup, so at most #{pool_size()} - #{@reserved_headroom} = #{max_tasks()} tasks \
      can be served. Raise :pool_size in config/config.exs or lower the task count.\
      """
    end

    :ok
  end

  defp guard_pool!(n) do
    raise ArgumentError, "run/3 needs a positive task count, got #{inspect(n)}"
  end

  defp validate_prefix!(prefix) when is_binary(prefix) do
    cond do
      String.length(prefix) < 4 ->
        raise ArgumentError, """
        #{inspect(__MODULE__)}.cleanup!/1 refuses #{inspect(prefix)}: a prefix shorter than \
        four characters would delete rows this harness does not own. Use \
        AuroraMeter.Test.unique_tenant/1.\
        """

      Regex.match?(@tenant_pattern, prefix) ->
        :ok

      :persistent_term.get({__MODULE__, :prefix, prefix}, false) ->
        :ok

      true ->
        raise ArgumentError, """
        #{inspect(__MODULE__)}.cleanup!/1 refuses #{inspect(prefix)}: it is neither a \
        AuroraMeter.Test.unique_tenant/1 value (#{inspect(@tenant_pattern)}) nor a prefix \
        registered with register_prefix/1.\
        """
    end
  end

  defp validate_prefix!(prefix) do
    raise ArgumentError, "a tenant prefix must be a string, got #{inspect(prefix)}"
  end
end
