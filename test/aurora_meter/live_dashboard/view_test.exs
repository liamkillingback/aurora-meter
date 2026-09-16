# Compiled only when Phoenix.LiveViewTest is available, the same guard
# lib/aurora_meter/live_dashboard/view.ex uses on Phoenix.Component. The page
# itself needs phoenix_live_dashboard; everything the acceptance criteria are
# about is here and needs only LiveView.
if Code.ensure_loaded?(Phoenix.LiveViewTest) do
  defmodule AuroraMeter.LiveDashboard.ViewTest do
    @moduledoc """
    Build unit 08b, task 08.03: what the core dashboard page may and may not put
    on an operator's screen.

    Three of these are negative assertions over rendered output, and a negative
    assertion over output is only worth what the input was: a page that rendered
    nothing at all would pass every one of them. So every case seeds data into
    the sections first and asserts the sections are populated before it asserts
    what is missing.
    """
    use AuroraMeter.DataCase, async: false

    import Phoenix.LiveViewTest

    alias AuroraMeter.Credits
    alias AuroraMeter.LiveDashboard.Sections
    alias AuroraMeter.LiveDashboard.View
    alias AuroraMeter.Test.Config, as: TestConfig

    @dollar 1_000_000

    test "with the check refusing, the page renders a refusal panel and no section at all" do
      # Seeded first: the data IS there, so "nothing is rendered" is a decision
      # rather than an empty database.
      identifiers = seed_every_section()
      readings = read_all()
      assert Enum.all?(readings, &match?({_name, {:ok, _data}}, &1))

      html =
        render_component(&View.page/1,
          allowed?: false,
          check: {:assign, :operator?},
          readings: readings
        )

      assert html =~ "not authorized"
      assert html =~ ":operator?"

      document = Floki.parse_fragment!(html)
      assert Floki.find(document, "table") == []
      assert Floki.find(document, "dl") == []
      assert Floki.find(document, ".aurora-dash__section") == []

      for {label, value} <- identifiers do
        refute html =~ value, "the refusal panel leaked the #{label}"
      end
    end

    test "rendering every section with seeded data produces no tenant key, feature name, reference or event id" do
      identifiers = seed_every_section()
      readings = read_all()

      # The sections are populated. Without this the next assertion is a test of
      # an empty page.
      assert Enum.all?(readings, &match?({_name, {:ok, _data}}, &1))
      assert {:ok, {:ok, metering}} = Keyword.fetch(readings, :metering)
      assert metering.counter_keys >= 1
      assert {:ok, {:ok, credits}} = Keyword.fetch(readings, :credits)
      assert credits.holds >= 1
      assert {:ok, {:ok, workers}} = Keyword.fetch(readings, :workers)
      assert workers.operations != []
      assert {:ok, {:ok, events}} = Keyword.fetch(readings, :durable_events)
      assert events.generations != [] or events.projection != nil

      html =
        render_component(&View.page/1,
          allowed?: true,
          check: :host_route,
          readings: readings
        )

      assert html =~ "Metering (this node)"
      assert html =~ "Credits"

      for {label, value} <- identifiers do
        refute html =~ value,
               "the core page rendered the #{label} (#{value}). It may render no " <>
                 "tenant-identifying value at all: that is what lets it be shown behind " <>
                 "authorized_by: :host_route."
      end
    end

    test "a gauge sample older than three metrics_intervals renders as stale with its age" do
      # The interval is 10 s and the clock moves 60 s, so the threshold (three
      # intervals, 30 s) is crossed by a margin rather than by a rounding.
      #
      # The age is a monotonic span through AuroraMeter.Clock, never a wall
      # clock: a duration in milliseconds read from a clock that can step
      # backwards is open-findings X100.
      TestConfig.with_config([{:aurora_meter, :metrics_interval, 10_000}], fn ->
        AuroraMeter.Test.with_clock(~U[2026-09-16 10:00:00.000000Z], fn ->
          :ok = AuroraMeter.Telemetry.emit_gauges()

          assert {:ok, fresh} = Sections.read(:metering)
          refute fresh.gauge.stale?

          AuroraMeter.Test.travel(60, :second)

          assert {:ok, stale} = Sections.read(:metering)
          assert stale.gauge.stale?
          assert stale.gauge.age_ms == 60_000

          html =
            render_component(&View.page/1,
              allowed?: true,
              check: :host_route,
              readings: [{:metering, {:ok, stale}}]
            )

          assert html =~ "stale (last sample 60000 ms ago)"
        end)
      end)
    end

    test "a gauge that has never been sampled renders 'not sampled yet' rather than 0" do
      reading =
        {:ok,
         %{
           counter_keys: 4,
           dirty_keys: 0,
           touched_keys: 0,
           flush_interval: 5_000,
           metrics_interval: 10_000,
           gauge: nil
         }}

      html =
        render_component(&View.page/1,
          allowed?: true,
          check: :host_route,
          readings: [{:metering, reading}]
        )

      assert html =~ "not sampled yet"
    end

    test "every section carries its runbook link" do
      readings = for name <- Sections.sections(), do: {name, {:unavailable, :timeout}}

      html =
        render_component(&View.page/1, allowed?: true, check: :host_route, readings: readings)

      document = Floki.parse_fragment!(html)
      links = Floki.find(document, ".aurora-dash__runbook a")

      assert length(links) == length(Sections.sections())
      assert Enum.all?(Floki.attribute(links, "href"), &String.starts_with?(&1, "https://"))
    end

    test "the guarantee banner names the loss window rather than implying durable work" do
      html =
        render_component(&View.page/1, allowed?: true, check: :host_route, readings: [])

      assert html =~ "can be lost"
      assert html =~ "loss window"
    end

    # -- helpers -------------------------------------------------------------

    # Every section gets data, and the data carries one distinctive identifier of
    # each kind the core page must never render.
    defp seed_every_section do
      n = System.unique_integer([:positive])
      tenant = "leakprobe#{n}"
      reference = "leakref#{n}"
      event_id = "leakevt#{n}"

      AuroraMeter.subscribe(tenant, :pro)
      :ok = AuroraMeter.track(tenant, :ai_generations, 3)

      {:ok, _grant} = Credits.grant(tenant, 10 * @dollar, reference: reference)
      {:ok, _hold} = Credits.hold(tenant, 2 * @dollar, "#{reference}:hold")

      {:ok, _event, _outcome} =
        AuroraMeter.Events.record(tenant, :ai_generations, 2,
          id: event_id,
          occurred_at: DateTime.utc_now()
        )

      :ok = AuroraMeter.Operations.put_checkpoint("lot_migration:#{tenant}", cursor: %{})
      :ok = AuroraMeter.Telemetry.emit_gauges()

      [
        {"tenant key", tenant},
        {"feature name", "ai_generations"},
        {"credit reference", reference},
        {"event id", event_id}
      ]
    end

    defp read_all, do: for(name <- Sections.sections(), do: {name, Sections.read(name)})
  end

  defmodule AuroraMeter.LiveDashboard.ViewUnavailableTest do
    @moduledoc """
    Criterion 5, which needs a database that really is not there.

    `async: true` for a reason rather than for speed. With `async: false` the
    sandbox runs in SHARED mode and every process on the node can use the test's
    connection, so the "no database" premise is simply false and the sections
    are readable. With per-process ownership, a process started with `spawn/1`
    (not `Task.async/1`, which sets `$callers` and is resolved back to the
    owner) meets a real `DBConnection.OwnershipError`.
    """
    use AuroraMeter.DataCase, async: true

    import Phoenix.LiveViewTest

    alias AuroraMeter.LiveDashboard.Sections
    alias AuroraMeter.LiveDashboard.View

    test "with the database gone, every affected section renders unavailable and none renders 0 or an empty table" do
      readings = read_all_unconnected()

      for {name, reading} <- readings, name not in [:metering, :cluster, :configuration] do
        assert match?({:unavailable, _class}, reading), "#{name} was readable after all"
      end

      # Only the sections that were actually unavailable. `:configuration` reads
      # no database, is therefore available, and legitimately renders
      # `metrics_interval: 0` in the test environment: scanning the whole page
      # for the character "0" would fail on a correct figure and say nothing
      # about the rule.
      unavailable = Enum.filter(readings, &match?({_name, {:unavailable, _class}}, &1))

      assert length(unavailable) >= 3

      html =
        render_component(&View.page/1,
          allowed?: true,
          check: :host_route,
          readings: unavailable
        )

      assert html =~ "unavailable (:database_unavailable)"

      document = Floki.parse_fragment!(html)

      # No zero anywhere, and no table with a head and no body rows. Both are
      # what a naive "rescue and return a default" implementation produces, and
      # both read to an operator as "there is nothing wrong here".
      zeroes =
        document
        |> Floki.find("dd, td")
        |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
        |> Enum.filter(&(&1 == "0"))

      assert zeroes == [], "an unavailable section rendered a zero"

      empty_tables =
        document
        |> Floki.find("table")
        |> Enum.filter(&(Floki.find(&1, "tbody tr") == []))

      assert empty_tables == [], "an unavailable section rendered an empty table"
    end

    defp read_all_unconnected do
      parent = self()

      spawn(fn ->
        readings = for name <- Sections.sections(), do: {name, Sections.read(name)}
        send(parent, {:readings, readings})
      end)

      assert_receive {:readings, readings}, 5_000
      readings
    end
  end
end
