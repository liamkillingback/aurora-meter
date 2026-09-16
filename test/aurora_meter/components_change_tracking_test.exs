# Compiled only when Phoenix.LiveViewTest is available, the same guard
# lib/aurora_meter/components.ex uses on Phoenix.Component, so the headless CI
# leg (AURORA_HEADLESS=1) can still compile its suite.
if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule AuroraMeter.ComponentsChangeTrackingTest do
    @moduledoc """
    `usage_meter/1` under LiveView change tracking (repair unit R6,
    `open-findings.md` X379).

    **What was wrong, and why every existing test was green while it was.**
    `usage_meter/1` called `AuroraMeter.quota/2` inside itself, so its output
    depended on data that was not in its assigns. LiveView re-renders a function
    component only when the assigns handed to it changed; a tenant key and a
    feature name do not change when usage does, so a socket that was subscribed
    correctly, received the broadcast and re-rendered still showed the figure
    read at the first render. Not a bar that lags: a bar that never moves again.

    `components_test.exs` and `realtime_test.exs` render through
    `render_component/2`, which renders once, from scratch, with no change
    tracking at all. They could not see this and cannot: **a component that
    reads the world behind change tracking's back renders perfectly every time
    it is rendered.** The defect is in what is NOT rendered.

    So these tests do not call `render_component/2`. They render a parent
    template twice, the way a LiveView does: once for the first paint, and once
    with `__changed__` naming only what moved. The second render's `dynamic`
    list is what the diff carries to the browser, and a part that comes back
    `nil` is a part the browser is told nothing about and therefore keeps. That
    list is the assertion, because it is the thing the browser acts on.
    """
    use AuroraMeter.DataCase, async: false

    import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

    alias AuroraMeter.LiveView, as: AuroraLiveView

    # Two parents that differ in exactly one thing: which form of the component
    # they use. Same tenant, same feature, same tick, same everything else.
    defmodule Parent do
      @moduledoc false
      use Phoenix.Component

      import AuroraMeter.Components

      # The snapshot form. Its assigns are a tenant and a feature name.
      def by_tenant(assigns) do
        ~H"""
        <span id="tick">{@tick}</span>
        <.usage_meter tenant={@tenant} feature={:ai_generations} />
        """
      end

      # The live form. Its assign is the number itself.
      def by_quota(assigns) do
        ~H"""
        <span id="tick">{@tick}</span>
        <.usage_meter quota={@quota} />
        """
      end

      def summary_by_quotas(assigns) do
        ~H"""
        <span id="tick">{@tick}</span>
        <.usage_summary quotas={@quotas} />
        """
      end
    end

    setup do
      tenant = unique_tenant("ctrack")
      {:ok, _} = AuroraMeter.subscribe(tenant, :free)
      :ok = AuroraMeter.track(tenant, :ai_generations, 1)
      %{tenant: tenant}
    end

    test "X379 the meter moves when usage moves, with no cache-busting attribute in sight", %{
      tenant: tenant
    } do
      # First paint: one generation used, out of the free plan's 50.
      quota = AuroraMeter.quota(tenant, :ai_generations)
      first = Parent.by_quota(%{tick: 0, quota: quota, __changed__: nil})
      assert rendered_to_string(first) =~ "1 / 50"

      # Usage moves, and the socket does what `docs/phoenix.md` tells it to:
      # it re-reads the quota into the assign. Nothing else about the page
      # changes, and there is no attribute here whose only job is to be
      # different.
      :ok = AuroraMeter.track(tenant, :ai_generations, 2)
      moved = AuroraMeter.quota(tenant, :ai_generations)
      assert moved.used == 3

      second =
        Parent.by_quota(%{
          tick: 1,
          quota: moved,
          __changed__: %{tick: true, quota: true}
        })

      # **What the browser is sent.** The meter's part is present and carries
      # the new figure, so the page the customer is looking at now reads 3.
      assert meter_part(second) =~ "3 / 50"
      assert meter_part(second) =~ ~s(aria-valuenow="3")
    end

    test "X379 the snapshot form sends the browser nothing when usage moves", %{tenant: tenant} do
      # **The discrimination, and the defect exactly as 09c found it.** Same
      # page, same broadcast, same re-render; the only difference is that the
      # component is given a tenant instead of a number.
      first = Parent.by_tenant(%{tick: 0, tenant: tenant, __changed__: nil})
      assert rendered_to_string(first) =~ "1 / 50"

      :ok = AuroraMeter.track(tenant, :ai_generations, 2)
      assert AuroraMeter.quota(tenant, :ai_generations).used == 3

      second = Parent.by_tenant(%{tick: 1, tenant: tenant, __changed__: %{tick: true}})

      # The tick moved, so the page really did re-render: without this the test
      # would pass just as happily against a page that rendered nothing at all.
      assert tick_part(second) == "1"

      # And the meter's part is `nil`: nothing is sent for it, so the browser
      # keeps "1 / 50" while the real figure is 3. That is the behaviour the
      # `@doc` describes and the reason `quota` exists.
      assert is_nil(part(second, 1)),
             "the snapshot form sent an update; if that is now true, the doc on " <>
               "usage_meter/1 and this test are both out of date"
    end

    test "X379 a quota that did not move sends nothing, so the live form is not a re-render on every tick",
         %{tenant: tenant} do
      # The other half of the live form's claim. Passing the quota must not mean
      # the meter is rebuilt on every unrelated assign change: when usage has
      # not moved, the quota map is equal and change tracking skips it. A fix
      # that simply defeated change tracking would fail here.
      quota = AuroraMeter.quota(tenant, :ai_generations)
      _first = Parent.by_quota(%{tick: 0, quota: quota, __changed__: nil})

      same = Parent.by_quota(%{tick: 1, quota: quota, __changed__: %{tick: true}})
      assert tick_part(same) == "1"
      assert is_nil(part(same, 1))
    end

    test "X379 usage_summary moves the same way, and for the same reason", %{tenant: tenant} do
      quotas = AuroraLiveView.quotas(tenant)
      first = Parent.summary_by_quotas(%{tick: 0, quotas: quotas, __changed__: nil})
      assert rendered_to_string(first) =~ "1 / 50"

      :ok = AuroraMeter.track(tenant, :ai_generations, 2)
      moved = AuroraLiveView.quotas(tenant)

      second =
        Parent.summary_by_quotas(%{
          tick: 1,
          quotas: moved,
          __changed__: %{tick: true, quotas: true}
        })

      assert meter_part(second) =~ "3 / 50"
    end

    test "X379 the two forms are exclusive and an ambiguous call raises", %{tenant: tenant} do
      quota = AuroraMeter.quota(tenant, :ai_generations)

      assert_raise ArgumentError, ~r/quota=\{@quota\}/, fn ->
        rendered_to_string(AuroraMeter.Components.usage_meter(%{__changed__: nil, rest: %{}}))
      end

      assert_raise ArgumentError, ~r/one form or the other/, fn ->
        rendered_to_string(
          AuroraMeter.Components.usage_meter(%{
            __changed__: nil,
            rest: %{},
            quota: quota,
            tenant: tenant,
            feature: :ai_generations,
            label: nil
          })
        )
      end
    end

    # -- reading the diff the browser receives -----------------------------------

    # A `%Phoenix.LiveView.Rendered{}`'s `dynamic` is a function of
    # `track_changes?`. Called with `true` it returns one entry per dynamic part
    # of the template, and `nil` for every part LiveView decided did not change,
    # which is precisely the part the browser is sent nothing for.
    defp part(rendered, index), do: rendered.dynamic.(true) |> Enum.at(index)

    defp tick_part(rendered), do: rendered |> part(0) |> to_string()

    defp meter_part(rendered) do
      case part(rendered, 1) do
        nil -> nil
        other -> rendered_to_string(other)
      end
    end
  end
end
