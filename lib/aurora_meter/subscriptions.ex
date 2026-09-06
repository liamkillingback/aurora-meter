defmodule AuroraMeter.Subscriptions do
  @moduledoc """
  Cached subscription lookups.

  Resolving a tenant's plan on every `check/2` or `reserve/3` would otherwise
  cost one database query per request. `get/1` memoises the storage lookup in
  ETS for `:subscription_cache_ttl` milliseconds (default 5s, `0` disables), and
  every write through `AuroraMeter.Storage.put_subscription/1` evicts the entry
  locally and broadcasts the eviction over PubSub so other nodes drop it too.

  The cache is transparent: it only ever holds what storage returned.
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Store
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  @doc """
  Returns the tenant's subscription (or `nil`), served from the cache when warm.

  ## Examples

      iex> AuroraMeter.Subscriptions.get("nobody_#{System.unique_integer([:positive])}")
      nil

  """
  @spec get(term()) :: Subscription.t() | nil
  def get(tenant) do
    key = Tenant.to_key(tenant)
    ttl = Config.subscription_cache_ttl()
    table = Store.subscription_cache_table()

    if ttl == 0 or :ets.whereis(table) == :undefined do
      Storage.get_subscription(key)
    else
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(table, key) do
        [{^key, subscription, expires_at}] when expires_at > now ->
          subscription

        _cold ->
          subscription = Storage.get_subscription(key)
          :ets.insert(table, {key, subscription, now + ttl})
          subscription
      end
    end
  end

  @doc """
  Drops the cached subscription for `tenant` on this node and announces the
  change so every other node drops it as well.

  ## Examples

      iex> AuroraMeter.Subscriptions.invalidate("org_1")
      :ok

  """
  @spec invalidate(term()) :: :ok
  def invalidate(tenant) do
    key = Tenant.to_key(tenant)
    table = Store.subscription_cache_table()

    if :ets.whereis(table) != :undefined, do: :ets.delete(table, key)

    PubSub.broadcast(
      Config.pubsub(),
      Store.invalidation_topic(),
      {:aurora_meter, :subscription_changed, key}
    )

    :ok
  end
end
