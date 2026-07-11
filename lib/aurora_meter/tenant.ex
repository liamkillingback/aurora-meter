defmodule AuroraMeter.Tenant do
  @moduledoc """
  Resolves an opaque tenant term into a stable string key.

  Tenants are never assumed to be strings or integers — a host may pass a struct,
  a tuple, or any identifier. The configured implementation (`:tenant`, default
  `AuroraMeter.Tenant.Default`) turns it into the `tenant_key` used everywhere in
  storage, ETS, and PubSub topics.
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
