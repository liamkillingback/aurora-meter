# Compiled only when `Phoenix.LiveView` is, exactly like the half of
# `AuroraMeter.LiveView` most of this file exercises
# (`lib/aurora_meter/live_view.ex` puts `on_mount/4`, `switch_tenant/2`,
# `handle_usage/2` and `handle_credits/2` behind that guard). Without this, the
# `headless` leg (AURORA_HEADLESS=1) and the `plug_only` leg
# (AURORA_NO_LIVEVIEW=1) cannot compile the suite at all, and invariant I20
# could not be proved by running anything.
#
# The unguarded half of the module (`subscribe/1,2`, `unsubscribe/1,2`,
# `topics/1,2`) is exercised WITHOUT LiveView on both of those legs, by
# `AuroraMeter.HeadlessTest` and by
# `AuroraMeter.OptionalIntegrationsTest`'s AURORA_NO_LIVEVIEW branch, so a guard
# that silently swallowed everything would be caught rather than read as green.
if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule AuroraMeter.LiveViewTest do
    @moduledoc """
    Invariant I20, build unit 09a: the LiveView helpers are optional and
    tenant-safe.

    Every subscription assertion counts **registrations**, not received messages.
    A message that does not arrive is consistent with "not subscribed" and with
    "nothing was broadcast", and only one of those is what these tests are about;
    `Registry.lookup/2` on the PubSub registry answers the actual question, and it
    is also the only way to see a duplicate registration, which delivers exactly
    the same messages as a single one until the day it leaks.

    Browser-level coverage of these helpers (a real endpoint, a real router,
    `Phoenix.LiveViewTest`) belongs to build unit 09c's sample. This file builds
    `%Phoenix.LiveView.Socket{}` by hand, which is what `AuroraMeter.Pro`'s
    dashboard test does for the same reason: core adds no Phoenix endpoint.
    """
    use AuroraMeter.DataCase, async: false

    import AuroraMeter.Test.Config, only: [with_config: 2]

    alias AuroraMeter.Broadcaster
    alias AuroraMeter.Config
    alias AuroraMeter.Credits
    alias AuroraMeter.LiveView
    alias Phoenix.LiveView.Socket

    doctest AuroraMeter.LiveView, import: true

    # A resolver a host would write: from the session, never from the params.
    def org_from_session(session, _socket), do: session["org"]

    describe "subscribe/1 and subscribe/2" do
      test "I20 subscribe/1 still subscribes to the usage topic only" do
        # Byte-compatible with 0.4.0, and with aurora_api's single call site.
        tenant = unique_tenant()

        assert :ok = LiveView.subscribe(tenant)

        assert registrations(usage_topic(tenant)) == 1
        assert registrations(credits_topic(tenant)) == 0
      end

      test "I20 subscribe/2 with topics [:usage, :credits] registers on both" do
        tenant = unique_tenant()

        assert :ok = LiveView.subscribe(tenant, topics: [:usage, :credits])

        assert registrations(usage_topic(tenant)) == 1
        assert registrations(credits_topic(tenant)) == 1
      end

      test "I20 subscribe/2 receives both message families" do
        tenant = unique_tenant()
        {:ok, _subscription} = AuroraMeter.subscribe(tenant, :payg)
        :ok = LiveView.subscribe(tenant, topics: [:usage, :credits])

        :ok = AuroraMeter.track(tenant, :requests, 3)
        :ok = AuroraMeter.Test.broadcast!()
        assert_receive {:aurora_meter, :usage, %{feature: :requests, value: 3}}

        {:ok, _txn} = Credits.grant(tenant, 5_000, reference: "lv-#{tenant}")
        assert_receive {:aurora_meter, :credits, %{balance: 5_000}}
      end

      test "I20 subscribe/2 unsubscribes what it had subscribed when a later topic fails" do
        # `Phoenix.PubSub.subscribe/2` is spec'd `:ok | {:error, term()}` and
        # delegates to `Registry.register/3`. The local adapter's registry has
        # duplicate keys and therefore never fails, so the only honest way to
        # drive the partial-failure path through the real function is a registry
        # that can refuse: a `:unique` one, where registering a key this process
        # already holds returns `{:error, {:already_registered, pid}}`. A
        # non-local adapter can return an error for its own reasons, which is why
        # the rollback exists at all.
        registry = :"lv_unique_#{System.unique_integer([:positive])}"
        start_supervised!({Registry, keys: :unique, name: registry})

        tenant = unique_tenant()

        with_config([{:aurora_meter, :pubsub, registry}], fn ->
          # Take the credits key first, so the SECOND subscribe is the one that
          # fails and there is something to roll back.
          {:ok, _pid} = Registry.register(registry, credits_topic(tenant), nil)

          assert {:error, {:already_registered, _pid}} =
                   LiveView.subscribe(tenant, topics: [:usage, :credits])

          # The half that succeeded was given back. Without the rollback this is
          # 1, which is a partial subscription nobody asked for and nobody knows
          # about.
          assert Registry.lookup(registry, usage_topic(tenant)) == []
        end)
      end

      test "I20 subscribe refuses a nil tenant and registers nothing for the empty key" do
        assert_raise ArgumentError, ~r/nil tenant/, fn -> LiveView.subscribe(nil) end

        assert registrations(Broadcaster.topic("")) == 0
        assert registrations(Credits.topic("")) == 0
      end

      test "I20 subscribe refuses a topic it does not know" do
        assert_raise ArgumentError, ~r/:topics must be a subset/, fn ->
          LiveView.subscribe(unique_tenant(), topics: [:usage, :invoices])
        end
      end
    end

    describe "topics/2 and unsubscribe/2" do
      test "I20 topics/2 returns the canonical strings for both families" do
        tenant = unique_tenant()

        assert LiveView.topics(tenant) == [usage: Broadcaster.topic(tenant)]

        assert LiveView.topics(tenant, topics: [:usage, :credits]) == [
                 usage: Broadcaster.topic(tenant),
                 credits: Credits.topic(tenant)
               ]
      end

      test "I20 unsubscribe/2 stops delivery of both topic families" do
        tenant = unique_tenant()
        :ok = LiveView.subscribe(tenant, topics: [:usage, :credits])

        assert :ok = LiveView.unsubscribe(tenant, topics: [:usage, :credits])

        assert registrations(usage_topic(tenant)) == 0
        assert registrations(credits_topic(tenant)) == 0
      end

      test "I20 unsubscribe/1 leaves a credits subscription the caller did not name" do
        tenant = unique_tenant()
        :ok = LiveView.subscribe(tenant, topics: [:usage, :credits])

        assert :ok = LiveView.unsubscribe(tenant)

        assert registrations(usage_topic(tenant)) == 0
        assert registrations(credits_topic(tenant)) == 1
      end
    end

    describe "on_mount/4" do
      test "I20 on_mount with an explicit function resolver assigns the tenant and subscribes only when connected" do
        tenant = unique_tenant()
        session = %{"org" => tenant}
        hook = {:subscribe, &__MODULE__.org_from_session/2}

        {:cont, static} = LiveView.on_mount(hook, %{}, session, %Socket{})

        assert static.assigns.aurora_meter_tenant == tenant
        assert static.assigns.aurora_meter_tenant_key == tenant
        assert static.assigns.aurora_meter_topics == [:usage]
        assert registrations(usage_topic(tenant)) == 0, "the static mount subscribed"

        {:cont, live} = LiveView.on_mount(hook, %{}, session, connected_socket())

        assert live.assigns.aurora_meter_tenant_key == tenant
        assert registrations(usage_topic(tenant)) == 1
      end

      test "I20 on_mount with assign: :current_org reads the assign set by an earlier hook" do
        tenant = unique_tenant()

        socket =
          Phoenix.Component.assign(connected_socket(), :current_org, tenant)

        {:cont, socket} =
          LiveView.on_mount({:subscribe, [assign: :current_org]}, %{}, %{}, socket)

        assert socket.assigns.aurora_meter_tenant == tenant
        assert registrations(usage_topic(tenant)) == 1
      end

      test "I20 on_mount carries topics: through to the subscription" do
        tenant = unique_tenant()
        hook = {:subscribe, [assign: :current_org, topics: [:usage, :credits]]}
        socket = Phoenix.Component.assign(connected_socket(), :current_org, tenant)

        {:cont, socket} = LiveView.on_mount(hook, %{}, %{}, socket)

        assert socket.assigns.aurora_meter_topics == [:usage, :credits]
        assert registrations(usage_topic(tenant)) == 1
        assert registrations(credits_topic(tenant)) == 1
      end

      test "I20 on_mount halts with :missing_tenant when the resolver returns nil and never subscribes" do
        hook = {:subscribe, &__MODULE__.org_from_session/2}

        {:halt, socket} = LiveView.on_mount(hook, %{}, %{"org" => nil}, connected_socket())

        assert socket.assigns.aurora_meter_denial == :missing_tenant
        refute Map.has_key?(socket.assigns, :aurora_meter_tenant)
        assert registrations(Broadcaster.topic("")) == 0
      end

      test "I20 on_mount bare :subscribe without live_view_tenant raises ArgumentError naming the config key" do
        assert Config.live_view_tenant() == nil

        error =
          assert_raise ArgumentError, fn ->
            LiveView.on_mount(:subscribe, %{}, %{}, connected_socket())
          end

        message = Exception.message(error)

        assert message =~ "live_view_tenant"
        assert message =~ "{:subscribe, &MyApp.Accounts.org_for/2}"
        assert message =~ "{:subscribe, assign: :current_org}"
      end

      test "I20 on_mount bare :subscribe resolves through live_view_tenant when it is set" do
        # The positive control for the test above: the raise is a fact about the
        # key being unset, not about the bare form being broken.
        tenant = unique_tenant()

        with_config([{:aurora_meter, :live_view_tenant, {__MODULE__, :org_from_session}}], fn ->
          {:cont, socket} =
            LiveView.on_mount(:subscribe, %{}, %{"org" => tenant}, connected_socket())

          assert socket.assigns.aurora_meter_tenant == tenant
          assert registrations(usage_topic(tenant)) == 1
        end)
      end

      test "I20 on_mount refuses an argument shape it does not know" do
        # Through a list so the type checker cannot narrow the literal and warn
        # that this call can never match: the point of the test is what happens at
        # runtime when a host writes a hook name that does not exist.
        unknown = Enum.random([:resubscribe])

        assert_raise ArgumentError, ~r/does not know :resubscribe/, fn ->
          LiveView.on_mount(unknown, %{}, %{}, connected_socket())
        end
      end
    end

    describe "switch_tenant/2" do
      test "I20 switch_tenant unsubscribes the old topics and subscribes the new ones" do
        first = unique_tenant()
        second = unique_tenant()
        socket = mounted(first, topics: [:usage, :credits])

        switched = LiveView.switch_tenant(socket, second)

        assert switched.assigns.aurora_meter_tenant == second
        assert switched.assigns.aurora_meter_tenant_key == second
        assert switched.assigns.aurora_meter_topics == [:usage, :credits]

        assert registrations(usage_topic(first)) == 0
        assert registrations(credits_topic(first)) == 0
        assert registrations(usage_topic(second)) == 1
        assert registrations(credits_topic(second)) == 1
      end

      test "I20 switch_tenant with the same tenant is a no-op and does not duplicate the subscription" do
        tenant = unique_tenant()
        socket = mounted(tenant)

        same = LiveView.switch_tenant(socket, tenant)

        assert same == socket
        assert registrations(usage_topic(tenant)) == 1
      end

      test "I20 switch_tenant raises on a nil tenant and leaves the old subscription alone" do
        tenant = unique_tenant()
        socket = mounted(tenant)

        assert_raise ArgumentError, ~r/nil tenant/, fn -> LiveView.switch_tenant(socket, nil) end

        assert registrations(usage_topic(tenant)) == 1
        assert registrations(Broadcaster.topic("")) == 0
      end

      test "I20 switch_tenant on a disconnected socket only re-assigns" do
        first = unique_tenant()
        second = unique_tenant()

        {:cont, socket} =
          LiveView.on_mount(
            {:subscribe, &__MODULE__.org_from_session/2},
            %{},
            %{"org" => first},
            %Socket{}
          )

        switched = LiveView.switch_tenant(socket, second)

        assert switched.assigns.aurora_meter_tenant_key == second
        assert registrations(usage_topic(first)) == 0
        assert registrations(usage_topic(second)) == 0
      end
    end

    describe "handle_usage/2 and handle_credits/2" do
      test "I20 handle_usage records value and period_start per feature" do
        tenant = unique_tenant()
        socket = mounted(tenant)
        period = ~U[2026-09-01 00:00:00Z]

        socket = LiveView.handle_usage(usage_message(tenant, :requests, 4, period), socket)
        socket = LiveView.handle_usage(usage_message(tenant, :ai_generations, 9, period), socket)
        socket = LiveView.handle_usage(usage_message(tenant, :requests, 6, period), socket)

        assert socket.assigns.aurora_meter_usage == %{
                 requests: %{value: 6, period_start: period},
                 ai_generations: %{value: 9, period_start: period}
               }
      end

      test "I20 handle_usage drops a message whose tenant_key is not the socket's" do
        mine = unique_tenant()
        theirs = unique_tenant()
        socket = mounted(mine)

        kept = LiveView.handle_usage(usage_message(mine, :requests, 1, nil), socket)
        dropped = LiveView.handle_usage(usage_message(theirs, :requests, 999, nil), kept)

        assert dropped.assigns.aurora_meter_usage == %{requests: %{value: 1, period_start: nil}}
        refute mine == theirs
      end

      test "I20 a socket switched to a second tenant keeps only the second tenant's value" do
        # Acceptance criterion 7, and the reason `tenant_key` is on the payload at
        # all. `Phoenix.PubSub.unsubscribe/2` stops routing; it does not empty a
        # mailbox, so a message broadcast a moment before the switch is delivered
        # after it, and a usage value is an absolute total, so a stale one stays
        # on screen until that feature moves again.
        first = unique_tenant()
        second = unique_tenant()

        socket =
          first
          |> mounted()
          |> LiveView.switch_tenant(second)

        # The STALE one arrives LAST, which is the only ordering that tests
        # anything and is also the real one: the message was broadcast before
        # the switch and delivered after it. Written the other way round
        # (`first` then `second`) this test passed with the tenant filter
        # removed entirely, because the second message overwrote the first and
        # the expected value came out either way. Found by control
        # `c6-handle-usage-does-not-filter`, which is the whole reason the
        # controls are run (X287).
        socket = LiveView.handle_usage(usage_message(second, :requests, 222, nil), socket)
        socket = LiveView.handle_usage(usage_message(first, :requests, 111, nil), socket)

        assert socket.assigns.aurora_meter_usage == %{requests: %{value: 222, period_start: nil}}
      end

      test "I20 handle_credits drops a foreign tenant_key and records available, held and low_balance" do
        mine = unique_tenant()
        theirs = unique_tenant()
        socket = mounted(mine, topics: [:usage, :credits])

        socket =
          LiveView.handle_credits(
            {:aurora_meter, :credits,
             %{tenant_key: mine, balance: 900, held: 100, available: 800}},
            socket
          )

        assert socket.assigns.aurora_meter_credits.available == 800
        assert socket.assigns.aurora_meter_credits.held == 100
        assert socket.assigns.aurora_meter_credits.low_balance == false

        socket =
          LiveView.handle_credits(
            {:aurora_meter, :low_balance, %{tenant_key: mine, available: 800, threshold: 1_000}},
            socket
          )

        assert socket.assigns.aurora_meter_credits.low_balance == true

        foreign =
          LiveView.handle_credits(
            {:aurora_meter, :credits, %{tenant_key: theirs, balance: 1, held: 0, available: 1}},
            socket
          )

        assert foreign.assigns.aurora_meter_credits.available == 800
      end

      test "I20 a credits message back above the threshold clears low_balance" do
        tenant = unique_tenant()

        socket =
          LiveView.handle_credits(
            {:aurora_meter, :low_balance, %{tenant_key: tenant, available: 10, threshold: 1_000}},
            mounted(tenant, topics: [:usage, :credits])
          )

        assert socket.assigns.aurora_meter_credits.low_balance == true

        socket =
          LiveView.handle_credits(
            {:aurora_meter, :credits,
             %{tenant_key: tenant, balance: 5_000, held: 0, available: 5_000}},
            socket
          )

        assert socket.assigns.aurora_meter_credits.low_balance == false
      end

      test "I20 an unrelated message leaves the socket untouched" do
        socket = mounted(unique_tenant())

        assert LiveView.handle_usage({:aurora_meter, :event, %{}}, socket) == socket
        assert LiveView.handle_credits(:tick, socket) == socket
      end
    end

    defp connected_socket, do: %Socket{transport_pid: self()}

    defp mounted(tenant, opts \\ []) do
      hook = {:subscribe, Keyword.merge([assign: :current_org], opts)}
      socket = Phoenix.Component.assign(connected_socket(), :current_org, tenant)
      {:cont, socket} = LiveView.on_mount(hook, %{}, %{}, socket)
      socket
    end

    defp usage_message(tenant_key, feature, value, period_start) do
      {:aurora_meter, :usage,
       %{tenant_key: tenant_key, feature: feature, value: value, period_start: period_start}}
    end

    defp usage_topic(tenant), do: Broadcaster.topic(tenant)
    defp credits_topic(tenant), do: Credits.topic(tenant)

    # How many registrations this process holds on `topic`. Not "did a message
    # arrive": a duplicate registration delivers the same messages as a single
    # one, and only a count can see it.
    defp registrations(topic) do
      Config.pubsub()
      |> Registry.lookup(topic)
      |> Enum.count(fn {pid, _value} -> pid == self() end)
    end
  end
end
