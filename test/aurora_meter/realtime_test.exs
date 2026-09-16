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

    test "I20 every quota kind renders its own wording" do
      # One meter per kind that the plans DSL can produce, each asserted on the
      # wording it is supposed to use and on the wording belonging to another
      # kind that it must not. A meter that rendered the same sentence for all
      # five would pass a test that only checked the value was somewhere in the
      # page (ADR 0006).
      hard = unique_tenant("kind_hard")
      AuroraMeter.subscribe(hard, :free)
      AuroraMeter.track(hard, :ai_generations, 10)

      metered = unique_tenant("kind_metered")
      AuroraMeter.subscribe(metered, :scale)
      AuroraMeter.track(metered, :ai_generations, 1_200)

      counter = unique_tenant("kind_counter")
      AuroraMeter.subscribe(counter, :payg)
      AuroraMeter.track(counter, :requests, 7)

      # A hard cap: used over its limit, with a bar.
      hard_html =
        render_component(&Components.usage_meter/1, tenant: hard, feature: :ai_generations)

      assert hard_html =~ "aurora-meter--hard"
      assert hard_html =~ "10 / 50"
      assert hard_html =~ ~s(role="progressbar")
      refute hard_html =~ "over"

      # A metered feature: used over its included allowance, plus the overage.
      metered_html =
        render_component(&Components.usage_meter/1, tenant: metered, feature: :ai_generations)

      assert metered_html =~ "aurora-meter--metered"
      assert metered_html =~ "1200 / 1000"
      assert metered_html =~ "+200 over"

      # A counter: the bare count, no denominator and no bar at all (ADR 0006).
      counter_html =
        render_component(&Components.usage_meter/1, tenant: counter, feature: :requests)

      assert counter_html =~ "aurora-meter--counter"
      assert counter_html =~ ">7<"
      # No denominator: never "7 / 50", never "7 / " and never a percentage.
      refute counter_html =~ ~r{aurora-meter__value">\s*\d+\s*/}
      refute counter_html =~ "%"
      refute counter_html =~ ~s(role="progressbar")

      # A boolean feature, both ways round.
      assert render_component(&Components.usage_meter/1, tenant: hard, feature: :api_access) =~
               "not included"

      assert render_component(&Components.usage_meter/1, tenant: metered, feature: :api_access) =~
               "enabled"

      # An integer feature carries its plan value and nothing else.
      seats = render_component(&Components.usage_meter/1, tenant: metered, feature: :seats)
      assert seats =~ "aurora-meter--feature"
      assert seats =~ ">25<"
      refute seats =~ "enabled"
    end

    test "I20 a single-point and an empty series render without a broken chart" do
      # Both ends of the range a chart can be handed. The single-point case is
      # the one that divides by a count of one and formats a range with one
      # date in it; the empty case is the one that must not draw an SVG with no
      # bars in it and call that a chart.
      one = [%{date: ~D[2026-09-01], spent: 1_500_000, granted: 0}]

      html = render_component(&Components.spend_chart/1, points: one)

      assert html =~ "<svg"
      assert html =~ "$1.50"
      # One bar, and its range label is the single date rather than a join of
      # two.
      assert length(Regex.scan(~r/class="aurora-spend-chart__bar/, html)) == 1
      assert html =~ "2026-09-01"
      refute html =~ "2026-09-01 to"
      refute html =~ "No spend yet"

      empty = render_component(&Components.spend_chart/1, points: [])

      assert empty =~ "No spend yet"
      refute empty =~ "<svg"
      refute empty =~ "aurora-spend-chart__axis"
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
      test "X271 renders every figure as dollars and says so in words when there is no burn" do
        tenant = unique_tenant()
        {:ok, _} = Credits.grant(tenant, 20_000_000, reference: "pi_summary")

        html = render_component(&Components.credit_summary/1, summary: Credits.summary(tenant))
        document = Floki.parse_fragment!(html)
        text = Floki.text(document)

        assert text =~ "$20.00"
        refute text =~ "20000000"

        # Not a long dash. This component renders into a host's own page, and
        # the house style forbids the character in anything a user reads; Pro
        # said "not yet" here already and core rendered the dash
        # (`open-findings.md` X271, build unit 09b).
        burn = Floki.text(Floki.find(document, ".aurora-credit-summary__item--burn"))
        runway = Floki.text(Floki.find(document, ".aurora-credit-summary__item--runway"))

        assert burn =~ "not yet"
        assert runway =~ "not yet"

        for dash <- [<<0x2014::utf8>>, <<0x2013::utf8>>] do
          refute text =~ dash, "the rendered summary carries #{inspect(dash)}"
        end
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

    test "I20 the usage broadcast carries the tenant_key" do
      # Build unit 09a. Without it AuroraMeter.LiveView.switch_tenant/2 cannot
      # tell a message that was already in flight when the socket left a tenant
      # from a current one, and a usage value is an absolute total, so the stale
      # one stays on screen until that feature moves again.
      tenant = unique_tenant()
      :ok = LiveView.subscribe(tenant)

      AuroraMeter.track(tenant, :ai_generations, 4)
      :ok = Broadcaster.broadcast_now()

      assert_receive {:aurora_meter, :usage, payload}
      assert payload.tenant_key == tenant
      assert payload.feature == :ai_generations
      assert payload.value == 4
      assert %DateTime{} = payload.period_start
    end

    test "I20 a clause matching only the three 0.4.0 keys still matches" do
      # The compatibility half of the additive map key. A host on 0.4.0 wrote a
      # three-key clause and it must keep matching; only a host that matched the
      # WHOLE map breaks, which is what docs/api.md section 7 has told them not
      # to do since 0.1.0.
      tenant = unique_tenant()
      :ok = LiveView.subscribe(tenant)

      AuroraMeter.track(tenant, :ai_generations, 5)
      :ok = Broadcaster.broadcast_now()

      assert_receive {:aurora_meter, :usage,
                      %{feature: :ai_generations, value: 5, period_start: %DateTime{}}}
    end
  end
end
