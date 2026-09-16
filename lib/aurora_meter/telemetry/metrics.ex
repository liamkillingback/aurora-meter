if Code.ensure_loaded?(Telemetry.Metrics) do
  defmodule AuroraMeter.Telemetry.Metrics do
    @moduledoc """
    `Telemetry.Metrics` definitions for every core event worth a series.

    This module exists only when the optional `telemetry_metrics` dependency is
    installed. Without it `AuroraMeter.Telemetry` and every event still work;
    this module is simply not defined, and nothing in the library references it.

    ## Use it instead of writing the list yourself

        defmodule MyApp.Telemetry do
          def metrics do
            AuroraMeter.Telemetry.Metrics.metrics() ++ my_own_metrics()
          end
        end

    Every tag here is on `AuroraMeter.Telemetry.tag_allow_list/0` and every
    value set behind one is bounded. Where an event's natural metadata name is
    not an allow-listed name, or where its value is not bounded, the preset maps
    it with `:tag_values` rather than tagging on it raw. The clearest case is
    `[:aurora_meter, :credits, :hold_reconciliation]`, whose `decision` is
    `{:settle, amount}` for a settlement: tagging on that metadata key directly
    gives one time series per distinct amount of money, which is unbounded. The
    preset maps it to `kind: :settle`.

    ## Cost

    `metrics/1` is pure: it builds structs and reads configuration. Attaching
    them is the host's reporter's job, and the reporter's handlers run in the
    process that emitted the event. The gauges are emitted by
    `AuroraMeter.Store` and `AuroraMeter.Cluster`, so a slow handler on one of
    them delays flush batch snapshots.

    ## Options

      * `:feature_label` - tag metering metrics on `:feature`. Defaults to
        `AuroraMeter.Config.metrics_feature_label?/0` (`false`). One series per
        feature per metric: cheap for ten features, not for ten thousand.
      * `:include` - which groups to return, any of `#{inspect([:metering, :quotas, :flush, :cluster, :events, :credits, :workers])}`.
        Defaults to all of them.

    The metric name prefix is fixed at `aurora_meter`. A host that needs another
    maps the list itself; making it an option would let two hosts disagree about
    what a documented metric is called.
    """

    import Telemetry.Metrics

    alias AuroraMeter.Config
    alias AuroraMeter.Schema.CreditTransaction

    @groups [:metering, :quotas, :flush, :cluster, :events, :credits, :workers]

    @doc """
    The preset metric definitions.

    ## Examples

        iex> AuroraMeter.Telemetry.Metrics.metrics(include: [:cluster]) |> Enum.map(& &1.name) |> Enum.uniq()
        [[:aurora_meter, :cluster, :apply, :count], [:aurora_meter, :cluster, :lag, :peers],
         [:aurora_meter, :cluster, :lag, :since_last_message_ms],
         [:aurora_meter, :cluster, :lag, :unreconciled_keys]]

    """
    @spec metrics(keyword()) :: [Telemetry.Metrics.t()]
    def metrics(opts \\ []) when is_list(opts) do
      feature? = Keyword.get(opts, :feature_label, Config.metrics_feature_label?())
      include = Keyword.get(opts, :include, @groups)

      unknown = include -- @groups

      unless unknown == [] do
        raise ArgumentError,
              "AuroraMeter.Telemetry.Metrics.metrics/1 :include got unknown groups " <>
                "#{inspect(unknown)}; known groups are #{inspect(@groups)}"
      end

      Enum.flat_map(@groups, fn group ->
        if group in include, do: group(group, feature?), else: []
      end)
    end

    @doc """
    The groups `:include` accepts.

    ## Examples

        iex> AuroraMeter.Telemetry.Metrics.groups()
        [:metering, :quotas, :flush, :cluster, :events, :credits, :workers]

    """
    @spec groups() :: [atom()]
    def groups, do: @groups

    defp group(:metering, feature?) do
      [
        sum("aurora_meter.track.count",
          tags: feature([], feature?),
          description: "Buffered usage counted, by feature when the label is on."
        )
      ]
    end

    defp group(:quotas, feature?) do
      [
        counter("aurora_meter.reserve.qty",
          tags: feature([:result], feature?),
          description:
            "Entitlement reservations by outcome (:ok, :limit_exceeded, :not_entitled)."
        ),
        sum("aurora_meter.reserve.granted",
          event_name: [:aurora_meter, :reserve],
          measurement: :qty,
          tags: feature([:result], feature?),
          description: "Quantity reserved, by outcome."
        )
      ]
    end

    defp group(:flush, _feature?) do
      [
        sum("aurora_meter.flush.count",
          description: "Counter keys written per committed flush batch."
        ),
        sum("aurora_meter.flush.delta_sum",
          description: "Usage written per committed flush batch."
        ),
        summary("aurora_meter.flush.stop.duration",
          unit: {:native, :millisecond},
          tags: [:result],
          description: "How long the storage write took, by outcome."
        ),
        counter("aurora_meter.flush.error.count",
          description: "Flushes that failed and retained their batch for retry."
        ),
        counter("aurora_meter.flush.exception.duration",
          tags: [:kind],
          description: "Flushes that raised, by exception kind (:error, :exit, :throw)."
        ),
        last_value("aurora_meter.store.gauge.dirty_keys",
          description: "Counter keys changed since the last flush. This is the loss window."
        ),
        last_value("aurora_meter.store.gauge.counter_keys",
          description: "Warm counter keys. A collapse to zero means the Store restarted."
        ),
        last_value("aurora_meter.store.gauge.oldest_pending_age_ms",
          unit: :millisecond,
          description:
            "Time since the dirty set was last observed empty. Sampled, so it is a " <>
              "lower bound and never a per-key age."
        ),
        last_value("aurora_meter.store.gauge.pending_batch_age_ms",
          unit: :millisecond,
          description: "How long the retained batch has been waiting. Exact, and zero when none."
        ),
        last_value("aurora_meter.store.gauge.pending_batch_items",
          description: "Rows in the retained batch."
        )
      ]
    end

    defp group(:cluster, _feature?) do
      [
        sum("aurora_meter.cluster.apply.count",
          tags: [:kind],
          description: "Keys applied from another node, by batch kind (:deltas, :totals)."
        ),
        last_value("aurora_meter.cluster.lag.peers",
          description: "Nodes heard from within the last ten intervals."
        ),
        last_value("aurora_meter.cluster.lag.since_last_message_ms",
          unit: :millisecond,
          description: "Milliseconds since any peer's batch arrived. `-1` means none ever has."
        ),
        last_value("aurora_meter.cluster.lag.unreconciled_keys",
          description:
            "Keys carrying peer value no flush total has superseded. Absent above " <>
              "`:metrics_scan_ceiling`, never zero."
        )
      ]
    end

    defp group(:events, feature?) do
      [
        sum("aurora_meter.record.stop.count",
          tags: feature([:result, :kind], feature?),
          description:
            "Durable quantity recorded, by result (:inserted, :duplicate, :conflict, " <>
              ":invalid, :unavailable, :unsupported) and kind (:usage, :correction)."
        ),
        summary("aurora_meter.record.stop.duration",
          unit: {:native, :millisecond},
          tags: feature([:result, :kind], feature?),
          description: "How long a durable write took."
        ),
        counter("aurora_meter.record.exception.duration",
          tags: [:kind],
          description: "Durable writes that raised."
        ),
        sum("aurora_meter.replay.batch.scanned",
          description: "Rows scanned by a projection rebuild."
        ),
        summary("aurora_meter.replay.batch.duration",
          unit: {:native, :millisecond},
          description: "How long one rebuild batch took."
        ),
        summary("aurora_meter.replay.phase.duration",
          tags: [:kind],
          tag_values: &%{kind: &1.phase},
          unit: {:native, :millisecond},
          description:
            "How long each rebuild phase took. `phase` is bounded (:announce, :drain, " <>
              ":compare, :activate) but is not an allow-listed tag name, so it is " <>
              "mapped onto `kind`."
        ),
        sum("aurora_meter.events.backfill.batch.updated",
          description: "Rows rewritten by `mix aurora_meter.events.backfill`."
        )
      ]
    end

    defp group(:credits, _feature?) do
      ledger_metrics() ++
        [
          # api-change-map 1.6 asks for an overrun counter. It needs no event of
          # its own: a settlement above its hold already carries `overrun: true`,
          # and a `:keep` filter over the entry the ledger already emits is one
          # fewer thing to keep correct than a second emit site.
          counter("aurora_meter.credits.settle.overrun.count",
            event_name: [:aurora_meter, :credits, :settle],
            measurement: :amount,
            keep: &(Map.get(&1, :overrun) == true),
            description: "Settlements charged above their hold, which is how debt is created."
          ),
          counter("aurora_meter.credits.low_balance.available",
            description: "Threshold crossings, once per crossing."
          ),
          counter("aurora_meter.credits.conservation_error.balance_delta",
            description: "Wallet movements the ledger could not account for. Any value is a bug."
          ),
          summary("aurora_meter.credits.hold_reconciliation.age_seconds",
            tags: [:kind, :result],
            tag_values: &hold_tags/1,
            description:
              "Age of each hold examined, by decision and outcome. `decision` is " <>
                "`{:settle, amount}` for a settlement, so it is collapsed to `:settle`: " <>
                "tagging on it raw is one series per amount of money."
          ),
          sum("aurora_meter.credits.recurrence.amount",
            tags: [:result],
            description: "Recurring grants, by result (:granted, :duplicate, :skipped, :error)."
          ),
          sum("aurora_meter.credits.lot_migration.migrated",
            tags: [:state],
            description: "Wallets moved onto lots, by migration state."
          )
        ]
    end

    defp group(:workers, _feature?) do
      [
        sum("aurora_meter.operations.batch.items",
          tags: [:result],
          description: "Items processed by a batched operation, by result."
        ),
        summary("aurora_meter.operations.batch.duration_ms",
          unit: :millisecond,
          tags: [:result],
          description: "How long one operation batch took."
        ),
        sum("aurora_meter.retention.prune.deleted",
          tags: [:kind],
          tag_values: &%{kind: &1.table},
          description:
            "Rows pruned per table. The table name is bounded by the retention allow " <>
              "list, and is mapped onto `kind`."
        ),
        sum("aurora_meter.plans.transition.count",
          tags: [:result],
          description: "Plan transitions applied or refused, by result."
        )
      ]
    end

    # `Telemetry.Metrics` attaches per event name, and the ledger's event name
    # carries the entry kind in its last segment, so a preset has to enumerate
    # the kinds rather than tag on one. `CreditTransaction.kinds/0` is the bound,
    # read at compile time so a kind added later without a preset is a visible
    # omission rather than a silent one.
    defp ledger_metrics do
      for kind <- CreditTransaction.kinds() do
        sum("aurora_meter.credits.#{kind}.amount",
          description: "Micro-USD moved by #{kind} entries."
        )
      end
    end

    defp hold_tags(metadata) do
      %{kind: decision_kind(Map.get(metadata, :decision)), result: Map.get(metadata, :outcome)}
    end

    defp decision_kind({:settle, _amount}), do: :settle
    defp decision_kind(decision) when is_atom(decision), do: decision
    defp decision_kind(_other), do: :unknown

    defp feature(tags, true), do: tags ++ [:feature]
    defp feature(tags, false), do: tags
  end
end
