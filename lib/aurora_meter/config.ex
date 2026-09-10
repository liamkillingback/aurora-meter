defmodule AuroraMeter.Config do
  @moduledoc """
  Reads and validates Aurora Meter configuration from the `:aurora_meter`
  application environment.

  Configuration is validated once at boot by `validate!/0` (called from
  `AuroraMeter.start_link/1`), which fails fast on a missing required key or a
  wrong type. Typed accessors below return the effective value, applying defaults
  for optional keys.
  """

  @schema NimbleOptions.new!(
            repo: [type: :atom, required: true, doc: "The host Ecto repo."],
            pubsub: [type: :atom, required: true, doc: "The host `Phoenix.PubSub` server name."],
            plans: [type: :atom, required: true, doc: "A module that `use`s `AuroraMeter.Plans`."],
            tenant: [type: :atom, default: AuroraMeter.Tenant.Default],
            default_plan: [type: :atom, default: :free],
            storage: [type: :atom, default: AuroraMeter.Storage.Ecto],
            provider: [type: :atom, default: AuroraMeter.Billing.Noop],
            period_source: [type: :atom, default: AuroraMeter.Period.Calendar],
            durable_features: [type: {:list, :atom}, default: []],
            flush_interval: [type: :pos_integer, default: 5_000],
            broadcast_interval: [type: :pos_integer, default: 1_000],
            history: [
              type: :boolean,
              default: true,
              doc: "Maintain UTC day buckets for `AuroraMeter.history/3`."
            ],
            subscription_cache_ttl: [
              type: :non_neg_integer,
              default: 5_000,
              doc: "Milliseconds a subscription lookup is cached; 0 disables the cache."
            ],
            cluster_sync: [
              type: :boolean,
              default: true,
              doc:
                "Exchange counter deltas and flushed totals between nodes over PubSub " <>
                  "so every node converges on the cluster-wide value."
            ],
            credits_currency: [
              type: :string,
              default: "usd",
              doc: "ISO 4217 code stamped on new `AuroraMeter.Credits` balance rows."
            ],
            credits_overdraft_tolerance: [
              type: :non_neg_integer,
              default: 0,
              doc:
                "Micro-dollars a hold or debit may take the available balance below zero " <>
                  "before `:insufficient_credits`."
            ],
            credits_low_balance_threshold: [
              type: {:or, [:integer, nil]},
              default: nil,
              doc:
                "Micro-dollars; when the available balance drops below it the low-balance " <>
                  "event fires. A balance row's own threshold overrides it."
            ],
            credits_low_balance_handler: [
              type: {:or, [{:fun, 1}, nil]},
              default: nil,
              doc:
                "Called with `%{tenant_key, available, threshold}` after a low-balance " <>
                  "crossing commits (a place to email or to auto-recharge)."
            ]
          )

  @doc """
  Validates the current `:aurora_meter` configuration, raising on any problem.

  Returns the validated options (with defaults applied) on success.

  ## Examples

      iex> is_list(AuroraMeter.Config.validate!())
      true

  """
  @spec validate!() :: keyword()
  def validate! do
    :aurora_meter
    |> Application.get_all_env()
    |> Keyword.take(Keyword.keys(@schema.schema))
    |> NimbleOptions.validate!(@schema)
  end

  @doc "The configured host Ecto repo."
  @spec repo() :: module()
  def repo, do: Application.fetch_env!(:aurora_meter, :repo)

  @doc "The configured host `Phoenix.PubSub` server name."
  @spec pubsub() :: atom()
  def pubsub, do: Application.fetch_env!(:aurora_meter, :pubsub)

  @doc "The configured plans module."
  @spec plans() :: module()
  def plans, do: Application.fetch_env!(:aurora_meter, :plans)

  @doc "The configured tenant-resolution module."
  @spec tenant() :: module()
  def tenant, do: get(:tenant, AuroraMeter.Tenant.Default)

  @doc "The plan id used for tenants with no subscription."
  @spec default_plan() :: atom()
  def default_plan, do: get(:default_plan, :free)

  @doc "The configured storage adapter."
  @spec storage() :: module()
  def storage, do: get(:storage, AuroraMeter.Storage.Ecto)

  @doc "The configured billing provider."
  @spec provider() :: module()
  def provider, do: get(:provider, AuroraMeter.Billing.Noop)

  @doc "The configured period source."
  @spec period_source() :: module()
  def period_source, do: get(:period_source, AuroraMeter.Period.Calendar)

  @doc "Features that also write a durable event row on every `track`."
  @spec durable_features() :: [atom()]
  def durable_features, do: get(:durable_features, [])

  @doc "Milliseconds between durable flushes of dirty counters to the database."
  @spec flush_interval() :: pos_integer()
  def flush_interval, do: get(:flush_interval, 5_000)

  @doc "Milliseconds between live PubSub broadcasts of touched counters."
  @spec broadcast_interval() :: pos_integer()
  def broadcast_interval, do: get(:broadcast_interval, 1_000)

  @doc "Whether UTC day buckets are maintained for `AuroraMeter.history/3` (default `true`)."
  @spec history?() :: boolean()
  def history?, do: get(:history, true)

  @doc "Milliseconds a subscription lookup stays cached (default 5_000; `0` disables)."
  @spec subscription_cache_ttl() :: non_neg_integer()
  def subscription_cache_ttl, do: get(:subscription_cache_ttl, 5_000)

  @doc "Whether nodes exchange deltas and totals so counters are cluster-wide (default `true`)."
  @spec cluster_sync?() :: boolean()
  def cluster_sync?, do: get(:cluster_sync, true)

  @doc "Currency code for new credit balance rows (default `\"usd\"`)."
  @spec credits_currency() :: String.t()
  def credits_currency, do: get(:credits_currency, "usd")

  @doc "Micro-dollars the available credit balance may go below zero on a hold or debit (default `0`)."
  @spec credits_overdraft_tolerance() :: non_neg_integer()
  def credits_overdraft_tolerance, do: get(:credits_overdraft_tolerance, 0)

  @doc "Default low-balance threshold in micro-dollars, or `nil` for none."
  @spec credits_low_balance_threshold() :: integer() | nil
  def credits_low_balance_threshold, do: get(:credits_low_balance_threshold, nil)

  @doc "The low-balance callback (`fun/1`), or `nil`."
  @spec credits_low_balance_handler() :: (map() -> term()) | nil
  def credits_low_balance_handler, do: get(:credits_low_balance_handler, nil)

  @spec get(atom(), term()) :: term()
  defp get(key, default), do: Application.get_env(:aurora_meter, key, default)
end
