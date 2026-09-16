if Code.ensure_loaded?(Telemetry.Metrics) do
  defmodule AuroraMeter.TelemetryCardinalityTest do
    @moduledoc """
    Cardinality and privacy, which are the same property seen from two sides.

    A metric tag becomes one time series per distinct value. Tag on `tenant_key`
    and a host buys one series per tenant for every metric, which is how a
    monitoring bill becomes larger than the product it watches and how a
    reporter runs a node out of memory. Tag on `reference` and the same series
    carries a PaymentIntent id out through the monitoring pipe, which is
    customer data leaving the system by a route nobody reviewed.

    The check is written as `offenders/2` over a list of metrics rather than as
    an assertion over the shipped list, so the same function can be pointed at a
    deliberately bad metric. A rule that has only ever been run against code
    which obeys it has not been shown to refuse anything
    (`open-findings.md` X125).

    There is no alias for `AuroraMeter.Telemetry` here on purpose: aliasing it
    would rebind `Telemetry.Metrics` to `AuroraMeter.Telemetry.Metrics`, and the
    `counter/2` this file builds bad metrics with has to come from the real one.
    """
    use ExUnit.Case, async: true

    import Telemetry.Metrics, only: [counter: 2]

    alias AuroraMeter.Telemetry, as: Contract
    alias AuroraMeter.Telemetry.Metrics, as: Presets

    @forbidden_by_name [:tenant_key, :reference, :origin, :node, :error, :period_start]
    @forbidden_by_suffix [:event_id, :original_event_id, :batch_id, :crossing_id, :item_id]

    test "M1 every shipped preset metric tags only on the allow list" do
      assert offenders(Presets.metrics(feature_label: false), false) == []
    end

    test "M1 the feature tag appears only when the feature label is on" do
      without = Presets.metrics(feature_label: false)
      with_label = Presets.metrics(feature_label: true)

      refute Enum.any?(without, &(:feature in &1.tags)),
             "the feature tag is on by default, and its bound is the host's plan definitions"

      assert Enum.any?(with_label, &(:feature in &1.tags)),
             "feature_label: true changed nothing, so the option is not wired to anything"

      # Both directions. A checker that only ever says yes is not a check.
      assert offenders(with_label, true) == []
      assert offenders(with_label, false) != []
    end

    test "M2 a preset that tags on a forbidden name is refused, one name at a time" do
      for tag <- @forbidden_by_name do
        metric = counter("aurora_meter.track.count", tags: [tag])

        assert [{_name, ^tag}] = offenders([metric], true),
               "tagging on #{inspect(tag)} was accepted; the denial list does not bite"
      end
    end

    test "M2 a preset that tags on any key ending _id is refused, whatever its name" do
      for tag <- @forbidden_by_suffix do
        metric = counter("aurora_meter.track.count", tags: [tag])

        assert [{_name, ^tag}] = offenders([metric], true),
               "tagging on #{inspect(tag)} was accepted; the suffix rule does not bite"
      end
    end

    test "M2 a name nobody thought of is refused too, because the allow list is closed" do
      for tag <- [:invented_dimension, :customer, :email, :payload, :dimensions] do
        metric = counter("aurora_meter.track.count", tags: [tag])

        assert [{_name, ^tag}] = offenders([metric], true),
               "tagging on #{inspect(tag)} was accepted, so the list is a denial list " <>
                 "wearing an allow list's name"
      end
    end

    test "M2 the allow-listed names are accepted, so the check is not refusing everything" do
      for tag <- Contract.tag_allow_list() do
        metric = counter("aurora_meter.track.count", tags: [tag])
        assert offenders([metric], false) == []
      end
    end

    test "M1 no shipped preset tags on a metadata key the event does not have" do
      # A tag naming a key the event never carries yields a `nil` series in
      # every reporter, which reads as a real dimension with one empty value
      # rather than as a mistake.
      known =
        Contract.events()
        |> Enum.flat_map(fn entry -> Enum.map(entry.names, &{&1, entry}) end)
        |> Map.new()

      unknown =
        for metric <- Presets.metrics(feature_label: true),
            entry = Map.get(known, metric.event_name),
            entry != nil,
            # A `:tag_values` function rewrites metadata before tagging, so its
            # tags need not be metadata keys. What they must be is on the allow
            # list, which the tests above assert.
            identity_tag_values?(metric),
            tag <- metric.tags,
            tag not in entry.metadata,
            do: {metric.name, tag, entry.metadata}

      assert unknown == [],
             "preset tags naming a key the event does not carry:\n" <>
               Enum.map_join(unknown, "\n", &inspect/1)
    end

    test "M2 the hold reconciliation preset collapses the settle tuple rather than tagging on it" do
      # `decision` is `{:settle, amount}`, so a tag on it is one series per
      # amount of money. The assertion is on the mapped value, not on the
      # presence of a function.
      [metric] =
        Enum.filter(Presets.metrics(), fn metric ->
          metric.event_name == [:aurora_meter, :credits, :hold_reconciliation]
        end)

      assert metric.tags == [:kind, :result]

      tagged =
        metric.tag_values.(%{
          decision: {:settle, 123_456_789},
          outcome: :settled,
          tenant_key: "org_synthetic",
          reference: "ref_synthetic"
        })

      assert tagged == %{kind: :settle, result: :settled}

      refute Map.has_key?(tagged, :tenant_key)
      refute Map.has_key?(tagged, :reference)
    end

    test "M2 the retention preset maps the table name onto kind rather than tagging on table" do
      [metric] =
        Enum.filter(Presets.metrics(), fn metric ->
          metric.event_name == [:aurora_meter, :retention, :prune]
        end)

      assert metric.tags == [:kind]

      assert metric.tag_values.(%{table: :flush_receipts, blocked: false}) == %{
               kind: :flush_receipts
             }
    end

    test "an unknown :include group is refused rather than silently returning nothing" do
      assert_raise ArgumentError, ~r/unknown groups \[:not_a_group\]/, fn ->
        Presets.metrics(include: [:not_a_group])
      end
    end

    # -- the check itself ----------------------------------------------------

    # Everything the shipped list is asserted against, and everything a
    # deliberately bad metric is asserted against, goes through here.
    defp offenders(metrics, feature_label?) do
      for metric <- metrics,
          tag <- metric.tags,
          not Contract.tag_allowed?(tag, feature_label?),
          do: {metric.name, tag}
    end

    # `Telemetry.Metrics` defaults `:tag_values` to a fresh identity closure, so
    # two structs never compare equal on it. Probing behaviour is the only
    # honest way to tell an identity from a mapping.
    defp identity_tag_values?(metric) do
      probe = %{__probe__: make_ref()}
      metric.tag_values.(probe) == probe
    rescue
      _ -> false
    end
  end
end
