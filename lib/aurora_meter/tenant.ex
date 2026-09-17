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

  ## What an implementation must return

  A non-empty binary, always. Two rules follow from that and both are part of
  the contract:

    * **A binary is passed through unchanged.** Aurora Meter Pro hands stored
      `tenant_key` values straight back to facade functions, which accept any
      term, so an implementation that rewrote an already-resolved key would
      meter Pro's work against a different tenant. `AuroraMeter.Tenant.Default`
      satisfies this; a custom one must too, which is the `to_key(key) when
      is_binary(key), do: key` clause in the example above.
    * **`""` is not a key.** An empty key used to be accepted, and every tenant
      whose resolver could not answer then shared one set of counters. In this
      release it warns once per node; in Aurora Meter 1.0 it raises. Anything
      that is not a binary raises in both.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Config.Schema, as: ConfigSchema

  @doc "Converts a tenant term into its stable string key."
  @callback to_key(tenant :: term()) :: String.t()

  @doc """
  Resolves `tenant` to its string key via the configured implementation.

  ## Examples

      iex> AuroraMeter.Tenant.to_key("org_42")
      "org_42"

  """
  @spec to_key(term()) :: String.t()
  def to_key(tenant) do
    module = Config.tenant()
    validate_key!(module, module.to_key(tenant), ConfigSchema.mode())
  end

  # The message names the configured module and what it returned, never the
  # term it was given: a host that meters a struct holding personal data must
  # not have it copied into a log line. The returned key is bounded too, for the
  # same reason.
  #
  # `mode` is a parameter, and this is public but undocumented, so the suite can
  # exercise both halves of the transition without depending on the package's
  # own version.
  @doc false
  @spec validate_key!(module(), term(), ConfigSchema.mode()) :: String.t()
  def validate_key!(_module, key, _mode) when is_binary(key) and key != "", do: key

  def validate_key!(module, "", :strict), do: raise(ArgumentError, empty_key_message(module))

  def validate_key!(module, "", :transition) do
    ConfigSchema.warn_once(:tenant_key, module, fn -> empty_key_message(module) end)
    ""
  end

  def validate_key!(module, key, _mode) do
    raise ArgumentError,
          "#{inspect(module)}.to_key/1 returned " <>
            "#{inspect(key, limit: 3, printable_limit: 64)}, which is not a binary. " <>
            "An AuroraMeter.Tenant implementation returns a non-empty String.t(); it is " <>
            "the key for every counter row, every ETS entry and every PubSub topic."
  end

  @spec empty_key_message(module()) :: String.t()
  defp empty_key_message(module) do
    "#{inspect(module)}.to_key/1 returned an empty tenant key. Every tenant it cannot " <>
      "resolve then shares one set of counters. Return a non-empty String.t(), or refuse " <>
      "the term. This version keeps the old behaviour and warns once per node; Aurora " <>
      "Meter 1.0 raises. See the AuroraMeter.Tenant documentation."
  end
end

defmodule AuroraMeter.Tenant.Default do
  @moduledoc """
  Default tenant resolver: passes binaries through and stringifies anything that
  implements `String.Chars` (integers, atoms, …). A term without `String.Chars`
  raises `Protocol.UndefinedError`; configure a custom `AuroraMeter.Tenant`
  implementation for structs.
  """

  @behaviour AuroraMeter.Tenant

  @impl AuroraMeter.Tenant
  @spec to_key(term()) :: String.t()
  def to_key(tenant) when is_binary(tenant), do: tenant
  def to_key(tenant), do: to_string(tenant)
end
