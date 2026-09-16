defmodule AuroraMeterExampleAiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AuroraMeterExampleAiWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AuroraMeterExampleAiWeb.Endpoint

      use AuroraMeterExampleAiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AuroraMeterExampleAiWeb.ConnCase
    end
  end

  setup tags do
    AuroraMeterExampleAi.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn} = context) do
    user = AuroraMeterExampleAi.AccountsFixtures.user_fixture()
    scope = AuroraMeterExampleAi.Accounts.Scope.for_user(user)

    opts =
      context
      |> Map.take([:token_authenticated_at])
      |> Enum.into([])

    %{conn: log_in_user(conn, user, opts), user: user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user, opts \\ []) do
    token = AuroraMeterExampleAi.Accounts.generate_user_session_token(user)

    maybe_set_token_authenticated_at(token, opts[:token_authenticated_at])

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  @doc """
  Setup helper that logs in the owner of a funded organisation.

      setup :log_in_org_owner

  Puts `:scope`, `:org` and `:user` in the context alongside the connection.
  """
  def log_in_org_owner(%{conn: conn} = context) do
    scope = AuroraMeterExampleAi.SampleFixtures.funded_scope_fixture(Map.take(context, [:credit]))
    %{conn: log_in_user(conn, scope.user), scope: scope, org: scope.org, user: scope.user}
  end

  @doc """
  Setup helper that logs in a **member** rather than an owner, which is what the
  operational pages and the developer tools are not for.
  """
  def log_in_org_member(%{conn: conn}) do
    org = AuroraMeterExampleAi.SampleFixtures.org_fixture()
    scope = AuroraMeterExampleAi.SampleFixtures.scope_fixture(org, "member")
    %{conn: log_in_user(conn, scope.user), scope: scope, org: org, user: scope.user}
  end

  defp maybe_set_token_authenticated_at(_token, nil), do: nil

  defp maybe_set_token_authenticated_at(token, authenticated_at) do
    AuroraMeterExampleAi.AccountsFixtures.override_token_authenticated_at(token, authenticated_at)
  end
end
