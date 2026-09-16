defmodule AuroraMeterExampleAi.Orgs do
  @moduledoc """
  Organisations, and the one funnel every organisation-scoped query goes
  through.

  There is no `get_org!/1` taking an id from the outside world, and that is the
  point. Everything an organisation owns is reached with `scope_query/2`, which
  takes the caller's session scope and adds the `org_id` filter itself. A
  caller cannot forget the filter, because there is no call shape that lets it.
  """

  import Ecto.Query, warn: false

  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Accounts.User
  alias AuroraMeterExampleAi.Orgs.Org
  alias AuroraMeterExampleAi.Repo

  @doc """
  Adds this scope's organisation filter to `queryable`.

  Every query in this application that touches organisation-owned data starts
  here. `scope.org.id` comes from the session, never from request parameters:
  see `AuroraMeterExampleAi.Tenancy`.
  """
  @spec scope_query(Ecto.Queryable.t(), Scope.t()) :: Ecto.Query.t()
  def scope_query(queryable, %Scope{org: %Org{id: org_id}}) when is_integer(org_id) do
    from(row in queryable, where: row.org_id == ^org_id)
  end

  @doc """
  The organisation a user belongs to, loading it if the association is not
  already loaded.

  The lazy load is one extra query on the session path at worst. A production
  application would preload it in the session query; the sample keeps the
  laziness here so that `Scope.for_user/1` stays a pure constructor and the
  reader has one place to look.
  """
  @spec org_for_user(User.t()) :: Org.t() | nil
  def org_for_user(%User{org: %Org{} = org}), do: org
  def org_for_user(%User{org_id: nil}), do: nil
  def org_for_user(%User{org_id: id}), do: Repo.get(Org, id)

  @doc "Creates an organisation."
  @spec create_org(map()) :: {:ok, Org.t()} | {:error, Ecto.Changeset.t()}
  def create_org(attrs) do
    %Org{} |> Org.changeset(attrs) |> Repo.insert()
  end

  @doc "Fetches an organisation by slug. Used by the seed and by tests only."
  @spec get_org_by_slug(String.t()) :: Org.t() | nil
  def get_org_by_slug(slug), do: Repo.get_by(Org, slug: slug)

  @doc "Every organisation, oldest first. Used by `mix sample.repair` and `/ops`."
  @spec list_orgs() :: [Org.t()]
  def list_orgs, do: Repo.all(from(o in Org, order_by: o.id))

  @doc """
  The organisation an API key belongs to, or `nil`.

  The comparison is `:crypto.hash_equals/2` on every candidate rather than a
  `where api_key = ?`, so the time it takes does not depend on how much of the
  key was right. A real application indexes a hash of the key and compares
  that; this sample has a handful of organisations and a clear comparison is
  worth more here than an index.
  """
  @spec get_org_by_api_key(String.t()) :: Org.t() | nil
  def get_org_by_api_key(key) when is_binary(key) do
    Enum.find(list_orgs(), fn org ->
      byte_size(org.api_key) == byte_size(key) and :crypto.hash_equals(org.api_key, key)
    end)
  end

  def get_org_by_api_key(_key), do: nil

  @doc "The organisation's owner, which is who an API request acts as."
  @spec owner(Org.t()) :: User.t() | nil
  def owner(%Org{id: id}) do
    Repo.one(
      from(u in User, where: u.org_id == ^id and u.role == "owner", order_by: u.id, limit: 1)
    )
  end
end
