# Compiled only when Phoenix.LiveViewTest is available, the same guard
# lib/aurora_meter/components.ex:1 uses on the module under test here.
# Without it the `headless` CI leg (AURORA_HEADLESS=1, build unit 01f)
# cannot compile its test suite at all, and invariant I20 ("optional
# integrations remain optional") could never be proved by running
# anything. phoenix_live_view is an optional dependency.
#
# The absence of this module on a headless build is asserted positively by
# test/aurora_meter/optional_deps_test.exs, so a guard that silently
# swallowed the whole suite would be caught.
if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule AuroraMeter.RealtimeTest do
    @moduledoc false
    use AuroraMeter.DataCase, async: false

    import Phoenix.LiveViewTest

    alias AuroraMeter.Broadcaster
    alias AuroraMeter.Components
    alias AuroraMeter.Credits
    alias AuroraMeter.LiveView

    test "usage_meter renders the value and progressbar semantics" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)
      AuroraMeter.track(tenant, :ai_generations, 10)

      html = render_component(&Components.usage_meter/1, tenant: tenant, feature: :ai_generations)

      assert html =~ ~s(role="progressbar")
      assert html =~ ~s(aria-valuenow="10")
      assert html =~ ~s(aria-valuemax="50")
      assert html =~ "10 / 50"
    end

    test "usage_summary renders a meter for each plan feature" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :free)

      html = render_component(&Components.usage_summary/1, tenant: tenant)

      assert html =~ "ai_generations"
      assert html =~ "api_access"
    end

    test "usage_meter renders a counter bare: a count, no bar, no percentage" do
      tenant = unique_tenant()
      AuroraMeter.subscribe(tenant, :payg)
      AuroraMeter.track(tenant, :requests, 6)

      html = render_component(&Components.usage_meter/1, tenant: tenant, feature: :requests)
      document = Floki.parse_fragment!(html)

      assert Floki.find(document, ".aurora-meter--counter") != []
      assert Floki.text(Floki.find(document, ".aurora-meter__value")) =~ "6"

      # No denominator means no bar and no "6 / 0".
      assert Floki.find(document, ".aurora-meter__bar") == []
      assert Floki.find(document, "[role=progressbar]") == []
      refute html =~ "/ 0"
      refute html =~ "over"
    end

    describe "spend_chart/1" do
      test "renders dollars, and a zero-spend day still gets a bar" do
        tenant = unique_tenant()
        {:ok, _} = Credits.grant(tenant, 20_000_000, reference: "pi_chart")
        {:ok, _} = Credits.debit(tenant, 420_000, "req:chart")

        points = Credits.spend_history(tenant, days: 4)
        html = render_component(&Components.spend_chart/1, points: points)
        document = Floki.parse_fragment!(html)

        # Dollars, never raw micro-dollars.
        assert Floki.text(document) =~ "$0.42"
        refute Floki.text(document) =~ "420000"

        bars = Floki.find(document, ".aurora-spend-chart__bar")
        assert length(bars) == 4

        # Every bar has a positive height: the three quiet days are a baseline,
        # not a gap in the chart.
        heights = Enum.map(bars, &(&1 |> Floki.attribute("height") |> hd() |> String.to_float()))
        assert Enum.all?(heights, &(&1 > 0))
        assert length(Floki.find(document, ".aurora-spend-chart__bar--zero")) == 3

        # Tooltips are <title> elements, in dollars, with no JavaScript.
        titles =
          document |> Floki.find(".aurora-spend-chart__bar title") |> Enum.map(&Floki.text/1)

        assert Enum.any?(titles, &(&1 =~ "$0.42 spent"))
        assert Enum.any?(titles, &(&1 =~ "$0.00 spent"))
        refute html =~ "<script"

        # The grant day is marked, in dollars.
        assert [marker] = Floki.find(document, ".aurora-spend-chart__grant")
        assert Floki.text(marker) =~ "$20.00"

        # The axis is labelled with the peak and the floor, both as money.
        assert Floki.text(Floki.find(document, ".aurora-spend-chart__axis-max")) == "$0.42"
        assert Floki.text(Floki.find(document, ".aurora-spend-chart__axis-min")) == "$0.00"
      end

      test "show_grants: false drops the markers but keeps every bar" do
        tenant = unique_tenant()
        {:ok, _} = Credits.grant(tenant, 5_000_000, reference: "pi_nomark")

        points = Credits.spend_history(tenant, days: 3)

        html = render_component(&Components.spend_chart/1, points: points, show_grants: false)
        document = Floki.parse_fragment!(html)

        assert Floki.find(document, ".aurora-spend-chart__grant") == []
        assert length(Floki.find(document, ".aurora-spend-chart__bar")) == 3
      end

      test "an empty series renders an empty state instead of a broken chart" do
        document = Floki.parse_fragment!(render_component(&Components.spend_chart/1, points: []))

        assert Floki.find(document, "svg") == []
        assert Floki.text(Floki.find(document, ".aurora-spend-chart__empty")) =~ "No spend yet"
      end

      test "carries no colour of its own, so it inherits the host's design system" do
        points = Credits.spend_history(unique_tenant(), days: 2)
        html = render_component(&Components.spend_chart/1, points: points)

        assert html =~ ~s(fill="currentColor")
        refute html =~ "#"
        refute html =~ "rgb("
        refute html =~ "style="
      end
    end

    describe "credit_summary/1" do
      test "renders every figure as dollars and shows nil burn and runway as a dash" do
        tenant = unique_tenant()
        {:ok, _} = Credits.grant(tenant, 20_000_000, reference: "pi_summary")

        html = render_component(&Components.credit_summary/1, summary: Credits.summary(tenant))
        document = Floki.parse_fragment!(html)
        text = Floki.text(document)

        assert text =~ "$20.00"
        refute text =~ "20000000"

        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--burn")) =~ "—"
        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--runway")) =~ "—"
      end

      test "shows held credit and a runway once there is spend" do
        tenant = unique_tenant()
        {:ok, _} = Credits.grant(tenant, 300_000_000, reference: "pi_burn")
        {:ok, _} = Credits.debit(tenant, 30_000_000, "req:burn")
        {:ok, _} = Credits.hold(tenant, 10_000_000, "job:burn")

        html = render_component(&Components.credit_summary/1, summary: Credits.summary(tenant))
        document = Floki.parse_fragment!(html)

        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--held")) =~ "$10.00"
        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--spent")) =~ "$30.00"

        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--burn")) =~
                 "$1.00 / day"

        assert Floki.text(Floki.find(document, ".aurora-credit-summary__item--runway")) =~
                 "260 days"
      end
    end

    test "the broadcaster fans usage out on the tenant topic" do
      tenant = unique_tenant()
      :ok = LiveView.subscribe(tenant)

      AuroraMeter.track(tenant, :ai_generations, 3)
      :ok = Broadcaster.broadcast_now()

      assert_receive {:aurora_meter, :usage, %{feature: :ai_generations, value: 3}}
    end
  end
end
