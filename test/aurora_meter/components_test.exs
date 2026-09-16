# Compiled only when Phoenix.LiveViewTest is available, the same guard
# lib/aurora_meter/components.ex uses on Phoenix.Component. Without it the
# `headless` CI leg (AURORA_HEADLESS=1) cannot compile its suite at all.
if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule AuroraMeter.ComponentsTest do
    @moduledoc """
    Build unit 09b, finding C9: `mix.exs` claimed `phoenix_live_view ~> 0.20 or
    ~> 1.0` while the components were written in LiveView 1.0's curly body
    interpolation, which 0.20 renders as literal text. A 0.20 host would have
    shipped a page reading `{@label}` to its own customers.

    Nothing asserted that any component rendered a value, which is the whole of
    C9: a compile-only leg is silent about it, because on 0.20 the templates
    compile perfectly well.

    The requirement is now `~> 1.0` and this file is what keeps that claim true.
    Every test renders through `Phoenix.LiveViewTest.render_component/2` and
    asserts on the output twice over:

      * **positively**, that the interpolated value is in the HTML, so a
        component that rendered nothing at all cannot pass; and
      * **negatively**, that the output carries no `{` at all. None of these
        four components has any legitimate reason to emit a brace, so the
        absence of one is a statement about the shape of the whole output and
        not a search for one substring (`open-findings.md` X325, X350).

    The decision record, with the measurement behind it, is in
    `docs/evidence/v1/phase-09/09b-components-liveview.md`.
    """
    use AuroraMeter.DataCase, async: false

    import Phoenix.Component, only: [sigil_H: 2]
    import Phoenix.LiveViewTest

    alias AuroraMeter.Components
    alias AuroraMeter.Credits.Money

    # `burn_text/1` and `runway_text/1` returned an em dash for "no honest
    # number to show" and `range_text/1` joined two dates with an en dash, so
    # the free MIT core rendered both characters into a host's page and into an
    # aria-label. Pro had exactly this and closed it at four to zero
    # (`open-findings.md` X271).
    @em_dash <<0x2014::utf8>>
    @en_dash <<0x2013::utf8>>

    @points [
      %{date: ~D[2026-09-01], spent: 1_500_000, granted: 0},
      %{date: ~D[2026-09-02], spent: 0, granted: 5_000_000},
      %{date: ~D[2026-09-03], spent: 250_000, granted: 0}
    ]

    @summary %{
      available: 12_000_000,
      held: 3_000_000,
      promotional: 1_000_000,
      spent_this_period: 4_250_000,
      granted_this_period: 20_000_000,
      daily_burn: 1_416_667,
      runway_days: 8
    }

    describe "usage_meter/1" do
      test "C9 renders the label as text and not as a literal brace expression" do
        tenant = unique_tenant("c9_meter")
        {:ok, _} = AuroraMeter.subscribe(tenant, :pro)
        :ok = AuroraMeter.track(tenant, :ai_generations, 7)

        html =
          render_component(&Components.usage_meter/1, tenant: tenant, feature: :ai_generations)

        # Positive: the label and the usage text are really there, so the
        # negative assertion below is about interpolation and not about an
        # empty render.
        assert html =~ "ai_generations"
        assert html =~ "7 / 1000"
        assert html =~ ~s(class="aurora-meter__label")

        refute_unrendered(html)
      end

      test "C9 an explicit label renders, and the overage line renders its number" do
        tenant = unique_tenant("c9_overage")
        {:ok, _} = AuroraMeter.subscribe(tenant, :scale)
        :ok = AuroraMeter.track(tenant, :ai_generations, 1_100)

        html =
          render_component(&Components.usage_meter/1,
            tenant: tenant,
            feature: :ai_generations,
            label: "Generations"
          )

        assert html =~ "Generations"
        assert html =~ "1100 / 1000"
        # lib/aurora_meter/components.ex renders this one as `+{@quota.overage}
        # over`, a brace in the middle of a text run rather than alone in an
        # element body. On 0.20 it is the clearest symptom of C9 there is.
        assert html =~ "+100 over"

        refute_unrendered(html)
      end
    end

    describe "usage_summary/1" do
      test "C9 renders one meter per plan feature, each with its value" do
        tenant = unique_tenant("c9_summary")
        {:ok, _} = AuroraMeter.subscribe(tenant, :free)
        :ok = AuroraMeter.track(tenant, :ai_generations, 3)

        html = render_component(&Components.usage_summary/1, tenant: tenant)

        assert html =~ "ai_generations"
        assert html =~ "3 / 50"
        assert html =~ "api_access"
        assert html =~ "not included"
        assert html =~ "seats"

        refute_unrendered(html)
      end
    end

    describe "spend_chart/1" do
      test "C9 renders labels, axis figures and tooltips with no literal brace expression" do
        html = render_component(&Components.spend_chart/1, points: @points)

        assert html =~ "Spend per day"
        # Total, peak and zero, all three through Money.format/2.
        assert html =~ Money.format(1_750_000)
        assert html =~ Money.format(1_500_000)
        assert html =~ Money.format(0)
        # The <title> tooltips, which are body interpolations inside an SVG.
        assert html =~ "2026-09-01: $1.50 spent"
        assert html =~ "2026-09-02: $5.00 added"
        # The range text in the axis, which also reaches the SVG's aria-label.
        # "to" and not an en dash (X271).
        assert html =~ "2026-09-01 to 2026-09-03"

        refute_unrendered(html)
      end

      test "C9 money renders through Credits.Money and never as raw micro-dollars" do
        html = render_component(&Components.spend_chart/1, points: @points)

        assert html =~ "$1.50"
        assert html =~ "$5.00"

        # The raw ledger integers must not reach a customer's screen. This is a
        # negative assertion over output, so it is only worth the positive ones
        # above: the same figures are asserted in their formatted shape first.
        for micro <- [1_500_000, 5_000_000, 250_000, 1_750_000] do
          refute html =~ Integer.to_string(micro),
                 "raw micro-dollars #{micro} rendered; money goes through " <>
                   "AuroraMeter.Credits.Money"
        end
      end

      test "C9 an empty chart renders its empty state rather than a brace" do
        html = render_component(&Components.spend_chart/1, points: [])

        assert html =~ "No spend yet"
        refute_unrendered(html)
      end
    end

    describe "credit_summary/1" do
      test "C9 renders every figure through Money and no literal brace expression" do
        html = render_component(&Components.credit_summary/1, summary: @summary)

        assert html =~ "Available"
        assert html =~ Money.format(12_000_000)
        assert html =~ "On hold"
        assert html =~ Money.format(3_000_000)
        assert html =~ "Promotional"
        assert html =~ "Spent this period"
        assert html =~ Money.format(4_250_000)
        assert html =~ "Added this period"
        assert html =~ "Daily burn"
        assert html =~ "/ day"
        assert html =~ "Runway"
        assert html =~ "8 days"

        refute_unrendered(html)
      end

      test "X271 a tenant with no burn says so in words, not in an em dash" do
        summary = %{@summary | daily_burn: nil, runway_days: nil, held: 0, promotional: 0}

        html = render_component(&Components.credit_summary/1, summary: summary)

        assert html =~ "Daily burn"
        assert html =~ "Runway"
        # Both null cases. Pro already said "not yet" here; core rendered a long dash.
        assert html =~ "not yet"
        # The zero rows are omitted by `:if`, which is the other half of the
        # claim that the template really ran.
        refute html =~ "On hold"
        refute html =~ "Promotional"

        refute_unrendered(html)
      end
    end

    describe "the detector itself" do
      # A detector that can match nothing passes everything it cannot see
      # (`open-findings.md` X325, X350). These two render exactly what a
      # LiveView 0.20 host and a dash-carrying component would have produced,
      # and assert that `refute_unrendered/1` refuses each of them. Without
      # these, every green above would be consistent with a helper that
      # asserted nothing at all.
      #
      # The broken output is produced as a string rather than as 0.20 syntax,
      # because under the requirement this unit now declares there is no
      # LiveView left that would render `{@label}` literally, and a control
      # that cannot be built is not a control.
      def unrendered_interpolation(assigns) do
        ~H"""
        <span class="aurora-meter__label">{"{@label}"}</span>
        """
      end

      def dashed(assigns) do
        ~H"""
        <dd class="aurora-credit-summary__value">{<<0x2014::utf8>>}</dd>
        """
      end

      test "C9 control: the detector refuses a literal curly interpolation" do
        html = render_component(&unrendered_interpolation/1, [])

        # It really did render, and what it rendered is the C9 symptom.
        assert html =~ "aurora-meter__label"
        assert html =~ "{@label}"

        assert_raise ExUnit.AssertionError, fn -> refute_unrendered(html) end
      end

      test "X271 control: the detector refuses a rendered em dash" do
        html = render_component(&dashed/1, [])

        assert html =~ "aurora-credit-summary__value"
        assert html =~ @em_dash

        assert_raise ExUnit.AssertionError, fn -> refute_unrendered(html) end
      end
    end

    describe "the declared requirement" do
      test "C9 mix.exs declares a phoenix_live_view requirement this file has rendered under" do
        # D12: never leave a false support claim. The requirement below is the
        # claim; the renders above are what makes it true, and they are run on
        # each declared major by the CI legs 01f defines.
        {:phoenix_live_view, requirement, opts} =
          Mix.Project.config()
          |> Keyword.fetch!(:deps)
          |> List.keyfind(:phoenix_live_view, 0)

        assert opts[:optional], "the LiveView dependency must stay optional (I20)"

        resolved = Application.spec(:phoenix_live_view, :vsn) |> List.to_string()

        assert Version.match?(resolved, requirement),
               "resolved phoenix_live_view #{resolved} does not satisfy the declared " <>
                 "#{requirement}"
      end
    end

    # The detector, in one place so every test uses the same one.
    #
    # None of these components has any reason to emit a brace: they render text,
    # numbers, dates and money. So "no brace anywhere in the output" is a
    # statement about the shape of the whole render. A test that only looked for
    # `{@label}` would pass the day someone renamed the assign.
    #
    # The dash half is a second defect that lived in the same file. `burn_text/1`
    # and `runway_text/1` returned an em dash for "no honest number to show" and
    # `range_text/1` joined two dates with an en dash, so the free MIT core
    # rendered both characters into a host's page and into an aria-label. Pro had
    # exactly this and closed it at four to zero (`open-findings.md` X271). It is
    # checked here, on rendered output, rather than by reading the source,
    # because the source is where it was already fixed once.
    defp refute_unrendered(html) do
      refute html =~ "{@",
             "rendered output carries an unrendered curly interpolation (C9):\n#{html}"

      refute html =~ "{",
             "rendered output carries a `{`, which none of these components emits. " <>
               "On LiveView 0.20 a body interpolation written as `{...}` is literal " <>
               "text (C9):\n#{html}"

      refute html =~ @em_dash,
             "rendered output carries an em dash. No user-facing string in either " <>
               "package uses one (X271):\n#{html}"

      refute html =~ @en_dash,
             "rendered output carries an en dash. No user-facing string in either " <>
               "package uses one (X271):\n#{html}"
    end
  end
end
