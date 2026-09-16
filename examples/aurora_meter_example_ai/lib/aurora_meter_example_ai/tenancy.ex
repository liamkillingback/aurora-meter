defmodule AuroraMeterExampleAi.Tenancy do
  @moduledoc """
  Turns this application's organisation into the key Aurora Meter meters
  against, and is the only place in the sample that decides what a tenant is.

  Configured as `config :aurora_meter, tenant: AuroraMeterExampleAi.Tenancy`.
  Without it, `AuroraMeter.Tenant.Default` would call `to_string/1` on whatever
  it was handed, which raises `Protocol.UndefinedError` for a struct and, worse,
  turns `nil` into `""` so that every unresolved tenant shares one set of
  counters.

  ## Why there is a binary clause

  `to_key/1` accepts a string that is already a key and returns it unchanged.
  That clause is not laziness: stored `tenant_key` values are passed back to the
  facade by operational code (a reconciler, a repair task, and in the Pro
  package the export outbox), so a custom tenant module that refuses its own
  keys makes those paths unusable. The rule is in the programme's architecture
  map and the shape is in `AuroraMeter.Tenant`'s own moduledoc.

  ## Why `org!/1` takes a scope and nothing else

  Every organisation in this application comes out of the session, through
  `AuroraMeterExampleAi.Accounts.Scope`. `org!/1` has one clause and it matches
  a scope carrying an organisation. Hand it a map of request parameters, a
  string id or `nil` and it raises `FunctionClauseError` rather than resolving
  anything, so "the tenant is never read from the URL" is enforced by the shape
  of the function rather than by everyone remembering.

  That is the whole of the fix for the commonest multi-tenant defect: a
  dashboard that reads `params["tenant"]` looks exactly like a dashboard that
  reads the session until somebody changes the number in the address bar.
  """

  @behaviour AuroraMeter.Tenant

  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Orgs.Org

  @doc """
  The Aurora Meter tenant key for an organisation.

  ## Examples

      iex> AuroraMeterExampleAi.Tenancy.to_key(%AuroraMeterExampleAi.Orgs.Org{id: 7})
      "org_7"

      iex> AuroraMeterExampleAi.Tenancy.to_key("org_7")
      "org_7"

  """
  @impl AuroraMeter.Tenant
  @spec to_key(term()) :: String.t()
  def to_key(%Org{id: id}) when is_integer(id) do
    key = "org_" <> Integer.to_string(id)

    # Emitted so the sample's organisation-isolation test can assert a negative:
    # that during a request made by one organisation's session, no other
    # organisation's key was ever resolved. A negative asserted over a rendered
    # page can pass by coincidence (the other organisation's figure happened to
    # match, or happened to be zero); a negative asserted over every resolution
    # the run actually performed cannot.
    #
    # It costs one `:telemetry.execute/3` with no handlers attached, which is a
    # map build and a table lookup. Your own application does not need this, but
    # an audit trail of tenant resolution is not a bad thing to have.
    :telemetry.execute([:aurora_meter_example_ai, :tenant, :resolved], %{count: 1}, %{
      tenant_key: key
    })

    key
  end

  def to_key(%Scope{org: %Org{} = org}), do: to_key(org)
  def to_key(key) when is_binary(key), do: key

  @doc """
  The organisation this caller is acting for, from the session scope.

  Raises `FunctionClauseError` on anything that is not a scope carrying an
  organisation, which is deliberate: see the module documentation.
  """
  @spec org!(Scope.t()) :: Org.t()
  def org!(%Scope{org: %Org{} = org}), do: org
end
