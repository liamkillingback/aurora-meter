defmodule AuroraMeter.Bench.MemoryStorage do
  @moduledoc false

  # An `AuroraMeter.Storage` that holds one subscription in `:persistent_term`
  # and knows nothing else.
  #
  # It exists so the `reserve` and `with_quota` micro modes can measure the
  # entitlement arithmetic with **no database anywhere in the path**. Every
  # counter read answers `nil` (a cold key seeds at zero) and every callback
  # that would need durable state raises, loudly and by name, rather than
  # answering a plausible empty value: a micro mode that silently reached a
  # storage callback would be measuring something other than its own name.
  #
  # The clause for every remaining callback is generated from
  # `AuroraMeter.Storage.behaviour_info(:callbacks)`, so a callback added to the
  # behaviour later is refused the day it is added rather than when somebody
  # remembers this file. `AuroraMeter.Test.RefusingStorage` uses the same
  # construction for the same reason.

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Schema.Subscription

  @key {__MODULE__, :subscription}

  @doc "Installs the single subscription every tenant resolves to."
  @spec put_plan(atom()) :: :ok
  def put_plan(plan_id) when is_atom(plan_id) do
    :persistent_term.put(@key, %Subscription{
      tenant_key: "bench",
      plan_id: to_string(plan_id),
      plan_version: nil,
      status: "active"
    })
  end

  @doc "Forgets the installed subscription."
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end

  @impl AuroraMeter.Storage
  def get_subscription(tenant_key) do
    case :persistent_term.get(@key, nil) do
      nil -> nil
      subscription -> %{subscription | tenant_key: tenant_key}
    end
  end

  @impl AuroraMeter.Storage
  def load_counter(_tenant_key, _feature, _period_start), do: nil

  @impl AuroraMeter.Storage
  def load_history(_tenant_key, _feature, _date), do: nil

  @impl AuroraMeter.Storage
  def load_history_range(_tenant_key, _feature, _from, _to), do: []

  @impl AuroraMeter.Storage
  def capabilities, do: []

  @refused [
    get_subscription: 1,
    load_counter: 3,
    load_history: 3,
    load_history_range: 4,
    capabilities: 0
  ]

  for {name, arity} <- AuroraMeter.Storage.behaviour_info(:callbacks),
      {name, arity} not in @refused do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl AuroraMeter.Storage
    def unquote(name)(unquote_splicing(args)) do
      raise "AuroraMeter.Bench.MemoryStorage has no #{unquote(name)}/#{unquote(arity)}: a " <>
              "micro bench mode reached durable storage, which means it is no longer " <>
              "measuring the in-memory path its `kind` claims"
    end
  end
end
