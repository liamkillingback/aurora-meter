defmodule AuroraMeterExampleAiWeb.ApiAuth do
  @moduledoc """
  Bearer-token authentication for `/api/generate`, and the tenant resolver
  `AuroraMeter.Plug.EnsureEntitled` is given.

  The resolver is the important part. `EnsureEntitled` requires `:tenant` with
  no default precisely because deciding **whose** request this is is the host's
  job and the library will not guess. This one reads the `Authorization`
  header, never a parameter and never a path segment: a tenant read out of a URL
  is an IDOR with a metering call attached.
  """

  @behaviour Plug

  import Plug.Conn

  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Orgs

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: authenticate(conn, [])

  @doc "A plug that puts the authenticated organisation on the conn, or refuses."
  def authenticate(conn, _opts) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         %Orgs.Org{} = org <- Orgs.get_org_by_api_key(key),
         %{} = owner <- Orgs.owner(org) do
      conn |> assign(:api_org, org) |> assign(:api_user, owner)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  @doc """
  The organisation for this request, for `AuroraMeter.Plug.EnsureEntitled`.

  Returns `nil` when the request was not authenticated, which the plug turns
  into 401 and nothing else: no counter is read and no counter row is created.
  """
  @spec org(Plug.Conn.t()) :: Orgs.Org.t() | nil
  def org(%Plug.Conn{} = conn), do: conn.assigns[:api_org]

  @doc "A scope for the API caller, so the domain layer sees the same shape the browser does."
  @spec scope(Plug.Conn.t()) :: Scope.t()
  def scope(%Plug.Conn{assigns: %{api_org: org, api_user: user}}) do
    %Scope{user: user, org: org}
  end
end
