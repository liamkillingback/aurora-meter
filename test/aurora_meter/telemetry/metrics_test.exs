if Code.ensure_loaded?(Telemetry.Metrics) do
  defmodule AuroraMeter.TelemetryMetricsTest do
    @moduledoc """
    The preset list itself: coverage, grouping, and the two places where the
    metric name has to carry a dimension because the event name does.
    """
    use ExUnit.Case, async: true

    alias AuroraMeter.Schema.CreditTransaction
    alias AuroraMeter.Telemetry, as: Contract
    alias AuroraMeter.Telemetry.Metrics, as: Presets

    test "every preset metric names an event that is in the catalogue" do
      known = MapSet.new(Contract.event_names())

      unknown =
        for metric <- Presets.metrics(),
            not MapSet.member?(known, metric.event_name),
            do: {metric.name, metric.event_name}

      assert unknown == [],
             "presets over events no catalogue has:\n" <>
               Enum.map_join(unknown, "\n", &inspect/1)
    end

    test "every catalogue event with a numeric measurement has at least one preset" do
      covered = MapSet.new(Presets.metrics(), & &1.event_name)

      # A gauge or a counter with no preset is an event a host has to discover
      # from the documentation and write a metric for by hand, which is what
      # this unit exists to remove. The exemptions are named, and each says why.
      exempt = [
        # A broadcast tick is a LiveView fan-out, not an operational signal, and
        # the numbers it carries duplicate the flush ones.
        [:aurora_meter, :broadcast],
        # The start event of a span carries no duration; `:stop` is where the
        # measurement is, and `:stop` has presets.
        [:aurora_meter, :flush, :start],
        [:aurora_meter, :record, :start],
        # The exception event of the flush span has a preset; `record`'s does
        # too. Nothing else here.
        []
      ]

      missing =
        for entry <- Contract.events(),
            entry.measurements != [],
            name <- entry.names,
            name not in exempt,
            not MapSet.member?(covered, name),
            do: "#{inspect(name)} (#{inspect(entry.emitter)})"

      assert missing == [],
             "catalogue events with measurements and no preset:\n  " <>
               Enum.join(missing, "\n  ")
    end

    test "metrics/1 enumerates one credits metric per CreditTransaction kind" do
      names =
        Presets.metrics(include: [:credits])
        |> Enum.map(& &1.event_name)
        |> Enum.filter(&match?([:aurora_meter, :credits, _], &1))
        |> Enum.map(&List.last/1)
        |> Enum.uniq()

      for kind <- CreditTransaction.kinds() do
        assert kind in names,
               "no preset for #{inspect(kind)}; Telemetry.Metrics attaches per event name, " <>
                 "so a kind without its own metric is a kind nobody charts"
      end
    end

    test "metrics/1 with include: [:credits] returns only credits metrics" do
      for metric <- Presets.metrics(include: [:credits]) do
        assert match?([:aurora_meter, :credits | _], metric.event_name),
               "#{inspect(metric.event_name)} is not a credits event"
      end
    end

    test "metrics/1 with every group is the same as metrics/0" do
      assert length(Presets.metrics(include: Presets.groups())) == length(Presets.metrics())
    end

    test "metrics/1 with include: [] returns nothing rather than everything" do
      assert Presets.metrics(include: []) == []
    end

    test "the overrun counter is derived from the settle event with a keep filter" do
      [metric] =
        Enum.filter(
          Presets.metrics(),
          &(&1.name == [:aurora_meter, :credits, :settle, :overrun, :count])
        )

      assert metric.event_name == [:aurora_meter, :credits, :settle]
      assert metric.keep.(%{overrun: true})
      refute metric.keep.(%{overrun: false})
      refute metric.keep.(%{})
    end

    test "no two preset metrics share a name and a type" do
      duplicates =
        Presets.metrics()
        |> Enum.group_by(&{&1.name, &1.__struct__})
        |> Enum.filter(fn {_key, metrics} -> length(metrics) > 1 end)
        |> Enum.map(&elem(&1, 0))

      assert duplicates == [],
             "two metrics of the same type and name collide in a reporter:\n" <>
               Enum.map_join(duplicates, "\n", &inspect/1)
    end

    test "metrics/1 defaults the feature label to the configured value" do
      # The default is read from configuration rather than hard coded, so a host
      # that turns it on once gets it everywhere rather than at each call site.
      assert AuroraMeter.Config.metrics_feature_label?() == false
      refute Enum.any?(Presets.metrics(), &(:feature in &1.tags))
    end
  end
end
