defmodule AuroraMeter.Tenant do
  @moduledoc """
  Resolves an opaque tenant term into a stable string key.

  Tenants are never assumed to be strings or integers. A host may pass a struct,
  a tuple, or any identifier. The configured implementation (`:tenant`, default
  `AuroraMeter.Tenant.Default`) turns it into the `tenant_key` used everywhere in
  storage, ETS, and PubSub topics.

  ## What a good tenant is

  Use the thing that owns the subscription: the organisation, workspace or
  account, not the individual user (two users in one org must share one set
  of counters). The key must be stable for the customer's whole life and
  unique across customers, so a database primary key or a slug works, an email
  address does not. Keep it short: it is stored on every counter row and
  appears in every PubSub topic.

      AuroraMeter.track("org_42", :api_calls)        # default resolver, as-is
      AuroraMeter.track(42, :api_calls)              # default resolver, "42"
      AuroraMeter.track(%MyApp.Org{id: 42}, :api_calls) # needs a custom resolver

  A custom resolver is a few lines:

      defmodule MyApp.Tenant do
        @behaviour AuroraMeter.Tenant

        @impl true
        def to_key(%MyApp.Accounts.Org{id: id}), do: "org_\#{id}"
        def to_key(%MyApp.Accounts.Scope{org_id: id}), do: "org_\#{id}"
        def to_key(key) when is_binary(key), do: key
      end

      # config/config.exs
      config :aurora_meter, tenant: MyApp.Tenant
  """

  @doc "Converts a tenant term into its stable string key."
  @callback to_key(tenant :: term()) :: String.t()

  @doc """
  Resolves `tenant` to its string key via the configured implementation.

  ## Examples

      iex> AuroraMeter.Tenant.to_key("org_42")
      "org_42"

  """
  @spec to_key(term()) :: String.t()
  def to_key(tenant), do: AuroraMeter.Config.tenant().to_key(tenant)
end

defmodule AuroraMeter.Tenant.Default do
  @moduledoc """
  Default tenant resolver: passes binaries through and stringifies anything that
  implements `String.Chars` (integers, atoms, …). A term without `String.Chars`
  raises `Protocol.UndefinedError` — configure a custom `AuroraMeter.Tenant`
  implementation for structs.
  """

  @behaviour AuroraMeter.Tenant

  @impl AuroraMeter.Tenant
  @spec to_key(term()) :: String.t()
  def to_key(tenant) when is_binary(tenant), do: tenant
  def to_key(tenant), do: to_string(tenant)
end
