defmodule AuroraMeter.Test.FaultRepo do
  @moduledoc """
  A repo shim that can fail an individual statement *inside* a production
  transaction (build unit 01b).

  It is not an `Ecto.Repo`. It exports exactly the functions this package's
  `lib/` calls on `AuroraMeter.Config.repo/0`, checks
  `AuroraMeter.Test.Faults` before each statement, and delegates to the real
  repo named by `Application.get_env(:aurora_meter_test, :repo)`.

  Because `AuroraMeter.Storage.Ecto` opens its `flush_batch` transaction on
  `repo()` and issues all three statements on `repo()`, arming
  `:before_commit` with a predicate on `statement: :history_upsert` fails the
  third statement inside the *real* transaction and Postgres rolls the first
  two back. That is I02's proof, and no production code is modified to get it.

      with_config([{:aurora_meter, :repo, AuroraMeter.Test.FaultRepo}], fn ->
        Faults.arm(:before_commit, :raise, when: &(&1[:statement] == :history_upsert))
        ...
      end)

  Context keys handed to every check: `:statement`, `:schema`, `:repo_fun` and
  `:kind` (`:read` or `:write`). Predicates should name both `:statement` and
  `:kind`: a read of the same schema carries the same statement name.

  `transaction/1` fires `:after_commit_before_ack` only when the *outermost*
  transaction has committed, so a nested ledger call does not look like a
  commit. It fires no `:before_commit`: that point belongs to statements.

  `uncovered_call_sites/1` is the surface guard. It parses `lib/**/*.ex` and
  reports every `repo().fun(...)`, `repo.fun(...)` and `Config.repo().fun(...)`
  call site whose `{name, arity}` this module does not export. A new call site
  in production therefore fails the harness self-test, rather than silently
  escaping injection.
  """

  alias AuroraMeter.Test.Faults

  @statements %{
    AuroraMeter.Schema.FlushReceipt => :receipt_insert,
    AuroraMeter.Schema.Counter => :counter_upsert,
    AuroraMeter.Schema.History => :history_upsert,
    AuroraMeter.Schema.Event => :event_insert,
    AuroraMeter.Schema.Subscription => :subscription_upsert,
    AuroraMeter.Schema.CreditTransaction => :transaction_insert,
    AuroraMeter.Schema.CreditBalance => :balance_update
  }

  @update_functions [:update, :update!, :insert_or_update, :insert_or_update!]

  @doc "The configured target repo. Set in `test_helper.exs`, never in the library's own key."
  @spec target() :: module()
  def target, do: Application.get_env(:aurora_meter_test, :repo, AuroraMeter.TestRepo)

  @doc "The statement name this shim reports for `schema` under `repo_fun`."
  @spec statement(module() | nil, atom()) :: atom()
  def statement(schema, repo_fun) do
    case {Map.get(@statements, schema), repo_fun} do
      {nil, _} -> :other
      {:transaction_insert, fun} when fun in @update_functions -> :transaction_update
      {name, _} -> name
    end
  end

  # -- the surface lib/ calls -------------------------------------------------

  @doc false
  @spec transaction(fun()) :: {:ok, term()} | {:error, term()}
  def transaction(fun) do
    result = target().transaction(fun)

    with {:ok, _} <- result, false <- target().in_transaction?() do
      Faults.check(:after_commit_before_ack, %{
        statement: :transaction,
        schema: nil,
        repo_fun: :transaction,
        kind: :write
      })
    end

    result
  end

  @doc false
  @spec transaction(fun(), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts), do: target().transaction(fun, opts)

  @doc false
  @spec insert_all(term(), term()) :: {non_neg_integer(), nil | [term()]}
  def insert_all(schema, entries) do
    guard(:insert_all, :write, schema, fn -> target().insert_all(schema, entries) end)
  end

  @doc false
  @spec insert_all(term(), term(), keyword()) :: {non_neg_integer(), nil | [term()]}
  def insert_all(schema, entries, opts) do
    guard(:insert_all, :write, schema, fn -> target().insert_all(schema, entries, opts) end)
  end

  @doc false
  @spec insert(term()) :: {:ok, term()} | {:error, term()}
  def insert(changeset),
    do: guard(:insert, :write, changeset, fn -> target().insert(changeset) end)

  @doc false
  @spec insert(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def insert(changeset, opts) do
    guard(:insert, :write, changeset, fn -> target().insert(changeset, opts) end)
  end

  @doc false
  @spec update(term()) :: {:ok, term()} | {:error, term()}
  def update(changeset),
    do: guard(:update, :write, changeset, fn -> target().update(changeset) end)

  @doc false
  @spec update!(term()) :: term()
  def update!(changeset) do
    guard(:update!, :write, changeset, fn -> target().update!(changeset) end)
  end

  @doc false
  @spec insert!(term()) :: term()
  def insert!(changeset),
    do: guard(:insert!, :write, changeset, fn -> target().insert!(changeset) end)

  @doc false
  @spec update_all(term(), keyword()) :: {non_neg_integer(), nil | [term()]}
  def update_all(queryable, updates) do
    guard(:update_all, :write, queryable, fn -> target().update_all(queryable, updates) end)
  end

  @doc false
  @spec insert_or_update(term()) :: {:ok, term()} | {:error, term()}
  def insert_or_update(changeset) do
    guard(:insert_or_update, :write, changeset, fn -> target().insert_or_update(changeset) end)
  end

  @doc false
  @spec insert_or_update!(term()) :: term()
  def insert_or_update!(changeset) do
    guard(:insert_or_update!, :write, changeset, fn -> target().insert_or_update!(changeset) end)
  end

  @doc false
  @spec delete(term()) :: {:ok, term()} | {:error, term()}
  def delete(struct), do: guard(:delete, :write, struct, fn -> target().delete(struct) end)

  @doc false
  @spec delete_all(term()) :: {non_neg_integer(), nil | [term()]}
  def delete_all(queryable) do
    guard(:delete_all, :write, queryable, fn -> target().delete_all(queryable) end)
  end

  @doc false
  @spec all(term()) :: [term()]
  def all(queryable), do: guard(:all, :read, queryable, fn -> target().all(queryable) end)

  @doc false
  @spec all(term(), keyword()) :: [term()]
  def all(queryable, opts),
    do: guard(:all, :read, queryable, fn -> target().all(queryable, opts) end)

  @doc false
  @spec one(term()) :: term() | nil
  def one(queryable), do: guard(:one, :read, queryable, fn -> target().one(queryable) end)

  @doc false
  @spec one!(term()) :: term()
  def one!(queryable), do: guard(:one!, :read, queryable, fn -> target().one!(queryable) end)

  @doc false
  @spec get(term(), term()) :: term() | nil
  def get(queryable, id), do: guard(:get, :read, queryable, fn -> target().get(queryable, id) end)

  @doc false
  @spec get!(term(), term()) :: term()
  def get!(queryable, id),
    do: guard(:get!, :read, queryable, fn -> target().get!(queryable, id) end)

  @doc false
  @spec get_by(term(), keyword() | map()) :: term() | nil
  def get_by(queryable, clauses) do
    guard(:get_by, :read, queryable, fn -> target().get_by(queryable, clauses) end)
  end

  @doc false
  @spec get_by!(term(), keyword() | map()) :: term()
  def get_by!(queryable, clauses) do
    guard(:get_by!, :read, queryable, fn -> target().get_by!(queryable, clauses) end)
  end

  @doc false
  @spec exists?(term()) :: boolean()
  def exists?(queryable) do
    guard(:exists?, :read, queryable, fn -> target().exists?(queryable) end)
  end

  @doc false
  @spec aggregate(term(), atom(), atom()) :: term()
  def aggregate(queryable, aggregate, field) do
    guard(:aggregate, :read, queryable, fn -> target().aggregate(queryable, aggregate, field) end)
  end

  @doc false
  @spec stream(term()) :: Enumerable.t()
  def stream(queryable),
    do: guard(:stream, :read, queryable, fn -> target().stream(queryable) end)

  @doc false
  @spec rollback(term()) :: term()
  def rollback(value), do: target().rollback(value)

  @doc false
  @spec checkout((-> term())) :: term()
  def checkout(fun), do: target().checkout(fun)

  @doc false
  @spec checkout((-> term()), keyword()) :: term()
  def checkout(fun, opts), do: target().checkout(fun, opts)

  @doc false
  @spec query!(String.t(), list()) :: term()
  def query!(sql, params \\ []), do: target().query!(sql, params)

  # `AuroraMeter.Events.Backfill` bounds its bulk statements with an explicit
  # `:timeout`, because the driver's 15 second default is the wrong bound for a
  # batch of thousands of rows.
  @doc false
  @spec query!(String.t(), list(), keyword()) :: term()
  def query!(sql, params, opts), do: target().query!(sql, params, opts)

  @doc false
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: target().in_transaction?()

  @doc false
  @spec config() :: keyword()
  def config, do: target().config()

  # -- the surface guard ------------------------------------------------------

  @doc """
  Every repo call site in `paths` (directories or files), as
  `%{fun: atom, arity: non_neg_integer, file: String.t(), line: pos_integer}`.
  """
  @spec call_sites([Path.t()]) :: [map()]
  def call_sites(paths) do
    paths
    |> Enum.flat_map(&expand/1)
    |> Enum.flat_map(&sites_in/1)
    |> Enum.sort_by(&{&1.file, &1.line, &1.fun, &1.arity})
  end

  @doc """
  The call sites in `paths` this shim does not export. `[]` is the only
  acceptable value: a call site the shim cannot see is a statement no fault can
  reach.
  """
  @spec uncovered_call_sites([Path.t()]) :: [map()]
  def uncovered_call_sites(paths) do
    exported = MapSet.new(__MODULE__.__info__(:functions))
    Enum.reject(call_sites(paths), &MapSet.member?(exported, {&1.fun, &1.arity}))
  end

  defp expand(path) do
    if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*.ex")), else: [path]
  end

  defp sites_in(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> unpipe()
    |> collect_sites(file)
  end

  defp unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, right]} = node -> pipe(node, left, right)
      node -> node
    end)
  end

  defp pipe(node, left, right) do
    Macro.pipe(left, right, 0)
  rescue
    ArgumentError -> node
  end

  defp collect_sites(ast, file) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [target, fun]}, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          if repo_expr?(target) do
            site = %{fun: fun, arity: length(args), file: file, line: meta[:line] || 0}
            {node, [site | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp repo_expr?({:repo, _, nil}), do: true
  defp repo_expr?({:repo, _, []}), do: true
  defp repo_expr?({{:., _, [{:__aliases__, _, _}, :repo]}, _, []}), do: true
  defp repo_expr?(_), do: false

  # -- internals --------------------------------------------------------------

  defp guard(repo_fun, kind, subject, run) do
    schema = source_schema(subject)

    Faults.check(:before_commit, %{
      statement: statement(schema, repo_fun),
      schema: schema,
      repo_fun: repo_fun,
      kind: kind
    })

    run.()
  end

  defp source_schema(%Ecto.Query{from: %{source: source}}), do: query_schema(source)
  defp source_schema(%Ecto.Changeset{data: %module{}}), do: module
  defp source_schema(%Ecto.Changeset{}), do: nil
  defp source_schema(%module{}), do: module
  defp source_schema(module) when is_atom(module), do: module
  defp source_schema({_table, module}) when is_atom(module), do: module
  defp source_schema(_other), do: nil

  defp query_schema({_table, module}) when is_atom(module), do: module
  defp query_schema(%Ecto.SubQuery{query: query}), do: source_schema(query)
  defp query_schema(module) when is_atom(module), do: module
  defp query_schema(_other), do: nil
end
