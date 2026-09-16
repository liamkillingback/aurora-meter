defmodule AuroraMeter.LiveView do
  @moduledoc """
  Helpers for consuming live usage and credit updates in a LiveView (or any
  process).

  **These helpers take no authorization decision.** They subscribe the calling
  process to the topics of whatever tenant they are given, and which tenant a
  socket may see is permanently the host's question. Resolve it from the
  session, or from an assign an earlier `on_mount` set from the session, and
  never from `params`: a tenant read from the URL is an IDOR with a topic
  subscription attached.

      # In your own on_mount, or in mount/3, from the session and not the params.
      def mount(_params, session, socket) do
        org = MyApp.Accounts.org_for_session!(session)
        if connected?(socket), do: AuroraMeter.LiveView.subscribe(org)
        {:ok, assign(socket, org: org)}
      end

      def handle_info({:aurora_meter, :usage, %{feature: feature, value: value}}, socket) do
        {:noreply, update_meter(socket, feature, value)}
      end

  The two-mount lifecycle matters. LiveView mounts twice, once for the static
  render with `connected?(socket) == false` and once for the socket. Subscribe
  only on the connected mount: the static mount has no channel to deliver to,
  and subscribing on both registers twice. A LiveView process that exits has its
  registrations reaped by the PubSub registry, so there is nothing to undo in
  `terminate/2`.

  ## The contract

  `subscribe/1` subscribes to one topic, the tenant's usage topic, exactly as it
  did in 0.4.0. `subscribe/2` opts into the credits topic as well.

  **Topics.** `AuroraMeter.Broadcaster.topic/1` of the resolved tenant key,
  which is `"aurora_meter:tenant:" <> tenant_key`, and
  `AuroraMeter.Credits.topic/1`, which is `"aurora_meter:credits:" <>
  tenant_key`. Build them with `topics/1` or with those functions rather than
  with string concatenation of your own: the prefix is part of the supported
  API, the way it is assembled is not.

  **Messages.** On the usage topic:

      {:aurora_meter, :usage, %{tenant_key: String.t(), feature: atom(),
                                value: integer(), period_start: DateTime.t()}}

  and, for a feature whose source is `:events`, `{:aurora_meter, :event, ...}`;
  plan transitions arrive as `{:aurora_meter, :plan_transition, ...}`. On the
  credits topic, `{:aurora_meter, :credits, ...}` and
  `{:aurora_meter, :low_balance, ...}`.

  One usage message per touched counter per tick, at most one tick every
  `:broadcast_interval` milliseconds (1000 by default). Match on the keys you
  need: the payload map gains keys additively across releases, so a match on
  the whole map will break where a match on three keys will not.

  Three properties worth knowing before you render the number.

    * **`value` includes units this node has reserved but not yet committed.**
      A `reserve/3` or `with_quota/4` call occupies quota immediately, and the
      broadcast reflects the counter as the entitlement check sees it. A meter
      can therefore tick up and then stay put when the reserved work commits.
    * **`value` is this node's converged view, not a database read.** With
      `cluster_sync: true` (the default) the broadcast is node-local, so a
      browser connected to node B sees node B's view; other nodes' increments
      arrive within one `:broadcast_interval`, and a flush re-bases every node
      on the database total within one `:flush_interval`.
    * **A day-bucket counter is never broadcast.** Only period counters are.
      Use `AuroraMeter.history/3` for the daily series.

  ## Switching tenant

  `switch_tenant/2` moves a live socket from one tenant to another, unsubscribing
  exactly the topic set it subscribed. `Phoenix.PubSub.unsubscribe/2` stops
  routing but does not empty a mailbox, so a message broadcast a moment before
  can still be delivered after the switch. That is why the usage payload carries
  `tenant_key` and why `handle_usage/2` and `handle_credits/2` drop a message
  whose key is not the socket's. A host matching the raw messages itself should
  compare `tenant_key` for the same reason.

  ## Compiled surface

  `subscribe/1,2`, `unsubscribe/1,2` and `topics/1` need no LiveView and are
  always compiled; a headless host gets them. `on_mount/4`, `switch_tenant/2`,
  `handle_usage/2` and `handle_credits/2` are compiled only when
  `Phoenix.LiveView` was available at the moment `aurora_meter` itself was
  compiled. A host that adds LiveView afterwards needs
  `mix deps.compile aurora_meter --force`; `mix aurora_meter.install
  --check-support` reports the mismatch.

  History day buckets and the cluster gossip topic are internal.
  """

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Config
  alias AuroraMeter.Credits
  alias AuroraMeter.Tenant
  alias Phoenix.PubSub

  @typedoc "A topic family this module can subscribe to."
  @type topic_name :: :usage | :credits

  @default_topics [:usage]
  @known_topics [:usage, :credits]

  @doc """
  Subscribes the calling process to `tenant`'s live usage updates.

  One topic, the usage topic, unchanged since 0.1.0. Use `subscribe/2` to add
  the credits topic.
  """
  @spec subscribe(term()) :: :ok | {:error, term()}
  def subscribe(tenant), do: subscribe(tenant, [])

  @doc """
  Subscribes the calling process to `tenant`'s topics.

  `opts[:topics]` is a subset of `#{inspect(@known_topics)}` and defaults to
  `#{inspect(@default_topics)}`, which is what `subscribe/1` does.

      AuroraMeter.LiveView.subscribe(org, topics: [:usage, :credits])

  Returns `:ok`, or the first `{:error, reason}` a `Phoenix.PubSub.subscribe/2`
  returned, having first unsubscribed anything it had already subscribed in the
  same call. A partial failure therefore leaves no partial subscription.

  Raises `ArgumentError` when `tenant` is `nil` or when `opts[:topics]` names a
  topic this module does not know.
  """
  @spec subscribe(term(), keyword()) :: :ok | {:error, term()}
  def subscribe(tenant, opts) when is_list(opts) do
    key = resolve_key!(tenant, "subscribe/2")
    names = topic_names!(opts)

    do_subscribe(key, names, [])
  end

  @doc """
  Unsubscribes the calling process from `tenant`'s live usage updates.
  """
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(tenant), do: unsubscribe(tenant, [])

  @doc """
  Unsubscribes the calling process from `tenant`'s topics.

  Takes the same `:topics` option as `subscribe/2`. Unsubscribing from a topic
  the process never subscribed to is not an error.

  Routing stops when this returns; messages already in the mailbox are still
  delivered, so a caller that cares filters on `tenant_key`.
  """
  @spec unsubscribe(term(), keyword()) :: :ok
  def unsubscribe(tenant, opts) when is_list(opts) do
    key = resolve_key!(tenant, "unsubscribe/2")

    Enum.each(topic_names!(opts), &PubSub.unsubscribe(Config.pubsub(), topic_for(key, &1)))
  end

  @doc """
  The canonical topic strings for `tenant`, as a keyword list.

      iex> [usage: usage] = AuroraMeter.LiveView.topics("org_1")
      iex> usage
      "aurora_meter:tenant:org_1"

  For a host that runs its own `Phoenix.PubSub.subscribe/2` and still wants the
  supported topic names. Takes the same `:topics` option as `subscribe/2`.
  """
  @spec topics(term(), keyword()) :: [{topic_name(), String.t()}]
  def topics(tenant, opts \\ []) when is_list(opts) do
    key = resolve_key!(tenant, "topics/2")

    Enum.map(topic_names!(opts), &{&1, topic_for(key, &1)})
  end

  @spec do_subscribe(String.t(), [topic_name()], [topic_name()]) :: :ok | {:error, term()}
  defp do_subscribe(_key, [], _done), do: :ok

  defp do_subscribe(key, [name | rest], done) do
    case PubSub.subscribe(Config.pubsub(), topic_for(key, name)) do
      :ok ->
        do_subscribe(key, rest, [name | done])

      {:error, reason} ->
        # Roll back what this call subscribed, so a caller that retries does not
        # accumulate registrations and a caller that gives up leaves none.
        Enum.each(done, &PubSub.unsubscribe(Config.pubsub(), topic_for(key, &1)))
        {:error, reason}
    end
  end

  @spec topic_for(String.t(), topic_name()) :: String.t()
  defp topic_for(key, :usage), do: Broadcaster.topic(key)
  defp topic_for(key, :credits), do: Credits.topic(key)

  @spec topic_names!(keyword()) :: [topic_name()]
  defp topic_names!(opts) do
    names = Keyword.get(opts, :topics, @default_topics)

    cond do
      not is_list(names) ->
        raise ArgumentError,
              ":topics must be a list of #{inspect(@known_topics)}, got: #{inspect(names)}"

      names -- @known_topics != [] ->
        raise ArgumentError,
              ":topics must be a subset of #{inspect(@known_topics)}, got: #{inspect(names)}"

      true ->
        names
    end
  end

  # Every entry point resolves here, and `nil` is refused before
  # `AuroraMeter.Tenant.to_key/1` can see it. `AuroraMeter.Tenant.Default`
  # stringifies whatever it is given, so `nil` would become `""`, and in the
  # 0.5.x transition mode an empty key is a warning rather than a refusal
  # (`open-findings.md` C12). An unresolved tenant would then subscribe to the
  # empty-string tenant's topic: one topic shared by every host that failed to
  # resolve one. Refusing here does not depend on that transition ending.
  @spec resolve_key!(term(), String.t()) :: String.t()
  defp resolve_key!(nil, where) do
    raise ArgumentError,
          "AuroraMeter.LiveView.#{where} was given a nil tenant. A tenant that could not be " <>
            "resolved is not the default tenant: AuroraMeter.Tenant.Default.to_key/1 would " <>
            "map it to \"\" and every unresolved tenant would then share one topic. Resolve " <>
            "the tenant from the session before you subscribe, and refuse the mount when " <>
            "there is none."
  end

  defp resolve_key!(tenant, _where), do: Tenant.to_key(tenant)

  # `Phoenix.LiveView` is an optional dependency, so everything that needs a
  # `%Phoenix.LiveView.Socket{}` sits behind the same guard `components.ex` uses.
  # The functions above need none of it and stay outside, which is what keeps a
  # headless host's `subscribe/1` working.
  if Code.ensure_loaded?(Phoenix.LiveView) do
    @doc """
    An `on_mount` hook that resolves the tenant, assigns it and subscribes.

    Three argument forms, all resolved at mount:

    | Form | Resolver |
    |---|---|
    | `{AuroraMeter.LiveView, {:subscribe, fun}}` | `fun.(session, socket)` |
    | `{AuroraMeter.LiveView, {:subscribe, assign: :current_org}}` | `socket.assigns[:current_org]`, set by an earlier hook in the same `live_session` |
    | `{AuroraMeter.LiveView, :subscribe}` | the `:live_view_tenant` config key, a `{module, function}` pair called with `(session, socket)` |

    Any of them may carry options, for example
    `{:subscribe, [assign: :current_org, topics: [:usage, :credits]]}`.

    The hook assigns `:aurora_meter_tenant`, `:aurora_meter_tenant_key` and
    `:aurora_meter_topics`, and subscribes only when `connected?(socket)`.

    When the resolver returns `nil` the hook returns `{:halt, socket}` with
    `:aurora_meter_denial` assigned as `:missing_tenant`, and subscribes to
    nothing. It does not redirect: it does not know your login route, and
    guessing one is worse than letting your own `on_mount` chain decide. Put
    your authentication hook before this one and it will never see a `nil`.

    The bare `:subscribe` form raises `ArgumentError` when `:live_view_tenant`
    is unset, rather than falling back to anything. A fallback here either
    subscribes to the empty-string tenant or silently subscribes to nothing,
    and both are worse than a mount-time error naming the fix.
    """
    @spec on_mount(term(), map(), map(), Phoenix.LiveView.Socket.t()) ::
            {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
    def on_mount(name, _params, session, socket) do
      {resolver, opts} = mount_spec!(name)

      case resolve_mount_tenant(resolver, session, socket) do
        nil ->
          {:halt, Phoenix.Component.assign(socket, :aurora_meter_denial, :missing_tenant)}

        tenant ->
          {:cont, assign_and_subscribe(socket, tenant, topic_names!(opts))}
      end
    end

    @doc """
    Moves a mounted socket from its current tenant to `tenant`.

    Unsubscribes exactly the topics recorded in `:aurora_meter_topics`, for the
    old key, then subscribes the same set for the new one, then re-assigns
    `:aurora_meter_tenant`, `:aurora_meter_tenant_key` and
    `:aurora_meter_topics`. On a socket that is not connected it only
    re-assigns, because nothing was subscribed.

    Returns the socket unchanged when the resolved key is the one the socket
    already holds, so a re-render that calls it is neither a duplicate
    registration nor a gap in delivery.

    Raises `ArgumentError` on a `nil` tenant, for `subscribe/2`'s reason.
    """
    @spec switch_tenant(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
    def switch_tenant(socket, tenant) do
      key = resolve_key!(tenant, "switch_tenant/2")
      names = socket_topics(socket)

      if key == socket.assigns[:aurora_meter_tenant_key] do
        socket
      else
        if Phoenix.LiveView.connected?(socket) do
          unsubscribe_key(socket.assigns[:aurora_meter_tenant_key], names)
          do_subscribe(key, names, [])
        end

        assign_tenant(socket, tenant, key, names)
      end
    end

    @doc """
    Folds a `{:aurora_meter, :usage, ...}` message into
    `socket.assigns.aurora_meter_usage`, a
    `%{feature => %{value: integer(), period_start: DateTime.t()}}` map.

    Message first, to match `handle_info/2`:

        def handle_info({:aurora_meter, :usage, _} = message, socket) do
          {:noreply, AuroraMeter.LiveView.handle_usage(message, socket)}
        end

    A message whose `tenant_key` is not the socket's is dropped and the socket
    returned unchanged. That is the whole reason the key is on the payload: see
    "Switching tenant" above.

    Entirely optional. Matching the raw message yourself is fully supported and
    is what `docs/phoenix.md` shows first.
    """
    @spec handle_usage(term(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
    def handle_usage({:aurora_meter, :usage, %{tenant_key: key} = payload}, socket) do
      if key == socket.assigns[:aurora_meter_tenant_key] do
        entry = %{value: payload[:value], period_start: payload[:period_start]}
        usage = Map.put(socket.assigns[:aurora_meter_usage] || %{}, payload[:feature], entry)
        Phoenix.Component.assign(socket, :aurora_meter_usage, usage)
      else
        socket
      end
    end

    def handle_usage(_other, socket), do: socket

    @doc """
    Folds a `{:aurora_meter, :credits, ...}` or `{:aurora_meter, :low_balance, ...}`
    message into `socket.assigns.aurora_meter_credits`.

    The assign is the last credits payload with a `:low_balance` boolean beside
    it, set `true` by a low-balance message and cleared by the next credits
    message that carries an `available` at or above the threshold that fired.
    A message whose `tenant_key` is not the socket's is dropped.
    """
    @spec handle_credits(term(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
    def handle_credits({:aurora_meter, :credits, %{tenant_key: key} = payload}, socket) do
      update_credits(socket, key, fn current ->
        threshold = current[:low_balance_threshold]
        available = payload[:available]

        payload
        |> Map.put(:low_balance, low_balance?(threshold, available))
        |> Map.put(:low_balance_threshold, threshold)
      end)
    end

    def handle_credits({:aurora_meter, :low_balance, %{tenant_key: key} = payload}, socket) do
      update_credits(socket, key, fn current ->
        current
        |> Map.merge(Map.take(payload, [:available, :spendable]))
        |> Map.put(:low_balance, true)
        |> Map.put(:low_balance_threshold, payload[:threshold])
      end)
    end

    def handle_credits(_other, socket), do: socket

    @spec low_balance?(term(), term()) :: boolean()
    defp low_balance?(threshold, available)
         when is_integer(threshold) and is_integer(available),
         do: available < threshold

    defp low_balance?(_threshold, _available), do: false

    @spec update_credits(Phoenix.LiveView.Socket.t(), String.t(), (map() -> map())) ::
            Phoenix.LiveView.Socket.t()
    defp update_credits(socket, key, fun) do
      if key == socket.assigns[:aurora_meter_tenant_key] do
        current = socket.assigns[:aurora_meter_credits] || %{}
        Phoenix.Component.assign(socket, :aurora_meter_credits, fun.(current))
      else
        socket
      end
    end

    @spec assign_and_subscribe(Phoenix.LiveView.Socket.t(), term(), [topic_name()]) ::
            Phoenix.LiveView.Socket.t()
    defp assign_and_subscribe(socket, tenant, names) do
      key = resolve_key!(tenant, "on_mount/4")

      # L09a-2: the static mount assigns and does not subscribe. Subscribing on
      # both mounts registers twice for one socket.
      if Phoenix.LiveView.connected?(socket), do: do_subscribe(key, names, [])

      assign_tenant(socket, tenant, key, names)
    end

    @spec assign_tenant(Phoenix.LiveView.Socket.t(), term(), String.t(), [topic_name()]) ::
            Phoenix.LiveView.Socket.t()
    defp assign_tenant(socket, tenant, key, names) do
      Phoenix.Component.assign(socket,
        aurora_meter_tenant: tenant,
        aurora_meter_tenant_key: key,
        aurora_meter_topics: names
      )
    end

    # L09a-3: unsubscribe exactly what was subscribed, for the key it was
    # subscribed under. Reading the topic set from the socket rather than from
    # the options means a host that subscribed one set never has another
    # unsubscribed out from under it.
    @spec socket_topics(Phoenix.LiveView.Socket.t()) :: [topic_name()]
    defp socket_topics(socket), do: socket.assigns[:aurora_meter_topics] || @default_topics

    @spec unsubscribe_key(String.t() | nil, [topic_name()]) :: :ok
    defp unsubscribe_key(nil, _names), do: :ok

    defp unsubscribe_key(key, names),
      do: Enum.each(names, &PubSub.unsubscribe(Config.pubsub(), topic_for(key, &1)))

    @spec mount_spec!(term()) :: {term(), keyword()}
    defp mount_spec!(:subscribe), do: {:config, []}
    defp mount_spec!({:subscribe, fun}) when is_function(fun, 2), do: {fun, []}

    defp mount_spec!({:subscribe, opts}) when is_list(opts) do
      case Keyword.fetch(opts, :assign) do
        {:ok, name} when is_atom(name) ->
          {{:assign, name}, opts}

        :error ->
          {:config, opts}

        {:ok, other} ->
          raise ArgumentError,
                "on_mount {AuroraMeter.LiveView, {:subscribe, assign: name}} needs an atom " <>
                  "assign name, got: #{inspect(other)}"
      end
    end

    defp mount_spec!(other) do
      raise ArgumentError,
            "AuroraMeter.LiveView.on_mount/4 does not know #{inspect(other)}. Use " <>
              "{AuroraMeter.LiveView, :subscribe}, " <>
              "{AuroraMeter.LiveView, {:subscribe, fun_of_arity_2}} or " <>
              "{AuroraMeter.LiveView, {:subscribe, assign: :current_org}}."
    end

    @spec resolve_mount_tenant(term(), map(), Phoenix.LiveView.Socket.t()) :: term()
    defp resolve_mount_tenant(fun, session, socket) when is_function(fun, 2),
      do: fun.(session, socket)

    defp resolve_mount_tenant({:assign, name}, _session, socket), do: socket.assigns[name]

    defp resolve_mount_tenant(:config, session, socket) do
      case Config.live_view_tenant() do
        {module, function} -> apply(module, function, [session, socket])
        nil -> raise ArgumentError, missing_live_view_tenant_message()
      end
    end

    @spec missing_live_view_tenant_message() :: String.t()
    defp missing_live_view_tenant_message do
      "on_mount {AuroraMeter.LiveView, :subscribe} needs the :live_view_tenant " <>
        "configuration key, and it is unset:\n\n" <>
        "    config :aurora_meter, live_view_tenant: {MyApp.Accounts, :org_for_session}\n\n" <>
        "The function is called with (session, socket) and returns the tenant term or nil. " <>
        "There is no default resolver on purpose: AuroraMeter.Tenant.Default.to_key/1 maps " <>
        "nil to \"\", so a fallback would put every unresolved tenant on one set of " <>
        "counters. Pass a resolver at the mount instead if you prefer:\n\n" <>
        "    on_mount {AuroraMeter.LiveView, {:subscribe, &MyApp.Accounts.org_for/2}}\n" <>
        "    on_mount {AuroraMeter.LiveView, {:subscribe, assign: :current_org}}\n"
    end
  end
end
